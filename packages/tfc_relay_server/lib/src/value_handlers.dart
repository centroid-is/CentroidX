/// The bodies of `read`, `readFresh`, `readMany`, `write`, `writeStatus` and
/// the hold-to-run tick.
///
/// Same rule as `session_handlers.dart`, for the same reason: **nothing in
/// here registers anything.** Handlers are handed to `RelaySession._on`, which
/// is the one seam where a method enters the table and therefore the one place
/// the handshake gate and the error armor are applied. A handler that
/// registered itself would be a handler that arrived ungated, and `write`
/// ungated is a client that never said hello reaching a contactor.
/// A grep for the peer's registration call over this file is meant to come
/// back empty — and unlike `session_handlers.dart`, this doc does not spell
/// that call out, so the grep is a check anyone can run rather than a sentence
/// that answers itself.
///
/// ## Why these five exist in Phase 4 rather than Phase 5
///
/// 04-RESEARCH Finding 4 ran the method sweep against a live `RelayServer`:
/// every one of these answered `-32601 Unknown method`, which put 28 of the
/// contract suite's 44 checks out of reach over the real gateway. The
/// contract leg cannot run against a socket that cannot read or write, so the
/// plumbing was pulled forward. Only the plumbing.
///
/// ## What Phase 5 still owns, and this file deliberately does not do
///
///  * **Write semantics.** Three-state depth beyond forwarding what the source
///    reports, dedup of a re-sent `cmd` against a live window, hold-to-run and
///    the rest of the write-safety machinery (WRT-*).
///  * **Authorization.** Which keys a session may read and which it may
///    actuate is Phase 6 (SEC-03, T-04-03). Every method here is reachable by
///    anyone who completes the handshake. That is not an oversight being
///    hidden — it is the same posture `subscribe` has had since Phase 3, and
///    it attaches at the same per-key seam.
///
/// ## The outcome log, and the one answer it must never invent
///
/// `writeStatus` is answered from [WriteOutcomeLog] — a short-TTL map of
/// `cmd` → outcome, pruned on access rather than by a timer, and owned by the
/// **server** rather than by this per-session object. That lifetime is
/// 04-REVIEW CR-02 and the whole of why the log is a class of its own; its
/// library doc carries the argument.
///
/// [WriteNotReceived] is the only outcome that tells an operator a re-send is
/// safe. A gateway that has merely *forgotten* a command must therefore never
/// spell its amnesia that way — so absence from the log is not enough to say
/// "never received". Three pieces of evidence are required, all of them the
/// gateway's own: the `cmd` is a ULID and can be dated, the instant it names
/// is one this log was already recording at, and it is inside the TTL.
/// Anything else is [WriteUnknown], because the gateway cannot tell "never
/// arrived" from "arrived while I was not looking".
library;

import 'dart:async';

import 'package:json_rpc_2/error_code.dart' as rpc_errors;
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'error_codes.dart';
import 'server_config.dart';
import 'session_handlers.dart' show KeyRejectKinds;

/// The handler bodies for one session's value methods.
///
/// Holds no outcome state of its own. The log it writes to and reads from
/// belongs to the server and outlives this object, because the only caller of
/// `writeStatus` is a client that has just reconnected — see
/// `write_outcome_log.dart`.
final class ValueHandlers {
  ValueHandlers({
    required this.api,
    required this.config,
    required this.now,
    WriteOutcomeLog? outcomes,
    this.ownerOf,
    this.canWriteKey = _anyKeyWritable,
  }) : outcomes =
            outcomes ?? WriteOutcomeLog(ttl: config.writeOutcomeTtl, now: now);

  /// The default [canWriteKey]: every key is writable.
  ///
  /// Not "no policy configured" written as a null check, but the same
  /// posture `PermissiveTokenValidator` takes and for the same reason — a
  /// `ValueHandlers` built directly by a test (`surface_test.dart:146-163`
  /// builds exactly that, as do the unit kits in `value_handlers_test.dart`)
  /// must behave as it did before this argument existed. Production never
  /// gets this: `RelaySession` always passes the session's own predicate.
  static bool _anyKeyWritable(String key) => true;

  final StateManApi api;
  final ServerConfig config;

  /// Wall-clock epoch milliseconds. Injected rather than read, because every
  /// promise the outcome log makes is arithmetic about *when*.
  final int Function() now;

  /// The server's outcome log. Defaulted to a fresh one so a handler can be
  /// driven on its own in a unit test, exactly as it is over a socket.
  final WriteOutcomeLog outcomes;

  /// Which session recorded an outcome, carried into the log for Phase 6's
  /// identity narrowing.
  ///
  /// A callback rather than a value because these handlers are built during
  /// the session's `_start` and the session id is minted later, by `hello` —
  /// the same reason `SessionHandlers` reads its epoch through one.
  final String? Function()? ownerOf;

  /// Whether the station this session speaks for may actuate a given key.
  ///
  /// A predicate rather than a policy object plus an identity, and read
  /// **late** on every call — the [ownerOf] idiom exactly (`relay_session
  /// .dart:576`), for the identical reason: these handlers are built during
  /// the session's `_start` and the identity is minted afterwards, by
  /// `_hello`. `RelaySession` supplies its `PolicyStateMan`'s own `canWrite`,
  /// which is the same object every read surface is already served through,
  /// so there is exactly one place that decides what a null identity means.
  ///
  /// It answers only about **writability**, never about visibility. A key the
  /// station may not see is refused as nonexistent by the existence check
  /// above this gate and never reaches it — see the comment at the call site,
  /// which is where that ordering is load-bearing.
  final bool Function(String key) canWriteKey;

  /// How many outcomes are being held. Read by the test that proves the log
  /// is bounded (T-04-06); nothing in production depends on it.
  int get recordedOutcomes => outcomes.recordedOutcomes;

  /// The hold-to-run deadmen this **session** has engaged, by plant key.
  ///
  /// Per session because this object is: `relay_session.dart` builds one
  /// `ValueHandlers` per `RelaySession`, and that is what makes teardown free
  /// — the session's `_teardown` calls [releaseAllHolds] and a panel that
  /// vanished stops feeding the machine it was jogging (05-RESEARCH §G.4,
  /// D-P5-J). A hold map on the *server* would outlive the socket that
  /// engaged it, which is a machine being fed by nobody.
  ///
  /// It is also the authorization boundary for the tick (T-05-16). A `'h'`
  /// frame names a key; this map decides whether that name means anything.
  /// Without it the tick would be a write primitive with no engage in front
  /// of it, no cmd, no outcome and no refusal path.
  final _holds = <String, HoldHandle>{};

  /// Whether [releaseAllHolds] has run — which is to say, whether the session
  /// this object belongs to has been torn down.
  ///
  /// It exists for exactly one reader: the store in [write]'s hold branch,
  /// which resumes after an `await` that [releaseAllHolds] can happen in the
  /// middle of. `RelaySession._teardown` calls that method **synchronously**
  /// (`relay_session.dart:1471`), on purpose — the counter has to stop in the
  /// same turn the session is given up on — and it clears [_holds] on the way
  /// out. A handler suspended in `api.holdToRun` at that instant would
  /// otherwise resume into a cleared map, find it empty, and store a **held**
  /// handle into a dead session: a counter nothing will tick and nothing will
  /// release, because the teardown that would have has already run.
  ///
  /// One-way. A session does not come back; a reconnect builds a new
  /// `ValueHandlers` (`relay_session.dart` constructs one per session), which
  /// is the same reason [_holds] is per-session in the first place.
  bool _closed = false;

  /// How many ticks were dropped: malformed, naming a hold this session never
  /// engaged, or thrown out of by the source.
  ///
  /// Doc'd exactly like [recordedOutcomes] and for the same reason: read by a
  /// test, and nothing in production depends on it. The production home for
  /// this number is a `PIPE.*` health key, and those ship with upstream
  /// fan-in in Phase 8 (STATE.md roadmap decision) — so the counter is built
  /// now and surfaced later (D-P5-I).
  int get droppedHoldTicks => _droppedHoldTicks;
  int _droppedHoldTicks = 0;

  /// `h`: one deadman tick for a hold **this session** engaged.
  ///
  /// The first client→server notification on this wire, and the only handler
  /// here that answers nothing: `json_rpc_2` discards a notification
  /// handler's return value and sends no frame back (measured, 05-RESEARCH
  /// §B.1 #1). The `Future<Object?>` signature is `RelaySession._on`'s, so
  /// the tick inherits the handshake gate and the error armor from the one
  /// seam every other method comes through.
  ///
  /// **The lookup is the authorization boundary, not bookkeeping** (D-P5-G,
  /// T-05-16). The counter is applied to the handle [write] took when *this*
  /// session engaged the hold — never to the key the frame names. Applying it
  /// to an arbitrary key would make `h` a write primitive with no engage in
  /// front of it, no cmd, no outcome-log entry and no refusal path, reachable
  /// by any peer past the handshake.
  ///
  /// **It cannot throw. Not for anything.** A malformed frame, a hold this
  /// session does not have, a source that throws out of `onTick` — all of
  /// them are dropped and counted. `json_rpc_2` sends no frame back for a
  /// notification and calls `onUnhandledError` instead (§B.1 #2), which
  /// `RelaySession.serve` forwards to the `RelayErrorHandler`: at 10 Hz per
  /// held button, a throw here is a log flood and nothing else. A tick for an
  /// unknown hold is an ordinary, expected condition — the panel released a
  /// moment ago, or the gateway restarted under it — and the client learns
  /// nothing either way, because the counter stopping is the whole signal.
  ///
  /// The frame's own `n` is decoded and validated but is **not** the value
  /// written: [HoldHandle.tick] mints the next counter from the handle the
  /// engage created. Trusting `n` would put an attacker-chosen integer on a
  /// deadman tag through this path, which is precisely what the write path's
  /// "1 or 0, nothing else" refusal prevents from the other side.
  Future<Object?> holdTick(rpc.Parameters params) async {
    final HoldTickParams tick;
    try {
      // Sanitize before decode, as on every ingress path: `1e999` decodes to
      // Infinity in silence, and `Infinity.toInt()` throws where nothing is
      // catching. `HoldTickParams.fromJson` refuses a non-finite counter
      // anyway; both belts are cheap and this one is the house convention.
      final decoded =
          (sanitize(params.asMap).value as Map).cast<String, Object?>();
      tick = HoldTickParams.fromJson(decoded);
    } catch (_) {
      _droppedHoldTicks++;
      return null;
    }

    final hold = _holds[tick.key];
    if (hold == null) {
      _droppedHoldTicks++;
      return null;
    }

    try {
      hold.tick();
    } catch (_) {
      // A source that throws while being fed is a dropped tick like any
      // other. The machine stops because the counter stopped, which has
      // already happened by the time anyone could act on an exception here.
      _droppedHoldTicks++;
    }
    return null;
  }

  /// `read`: the cached value, no round trip.
  ///
  /// **Why it stays on the table even though `RemoteStateMan` never sends it**
  /// (04-REVIEW WR-11). `read` is `StateManApi`'s cached read and this gateway
  /// exists to serve that interface; the panel client happens to hold its own
  /// `ValueStore` and answers from it synchronously, which is a property of
  /// *that* client and not of the protocol. A browser bundle, a diagnostic
  /// tool or a script has no cache to peek, and for them the gateway's cache
  /// is the only one there is. It adds no exposure class its neighbours do not
  /// already have — every method here is reachable by anyone past the
  /// handshake until Phase 6 attaches authorization at the same per-key seam.
  Future<Object?> read(rpc.Parameters params) async {
    // Sanitize before decode, every time, on every ingress path:
    // `jsonDecode('1e999')` yields Infinity in silence, and an Infinity that
    // reaches an error response makes the *error* unencodable — the 02-05 hang.
    final decoded = sanitize(params.asMap).value as Map;
    final key = _requireKey(decoded['key'], Methods.read);

    // An answer, not a throw. The caller asked a legitimate question and
    // "this source does not serve that tag" is the answer to it; a refusal
    // would make a page editor's key check indistinguishable from a broken
    // gateway.
    if (!api.keys.contains(key)) return _unserved(key);

    return {'key': key, 'value': _wire(api.read(key)).toJson()};
  }

  /// `readFresh`: force the round trip the cache is under suspicion of.
  ///
  /// **The existence check is the same one [read] has had all along** (06-04,
  /// amendment 2 of 06-CONTEXT). Until this plan `readFresh` forwarded the key
  /// straight to the source and reported whatever came back — `q:258`
  /// (`uncertainNotYetKnown`) on the fake, with no `rejected` map at all —
  /// while its neighbour answered `q:770` (`errorConfig`) plus
  /// `KeyReject(unknownKey)`. Two read methods disagreeing about one tag is
  /// the divergence 04-REVIEW WR-11 already fixed once between [read] and
  /// [readMany], and it is worse here: `readFresh` is the method a diagnostics
  /// page calls precisely *because* it doubts the cache, so "wait, it is
  /// coming" is the one answer that cannot be right about a tag that will
  /// never come.
  ///
  /// **This changes the answer a client sees**, deliberately, and the two
  /// codes mean opposite things. 258 is "no reading has arrived yet"; 770 is
  /// "the source affirmatively said the tag is gone" (STATE.md, Phase 1
  /// handoff, where `errorConfig` was narrowed to exactly that). The gateway
  /// knows the second — it has the source's key list in hand — and only the
  /// second is a sentence an engineer can act on.
  ///
  /// The answer is built by [_unserved], the same helper [read] uses, so the
  /// two cannot drift apart again by editing one of them.
  Future<Object?> readFresh(rpc.Parameters params) async {
    final decoded = sanitize(params.asMap).value as Map;
    final key = _requireKey(decoded['key'], Methods.readFresh);

    if (!api.keys.contains(key)) return _unserved(key);

    final value = await api.readFresh(key);
    return {'key': key, 'value': _wire(value).toJson()};
  }

  /// `readMany`: one round trip, an answer per key.
  ///
  /// A key this source cannot serve costs that one key. The argument is
  /// `session_handlers.dart:30-44`'s, unchanged: a page config carries ~1500
  /// hand-edited keys, so one typo must not cost the call.
  Future<Object?> readMany(rpc.Parameters params) async {
    final decoded = sanitize(params.asMap).value as Map;
    final raw = decoded['keys'];
    if (raw is! List) {
      throw _refuse(Methods.readMany,
          'readMany needs a "keys" list: the one call that exists so a '
          'diagnostics page does not pay N round trips');
    }
    if (raw.isEmpty) {
      throw _refuse(Methods.readMany,
          'readMany needs at least one key: a request for nothing is a '
          'round trip the client then waits on');
    }
    if (raw.length > config.maxKeysPerSubscribe) {
      throw _refuse(
          Methods.readMany,
          'readMany carried ${raw.length} keys, over this server\'s limit of '
          '${config.maxKeysPerSubscribe}; split the request or raise '
          'maxKeysPerSubscribe');
    }

    final servable = api.keys.toSet();
    final wanted = <String>[];
    final rejected = <String, Object?>{};
    for (final entry in raw) {
      if (entry is! String || entry.trim().isEmpty) {
        rejected['$entry'] = const KeyReject(KeyRejectKinds.invalidKey,
                message: 'an empty key is not a tag; something built this '
                    'list from a blank field')
            .toJson();
        continue;
      }
      if (!servable.contains(entry)) {
        rejected[entry] = _unknownKey(entry).toJson();
        continue;
      }
      wanted.add(entry);
    }

    // One call for the whole list even when the list is empty after
    // filtering — an empty upstream read is cheap, and skipping it would make
    // the round-trip count depend on how many keys were mistyped.
    final values = wanted.isEmpty
        ? const <String, DynamicValue>{}
        : await api.readMany(wanted);

    return {
      'values': {
        for (final entry in values.entries) entry.key: _wire(entry.value).toJson(),
      },
      'rejected': rejected,
    };
  }

  /// `write`: forward the operator's intent, report what became of it.
  ///
  /// Never throws to report an outcome. A JSON-RPC error on this path means
  /// "definitively no effect, safe to re-send" (`write_result.dart:6-8`), so
  /// the only refusals here are shape refusals raised *before* the plant is
  /// touched; anything that goes wrong after that is [WriteUnknown].
  Future<Object?> write(rpc.Parameters params) async {
    final sanitized = sanitize(params.asMap);
    if (sanitized.hadNonFinite) {
      // Refused rather than cleaned up, and the asymmetry is the point.
      // Sanitizing is right for telemetry, where the alternative is a frame
      // that fails for every client. Here a nulled `value` actuates the device
      // with something nobody chose, and a nulled `expect` is this path's
      // encoding of "no guard at all" — the operator's "only if it still reads
      // 1200" silently becomes "whatever it reads".
      throw _refuse(
          Methods.write,
          'this write carries a non-finite number. Nulling the value would '
          'actuate the device with something the operator did not choose, and '
          'nulling an expect would turn a guarded write into an unconditional '
          'one, so neither is done for you');
    }
    final decoded = (sanitized.value as Map).cast<String, Object?>();

    final WriteParams request;
    try {
      request = WriteParams.fromJson(decoded);
    } on FormatException catch (error) {
      throw _refuse(Methods.write, 'write params could not be read: $error');
    } on TypeError {
      throw _refuse(
          Methods.write,
          'write needs a "cmd" and a "key", both strings: the cmd is the '
          'operator action this outcome will be reconciled against, and '
          'without it nothing can be re-queried later');
    }
    if (request.cmd.trim().isEmpty) {
      throw _refuse(
          Methods.write,
          'write needs a non-empty "cmd": it is the id the operator\'s action '
          'was minted under, and the only handle writeStatus has on it');
    }
    if (request.key.trim().isEmpty) {
      throw _refuse(Methods.write, 'write needs a non-empty "key"');
    }
    // **A tag this source does not serve is refused, not invented** (06-04,
    // 06-CONTEXT amendment 2, T-06-15). Until this plan `write` consulted
    // `api.keys` nowhere at all: a write naming a key the source had never
    // heard of was forwarded, answered `applied` with a readback, and the key
    // appeared in `api.keys` afterwards. The operator was told a setpoint took
    // on a machine that never heard of it — a false `applied` is the one
    // three-state answer nobody downstream can act on, and on a
    // safety-relevant path silently inventing a tag is the worst option
    // available.
    //
    // **The code is `INVALID_PARAMS`, deliberately, and not `forbidden`**
    // (06-RESEARCH §E.7 rows 2 and 3). A nonexistent tag and an unauthorized
    // one are different facts and the client behaves differently about them:
    // the first is a typo to fix, the second a permission to obtain. 06-08's
    // hiding rule sends a hidden key down *this* path precisely because
    // answering "forbidden" would leak the existence it is hiding — which is
    // also why the message and the `rejected` map are the same ones `read`
    // and `readMany` produce, from [_unknownKeyMessage], rather than a fourth
    // hand-copied sentence.
    //
    // **Placed here, and the placement is the property.** Above the
    // fingerprint, above the idempotency window and above the in-flight
    // `_record` at the bottom of this ladder, so `INVALID_PARAMS` means on
    // this path exactly what it means everywhere else on it: definitively no
    // effect, nothing sent, nothing remembered, safe to re-send. A refusal
    // below the pre-record would still refuse — and would leave `writeStatus`
    // answering `unknown` about an action that provably never happened, which
    // is the answer that makes an operator press the button again.
    //
    // One check covers `holdToRun` as well: that seam is reachable only
    // through this method (`:541-556`), so an engage on an unserved tag is
    // refused before a handle is taken and before anything starts feeding a
    // deadman counter this gateway invented.
    if (!api.keys.contains(request.key)) {
      throw _refuseUnknownKey(Methods.write, request.key);
    }
    // **The authorization gate, and its two neighbours are both load-bearing**
    // (06-08, SEC-03, T-06-35).
    //
    // **Below the existence check, and that ordering is the hiding rule.** A
    // key this station may not *see* has already been filtered out of
    // `api.keys` by the session's `PolicyStateMan`, so it was refused one line
    // above as a tag this source does not serve — byte-identically to a tag
    // that never existed — and it never reaches this question. Swap the two
    // and a hidden key is answered `forbidden`, which says it exists: ask
    // about a thousand names, keep the ones answered `forbidden` rather than
    // `unknownKey`, and the plant's address space has been enumerated by a
    // station that may not read a byte of it (T-06-37). The two refusals are
    // two different facts — a typo to fix, versus a permission to obtain —
    // and `policy_test.dart` asserts the codes differ.
    //
    // **Above the fingerprint, the idempotency window and the in-flight
    // `_record`**, exactly like the unserved-tag refusal it follows, so
    // `-32005` inherits what `INVALID_PARAMS` means everywhere on this ladder:
    // definitively no effect, nothing sent, nothing remembered. A `writeStatus`
    // about this cmd afterwards answers `not_received` and is entitled to. A
    // gate a few lines lower would refuse just as loudly and leave a
    // reconnecting panel told "unknown" about a setpoint that never moved.
    //
    // One check covers `holdToRun` too (ruling OQ5): that seam is reachable
    // only through this method, so a `view` station's engage is refused before
    // a handle is taken and before anything feeds a deadman counter.
    if (!canWriteKey(request.key)) {
      throw rpc.RpcException(
          ServerErrorCodes.forbidden,
          'this station may see "${request.key}" but may not actuate it. '
          'Nothing was sent: no device was consulted and no outcome was '
          'recorded, so this action definitively did not happen. Do not '
          'retry — the session is fine and reading continues; what is missing '
          'is a permission, and permissions change in the gateway\'s token '
          'file rather than on the next attempt',
          data: _substitute(Methods.write));
    }
    // The hold flag's vocabulary on the *write* path is exactly two values,
    // and this is a pre-plant refusal like the ones above it: raised before
    // `api.holdToRun` and before `api.write`, so `INVALID_PARAMS` here means
    // what it means everywhere else on this path — definitively no effect.
    //
    // Anything else would make `write` a way to put an arbitrary integer on a
    // deadman tag while calling it an engage. Intermediate counter values are
    // ticks: notifications, no cmd, no outcome, and only ever for a hold this
    // session already engaged.
    //
    // `num` rather than `int` on purpose: a REAL tag's 1.0 and a DINT's 1 are
    // the same operator intent, and this refusal is about the number 7, not
    // about which Dart type a JSON decoder chose.
    if (request.hold) {
      final value = request.value;
      if (value is! num || (value != 1 && value != 0)) {
        throw _refuse(
            Methods.write,
            'a hold-to-run write carries 1 to engage or 0 to release, and '
            'this one carries ${request.value}. Intermediate counter values '
            'arrive as ticks — notifications for a hold already engaged — '
            'and never as writes, so nothing was sent: no hold was taken and '
            'no device was consulted');
      }
    }

    // The request this outcome will be recorded for, and the request a second
    // frame under the same id is compared against. Built from the decoded
    // params *after* `sanitize` ran at the top of this method — so the value
    // stored is the value that goes upstream, and the deep comparison below is
    // bounded in depth by that same sanitize pass (`json_equality.dart`
    // recurses; ingress is what keeps that finite).
    final fingerprint = (
      key: request.key,
      value: request.value,
      expect: request.expect,
    );

    // **One id, one actuation** (04-REVIEW CR-05), and — since 05-03 — one id,
    // one *answer*. The `cmd` arrives from the wire and is accepted verbatim,
    // so any peer past the handshake can send a second frame under an id this
    // gateway has already recorded. Two of those are not the same event, and
    // the difference is the request itself:
    //
    //  * **The same key, value and expect** is one operator action arriving
    //    twice — a client that restarted still holding the id it minted at the
    //    keyboard. It is answered with the outcome that action already got,
    //    from the log, with no second `api.write`. That is the Stripe
    //    semantic, and the `upstreamWriteAttempts` assertion in
    //    `value_handlers_test.dart` is the property: one press, one movement
    //    of the machine.
    //
    //    Including while the first write is still upstream (**D-P5-A**). The
    //    pre-record below means such a replay reads `unknown(in_flight)`, and
    //    that is deliberately not a refusal: a refusal reaches the client as
    //    `WriteRejected(server_refused)` and *settles* the id, against a write
    //    that is at that instant on its way to a machine. An `unknown` leaves
    //    it unresolved, so the next `ready` re-queries `writeStatus`.
    //
    //  * **Anything else** — a different key, a different value, or a
    //    different compare-and-set guard (**D-P5-B**: "set 1450" and "set 1450
    //    only if it still reads 1200" are two different intents) — stays a
    //    refusal. There is no reading of two different writes under one id
    //    that an operator can act on, and reporting the first one's outcome
    //    for the second would put "applied" on a setpoint nobody applied.
    //
    // The comparison is `WriteOutcomeEntry.matches` (`write_outcome_log.dart`,
    // which also carries why the fingerprint is a record and why a null one
    // never matches), over `jsonEquals` — deep, insensitive to JSON object key
    // order, and holding numbers to their runtime type so a DINT 1 and a REAL
    // 1.0 stay two different writes.
    //
    // The refusal is a shape refusal raised before the plant is touched, which
    // is the one class of refusal this path allows: `INVALID_PARAMS` on a
    // write means "definitively no effect", and here that is exactly true.
    final held = outcomes.entryFor(request.cmd);
    if (held != null) {
      if (held.matches(fingerprint)) {
        // No `api.write`, and no new `_record`: nothing happened this time
        // round, so there is nothing new to remember. `_withCmd` already
        // normalized the stored result under this client's id when it was
        // recorded, and `WriteResult.fromJson` decodes it on the far side like
        // any other write answer — a replay of an applied write therefore
        // re-adopts the same readback onto the mimic.
        return held.result.toJson();
      }
      throw _refuse(
          Methods.write,
          'the command id "${request.cmd}" is already recorded on this '
          'gateway for a different write. One id is one operator action: a '
          'second, different write under it would actuate the plant twice and '
          'leave one writeStatus answer covering both, so nothing was sent: '
          'this write had no effect of any kind and no device was consulted '
          'about it. The two frames disagree about the key, the value or the '
          'expect guard, which is a defect in the caller and not a condition '
          'of the machine. Mint a new id per action');
    }

    // **One key, one live hold on this session** (05-REVIEW WR-02), and the
    // refusal is what keeps every handle this gateway ever took reachable.
    //
    // The alternative considered was re-engage — take the new hold, release
    // the displaced one — and it is worse in the only way that matters: the
    // new engage puts 1 on the tag and the displaced handle's release then
    // puts 0 on it, so the deadman counter reads released while a live hold
    // exists. Refusing touches nothing.
    //
    // Refusing also matches both ends of the design. `HoldToRunController`
    // throws `StateError` on a second `press()` for the same reason (§4.6a:
    // one finger, one button, and nothing in software can decide which of two
    // holds the machine should obey), and `releaseAllHolds` — which is what
    // makes a hold unable to outlive its socket (T-05-20) — iterates
    // `_holds.values`, so a handle that is not in that map is a hold no
    // teardown can end.
    //
    // Placed *after* the idempotency window above, so a replayed engage under
    // the same id is still answered from the log rather than refused: one
    // press arriving twice is one press. Placed *before* `_record` and before
    // any source call, so `INVALID_PARAMS` means here what it means
    // everywhere else on this path — definitively no effect.
    //
    // Conditional on the entry still being *held*, because a source can end a
    // hold for its own reasons (a PLC link dropping under it). An inert
    // handle is not an orphan — there is nothing left to release — and
    // refusing against one would wedge the key for the life of the session.
    //
    // **And it is only half of the invariant.** This check is synchronous and
    // nothing above it in `write` awaits anything, so within one turn it holds
    // absolutely. It says nothing about the suspend at `api.holdToRun` further
    // down, where a second engage or a teardown can arrive; the re-check
    // beside that call is the other half, and neither half is sufficient
    // alone.
    if (request.hold && request.value == 1) {
      final live = _holds[request.key];
      if (live != null && live.isHeld) {
        throw _refuse(
            Methods.write,
            'this session already holds a live hold-to-run on "${request.key}" '
            'and one key is one deadman counter, so a second engage was not '
            'sent: no hold was taken and no device was consulted. Two holds on '
            'one tag are a contradiction at the operator\'s end — one finger, '
            'one button — and the second handle would be unreachable by every '
            'tick, every release and the session teardown that has to end it. '
            'Release the live hold first');
      }
      if (live != null) _holds.remove(request.key);
    }

    // Recorded *before* the call so a writeStatus arriving while this is
    // upstream is answered "unknown" and not "never received": the command is
    // on its way to a machine at that exact moment.
    _record(
        request.cmd,
        WriteUnknown(
            request.cmd,
            const WriteReason('in_flight',
                message: 'the gateway has sent this write upstream and has not '
                    'heard back yet')),
        fingerprint);

    WriteResult result;
    // Set when this engage lost a race it could only lose *across* the await
    // in the hold branch below — see the re-check there. Thrown after the
    // outcome has been recorded rather than from inside the branch, for two
    // reasons: the `catch` below turns every throw into `WriteUnknown`, which
    // is the wrong answer for a refusal this gateway is certain about; and a
    // refusal that skipped `_record` would leave `writeStatus` answering
    // `unknown(in_flight)` for ever about a command that has already settled.
    rpc.RpcException? lostTheRace;
    try {
      // **The hold branch (D-P5-C).** An engage and a release are ordinary
      // writes — same idempotency window above, same in-flight pre-record,
      // same three-state outcome, same two record sites below — and the flag
      // changes only which seam they travel through.
      //
      //  * `hold: true, value: 1` → `api.holdToRun`, and the handle it
      //    returns is what this session's ticks feed. An `api.write(key, 1)`
      //    here would put a 1 on the tag with nothing behind it: the number
      //    would be right for one instant and there would be no way to
      //    advance it afterwards, which is a jog button that stops the
      //    machine a second after it starts it.
      //  * `hold: true, value: 0` → the handle's own `release()`, which
      //    writes the 0 and completes `onReleased`.
      //  * A replayed engage answered from the log above never reaches this
      //    branch, and if the `cmd` was recorded by a *different* session the
      //    replaying one is told "applied" without being given a handle
      //    (05-REVIEW IN-01). The log is server-global by design (04-REVIEW
      //    CR-02) and `_holds` is per-session, so every tick that session
      //    then sends is dropped and counted in `droppedHoldTicks`. Fail-safe
      //    — the counter never advances, so the machine stays stopped — but
      //    the UI shows a live hold on a dead button. It is reachable only by
      //    a peer holding another client's 80-bit-random ULID, which is the
      //    capability argument `write_outcome_log.dart:32-41` already makes
      //    and Phase 6's identity narrowing closes.
      //  * `hold: true, value: 0` with **no** handle held → falls through to
      //    the ordinary write below, deliberately. Writing 0 to a deadman tag
      //    is a legitimate thing to do, and a gateway that restarted holds no
      //    handle for a hold its predecessor engaged; refusing would make a
      //    sensible release read as a caller defect.
      //
      // The outcome is relabelled by the same `_withCmd` every other write
      // answer goes through: the source mints its own id inside `holdToRun`,
      // and an answer carrying an id the client never minted is one
      // `writeStatus` could never match.
      final hold = request.hold ? _holds[request.key] : null;
      if (request.hold && request.value == 1) {
        final handle = await api.holdToRun(request.key);
        // **The re-check after the await.** This file's instance of the
        // pattern; `relay_session.dart`'s `_hello` carries the other one, and
        // the two are one idea.
        //
        // The refusal at :583 is synchronous and `write` has no `await` at all
        // in front of it, so *within one turn* it does guarantee this key
        // holds no live hold. What it cannot survive is the suspend on the
        // line above, and two things can happen during that suspend:
        //
        //  * **Another engage wins.** `json_rpc_2`'s `listen` does not await
        //    its dispatch (`server.dart:115`), and a JSON-RPC batch runs its
        //    members through `Future.wait` (`:175-181`), so a second engage
        //    can pass the guard while this one is upstream. Storing over the
        //    winner would leave its handle unreachable by `holdTick` (the
        //    `_holds` lookup is that frame's authorisation boundary), by the
        //    release branch below, and by `releaseAllHolds`.
        //  * **The session died.** `RelaySession._teardown:1471` calls
        //    `releaseAllHolds` synchronously, so this handler can resume into
        //    a map that has already been cleared for a socket that is gone.
        //    That one needs no second client at all.
        //
        // The loser's handle is **released, not dropped**. Dropping it is the
        // same strand wearing a different hat: a handle nobody holds a
        // reference to is a `1` placed on a deadman that nothing will ever
        // explicitly take back. Releasing writes the 0 and completes
        // `onReleased`, so the source stops counting it as live.
        final displaced = _holds[request.key];
        final String? lost = _closed
            ? 'this session was torn down while the engage was upstream'
            : (displaced != null && displaced.isHeld
                ? 'another engage on this key took the hold while this one '
                    'was upstream'
                : null);
        if (lost == null) {
          // Recorded only when it took. A refused engage produces an inert
          // handle (`hold_handle.dart`), and keeping one would make the next
          // tick look authorized for a hold that never existed.
          if (handle.isHeld) _holds[request.key] = handle;
          result = _withCmd(handle.engagement, request.cmd);
        } else {
          if (handle.isHeld) {
            // Not awaited, and errors swallowed, for `releaseAllHolds`'s
            // reasons exactly: the machine stops when the counter stops, which
            // has already happened here, and the source may be going away
            // underneath us.
            //
            // `HoldEnded.disposed` because that is what is happening to this
            // handle — the gateway is disposing of one it cannot make
            // reachable. `refused` would be a lie (the engage *did* come back
            // applied) and `operatorLetGo` names something nobody did.
            unawaited(handle
                .release(reason: HoldEnded.disposed)
                .then((_) {}, onError: (Object _) {}));
          }
          // Rejected, with the instant, because that is what happened: the
          // command reached the source and was taken back. It is recorded so
          // that `writeStatus` and a replay of this cmd both agree with the
          // refusal the client is about to receive.
          result = WriteRejected(
              request.cmd,
              WriteReason('hold_race_lost', message: lost),
              at: now());
          // **The same refusal shape the synchronous guard uses**, so a client
          // sees one answer for "one key, one hold" whichever side of the
          // await it lost on — and the message says the one thing that is
          // *not* the same. Everywhere else on this ladder `INVALID_PARAMS`
          // means "definitively no effect, nothing sent"; here the engage did
          // reach the plant and was taken back, so the tag went to 1 and
          // returned to 0. Saying so is the whole difference between a refusal
          // an operator can act on and one that is quietly wrong.
          lostTheRace = _refuse(
              Methods.write,
              'this engage was not the one that took the hold on '
              '"${request.key}": $lost. One key is one deadman counter — one '
              'finger, one button — and the handle this call was given has '
              'been released rather than kept, because a hold nothing can '
              'tick and nothing can release is a 1 left on a deadman by an '
              'engage nobody will ever take back. Unlike the refusals raised '
              'before the source is consulted, something *was* sent: the tag '
              'was taken to 1 and returned to 0 by that release, and this '
              'command is recorded as rejected. Read the tag back before '
              'acting, and engage again only once the live hold has been '
              'released');
        }
      } else if (hold != null && request.value == 0) {
        _holds.remove(request.key);
        result = _withCmd(await hold.release(), request.cmd);
      } else {
        // The client's cmd goes upstream, and the gateway does not mint one of
        // its own. It is not this process's action to identify: the id was
        // minted at the operator's keyboard (design §4.6) and everything that
        // will ever ask about this write — the `writeStatus` re-query after a
        // reconnect, the outcome log below, the plant's own count of how many
        // times the command reached the device — has to be keyed by that one
        // id or the three-state answer stops being attributable to anything.
        //
        // Minting here instead was a write-safety defect, not a cosmetic one:
        // the plant recorded the attempt under an id the client could never
        // name, so "how many times did my write reach the machine" had no
        // answer from either end, and `_withCmd` relabelling the outcome on
        // the way back made the loss invisible at exactly the point it
        // mattered.
        result = _withCmd(
            await api.write(request.key, request.value,
                expect: request.expect, cmd: request.cmd),
            request.cmd);
      }
    } catch (error) {
      // The source failed in a way it does not describe as an outcome. The
      // write may still have reached the device, so this is unknown — not an
      // RPC error, which would read as "definitely did not happen" and is
      // what makes an operator press the button a second time.
      result = WriteUnknown(
          request.cmd,
          WriteReason('gateway_lost_track',
              message: 'the gateway lost track of this write: $error'));
    }

    _record(request.cmd, result, fingerprint);
    // After the record, and outside the `catch`: see the declaration. The
    // rejected outcome is on the log before the client is told, so the two
    // never disagree about a command whose engage this gateway took and gave
    // straight back.
    if (lostTheRace != null) throw lostTheRace;
    return result.toJson();
  }

  /// Ends every hold this session engaged, because the session has ended.
  ///
  /// Called from `RelaySession._teardown`, so it runs for **every** way a
  /// session can end — a graceful close, a protocol refusal, the heartbeat
  /// reaper, a backpressure eviction, a yanked cable. A hold that outlived
  /// its socket would be a counter still advancing for a panel that went
  /// home, which is the one shape of this feature that could hurt somebody
  /// (T-05-20).
  ///
  /// The release writes are **not** awaited. The machine stops when the
  /// counter stops, which happens synchronously here; the release write's
  /// outcome is informational, and a teardown that waited for one would hang
  /// on exactly the dead link that caused it. Errors are swallowed for the
  /// same reason — the source may already be disposed underneath us.
  void releaseAllHolds() {
    // Set *before* the iteration, so a handler that resumes from
    // `api.holdToRun` at any point during or after this method sees it. The
    // iteration below is synchronous and cannot itself be interleaved with;
    // what can is the suspend in [write]'s hold branch, which is why the flag
    // is raised on the first line rather than the last.
    _closed = true;
    for (final hold in List<HoldHandle>.of(_holds.values)) {
      unawaited(hold
          .release(reason: HoldEnded.disposed)
          .then((_) {}, onError: (Object _) {}));
    }
    _holds.clear();
  }

  /// `writeStatus`: what became of these commands, as far as this gateway can
  /// honestly say.
  Future<Object?> writeStatus(rpc.Parameters params) async {
    final decoded = sanitize(params.asMap).value as Map;
    final raw = decoded['cmds'];
    if (raw is! List) {
      throw _refuse(Methods.writeStatus,
          'writeStatus needs a "cmds" list of the ids to re-query');
    }
    if (raw.isEmpty) {
      throw _refuse(Methods.writeStatus,
          'writeStatus needs at least one cmd: a re-query about nothing is a '
          'reconnect that learns nothing');
    }
    if (raw.length > config.maxKeysPerSubscribe) {
      throw _refuse(
          Methods.writeStatus,
          'writeStatus carried ${raw.length} cmds, over this server\'s limit '
          'of ${config.maxKeysPerSubscribe}');
    }

    outcomes.prune();
    return {
      'results': [
        for (final entry in raw) _statusOf('$entry').toJson(),
      ],
    };
  }

  /// The answer for one cmd, after the log has been pruned.
  WriteResult _statusOf(String cmd) {
    final held = outcomes.entryFor(cmd);
    if (held != null) return held.result;

    final mintedAt = ulidMs(cmd);
    if (mintedAt == null) {
      return WriteUnknown(
          cmd,
          const WriteReason('unrecognized_cmd',
              message: 'this is not an id this gateway could have issued an '
                  'outcome for, so nothing about it can be ruled out'));
    }
    if (!outcomes.witnessed(mintedAt)) {
      // Either minted before this log existed — which, on a gateway that has
      // restarted, is every command that crossed the outage — or minted in a
      // future this gateway's clock has not reached, which is a panel whose
      // clock runs ahead and which would otherwise have bought itself a
      // `not_received` window of `ttl + skew`. Neither is evidence. Forgetting
      // is not evidence of never happening, and neither is never having been
      // told.
      return WriteUnknown(
          cmd,
          const WriteReason('outcome_unwitnessed',
              message: 'this command was minted outside the window this '
                  'gateway can vouch for with its own clock — before it '
                  'started recording, or ahead of it. Nothing about it can be '
                  'ruled out; read the value back before acting'));
    }
    if (outcomes.insideWindow(mintedAt)) {
      // Inside the window, dated by a clock this gateway trusts, and nothing
      // was recorded: the command genuinely never arrived. The only re-send-
      // safe answer, and it is only safe because of the three checks above.
      return WriteNotReceived(cmd);
    }
    return WriteUnknown(
        cmd,
        WriteReason('outcome_expired',
            message: 'this command is older than the gateway\'s '
                '${config.writeOutcomeTtl.inSeconds} s memory. Forgetting is '
                'not evidence that it never happened — read the value back '
                'before acting'));
  }

  /// The one place an outcome enters the log.
  ///
  /// [fingerprint] is the write the outcome is about, and it is not optional
  /// here even though [WriteOutcomeLog.record] allows a null one: both callers
  /// are inside `write`, with the decoded and sanitized [WriteParams] in scope,
  /// and an entry recorded without a fingerprint would refuse every replay of
  /// itself.
  void _record(String cmd, WriteResult result, WriteFingerprint fingerprint) =>
      outcomes.record(cmd, result,
          ownerHint: ownerOf?.call(), fingerprint: fingerprint);

  /// The same outcome under the client's own [cmd].
  ///
  /// A **belt-and-braces** normalization since the client's cmd started going
  /// upstream: a source that honours the forwarded id already answers under it,
  /// and this is a no-op. It stays because `StateManApi.write`'s [cmd] is
  /// optional, so an implementation is free to ignore it and mint anyway, and
  /// an answer carrying an id the client never minted is an answer
  /// `writeStatus` could never match — the one failure the client cannot detect
  /// for itself.
  ///
  /// What it deliberately does *not* do is make ignoring the forwarded id
  /// harmless. The outcome is relabelled; the plant's own attempt count is not,
  /// and that discrepancy is what the contract's
  /// `exactly one upstream attempt per cmd` check reads.
  static WriteResult _withCmd(WriteResult result, String cmd) =>
      switch (result) {
        WriteApplied(:final readback, :final at) =>
          WriteApplied(cmd, readback: readback, at: at),
        WriteRejected(:final reason, :final at) =>
          WriteRejected(cmd, reason, at: at),
        WriteUnknown(:final reason) => WriteUnknown(cmd, reason),
        WriteNotReceived() => WriteNotReceived(cmd),
      };

  /// What this gateway says about a tag its source does not serve, in one
  /// place because four surfaces now have to say it identically.
  ///
  /// **One string, not four copies** (06-04). `read`, `readMany`, `readFresh`
  /// and `write` all answer for an unserved key, and 06-08's hiding rule turns
  /// "byte-identical to a nonexistent key" into a property a test asserts:
  /// a hidden key must be indistinguishable from one that never existed, or
  /// the refusal leaks the existence it is trying to conceal. Four
  /// hand-copied sentences cannot hold that, and the divergence between `read`
  /// and `readMany` that 04-REVIEW WR-11 fixed is what two copies already
  /// cost once.
  ///
  /// The wording names the two things it actually is, in the order they
  /// happen: a page config carries ~1500 hand-edited keys, so a typo is the
  /// usual cause; a tag renamed upstream is the one that arrives without
  /// anybody touching the page.
  static String _unknownKeyMessage(String key) =>
      'this source does not serve "$key" — usually a typo in a page config, '
      'occasionally a tag renamed upstream';

  /// The rejection itself, keyed by tag wherever it is used.
  static KeyReject _unknownKey(String key) =>
      KeyReject(KeyRejectKinds.unknownKey, message: _unknownKeyMessage(key));

  /// The whole read-shaped answer for an unserved tag.
  ///
  /// **Keyed by tag, exactly as `readMany` keys it** (04-REVIEW WR-11). `read`
  /// used to answer `'rejected': <one KeyReject>` while its neighbour answered
  /// `'rejected': {key: KeyReject}`, so a client written against either
  /// decoded the other wrongly — and the wrong decode is silent: a `kind` read
  /// off a map that has none comes back null, and the tag renders as merely
  /// quiet instead of as misconfigured.
  static Map<String, Object?> _unserved(String key) => {
        'key': key,
        'value': WireValue.of(null, quality: Quality.errorConfig).toJson(),
        'rejected': {key: _unknownKey(key).toJson()},
      };

  String _requireKey(Object? raw, String method) {
    if (raw is! String || raw.trim().isEmpty) {
      throw _refuse(method,
          '$method needs a non-empty "key": the tag being asked about');
    }
    return raw;
  }

  /// A refusal with the armor already on it.
  ///
  /// `data['request']` is pre-substituted because `RpcException.serialize`
  /// copies the offending request into `error.data` when it is not — and one
  /// request carrying `1e999` then makes the *error* unencodable, at which
  /// point the peer drops it and every caller without a deadline waits forever
  /// (STATE.md, the 02-05 hang).
  ///
  /// Spelled with the general constructor rather than
  /// `RpcException.invalidParams`, which takes no `data` — and a refusal with
  /// no `data` is exactly the one the serializer fills in for you.
  static rpc.RpcException _refuse(String method, String why) =>
      rpc.RpcException(rpc_errors.INVALID_PARAMS, why,
          data: _substitute(method));

  /// The write path's refusal for a tag this source does not serve.
  ///
  /// [_refuse]'s armor plus the same `rejected` map the read surfaces carry,
  /// keyed by tag, so one decoder on the client reads all four answers — and
  /// so 06-08 can make a hidden key produce this response byte for byte.
  static rpc.RpcException _refuseUnknownKey(String method, String key) =>
      rpc.RpcException(rpc_errors.INVALID_PARAMS, _unknownKeyMessage(key),
          data: {
            ..._substitute(method),
            'rejected': {key: _unknownKey(key).toJson()},
          });

  static Map<String, Object?> _substitute(String method) => {
        'method': method,
        'request': 'omitted: echoing a request that may carry a non-finite '
            'number is what makes the error itself unencodable, and an '
            'unencodable error on a path with no deadline is a hang',
      };

  /// A value on the wire. Null means "not known yet" — a distinct thing from a
  /// known-bad value, and the wire says which.
  static WireValue _wire(DynamicValue? value) {
    if (value == null) {
      return WireValue.of(null, quality: Quality.uncertainNotYetKnown);
    }
    return WireValue.of(
      value.toJson(slim: true),
      quality: value.quality,
      t: value.sourceTime?.millisecondsSinceEpoch,
    );
  }

  /// Crockford base32, the same alphabet `newUlid` encodes with.
}

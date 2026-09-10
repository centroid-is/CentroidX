/// The write half of the backend adapter: an operator's command, carried from
/// a connected client through main and down the pipe with its three-state
/// outcome intact.
///
/// This file exists because of one sentence in `CLAUDE.md`: *writes are applied
/// / rejected / explicitly unknown — never silently lost, never silently
/// re-sent*. Phase 12 built that guarantee across the isolate boundary
/// (`kPipeWriteDeadline` 5 s, worker death resolving unknown, no replay across
/// a respawn). This class carries it up to `StateManApi` without weakening it,
/// and adds the two things the pipe does not have:
///
///  * **an outcome log**, so `writeStatus` can answer a client that reconnected
///    after the link died with the write still in the air; and
///  * **the hold-to-run deadman** (`backend_hold.dart`), which is write-shaped
///    and rides the same discipline.
///
/// ## The rules, in the order they are enforced
///
///  1. **Nothing on any path sends a command a second time.** Not on a
///    deadline, not on a worker death, not on a respawn. A wrapper that did
///    would be invisible from the API surface — same call, same result type, a
///    few hundred milliseconds later — which is why
///    [BackendWrites.upstreamAttempts] exists and why the contract asserts a
///    number rather than a behaviour.
///  2. **The outcome is returned unchanged in kind.** Applied stays applied,
///    rejected stays rejected, unknown stays unknown. Nothing collapses unknown
///    into a failure, and no member of this class throws to report an outcome.
///  3. **A supplied `cmd` is passed through.** `StateManApi.write` mints the id
///    at the operator's keyboard *except* on a relay, and this adapter is a
///    relay: "a relay passes the id it was given, and does not mint". An
///    implementation in the middle that minted a second id would have created a
///    write it can no longer reconcile — the client's `writeStatus` would ask
///    about an id this side never recorded.
///  4. **Readback is the only confirmation.** An applied write stores what the
///    plant reported, never what the caller typed.
///  5. **`not_received` needs four pieces of positive evidence.** Anything
///    short of all four is `WriteUnknown`: "I have no record of it" and "it
///    never happened" are the same sentence to a lookup table and very
///    different sentences to a machine.
///  6. **A write that is really a read-modify-write is refused without a
///    compare-and-set.** See [readModifyWriteKeysOf] and the guard in [write].
///
/// ## The read-modify-write guard, and why it is here (P4a)
///
/// Rule 6 was measured missing on the rig
/// (`13-RIG-PROBE-EVIDENCE.md`, probe P4a): a blind write to `data.real.1` —
/// `MAIN.rData` element 0 — came back `{"outcome":"applied"}` from this class
/// where the standalone gateway refused it. It was **not** a whole-node
/// clobber; a sentinel write stayed element-scoped and the other nine elements
/// kept their own values. What was missing was the guard itself, and the reason
/// it exists is one sentence long: writing one element of an array reads the
/// whole array, replaces one slot and writes it all back
/// (`state_man.dart:2033-2039`, with the author's own "not sure I like this"
/// beside it), so a concurrent change to a *different* element between the two
/// crossings is silently overwritten. `guardArrayElementWrite`
/// (`write_translation.dart`) is the refusal both gateways already use, and it
/// is called here rather than re-worded, so the two cannot drift.
///
/// ## The pipe's `cmd` is not an operator action id
///
/// `PipeMainEndpoint.write` answers with a `WriteResult` whose `cmd` is a
/// per-worker integer sequence number — a transport correlation id. It restarts
/// with the isolate and two workers issue the same numbers, so it cannot be the
/// thing a client reconciles by. Every result crossing this class is therefore
/// re-stamped with the operator's own id. **Re-stamping is not minting**: no
/// second id is created, the one the operator's action already carries is put
/// back on an answer that lost it at a transport boundary.
///
/// ## The outcome log is shared, and no longer written here
///
/// This file used to carry its own `BackendWriteOutcomeLog`, re-stating the
/// evidence rules because `tfc_relay_server`'s `WriteOutcomeLog` was not on
/// that package's barrel and reaching past it would have tripped
/// `implementation_imports`. The two were byte-identical across nine members
/// and **neither said so** — the only undeclared copy in Phase 18's inventory.
///
/// Since 18-04 both are [relay.WriteOutcomeLog], in `tfc_relay_protocol`, which
/// is a package both sides already depend on. The evidence rules, and the
/// reason `tfc_relay_local` keeps a third and different log, are in that file's
/// library doc rather than restated here — a restatement is what drifted.
///
/// One shape changed in the move and it is the one worth knowing about: this
/// side's `fingerprint` was already required and non-nullable where the
/// server's was optional, and **this side's shape is the one that survived**.
///
/// The two logs still do **not** answer about the same command in the mounted
/// composition, and that is worth stating because it is not obvious:
/// `value_handlers.dart` answers a wire `writeStatus` entirely from the
/// gateway's own log and never delegates to `StateManApi.writeStatus`. So the
/// server's log answers clients; this one answers in-process callers and the
/// contract suite. See 13-10. Sharing the class did not merge the instances.
///
/// Protocol types are imported `as relay`, the house rule inside `tfc_dart`.
library;

import 'dart:async';

import 'package:logger/logger.dart';
import 'package:meta/meta.dart';
import 'package:tfc_dart/core/pipe_main_endpoint.dart';
import 'package:tfc_dart/core/relay/backend_hold.dart';
import 'package:tfc_dart/core/relay/backend_seams.dart';
import 'package:tfc_dart/core/state_man_types.dart' show KeyMappings;
import 'package:tfc_dart/core/write_translation.dart'
    show guardArrayElementWrite;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

/// Every key whose write is a **read-modify-write** rather than one crossing.
///
/// Two shapes, one hazard, and both of them are in this process:
///
///  * an OPC UA key mapped with an `array_index` — `state_man.dart:2033-2039`
///    reads the whole array, replaces one element and writes it back; and
///  * a key mapped with a `bit_mask` — `modbus_device_client.dart:1241-1264`
///    reads the current register, merges the masked bits and writes the whole
///    word back.
///
/// Neither pair of crossings is atomic, so a concurrent change between them is
/// lost without a word to anybody, and the thing it destroys is another
/// operator's setpoint. [BackendWrites] refuses both without an `expect`.
///
/// A pure function over the mappings rather than a member on anything, so the
/// composition root and every test derive the set the same way — a second
/// derivation is how the guard starts disagreeing with the router about which
/// keys it covers.
Set<String> readModifyWriteKeysOf(KeyMappings keyMappings) => <String>{
      for (final entry in keyMappings.nodes.entries)
        if (entry.value.opcuaNode?.arrayIndex != null ||
            entry.value.bitMask != null)
          entry.key,
    };

/// How long this source remembers what became of a write.
///
/// The same 60 s `ServerConfig.writeOutcomeTtl` defaults to, and for the same
/// argument: it is the boundary of a *safety* claim rather than of a
/// convenience. `not_received` — the one verdict that tells an operator a
/// second press is safe — may only be given for a command minted inside this
/// window, because outside it this side cannot tell "never arrived" from
/// "arrived, and forgotten". 60 s is the reconnect budget (backoff capped at
/// 30 s, so one full cycle plus a resync) with room to spare.
const Duration kBackendWriteOutcomeTtl = Duration(seconds: 60);

/// `BackendWriteSource` over [PipeMainEndpoint]. See the library doc.
final class BackendWrites implements BackendWriteSource {
  /// Composes the write half over an already-built pipe and value source.
  ///
  /// [now] is injectable epoch milliseconds so the TTL and the four evidence
  /// conditions can be aged by arithmetic rather than by a sleep —
  /// `RelayServer` does exactly this (`relay_server.dart:181-184`). It is
  /// deliberately the only injected clock: the write *deadline* belongs to the
  /// pipe and stays on the real one, because a source that never runs its own
  /// timeout passes every fake-clock case and hangs in the plant.
  ///
  /// [readModifyWriteKeys] is **required and has no default**, for
  /// `backend_seams.dart`'s rule about permissive defaults: an empty set means
  /// "no key on this deployment is a read-modify-write", which was the silent
  /// answer the rig measured, and a default would let a composition root lose
  /// the guard by forgetting an argument. Production derives it with
  /// [readModifyWriteKeysOf] from the same mappings the workers were
  /// registered with.
  BackendWrites({
    required PipeMainEndpoint pipe,
    required BackendValueSource values,
    required Set<String> readModifyWriteKeys,
    Duration outcomeTtl = kBackendWriteOutcomeTtl,
    int Function()? now,
    Logger? logger,
  })  : _pipe = pipe,
        _values = values,
        _readModifyWriteKeys = Set<String>.unmodifiable(readModifyWriteKeys),
        _now = now ?? _wallClock,
        _logger = logger ?? Logger(),
        _log = relay.WriteOutcomeLog(
            ttl: outcomeTtl, now: now ?? _wallClock) {
    _holds = BackendHoldRegistry(feed: _feedDeadman, logger: _logger);
  }

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  final PipeMainEndpoint _pipe;
  final BackendValueSource _values;

  /// The keys whose write is a read-modify-write. See [readModifyWriteKeysOf].
  final Set<String> _readModifyWriteKeys;
  final int Function() _now;
  final Logger _logger;
  final relay.WriteOutcomeLog _log;

  /// The live holds this source is keeping. See `backend_hold.dart`.
  late final BackendHoldRegistry _holds;

  /// How many times each command has been handed to the pipe.
  ///
  /// **An observable, never a wire member**, for `backend_seams.dart`'s reason
  /// about `roundTrips`: it exists so a contract case can assert that one
  /// operator action cost exactly one upstream attempt, and a count a connected
  /// client could query would be an access-control decision rather than a
  /// testing convenience. Bounded by the outcome log's own window — an entry
  /// pruned there drops its counter here.
  final Map<String, int> _attempts = <String, int>{};

  /// Every id this source minted, in the order it minted them.
  ///
  /// A passed-through id is deliberately absent: the list is what distinguishes
  /// the relay case from a coincidence.
  final List<String> _mintedCmds = <String>[];

  bool _disposed = false;

  /// How many times [cmd] has been handed to the pipe. Must be one, forever.
  @visibleForTesting
  int upstreamAttempts(String cmd) => _attempts[cmd] ?? 0;

  /// Every id this source minted, in order. Test observable.
  @visibleForTesting
  List<String> get mintedCmds => List<String>.unmodifiable(_mintedCmds);

  /// How many outcomes the log is holding. Test observable.
  @visibleForTesting
  int get recordedOutcomes {
    _log.prune();
    return _log.recordedOutcomes;
  }

  // ----------------------------------------------------------------- the write

  /// Sends [value] to [key] and reports what became of it.
  ///
  /// Deliberately **not** an `async` function. The body has to reach
  /// [PipeMainEndpoint.write] and [BackendValueSource.markPending]
  /// synchronously, so that a caller which drops the link on the very next line
  /// finds a pending record already in the pipe's table, and a widget watching
  /// the key sees the badge before the caller's next `await`. An `async` body
  /// with a guard clause above the send would move both behind a microtask.
  @override
  Future<relay.WriteResult> write(String key, Object? value,
      {Object? expect, String? cmd}) {
    // Both walks run before either refusal, so a non-finite buried in a nested
    // structure is caught too and not just a bare double.
    final sanitized = relay.sanitize(value);
    final sanitizedExpect = relay.sanitize(expect);

    // A shape refusal, and the first thing this method does: before an id is
    // minted, before the routing guard, before the compare-and-set and a long
    // way before the pipe. `value_handlers.write`'s rule for this path is that
    // "the only refusals here are shape refusals raised *before* the plant is
    // touched", and ahead of the mint is as early as "before" gets — an id that
    // exists is an action a `writeStatus` can no longer answer `not_received`
    // about, and `not_received` is the one verdict that makes a re-send safe.
    //
    // A throw and not a `WriteRejected`, and the difference matters here more
    // than anywhere: a `WriteRejected` is a machine's answer, and a machine
    // never saw this. A non-finite number cannot be encoded at all, so the
    // value that arrived is a defect in the caller — a divide-by-zero in a
    // rate calculation is the ordinary source — and it is the same
    // `ArgumentError` `RemoteStateMan._write`, `ChannelStateMan.write`,
    // `FakeStateMan.write` and `LocalStateMan.write` raise for it.
    //
    // This path used to sanitize the value, send the null, and carry a
    // `poisoned` flag through to `_applyOutcome` so the tag could be badged
    // `badNonFinite` afterwards. The badge was consolation for having already
    // actuated the device with a value nobody chose while answering
    // `WriteApplied` — and it was local to this client, so the plant kept the
    // null and every other screen read it as an ordinary number. Ruled
    // 2026-09-06.
    if (sanitized.hadNonFinite) {
      throw ArgumentError.value(
          value,
          'value',
          'a write cannot carry a non-finite number: it encodes to null, and '
              'a write of null actuates the device with a value nobody chose '
              'while the operator is told the write applied');
    }
    if (sanitizedExpect.hadNonFinite) {
      throw ArgumentError.value(
          expect,
          'expect',
          'a write cannot carry a non-finite compare-and-set guard: nulling '
              'it is this path\'s encoding of "no guard at all", so a guarded '
              'write would silently become an unconditional one');
    }

    final id = cmd ?? _mint();

    if (_disposed) {
      // Loud, not silent. A command accepted by a torn-down router is accepted
      // and dropped, and at the panel silence and success look the same.
      return Future<relay.WriteResult>.value(relay.WriteRejected(
        id,
        const relay.WriteReason('source_disposed',
            message: 'this write router has been torn down, so nothing was '
                'sent and nothing could have moved'),
        at: _now(),
      ));
    }

    // The fingerprint keeps the sanitized forms rather than the raw ones so
    // that an idempotent re-send compares equal to what was recorded the first
    // time.
    final fingerprint = (
      key: key,
      value: sanitized.value,
      expect: sanitizedExpect.value,
    );

    final held = _log.entryFor(id);
    if (held != null) {
      if (held.matches(fingerprint)) {
        // The same operator action, arriving again. One press of a jog button
        // is one movement of the machine, so the recorded outcome is replayed
        // and nothing crosses the pipe.
        return Future<relay.WriteResult>.value(held.result);
      }
      return Future<relay.WriteResult>.value(relay.WriteRejected(
        id,
        const relay.WriteReason('duplicate_cmd',
            message: 'this id has already been answered for a different '
                'write; one id covering two actuations would leave a single '
                'writeStatus answer for both, so nothing was sent'),
        at: _now(),
      ));
    }

    // P4a. Before the compare-and-set rather than beside it, because the two
    // answer different questions: this one asks "may this write happen at all
    // without a guard", the next asks "does the guard hold". Before the pipe
    // for the same reason the CAS is — a read-modify-write that is sent and
    // then judged has already overwritten whatever it raced.
    //
    // It is therefore also ahead of ROUTING, which the gateway's copy was not:
    // there the refusal lived in the OPC UA adapter, so an unroutable element
    // key answered `unrouted`. Here it answers `array_element_requires_expect`.
    // That is the same ordering the compare-and-set already has on this path
    // (rig probe P6's note), and the safer of the two: a key nothing claims is
    // still a key nobody should be writing blind.
    if (_readModifyWriteKeys.contains(key)) {
      final guard = guardArrayElementWrite(cmd: id, hasExpect: expect != null);
      if (guard is relay.WriteRejected) {
        // Re-stamped onto this source's clock — `guardArrayElementWrite` dates
        // its refusal from the wall, and every other outcome this class
        // records is dated by the injected one. Two clocks in one outcome log
        // is how a `not_received` window starts lying.
        final refusal = relay.WriteRejected(id, guard.reason, at: _now());
        _log.record(id, refusal, fingerprint: fingerprint);
        return Future<relay.WriteResult>.value(refusal);
      }
    }

    if (expect != null) {
      final current = _values.read(key);
      if (!relay.jsonEquals(current?.value, fingerprint.expect)) {
        // Compare-and-set exists so a concurrent change is NOT overwritten, so
        // the comparison happens BEFORE anything crosses the pipe. A write that
        // is sent and then judged has already overwritten it.
        final refusal = relay.WriteRejected(
          id,
          relay.WriteReason('compare_failed',
              message: 'the write was guarded on ${fingerprint.expect} and '
                  '"$key" holds ${current?.value}; nothing was sent'),
          at: _now(),
        );
        _log.record(id, refusal, fingerprint: fingerprint);
        return Future<relay.WriteResult>.value(refusal);
      }
    }

    // Recorded before the send, so a writeStatus arriving while this is in
    // flight answers unknown rather than "never received" about a command on
    // its way to a machine.
    _log.record(
      id,
      relay.WriteUnknown(
          id,
          const relay.WriteReason('in_flight',
              message: 'this command is upstream and has not been answered '
                  'yet; read the value back before acting')),
      fingerprint: fingerprint,
    );

    _attempts[id] = (_attempts[id] ?? 0) + 1;
    // The badge is a property of the value the widget is already watching, so
    // there is no second object for a call site to keep in sync.
    _values.markPending(key);

    final Future<relay.WriteResult> upstream;
    try {
      upstream = _pipe.write(
          key, relay.DynamicValue(value: sanitized.value));
    } catch (error, stack) {
      // The pipe promises not to throw here. If it ever does, the operator
      // still gets an outcome rather than an exception: the request may have
      // been built and sent before whatever failed.
      _logger.e('backend writes: the pipe threw on the way out for "$key"',
          error: error, stackTrace: stack);
      _values.clearPending(key);
      final lost = relay.WriteUnknown(
          id,
          const relay.WriteReason('write_path_failed',
              message: 'the write path failed on the way out; whether the '
                  'command reached the plant is not established'));
      _log.record(id, lost, fingerprint: fingerprint);
      return Future<relay.WriteResult>.value(lost);
    }

    return _settle(id, key, fingerprint, upstream);
  }

  /// Waits for the pipe's answer and applies it to the store.
  ///
  /// A `poisoned` flag used to be threaded through here from [write] and on
  /// into [_applyOutcome], so a write whose value had been sanitized to null
  /// could badge its tag `badNonFinite` once the outcome was back. [write] now
  /// refuses that value instead of sending it, so nothing can set the flag —
  /// and a parameter nothing can set is plumbing that reads as live policy.
  Future<relay.WriteResult> _settle(
    String cmd,
    String key,
    relay.WriteFingerprint fingerprint,
    Future<relay.WriteResult> upstream,
  ) async {
    var badgeHandled = false;
    try {
      final result = _restamp(cmd, await upstream);
      _applyOutcome(key, result);
      badgeHandled = true;
      _log.record(cmd, result, fingerprint: fingerprint);
      return result;
    } catch (error, stack) {
      _logger.e('backend writes: settling the write to "$key" failed',
          error: error, stackTrace: stack);
      final lost = relay.WriteUnknown(
          cmd,
          const relay.WriteReason('write_path_failed',
              message: 'the outcome could not be settled on this side; '
                  'whether the plant applied the command is not established'));
      _log.record(cmd, lost, fingerprint: fingerprint);
      return lost;
    } finally {
      // T-13-08-e. Whatever happened above, the badge does not outlive this
      // call: a value stuck pending is a permanent amber box the operator
      // learns to ignore, on the one key they most need to trust.
      if (!badgeHandled) _values.clearPending(key);
    }
  }

  /// Puts the operator's id back on an answer that lost it at the transport
  /// boundary. See the library doc — this is not a mint.
  relay.WriteResult _restamp(String cmd, relay.WriteResult raw) =>
      switch (raw) {
        relay.WriteApplied(readback: final readback, at: final at) =>
          relay.WriteApplied(cmd,
              readback: relay.sanitize(readback).value,
              at: at > 0 ? at : _now()),
        relay.WriteRejected(reason: final reason, at: final at) =>
          relay.WriteRejected(cmd, reason, at: at ?? _now()),
        relay.WriteUnknown(reason: final reason) =>
          relay.WriteUnknown(cmd, reason),
        // The pipe never mints this one, and a lower layer claiming it would be
        // claiming the single verdict that licenses a second actuation. Unknown
        // is the conservative default and stays the conservative default.
        relay.WriteNotReceived() => relay.WriteUnknown(
            cmd,
            const relay.WriteReason('unrecognized_outcome',
                message: 'the write path answered with a verdict this side '
                    'cannot vouch for; read the value back before acting')),
      };

  /// What the store is told, given an outcome.
  void _applyOutcome(String key, relay.WriteResult result) {
    switch (result) {
      case relay.WriteApplied(readback: final readback):
        if (readback == null) {
          // Applied, and nobody said what the device now holds. The OPC UA
          // write service answers `Good` with no value, so this is the ordinary
          // shape upstream. Readback is the only confirmation there is, so what
          // stays on the screen is the last reading anybody measured — badged
          // uncertain, until the subscription carries the new one.
          _values.clearPending(key);
          return;
        }
        // Deliberately no sourceTime: an identical readback must stay equal to
        // the cached reading, or the unchanged-value guard the whole k-of-n
        // rebuild property rests on stops working (`harness.dart:50-58`).
        _values.applyReadback(
            key,
            relay.DynamicValue(
                value: readback, quality: relay.Quality.good));
      case relay.WriteRejected():
      case relay.WriteUnknown():
      case relay.WriteNotReceived():
        _values.clearPending(key);
    }
  }

  String _mint() {
    final id = relay.newUlid();
    _mintedCmds.add(id);
    return id;
  }

  // ----------------------------------------------------------- the re-query

  /// Re-asks what became of [cmds], **positionally aligned** with the argument.
  ///
  /// Built by walking the input in order rather than by keying a map, because
  /// the alignment IS the protocol: a short or reordered list shifts every
  /// later verdict onto the wrong command, and one of those verdicts could be
  /// the `not_received` that invites a second actuation.
  @override
  Future<List<relay.WriteResult>> writeStatus(List<String> cmds) async {
    _log.prune();
    return <relay.WriteResult>[for (final cmd in cmds) _statusOf(cmd)];
  }

  /// The answer for one cmd, after the log has been pruned.
  ///
  /// Four pieces of positive evidence stand between a missing entry and
  /// [relay.WriteNotReceived], and each one that fails answers
  /// [relay.WriteUnknown] instead:
  ///
  ///  1. the id is datable at all — 26 Crockford characters this side could
  ///     have issued an outcome for;
  ///  2. it was minted after this source started recording;
  ///  3. it is not in the future, which is a panel whose clock runs ahead and
  ///     which would otherwise buy itself a window of `ttl + skew`; and
  ///  4. it is still inside the TTL.
  relay.WriteResult _statusOf(String cmd) {
    final held = _log.entryFor(cmd);
    if (held != null) return held.result;

    final mintedAt = relay.ulidMs(cmd);
    if (mintedAt == null) {
      return relay.WriteUnknown(
          cmd,
          const relay.WriteReason('unrecognized_cmd',
              message: 'this is not an id this source could have issued an '
                  'outcome for, so nothing about it can be ruled out'));
    }
    if (!_log.witnessed(mintedAt)) {
      return relay.WriteUnknown(
          cmd,
          const relay.WriteReason('outcome_unwitnessed',
              message: 'this command was minted outside the window this '
                  'source can vouch for with its own clock — before it '
                  'started recording, or ahead of it. Nothing about it can be '
                  'ruled out; read the value back before acting'));
    }
    if (_log.insideWindow(mintedAt)) {
      // Inside the window, dated by a clock this side trusts, and nothing was
      // recorded: the command genuinely never arrived. The only re-send-safe
      // answer, and it is only safe because of the three checks above.
      return relay.WriteNotReceived(cmd);
    }
    return relay.WriteUnknown(
        cmd,
        relay.WriteReason('outcome_expired',
            message: 'this command is older than this source\'s '
                '${_log.ttl.inSeconds} s memory. Forgetting is not evidence '
                'that it never happened — read the value back before acting'));
  }

  // ------------------------------------------------------------------- holds

  /// Engages the hold-to-run deadman on [key].
  ///
  /// The engage is a real write on this same path — same three states, same
  /// no-repeat rule, same outcome log — because 13-CONTEXT says in as many
  /// words that `holdToRun` is write-shaped and must not be silently
  /// unsupported. See `backend_hold.dart`.
  @override
  Future<relay.HoldHandle> holdToRun(String key) => _holds.engage(key);

  /// The registry, so an arm can engage a hold at a chosen counter.
  @visibleForTesting
  BackendHoldRegistry get holds => _holds;

  /// The one write a deadman counter travels on.
  ///
  /// A plain [write] with no `cmd` and no guard: every engage, tick and release
  /// is its own action with its own id, so the outcome log can be asked about
  /// the engage and the release independently. A guard would be wrong here for
  /// a reason worth stating — a compare-and-set on a counter the caller is
  /// itself advancing would refuse the tick after any dropped one, which is a
  /// deadman that stops feeding the moment the link hiccups.
  ///
  /// One consequence of the read-modify-write guard lands here and is meant to:
  /// a deadman counter mapped onto an array element or a bit field cannot be
  /// fed, because every tick would be a blind read-modify-write. The *engage*
  /// is refused first, so the handle comes back inert and the button never
  /// lights — which is the honest outcome for a hold nobody can be sure of.
  Future<relay.WriteResult> _feedDeadman(String key, int counter) =>
      write(key, counter);

  // ---------------------------------------------------------------- teardown

  /// Releases every live hold and stops taking commands.
  ///
  /// The release writes are **not** awaited: the machine stops when the counter
  /// stops, which happens synchronously inside `HoldHandle.release`, and a
  /// teardown that waited for a release to be confirmed would hang on exactly
  /// the dead link that caused it.
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    // Before the flag, because a release IS a write and a disposed router
    // refuses those.
    _holds.releaseAll();
    _disposed = true;
  }
}

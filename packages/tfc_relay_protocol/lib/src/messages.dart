/// Message parameter/result shapes. json_rpc_2 owns the envelope; these are
/// the `params`/`result` payloads only. Decoders read known keys and ignore
/// everything else (forward compatibility); encoders omit absent optionals.
library;

import 'quality.dart';
import 'sanitize.dart';
import 'wire_value.dart';

final class PeerInfo {
  final String name;
  final String version;
  const PeerInfo(this.name, this.version);

  factory PeerInfo.fromJson(Map<String, Object?> json) =>
      PeerInfo(json['name'] as String, json['version'] as String);

  Map<String, Object?> toJson() => {'name': name, 'version': version};
}

/// Client → server, first message on the socket. Server rejects every other
/// method until it has been accepted.
final class HelloParams {
  final String protocol;
  final List<String> supported;
  final PeerInfo client;
  final Map<String, Object?> capabilities;

  /// The station's credential, presented on the first frame. Null when the
  /// deployment runs no token file — every fixture in this workspace does.
  ///
  /// **Typed, and not an entry in [capabilities].** `capabilities` is an open
  /// map: the session logs it and copies it into its own record, so a
  /// credential put there is a credential in a log line, and no amount of care
  /// downstream takes it back out. A named field costs one key on the wire and
  /// buys three things — `toJson` can omit it by name from a diagnostic dump,
  /// a reviewer can see at the declaration that this is secret, and "does
  /// anything print the token?" becomes a grep for one identifier instead of
  /// an audit of every map that ever held it.
  ///
  /// It is a *station's* credential, not a person's: it says which panel is
  /// speaking, never who is standing at it.
  ///
  /// Omitted from [toJson] when null rather than emitted as `null`, so a
  /// tokenless hello is byte-identical to the frame this build sent before the
  /// field existed — which is what makes the field compatible in both
  /// directions with no version negotiation (see the library doc: decoders
  /// ignore unknown keys, encoders omit absent optionals).
  final String? token;

  const HelloParams({
    required this.protocol,
    required this.supported,
    required this.client,
    this.capabilities = const {},
    this.token,
  });

  factory HelloParams.fromJson(Map<String, Object?> json) => HelloParams(
        protocol: json['protocol'] as String,
        supported:
            (json['supported'] as List? ?? const []).cast<String>(),
        client: PeerInfo.fromJson((json['client'] as Map).cast()),
        capabilities:
            (json['capabilities'] as Map? ?? const {}).cast<String, Object?>(),
        token: json['token'] as String?,
      );

  Map<String, Object?> toJson() => {
        'protocol': protocol,
        'supported': supported,
        'client': client.toJson(),
        if (capabilities.isNotEmpty) 'capabilities': capabilities,
        if (token != null) 'token': token,
      };
}

/// The keys the gateway may put in [HelloResult.capabilities].
///
/// **Named here so both ends spell them once.** `capabilities` is an open map
/// on purpose (04-RESEARCH A4) — every key is additive and no deployed client
/// has to know about it — but "open" is not the same as "anonymous". A string
/// literal typed out on the gateway and again on the panel is a key that a
/// typo silently disables: the client reads `null`, falls back on its default,
/// and nothing anywhere reports that the negotiation did not happen. Both keys
/// below are read by exactly one caller each and the constant is what makes
/// that a compile-time fact rather than a grep.
///
/// Adding a key here is not a protocol version bump. Decoders ignore unknown
/// keys and encoders omit absent optionals (see the library doc), so a gateway
/// that predates a key and a panel that ignores one are both still correct.
abstract final class HelloCapabilities {
  /// The gateway's fan-out cadence in milliseconds — how often it re-evaluates
  /// a subscription. Read by `FreshnessWatchdog` for the *per-subscription*
  /// staleness limit and by nothing else (04-REVIEW WR-06).
  static const String tickMs = 'tickMs';

  /// How long the gateway lets a session go silent before its reaper closes it
  /// with `4003 heartbeatTimeout`, in milliseconds.
  ///
  /// **This is the panel's own survival number.** Nothing the gateway sends
  /// keeps a session alive; only inbound application frames do
  /// (`relay_session.dart`'s `_lastSeen`). A panel that is merely watching a
  /// page sends nothing at all, so without an app heartbeat it is reaped one
  /// deadline after its handshake, for ever, at the cost of a full page resync
  /// per cycle — measured on this build in 07-08-SUMMARY deviation 3 before
  /// the pump existed.
  ///
  /// The panel derives its heartbeat period from this rather than carrying a
  /// constant, for the same reason [tickMs] exists: a client number that has
  /// to match a server config nobody diffs is a mismatch that surfaces a year
  /// later, and here it surfaces as every screen in the factory redialling.
  static const String heartbeatDeadlineMs = 'heartbeatDeadlineMs';

  /// The username of the account the gateway verified this session as — the
  /// token file's account on a station hello, absent entirely on a
  /// credential-less (awaiting-sign-in) one and on a gateway too old to
  /// send it.
  ///
  /// **Advisory display material, exactly as [HelloResult.publisherId] is:**
  /// nothing routes on it, nothing is authorised by it, and the panel's only
  /// legitimate use is prose — "saves are recorded against …" naming the
  /// account instead of a machine id nobody can read. The server attributes
  /// every relayed operation to the identity it verified whether or not the
  /// panel ever reads this key. It exists because the verified username was
  /// otherwise unknowable client-side, and the panel's own hostname — the
  /// thing screens used to print in its place — is a fact about the machine,
  /// not about the account (the rig rendered a bare container id).
  static const String account = 'account';
}

final class HelloResult {
  final String protocol;
  final PeerInfo server;
  final Map<String, Object?> capabilities;
  final String sessionId;
  final String epoch;

  // --- where `resumed` used to be (withdrawn in 16-11, HARD-03) ------------
  //
  // A protocol reader looking for the missing field will look here, so the
  // answer lives here rather than only in a plan.
  //
  // `session.resumed` said "your cache survived; resubscribe nothing", and
  // alongside it `HelloParams.session` (a `SessionResume` carrying a previous
  // session id, an epoch and a per-subscription `lastSeq`) said "here is where
  // I left off". Neither was ever honoured: no client in this workspace set
  // the request field, the server decoded it and read nothing, and the answer
  // was hardcoded `false` for eleven phases behind a comment promising it
  // would mean something in a phase that had already come and gone.
  //
  // **Withdrawn rather than implemented, and that is the decision.** Honouring
  // a resume means the gateway retaining per-session subscription state across
  // a socket loss and replaying from `lastSeq` — delta replay. This product's
  // doctrine, in CLAUDE.md's own words, is "resync = snapshot, never delta
  // replay". Implementing the field would have been implementing the one thing
  // the architecture refuses, and leaving it standing was worse than either:
  // a field that promises fault tolerance it does not have is what the next
  // milestone builds on. The reasoning is written out in
  // `.planning/phases/16-transport-hardening/16-CONTEXT.md`.
  //
  // If a future milestone wants resume, it starts from that doctrine question
  // — what may be replayed, and how a resumed session is bound to the
  // credential that owns it, since the request field was an unauthenticated
  // claim about a prior session — and not from re-declaring these fields.
  //
  // **Decoding stays tolerant in both directions.** `fromJson` ignores a
  // `resumed` key that is still present (a gateway from before this change) as
  // it ignores any unknown key, and no longer requires one. What it cannot fix
  // is the third direction: a *decoder* from before this change reads
  // `session['resumed'] as bool` and throws on the frame this build now emits.
  // Nothing in this package can reach that binary. It is survivable only
  // because gateway and panels ship together this milestone.

  /// Server wall clock at handshake (UTC epoch ms) — the client derives its
  /// clock offset from this so staleness is measured against one clock.
  final int serverTime;

  /// A stable name for the *gateway process*, from server config. Null when
  /// the deployment configured none. 08-13 wires the config; nothing in this
  /// package produces it.
  ///
  /// **What it buys.** A capture taken on a LAN carrying a bench gateway and
  /// the plant gateway shows two handshakes that are otherwise identical in
  /// every field an engineer would read — same protocol, same server name and
  /// version, differing only in a session id neither machine chose. This names
  /// which process answered, so "ST201 disconnected" can be attributed without
  /// correlating source ports against a topology nobody wrote down. The
  /// Sparkplug `publisherId` adoption (07-RESEARCH-PUBSUB); the plant's own
  /// `@conn` catalogue reached for the same thing under other names.
  ///
  /// **Advisory, and a client must not treat it as identity.** Nothing routes
  /// on it, nothing is authorised by it, and it is set by whoever wrote the
  /// gateway's config file — which makes it a label, not a claim. Identity is
  /// the Phase 6 token, checked by the policy decorator; a client that granted
  /// anything on the strength of this string would be trusting a value the
  /// wire hands it for free.
  ///
  /// It sits at the **top level** of [toJson], beside `protocol`, rather than
  /// inside `session` or `clock`: it identifies the process, which outlives
  /// every session it serves.
  ///
  /// Omitted from [toJson] when null rather than emitted as `null` — the
  /// [HelloParams.token] idiom and the library rule, which is what makes the
  /// field compatible in both directions with no version negotiation.
  final String? publisherId;

  const HelloResult({
    required this.protocol,
    required this.server,
    this.capabilities = const {},
    required this.sessionId,
    required this.epoch,
    required this.serverTime,
    this.publisherId,
  });

  factory HelloResult.fromJson(Map<String, Object?> json) {
    final session = (json['session'] as Map).cast<String, Object?>();
    final clock = (json['clock'] as Map).cast<String, Object?>();
    return HelloResult(
      protocol: json['protocol'] as String,
      server: PeerInfo.fromJson((json['server'] as Map).cast()),
      capabilities:
          (json['capabilities'] as Map? ?? const {}).cast<String, Object?>(),
      sessionId: session['id'] as String,
      epoch: session['epoch'] as String,
      // No `resumed` read. A frame that still carries the key is decoded and
      // the key ignored, which is this library's general rule rather than a
      // special case; see the block where the field was declared.
      serverTime: (clock['serverTime'] as num).toInt(),
      publisherId: json['publisherId'] as String?,
    );
  }

  Map<String, Object?> toJson() => {
        'protocol': protocol,
        'server': server.toJson(),
        if (capabilities.isNotEmpty) 'capabilities': capabilities,
        // The `session` object stays, and only the withdrawn key leaves it.
        // `epoch` is the whole epoch-change re-establishment mechanism — the
        // client feeds it straight to `ResyncEngine.onHello` — and `id` is what
        // server-side attribution is written against. A withdrawal that took
        // the object whole would break every reconnection in the plant while
        // looking like the same deletion.
        'session': {'id': sessionId, 'epoch': epoch},
        'clock': {'serverTime': serverTime},
        if (publisherId != null) 'publisherId': publisherId,
      };

  /// [HelloCapabilities.heartbeatDeadlineMs], or null when this gateway
  /// advertised nothing usable.
  ///
  /// **A reader rather than a field, because the source is an open map.**
  /// Whatever is under the key came off a wire: it may be a string, a negative
  /// number, or `1e999` decoded to `Infinity` (`sanitize.dart` defuses the
  /// last of those on the value path, not inside a capabilities map). Each of
  /// those has to mean "this gateway told me nothing", so the caller falls
  /// back on its own configured floor instead of dividing garbage by three and
  /// either spinning at 0 ms or never beating at all.
  ///
  /// The tolerance rule is `FreshnessWatchdog.learnedTickMs`'s, restated
  /// rather than shared because that class lives in the client package and
  /// this one may not depend on it: finite, positive, and truncated to an int
  /// so a gateway written in a language with one number type can send 6000.0.
  int? get heartbeatDeadlineMs =>
      _positiveInt(capabilities[HelloCapabilities.heartbeatDeadlineMs]);

  static int? _positiveInt(Object? advertised) =>
      advertised is num && advertised.isFinite && advertised > 0
          ? advertised.toInt()
          : null;
}

final class SubscribeParams {
  final String sub;
  final List<String> keys;
  final double? maxRateHz;
  const SubscribeParams(
      {required this.sub, required this.keys, this.maxRateHz});

  factory SubscribeParams.fromJson(Map<String, Object?> json) =>
      SubscribeParams(
        sub: json['sub'] as String,
        keys: (json['keys'] as List).cast<String>(),
        maxRateHz: (json['maxRateHz'] as num?)?.toDouble(),
      );

  Map<String, Object?> toJson() => {
        'sub': sub,
        'keys': keys,
        if (maxRateHz != null) 'maxRateHz': maxRateHz,
      };
}

final class KeyReject {
  final String kind;
  final String? message;
  const KeyReject(this.kind, {this.message});

  factory KeyReject.fromJson(Map<String, Object?> json) =>
      KeyReject(json['kind'] as String, message: json['message'] as String?);

  Map<String, Object?> toJson() =>
      {'kind': kind, if (message != null) 'message': message};
}

final class SubscribeResult {
  final String sub;
  final String epoch;
  final int seq;

  /// Which establishment of this `sub` the answer belongs to, minted by the
  /// gateway and bumped every time the name is (re-)established.
  ///
  /// **The epoch is not enough, and neither is a client-side connection
  /// counter** (04-REVIEW CR-04). Both change per *session*, and the frame that
  /// poisons a cache is the one still in flight from before a resync on the
  /// **same socket** — a server-announced resync or a gap-triggered
  /// resubscribe rebuilds one subscription while the session epoch stays put.
  /// The stale frame is then applied as an in-sequence batch and takes the
  /// baseline, after which the genuine frame at the same `seq` is discarded as
  /// a replay: the mimic shows the old number, under good quality, and the new
  /// one is gone. One integer per subscription covers that case and the
  /// cross-reconnect case with one mechanism.
  final int generation;

  /// key → integer handle used in every subsequent push.
  final Map<String, int> handles;

  /// handle → full metadata (typeId/displayName/enums…), sent once here.
  final Map<int, Object?> meta;

  /// handle → current value. Atomic with `seq`: the explicit
  /// "initial state complete" every surveyed protocol needed.
  final Map<int, WireValue> snapshot;

  /// Per-key failures — one bad key never blanks a page.
  final Map<String, KeyReject> rejected;

  const SubscribeResult({
    required this.sub,
    required this.epoch,
    required this.seq,
    required this.handles,
    this.meta = const {},
    required this.snapshot,
    this.rejected = const {},
    this.generation = 0,
  });

  factory SubscribeResult.fromJson(Map<String, Object?> json) =>
      SubscribeResult(
        sub: json['sub'] as String,
        epoch: json['epoch'] as String,
        seq: (json['seq'] as num).toInt(),
        // Absent from a gateway that predates the generation: zero, which is
        // the same value every frame from such a gateway carries, so the
        // client's comparison passes rather than dropping everything.
        generation: (json['generation'] as num?)?.toInt() ?? 0,
        handles: (json['handles'] as Map? ?? const {}).cast<String, int>(),
        meta: _intKeyed(json['meta'], (v) => v),
        snapshot: _intKeyed(json['snapshot'],
            (v) => WireValue.fromJson((v as Map).cast())),
        rejected: (json['rejected'] as Map? ?? const {})
            .cast<String, Object?>()
            .map((k, v) =>
                MapEntry(k, KeyReject.fromJson((v as Map).cast()))),
      );

  Map<String, Object?> toJson() => {
        'sub': sub,
        'epoch': epoch,
        'seq': seq,
        'generation': generation,
        'handles': handles,
        if (meta.isNotEmpty) 'meta': _stringKeyed(meta, (v) => v),
        'snapshot': _stringKeyed(snapshot, (v) => v.toJson()),
        if (rejected.isNotEmpty)
          'rejected': rejected.map((k, v) => MapEntry(k, v.toJson())),
      };
}

/// The hot-path notification (`u`). Single-character field names here and
/// only here.
final class UpdateParams {
  final String sub;

  /// Per-subscription, increments by one per message. A gap ⇒ resync.
  final int seq;

  /// Which establishment of [sub] this frame belongs to — `g` on the wire,
  /// one character, because this is the hot path.
  ///
  /// A frame carrying any other generation than the one the client's last
  /// snapshot came with is from before that snapshot, and applying it puts a
  /// reading from a subscription that no longer exists onto a mimic under good
  /// quality. See [SubscribeResult.generation] for why the epoch cannot do
  /// this job.
  final int generation;

  /// Batch timestamp (UTC epoch ms) applying to values without their own.
  final int t;

  /// handle → changed value (slim).
  final Map<int, WireValue> changes;

  /// handle → quality-only transition.
  final Map<int, Quality> qualities;

  /// handles no longer available.
  final List<int> removed;

  const UpdateParams({
    required this.sub,
    required this.seq,
    required this.t,
    this.generation = 0,
    this.changes = const {},
    this.qualities = const {},
    this.removed = const [],
  });

  factory UpdateParams.fromJson(Map<String, Object?> json) => UpdateParams(
        sub: json['sub'] as String,
        seq: (json['seq'] as num).toInt(),
        t: (json['t'] as num).toInt(),
        generation: (json['g'] as num?)?.toInt() ?? 0,
        changes: _intKeyed(
            json['c'], (v) => WireValue.fromJson((v as Map).cast())),
        qualities: _intKeyed(json['q'], Quality.fromWire),
        removed: (json['r'] as List? ?? const []).cast<int>(),
      );

  Map<String, Object?> toJson() => {
        'sub': sub,
        'seq': seq,
        't': t,
        'g': generation,
        if (changes.isNotEmpty)
          'c': _stringKeyed(changes, (v) => v.toJson()),
        if (qualities.isNotEmpty)
          'q': _stringKeyed(qualities, (v) => v.code),
        if (removed.isNotEmpty) 'r': removed,
      };
}

/// Per-subscription heartbeat state inside a [TickParams]: proves the
/// subscription itself is alive, not just the socket (the
/// dead-subscription-on-live-connection failure).
final class SubTick {
  final int seq;
  final int evaluatedAt;
  const SubTick({required this.seq, required this.evaluatedAt});

  factory SubTick.fromJson(Map<String, Object?> json) => SubTick(
        seq: (json['seq'] as num).toInt(),
        evaluatedAt: (json['evaluatedAt'] as num).toInt(),
      );

  Map<String, Object?> toJson() => {'seq': seq, 'evaluatedAt': evaluatedAt};
}

/// Client → server on the app heartbeat: the one frame that says *how far the
/// panel has actually got*.
///
/// ## Why it rides `ping`
///
/// `poll` can measure how much this gateway has **produced** for a client and
/// nothing else — `dart:io` exposes no `bufferedAmount` and no `flush`
/// (flutter#103306), so nine megabytes can pile into an unread socket while
/// every `addStream` returns in 0 ms. `16-02-DECISION.md` measured that
/// directly, refuted the `sink.done` liveness option the source had been
/// recommending since Phase 3, and chose an application-level ack instead:
/// **the only party that knows what was delivered is the party that read it.**
///
/// It rides `ping` rather than a frame of its own because `ping` already
/// exists and already crosses on exactly the cadence this question needs
/// asking on (§7). At a realistic four subscriptions it is 134 bytes and
/// 544 ns per panel per beat, against a 389 µs per-tick fan-out — and it is
/// client→server, so it is not on the encode-once path at all (§2.6).
///
/// ## It is a claim by the party being judged
///
/// Nothing here is verified, and nothing here is meant to be. The trust
/// boundary is one line in `ConflatingSendBuffer.recordAck`, which clamps the
/// reported sequence to what was actually sent: over-reporting therefore buys
/// a stuck client nothing, and under-reporting is left alone on purpose,
/// because a client that evicts itself is harmless and pays one snapshot for
/// it. This class must not grow a second opinion about that.
///
/// ## Every malformation degrades; none of them throws
///
/// A `ping` is what stops the reaper. A decode that threw here would turn a
/// panel with a cosmetic bug in its ack into a panel that is disconnected
/// every heartbeat — trading a diagnostic for an outage. So an absent
/// `params`, an absent `ack`, an `ack` that is not a map, and a sequence that
/// is not an `int` each degrade to *no ack for that subscription*, which is
/// the same thing the gateway hears from a panel too old to send one, and
/// which it already knows how to answer (`send_buffer.dart`: a null
/// `ackedSeq` is skipped by the verdict).
final class PingParams {
  /// Subscription name → the highest sequence the client has **applied**.
  ///
  /// Applied, not received: the number a panel may honestly put here is the
  /// one it has decoded into its own state, because that is the number the
  /// gateway is trying to learn. On the client this is
  /// `SubscriptionState.lastSeq` and it is read rather than counted, so the
  /// pump learns nothing the supervisor did not already know.
  final Map<String, int> ack;

  const PingParams({this.ack = const {}});

  /// **Tolerant by contract, one entry at a time.**
  ///
  /// Bad entries are dropped individually rather than poisoning the frame: a
  /// panel that mangles one subscription's sequence must not blind the gateway
  /// to the four beside it.
  ///
  /// **`int` and not `num`, deliberately.** A sequence is minted as an `int`,
  /// so a fractional or non-finite value is not a rounding question but a peer
  /// that is not speaking this protocol. It also defuses the `1e999` decode
  /// poison here by construction: `jsonDecode` yields `double.infinity`
  /// silently, `Infinity.toInt()` throws, and — worse than either — an
  /// Infinity that got as far as `recordAck` would be *clamped to `sentSeq`*
  /// and read as a client claiming to be perfectly caught up. Dropping it is
  /// the only answer that cannot be turned into an ack the client never sent.
  factory PingParams.fromJson(Map<String, Object?> json) {
    final raw = json['ack'];
    if (raw is! Map) return const PingParams();
    final ack = <String, int>{};
    for (final entry in raw.entries) {
      final sub = entry.key;
      final seq = entry.value;
      if (sub is String && seq is int) ack[sub] = seq;
    }
    return PingParams(ack: ack);
  }

  /// Omits `ack` when there is nothing to say, so a panel holding no
  /// subscriptions beats with the same 47-byte frame it always did.
  Map<String, Object?> toJson() => {if (ack.isNotEmpty) 'ack': ack};
}

/// Server → client on a fixed cadence even when nothing changed: silence is
/// never ambiguous (OPC UA keep-alive rule; client death deadline = 3×).
final class TickParams {
  final int serverTime;
  final Map<String, SubTick> subs;
  const TickParams({required this.serverTime, this.subs = const {}});

  factory TickParams.fromJson(Map<String, Object?> json) => TickParams(
        serverTime: (json['serverTime'] as num).toInt(),
        subs: (json['subs'] as Map? ?? const {})
            .cast<String, Object?>()
            .map((k, v) => MapEntry(k, SubTick.fromJson((v as Map).cast()))),
      );

  Map<String, Object?> toJson() => {
        'serverTime': serverTime,
        if (subs.isNotEmpty)
          'subs': subs.map((k, v) => MapEntry(k, v.toJson())),
      };
}

final class ResyncParams {
  final String sub;
  final String epoch;

  /// `epoch_changed` | `server_restart` | `overrun` |
  /// `permissions_changed` | `gateway_stalled` | `plc_reprogrammed`
  final String reason;

  /// For `gateway_stalled`: how long the event loop was frozen.
  final int? stalledMs;

  const ResyncParams(
      {required this.sub,
      required this.epoch,
      required this.reason,
      this.stalledMs});

  factory ResyncParams.fromJson(Map<String, Object?> json) => ResyncParams(
        sub: json['sub'] as String,
        epoch: json['epoch'] as String,
        reason: json['reason'] as String,
        stalledMs: (json['stalledMs'] as num?)?.toInt(),
      );

  Map<String, Object?> toJson() => {
        'sub': sub,
        'epoch': epoch,
        'reason': reason,
        if (stalledMs != null) 'stalledMs': stalledMs,
      };
}

/// Per-upstream link state — its own channel, never smuggled inside tag
/// values. Also feeds the `PIPE.upstream.<alias>.*` keys and alarm
/// master-inhibit.
final class StatusParams {
  final String alias;

  /// `connected` | `connecting` | `disconnected` | `unhealthy` |
  /// `reprogrammed`
  final String state;
  final String? error;

  /// A stable name for the *gateway process* that observed this link, from
  /// server config. Null when the deployment configured none. 08-12 emits it;
  /// nothing in this package produces it.
  ///
  /// **Why status carries it too.** This is a notification: it arrives with no
  /// request to correlate it against, so unlike every result shape there is
  /// nothing in the exchange that says who sent it. On a LAN where a bench rig
  /// and the plant gateway both watch an alias spelled `ST201`, a captured
  /// "ST201 went disconnected" has two readings — the rig lost its fake PLC,
  /// or the plant lost a real one — and they are not close to each other.
  ///
  /// **Advisory, exactly as on [HelloResult.publisherId]:** nothing routes on
  /// it and a client must not treat it as identity. Identity is the Phase 6
  /// token.
  ///
  /// Omitted from [toJson] when null (the library rule), so the frame a
  /// gateway with no configured name sends is byte-for-byte the frame this
  /// build sent before the field existed.
  final String? publisherId;

  const StatusParams({
    required this.alias,
    required this.state,
    this.error,
    this.publisherId,
  });

  factory StatusParams.fromJson(Map<String, Object?> json) => StatusParams(
        alias: json['alias'] as String,
        state: json['state'] as String,
        error: json['error'] as String?,
        publisherId: json['publisherId'] as String?,
      );

  Map<String, Object?> toJson() => {
        'alias': alias,
        'state': state,
        if (error != null) 'error': error,
        if (publisherId != null) 'publisherId': publisherId,
      };
}

final class WriteParams {
  /// Client-minted ULID, created when the operator acts — a re-send reuses
  /// it (idempotency key; server dedups within [ttlMs]).
  final String cmd;
  final String key;
  final Object? value;

  /// Optional compare-and-set guard: apply only if the current value
  /// matches.
  final Object? expect;
  final int? ttlMs;

  /// Marks this write as the engage or the release of a hold-to-run deadman
  /// (D-P5-C).
  ///
  /// Engage and release are ordinary writes — that is what buys them a
  /// three-state outcome, an entry in the outcome log, and `writeStatus`
  /// reconciliation across a reconnect with no new code. This flag is the one
  /// bit the gateway needs to tell an engage from any other write to the same
  /// tag, so that it can take a [HoldHandle] and accept ticks for it. A hold
  /// write carrying anything but 1 or 0 is refused before the plant is
  /// touched.
  ///
  /// It lives here, on the wire DTO, and **not** on `StateManApi.write`: the
  /// interface already has `holdToRun`, and a second way to say the same
  /// thing on the same interface is the ambiguity the surface test exists to
  /// prevent.
  final bool hold;

  /// Refuses a non-finite [value] or [expect] rather than sanitizing it.
  ///
  /// Sanitizing is right for telemetry, where the alternative is a frame that
  /// fails for every client. On the write path the value is an operator's
  /// intent and the two losses are both silent: a non-finite [value] would
  /// become a write of `null`, actuating the device with something nobody
  /// chose, and a non-finite [expect] would become `null`, which is this
  /// class's encoding of "no compare-and-set guard" — turning a guarded write
  /// into an unconditional one. Nothing upstream of a write box can
  /// legitimately produce a NaN, so this is programmer error, and throwing is
  /// the one thing the write path is allowed to do about it.
  factory WriteParams(
      {required String cmd,
      required String key,
      required Object? value,
      Object? expect,
      int? ttlMs,
      bool hold = false}) {
    final v = sanitize(value);
    final e = sanitize(expect);
    if (v.hadNonFinite || e.hadNonFinite) {
      throw ArgumentError.value(
          v.hadNonFinite ? value : expect,
          v.hadNonFinite ? 'value' : 'expect',
          'a write cannot carry a non-finite number: nulling it would actuate '
              'the device with a value the operator did not choose, and '
              'nulling an expect would turn a guarded write into an '
              'unconditional one');
    }
    return WriteParams._(cmd, key, v.value, e.value, ttlMs, hold);
  }

  const WriteParams._(
      this.cmd, this.key, this.value, this.expect, this.ttlMs, this.hold);

  factory WriteParams.fromJson(Map<String, Object?> json) {
    final hold = json['hold'];
    if (hold != null && hold is! bool) {
      // Not coerced: a truthy string would turn an ordinary write into a hold
      // engage, and a falsy one would turn an engage into a write the gateway
      // takes no handle for — a machine that jogs with nothing feeding it.
      throw FormatException('write params carry a non-boolean hold flag: '
          '$hold');
    }
    try {
      return WriteParams(
        cmd: json['cmd'] as String,
        key: json['key'] as String,
        value: json['value'],
        expect: json['expect'],
        ttlMs: (json['ttlMs'] as num?)?.toInt(),
        hold: hold as bool? ?? false,
      );
    } on ArgumentError catch (e) {
      // `1e999` decodes silently to Infinity, so a peer can reach the refusal
      // above. From here it is a malformed frame rather than local programmer
      // error — the write is refused either way, which is the point.
      throw FormatException('write params carry a non-finite number: '
          '${e.name} = ${e.invalidValue}');
    }
  }

  Map<String, Object?> toJson() => {
        'cmd': cmd,
        'key': key,
        'value': value,
        if (expect != null) 'expect': expect,
        if (ttlMs != null) 'ttlMs': ttlMs,
        if (hold) 'hold': hold,
      };
}

/// One operator acknowledging one active alarm.
///
/// Sent as a request under [Methods.ackAlarm] — see that constant for why an
/// acknowledge is an RPC when the active set is a value key, why it carries no
/// `cmd`, and why its answer is not the operator's confirmation.
///
/// **The identity is D-4's, and there is deliberately no third field.**
/// `(alarm_uid, rule_index)` is the key of the partial unique index D-5 adds
/// to `alarm_history` — `WHERE deactivated_at IS NULL` — so the open row is
/// unique by construction and the engine resolves it from these two values
/// alone. A `historyId` beside them would be a *second* identity scheme for
/// the same row, and two identities for one row can disagree: the frame would
/// still read as valid and would acknowledge the wrong alarm. One identity, and
/// the wire cannot express the disagreement.
final class AckAlarmParams {
  /// The alarm instance's uid, from D-4's `alarm_history.alarm_uid`.
  final String alarmUid;

  /// Which rule of that alarm fired, from D-4's `alarm_history.rule_index`.
  ///
  /// A position in a list, so a negative one names no rule and is refused at
  /// both doors below.
  final int ruleIndex;

  /// Refuses a frame that identifies nothing, in [HoldTickParams]' style and
  /// for its reason: the alternative is a frame that reads as valid and
  /// acknowledges whatever row happens to sort first.
  factory AckAlarmParams({required String alarmUid, required int ruleIndex}) {
    if (alarmUid.isEmpty) {
      throw ArgumentError.value(alarmUid, 'alarmUid',
          'an acknowledge must name the alarm instance it acknowledges');
    }
    if (ruleIndex < 0) {
      throw ArgumentError.value(ruleIndex, 'ruleIndex',
          'a rule index is a position in a list; a negative one names no rule');
    }
    return AckAlarmParams._(alarmUid, ruleIndex);
  }

  const AckAlarmParams._(this.alarmUid, this.ruleIndex);

  /// Refuses a missing or empty uid, a non-numeric index, a fractional one, a
  /// non-finite one and a negative one, all as a [FormatException].
  ///
  /// The non-finite arm is [HoldTickParams.fromJson]'s and is not theoretical:
  /// `1e999` decodes to `Infinity` without complaint, and `Infinity.toInt()`
  /// throws an `UnsupportedError` that nothing at this boundary is catching.
  ///
  /// An unknown extra field is **ignored**, not refused — forward
  /// compatibility runs both ways, and a newer client adding a field must not
  /// make an older gateway refuse the acknowledge.
  factory AckAlarmParams.fromJson(Map<String, Object?> json) {
    final uid = json['alarmUid'];
    if (uid is! String || uid.isEmpty) {
      throw FormatException('acknowledge names no alarm: $json');
    }
    final index = json['ruleIndex'];
    if (index is! num) {
      throw FormatException('acknowledge rule index is not a number: $index');
    }
    if (index is double) {
      if (!index.isFinite) {
        throw const FormatException(
            'acknowledge rule index is not finite: 1e999 decodes to Infinity, '
            'and a rule index that is not a whole number is nonsense');
      }
      if (index != index.truncateToDouble()) {
        throw FormatException(
            'acknowledge rule index is not a whole number: $index');
      }
    }
    if (index < 0) {
      throw FormatException(
          'acknowledge rule index is negative: $index. A rule index is a '
          'position in a list, so this names no rule and there is nothing for '
          'an alarm engine to look up');
    }
    return AckAlarmParams(alarmUid: uid, ruleIndex: index.toInt());
  }

  /// Exactly two keys. `ack_alarm_params_test.dart` asserts the key set as an
  /// equality, so a third one cannot arrive without that arm being edited.
  Map<String, Object?> toJson() =>
      {'alarmUid': alarmUid, 'ruleIndex': ruleIndex};
}

/// One feed of a hold-to-run deadman: the tag, and the counter value on it.
///
/// Sent as a client→server notification under [Methods.holdTick] and never
/// answered — a tick has no outcome to correlate, so it carries no `cmd`
/// (D-P5-C). Slim wire keys (`k`, `n`) for the same reason `update` is `u`:
/// this is the hot path while a button is held.
final class HoldTickParams {
  /// The tag being fed. The same key the engage write named.
  final String key;

  /// The monotonic counter: 1 at engage, +1 per tick, 0 at release, wrapping
  /// to 1 rather than going negative (D-P5-E).
  final int counter;

  /// Refuses a tick that names no tag, for the same reason the write path
  /// refuses a non-finite value: the alternative is a frame that reads as
  /// valid and feeds nothing.
  factory HoldTickParams({required String key, required int counter}) {
    if (key.isEmpty) {
      throw ArgumentError.value(
          key, 'key', 'a tick must name the tag whose deadman it feeds');
    }
    return HoldTickParams._(key, counter);
  }

  const HoldTickParams._(this.key, this.counter);

  /// Refuses a missing or empty key, a non-numeric counter, a fractional one
  /// and a non-finite one, all as a [FormatException].
  ///
  /// The non-finite arm is not theoretical: `1e999` decodes to `Infinity`
  /// without complaint, and `Infinity.toInt()` throws an `UnsupportedError`
  /// that nothing at this boundary is catching — the same poison
  /// [WriteParams.fromJson] defuses.
  factory HoldTickParams.fromJson(Map<String, Object?> json) {
    final key = json['k'];
    if (key is! String || key.isEmpty) {
      throw FormatException('hold tick names no tag: $json');
    }
    final counter = json['n'];
    if (counter is! num) {
      throw FormatException('hold tick counter is not a number: $counter');
    }
    if (counter is double) {
      if (!counter.isFinite) {
        throw const FormatException(
            'hold tick counter is not finite: 1e999 decodes to Infinity, and '
            'a deadman counter that is not a whole number is nonsense');
      }
      if (counter != counter.truncateToDouble()) {
        throw FormatException(
            'hold tick counter is not a whole number: $counter');
      }
    }
    return HoldTickParams(key: key, counter: counter.toInt());
  }

  Map<String, Object?> toJson() => {'k': key, 'n': counter};
}

/// The re-query frame: which commands the caller wants an answer about.
///
/// Built by `RemoteStateMan.writeStatus`. The gateway decodes `cmds` by hand
/// because its refusals are part of its contract — an empty list, a list over
/// `maxKeysPerSubscribe`, a `cmds` that is not a list at all each carry their
/// own `INVALID_PARAMS` message — and routing that through a DTO would trade
/// those sentences for a `FormatException`.
final class WriteStatusParams {
  final List<String> cmds;
  const WriteStatusParams(this.cmds);

  /// **Eager, and refusing** (05-REVIEW IN-03). `(json['cmds'] as List)
  /// .cast<String>()` is a *lazy* view: a non-string element throws at
  /// iteration, which happens outside whatever `try` the decoder was called
  /// under — the exact shape `WriteResult.fromJson`'s tolerance is built
  /// against. Every element is checked here, where the failure is a decode
  /// failure and can be answered as one.
  factory WriteStatusParams.fromJson(Map<String, Object?> json) {
    final raw = json['cmds'];
    if (raw is! List) {
      throw FormatException('writeStatus params carry no "cmds" list: $raw');
    }
    final cmds = <String>[];
    for (final entry in raw) {
      if (entry is! String) {
        throw FormatException('a writeStatus cmd is not a string: $entry');
      }
      cmds.add(entry);
    }
    return WriteStatusParams(cmds);
  }

  Map<String, Object?> toJson() => {'cmds': cmds};
}

// JSON objects key by String; handles are ints. Convert at the boundary.
Map<int, V> _intKeyed<V>(Object? raw, V Function(Object?) decode) {
  if (raw == null) return const {};
  return (raw as Map).cast<String, Object?>().map(
        (k, v) => MapEntry(int.parse(k), decode(v)),
      );
}

Map<String, Object?> _stringKeyed<V>(
        Map<int, V> map, Object? Function(V) encode) =>
    map.map((k, v) => MapEntry('$k', encode(v)));

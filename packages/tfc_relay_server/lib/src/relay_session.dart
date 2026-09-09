/// One connected client: the JSON-RPC peer, the handler table, and the two
/// pieces of armor every handler is born with.
///
/// The direct ancestor is `served_state_man.dart` in the contract kit — a
/// `Peer` over a `StreamChannel<String>` serving a `StateManApi`, with a
/// registration ledger, error armor and an ordered teardown. This is that
/// class with a gate in front of it and a socket underneath (03-04), and three
/// things are copied from it rather than rewritten, on purpose:
///
///  * the `.._start()` cascade, so registration and listening are one
///    expression and a session cannot exist half-registered;
///  * `registeredMethods`, so the wire surface can be asserted in *both*
///    directions — a declared name with no handler, and a handler nobody
///    declared;
///  * `_answer`/`_substitute`, verbatim, including the explanation. That one
///    is the 02-05 hang trap and the highest-risk item in this phase.
///
/// **What this class does not do.** It does not know what a socket is. The
/// channel arrives built (see `ws_channel.dart`), which is what lets every
/// property below be tested over an in-memory pair in milliseconds instead of
/// over a port. It also does not close its own transport: it closes the peer
/// and then hands the close code to the closer its caller supplied, because
/// only the caller knows whether there is a WebSocket down there and only a
/// WebSocket can carry a 4xxx code.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:json_rpc_2/error_code.dart' as rpc_errors;
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:stream_channel/stream_channel.dart';
// Narrowed by `show` on purpose: the master system's vocabulary (groups,
// sessions, records) must not become ambient in this file — the session
// routes and registers, the policy decorator decides. The names past the two
// sinks are the sign-in handler's: the seam it verifies through
// (AuthProvider), the row and session types the verified identity is built
// from, and the two audit factories a login and a logout write with. None of
// them grades anything.
import 'package:tfc_access/tfc_access.dart'
    show
        AccessSession,
        AuditRecord,
        AuditSink,
        AuthProvider,
        AuthenticatedUser,
        NullAuditSink,
        newActionId;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'access_handlers.dart';
import 'alarm_ack_sink.dart';
import 'alarm_handlers.dart';
import 'auth/file_token_validator.dart' show ResolvedUser, UserResolver;
import 'auth/identity.dart';
import 'auth/session_login_validator.dart';
import 'data_handlers.dart';
import 'error_codes.dart';
import 'error_reporter.dart';
import 'handle_table.dart';
import 'health/session_health_state_man.dart';
import 'policy/key_policy.dart';
import 'policy/policy_state_man.dart';
import 'policy/series_mapping_tally.dart';
import 'server_config.dart';
import 'session_handlers.dart';
import 'subscription_registry.dart';
import 'token_validator.dart';
import 'value_handlers.dart';

/// The moment the last inbound frame arrived, updated by a tap on the read
/// side.
///
/// A tiny mutable holder rather than a field on the session, because the tap
/// has to exist *before* the `Peer` does and the `Peer` has to exist before
/// the session does — and the alternative, a `late` peer assigned after
/// construction, is how a session comes to exist half-built.
final class _LastSeen {
  _LastSeen(this._now, this._monotonicNow)
      : at = _now(),
        atMono = _monotonicNow();
  final int Function() _now;
  final int Function() _monotonicNow;
  int at;

  /// The same instant on the LIVENESS clock — the engine's monotonic domain
  /// when the composition root injected one (09-REVIEW WR-01), this session's
  /// wall clock otherwise. `silentForMs` subtracts from this field; [at] is
  /// the *reported* instant and stays wall-clock.
  int atMono;

  /// Whether inbound frames count as evidence of a client worth keeping.
  ///
  /// Null until the session exists, and answering false until the handshake
  /// lands (05-REVIEW WR-03). Before `hello` an inbound frame is not evidence
  /// of a panel — it is evidence of a socket, which the reaper is entitled to
  /// take back. A peer that never authenticates and sends `h` at line rate
  /// would otherwise hold its own session open indefinitely by shouting at a
  /// gate that keeps refusing it.
  bool Function()? _helloed;

  // ignore: use_setters_to_change_properties — a setter here would read as a
  // field assignment at the one call site, where the point is that the
  // predicate is installed once and late.
  void gateOn(bool Function() helloed) => _helloed = helloed;

  String touch(String frame) {
    if (_helloed?.call() ?? false) {
      at = _now();
      atMono = _monotonicNow();
    }
    return frame;
  }

  /// Starts the heartbeat clock at the handshake.
  ///
  /// The `hello` frame itself arrives before [touch] will move anything, so
  /// without this a panel that took ten seconds to connect would begin its
  /// session already ten seconds silent.
  void touchNow() {
    at = _now();
    atMono = _monotonicNow();
  }
}

/// The access families whose backend halves attribute every audit row to
/// a session — the ones `composeBackendRelay` deliberately does **not** wire
/// (17-06): at compose time there is no identity to attribute to, and
/// constructing them with an invented one would be the false attribution
/// D-11 forbids.
///
/// `backendConfig` is the third slot, the Phase 17 gate's one named
/// carry-forward: the config store writes audit rows for accepted AND
/// refused writes (17-10), so it needs the verified identity exactly as the
/// other two do. Nullable, and null is a **decision**, not a default: a
/// factory that hands no config family leaves the shared source answering,
/// which on the shipped backend is 17-03b's refuse-by-name — fail closed,
/// never a stub.
typedef IdentityAccessFamilies = ({
  AccessTemplateApi accessTemplates,
  AccessAdminApi accessAdmin,
  BackendConfigApi? backendConfig,
});

/// Builds the per-identity halves of the access surface, invoked exactly once
/// per session, at `hello`, with the resolver-verified [StationIdentity].
///
/// The seam 17-11 fills from the moved stores
/// (`BackendAccessTemplates`/`BackendAccessAdmin`/`BackendConfigStore` take
/// `session: () => identity.session, station: identity.station` — their own
/// contract, per 17-06-SUMMARY deviation 1). This package cannot name those
/// classes — `tfc_dart` depends on it, not the reverse — so the construction
/// crosses as a callback, exactly as [TokenValidator] and [KeyPolicy] do.
///
/// Null means the shared source's own families answer, which for the shipped
/// backend is 17-03b's refuse-by-name — **fail closed, never a stub**.
typedef AccessScopeFactory = IdentityAccessFamilies Function(
    StationIdentity identity);

/// One client session.
final class RelaySession {
  RelaySession._(
    this.peer,
    this._source,
    this.config,
    this.handles,
    this.buffer,
    this.validator,
    this.policy,
    this.alarmAcks,
    this.resolver,
    this._gate,
    this._lastSeen,
    this._now,
    this._monotonicNow,
    this._closeChannel,
    this._emitFrame,
    this._onClosing,
    this._writeOutcomes,
    this._seriesTally,
    this._mintGeneration,
  );

  /// Serves [api] over [channel] and starts listening immediately.
  ///
  /// [channel] is already a channel of whole JSON strings, and its sink is
  /// already whoever's the caller decided it should be — the session sink for
  /// a real client, the raw pair end for a test.
  ///
  /// [emitFrame] is how an already-encoded frame the **tick engine** produced
  /// leaves this session — the drained priority lane, the `u` updates and the
  /// tick notification. It cannot be the channel's own sink: that sink is the
  /// [SessionSink], which puts everything it is given *into* the buffer, so a
  /// tick that wrote its drained frames back through it would refill the lane
  /// it had just emptied and nothing would ever reach the wire. Optional,
  /// because a session driven by no engine never produces one; when it is
  /// absent [emit] drops the frame rather than throwing, since the caller is
  /// the timer and an exception there takes the whole server's tick down with
  /// it.
  ///
  /// [closeChannel] is how a close *code* reaches the client. Optional,
  /// because an in-memory channel has nowhere to put one; without it [close]
  /// still records the code and tears the session down, which is what every
  /// assertion in this phase reads (`web_socket_channel` #1698: a socket's own
  /// `closeCode` is unreliable for a close it initiated).
  ///
  /// [monotonicNow] is the LIVENESS clock [silentForMs] measures on. The
  /// composition root (`relay_server.dart`) hands every session the tick
  /// engine's own uptime clock, so the reaper's `silentMs - forgivenMs`
  /// subtraction lands in one clock domain — the domain `LagStalled.stalledMs`
  /// was measured in (09-REVIEW WR-01). Absent, it falls back to [now]: a
  /// by-hand session keeps one clock for both jobs, which is single-domain
  /// too.
  static RelaySession serve({
    required StreamChannel<String> channel,
    required StateManApi api,
    required ServerConfig config,
    required HandleTable handles,
    required ConflatingSendBuffer buffer,
    TokenValidator validator = const PermissiveTokenValidator(),
    KeyPolicy policy = const AccessPolicyKeyPolicy(),
    AlarmAckSink? alarmAcks,
    AuditSink audit = const NullAuditSink(),
    AccessScopeFactory? accessFor,
    AuthProvider? loginVerifier,
    UserResolver? loginAccounts,
    required SeriesResolver resolver,
    List<String> serverSupported = const [protocolVersion],
    WriteOutcomeLog? writeOutcomes,
    SeriesMappingTally? seriesTally,
    int Function()? mintGeneration,
    Future<void> Function(int code, String reason)? closeChannel,
    void Function(String frame)? emitFrame,
    void Function(RelaySession session)? onClosing,
    RelayErrorHandler? onError,
    int Function()? now,
    int Function()? monotonicNow,
    SessionHealthStateMan? health,
  }) {
    final clock = now ?? () => DateTime.now().millisecondsSinceEpoch;
    final liveness = monotonicNow ?? clock;
    final lastSeen = _LastSeen(clock, liveness);
    return RelaySession._(
      rpc.Peer(
          StreamChannel<String>(
              channel.stream
                  .map(lastSeen.touch)
                  .map((frame) => _underCeiling(frame, config.maxFrameBytes))
                  .map(_defuse),
              channel.sink),
          onUnhandledError: onError == null
              ? null
              // `ErrorCallback`'s two parameters are `dynamic`
              // (json_rpc_2/src/server.dart:18), so they are narrowed here
              // rather than at every call site of ours.
              : (dynamic error, dynamic stack) => onError(
                  error as Object,
                  stack is StackTrace ? stack : StackTrace.current,
                  'session peer')),
      api,
      config,
      handles,
      buffer,
      validator,
      policy,
      alarmAcks,
      resolver,
      HelloGate(serverSupported: serverSupported),
      lastSeen,
      clock,
      liveness,
      closeChannel,
      emitFrame,
      onClosing,
      writeOutcomes ??
          WriteOutcomeLog(ttl: config.writeOutcomeTtl, now: clock),
      seriesTally ?? SeriesMappingTally(),
      mintGeneration,
    )
      .._onError = onError
      .._health = health
      // Before `_start()`, which is what evaluates the late `api` these two
      // feed. Assigned in the cascade, [_onError]'s style: they are wiring
      // details of the server, not part of what a session *is*, and every
      // by-hand session in this package's suite leaves them defaulted.
      .._audit = audit
      .._accessFor = accessFor
      .._loginVerifier = loginVerifier
      .._loginAccounts = loginAccounts
      .._start();
  }

  /// Where this session's authorization verdicts become rows (D-05).
  ///
  /// Threaded into the policy decorator below; [NullAuditSink] on a session
  /// built by hand, `RelayServer`'s injected sink in production. The trail is
  /// an account of decisions and never a precondition for making them, which
  /// is why the default discards rather than throws.
  AuditSink _audit = const NullAuditSink();

  /// See [AccessScopeFactory]. Consulted exactly once, in `_hello`, beside
  /// the identity assignment it depends on.
  AccessScopeFactory? _accessFor;

  /// What [_accessFor] built for this session's identity, or null before
  /// `hello` — and null forever when no factory was supplied, in which case
  /// the shared source's own families answer (refuse-by-name on the shipped
  /// backend).
  IdentityAccessFamilies? _scoped;

  /// Where `session.login` verifies a password, or null on a gateway that
  /// serves no interactive sign-in (every by-hand session in this package's
  /// suite, and any deployment that has not wired one).
  ///
  /// The seam is `tfc_access`'s own [AuthProvider] — the interface
  /// `LocalAuthProvider` already implements — so the wire adds no second
  /// verification vocabulary. Its null-versus-throw contract is load-bearing
  /// here exactly as it is on the panel: null is a credential verdict,
  /// a throw is infrastructure, and [_sessionLogin] keeps them apart all
  /// the way into two different refusal markers and an audit row for only
  /// one of them.
  AuthProvider? _loginVerifier;

  /// Where a verified username becomes an account and its grants — the same
  /// synchronous, embedder-refreshed [UserResolver] the file validator and
  /// the sweep read, threaded per session so the login handler resolves
  /// against the exact cache `stillValid` will judge the identity by. Two
  /// sources here would mint sessions the next sweep tick retires.
  UserResolver? _loginAccounts;

  /// This session's health overlay, or null on a session built by hand.
  ///
  /// Held so [_ping] can touch its deadline. Assigned in the cascade above
  /// rather than taken through the positional constructor, in [_onError]'s
  /// style: it is a wiring detail of the server, not part of what a session
  /// *is*, and every case in this package that builds a session by hand leaves
  /// it null.
  ///
  /// **Renamed from `certHealth` in 08-12**, when the per-server certificate
  /// overlay was replaced by a per-session one in the same chain slot. The
  /// parameter was renamed rather than kept beside a second because nothing
  /// but `relay_server.dart` ever passed it — every by-hand session in this
  /// package's suite leaves it null — so keeping the old spelling would have
  /// bought a name that lies about what it holds and nothing else.
  SessionHealthStateMan? _health;

  /// Refuses one inbound frame that is over the ingress ceiling, before
  /// anything decodes it.
  ///
  /// **03-REVIEW WR-04 / threat T-03-29.** There was no frame-size limit
  /// anywhere in the path, and json_rpc_2's parse-error responder echoes the
  /// *entire* offending text back (`utils.dart:60-70`), into the priority lane,
  /// held until the next tick. A client sending garbage faster than the tick
  /// drains grew the server's heap by megabytes per frame with no verdict
  /// available to stop it.
  ///
  /// A `FormatException` rather than a stream error, and one carrying **no
  /// source**: that is what makes json_rpc_2 answer `-32700` to the sender and
  /// carry on, and the missing source is what keeps the refusal from echoing
  /// the very megabytes it is refusing. The session survives — an oversized
  /// request must cost the request, not the panel that sent it.
  ///
  /// The ceiling is on the decoded *string* length rather than on wire bytes.
  /// For the plant's ASCII tag names the two are the same number; for a frame
  /// full of Icelandic þ/ð/æ the UTF-8 encoding is larger, so this is the
  /// slightly permissive direction, which is the right one for a limit whose
  /// job is to refuse an order of magnitude rather than a byte.
  ///
  /// ## What this ceiling cannot bound, and why (16-09, WSH-13 / S10)
  ///
  /// The paragraph above concedes the *unit*. This one concedes the thing that
  /// matters more, and that the paragraph above does not mention at all: the
  /// **assembly point**.
  ///
  /// This runs on the decoded `String`, which means it runs **after** `dart:io`
  /// has already read every fragment of the WebSocket message off the socket,
  /// assembled them into one buffer in heap, and UTF-8-decoded the result. By
  /// the time `frame.length` is compared against anything, the megabytes are
  /// already allocated. The refusal below stops the *amplification* — the echo,
  /// the priority-lane growth, json_rpc_2's parse-error responder quoting back
  /// the very thing it is refusing — and it does not, and cannot, stop the
  /// allocation.
  ///
  /// **There is no earlier place to put it on this platform.** Neither
  /// `dart:io`'s `WebSocket` nor `shelf_web_socket` 3.0.0 exposes an incoming
  /// frame-size or message-size cap. `shelf_web_socket`'s `WebSocketHandler`
  /// takes exactly three arguments — `_protocols`, `_allowedOrigins`,
  /// `_pingInterval` — and there is no fourth to pass a limit through. Both
  /// were **read in those packages' own source**, not inferred from their
  /// documentation, and `server_config.dart`'s `maxFrameBytes` records the
  /// same finding from the configuration side.
  ///
  /// **So what bounds the exposure is volume, not size.** Three things, none
  /// of which is this ceiling:
  ///
  ///  * `ServerConfig.preHelloDeadline` — how long a peer that has not
  ///    authenticated may hold a session at all: 2 s at the shipping defaults,
  ///    where before 16-09 it was the 6 s heartbeat deadline;
  ///  * `ServerConfig.maxUnhelloedSessions` — how many such peers there may be
  ///    at once (64), enforced in `RelayServer._onConnect` before a session is
  ///    built rather than after;
  ///  * `ServerConfig.allowedOrigins` — which browsers may open one at all.
  ///
  /// **The residual, stated as a number and accepted.** One assembled frame
  /// per un-helloed connection, up to `maxFrameBytes`: at the shipping
  /// defaults, 64 × 1 MiB = **64 MiB** that peers presenting no credential can
  /// make this gateway hold, for up to two seconds each. That is **accepted**,
  /// not closed, because the platform offers nowhere earlier to refuse it and
  /// both alternatives — hand-rolling the WebSocket framing layer, or putting
  /// a reverse proxy in front of every gateway in the plant — are larger than
  /// the exposure they would remove. "Bounded" is a weaker claim than "fixed"
  /// and this paragraph is worth nothing if a later reader can mistake one for
  /// the other.
  ///
  /// **If the transport ever gains a pre-assembly cap, this is the site that
  /// changes**: the ceiling moves off the decoded string and onto the frame,
  /// `maxFrameBytes` starts measuring the unit its own name claims, and the
  /// UTF-16 concession above retires with it.
  static String _underCeiling(String frame, int maxFrameBytes) {
    if (frame.length <= maxFrameBytes) return frame;
    throw FormatException('frame of ${frame.length} bytes exceeds the '
        '$maxFrameBytes byte ingress ceiling');
  }

  /// Takes the poison out of one inbound frame before the `Peer` ever sees it.
  ///
  /// **The one place `1e999` is disarmed for paths this class does not own.**
  /// `_answer` and the fallback below can only armor errors that pass through
  /// them. Two shapes never do: an envelope json_rpc_2 itself rejects (missing
  /// `method`, wrong `jsonrpc`, a non-object `params` — every throw in
  /// `Server._validateRequest`), and an `id` that is itself non-finite, which
  /// `RpcException.serialize` copies into the response before any of our code
  /// runs (`exception.dart:60` accepts any `num` as an id, and Infinity is
  /// one). Both produce a response `jsonEncode` refuses; json_rpc_2 discards
  /// the refusal inside the Peer and the client waits forever on a healthy
  /// link. That is the 02-05 hang, reachable by anything that can open a
  /// socket.
  ///
  /// So the frame is decoded, sanitized and re-encoded here, at the boundary,
  /// which is where CLAUDE.md says wire hazards belong. The cost is one extra
  /// `jsonDecode` per **inbound** frame — requests only, never the telemetry
  /// fan-out, which is the path Finding 2 measured — and the re-encode is paid
  /// only by a frame that actually carried a non-finite number.
  ///
  /// **A frame the sanitizer cannot process is refused, not passed through**
  /// (06-04, 06-RESEARCH §H.2). This paragraph used to argue the opposite —
  /// "anything that goes wrong here leaves the frame exactly as it was" — on
  /// the grounds that a value nested past [maxValueDepth] would be caught by
  /// the handler's own `sanitize` and cost one request, where a stream error
  /// would cost the session. That trade was right when those were the two
  /// options. It is wrong now that the pass-through has been measured, because
  /// what it actually buys is two things and neither is a per-request refusal:
  ///
  ///  * **A pre-hello amplification** (T-06-17). The frame reaches
  ///    `json_rpc_2` intact. If it names an unknown method, `Server`'s own
  ///    `methodNotFound` is thrown with `data == null` and `serialize` fills
  ///    that `data` with the **raw request** — up to `maxFrameBytes` (1 MB) of
  ///    `params` echoed back into the priority lane, held until the next tick,
  ///    by a peer that has not authenticated. The fallback registered below
  ///    does not stop it; see the comment there for why.
  ///  * **The 02-05 hang, reachable pre-hello** (T-06-18). Add `1e999`
  ///    anywhere in that request and the echo cannot be encoded, so the
  ///    refusal is discarded *inside* the Peer and a caller with no deadline
  ///    waits forever. Measured, over a real socket, before any handshake.
  ///
  /// So a `sanitize` failure becomes a [FormatException] with **no source** —
  /// [_underCeiling]'s exact shape, and the precedent that the session
  /// survives it: `json_rpc_2` answers `-32700` to the sender, the missing
  /// source is what keeps the refusal from being as large as the thing it
  /// refuses, and the stream carries on. The per-request cost is kept; the
  /// amplification and the hang are not.
  ///
  /// A frame that is merely **not JSON** is still json_rpc_2's parse error to
  /// answer — `jsonDecode`'s own `FormatException` carries the source *text*,
  /// a String, which encodes, and there is nothing in it to defuse. It is
  /// allowed to propagate rather than being caught and re-thrown, so the
  /// answer is the same one this boundary has always given for garbage.
  static String _defuse(String frame) {
    // Outside the `try` on purpose: a `FormatException` from here is the
    // not-JSON case above and must reach json_rpc_2 with its source intact.
    final decoded = jsonDecode(frame);

    final SanitizeResult sanitized;
    try {
      sanitized = sanitize(decoded);
    } catch (error) {
      // Sourceless, exactly as `_underCeiling` throws. The message says what
      // was refused without quoting any of it.
      throw FormatException('frame could not be sanitized and was refused '
          'rather than passed on: $error');
    }
    if (!sanitized.hadNonFinite) return frame;
    return jsonEncode(sanitized.value);
  }

  /// The shared source this gateway serves, **before** the policy.
  ///
  /// Private, and that privacy is the T-06-38 mitigation rather than style.
  /// Everything inside this class reaches the plant through [api], which is
  /// the policed view of this field; a handler added in Phase 10 therefore
  /// cannot forget the policy consultation, because there is no unwrapped
  /// source in scope for it to forget with. If this ever needs to become
  /// public again, that is the property being given up.
  final StateManApi _source;

  /// The source being served, seen through this session's [policy].
  ///
  /// Every handler this session builds is handed *this*, never [_source]:
  /// `SessionHandlers` and `ValueHandlers` both take it in [_start], so
  /// `subscribe`, `read`, `readFresh`, `readMany`, `write` and `holdToRun` all
  /// reach the plant through one object that knows which station is asking.
  ///
  /// `late` because the decorator reads the identity through a callback and
  /// the field initializer runs on first use, which is inside [_start] — after
  /// [policy] and [_source] are set and long before `_hello` mints anything.
  /// Typed as the concrete decorator rather than as `StateManApi` so [_start]
  /// can build the write predicate from its `canWrite`, which keeps the
  /// null-identity decision in exactly one place.
  late final PolicyStateMan api = PolicyStateMan(
    // The one divergence from handing [_source] straight in, and it is three
    // getters wide: the scoping view answers the session's per-identity
    // template/admin/config families once `_hello` has built them, and
    // forwards everything else — including `audit`, which is sessionless
    // (17-06) — untouched. It sits UNDER the decorator on
    // purpose, so the policy gate applies to a scoped family exactly as it
    // applies to the shared one; a scoped family handed to a handler
    // directly would be a family the gate never sees.
    //
    // Interposed only when a factory exists: with none, the view would be
    // pure forwarding — semantically identical and one indirection wide —
    // and `health_session_test.dart`'s chain arm reads "policy over health
    // over source" off this field by type, which a decorative wrapper would
    // break for nothing.
    source: _accessFor == null
        ? _source
        : _IdentityScopedSource(_source, () => _scoped),
    policy: policy,
    resolver: resolver,
    tally: _seriesTally,
    sink: _audit,
    // The session's one error seam, so a sink failure lands where every
    // other failure this session produces lands. Falls back to the
    // decorator's own default when the server wired no handler.
    onAuditError: _onError ?? reportToStderr,
    // Late-read, the `epochOf` / `ownerOf` idiom below: the identity is minted
    // by `_hello`, which cannot have run when this object is built.
    identityOf: () => _identity,
  );

  /// The JSON-RPC endpoint. Exposed so a test can assert on its state.
  final rpc.Peer peer;

  final ServerConfig config;

  /// The server-global key→handle table. Shared across sessions on purpose:
  /// two panels watching one motor must be handed the same integer, or the
  /// encode-once body stops being byte-identical.
  final HandleTable handles;

  /// This session's outbound buffer. Everything the tick engine will drain.
  final ConflatingSendBuffer buffer;

  /// What this session is currently watching.
  ///
  /// Public because "the release is asserted by registry inspection" (SRV-02)
  /// is only true of a registry something can look into, and because the tick
  /// engine and the reaper both read it from outside the session.
  late final SubscriptionRegistry subscriptions = SubscriptionRegistry(
      maxSubscriptions: config.maxSubscriptionsPerSession,
      mintGeneration: _mintGeneration);

  /// The gateway's subscription-generation counter, shared with every other
  /// session on this server. See [SubscriptionRegistry._mint].
  final int Function()? _mintGeneration;

  final TokenValidator validator;

  /// Which tags this session's station may see and actuate.
  ///
  /// Held here rather than reached for through the server, because the session
  /// deliberately does not know what a server is (see this library's doc) —
  /// the same reason [validator] is a field. What consults it is the
  /// `PolicyStateMan` built in [_start]; nothing else in this class asks it a
  /// question directly.
  final KeyPolicy policy;

  /// Where an accepted acknowledge goes, or null on a gateway serving no alarm
  /// engine.
  ///
  /// Held here for [policy]'s reason — the session deliberately does not know
  /// what a server is. **Null is a supported deployment, not a
  /// misconfiguration**: `Methods.ackAlarm` is registered either way, and the
  /// handler answers a named refusal rather than being absent from the wire.
  /// What consults it is the [AlarmHandlers] built in [_start]; nothing else in
  /// this class asks it anything.
  final AlarmAckSink? alarmAcks;

  /// How a node id and a table name become a plant key.
  ///
  /// Held here rather than reached for through the server, exactly as
  /// [validator] and [policy] are and for the same reason: the session
  /// deliberately does not know what a server is. What consults it is the
  /// [PolicyStateMan] built below and the [DataHandlers] built in [_start];
  /// nothing in this class asks it a question directly.
  final SeriesResolver resolver;

  final HelloGate _gate;
  final _LastSeen _lastSeen;
  final int Function() _now;

  /// The liveness clock — the engine's own monotonic clock in production
  /// (09-REVIEW WR-01), [_now] on a session built without one.
  final int Function() _monotonicNow;
  final Future<void> Function(int code, String reason)? _closeChannel;
  final void Function(String frame)? _emitFrame;

  /// Called synchronously, once, at the top of [close] — before the peer, the
  /// subscriptions or the transport are touched.
  ///
  /// The server hangs the registry removal off it. A hook rather than a
  /// registry reference because the session does not know what a server is
  /// (see this library's doc), and every in-memory test in this phase builds
  /// one without either.
  final void Function(RelaySession session)? _onClosing;

  /// The gateway's write outcome log, shared with every other session on this
  /// server. Defaulted to one of this session's own when nobody supplied one,
  /// which is the in-memory test shape — and which is exactly the per-socket
  /// lifetime 04-REVIEW CR-02 is about, so a session built that way can only
  /// ever answer about writes it handled itself.
  final WriteOutcomeLog _writeOutcomes;

  /// Where a series this gateway cannot map is recorded.
  ///
  /// Server-owned and shared across sessions, like [_writeOutcomes] and for a
  /// related reason: the number that matters is "is anything still asking for
  /// a series the collection plan does not produce", and a per-socket copy
  /// would be reset by every reconnect. The default here is a fresh one so a
  /// session built by hand in a test is not obliged to supply one; `RelayServer`
  /// always does.
  final SeriesMappingTally _seriesTally;

  /// This session's value handlers, held because they own the hold-to-run map
  /// and [_teardown] has to release it. Null only between construction and
  /// [_start], which is one expression in [serve].
  ValueHandlers? _values;

  /// This session's data-service handlers, held for the same reason [_values]
  /// is: they own a listener on the gateway's **shared** preference store, and
  /// a listener that outlives its session goes on building key sets and
  /// announcing them for a panel that has gone home. Null only between
  /// construction and [_start].
  DataHandlers? _data;

  /// Puts one already-encoded [frame] on this session's transport.
  ///
  /// The tick engine's write seam, and the only way out of a session that does
  /// not go through the buffer first — because by the time the engine calls
  /// this, the buffer is what the frame came *out* of.
  ///
  /// It is also where [egressKbps] is metered, because it is the one place
  /// every byte this gateway says to this client passes through. A second
  /// meter anywhere else would be a second number that nearly agrees.
  void emit(String frame) {
    _egressBytes += frame.length;
    _egressLastMs = _now();
    _egressFirstMs ??= _egressLastMs;
    _emitFrame?.call(frame);
  }

  // ---------------------------------------------------------------------------
  // The per-session health measurements (HLTH-01, 08-12).
  //
  // Counters on the session rather than in the overlay, because the overlay is
  // built before the session exists and because these are properties of the
  // connection: an overlay swapped out would take the panel's history with it.
  // Nothing here holds a timer — every number is a subtraction over values
  // recorded by paths that already run.
  // ---------------------------------------------------------------------------

  /// Bytes this gateway has written to this client, as [emit] measured them.
  ///
  /// The frame's `String.length`, not its UTF-8 size: for the plant's ASCII
  /// tag names the two are the same number, and a frame full of Icelandic
  /// þ/ð/æ is under-counted by a few percent. Encoding every outbound frame a
  /// second time to be exact would put a whole encode back on the hot path
  /// this design spent Finding 3 taking off it, for a gauge measured in
  /// kilobits.
  int get egressBytes => _egressBytes;
  int _egressBytes = 0;
  int? _egressFirstMs;
  int? _egressLastMs;

  /// Kilobits per second through this session's sink, or null before there is
  /// a span to divide by.
  ///
  /// Null and not zero: a session that has said nothing yet has an *unknown*
  /// egress, where zero is the claim that the pipe has stopped.
  double? get egressKbps {
    final first = _egressFirstMs;
    final last = _egressLastMs;
    if (first == null || last == null || last <= first) return null;
    return (_egressBytes * 8) / (last - first);
  }

  /// Ticks on which the tick engine actually fanned telemetry out to this
  /// session.
  ///
  /// **Ticks delivered, not ticks that happened.** The engine ticks the whole
  /// registry at one cadence, so a counter of those would read the configured
  /// rate for every session on the gateway and could never distinguish a panel
  /// that is being served from one that is not — which is the entire question
  /// `effective_hz` exists to answer. A subscription held back by its own
  /// `maxRateHz`, or by the lane split's deferral, is genuinely not being
  /// delivered to on that tick.
  int get servedTicks => _servedTicks;
  int _servedTicks = 0;
  int? _servedFirstMs;
  int? _servedLastMs;

  /// Records that this session was served on the tick at [monotonicMs].
  ///
  /// Idempotent within a tick: the engine calls it once per due subscription
  /// and a session watching forty pages is not being served forty times as
  /// fast as one watching a single page.
  ///
  /// [monotonicMs] is the **engine's** clock — a monotonic uptime `Stopwatch`,
  /// not the session's wall clock — and that is deliberate: a rate is a
  /// measurement of arrivals, and an NTP step must not show up as a burst or a
  /// gap. It is never mixed with the wall-clock numbers beside it; see
  /// `tick_engine.dart:169-187` for the same split made for the wire clock.
  void noteServedTick(int monotonicMs) {
    if (_servedLastMs == monotonicMs) return;
    _servedTicks++;
    _servedFirstMs ??= monotonicMs;
    _servedLastMs = monotonicMs;
  }

  /// Ticks delivered to this session per second, or null before there have
  /// been two.
  ///
  /// Null and not zero before the first span: `effective_hz` reading 0 means
  /// "the pipe has stopped", which is a different and considerably more
  /// alarming claim than "nothing has been measured yet".
  double? get effectiveHz {
    final first = _servedFirstMs;
    final last = _servedLastMs;
    if (first == null || last == null || last <= first) return null;
    return ((_servedTicks - 1) * 1000) / (last - first);
  }

  /// Acts on one [verdict] from this session's send buffer. Returns whether
  /// the session survived it.
  ///
  /// **Why the switch lives here rather than at the caller.** The close code a
  /// backpressure eviction carries is decided by the thing that measured the
  /// backlog, and it reaches the client by being *carried* — `verdict.closeCode`
  /// and `verdict.reason`, never a constant re-typed at this call site. A
  /// session that named 4004 for its own reasons and a buffer that named it for
  /// the measured one can drift apart the moment either is edited, and the
  /// symptom of that drift is a client told the wrong thing about why it was
  /// disconnected — which is precisely the repudiation T-03-27 is about. One
  /// switch, in one place, over the sealed type.
  ///
  /// The switch is exhaustive with no `default:` and no `_ =>` arm, and
  /// [BufferOk] is an explicit no-op rather than a fall-through: a third
  /// verdict added to `BufferVerdict` must be a compile error here, not a
  /// silently ignored eviction policy.
  bool applyVerdict(BufferVerdict verdict) {
    switch (verdict) {
      case BufferDisconnect(:final closeCode, :final reason):
        unawaited(close(closeCode, reason));
        return false;
      case BufferOk():
        return true;
    }
  }

  /// The negotiated protocol, and the session's identity — all null until a
  /// `hello` is accepted.
  String? get protocol => _protocol;
  String? _protocol;

  String? get sessionId => _sessionId;
  String? _sessionId;

  /// Whether the handshake has landed on this session.
  ///
  /// **One spelling of "helloed", used by everything that asks.** Three
  /// separate mechanisms depend on this predicate and they must not be able to
  /// disagree about it: [_LastSeen]'s gate (an inbound frame is evidence of a
  /// panel only after the handshake, 05-REVIEW WR-03), the pre-hello deadline
  /// `RelayServer` arms per connection, and the un-helloed budget the same
  /// class consults before it registers a new one. Two of those would close a
  /// session and the third would refuse one, so a version that drifted would
  /// disconnect panels the others considered established.
  ///
  /// [sessionId] rather than [identity], deliberately: the id is minted at the
  /// end of `_hello`, after the credential has been accepted and the gate has
  /// been spent, so it is the moment the session became a panel rather than
  /// the moment a token was recognised.
  bool get helloed => _sessionId != null;

  String? get epoch => _epoch;
  String? _epoch;

  /// Which station this session is, once its credential has been accepted.
  ///
  /// Null before the handshake and on a session whose credential was refused,
  /// which is what `RelayServer.reloadTokens`' sweep skips on: a pre-hello
  /// session is already held by the gate and already reaped by the heartbeat
  /// reaper, so it is not the revocation's business.
  ///
  /// Set once and never again — see [_hello]. On a `PermissiveTokenValidator`
  /// it is that validator's self-naming station, which is the honest answer:
  /// the gateway does know who this is, and the answer is "anybody".
  // 17-07 spillover, mechanical only (flagged in 17-07-SUMMARY): `Identity`
  // was deleted by 17-04b and this pair blocked every suite importing this
  // file from loading. The rewrite of what surrounds it is 17-09's.
  StationIdentity? get identity => _identity;
  StationIdentity? _identity;

  /// A one-way digest of the credential this session authenticated with, when
  /// the validator produced one.
  ///
  /// Set at the same moment as [identity] and never separately — the pair is
  /// what `RelayServer.reloadTokens`' sweep asks about. Without it the sweep
  /// can see a station whose token was removed, renamed or demoted and cannot
  /// see one whose token was **replaced**, which is what a leaked credential
  /// is actually remediated with. Never the credential itself; see
  /// [TokenAccepted.credentialDigest] for why the digest is safe to hold.
  Uint8List? get credentialDigest => _credentialDigest;
  Uint8List? _credentialDigest;

  /// How many hold-to-run ticks this session dropped — malformed, naming a
  /// hold it never engaged, or arriving before the handshake.
  ///
  /// A passthrough to [ValueHandlers.droppedHoldTicks] *plus* the ones the
  /// gate refused before the handler was reached, exposed here for the same
  /// reason [sentCloseCode] and [lastSeenMs] are: it is the only way a case
  /// that drives a whole session can read a property the wire cannot report,
  /// because a tick is never answered. Nothing in production depends on it;
  /// the production home for the number is a `PIPE.*` health key in Phase 8
  /// (D-P5-I).
  ///
  /// One number and not two (05-REVIEW WR-03): a pre-hello tick is a frame
  /// that reached a handler and did nothing, which is what every other entry
  /// in this count is, and the health key Phase 8 surfaces should not have a
  /// hole in it where the unauthenticated peers go.
  int get droppedHoldTicks =>
      (_values?.droppedHoldTicks ?? 0) + _ungatedNotifications;

  /// Notifications the gate refused, dropped rather than thrown.
  var _ungatedNotifications = 0;

  /// Whether the one summary line has been emitted for this session.
  var _complainedUngated = false;

  /// The server's one error seam, kept because a notification's refusal has
  /// nowhere else to be reported: `onUnhandledError` is per *thrown* error,
  /// and the whole point of [_onNotification] is not to throw one per frame.
  RelayErrorHandler? _onError;

  /// When the last inbound frame arrived, on the session's clock.
  ///
  /// The heartbeat reaper (03-11) sweeps on this. A tap on the read side
  /// rather than a touch in each handler, because a frame the peer *rejects*
  /// is still evidence the client is alive.
  ///
  /// **Not before the handshake, though** (05-REVIEW WR-03). Until `hello` is
  /// accepted an inbound frame is evidence of a socket, not of a panel, and a
  /// peer that never authenticates would otherwise keep its own session out
  /// of the reaper's reach by sending frames the gate keeps refusing. The
  /// clock starts at the handshake, which touches this once on the way past.
  ///
  /// **WebSocket pongs deliberately do not move it.** `dart:io` answers the
  /// server's pings inside the socket and surfaces nothing on the stream, so
  /// only frames the *application* sent land here. That is the whole
  /// distinction Finding 7 rests on: a panel whose process is wedged while its
  /// kernel still answers pings is exactly the client the ping cannot see, and
  /// a liveness field that counted pongs would be the ping wearing the
  /// heartbeat's name.
  int get lastSeenMs => _lastSeen.at;

  /// How long this session has been silent, **on the engine's clock**.
  ///
  /// The reaper asks the session rather than doing the arithmetic itself,
  /// because only the session knows when its last frame arrived — but the
  /// clock the answer lives on is the one the composition root injected as
  /// [RelaySession.serve]'s `monotonicNow`, which in production is the tick
  /// engine's own uptime `Stopwatch` (09-REVIEW WR-01). That puts the reap
  /// forgiveness's `silentMs - forgivenMs` in ONE clock domain: before this,
  /// the silence was wall-clock (`_now() - _lastSeen.at`) while
  /// `LagStalled.stalledMs` is monotonic, and the two agree only for stalls
  /// both clocks observe — Isolate.pause and SIGSTOP, but not a hypervisor
  /// stun on a guest whose monotonic clock freezes across it, nor an NTP
  /// forward step with no event-loop stall. Either shape inflated every
  /// session's wall silence with no `LagStalled` to credit, and the wake-up
  /// tick 4003'd every beating panel — the synchronized false disconnect
  /// F22 exists to prevent, produced by our own reaper.
  ///
  /// [lastSeenMs] stays wall-clock: the *reported* instant is for humans and
  /// for `HelloResult.serverTime`'s offset arithmetic; only the *comparison*
  /// is monotonic. A session built without a `monotonicNow` falls back to
  /// its wall clock, which keeps both measurements in one domain either way.
  int silentForMs() => _monotonicNow() - _lastSeen.atMono;

  /// The close code this session sent, recorded by the session itself.
  ///
  /// Never read off the socket: `closeCode` is unreliable for a close the
  /// server initiated (`web_socket_channel` #1698), so both ends track what
  /// they sent. Every close-code assertion in this phase reads this field.
  int? get sentCloseCode => _sentCloseCode;
  int? _sentCloseCode;

  /// Completes when the session has stopped serving.
  Future<void> get closed => _done.future;
  final _done = Completer<void>();

  var _closed = false;

  /// Every name [_on] has registered, in registration order.
  ///
  /// Kept so the wire surface can be asserted against the handlers in *both*
  /// directions: a declared name with no handler answers METHOD_NOT_FOUND from
  /// a table claiming to carry it, and a handler with no declared name is
  /// surface nobody counted. 03-08 freezes this set.
  Set<String> get registeredMethods => Set.unmodifiable(_registered);
  final _registered = <String>{};

  /// Registers [handler] under [method], with the gate and the error armor
  /// wrapped around it.
  ///
  /// **The composition is the point.** Gating lives here, at the one seam
  /// where a method enters the table, so a handler added in 03-05 or 03-07 is
  /// gated and armored by construction. A per-handler check would be a rule
  /// every future plan has to remember, and the one it forgot would be the
  /// method that serves plant data to a client that never authenticated.
  void _on(String method, Future<Object?> Function(rpc.Parameters) handler) {
    _registered.add(method);
    peer.registerMethod(
        method,
        (rpc.Parameters params) =>
            _gated(method, () => _answer(method, () async => handler(params))));
  }

  /// As [_on], for a **notification**.
  ///
  /// json_rpc_2 has no id to answer a notification with, so a gate refusal
  /// raised here cannot reach the client — and must not reach the error
  /// handler once per frame either (05-REVIEW WR-03). Thrown, it went to
  /// `onUnhandledError` and `reportToStderr` wrote the message *and a full
  /// stack trace*, with no rate limit and no dedup, for a condition any peer
  /// that completes the WebSocket upgrade can produce at line rate.
  ///
  /// So the refusal is dropped rather than thrown: counted in
  /// [droppedHoldTicks], which is what a tick the handler cannot use is
  /// counted in everywhere else, and reported once per session. A pre-hello
  /// tick has no hold to feed, so there is nothing else to do with it.
  void _onNotification(
      String method, Future<Object?> Function(rpc.Parameters) handler) {
    _registered.add(method);
    peer.registerMethod(method, (rpc.Parameters params) async {
      // The awaiting-sign-in condition rides beside the handshake gate for
      // the same reason it rides inside `_gated`: a session nobody signed in
      // on has no hold to feed either, and a refusal with no id to answer is
      // dropped-and-counted the same way a pre-hello one is.
      if (_gate.checkRequest(method) is! GateAllow ||
          _identity == SessionLoginValidator.awaitingSignIn) {
        _ungatedNotifications++;
        if (!_complainedUngated) {
          _complainedUngated = true;
          // `StackTrace.empty` is the deliberate spelling: the line is the
          // whole report, and `reportToStderr` skips the trace for it. A
          // trace here would point at json_rpc_2's dispatch and say nothing
          // the message does not.
          _onError?.call(
              'a "$method" notification arrived before hello and was dropped: '
              'a pre-hello tick has no hold to feed. Further ones on this '
              'session are counted in droppedHoldTicks and not reported '
              'again',
              StackTrace.empty,
              'notification gate');
        }
        return null;
      }
      return _answer(method, () async => handler(params));
    });
  }

  void _start() {
    _lastSeen.gateOn(() => helloed);
    // Every one of these goes through `_on`, and there is no second path.
    //
    // The table is forty-four names. Phase 3 registered four; 04-02 added
    // `write`, `writeStatus`, `read`, `readFresh` and `readMany`, pulled
    // forward from Phase 5 because 04-RESEARCH Finding 4 ran the method sweep
    // against a live gateway and found all five answering `-32601`, which put
    // 28 of the contract suite's 44 checks out of reach over the real
    // transport. Only the plumbing moved: Phase 5 still owns write *semantics*
    // (three-state depth beyond forwarding, idempotency windows, hold-to-run)
    // and Phase 6 owns authorization. 10-02 added the four `browse.*` names in
    // `_registerDataServices` below, which retired six of the thirteen checks
    // the contract legs had been proving unreachable; 10-03's timeseries four,
    // which retired three more; 10-04's history-view eleven, which retired
    // two; and 10-05's preferences fifteen, which retired the last two and
    // closed the table at forty-three callable names; 14-12 reopened it for
    // exactly one, `ackAlarm`, the first operator action on this wire that is
    // not a write. 03-08's rule stands —
    // the set is frozen against a hand-written literal in `surface_test.dart`
    // so each addition is a deliberate edit to a test that explains its cost.
    final handlers = SessionHandlers(
      api: api,
      config: config,
      handles: handles,
      buffer: buffer,
      subscriptions: subscriptions,
      // The epoch is minted by `hello`, which cannot have run yet; the gate
      // guarantees no subscribe reaches a handler before it has.
      epochOf: () => _epoch ?? '',
    );
    // The handlers are per session; the outcome log they write to is not.
    // 04-REVIEW CR-02: `writeStatus` is only ever asked by a client that has
    // just reconnected, so a per-socket log was empty every time it was
    // consulted and answered `not_received` — the one verdict that licenses
    // re-actuating a machine — for the commands whose fate was unknown.
    // T-04-05's cross-client concern is answered in `write_outcome_log.dart`:
    // the `cmd` is an 80-bit-random ULID, and Phase 6's identity narrows it
    // further without moving the log back inside a socket's lifetime.
    final values = ValueHandlers(
      api: api,
      config: config,
      now: _now,
      outcomes: _writeOutcomes,
      // Minted by `hello`, which cannot have run yet — read through a callback
      // for the same reason the epoch is.
      ownerOf: () => _sessionId,
      // The session's own policy view answers, so the null-identity decision
      // lives in exactly one place (`policy_state_man.dart`'s `identityOf`)
      // and the read surfaces and the write gate cannot drift apart about it.
      //
      // **`canWrite` alone, deliberately — not `canSee && canWrite`.** A key
      // this station may not see is already gone from `api.keys` and is
      // refused as nonexistent *above* this gate, so anding in visibility
      // would be dead code in the good case and, if the two checks were ever
      // reordered, would answer `forbidden` for a hidden key — the one answer
      // that leaks the existence the hiding rule conceals.
      canWriteKey: api.canWrite,
    );
    // The alarm methods, built beside the value ones and given the **same
    // expression** for their gate rather than a copy of the role comparison.
    // That is the whole of T-14-49's mitigation: the ack and the write ask one
    // object the same question, so a policy change moves both at once and
    // neither can drift about what an operator is.
    //
    // `sink` may be null, and that is a deployment rather than a mistake —
    // `tfc_relay_local`'s harness and every fixture in this package build a
    // gateway with no alarm engine. The name is registered either way; see the
    // handler's null branch for why a named refusal beats `-32601` here.
    final alarms = AlarmHandlers(
      api: api,
      sink: alarmAcks,
      canWriteKey: api.canWrite,
    );
    // Kept, unlike `handlers`, because this object owns state with a lifetime:
    // the hold-to-run map. `_teardown` has to be able to release it, and the
    // fact that it hangs off a *per-session* object is what makes that release
    // free (05-RESEARCH §G.4 / D-P5-J).
    _values = values;
    _on(Methods.hello, _hello);
    _on(Methods.ping, _ping);
    // The forty-fifth and forty-sixth names (increment B of the 2026-09-08
    // no-station-file ruling): interactive sign-in and its way back down.
    // Registered through `_on` like everything else — the handshake gate
    // covers them by construction — and they are two of the three names the
    // awaiting-sign-in stage exempts, because they exist precisely for a
    // session that stage is holding.
    _on(Methods.sessionLogin, _sessionLogin);
    _on(Methods.sessionLogout, _sessionLogout);
    _on(Methods.subscribe, handlers.subscribe);
    _on(Methods.unsubscribe, handlers.unsubscribe);
    _on(Methods.write, values.write);
    _on(Methods.writeStatus, values.writeStatus);
    // 14-12, placed here so the table reads as the operator-action group it
    // belongs to. **The forty-fourth name, and the first operator action on
    // this wire that is not a write** — which is exactly why it is gated by
    // the same `canWrite` answer a write is, one line above.
    _on(Methods.ackAlarm, alarms.acknowledge);
    _on(Methods.read, values.read);
    _on(Methods.readFresh, values.readFresh);
    _on(Methods.readMany, values.readMany);
    // **The first client→server notification on this wire** (05-05). Every
    // other name above is a request; all five *sent* notifications travel the
    // other way and are asserted absent from this table. `h` is registered
    // here because that is how json_rpc_2 dispatches an un-idded frame — the
    // same `_methods[name]` lookup a request goes through — so it lands in
    // `registeredMethods` and `surface_test.dart` keeps it in a literal of its
    // own rather than in the nine names a client may *call*.
    //
    // It comes through `_onNotification` — the same gate and the same armor
    // as `_on`, with the one difference a notification forces. **D-P5-H**: a
    // tick arriving before `hello` is still refused — right, since a
    // pre-hello tick has no hold to feed — and the refusal *evaporates*
    // instead of being answered, because the frame has no id for a response
    // to name. That is the one asymmetry in this table: every other gate
    // refusal is visible to the client. What `_onNotification` changes is
    // where the refusal goes on this side: dropped and counted, with one
    // summary line per session, rather than thrown once per frame into the
    // error handler (05-REVIEW WR-03).
    _onNotification(Methods.holdTick, values.holdTick);
    // Kept, like `values` and for the same reason: this object owns state with
    // a lifetime — one listener on the gateway's shared preference store — and
    // `_teardown` has to be able to take it off again.
    final data = _data = DataHandlers(
      source: api,
      config: config,
      resolver: resolver,
      // **The one thing this object may do to the peer**, and it is a closure
      // rather than the peer itself so that `data_handlers.dart`'s first rule
      // — nothing in that file registers anything — stays true by
      // construction.
      //
      // Three guards, and the third is the one a reader will not guess.
      // `sendNotification` on a closed peer is a `StateError`; a session in
      // teardown has nothing left to send through; and **a session that has
      // not said `hello` is told nothing at all**. Preference keys are the
      // gateway's own configuration vocabulary — `key_mappings` names itself —
      // and announcing them to a socket that has not authenticated is a
      // disclosure nothing else on this wire makes. The frame is *dropped*
      // rather than queued, because a peer that never authenticates would
      // otherwise accumulate the name of every preference on the gateway;
      // `DataHandlers._flush` clears its buffer before consulting this, which
      // is what makes the drop free.
      notify: (method, params) {
        if (_closed || peer.isClosed || _sessionId == null) return;
        // The awaiting-sign-in session is helloed, so the `_sessionId` guard
        // above no longer covers it — and the disclosure argument is the
        // same: preference keys are the gateway's configuration vocabulary,
        // and nobody has signed in on this socket. Dropped, not queued, for
        // the reason the pre-hello drop gives.
        if (_identity == SessionLoginValidator.awaitingSignIn) return;
        peer.sendNotification(method, params);
      },
    );
    _registerDataServices(data);
    // 17-09: the access twenty-eight, built beside `DataHandlers` and, like
    // it, handed **`api` — the decorator — and never `_source`**. That one
    // word is the whole difference between a gated family and an ungated
    // one, and `access_handlers_test.dart` pins it structurally AND
    // behaviourally because the mistake is invisible at runtime until
    // somebody has the wrong permissions. Not held on a field: unlike
    // `_values` and `_data` this object owns no state with a lifetime, so
    // there is nothing for `_teardown` to release.
    _registerAccessFamilies(AccessHandlers(source: api));
    // After the registrations, and outside them: registering a method and
    // attaching a listener are two different acts, and only one of them is the
    // access-control decision `_registerDataServices` documents.
    data.watchPreferences();
    // Method-not-found. **This fallback's armor is inert, and the code below
    // is kept anyway** (06-04, 06-RESEARCH §H.2, measured).
    //
    // The comment here used to claim that "a registered fallback puts that
    // refusal back inside `_answer`'s armor". It does not.
    // `Server._tryFallbacks` (`json_rpc_2-4.1.0/lib/src/server.dart:301-318`)
    // catches an `RpcException` from a fallback and, when its code is
    // `METHOD_NOT_FOUND`, treats it as *this fallback declined* and moves to
    // the next one:
    //
    //     } on RpcException catch (error) {
    //       if (error.code != error_code.METHOD_NOT_FOUND) rethrow;
    //       return tryNext();
    //     }
    //
    // Ours throws exactly that code, so it is swallowed there. The iterator
    // then exhausts and json_rpc_2 throws its own
    // `RpcException.methodNotFound(name)` with `data == null`
    // (`exception.dart:33-34`), which `serialize` fills with the raw request
    // (`:46-57`). Nobody noticed because the two messages are byte-identical
    // — a probe reading the message alone cannot tell which one answered; the
    // tell is that `data` carries no `"method"` key, so `_substitute` never
    // ran.
    //
    // **The property is enforced by `_defuse` instead**, at the ingress
    // boundary, where an unencodable frame is refused before it can be echoed
    // at all — which is the honest place for it, since "should an unknown
    // method echo its request?" is answered no for every method rather than
    // per handler.
    //
    // The registration stays, and its code stays `METHOD_NOT_FOUND`. 06-04
    // gave two reasons for keeping it and **one of them has since been
    // spent**, so the next reader is owed both halves rather than a list they
    // would find half-true.
    //
    // The spent one: the contract kit's `expectUnreachableMethod` pins
    // `-32601` exactly, and while the gateway still had thirteen data-service
    // names nothing answered, that pin was how each gap was *proved* rather
    // than assumed. Phase 10 closed the table — all thirty-four are registered
    // above — and both socket legs now pass their fifty checks with an empty
    // gap list, so there is no longer a gap for the exactness to prove. The
    // parameter that carried them is retained with an empty set so a future
    // gap has a mechanism instead of a precedent (10-05), but nothing is
    // riding on this code today.
    //
    // The standing one, and the reason the registration is not vestigial: a
    // fallback that declines is the correct behaviour for a name this session
    // does not serve. It is only the *armor* that is inert, not the answer —
    // deleting it would not change what a client sees, and it would leave the
    // next reader to rediscover `Server._tryFallbacks` from scratch when they
    // wonder where the refusal comes from.
    //
    // It does not gate: an unknown name is unknown whether or not the client
    // has said hello, and answering "unknown method" before the handshake
    // tells an attacker nothing it could not learn by reading this file.
    peer.registerFallback((rpc.Parameters params) async {
      throw rpc.RpcException(rpc_errors.METHOD_NOT_FOUND,
          'Unknown method "${params.method}".',
          data: _substitute(params.method));
    });
    unawaited(peer.listen().then(
        (_) => _transportEnded(),
        onError: (Object _) => _transportEnded()));
  }

  /// The data services, **named one registration at a time**.
  ///
  /// Not a loop over a map of name → closure, and the argument is
  /// `served_state_man.dart:366-372`'s, which this whole file family copies:
  /// the registration **is** the access-control decision (T-02-22), so a loop
  /// would move the list of what this peer answers out of the place a reviewer
  /// reads and into a place a caller supplies. Thirty-four lines when the
  /// table is closed, and every one of them a line somebody had to write.
  ///
  /// Through [_on] like everything else, with no second path
  /// (`subscribe_test.dart:450-453`). `_on` is what applies the handshake gate
  /// and the error armor; `peer.registerMethod` here would register an
  /// **ungated** method, and `ws_malformed_test.dart:529-593`'s pre-hello
  /// sweep is a sweep rather than a list precisely so it catches one.
  ///
  /// 10-02 registered four of the thirty-four; 10-03 added the timeseries four
  /// and 10-04 the history-view eleven, which was nineteen; 10-05 adds the
  /// preferences fifteen and **closes the table** — all thirty-four
  /// data-service methods are here, and there is no thirty-fifth to add. The
  /// one notification they send is attached in [_start] rather than here, next
  /// to the callback it sends through.
  void _registerDataServices(DataHandlers data) {
    _on(DataServiceMethods.browseFetchRoots, data.browseFetchRoots);
    _on(DataServiceMethods.browseFetchChildren, data.browseFetchChildren);
    _on(DataServiceMethods.browseFetchDetail, data.browseFetchDetail);
    _on(DataServiceMethods.browseResolvePath, data.browseResolvePath);
    _on(DataServiceMethods.timeseriesQuery, data.timeseriesQuery);
    _on(DataServiceMethods.timeseriesQueryMultiple,
        data.timeseriesQueryMultiple);
    _on(DataServiceMethods.timeseriesQueryDownsampled,
        data.timeseriesQueryDownsampled);
    _on(DataServiceMethods.historyCreateView, data.historyCreateView);
    _on(DataServiceMethods.historyUpdateView, data.historyUpdateView);
    _on(DataServiceMethods.historyDeleteView, data.historyDeleteView);
    _on(DataServiceMethods.historySelectViews, data.historySelectViews);
    _on(DataServiceMethods.historyGetKeys, data.historyGetKeys);
    _on(DataServiceMethods.historyGetGraphs, data.historyGetGraphs);
    _on(DataServiceMethods.historyGetKeyNames, data.historyGetKeyNames);
    _on(DataServiceMethods.historyAddPeriod, data.historyAddPeriod);
    _on(DataServiceMethods.historyDeletePeriod, data.historyDeletePeriod);
    _on(DataServiceMethods.historyListPeriods, data.historyListPeriods);
    _on(DataServiceMethods.historyRetentionHorizon,
        data.historyRetentionHorizon);
    // The preferences fifteen, which close the table. **Seven of these are
    // the only names on this wire a `view` station may not call**: the
    // registration is the access-control decision, and the decision itself —
    // reads for everyone, writes for `operate` — landed one commit earlier in
    // `_PolicyPreferences`, because a handler that is ungated for the length
    // of one commit is a handler that was ungated.
    _on(DataServiceMethods.prefGetKeys, data.prefGetKeys);
    _on(DataServiceMethods.prefGetAll, data.prefGetAll);
    _on(DataServiceMethods.prefGetBool, data.prefGetBool);
    _on(DataServiceMethods.prefGetInt, data.prefGetInt);
    _on(DataServiceMethods.prefGetDouble, data.prefGetDouble);
    _on(DataServiceMethods.prefGetString, data.prefGetString);
    _on(DataServiceMethods.prefGetStringList, data.prefGetStringList);
    _on(DataServiceMethods.prefContainsKey, data.prefContainsKey);
    _on(DataServiceMethods.prefSetBool, data.prefSetBool);
    _on(DataServiceMethods.prefSetInt, data.prefSetInt);
    _on(DataServiceMethods.prefSetDouble, data.prefSetDouble);
    _on(DataServiceMethods.prefSetString, data.prefSetString);
    _on(DataServiceMethods.prefSetStringList, data.prefSetStringList);
    _on(DataServiceMethods.prefRemove, data.prefRemove);
    _on(DataServiceMethods.prefClear, data.prefClear);
  }

  /// The access families, **named one registration at a time** — 17-09.
  ///
  /// [_registerDataServices]' rule, unchanged: the registration is the
  /// access-control decision (T-02-22), so the list of what this peer
  /// answers stays in the place a reviewer reads. Twenty-eight lines, in
  /// `AccessMethods` order, so the block reads as the wire surface an access
  /// review walks — and through [_on] like everything else, with no second
  /// path, because `_on` is what applies the handshake gate and the error
  /// armor. `peer.registerMethod` here would be an **ungated** access
  /// method, which is the largest privilege hole this wire could grow.
  ///
  /// The table reopened at forty-four names (14-12's `ackAlarm` was the
  /// forty-fourth callable) and closes again at seventy-two: nine template,
  /// eleven admin, three audit reads, five config. There is no
  /// `accessTemplates.template` — the audit cut it (no caller anywhere,
  /// its own store included) — and no `audit.record`: the relay writes its
  /// own rows server-side, and a wire method a client could write a row
  /// through would be a forgery surface, not a trail.
  void _registerAccessFamilies(AccessHandlers access) {
    _on(AccessMethods.templateList, access.templateList);
    _on(AccessMethods.templateBindings, access.templateBindings);
    _on(AccessMethods.templateKeysBoundTo, access.templateKeysBoundTo);
    _on(AccessMethods.templateCreate, access.templateCreate);
    _on(AccessMethods.templateUpdate, access.templateUpdate);
    _on(AccessMethods.templateRename, access.templateRename);
    _on(AccessMethods.templateDelete, access.templateDelete);
    _on(AccessMethods.templateBind, access.templateBind);
    _on(AccessMethods.templateUnbind, access.templateUnbind);
    _on(AccessMethods.adminRoles, access.adminRoles);
    _on(AccessMethods.adminListUsers, access.adminListUsers);
    _on(AccessMethods.adminCreateRole, access.adminCreateRole);
    _on(AccessMethods.adminUpdateRole, access.adminUpdateRole);
    _on(AccessMethods.adminDeleteRole, access.adminDeleteRole);
    _on(AccessMethods.adminRenameRole, access.adminRenameRole);
    _on(AccessMethods.adminCreateUser, access.adminCreateUser);
    _on(AccessMethods.adminDeleteUser, access.adminDeleteUser);
    _on(AccessMethods.adminSetUserRole, access.adminSetUserRole);
    _on(AccessMethods.adminSetUserStationAccount,
        access.adminSetUserStationAccount);
    _on(AccessMethods.adminSetUserPassword, access.adminSetUserPassword);
    _on(AccessMethods.auditEntries, access.auditEntries);
    _on(AccessMethods.auditMemberCountsByAction,
        access.auditMemberCountsByAction);
    _on(AccessMethods.auditDistinctWho, access.auditDistinctWho);
    _on(AccessMethods.configRead, access.configRead);
    _on(AccessMethods.configValidate, access.configValidate);
    _on(AccessMethods.configWrite, access.configWrite);
    _on(AccessMethods.configPrevious, access.configPrevious);
    _on(AccessMethods.configRestorePrevious, access.configRestorePrevious);
  }

  /// The client's end vanished — a graceful close, a reset, a yanked cable.
  ///
  /// **This is a teardown, not just a completion, and that is the 03-11 fix.**
  /// Before it, the peer's listen completing merely completed [closed] and the
  /// server released the connection; nothing ever called [close], so
  /// `subscriptions.clear()` never ran and every listener the session had
  /// attached to the backing source stayed attached. `teardown_test.dart`
  /// measured the consequence at 2.50 leaked listeners per kill cycle — one
  /// per subscribed key — which over a day of flapping plant network is a
  /// gateway pushing values for panels that went home.
  ///
  /// **With no close code, deliberately.** A code recorded here would be a
  /// code the server never sent, and `ConnectionClose` distinguishes "we
  /// evicted it" from "it left" by exactly that field. A ledger that invented
  /// one would make every disconnect look deliberate, and "it left" and "we
  /// evicted it for backpressure" call for opposite operator responses.
  void _transportEnded() =>
      unawaited(_teardown(null, 'the client\'s transport ended'));

  /// Applies the handshake gate to [method] before [work] runs.
  ///
  /// The switch is exhaustive over `GateAction` with no default arm, so a new
  /// verdict added to the gate is a compile error here rather than a request
  /// that quietly proceeds.
  Future<Object?> _gated(String method, Future<Object?> Function() work) async {
    final action = _gate.checkRequest(method);
    switch (action) {
      case GateAllow():
        _refuseWhileAwaitingSignIn(method);
        return await work();
      case GateReject(:final kind):
        throw rpc.RpcException(
            kind == 'already_helloed'
                ? ServerErrorCodes.alreadyHelloed
                : ServerErrorCodes.helloRequired,
            '$method refused: $kind',
            data: _substitute(method));
      case GateClose(:final closeCode, :final supported, :final requested):
        _requestClose(closeCode, 'protocol mismatch');
        throw rpc.RpcException(
            ServerErrorCodes.versionMismatch, '$method refused: no common '
                'protocol version',
            data: {
              ..._substitute(method),
              'supported': supported,
              'requested': requested,
            });
      case GateClosed():
        throw rpc.RpcException(ServerErrorCodes.helloRequired,
            '$method refused: this session has been closed',
            data: _substitute(method));
      case GateAccept():
        // Unreachable from `checkRequest`, which never accepts — acceptance is
        // `negotiate`'s answer and belongs to the hello handler. Named anyway,
        // because that is what makes the switch total.
        return await work();
    }
  }

  /// Refuses [method] while this session's identity is the awaiting-sign-in
  /// sentinel — the second stage of the gate, and the fail-closed half of
  /// the credential-less admission `SessionLoginValidator` makes.
  ///
  /// **Why the empty group set is not enough on its own.** The sentinel's
  /// session holds no groups, so every write question already answers no —
  /// but reads are deliberately ungated on this wire (`key_policy.dart`,
  /// §11's deferral: `canSee` filters, there is no read gate), so a session
  /// graded only by its groups could still subscribe to every tag, read
  /// every preference and walk the browse tree while nobody has signed in.
  /// "Nobody yet" is an *authentication* state, and it is answered here, at
  /// the same single choke point the handshake gate uses — before params
  /// are decoded, ahead of every handler, covering a method added next year
  /// by construction. It grades no key and names no group, which is what
  /// keeps it the credential mechanism's business rather than a second
  /// policy (`no_second_policy_test.dart`'s constitution).
  ///
  /// `hello` is exempt because the first hello runs while `_identity` is
  /// still null (and a second one is the gate's `already_helloed` refusal
  /// before this is ever consulted); `ping` is exempt because a panel
  /// sitting at the sign-in screen is waiting, not broken, and reaping it
  /// for silence would darken every idle station. `session.login` and
  /// `session.logout` are exempt because they are the two methods the
  /// awaiting state exists FOR: the login is how it ends, and the logout is
  /// idempotent on nobody so a panel that cannot know whether a reconnect
  /// already reset the far end may always send it.
  ///
  /// The refusal is `unauthorized` with a stable `awaiting_sign_in` marker:
  /// what a panel does with it is show the sign-in screen, not an error.
  void _refuseWhileAwaitingSignIn(String method) {
    if (method == Methods.hello ||
        method == Methods.ping ||
        method == Methods.sessionLogin ||
        method == Methods.sessionLogout) {
      return;
    }
    if (_identity != SessionLoginValidator.awaitingSignIn) return;
    throw rpc.RpcException(
        ServerErrorCodes.unauthorized,
        '$method refused: awaiting_sign_in — nobody has signed in on this '
        'session, and a session nobody signed in on may do nothing but '
        'wait. Sign in first',
        data: _substitute(method));
  }

  /// Answers [method], with every failure turned into an encodable error.
  ///
  /// The wrapper exists for one reason, and it is the trap 02-05 documented on
  /// the write path: `RpcException.serialize` copies the offending **request**
  /// into the error response unless `data` already carries a `request` key
  /// (`json_rpc_2-4.1.0/lib/src/exception.dart:46-57`), and json_rpc_2's own
  /// wrapping of an uncaught error does the same. A request that `jsonEncode`
  /// cannot re-emit — one carrying an Infinity decoded from `1e999` — therefore
  /// produces an error response that cannot be sent, the refusal is thrown away
  /// inside the peer, and the caller waits forever on a path with no deadline.
  /// Substituting `request` here is what keeps the answer sendable, so a
  /// failure arrives as a failure.
  ///
  /// [TypeError] keeps its own code on the way out, because it is what a typed
  /// decode throws when a client sends a field of the wrong type, and that is
  /// a different instruction to the client than "the server broke".
  Future<Object?> _answer(String method, Future<Object?> Function() work) async {
    try {
      return await work();
    } on rpc.RpcException catch (error) {
      // A handler that supplied its own `data` has already thought about the
      // echo; one that did not must not be allowed to make that choice by
      // omission. Six refusals in `session_handlers.dart` did exactly that,
      // and each of them was a hang waiting for a request that carried
      // `1e999` in any sibling field. Substituting *here* — at the choke point
      // every handler's failure passes through — is what makes the property
      // structural instead of a rule each future handler has to remember.
      if (error.data != null) rethrow;
      throw rpc.RpcException(error.code, error.message,
          data: _substitute(method));
    } on TypeError catch (error) {
      throw rpc.RpcException(ServerErrorCodes.typeMismatch, '$error',
          data: _substitute(method));
    } catch (error) {
      throw rpc.RpcException(
          ServerErrorCodes.handlerFailed, '$method failed: $error',
          data: _substitute(method));
    }
  }

  static Map<String, Object?> _substitute(String method) => {
        'method': method,
        'request': 'omitted: echoing a request that may carry a non-finite '
            'number is what makes the error itself unencodable, and an '
            'unencodable error on a path with no deadline is a hang',
      };

  /// The station label an unlabelled login's audit rows carry. Self-naming,
  /// [SessionLoginValidator.station]'s reason: it reaches the trail and must
  /// read as "the panel did not say", never as a station somebody configured.
  static const String unlabelledStation = 'unlabelled-panel';

  /// The audit trail's `station` column for this login: the panel's own
  /// claim about WHERE it stands, trimmed and capped — a location label,
  /// exactly what a direct-mode panel writes from its own hostname. Never an
  /// identity: who signed in is [_loginVerifier]'s answer alone, and no
  /// length of string here can influence it.
  static String _stationLabelOf(SessionLoginParams login) {
    final label = login.station?.trim() ?? '';
    if (label.isEmpty) return unlabelledStation;
    // The close-reason clamp's neighbourhood: a station label rides in close
    // reasons ("credential revoked for station …", capped at 123 bytes) and
    // in every audit row, so a pasted megabyte must not become either.
    return label.length > 63 ? label.substring(0, 63) : label;
  }

  /// One auth row, never a precondition: the trail is an account of
  /// decisions, and a sink that throws must not turn a verified sign-in
  /// into a refusal (the app's `_record` makes the same trade, same words).
  Future<void> _recordAuth(AuditRecord entry) async {
    try {
      await _audit.record(entry);
    } catch (error, stack) {
      _onError?.call(error, stack, 'session auth audit row');
    }
  }

  /// `session.login` — a person (or, at commissioning, the integrator
  /// holding a station account's password) signing in over the socket.
  ///
  /// **The server verifies; the panel decides nothing.** The password is
  /// checked through [_loginVerifier] (Argon2id behind the `AuthProvider`
  /// seam), the account is resolved user → role → groups through
  /// [_loginAccounts] — the same cache the revocation sweep judges by — and
  /// the answer is what was RESOLVED, never what was claimed. The heavy
  /// derivation runs here, post-hello, where `TokenValidator.validate`'s
  /// no-event-loop-await constraint does not bind (the constraint exists for
  /// the hello/reload interleaving; a login races nothing but itself, and
  /// the once-only + re-check-after-the-await discipline below covers that).
  ///
  /// **One identity per session.** Allowed only while the identity is the
  /// awaiting-sign-in sentinel. A station-credential session is refused by
  /// name: signing a person in OVER a station's base identity is elevation
  /// semantics — stacked identities with a revert — and the
  /// remove-station-credential design defers that whole (§5) rather than
  /// half-shipping it. A second login after a first is refused the way a
  /// second hello is.
  ///
  /// **Never the password anywhere.** It is decoded, handed to the verifier,
  /// and discarded; no refusal message, no audit row and no log line carries
  /// it — `session_login_ws_test.dart` drives a distinctive secret through
  /// every refusal path and sweeps.
  Future<Object?> _sessionLogin(rpc.Parameters params) async {
    if (_identity != SessionLoginValidator.awaitingSignIn) {
      throw _notSignInable();
    }
    final verifier = _loginVerifier;
    if (verifier == null) {
      throw rpc.RpcException(
          ServerErrorCodes.unauthorized,
          'session.login refused: ${SessionAuthMarkers.signInNotServed} — '
          'this gateway was composed without a sign-in verifier, so there '
          'is nothing to check a password against. A deployment fact, not '
          'a credential verdict',
          data: _substitute(Methods.sessionLogin));
    }
    // Sanitized like every ingress decode; a wrong-typed field lands on
    // `_answer`'s TypeError arm as a typed refusal.
    final login = SessionLoginParams.fromJson(
        (sanitize(params.asMap).value as Map).cast<String, Object?>());
    final station = _stationLabelOf(login);

    final AuthenticatedUser? verified;
    try {
      verified = await verifier.authenticate(login.username, login.password);
    } catch (_) {
      // Infrastructure, not a credential — and NO audit row, deliberately:
      // a database blip is not somebody trying to get in, and a trail full
      // of phantom failed attempts during an outage is a trail nobody
      // reads. The thrown error is not interpolated: an upstream message
      // can carry addresses and paths, and this one travels to a panel.
      throw rpc.RpcException(
          ServerErrorCodes.unauthorized,
          'session.login refused: '
          '${SessionAuthMarkers.userSourceUnavailable} — verification could '
          'not be attempted. This is the gateway\'s user source, not the '
          'credential that was typed',
          data: _substitute(Methods.sessionLogin));
    }

    // Re-check after the await — `_hello`'s own discipline, for the same
    // field: two logins racing through a slow verifier both pass the guard
    // at the top in one turn, and the assignment happens in another. The
    // loser costs itself a refusal, never the session.
    if (_identity != SessionLoginValidator.awaitingSignIn) {
      throw _notSignInable();
    }

    if (verified == null) {
      await _recordAuth(AuditRecord.loginFailed(
        who: login.username,
        station: station,
        actionId: newActionId(),
        origin: 'relay',
      ));
      // One message for an unknown username and a wrong password: two would
      // let anybody at the panel enumerate which usernames exist.
      throw rpc.RpcException(
          ServerErrorCodes.unauthorized,
          'session.login refused: ${SessionAuthMarkers.badCredentials} — '
          'the username or password was not recognised',
          data: _substitute(Methods.sessionLogin));
    }

    // The verifier said who; the account cache says what that is right now.
    // The CACHE's row is what the identity is minted from, because the
    // cache is what the revocation sweep re-resolves against — minting from
    // a fresher source would build sessions the next tick retires.
    ResolvedUser? resolved;
    final resolve = _loginAccounts;
    if (resolve != null) {
      try {
        resolved = resolve(verified.username);
      } catch (_) {
        resolved = null;
      }
    }
    if (resolved == null) {
      // Verified but not resolvable: no seam wired, the cache has not
      // caught up, or the source threw. Fail closed with the
      // infrastructure marker — the password was RIGHT, and saying
      // otherwise sends the person to reset it.
      throw rpc.RpcException(
          ServerErrorCodes.unauthorized,
          'session.login refused: '
          '${SessionAuthMarkers.userSourceUnavailable} — the account was '
          'verified but could not be resolved to a role and its grants, '
          'and a session elevated against an unresolved account would be '
          'a grant nobody made',
          data: _substitute(Methods.sessionLogin));
    }

    final identity = StationIdentity(
      user: resolved.user,
      station: station,
      session: AccessSession(user: resolved.user, groups: resolved.groups),
    );
    // The two assignments and the family construction are `_hello`'s
    // TokenAccepted arm, one provenance over: identity and digest written
    // together (no digest — no credential is at rest anywhere, which is
    // increment C's still-open decision, not an oversight), and the
    // per-identity families built once, for the verified person (D-11).
    _identity = identity;
    _credentialDigest = null;
    _scoped = _accessFor?.call(identity);

    await _recordAuth(AuditRecord.login(
      who: resolved.user.username,
      station: station,
      roleName: resolved.user.roleName,
      actionId: newActionId(),
      origin: 'relay',
    ));

    return SessionLoginResult(user: resolved.user, groups: resolved.groups)
        .toJson();
  }

  /// The refusal for a login on a session that is not the sentinel: a
  /// station-credential session by name, anything else as a second login.
  rpc.RpcException _notSignInable() {
    if (_credentialDigest != null) {
      return rpc.RpcException(
          ServerErrorCodes.unauthorized,
          'session.login refused: '
          '${SessionAuthMarkers.stationCredentialSession} — this session '
          'authenticated with a station credential at hello, and signing a '
          'person in over a station\'s base identity is deferred elevation '
          'semantics. Clear the station credential file on this panel and '
          'reconnect to sign in over the socket',
          data: _substitute(Methods.sessionLogin));
    }
    return rpc.RpcException(
        ServerErrorCodes.unauthorized,
        'session.login refused: ${SessionAuthMarkers.alreadySignedIn} — '
        'somebody is already signed in on this session. Sign out first',
        data: _substitute(Methods.sessionLogin));
  }

  /// `session.logout` — back to nobody, never to a direct-mode-shaped
  /// anonymous.
  ///
  /// Idempotent on a session that is already the sentinel: the panel that
  /// calls this cannot know whether a reconnect already reset the far end,
  /// and refusing would make every sign-out after a link flap an error
  /// toast. A station-credential session is refused by name — its identity
  /// came from `hello` and lives as long as the socket; "signing it out"
  /// would strand a wall panel below its own mounted credential.
  ///
  /// What ends with the sign-out, in fail-safe order: the subscriptions are
  /// cleared server-side (a session returned to nobody must stop being fed
  /// the plant — the same disclosure rule the awaiting gate enforces on the
  /// request path), and any engaged hold starves within its own deadman
  /// window, because the awaiting condition in `_onNotification` drops the
  /// ticks — the feed's whole safety property is that it STOPS.
  Future<Object?> _sessionLogout(rpc.Parameters params) async {
    final current = _identity;
    if (current == null || current == SessionLoginValidator.awaitingSignIn) {
      // Already nobody. No row: there is nobody to attribute one to.
      return null;
    }
    if (_credentialDigest != null) {
      throw rpc.RpcException(
          ServerErrorCodes.unauthorized,
          'session.logout refused: '
          '${SessionAuthMarkers.stationCredentialSession} — this session '
          'authenticated with a station credential at hello, and a station '
          'has nothing to sign out: its identity lives as long as the '
          'socket',
          data: _substitute(Methods.sessionLogout));
    }
    await _recordAuth(AuditRecord.logout(
      who: current.user.username,
      station: current.station,
      roleName: current.session.roleName,
      actionId: newActionId(),
      origin: 'relay',
    ));
    _identity = SessionLoginValidator.awaitingSignIn;
    _credentialDigest = null;
    _scoped = null;
    subscriptions.clear();
    return null;
  }

  /// The handshake. Credential first, version second, identity third.
  ///
  /// The order matters: a rejected credential must not advance the gate's
  /// state, or a client that failed to authenticate would have spent the one
  /// `hello` the session allows.
  Future<Object?> _hello(rpc.Parameters params) async {
    // Every decode on the ingress path is sanitized first: `jsonDecode('1e999')`
    // yields Infinity silently, and Infinity anywhere in a value the server
    // later re-emits is a frame that cannot be encoded.
    final decoded = sanitize(params.asMap).value as Map;
    final hello = HelloParams.fromJson(decoded.cast<String, Object?>());

    // **The credential is checked once per session — and once means once
    // across the `await` below, not merely once per turn.**
    //
    // The check has to be *before* the gate: a rejected credential must not
    // spend the one `hello` the session allows. So a second `hello` does reach
    // the validator on a session that already has an identity, and there is
    // nothing left for the validator to decide there. Two things went wrong
    // when it was consulted anyway:
    //
    //  * A second `hello` carrying another station's **valid** token
    //    overwrote the field. A view station could talk itself into an operate
    //    identity on a handshake the gate then refuses, and the refusal would
    //    not matter, because the damage is the field rather than the answer.
    //  * A second `hello` carrying an **invalid** token reached
    //    `TokenRejected` and closed the socket with 4001 — tearing down a
    //    session that authenticated correctly and has been serving the plant,
    //    for a frame that gets `alreadyHelloed` when the token happens to be
    //    good. Only the peer can do that to itself, but a client with a state
    //    bug should not be able to disconnect itself over a field the server
    //    has already decided.
    //
    // **The guard below is only half of the answer, and the comment here used
    // to claim it was the whole one.** It is around the check rather than
    // around its result, which is right — but it is evaluated in one turn and
    // the assignment happens in another, after `validator.validate`. Two
    // hellos that both reach this line before either resumes both pass it, and
    // both failures above come straight back: `json_rpc_2` does not await its
    // dispatch (`server.dart:115`), and a JSON-RPC **batch** runs its members
    // through `Future.wait` (`:175-181`), which makes the interleaving
    // deterministic in a single frame. Two separate frames do the same against
    // any validator that suspends on an event rather than on a microtask —
    // the very implementation `token_validator.dart:39-62` warns about for the
    // revocation sweep, biting the identity itself.
    //
    // So the invariant is re-checked *after* the await as well. This is the
    // session's instance of **re-check after the await**;
    // `value_handlers.dart`'s hold store carries the other one, and the two
    // are one idea: a synchronous guard, a suspend, and a write that assumed
    // the guard still held.
    if (_identity == null) {
      final verdict = await validator.validate(hello);
      if (_identity != null) {
        // This call lost. It is refused **with a response and never a close**
        // — that is the whole of the second failure above, and restoring a
        // `_requestClose` here would restore it exactly.
        //
        // `alreadyHelloed` deliberately, because it is the code a *sequential*
        // second hello already gets (`_gate.negotiate` answers `GateReject`
        // below). A client that says hello twice sees one answer for it
        // whether the frames raced or not, and the timing it lost by is not a
        // fact it has to model.
        //
        // Returned before `_gate.negotiate`: the winner spent the gate's one
        // slot, and running `negotiate` for the loser would advance gate state
        // on behalf of a handshake that is being refused. The verdict above is
        // discarded on purpose — accepted or rejected, there is nothing left
        // for it to decide.
        throw rpc.RpcException(
            ServerErrorCodes.alreadyHelloed,
            'hello refused: already_helloed — another hello on this session '
            'was accepted while this one was still with the credential '
            'validator. The session keeps the identity that handshake set',
            data: _substitute(Methods.hello));
      }
      switch (verdict) {
        case TokenRejected(:final reason):
          _requestClose(CloseCodes.authExpired, 'credential rejected');
          throw rpc.RpcException(
              ServerErrorCodes.unauthorized, 'hello refused: $reason',
              data: _substitute(Methods.hello));
        case TokenAccepted(:final identity, :final credentialDigest):
          // Here rather than in the `GateAccept` arm below, which is what
          // keeps the ordering this method argues for true by construction:
          // the identity is recorded the moment the credential is accepted
          // and before the protocol is, so nothing can observe a session with
          // a protocol and no identity.
          //
          // The two assignments are one fact and are written together: a
          // session carrying one hello's identity and another's digest is a
          // session the revocation sweep would judge on a credential it is
          // not using.
          _identity = identity;
          _credentialDigest = credentialDigest;
          // Beside the identity, and only ever here: the per-identity
          // template/admin/config families are constructed once, for the
          // verified station (D-11). The once-only guard above is what makes
          // "once" true for this line too — a batched hello that could replace
          // the identity could replace the families the audit rows attribute
          // to.
          //
          // Never for the awaiting-sign-in sentinel: the factory builds
          // stores whose audit rows attribute to the identity it was called
          // with, and nobody is not an identity a row may name (D-11). The
          // gate holds every access method away from an awaiting session
          // anyway; leaving `_scoped` null keeps the shared source's
          // refuse-by-name behind it, fail closed twice over.
          _scoped = identity == SessionLoginValidator.awaitingSignIn
              ? null
              : _accessFor?.call(identity);
      }
    }

    final action = _gate.negotiate(hello);
    switch (action) {
      case GateAccept(:final protocol):
        _protocol = protocol;
        final id = newUlid();
        _sessionId = id;
        _epoch = newUlid();
        // The handshake starts the heartbeat clock. Inbound frames do not
        // move `lastSeen` until this line has run (05-REVIEW WR-03), and the
        // `hello` frame itself arrived before it — so without this a panel
        // that took ten seconds to connect would begin its session already
        // ten seconds silent, and be reaped for the silence that preceded its
        // own handshake.
        _lastSeen.touchNow();
        return HelloResult(
          protocol: protocol,
          server: const PeerInfo('tfc-relay-gateway', '0.1.0'),
          // An open map, and it stays one (04-RESEARCH A4): the live handshake
          // returns `{}` today, so every key added here is additive and no
          // deployed client has to know about it. A typed DTO would make the
          // next key a breaking change.
          //
          // `tickMs` is the gateway's real cadence, from the config this
          // session was built with. The client's per-subscription staleness
          // arithmetic is derived from it (Finding 5), and the alternative —
          // a constant on the client that must match a server config nobody
          // diffs — fails silently a year later, as values an operator
          // believes are fresh.
          //
          // `heartbeatDeadlineMs` is the same argument about a different
          // number, and it is the panel's own survival number: nothing this
          // gateway *sends* keeps a session alive — only inbound application
          // frames move `_lastSeen` — so a panel that is merely watching a
          // page has to beat on a schedule derived from this deadline or the
          // reaper takes it one deadline after its handshake, for ever, at a
          // full page resync per cycle. That is not hypothetical: it is what
          // this build did before there was a pump to advertise it to
          // (07-08-SUMMARY deviation 3). Both keys are read from the config
          // this session was built with, never from a literal.
          capabilities: {
            HelloCapabilities.tickMs: config.tick.inMilliseconds,
            HelloCapabilities.heartbeatDeadlineMs:
                config.heartbeatDeadline.inMilliseconds,
            // The verified account's username, so the panel's attribution
            // prose can name the account instead of a machine id (the rig
            // rendered a bare container id). Advisory display material —
            // see `HelloCapabilities.account` — and OMITTED for the
            // awaiting-sign-in sentinel: nobody is not an account, and
            // printing the sentinel's self-naming string as one would be
            // the lie its names exist to prevent. `_identity` is non-null
            // here by the credential-first ordering above.
            if (_identity != SessionLoginValidator.awaitingSignIn)
              HelloCapabilities.account: _identity!.user.username,
          },
          sessionId: id,
          epoch: _epoch!,
          // This used to also send `resumed: false`, under a comment saying
          // nothing was resumable "until 03-09" — a phase that came and went
          // eight phases ago, leaving a wire field that was hardcoded on one
          // side, never set on the other, and read by nobody in between.
          //
          // **Session resume was withdrawn in Phase 16 (HARD-03), not
          // deferred again.** Honouring it means retaining this session's
          // subscription state across a socket loss and replaying from a
          // per-subscription `lastSeq`; that is delta replay, and this
          // product's doctrine is snapshot-never-replay (CLAUDE.md). So the
          // field could not have been implemented without implementing the
          // thing the architecture refuses, and leaving it standing was the
          // worse option: a client told its cache survived when it did not
          // shows stale plant data under a healthy-looking link, which is the
          // exact failure this gateway exists to prevent.
          //
          // The reasoning, and the fork it resolves, are in
          // `.planning/phases/16-transport-hardening/16-CONTEXT.md`. A future
          // milestone that wants resume starts from the doctrine question, not
          // from this field.
          //
          // `sessionId` and `epoch` stay, and they are the load-bearing half:
          // the client feeds `epoch` straight into `ResyncEngine.onHello`.
          serverTime: _now(),
          // Read from the config this session was built with, never a
          // literal, and omitted from `toJson` when null — so a deployment
          // that configures none sends the frame it always sent.
          publisherId: config.publisherId,
        ).toJson();
      case GateClose(:final closeCode, :final supported, :final requested):
        _requestClose(closeCode, 'no common protocol version');
        throw rpc.RpcException(ServerErrorCodes.versionMismatch,
            'hello refused: no common protocol version',
            data: {
              ..._substitute(Methods.hello),
              'supported': supported,
              'requested': requested,
            });
      case GateReject(:final kind):
        throw rpc.RpcException(ServerErrorCodes.alreadyHelloed,
            'hello refused: $kind',
            data: _substitute(Methods.hello));
      case GateClosed():
        throw rpc.RpcException(ServerErrorCodes.helloRequired,
            'hello refused: this session has been closed',
            data: _substitute(Methods.hello));
      case GateAllow():
        // `negotiate` never merely allows; it accepts, rejects or closes.
        throw StateError('the gate allowed a hello without negotiating it');
    }
  }

  /// The app-level heartbeat. Answers with the server's clock so a client can
  /// re-derive its offset without a second handshake.
  ///
  /// **And it is the gateway's certificate deadline check.** The cert-health
  /// overlay has no timer, by a ruling `teardown_test.dart` enforces, so it
  /// recomputes on a deadline consulted by requests that already run — and
  /// every one of those is a request that reads a *key*. An established panel
  /// holding its subscriptions sends none of them: `ping` all shift, and a
  /// `writeStatus` sweep after a reconnect. That is a night shift, not an
  /// untrafficked gateway, so the heartbeat carries the check.
  /// **And it is where the delivery ack is ingested** (16-02-DECISION §5.1).
  ///
  /// `poll` can measure how much this gateway has *produced* for a client and
  /// nothing else: `dart:io` exposes no `bufferedAmount` and no `flush`
  /// (flutter#103306), so 9.5 MiB piled into an unread socket while every
  /// `addStream` returned in 0 ms — measured, not assumed, along with the
  /// refutation of the `sink.done` liveness option this file used to
  /// recommend. The only party that knows what was *delivered* is the party
  /// that read it, so it is asked, on the beat it is already sending.
  ///
  /// **A malformed ack must never cost a panel its socket.** This is the frame
  /// that stops the reaper; a decode that threw here would turn a cosmetic
  /// client bug into a disconnect every heartbeat. `PingParams.fromJson`
  /// degrades every malformation to "no ack for that subscription", and the
  /// `is Map` guard below covers the shape json_rpc_2 would otherwise refuse
  /// on our behalf with `invalidParams`.
  ///
  /// **No clock crosses this call.** `ConflatingSendBuffer.recordAck` once
  /// declared a `nowMs` parameter that nothing read — dead since 16-08's own
  /// `51d6941c`, the fix that removed the duplicate window reset so the
  /// recovery branch in `_deliveryVerdict` would be reachable — and its own
  /// doc asked the next visitor to implement §5.2's `ackedMovedAtMs` or
  /// delete the parameter. Deleted: a dead argument that looks load-bearing
  /// is how the wrong clock gets chosen quietly. If that field ever becomes
  /// live, the instant to hand it is [_monotonicNow] and not [_now] — the
  /// window this feeds is closed by `buffer.poll(nowMs)` under
  /// `TickEngine.tickOnce(now())`, and two clocks either side of one
  /// subtraction is how a wall-clock step becomes an eviction (the failure
  /// `clock_offset.dart` and `HeartbeatPump._now` are both already about).
  ///
  /// No sanitize pass: `PingParams` accepts `int` and nothing else, so the
  /// `1e999` → `Infinity` poison is dropped at the decode rather than being
  /// clamped into a client claiming it is perfectly caught up.
  Future<Object?> _ping(rpc.Parameters params) async {
    _health?.refreshIfDue();
    final raw = params.value;
    if (raw is Map) {
      final ack = PingParams.fromJson(raw.cast<String, Object?>()).ack;
      if (ack.isNotEmpty) {
        for (final entry in ack.entries) {
          // Scoping is `recordAck`'s rule 3 and stays there: an ack naming a
          // subscription this session does not hold creates no entry, so the
          // map cannot be grown by whatever a peer puts in an ack on a path
          // that runs every heartbeat.
          buffer.recordAck(entry.key, entry.value);
        }
      }
    }
    return {'serverTime': _now()};
  }

  /// One last `tick` naming where each subscription got to, into the priority
  /// lane, for a **planned** drain only.
  ///
  /// ## What it is for
  ///
  /// [CloseCodes.serverDraining] means "reconnect, do not alarm", and until
  /// this existed that was all it meant: a panel coming back after a deploy
  /// could not tell a sequence it missed from one that never happened, so it
  /// could not say whether the numbers still on its screen were the last ones
  /// this gateway evaluated. That is T-08-48 — a client left unable to account
  /// for what it missed — and the fix is one frame naming the last `seq` per
  /// subscription.
  ///
  /// ## Planned only
  ///
  /// A heartbeat timeout, a backpressure eviction, a dead socket and a client
  /// that walked away all reach [_teardown] too, and none of them may produce
  /// this frame: a tick after an abrupt drop is a claim about state nobody
  /// verified, sent down a link the gateway has just decided it cannot trust.
  /// The `code == serverDraining` test is the whole of the distinction.
  ///
  /// ## Its own frame, and never the close reason
  ///
  /// Into the priority lane, where `_Connection.closeSocket`'s existing flush
  /// puts it on the wire *before* `sink.close`. That ordering is already
  /// load-bearing for the refusals that explain a close, so this rides a seam
  /// that is tested rather than inventing one.
  ///
  /// **It must never be spliced into the close reason.** RFC 6455 caps a
  /// reason at 123 UTF-8 bytes and `package:web_socket` enforces the cap with
  /// an `ArgumentError` that lands inside `closeSocket`'s `try` and is
  /// swallowed as "the far end is already gone" — so the close a gateway
  /// believes it sent was never sent, and the session lives on. Phase 6 paid
  /// for that discovery once. A sequence number in the reason would put every
  /// planned drain one long station name away from paying for it again.
  ///
  /// Built through [TickParams] rather than concatenated, unlike
  /// `TickEngine._writeTick`: that one runs for every subscription of every
  /// session on every tick and the encode is the cost being avoided. This runs
  /// once per session, ever.
  void _writeFinalTick() {
    final subs = subscriptions.subscriptions;
    if (subs.isEmpty) return;
    final at = _now();
    buffer.putPriority(jsonEncode({
      'jsonrpc': '2.0',
      'method': Methods.tick,
      'params': TickParams(
        serverTime: at,
        subs: {
          for (final state in subs)
            state.sub: SubTick(seq: state.seq, evaluatedAt: at),
        },
      ).toJson(),
    }));
  }

  /// Records [code] and schedules the teardown for after the answer.
  ///
  /// Recorded synchronously, torn down on the next turn of the event loop: the
  /// refusal that explains the close is still being written when this is
  /// called, and closing the peer underneath it would leave the client
  /// disconnected with no idea why — which is the failure this whole close-code
  /// discipline exists to prevent.
  void _requestClose(int code, String reason) {
    _sentCloseCode ??= code;
    Timer.run(() => unawaited(close(code, reason)));
  }

  /// Stops serving, in the order Finding 9 measured. Idempotent.
  ///
  /// The code is recorded first so it is readable even if the transport is
  /// already gone; the peer is closed next, which is what stops handlers from
  /// running; the transport is closed last, with the code, because a socket
  /// closed before the peer swallows the peer's final frames.
  ///
  /// **Everything before the first `await` is the synchronous half, and that
  /// is deliberate.** A close decided inside a tick — a backpressure eviction,
  /// the heartbeat reaper — must take the session out of the registry in the
  /// same turn it was decided in. This method is a `Future` because it has to
  /// await the peer, and a caller that only `unawaited`s it would otherwise
  /// leave a window in which the server is still selecting a client it has
  /// already given up on: the next tick fans out to it, the reaper sweeps it,
  /// and the frames go to a socket that is halfway through closing.
  Future<void> close(int code, String reason) => _teardown(code, reason);

  /// The one teardown, and the only thing in this class that releases
  /// anything.
  ///
  /// **Four callers, one body.** The heartbeat sweep, a backpressure verdict
  /// (`applyVerdict`), a protocol refusal (`_requestClose`) and an explicit
  /// server drain all arrive here through [close]; a dead transport arrives
  /// through [_transportEnded]. Five paths and one guard is what makes
  /// "released exactly once" a property of the class rather than a rule each
  /// caller has to remember — and the fifth path is the one that was missing,
  /// which is precisely why it leaked.
  ///
  /// [code] is null when the *client* ended the connection: see
  /// [_transportEnded]. A null code skips step 6 — there is no socket left to
  /// carry it and no decision of ours to announce.
  ///
  /// **Finding 9's order, and every step of it is load-bearing:**
  ///
  ///  1. the close code is recorded *first*, so it is readable even if the
  ///     transport is already gone (Finding 6 / `web_socket_channel` #1698);
  ///  2. the registry entry comes out next, synchronously — see below;
  ///  3. every subscription is detached from the backing `StateManApi`, because
  ///     a listener still attached keeps pushing this client's values into a
  ///     buffer that will never be drained again;
  ///  4. `await peer.close()`, which is what stops handlers from running;
  ///  5. the transport closes last, *with* the code, because a socket closed
  ///     before the peer swallows the peer's final frames — including the
  ///     refusal that explains the close;
  ///  6. the buffer is released, and only now: `_Connection.closeSocket`
  ///     flushes the priority lane on its way out, so a buffer emptied before
  ///     step 5 would throw away the very frame that tells the client why it
  ///     was disconnected. Handles are **not** released — permanence is the
  ///     03-CONTEXT ruling, and `teardown_test.dart` asserts the table's size
  ///     is constant across two hundred cycles rather than returning to
  ///     baseline.
  ///
  /// **Everything before the first `await` is the synchronous half, and that
  /// is deliberate.** A close decided inside a tick — a backpressure eviction,
  /// the heartbeat reaper — must take the session out of the registry in the
  /// same turn it was decided in. This method is a `Future` because it has to
  /// await the peer, and a caller that only `unawaited`s it would otherwise
  /// leave a window in which the server is still selecting a client it has
  /// already given up on: the next tick fans out to it, the reaper sweeps it,
  /// and the frames go to a socket that is halfway through closing.
  Future<void> _teardown(int? code, String reason) async {
    if (_closed) return;
    _closed = true;
    if (code != null) _sentCloseCode ??= code;
    _onClosing?.call(this);
    // Before `subscriptions.clear()` below, because it is the subscriptions
    // that are being named. See [_writeFinalTick].
    if (code == CloseCodes.serverDraining) _writeFinalTick();
    // In the synchronous half, and beside `subscriptions.clear()` because it
    // is the same kind of debt: a listener still attached pushes values at a
    // panel that is gone, and a hold still engaged pushes a *counter* at a
    // machine on behalf of one. The second is the one that moves metal, so it
    // must not wait for the peer to close — this line is what makes "the app
    // was killed / the cable was pulled / the reaper swept it" all stop the
    // jog, since every one of those arrives here (T-05-20, D-P5-J).
    _values?.releaseAllHolds();
    subscriptions.clear();
    // Beside `subscriptions.clear()` because it is the same debt on a
    // different stream: this session attached its own listener to the
    // gateway's **one shared** preference store, and a listener left attached
    // keeps buffering keys and pushing `preferences.changed` at a panel that
    // is gone. `teardown_test.dart` measures it as a rate across kill cycles,
    // the way the value path's 2.50-per-cycle leak was measured in 03-11.
    //
    // The awaited half is only the `cancel`; everything that matters
    // synchronously — the released flag and the buffered keys — is dropped
    // before this returns, so a flush already scheduled finds nothing to send.
    await _data?.releasePreferenceWatch();
    await peer.close();
    if (code != null) await _closeChannel?.call(code, reason);
    // Step 6. `drain()` is the only release the buffer offers — it empties
    // both lanes and hands back what it held, which is discarded here because
    // by this line there is nowhere left to send it. The reference itself is
    // final and cannot be nulled; it does not need to be, because the session
    // left the registry at step 2 and the buffer goes wherever the session
    // goes. What must not survive is the *contents*: a conflated frame per
    // subscribed handle, held for a client that is gone.
    buffer.drain();
    if (!_done.isCompleted) _done.complete();
  }
}

/// The session's source, with the identity-scoped families swapped in —
/// and everything else forwarded untouched.
///
/// Sits **under** the policy decorator, deliberately: the decorator's family
/// gates read `source.accessTemplates` through a thunk evaluated per call,
/// after the gate, so a scoped family served from here is graded exactly as
/// the shared one would be. Putting the scoping *above* the decorator — say,
/// handing the factory's families to `AccessHandlers` directly — would be a
/// family the gate never sees, which is the one-word bypass this whole file
/// spends its comments warning about.
///
/// Hand-written forwarding, no `noSuchMethod`, on `PolicyStateMan`'s own
/// argument: a member added to `StateManApi` in a later phase must be a
/// compile error here, so somebody decides whether it needs scoping, rather
/// than a silent pass-through nobody reviewed. Eighteen members; fifteen
/// forward.
///
/// [_scopedOf] is read late, per call — the `identityOf` idiom — because
/// this object is built before `_hello` mints anything. Before the handshake
/// it answers the shared source's families, which the handshake gate keeps
/// unreachable from the wire anyway; `audit` always forwards, because it is
/// sessionless (17-06 wired the audit family at composition). `backendConfig`
/// is scoped like the other two — the store attributes accepted and refused
/// writes to the verified identity (17-10, D-11) — with the shared source as
/// the fallback when the factory hands none, which on the shipped backend is
/// refuse-by-name (fail closed).
final class _IdentityScopedSource implements StateManApi {
  _IdentityScopedSource(this._inner, this._scopedOf);

  final StateManApi _inner;
  final IdentityAccessFamilies? Function() _scopedOf;

  @override
  AccessTemplateApi get accessTemplates =>
      _scopedOf()?.accessTemplates ?? _inner.accessTemplates;

  @override
  AccessAdminApi get accessAdmin =>
      _scopedOf()?.accessAdmin ?? _inner.accessAdmin;

  @override
  AuditApi get audit => _inner.audit;

  @override
  BackendConfigApi get backendConfig =>
      _scopedOf()?.backendConfig ?? _inner.backendConfig;

  @override
  ValueListenable<DynamicValue> listen(String key) => _inner.listen(key);

  @override
  Stream<DynamicValue> subscribe(String key) => _inner.subscribe(key);

  @override
  DynamicValue? read(String key) => _inner.read(key);

  @override
  Future<DynamicValue> readFresh(String key) => _inner.readFresh(key);

  @override
  Future<Map<String, DynamicValue>> readMany(List<String> keys) =>
      _inner.readMany(keys);

  @override
  Future<WriteResult> write(String key, Object? value,
          {Object? expect, String? cmd}) =>
      _inner.write(key, value, expect: expect, cmd: cmd);

  @override
  Future<List<WriteResult>> writeStatus(List<String> cmds) =>
      _inner.writeStatus(cmds);

  @override
  Future<HoldHandle> holdToRun(String key) => _inner.holdToRun(key);

  @override
  List<String> get keys => _inner.keys;

  @override
  BrowseApi get browse => _inner.browse;

  @override
  TimeseriesApi get timeseries => _inner.timeseries;

  @override
  HistoryViewApi get historyViews => _inner.historyViews;

  @override
  PreferencesApi get preferences => _inner.preferences;

  @override
  Future<void> dispose() => _inner.dispose();
}

/// The listening end: a shelf HTTP server whose one route upgrades WebSocket
/// connections, and one [RelaySession] per upgraded connection.
///
/// This file is where the three pieces the rest of the package builds
/// separately are finally wired together — the send buffer, the session sink
/// and the channel adapter — and it is the only place in the package that
/// knows a socket exists. `RelaySession` deliberately does not (see its own
/// doc): that is what lets every session property be asserted over an
/// in-memory pair in milliseconds, and it is why this file's own test file is
/// short.
///
/// **The accepted divergence from design §5.** The design says the fan-out
/// tick should "drain when the previous write completes", and `dart:io`
/// WebSockets offer no way to know when that is: no `bufferedAmount`, no
/// `flush()`, and an `add` that returns `void` (03-RESEARCH Finding 5, option
/// (a); 03-CONTEXT records the decision). So the safety net is the other one
/// the design already carries — tick-paced draining plus
/// `ConflatingSendBuffer`'s own `poll` verdicts, which measure the backlog the
/// server can see rather than the one the kernel is holding. This is a
/// recorded decision, not an omission, and anyone who later finds a genuine
/// completion signal on this transport should revisit it here first.
///
/// **The single outbound chokepoint.** [writeFrame] is the only function in
/// this package that calls `ws.sink.add`. Everything the server says — RPC
/// answers, write acks, status, and from 03-07 the drained telemetry frame —
/// goes through it, because a second write path is a frame that skips the
/// buffer and therefore skips backpressure accounting entirely.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:stream_channel/stream_channel.dart';
// Narrowed to the sink names, `relay_session.dart`'s discipline: the server
// wires the trail, the decorator writes it, and the master system's wider
// vocabulary stays out of this file.
import 'package:tfc_access/tfc_access.dart' show AuditSink, NullAuditSink;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'alarm_ack_sink.dart';
import 'auth/file_token_validator.dart';
import 'auth/session_login_validator.dart';
import 'error_reporter.dart';
import 'handle_table.dart';
import 'health/cert_health_state_man.dart';
import 'health/session_health_state_man.dart';
import 'policy/key_policy.dart';
import 'policy/series_mapping_tally.dart';
import 'relay_session.dart';
import 'server_config.dart';
import 'session_sink.dart';
import 'tick_engine.dart';
import 'token_validator.dart';
import 'write_outcome_log.dart';
import 'ws_channel.dart';

/// Writes one already-encoded frame to [socket].
///
/// **The one `ws.sink.add` in this package.** Named, top-level and boring on
/// purpose: `grep -rn "sink.add" lib/src/` is meant to return exactly this
/// line, so "does anything bypass the send buffer?" is a question with a
/// mechanical answer. 03-07's tick engine writes its drained frames through
/// here.
void writeFrame(WebSocketChannel socket, String frame) =>
    socket.sink.add(frame);

/// The sessions a server is currently holding.
///
/// A thin holder rather than a bare `List`, for two reasons that arrive later:
/// 03-05 hangs subscription counts off it and 03-11's reaper sweeps it. What
/// it owes today is a count a test can read and the two events a fixture needs
/// to know when a connection has appeared or gone — polling for either is how
/// a socket test becomes a timing test.
final class SessionRegistry {
  final _sessions = <RelaySession>[];
  final _opened = StreamController<RelaySession>.broadcast();
  final _gone = StreamController<RelaySession>.broadcast();

  /// How many sessions are live right now.
  int get sessionCount => _sessions.length;

  /// The live sessions, in the order they connected.
  List<RelaySession> get sessions => List.unmodifiable(_sessions);

  /// Fires once per session, as it is registered.
  Stream<RelaySession> get opened => _opened.stream;

  /// Fires once per session, as it is removed.
  Stream<RelaySession> get gone => _gone.stream;

  void add(RelaySession session) {
    _sessions.add(session);
    if (!_opened.isClosed) _opened.add(session);
  }

  void remove(RelaySession session) {
    if (!_sessions.remove(session)) return;
    if (!_gone.isClosed) _gone.add(session);
  }

  /// Releases the event controllers. The sessions themselves are closed by
  /// [RelayServer.close], which calls this last.
  Future<void> dispose() async {
    _sessions.clear();
    await _opened.close();
    await _gone.close();
  }
}

/// How one connection ended, from both sides.
///
/// Both fields exist because they disagree, and the disagreement is the point.
/// A code the server *sent* is recorded by the session; a code the server
/// *observed* on its own socket is only meaningful when the client initiated
/// the close — after a self-initiated close it is `null`
/// (`web_socket_channel` #1698). So a record with a `serverCloseCode` and no
/// `clientCloseCode` is an eviction, and the reverse is a client that went
/// away. Anything that reads only one field cannot tell those apart, and they
/// call for opposite operator responses.
final class ConnectionClose {
  const ConnectionClose({this.clientCloseCode, this.serverCloseCode});

  /// What this end's socket observed. Trustworthy only for a close the client
  /// initiated; 1005 there means "went away with no status".
  final int? clientCloseCode;

  /// What the session recorded itself as sending, or null if it sent nothing.
  final int? serverCloseCode;

  @override
  String toString() => 'ConnectionClose(client: $clientCloseCode, '
      'server: $serverCloseCode)';
}

/// The gateway's listening end.
///
/// ```dart
/// final server = RelayServer(api: stateMan, config: ServerConfig());
/// await server.start();
/// print('listening on ${server.port}');
/// ```
final class RelayServer {
  RelayServer({
    required this.api,
    ServerConfig? config,
    HandleTable? handles,
    TokenValidator validator = permissiveDefault,
    this.policy = const AccessPolicyKeyPolicy(),
    this.alarmAcks,
    this.audit = const NullAuditSink(),
    this.accounts,
    this.accessFor,
    required this.resolver,
    this.serverSupported = const [protocolVersion],
    this.onError = reportToStderr,
    int Function()? now,
  })  : config = config ?? ServerConfig(),
        handles = handles ?? HandleTable(),
        _configured = validator,
        _now = now ?? _wallClock {
    if (this.config.auth != null && !identical(validator, permissiveDefault)) {
      throw ArgumentError('this RelayServer was given both a '
          'ServerConfig.auth (${this.config.auth!.tokenFilePath}) and an '
          'explicit validator (${validator.runtimeType}). Two sources of '
          'truth for the credential check is a configuration nobody can '
          'reason about, and the one that wins would be an implementation '
          'detail. Remove whichever is not the deployment: drop `validator:` '
          'to use the token file, or drop `ServerConfig.auth` to use the '
          'validator you built');
    }
    writeOutcomes =
        WriteOutcomeLog(ttl: this.config.writeOutcomeTtl, now: _now);
  }

  /// The permissive validator every caller gets when it configures none.
  ///
  /// A named constant rather than an inline `const PermissiveTokenValidator()`
  /// because the constructor tells "you configured nothing" from "you
  /// configured a validator" by **identity** against this object. Dart
  /// canonicalises const instances, so a caller that writes
  /// `validator: const PermissiveTokenValidator()` — `ws_harness.dart:212`
  /// does, for every fixture in the package — is passing this very object and
  /// is correctly read as having configured nothing. The permissive default
  /// carries no truth, so it cannot be the second source of one.
  static const TokenValidator permissiveDefault = PermissiveTokenValidator();

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  /// Wall-clock epoch milliseconds, injectable so a test can age the outcome
  /// log with arithmetic rather than a sleep.
  final int Function() _now;

  /// What became of every write this gateway has handled recently.
  ///
  /// **Per server, not per session** (04-REVIEW CR-02). `writeStatus` is only
  /// ever asked by a client that has just reconnected, so a log that died with
  /// the socket was empty every single time it was consulted — and an empty log
  /// answered `not_received`, the one verdict that licenses re-actuating a
  /// machine, about commands the gateway had received and forwarded. The
  /// argument in full is in `write_outcome_log.dart`.
  late final WriteOutcomeLog writeOutcomes;

  /// What this gateway has been asked for that it has no series mapping for.
  ///
  /// **One per gateway, and the surface an engineer reads.** The wire answer
  /// for an unmappable series is deliberately indistinguishable from a series
  /// that does not exist (T-10-12), so this is the only place the gap is
  /// visible — see [SeriesMappingTally] for both halves of that argument.
  /// 10-07 builds the real resolver over 8b's collection plan and 10-10 the
  /// reader; both read this to tell "nothing recorded" from "never mapped".
  /// Announced through [onError] with [StackTrace.empty] — the package's one
  /// notification seam, and the shape `error_reporter.dart` reserves for a
  /// *condition* a peer can produce at will rather than a defect. Once per
  /// distinct name, never per query: a dashboard polling one broken chart is
  /// one mapping gap, not one a second.
  late final SeriesMappingTally seriesTally =
      SeriesMappingTally(report: onError);

  /// The last subscription generation this gateway minted.
  int _generations = 0;

  /// Where this server reports an error nobody asked for: an unhandled peer
  /// error, a session that threw inside the tick, a sweep that failed.
  ///
  /// Defaults to [reportToStderr] rather than to null, because the alternative
  /// is the state this package shipped in — every failure swallowed, and a
  /// gateway that cannot say what went wrong. A test supplies a collector and
  /// asserts on it; an embedder supplies its own logger.
  final RelayErrorHandler onError;

  /// The subprotocol this gateway answers to, when a client asks for one.
  ///
  /// Panels do not: `WebSocketChannel.connect` sends no
  /// `Sec-WebSocket-Protocol` header unless told to, and `shelf_web_socket`
  /// then selects none and sends none back. It is declared so that a browser
  /// client — Phase 6's web bundle — can pin the protocol it expects and be
  /// refused early rather than after a hello it cannot parse.
  static const subprotocol = 'tfc-relay.v1';

  /// The source every session serves. One instance, shared: two panels
  /// watching one motor must be served by one upstream subscription.
  final StateManApi api;

  final ServerConfig config;

  /// The server-global key→handle table, shared across sessions so an
  /// encode-once body stays byte-identical for every client that gets it.
  final HandleTable handles;

  /// The credential check every session on this gateway runs.
  ///
  /// The validator the caller configured until [start] builds one from
  /// [ServerConfig.auth], and that one afterwards. Read through the getter
  /// rather than captured, because `_onConnect` runs long after `start` and a
  /// session built against the pre-start value would be permissive on a
  /// gateway that is not.
  TokenValidator get validator => _loaded ?? _configured;

  final TokenValidator _configured;

  /// The validator [start] read out of [ServerConfig.auth], if there was one.
  TokenValidator? _loaded;

  /// Which tags each station may see and actuate (SEC-03, CONTEXT decision 2).
  ///
  /// A construction argument in [validator]'s style, and for the same two
  /// reasons: a deployment supplies its own, and the shipped default stays
  /// legible in a config diff because it is named for what it does. Unlike
  /// the validator there is no both-sources-of-truth refusal to make — a
  /// policy has no `ServerConfig` counterpart, since 06-CONTEXT deliberately
  /// does not define a pattern grammar this phase.
  ///
  /// Handed to every session, where a per-session `PolicyStateMan` wraps the
  /// shared [api] with it. The wrapping is per session because the question is
  /// per *identity* — [api] is one instance shared by every panel on this
  /// gateway, which is the whole reason the policy cannot live inside it.
  final KeyPolicy policy;

  /// The alarm engine an accepted `ackAlarm` is handed to, if this deployment
  /// has one.
  ///
  /// A construction argument in [policy]'s style — a deployment supplies its
  /// own, and this package cannot name an alarm engine because the engine lives
  /// in `tfc_dart`, which depends on this package. See [AlarmAckSink].
  ///
  /// **Optional, and the optionality is the compatibility property.** 14-12
  /// added a name to the wire, not a version: `protocolVersion` and `hello` are
  /// untouched, and every existing embedder — `tfc_relay_local`'s harness,
  /// `ws_harness.dart`, every fixture in this package — constructs a
  /// `RelayServer` without this argument and keeps compiling with no edit. A
  /// gateway built that way still *registers* `ackAlarm` and refuses it by
  /// name, which is what keeps "this gateway serves no alarm engine"
  /// distinguishable from "this gateway is too old to know the word".
  final AlarmAckSink? alarmAcks;

  /// Where every session's authorization verdicts become rows (D-05, 17-09).
  ///
  /// [NullAuditSink] by default, so every existing composition in the
  /// workspace is unaffected — the trail is an account of decisions, never a
  /// precondition for making them. `composeBackendRelay` (17-11) injects the
  /// same `DriftAuditSink` shape the app's provider builds, writing the same
  /// `audit_entry` table, so one SELECT answers for panel and wire alike.
  /// Threaded to every session's `PolicyStateMan` in [_onConnect]; the arm
  /// that proves the threading measures rows through *this* class rather
  /// than through a directly-built decorator, because "a composition nothing
  /// assembles is a composition nothing tests" (Phase 10, CR-01).
  final AuditSink audit;

  /// Where a token file's usernames become accounts and groups (D-06,
  /// 17-04b's `UserResolver`).
  ///
  /// Nullable at construction and **required the moment [config] names a
  /// token file** — [start] refuses the combination, because a token file
  /// with no resolver behind it is a list of usernames nobody can grade.
  /// There is deliberately no permissive fallback, on
  /// `FileTokenValidator`'s own reasoning about a misspelled PEM: a gateway
  /// that admitted every panel because somebody forgot this argument would
  /// look perfectly healthy from every screen in the plant. 17-11 fills it
  /// from `AccessRepository`, cached in memory on the same cadence the
  /// token reload uses.
  final UserResolver? accounts;

  /// Builds each session's per-identity template/admin families at `hello`
  /// (D-11) — see [AccessScopeFactory]. Forwarded to every session exactly
  /// as [validator] and [policy] are; null leaves the shared source's own
  /// families answering, which on the shipped backend is 17-03b's
  /// refuse-by-name. 17-11 fills it from the moved stores.
  final AccessScopeFactory? accessFor;

  /// How a browse node id and a database table name become a plant key.
  ///
  /// **Required, with no default, and that is the decision.** [validator] had
  /// the same choice and took the other branch: `PermissiveTokenValidator` is
  /// a named default, so a deployment still running it in Phase 12 says so in
  /// a config diff. A permissive *resolver* would not be legible that way —
  /// nothing in the configuration would name it and nothing in a log would
  /// show it — and what it would silently do is map every table to a key that
  /// exists, which serves history for tags the identity may not see.
  ///
  /// 10-CONTEXT amendment 6 makes an unmappable table fail-closed: it is not
  /// served until it is mapped. A fail-closed rule with a permissive default
  /// is a rule that holds until somebody forgets a constructor argument, so
  /// there is no default to forget. There is also no implementation of
  /// [SeriesResolver] in any relay package's `lib/` — a sweep in
  /// `handler_table_test.dart` asserts it — which means a caller cannot
  /// satisfy this parameter without having built or chosen a mapping.
  ///
  /// **Not on [ServerConfig].** Config is data a deployment writes in a file;
  /// this is an object built from the keymappings the composition root has
  /// already loaded (10-07 builds the real one over 8b's collection config,
  /// which names both the plant key and the `gw_`-prefixed table).
  ///
  /// Forwarded to every session, which hands it to its `PolicyStateMan` and
  /// its `DataHandlers`.
  final SeriesResolver resolver;

  /// The protocol versions this build can speak, newest last.
  final List<String> serverSupported;

  final SessionRegistry _sessions = SessionRegistry();
  final _connections = <_Connection>[];
  final _closeLedger = <ConnectionClose>[];

  HttpServer? _http;
  var _closed = false;

  /// Whether [announceDraining] has been called. See it for why this is not
  /// [_closed].
  var _draining = false;

  /// The gateway's own health producer, or null on a plaintext gateway.
  ///
  /// Built by [start] from the very [TlsConfig] the `SecurityContext` is built
  /// from — one instance for the server, shared by every session, for the same
  /// reason [api] is — and **only** when there is a certificate to report on.
  /// A plaintext gateway has none, so it grows no key, which is what keeps
  /// every existing fixture in this package byte-identical (06-03 measured the
  /// cost of the opposite at 53 cases).
  ///
  /// Public because a deployment may want the number recomputed on a cadence
  /// of its own — `certHealth?.refresh()` — the same seam and the same
  /// argument [reloadTokens] carries for the credential file. It holds no
  /// timer; see `session_health_state_man.dart` for why.
  ///
  /// **Still per server, and still the only certificate producer** after
  /// 08-12's merge. What changed is that it is no longer the thing in the
  /// chain slot: each session's own overlay sits there and forwards this key
  /// here, so one `refresh()` still pushes to every panel subscribed to it
  /// rather than to one store per panel.
  CertHealthStateMan? get certHealth => _certHealth;
  CertHealthStateMan? _certHealth;

  /// The one tick engine, built by [start] and stopped by [close].
  ///
  /// Exactly one per server, holding the server's only timer and the one
  /// [FrameEncoder] whose cache is shared by every session that ticks
  /// together — that sharing is what makes two panels watching one motor cost
  /// one encode instead of two.
  TickEngine? get engine => _engine;
  TickEngine? _engine;

  /// The sessions this server is holding.
  SessionRegistry get sessions => _sessions;

  /// How the last few connections ended, oldest first.
  ///
  /// Bounded at [_ledgerLimit]: a gateway that ran for a month would otherwise
  /// hold one record per connection ever made, which is a leak with a
  /// diagnostic excuse. What it is for is the question an operator asks after
  /// a panel drops — "did it leave, or did we evict it?" — and 03-08's
  /// close-code sweep.
  List<ConnectionClose> get closeLedger => List.unmodifiable(_closeLedger);

  static const _ledgerLimit = 64;

  /// How many connections are upgraded but have not yet said `hello`.
  ///
  /// **Derived from the connection table, never kept as a counter, and that is
  /// the decision.** A counter here has one obvious bug and one subtle one,
  /// and both are permanent: increment on connect and decrement only on
  /// `hello`, and every peer that connects and drops without speaking spends a
  /// slot of the budget for ever — a few hundred of those and the gateway
  /// refuses the entire plant while holding no sessions at all, which from
  /// outside is indistinguishable from a gateway that is fine. Decrement in
  /// both places and the two paths can still race: a session that hellos and
  /// is torn down in the same turn is decremented twice, and the budget grows
  /// past its own ceiling. A count read off [_connections] cannot drift from
  /// the table it describes, because it *is* the table.
  ///
  /// The cost is a linear scan per accepted connection, over a list bounded by
  /// the plant's panel count. Connections are rare — a panel dials once and
  /// stays for a shift — so this is microseconds on an event that happens
  /// tens of times a day, paid to remove a class of bug that would only ever
  /// be found in production.
  ///
  /// A connection whose session is still null counts as un-helloed, which is
  /// correct: it is mid-wiring or its wiring failed, and either way nothing on
  /// it has authenticated.
  int get unhelloedCount =>
      _connections.where((c) => !(c.session?.helloed ?? false)).length;

  /// The bound port. Throws before [start] has completed, because a caller
  /// that reads it early wants to be told that rather than shown a 0.
  int get port {
    final http = _http;
    if (http == null) {
      throw StateError('the server has no port until `start()` has completed; '
          'await it before reading one');
    }
    return http.port;
  }

  /// Binds [ServerConfig.address] on [ServerConfig.port] and starts accepting
  /// upgrades, over TLS when [ServerConfig.tls] says so.
  ///
  /// Loopback and port 0 are still the defaults (threat T-03-11): exposing the
  /// gateway on a public interface is a deployment decision with a firewall
  /// attached to it, not something a default should do quietly, and port 0 is
  /// so two servers can run in one test process without agreeing on a number.
  /// What Phase 6 adds is the ability for a deployment to *be* deliberate
  /// about both — the default is still not the deployment.
  ///
  /// **The `SecurityContext` is built here, not at config construction.**
  /// `useCertificateChain` reads a file and `ServerConfig` is pinned pure data
  /// (`server_config.dart:4-5`). It is also not memoised: `start()` refuses on
  /// a closed server just below, so a restarted gateway is a new object and
  /// there is nothing to reuse.
  ///
  /// **A missing or unreadable PEM lets its `FileSystemException` out.** There
  /// is deliberately no plaintext fallback: a gateway that downgraded to
  /// `ws://` because somebody misspelled a path would keep every panel working
  /// while carrying the plant's traffic in cleartext, and that is discovered
  /// by a packet capture months later. `tls == null` is the *other* thing — an
  /// explicit choice visible in a config diff.
  Future<void> start() async {
    if (_closed) {
      throw StateError('a closed RelayServer cannot be restarted: its sessions '
          'are gone and its registry is disposed. Build a new one');
    }
    // Before the bind, and deliberately before the `SecurityContext`: a
    // gateway whose credential file is unreadable must fail with no port
    // open, so nothing can connect to it during the window in which it looks
    // started. Same rule as a missing PEM, one line earlier because a token
    // file is cheaper to get wrong.
    final auth = config.auth;
    if (auth != null) {
      // The resolver check comes even before the file read: both are
      // fail-closed refusals, and this is the one whose remedy is a
      // constructor argument rather than a mount. Named twice over —
      // the parameter and its type — because the operator reading this is
      // standing at a gateway that will not start (D-06's third leg).
      if (accounts == null) {
        throw ArgumentError.value(
            null,
            'accounts',
            'this RelayServer was given a token file '
                '(${auth.tokenFilePath}) and no UserResolver. The file names '
                'usernames; without the resolver this gateway cannot learn '
                'who any of them is or what its role may do, and there is no '
                'permissive fallback — a gateway that admitted every panel '
                'because nobody wired the user source would look perfectly '
                'healthy from every screen in the plant. Pass accounts:, the '
                'way composeBackendRelay fills it from AccessRepository');
      }
      _loaded =
          await FileTokenValidator.load(auth.tokenFilePath, accounts: accounts);
    }
    // Before the bind, so it is the first thing in the log rather than a line
    // after the port is already open. `StackTrace.empty` is this package's
    // "condition, not defect" marker (05-REVIEW WR-03): it is a statement
    // about the configuration, already complete in the message, and a trace
    // would be noise.
    final exposure = exposureWarning(config);
    if (exposure != null) {
      onError(StateError(exposure), StackTrace.empty, 'bind');
    }
    final tls = config.tls;
    // `withTrustedRoots: false` on the *server* context is not the client-side
    // pinning posture repeated by mistake. A server context's trust store is
    // consulted only when verifying client certificates, which this design
    // does not do, so loading the system roots here would be surface with no
    // purpose (06-RESEARCH §A.2, measured).
    final security = tls == null
        ? null
        : (SecurityContext(withTrustedRoots: false)
          ..useCertificateChain(tls.chainPath)
          ..usePrivateKey(tls.keyPath, password: tls.keyPassword));
    // From the same TlsConfig, one line later, so the number a panel reads can
    // never be about a different file than the one the handshake presents.
    // Computed once here so the value exists before the first subscribe —
    // `fake_state_man.dart:93-107`'s argument for the other five health keys,
    // applied to the sixth.
    _certHealth = tls == null
        ? null
        : (SessionHealthStateMan(
            source: api,
            chainPath: tls.chainPath,
            nowMs: _now,
          )..refresh());
    _http = await shelf_io.serve(
      webSocketHandler(
        _onConnect,
        protocols: const [subprotocol],
        // From the config, never a literal (threat T-03-10). Empty — the
        // default — rejects every browser `Origin` with 403 and leaves
        // origin-less clients, which is what the panels are, untouched.
        allowedOrigins: config.allowedOrigins,
        // NAT keepalive, and a backstop for a client whose heartbeat logic is
        // broken while its socket still works. **Never the liveness reaper**:
        // Finding 7 measured half-open detection through the ping at 1.85x
        // the interval, which at 20 s is a ~37 s window. 03-11's app-level
        // heartbeat is the reaper.
        pingInterval: config.pingInterval,
      ),
      config.address,
      config.port,
      securityContext: security,
    );
    // After the bind, so a server that failed to bind has no timer running
    // against an empty registry, and one engine for the whole process — see
    // `tick_engine.dart` on why this is never per session.
    _engine = TickEngine(
      registry: _sessions,
      config: config,
      onSessionError: onError,
    )..start();
  }

  /// Re-reads the credential set and disconnects every station that is no
  /// longer in it, with [CloseCodes.authExpired].
  ///
  /// **In-process, and that is what makes revocation real.** A restart-to-
  /// apply design closes every session with [CloseCodes.serverDraining] (see
  /// [close]) — a code that tells a panel "reconnect, do not alarm", which is
  /// the opposite of what a revoked station should be told, and which is why
  /// 4001 stood as the last unpaid debt in `handler_table_test.dart` from
  /// Phase 3 until this method existed. It also takes the whole plant down to
  /// disconnect one panel.
  ///
  /// **Production wiring is the embedder's, deliberately.** Whatever already
  /// watches the deployment's configuration calls [FileTokenValidator
  /// .reloadIfChanged] and then this — an mtime or digest poll is enough, and
  /// is what the backend's config-watch pattern does. Three reasons this
  /// server does not own that loop: `File.watch` on a bind-mounted path in
  /// Docker is unreliable, the reload cadence is a deployment's business
  /// rather than a gateway's, and a second timer inside this process would
  /// fight the one `tick_engine.dart` argues there should only ever be one of.
  /// Tests call this directly, which is what keeps the 4001 case hermetic —
  /// no timer, no sleep.
  ///
  /// Throws a [StateError] when the live validator cannot reload, rather than
  /// no-opping: a deployment that believes rotation works and has it silently
  /// do nothing is worse off than one told at the first attempt.
  ///
  /// **The sweep is `TickEngine.reap`'s shape, safety property included.**
  /// `registry.sessions` is read fresh rather than copied — a session closed
  /// earlier in this same sweep is already gone, and closing it twice is a
  /// second teardown for a session with no resources left — and the close is
  /// `unawaited`, which is safe *precisely* because the registry removal is
  /// the synchronous half of the teardown (`relay_session.dart:911-915` runs
  /// `_onClosing?.call(this)` before the first `await`; the `onClosing:`
  /// argument in [_onConnect] documents why it must stay that way). There is
  /// deliberately no `await` inside the loop: one would let the next
  /// iteration observe a registry the previous close had not finished leaving.
  ///
  /// **No station→session index**, deliberately. Panels number in the tens, a
  /// full sweep on a file change is free, and an index would be a second
  /// place session lifetime is tracked when `_sessions.remove` is the single
  /// synchronous chokepoint the whole close path depends on.
  ///
  /// **A hello in flight cannot slip past the sweep, and the reason is a
  /// property of the validator rather than of this method.** The sweep runs
  /// after `await live.reload()`, so a session whose identity is assigned
  /// during that await would be skipped — visited while its identity was
  /// still null — and would then be handed a credential set nobody checked.
  /// It cannot happen with a validator that meets the constraint
  /// [TokenValidator.validate] states: `FileTokenValidator.validate` contains
  /// no `await`, so a hello in flight resolves in a microtask, and microtasks
  /// drain before `readAsBytes`'s completion is delivered. That constraint is
  /// written on the interface, where an implementer will read it, and pinned
  /// for this implementation by `auth_test.dart`'s "the credential check
  /// resolves without waiting on the world". Anything that awaits real work
  /// inside `validate` reopens the window, and the session that slips through
  /// keeps its access for the life of its socket.
  Future<void> reloadTokens() async {
    final live = validator;
    if (live is! RevocableTokenValidator) {
      throw StateError('this gateway\'s validator is a ${live.runtimeType}, '
          'which cannot reload. Rotation here would be a no-op: the file '
          'would be edited, nothing would happen, and nothing would say so. '
          'Configure ServerConfig.auth, or pass a validator that implements '
          'RevocableTokenValidator');
    }
    await live.reload();
    _sweepRevoked(live);
  }

  /// [reloadTokens]' cheaper sibling: one read of the file, a re-parse only
  /// when the bytes changed — and a sweep **either way**. Answers whether
  /// the bytes did change.
  ///
  /// **The call an embedder's poll should make** — and, since 17-09, the
  /// call that makes a *database* revocation take effect too. [reloadTokens]'
  /// own doc, and design §7.4, tell the embedder to call
  /// [FileTokenValidator.reloadIfChanged] first — and then [reloadTokens]
  /// re-reads the file anyway, so the intended production sequence parses it
  /// twice per change. The two reads can disagree: a file edited between them,
  /// or half-written by an editor that does not write atomically, leaves the
  /// sweep running against a credential set the `reloadIfChanged` caller never
  /// saw.
  ///
  /// **The digest guards the parse, not the sweep.** Under the user model
  /// (17-04b) most revocations never visit the file: an account deleted,
  /// re-roled, unmarked as a station, or a group unticked on its role are
  /// all `app_user`/`app_role` edits, invisible to the file digest — and
  /// after Phase 17 that role also decides `configure` and `administer`. So
  /// the sweep runs on every call, consulting the live [accounts] resolver
  /// through `stillValid`; what the unchanged digest skips is the re-parse.
  /// The sweep is a synchronous walk over tens of sessions and closes
  /// nothing whose credential still means what it meant (D-08; the arm is
  /// `session_identity_test.dart`'s "an unchanged credential closes
  /// nothing").
  ///
  /// **No production poll exists yet.** Nothing in `centroidx-backend` calls
  /// this — 17-11 wires it onto the backend's config-watch tick *and* the
  /// LISTEN/NOTIFY tick, and until it lands revocation does not happen in
  /// production. Named here so the next reader does not assume it is wired.
  ///
  /// Narrower than [reloadTokens] by necessity: `reloadIfChanged` is on
  /// [FileTokenValidator] and deliberately not on [RevocableTokenValidator]
  /// (an in-memory implementation has no digest to compare, and an interface
  /// member only one implementation can mean gets implemented as `=> true`).
  /// A gateway whose validator is something else gets the same [StateError]
  /// [reloadTokens] gives, for the same reason.
  Future<bool> reloadTokensIfChanged() async {
    final live = validator;
    // The decorator that admits credential-less hellos (increment A of the
    // no-station-file ruling) is accepted beside the bare file validator, so
    // the backend's existing poll keeps ticking the day the composition
    // wraps its validator. Its `reloadIfChanged` delegates to the wrapped
    // file when one is still configured and answers an honest false when
    // none is — and the sweep below runs either way, which is what keeps a
    // database-only demotion taking effect (the digest guards the parse,
    // never the sweep).
    // One suspension point, structurally (auth_test pins the count): the
    // branch picks which reload runs, and the single wait below is the only
    // thing the sweep is ordered behind.
    final (RevocableTokenValidator swept, Future<bool> Function() reload) =
        switch (live) {
      FileTokenValidator() => (live, live.reloadIfChanged),
      SessionLoginValidator() => (live, live.reloadIfChanged),
      _ => throw StateError('this gateway\'s validator is a '
          '${live.runtimeType}, which does not read a file and so cannot '
          'tell whether one changed. Configure ServerConfig.auth, or '
          'drive the reload yourself through reloadTokens()'),
    };
    final changed = await reload();
    _sweepRevoked(swept);
    return changed;
  }

  /// Closes every session whose credential [live] no longer honours.
  ///
  /// Synchronous, and that is the property: see [reloadTokens] on why there is
  /// no `await` in here.
  void _sweepRevoked(RevocableTokenValidator live) {
    for (final session in _sessions.sessions) {
      final identity = session.identity;
      // A pre-hello session has no credential to revoke. The gate already
      // holds it to `hello` alone and the heartbeat reaper already reaps it.
      if (identity == null) continue;
      if (live.stillValid(identity, session.credentialDigest)) continue;
      // Short on purpose: a close reason is capped at 123 bytes and the
      // station id is the variable part (see `_Connection._clampReason`, which
      // is the belt to this brace).
      // 17-07 spillover, mechanical only: `stationId` became `station` when
      // 17-04b replaced `Identity` with `StationIdentity` (see relay_session).
      unawaited(session.close(CloseCodes.authExpired,
          'credential revoked for station ${identity.station}'));
    }
  }

  /// What an operator should be told about a gateway binding off loopback
  /// with neither TLS nor a credential file, or null when there is nothing to
  /// say.
  ///
  /// A **warning, not a refusal**: cleartext and unauthenticated on a
  /// segmented network behind a firewall is a legitimate deployment, and this
  /// class has no way to know whether that is the one it is in. What it should
  /// not be is quiet — every other misconfiguration this phase can produce is
  /// refused with a paragraph attached (an empty path, a port out of range,
  /// two sources of credential truth, `wss` with no root), and
  /// `ServerConfig(address: InternetAddress.anyIPv4, port: 8443)` with both
  /// nullable halves left null was accepted in silence: cleartext,
  /// unauthenticated, writable, on every interface, with
  /// [PermissiveTokenValidator] granting `operate` to every peer that can
  /// reach the port.
  ///
  /// Static and public so a deployment can ask the question before it binds,
  /// and so a case can ask it without one.
  static String? exposureWarning(ServerConfig config) {
    if (config.address.isLoopback) return null;
    final missing = [
      if (config.tls == null) 'TLS',
      if (config.auth == null) 'a token file',
    ];
    if (missing.isEmpty) return null;
    // "every access group" and not the old "operate rights": since Phase 17
    // the permissive validator mints the FULL group set — administer and
    // users included, seven groups where there used to be one of two roles —
    // and a warning that made the smaller claim would be underselling the
    // exposure by exactly the amount this phase added (token_validator.dart's
    // "larger claim than it used to make").
    return 'binding ${config.address.address}:${config.port} with no '
        '${missing.join(' and no ')}. Every peer that can reach this port is '
        'a panel ${config.auth == null ? 'holding every access group' : 'with '
            'a credential'}'
        '${config.tls == null ? ', and every value and every write crosses '
            'the network in cleartext' : ''}. That is a legitimate deployment '
        'behind a firewall on a segmented network and this gateway cannot '
        'tell whether it is in one — so this is a warning, not a refusal. If '
        'it is deliberate, it is worth writing down somewhere the next person '
        'will look.';
  }

  /// Builds one session for one upgraded connection.
  ///
  /// Never throws. A wiring failure here would otherwise land in the ambient
  /// isolate — `socket_harness.dart:50-56`'s rule — and be attributed to
  /// whichever test happened to be running; it is delivered to the connection
  /// that caused it instead.
  void _onConnect(WebSocketChannel ws, String? negotiated) {
    if (_closed || _draining) {
      // Accepted while the drain was running. Refused with the same code every
      // drained session gets, because from the panel's side it is the same
      // event: this gateway is going away, reconnect rather than alarm.
      unawaited(ws.sink
          .close(CloseCodes.serverDraining, 'server draining')
          .catchError((Object _) {}));
      return;
    }
    // **Before anything is built, and before [_connections] grows** (16-09,
    // WSH-13, threat T-16-09a). The token file gates `hello` and not the
    // upgrade, so every line below this one is server memory allocated for a
    // peer that has presented no credential. A connection refused here has
    // cost a socket; one refused three statements lower would already have
    // cost a send buffer, a sink, a health overlay and a `Peer`, which is
    // everything the budget exists to avoid.
    //
    // Refused **loudly**, with the number in the reason. Naming a budget tells
    // an unauthenticated peer nothing it could not measure by trying, and the
    // alternative — a silent drop — is the "silence, not success" failure this
    // project has already paid for once: it costs an engineer a packet capture
    // to discover that the gateway is refusing anybody at all.
    if (unhelloedCount >= config.maxUnhelloedSessions) {
      unawaited(ws.sink
          .close(
              CloseCodes.unhelloedBudget,
              'the gateway is already holding ${config.maxUnhelloedSessions} '
                  'connections that have not said hello; try again shortly')
          .catchError((Object _) {}));
      return;
    }
    try {
      final buffer = ConflatingSendBuffer(
        maxPending: config.maxPending,
        peakThreshold: config.peakThreshold,
        peakWindowMs: config.peakWindowMs,
        maxPendingBytes: config.maxPendingBytes,
      );
      final sink = SessionSink(buffer, socket: ws.sink);

      // Built by hand, and this is the line the trap is about (Finding 1):
      // `rpc.Peer(ws.cast<String>())` — the documented idiom — binds the
      // socket's sink with `addStream` for the life of the connection, and
      // every later writer, the fan-out tick included, gets "Bad state: Cannot
      // add event while adding stream" on its first push. Cast the *stream*,
      // which is a cheap view, and keep ownership of the sink.
      final channel = StreamChannel<String>(
        mutedRepublish(ws.stream.cast<String>()),
        sink,
      );

      final connection = _Connection(ws: ws, buffer: buffer, sink: sink);
      _connections.add(connection);

      // **Built here, per connection, and that is the whole point** (08-12,
      // threat T-08-45). `link_degraded`, `effective_hz`, `egress_kbps` and
      // `pending_keys` are facts about *this* socket; [api] is one instance
      // shared by every panel in the plant. An overlay built once in `start()`
      // would serve whichever client last moved a number to everybody, so a
      // quiet panel would show the busiest panel's degradation and an engineer
      // would go and look at the wrong machine. It is the same argument the
      // per-session `PolicyStateMan` rests on, about a different fact.
      //
      // The probe reads the session *late*: the overlay has to exist before
      // `serve` in order to be handed to it, so the session it reports on is
      // assigned one statement later. That is the `identityOf` idiom
      // `PolicyStateMan` uses, for the same reason.
      final probe = _SessionProbe(buffer: buffer, engine: () => _engine);
      final health = SessionHealthStateMan(
        source: api,
        // Forwarded, never re-measured: one process, one certificate, one
        // store — so `certHealth!.refresh()` still pushes to every panel
        // subscribed to the key rather than to one store per panel. Null on a
        // plaintext gateway, which is what keeps the key absent there.
        cert: _certHealth,
        probe: probe,
        nowMs: _now,
      );

      final session = RelaySession.serve(
        channel: channel,
        // **Policy over health over source.** `RelaySession` wraps whatever it
        // is handed in its own per-session `PolicyStateMan`, so handing it the
        // health overlay puts the two decorators in the order 06-09 argues
        // for: `canSee` filters a key list that already contains the health
        // keys, and a policy that hides one hides it here too. What changed in
        // 08-12 is *which* overlay sits in the slot — a per-session one rather
        // than the per-server certificate one, which now sits underneath it as
        // `cert:` above. The order did not change, and must not: chained the
        // other way `canSee` would filter a list that does not yet contain the
        // health keys, and a future hiding policy could never reach them.
        api: health,
        config: config,
        handles: handles,
        buffer: buffer,
        validator: validator,
        // Forwarded exactly as `validator` is, and read off `this` rather than
        // captured for the same reason: one gateway, one policy, and a session
        // built against something else would be a panel this server's
        // configuration does not describe.
        policy: policy,
        // Forwarded exactly as `policy` is, and null here is a deployment
        // rather than an omission: the session registers `ackAlarm` either way
        // and refuses it by name when there is no engine behind it.
        alarmAcks: alarmAcks,
        // One sink for the gateway, threaded to every session's decorator —
        // a reconnecting panel's rows and its predecessor's land in one
        // trail (D-05). The seam 17-07 built; this line is what makes it
        // survive composition (CR-01).
        audit: audit,
        // The per-identity family factory, consulted by the session at
        // `hello` — see `AccessScopeFactory` (D-11).
        accessFor: accessFor,
        // Forwarded the same way, and required at both ends: a session built
        // without a mapping is a session whose browse filter has nothing to
        // ask, and 10-03's timeseries handlers would have no table to resolve.
        resolver: resolver,
        serverSupported: serverSupported,
        // One log for the whole gateway: a reconnecting panel is a new session
        // asking about a write the previous one issued.
        writeOutcomes: writeOutcomes,
        seriesTally: seriesTally,
        // One counter for the gateway, so no two establishments anywhere on it
        // share a generation — including across the reconnect that replaces
        // one session with another (04-REVIEW CR-04).
        mintGeneration: () => ++_generations,
        now: _now,
        // The liveness clock is the ENGINE's, not the wall's (09-REVIEW
        // WR-01): `silentForMs` must live in the same clock domain as the
        // reap forgiveness's `LagStalled.stalledMs`, or a hypervisor stun /
        // NTP forward step that only the wall clock observes inflates every
        // session's silence with nothing to credit — the synchronized false
        // disconnect F22 is about, produced by our own reaper. Deferred
        // through a closure like `_SessionProbe.engine` above: `_engine` is
        // assigned in `start()`, before any connection can reach this — the
        // upgrade handler this closure lives in does not exist until the
        // bind, so the `!` cannot fire.
        monotonicNow: () => _engine!.now(),
        closeChannel: connection.closeSocket,
        emitFrame: connection.write,
        // Synchronous, and the asynchronous `_release` below does *not*
        // replace it. A session evicted inside a tick — backpressure, the
        // heartbeat reaper — must be gone from the registry by the time that
        // tick's remaining work runs; `session.closed` completes a turn or
        // more later, after the peer has shut down, and until then the engine
        // would keep fanning out to a client the server has already evicted.
        // `remove` is idempotent and fires `gone` once, so the two paths
        // meeting is not a double report.
        onClosing: _sessions.remove,
        onError: onError,
        // So the heartbeat can touch the deadline. Four of the nine registered
        // methods read no key, and `ping` is the one an established panel
        // sends all shift — see `_ping`.
        health: health,
      );
      connection.session = session;
      probe.session = session;
      _sessions.add(session);

      unawaited(session.closed.then((_) => _release(connection)));
    } catch (error, stack) {
      unawaited(_failConnection(ws, error, stack));
    }
  }

  /// Tells one client its session could not be built, then closes it.
  ///
  /// A notification rather than an error response: there is no request to
  /// answer — the failure happened before the client said anything — and a
  /// socket that closes with no explanation is indistinguishable from a
  /// crashed server, which is the reconnect behaviour we do not want.
  ///
  /// **Built through [StatusParams], not by hand** (03-REVIEW WR-06). This
  /// used to send `{'fatal': '...'}` under the `status` method, and `status`
  /// is `StatusParams` — `{alias, state, error?}`. A client routing the
  /// notification through `StatusParams.fromJson` hit `json['alias'] as String`
  /// on null and threw a TypeError on the *notification* path, where there is
  /// no request to fail and the error is swallowed. So the one frame whose job
  /// is to explain a fatal wiring failure was the one frame a conforming
  /// client could not read. Going through the DTO makes a future drift a
  /// compile error instead.
  ///
  /// The underlying `$error` rides in `error:`, which is the field the
  /// contract has for it — not spliced into free text that nothing can parse.
  Future<void> _failConnection(
      WebSocketChannel ws, Object error, StackTrace stack) async {
    onError(error, stack, 'session wiring');
    try {
      writeFrame(
        ws,
        jsonEncode({
          'jsonrpc': '2.0',
          'method': Methods.status,
          'params': StatusParams(
            alias: 'gateway',
            state: 'unhealthy',
            error: 'the server could not build a session for this connection: '
                '$error',
            // A fault report with no return address is one nobody can
            // attribute when two gateways serve one plant. Omitted when null,
            // so an unconfigured deployment's frame is unchanged.
            publisherId: config.publisherId,
          ).toJson(),
        }),
      );
      await ws.sink.close(1000, 'session wiring failed');
    } catch (_) {
      // The socket was already gone. There is nowhere left to deliver the
      // failure to, and throwing here would put it exactly where this method
      // exists to keep it out of.
    }
  }

  void _release(_Connection connection) {
    if (connection.released) return;
    final session = connection.session;
    if (session != null) _sessions.remove(session);
    _connections.remove(connection);
    _record(connection.finish());
  }

  void _record(ConnectionClose close) {
    _closeLedger.add(close);
    if (_closeLedger.length > _ledgerLimit) _closeLedger.removeAt(0);
  }

  /// Tells every connected panel that this gateway is going away **on
  /// purpose** — synchronously, awaiting nothing, for a caller that is about to
  /// `exit(0)`.
  ///
  /// [close] is the graceful teardown and this is not it. An embedder whose
  /// shutdown may await should call [close]; this exists for the one that must
  /// not. `centroidx-backend` is that one: `bin/main.dart`'s shutdown kills the
  /// acquisition workers with `Isolate.immediate` and exits, because an awaited
  /// OPC UA teardown has been measured at 5.76 s and a container that slow is
  /// SIGKILLed in the middle of whatever it was doing. So it never reaches
  /// [close], and the rig measured the consequence (probe P9): every panel was
  /// disconnected with **1006 and an empty reason** — a deliberate restart
  /// wearing the exact costume of a broken network.
  ///
  /// **What this can and cannot promise.** It closes each socket with
  /// [CloseCodes.serverDraining] and returns; the frame is *queued*, not
  /// flushed. `sink.close` hands it to a controller the socket consumer drains
  /// on a later turn of the event loop, so a caller that exits in the same turn
  /// delivers nothing at all — measured, and pinned by the `sync` arm of
  /// `drain_close_test.dart`.
  ///
  /// **One turn is not enough over TLS, and the plant is entirely TLS.** That
  /// was the second thing the rig proved (probe P9, run 2): the same image
  /// delivered 4002 with TLS off and 1006 with it on, because a `SecureSocket`
  /// needs several rounds of the event loop to encrypt and write what a plain
  /// one takes in the round it is handed. So the contract is **announce, then
  /// [settleDrain], then exit** — see [drainTurns] for the measurements behind
  /// the budget. It remains best effort by construction — a client whose TCP
  /// window is full gets 1006 anyway — and that is the honest ceiling for a
  /// shutdown that is forbidden to wait.
  ///
  /// Straight to the transport rather than through `RelaySession.close`, and
  /// deliberately: that path awaits the preference watch and the peer before it
  /// reaches the close channel, which is several turns for a process that has
  /// one. Everything it would have released goes with the process.
  ///
  /// **Not** `_closed`: that flag also short-circuits [close], so a drain that
  /// set it would leave the listener bound and the sessions attached in any
  /// process that survived — every socket fixture in this package would leak a
  /// port. A drained server is still a server whose [close] must work.
  void announceDraining() {
    if (_draining || _closed) return;
    _draining = true;
    for (final connection in _connections.toList()) {
      // `closeSocket` runs its flush and its `_finished` flag synchronously and
      // only awaits the sink; unawaited, it is exactly "queue the frame and
      // come straight back". It swallows a dead far end itself, so there is no
      // error for this to handle (`unawaited` attaches no handler).
      unawaited(
          connection.closeSocket(CloseCodes.serverDraining, 'server draining'));
    }
  }

  /// How many turns of the event loop [settleDrain] yields.
  ///
  /// **Measured, on a `wss://` socket, because that is the only kind the plant
  /// has** (13-14; the numbers are in `13-14-TLS-DRAIN-SUMMARY.md`). A close
  /// frame queued by [announceDraining] has to cross the WebSocket sink, the
  /// `SecureSocket`'s encryption buffer and the raw socket's write-ready
  /// event, and each of those hops is a separate round of the event loop. The
  /// floor is four turns: one, two and three turns delivered 1006 every time,
  /// four delivered 4002 six times out of six, five was flaky at one failure
  /// in six. Sixteen delivered ten out of ten, and sixty-four delivered ten out
  /// of ten to one client and twenty-five out of twenty-five to twenty-five
  /// simultaneous ones.
  ///
  /// Sixty-four is sixteen times the measured floor and it is nearly free: on
  /// an idle loop the whole pump costs about a millisecond more than the single
  /// turn it replaces (~15 µs a turn), and the client learns of the close
  /// *sooner* end to end — 7 ms against the 20 ms it takes to notice a socket
  /// that simply vanished.
  ///
  /// **This is a turn budget, not a duration, and the difference is the whole
  /// design.** A one-millisecond `Timer` failed six times out of six while four
  /// turns — which elapse in far less than a millisecond — succeeded six times
  /// out of six. What the flush needs is rounds of the event loop, and a
  /// wall-clock wait buys those only by accident. A turn budget also scales
  /// itself: on a slower machine each turn takes longer because the work in it
  /// takes longer, which is precisely the adaptation a hardcoded 50 ms cannot
  /// make.
  static const int drainTurns = 64;

  /// Yields [drainTurns] turns of the event loop, so the frames
  /// [announceDraining] queued can reach the wire.
  ///
  /// **Nothing here waits on a peer, and nothing here waits on a clock.** Every
  /// yield is `Duration.zero`; the loop's only bound is a compile-time count. A
  /// panel that has gone away, a socket whose window is full, a far end that
  /// never answers — none of them can make this take one turn longer than the
  /// budget, which is what keeps it inside Phase 12's law. The honest ceiling is
  /// unchanged: this is best effort, and a socket that cannot take the bytes in
  /// sixty-four turns leaves its panel with 1006, exactly as it would have
  /// without it.
  ///
  /// Static, and takes no server: it is a property of the Dart event loop and
  /// the TLS stack, not of any one gateway, and a caller with no server left to
  /// hold — a process in the middle of exiting — must still be able to reach it.
  static Future<void> settleDrain() async {
    for (var turn = 0; turn < drainTurns; turn++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Stops serving. Idempotent, and ordered.
  ///
  /// **The listener first** (03-REVIEW WR-05). The doc used to say "the
  /// listener last, so nothing new arrives while the drain is running", which
  /// is the opposite of what closing it last achieves: a connection accepted
  /// between the session-drain loop and the listener close built a whole
  /// session — peer, listeners on the backing `StateManApi`, buffer — and
  /// registered it, and `_sessions.dispose()` then cleared the registry
  /// *without closing anything*, so that session's listeners stayed attached
  /// to the source and its socket stayed open. That is precisely the leak
  /// `teardown_test.dart` exists to police, on the one path it could not see.
  ///
  /// The engine next, so no tick can start fanning out to a session that is
  /// halfway through its own teardown — and so the process has no timer left
  /// holding it open. Sessions after that, each with
  /// [CloseCodes.serverDraining] so a panel knows to reconnect rather than
  /// alarm: a client disconnected with no code cannot tell a restart from a
  /// crash. Completes only when every session has.
  ///
  /// [_onConnect] is guarded as well, and the guard is not redundant:
  /// `force: true` does not retract a connection already handed to the
  /// handler, and `_closed` is set synchronously here while the close itself
  /// is awaited.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    await _http?.close(force: true);
    _http = null;

    await _engine?.stop();
    _engine = null;

    for (final session in _sessions.sessions) {
      await session.close(CloseCodes.serverDraining, 'server draining');
    }
    for (final connection in _connections.toList()) {
      _release(connection);
    }

    await _sessions.dispose();
  }
}

/// Where one session's health overlay gets its numbers from.
///
/// The composition root's half of `session_health_state_man.dart`: that
/// library deliberately knows nothing about sessions, sockets or engines, and
/// this class is the only thing in the package that knows how to answer all
/// six questions. It holds no state of its own — every getter is a read of
/// something that was already being measured, which is what keeps the overlay
/// free of a timer.
///
/// [session] is assigned one statement after construction, because the overlay
/// must exist before `RelaySession.serve` in order to be handed to it. Until
/// then the session-derived numbers read as unmeasured, which is the honest
/// answer for a connection that has not finished being built.
final class _SessionProbe implements SessionProbe {
  _SessionProbe({required this.buffer, required TickEngine? Function() engine})
      : _engine = engine;

  final ConflatingSendBuffer buffer;
  final TickEngine? Function() _engine;

  RelaySession? session;

  /// The buffer is over a ceiling it will eventually be evicted for crossing.
  ///
  /// **The soft ceiling when there is one, and the hard one otherwise.**
  /// `peakThreshold` is the number `ConflatingSendBuffer.poll` starts a clock
  /// on: staying above it for `peakWindowMs` continuously *is* "the client
  /// cannot keep up", so it is exactly the line an operator wants a badge to
  /// light on. Reporting the hard `maxPending` instead would mean the
  /// indicator turned amber in the same instant the panel was disconnected,
  /// which is a log entry rather than a warning.
  ///
  /// The byte ceiling is composed in rather than reported separately: from a
  /// panel's side "this link is shedding" is one fact, and a second boolean
  /// nobody wired up is a second fact nobody reads.
  @override
  bool get linkDegraded {
    final entries = buffer.pendingCount;
    final ceiling = buffer.peakThreshold ?? buffer.maxPending;
    if (entries > ceiling) return true;
    final byteCeiling = buffer.maxPendingBytes;
    return byteCeiling != null && buffer.pendingBytes > byteCeiling;
  }

  @override
  double? get effectiveHz => session?.effectiveHz;

  @override
  double? get egressKbps => session?.egressKbps;

  @override
  int get pendingKeys => buffer.pendingCount;

  /// Both halves, summed — `RelaySession.droppedHoldTicks` is already the sum
  /// of `ValueHandlers.droppedHoldTicks` and the notifications the hello gate
  /// refused before a handler was reached. Reporting only the handler's half
  /// would leave the health key with a hole in it exactly where the
  /// unauthenticated peers go, which is what `relay_session.dart:470-478` says
  /// in so many words.
  @override
  int get droppedHoldTicks => session?.droppedHoldTicks ?? 0;

  /// Read through the engine getter rather than captured, exactly as
  /// `validator` and `policy` are: `_onConnect` runs long after `start`, and
  /// a probe built against a null engine would read unmeasured for the life of
  /// the connection.
  @override
  int? get eventLoopLagMs => _engine()?.lastLagMs;
}

/// One socket, its buffer, and the two ways a frame gets from one to the
/// other: the tick engine's [_Connection.write], and the out-of-band priority
/// flush the teardown path needs.
final class _Connection {
  _Connection({
    required WebSocketChannel ws,
    required this.buffer,
    required this.sink,
  }) : _ws = ws;

  final WebSocketChannel _ws;
  final ConflatingSendBuffer buffer;
  final SessionSink sink;

  RelaySession? session;
  var _finished = false;

  /// Whether [finish] has already run.
  ///
  /// Both paths into it are real and can race: the session completing on its
  /// own, and the server draining. Recording one connection twice would put a
  /// disconnect in the ledger that never happened.
  bool get released => _released;
  var _released = false;

  /// The session's `emitFrame`: one already-encoded frame onto this socket.
  ///
  /// Everything the tick engine produces for this client arrives here — the
  /// drained priority lane, the `u` updates, the tick notification — and it is
  /// the reason `_Connection` no longer owns a timer. Until 03-07 this class
  /// pumped its own buffer on its own `Timer.periodic`, which is one timer per
  /// connected panel; the engine replaced all of them with the server's single
  /// one (`tick_engine.dart`, Finding 8).
  void write(String frame) {
    if (_finished) return;
    writeFrame(_ws, frame);
  }

  /// Puts the priority lane on the wire *now*, outside the tick.
  ///
  /// Only the priority lane, and only on the way out: this runs from
  /// [closeSocket], where the telemetry that is still pending belongs to a
  /// client that is being disconnected in the next statement. Dropping it is
  /// correct — resync is a snapshot, never a replayed backlog — while the
  /// refusal that explains the close must land, and that is what the priority
  /// lane is for.
  ///
  /// Deliberately **not** calling `buffer.poll`: a backpressure verdict here
  /// would be an eviction decided during a teardown that is already underway.
  void flushPriority() {
    if (_finished) return;
    final frame = buffer.drain();
    for (final message in frame.priority) {
      writeFrame(_ws, message is String ? message : jsonEncode(message));
    }
  }

  /// The session's `closeChannel`: flush, then close the socket with the code.
  ///
  /// The flush is load-bearing and not obvious. A refusal that explains a
  /// close — the 4005 body naming both version lists, say — is written into
  /// the buffer by the peer and would otherwise wait up to a full tick for the
  /// engine, while `RelaySession._requestClose` schedules the close on the very
  /// next turn of the event loop. The client would then get the close and
  /// never the explanation. Flushing here puts both frames on the wire in
  /// order, which is what the whole close-code discipline is for.
  Future<void> closeSocket(int code, String reason) async {
    flushPriority();
    _finished = true;
    try {
      await _ws.sink.close(code, _clampReason(reason));
    } catch (_) {
      // The far end is already gone. That is the ordinary shape of a
      // disconnect, not news.
    }
  }

  /// RFC 6455 caps a close reason at 123 bytes, and `package:web_socket`
  /// enforces it with an `ArgumentError` (`utils.dart:18`).
  ///
  /// **Clamped here rather than at each site that composes a reason, because
  /// the failure is silent and severe.** The throw lands inside the `try`
  /// above, is swallowed as "the far end is already gone", and the socket is
  /// never closed — so a close code the gateway believes it sent was never
  /// sent, and the session lives on. The revocation reason is one station id
  /// away from that today: a thirteen-character `stationId` is enough to push
  /// it over, and the panel holding the pulled credential would simply keep
  /// its socket. The cap belongs to the transport, so it is applied where the
  /// transport is.
  static String _clampReason(String reason) {
    final bytes = utf8.encode(reason);
    if (bytes.length <= _maxCloseReasonBytes) return reason;
    var cut = _maxCloseReasonBytes;
    // Back off to a code-point boundary — a UTF-8 continuation byte is
    // `10xxxxxx`, and a cut through the middle of a sequence is not a string.
    while (cut > 0 && (bytes[cut] & 0xC0) == 0x80) {
      cut--;
    }
    return utf8.decode(bytes.sublist(0, cut));
  }

  static const int _maxCloseReasonBytes = 123;

  /// Releases the connection and reports how it ended.
  ///
  /// The observation is snapshotted *before* this end closes its own sink: for
  /// a client-initiated close the socket is already carrying the client's code
  /// (1005 when it sent none) and reading it later risks racing our own close.
  ConnectionClose finish() {
    _released = true;
    final close = ConnectionClose(
      clientCloseCode: _ws.closeCode,
      serverCloseCode: session?.sentCloseCode,
    );
    _finished = true;
    sink.finish();
    unawaited(_ws.sink.close().catchError((Object _) {}));
    return close;
  }
}

/// The four-state machine that owns one connection's life, and the loop that
/// builds the next one when it dies.
///
/// Source: 04-RESEARCH Finding 2, whose state table is this file's spec:
///
/// | State | Entered when | Backoff |
/// |---|---|---|
/// | `connecting` | an attempt starts | — |
/// | `resyncing` | socket up, hello answered, subscriptions re-establishing | **not** reset |
/// | `ready` | every subscription has its snapshot | **reset** |
/// | `down` | the attempt failed, or an established link dropped | next attempt scheduled |
///
/// **The one line CLI-02 is about.** The schedule is put back to its
/// attempt-0 window on entry to `ready` and nowhere else. A gateway that
/// accepts sockets and closes them before the snapshot lands is exactly the
/// flap that bites: reset on entry to `resyncing` and every panel in the
/// factory redials from the same 40 ms window, in a wave, against a gateway
/// still replaying snapshots for the previous wave. The herd is
/// self-sustaining — the synchronised retry is what keeps the gateway too busy
/// to finish, which is what keeps the retries synchronised — so the rule is
/// that a link earns its forgiveness by *delivering a snapshot*, not by
/// answering the phone. `reconnect_test.dart`'s
/// `a server that closes before the snapshot does not earn a reset` is the arm
/// that fails the wrong version; every happy-path reconnect case passes under
/// it, which is why that one arm exists.
///
/// **Nothing here reads a close code.** Finding 2 drove a protocol mismatch
/// against the real gateway and saw 4005, then drove a `killOnce` through the
/// fault proxy and saw **1002 with an empty reason** — a yanked cable is
/// indistinguishable-by-code from a protocol error. So the stop decision is
/// taken from the thing that actually carries meaning: the gateway *answered*
/// the handshake and refused it by version. Everything else — a cut cable, a
/// 4002 drain, a socket that ends with no code at all — means the link went
/// away, and the answer to that is always to come back.
///
/// **A fresh peer per connection, and one teardown for both ends of it.** The
/// lifecycle half is `tfc_relay_server`'s `relay_session.dart:418-440`, copied
/// with its reasoning: `listen()` is routed to the same teardown on completion
/// *and* on error, because the server's 03-11 defect was a completion path
/// that released the connection without ever running the teardown, measured at
/// 2.50 leaked listeners per kill cycle. The client does this on every
/// reconnect attempt, and a panel whose gateway is rebooting does it for as
/// long as the reboot takes.
///
/// **Handlers are born with armor.** Every notification body and the fallback
/// carry the pre-substituted `data` from `relay_session.dart:521-526`. Echoing
/// a request that may hold a non-finite number is what makes the *error*
/// unencodable, and an unencodable error hangs every error path on that peer
/// (STATE line 77, the 02-05 trap).
///
/// What breaks in the plant without this file: the panel connects once and
/// never again. A gateway restart at shift change leaves every screen in the
/// control room grey until somebody walks around power-cycling them.
library;

import 'dart:async';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:stream_channel/stream_channel.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'backoff.dart';
import 'client_config.dart';
import 'clock_offset.dart';
import 'deadline.dart';
import 'freshness_watchdog.dart';
import 'heartbeat_pump.dart';
import 'readiness_barrier.dart';
import 'resync_engine.dart';
import 'subscription_state.dart';
import 'ws_transport.dart';

/// Where a connection is in its life. Four, and no fifth — every switch over
/// this enum in the client is exhaustive with no fallthrough arm, so a fifth
/// state would be a compile error rather than a transition nobody handles.
enum LinkState {
  /// An attempt is in flight. The cache is retained and shown as stale.
  connecting,

  /// The socket is up and the handshake answered; snapshots are on their way.
  /// The link is up and the values are not yet trustworthy.
  resyncing,

  /// Every subscription is holding its snapshot. Normal.
  ready,

  /// The attempt failed, or an established link dropped. Next attempt
  /// scheduled unless the gateway refused this build outright.
  down,
}

/// The JSON-RPC error code the gateway refuses an unspeakable protocol with.
///
/// Declared here rather than imported: the server's `ServerErrorCodes` lives
/// in a package this one depends on only for its tests, and a production file
/// may not reach into a dev dependency. The number is the contract, and
/// `reconnect_test.dart` drives it verbatim.
const int _versionMismatch = -32004;

/// The JSON-RPC error code the gateway refuses a credential with.
///
/// Declared here for the same reason [_versionMismatch] is, and the reason has
/// not changed: the server's `ServerErrorCodes` lives in a package this one
/// depends on only for its tests, and a production file may not reach into a
/// dev dependency. The number is the contract, and `auth_refusal_test.dart`
/// drives it verbatim against a scripted gateway, end to end.
const int _unauthorized = -32003;

/// The code this client reports its own handler failures under.
const int _handlerFailed = -32000;

/// The `ResyncParams.reason` a stalled gateway announces itself under — one of
/// the wire vocabulary `messages.dart:455-464` documents.
///
/// Declared here as the literal for the same reason the error codes above are:
/// `tfc_relay_server`'s `gatewayStalled` constant lives in a package this one
/// depends on only for its tests, and the wire string is the contract.
const String _gatewayStalled = 'gateway_stalled';

/// Builds a socket, builds a peer, drives hello through resubscribe to a
/// snapshot, feeds the watchdog, and schedules the next attempt when the link
/// dies.
final class ConnectionSupervisor {
  ConnectionSupervisor({
    required this.uri,
    required this.config,
    required this.backoff,
    required this.barrier,
    required this.watchdog,
    required this.subscriptions,
    required this.storeFor,
    this.heartbeat,
    this.client = const PeerInfo('tfc_relay_client', '0.1.0'),
    void Function(StatusParams status)? onStatus,
    void Function(String reason)? onBye,
    void Function(String key)? onPreferenceChanged,
    int Function()? now,
    Future<ConnectAttempt> Function(Uri uri)? dial,
  })  : _onStatus = onStatus,
        _onBye = onBye,
        _onPreferenceChanged = onPreferenceChanged,
        _now = now ?? _wallClock,
        _dial = dial ?? connect {
    // The watchdog is built by the client above and handed down, so what it
    // *does* about an expiry is wired here, where the peer and the schedule
    // are (04-REVIEW CR-06).
    watchdog.onQuiet = _linkWentQuiet;
    _resync = ResyncEngine(
      storeFor: storeFor,
      subscribe: _subscribe,
      subscriptions: subscriptions,
      forget: watchdog.forgetSubscription,
    );
  }

  /// Where the gateway is. One address; a panel dials the gateway its config
  /// names and does not go looking for another one.
  final Uri uri;

  final ClientConfig config;

  /// The schedule. Reset in exactly one place — see [_enter].
  final Backoff backoff;

  /// The rendezvous every call that touches the wire waits on.
  final ReadinessBarrier barrier;

  /// The link deadline, fed by every inbound frame of any kind.
  final FreshnessWatchdog watchdog;

  /// The app heartbeat, or null when nobody wired one.
  ///
  /// **Taught here and owned elsewhere**, which is the one asymmetry in this
  /// class and it is deliberate. `hello` is the only place the gateway's
  /// deadline crosses the wire, so this is the only place that can teach it —
  /// but the pump's *lifetime* follows `LinkState`, which `RemoteStateMan`
  /// already watches, and giving this class a second thing to start and stop
  /// in every one of its exit paths is how one of them gets forgotten. So:
  /// this supervisor tells the pump what it learned, and never starts, stops
  /// or disposes it. Null in every harness that builds a supervisor by hand,
  /// and a null pump simply learns nothing.
  final HeartbeatPump? heartbeat;

  /// The pages this panel is showing. Owned by the caller: this class
  /// re-establishes them, it does not decide which exist.
  final Map<String, SubscriptionState> subscriptions;

  /// One cache per subscription — see `resync_engine.dart` on why a shared one
  /// manufactures a permanent false-gap loop.
  final ValueStore Function(String sub) storeFor;

  /// Who this panel says it is at the handshake.
  final PeerInfo client;

  final void Function(StatusParams status)? _onStatus;
  final void Function(String reason)? _onBye;

  /// Where a `preferences.changed` notification goes. The client above wires
  /// it to `ClientPreferencesApi.announce`.
  final void Function(String key)? _onPreferenceChanged;
  final int Function() _now;

  /// How one attempt reaches the gateway. Defaults to [connect], the real
  /// dial, and is overridden only by a harness.
  ///
  /// The seam exists because the shared contract suite calls
  /// `StateManApi Function() make` **synchronously** (04-RESEARCH Finding 6)
  /// while a `RelayServer` only learns its port from an asynchronous
  /// ephemeral bind (`relay_server.dart:219-247`, port 0 on purpose). Without
  /// this, a contract leg would have to guess a port number before anything
  /// was listening on it, and a guessed port that collides is a flaky suite
  /// blaming the client. Overriding the dial rather than the [uri] keeps the
  /// retry policy exactly where the operator can see it: this is one attempt
  /// in, one [ConnectAttempt] out, same as the real one, so backoff, the
  /// generation counter and the health line are all unchanged.
  final Future<ConnectAttempt> Function(Uri uri) _dial;

  final StreamController<LinkState> _states =
      StreamController<LinkState>.broadcast();

  final List<Duration> _waits = <Duration>[];

  /// How many scheduled waits [debugScheduledWaits] keeps.
  static const int _waitHistory = 64;

  late final ResyncEngine _resync;

  LinkState _state = LinkState.down;
  rpc.Peer? _peer;
  ClockOffset _clockOffset = ClockOffset.none;

  /// Elapsed time, for the one thing in this class that measures an interval
  /// rather than naming an instant.
  ///
  /// A `Stopwatch` and not [_now], which is the wall clock `ClockOffset` needs
  /// and which steps when NTP corrects it. A rate limit measured on a clock
  /// that can step backwards is a rate limit that suppresses for ever after
  /// one correction (the WR-03 shape, in a third file).
  final Stopwatch _elapsed = Stopwatch()..start();

  /// When each subscription was last rebuilt on this client's own initiative,
  /// in [_elapsed]'s clock, and which of them this connection has already
  /// complained about suppressing. Cleared on the way down.
  ///
  /// **One budget, and three consumers** (16-07, finding S14). A rebuild is a
  /// rebuild whichever detector asked for it, and 07-REVIEW WR-02's bound is
  /// one per subscription per [ClientConfig.freshnessDeadline] — so two
  /// detectors each honouring their own copy of that limit is not that bound,
  /// it is twice it. The three that consult this pair:
  ///
  /// 1. [_tick]'s sequence-mismatch branch, the original (07-07, WR-02);
  /// 2. [_tick]'s unestablished branch (16-01, S1b) — the way back for a page
  ///    a snapshot timeout gave up on;
  /// 3. [_update]'s unannounced-handle branch (16-07, S14), which reached the
  ///    same `ResyncEngine.onResync` with no rate limit at all. At 10–20 Hz
  ///    with a handle this session never announced in every frame, that was
  ///    several full ~1500-key snapshot requests per second against the one
  ///    process serving every screen in the plant, indefinitely.
  ///
  /// The name has no `tick` in it for that reason: anything that adds a fourth
  /// detector must come through here too, and a field named after one of them
  /// invites a second map beside it.
  final Map<String, int> _resyncAtMs = <String, int>{};
  final Set<String> _resyncComplained = <String>{};

  /// Whether [sub] may be rebuilt now, and books the rebuild if so.
  ///
  /// The one gate all three detectors pass through. Stamped **before** the
  /// caller awaits `onResync`, deliberately: stamping afterwards reopens a
  /// window in which a second detector starts a second rebuild while the first
  /// is still in flight, which is the storm this exists to prevent.
  bool _mayRebuild(String sub) {
    final sinceLast = _elapsed.elapsedMilliseconds;
    final rebuiltAt = _resyncAtMs[sub];
    if (rebuiltAt != null &&
        sinceLast - rebuiltAt < config.freshnessDeadline.inMilliseconds) {
      return false;
    }
    _resyncAtMs[sub] = sinceLast;
    return true;
  }

  /// The `gateway_stalled` reason and its absolute duration, carried up from the
  /// last such resync on this connection (09-07). Both null until the gateway
  /// announces a stall; both cleared on the way down, because a stall on a
  /// previous socket is not a fact about this one. [_stallComplained] damps the
  /// complaint to once per connection — fifty subscriptions resyncing on one
  /// stall is one operator-facing sentence, not fifty (WR-02's shape).
  String? _stallReason;
  int? _stalledMs;

  /// When the stall was announced, on [_elapsed]'s clock — the anchor
  /// [stallAge] measures from, cleared with the pair (09-REVIEW IN-05).
  int? _stallAtElapsedMs;
  bool _stallComplained = false;
  Timer? _retry;
  bool _stopped = false;
  String? _stopReason;
  String? _lastDownReason;
  String? _verifiedAccount;
  bool _disposed = false;

  /// True while this session was admitted with no credential and has not yet
  /// signed in — the gateway's awaiting-sign-in sentinel, seen from the
  /// client. The socket is up and the hello is answered; the value barrier
  /// stays shut (nothing may be read or subscribed until a sign-in lands),
  /// but the session barrier is open so `session.login` can cross.
  ///
  /// **This is the client half of the PRIMARY defect's fix.** Before it, an
  /// awaiting-sign-in refusal on the resync subscribe hit the `unauthorized`
  /// arm and `_stop`ped the retry loop — a gateway panel that could never
  /// subscribe read as "the gateway refused this panel's credential" and
  /// showed an error, never a sign-in screen. Now it is a stable, live,
  /// sign-in-able condition instead.
  bool _awaitingSignIn = false;
  bool get awaitingSignIn => _awaitingSignIn;

  /// The epoch of the current hello, kept so a successful `session.login` can
  /// drive the resync that the awaiting state deferred — see [resumeAfterSignIn].
  String _lastEpoch = '';

  /// Opens when the hello is answered — whether or not the resync that
  /// follows it can complete. `session.login` and `session.logout` wait on
  /// this rather than on [barrier], because they exist precisely for a
  /// session that cannot yet reach `ready`: gating them on the value barrier
  /// would be a sign-in screen no one could ever get past. Re-armed on
  /// [_down] / [_stop] like the value barrier, by the same swap-a-completed-
  /// completer rule [ReadinessBarrier] documents.
  Completer<void> _sessionGate = Completer<void>();
  Future<void> get sessionReady => _sessionGate.future;

  void _openSession() {
    if (!_sessionGate.isCompleted) _sessionGate.complete();
  }

  void _rearmSession() {
    if (_sessionGate.isCompleted) _sessionGate = Completer<void>();
  }

  /// Which connection the callbacks in flight belong to.
  ///
  /// Bumped the moment a connection is retired, so a `listen()` that completes
  /// after the teardown has already run — the ordinary shape of a socket that
  /// died while a call was on it — is recognised as belonging to a connection
  /// that no longer exists instead of scheduling a second reconnect for the
  /// same failure.
  int _generation = 0;

  /// Every transition, in order, for the operator-facing link indicator.
  ///
  /// Broadcast, and a caller subscribes **before** starting: the session can
  /// register in the same event-loop turn the connect completes in
  /// (`ws_fault_test.dart:118-121`), so a listener attached afterwards waits
  /// for a transition that already happened.
  Stream<LinkState> get states => _states.stream;

  LinkState get state => _state;

  /// The current connection's peer, or null when there is none.
  ///
  /// The seam `callWithDeadline` reads — as a getter, because this field is
  /// swapped on every reconnect and a call must capture it once before it
  /// suspends.
  rpc.Peer? get peer => _peer;

  /// The skew captured at the last hello. [ClockOffset.none] before the first.
  ClockOffset get clockOffset => _clockOffset;

  /// The subscription bookkeeping, exposed so the client above can read the
  /// configuration complaints a resubscribe collected.
  ResyncEngine get resync => _resync;

  /// Whether the loop has given up for good.
  bool get stopped => _stopped;

  /// Why, in words an integrator can act on.
  String? get stopReason => _stopReason;

  /// Why the last connection ended, for the operator-facing health line.
  ///
  /// Carried because "attempt failed" with no cause is a phone call to the
  /// integrator — `ws_transport.dart` makes the same argument about the value
  /// it hands back from a refused dial.
  String? get lastDownReason => _lastDownReason;

  /// The username the gateway said it verified this session as, from the
  /// hello answer's `account` capability — or null when the gateway sent
  /// none: a credential-less (awaiting-sign-in) session, or a gateway too
  /// old to say.
  ///
  /// **Advisory display material, never identity** — `HelloCapabilities.
  /// account`'s own rule. The one legitimate consumer is attribution prose
  /// ("saves are recorded against …"), which used to print the panel's own
  /// hostname and on the rig rendered a bare container id. Re-learned on
  /// every hello, so a re-provisioned station follows its token file rather
  /// than a stale first answer; NOT cleared when the link drops, because it
  /// describes the last verified session and the link row beside it already
  /// says the link is down.
  String? get verifiedAccount => _verifiedAccount;

  /// The reason of the last `gateway_stalled` resync this connection was told,
  /// or null. See [RemoteStateMan.stallReason].
  ///
  /// Recorded by [_resynced], which used to decode `ResyncParams.reason` and
  /// drop it (09-07 ruling 5a). Reset on the way down: a stall reported over a
  /// previous socket is not a fact about this one.
  String? get stallReason => _stallReason;

  /// The absolute stalledMs of that resync, or null. See
  /// [RemoteStateMan.stalledMs]. The figure the gateway sent, never recomputed.
  int? get stalledMs => _stalledMs;

  /// How long ago the current connection's stall was announced, or null when
  /// [stallReason] is null (09-REVIEW IN-05).
  ///
  /// The surface's "when": [stallReason]/[stalledMs] persist until the
  /// connection dies, so a widget binding them on a long-lived healthy link
  /// would render "gateway stalled for 5015 ms" hours after the fact with
  /// nothing to age it by. Measured on [_elapsed] — this panel's monotonic
  /// clock — because it is capture time on this side, a *display* fact and
  /// not a wire fact: no gateway clock arithmetic, and an NTP step cannot
  /// age or un-age it (the WR-03 shape, kept out of a fourth file).
  Duration? get stallAge {
    final at = _stallAtElapsedMs;
    if (at == null) return null;
    return Duration(milliseconds: _elapsed.elapsedMilliseconds - at);
  }

  /// Every delay this supervisor has waited before an attempt, in order.
  ///
  /// The schedule's observable history. `reconnect_test.dart` asserts the band
  /// these were drawn from, which is the only honest claim about a jittered
  /// number.
  List<Duration> get debugScheduledWaits =>
      List<Duration>.unmodifiable(_waits);

  /// Every timer this supervisor *schedules*: the watchdog's one deadline,
  /// plus the one pending reconnect when an attempt is scheduled.
  ///
  /// Never more than two, and the count is the design — a panel that flaps all
  /// shift accumulates one orphaned timer per cycle if the teardown misses
  /// one, and the one that is missed fires into a connection that no longer
  /// exists.
  ///
  /// It does **not** count the per-call timers `Future.timeout` allocates
  /// (04-REVIEW IN-01), so a panel with ten calls out owns twelve and this
  /// still reads two. That is not a gap in the count: those timers belong to
  /// the call and are cancelled when it settles either way, which is the
  /// property actually being asserted — no timer outlives the thing it belongs
  /// to. A registry of them is exactly what `deadline.dart` argues against
  /// owning.
  int get debugTimerCount =>
      watchdog.debugTimerCount + (_retry == null ? 0 : 1);

  /// Begins dialling. Never throws.
  ///
  /// A gateway that is not up yet is the *normal* state of a panel at
  /// power-on — it boots with the rest of the line, on a switch still learning
  /// MAC addresses — so a start that threw would leave the screen grey until
  /// somebody drove to the factory.
  void start() {
    if (_disposed || _stopped) return;
    if (_state != LinkState.down || _retry != null) return;
    unawaited(_attempt());
  }

  /// The client is going away.
  ///
  /// Order matters: retire the generation first so nothing in flight schedules
  /// another attempt, then drop the timers, then the peer, then release
  /// everyone waiting on the barrier with an error they can show.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _retry?.cancel();
    _retry = null;
    watchdog.dispose();
    barrier.dispose();
    // Strand any sign-in waiting on the session gate, the way the value
    // barrier's own dispose strands its waiters: a login parked here while
    // the client shuts down must get an error it can show, not a spinner
    // that never stops.
    if (!_sessionGate.isCompleted) {
      final stranded = _sessionGate;
      stranded.completeError(StateError(
          'the client was disposed while a sign-in was waiting for the link'));
      unawaited(stranded.future.catchError((Object _) {}));
    }
    final peer = _peer;
    _peer = null;
    if (peer != null) await peer.close().catchError((Object _) {});
    await _states.close();
  }

  /// One attempt, from the dial to whatever ends it.
  Future<void> _attempt() async {
    if (_disposed || _stopped) return;
    final gen = ++_generation;
    _enter(LinkState.connecting);

    final ConnectAttempt attempt;
    try {
      attempt = await _dial(uri);
    } catch (error) {
      // `connect` reports a refused dial as a value, so a throw here is
      // something else entirely — a bad URI, a DNS failure. Same answer: the
      // gateway is not reachable, come back.
      _down(gen, 'the dial failed: $error');
      return;
    }
    if (_disposed || gen != _generation) {
      // **Both doors of this condition, one answer** (16-07, finding S12).
      // The dial has already completed: the socket is up and the WebSocket
      // upgrade has happened. Returning here without closing it dropped it
      // where nothing else in this file can reach — the only sink close is
      // `_stopServing`'s `peer.close()`, and the peer is built inside
      // [_serve], which this path never enters.
      await _closeAbandonedDial(attempt);
      return;
    }

    // Sealed, two arms, and no fallthrough: a third outcome added to
    // `ConnectAttempt` is a compile error here rather than a dial whose result
    // nobody looked at.
    switch (attempt) {
      case ConnectFailed(:final error, :final certificateUntrusted):
        _down(gen,
            _refusalReason(error, certificateUntrusted: certificateUntrusted));
      case ConnectSucceeded(:final channel):
        await _serve(gen, channel);
    }
  }

  /// Closes the socket a dial produced for a connection nobody will serve.
  ///
  /// **`_pinned?.close(force: true)` does not reap this**, which is the reason
  /// it is worth three lines rather than none. The WebSocket upgrade detaches
  /// the socket from the `HttpClient` connection pool, so closing the panel's
  /// pinned client leaves it open and the gateway carries a session nobody is
  /// on until its own reaper fires. The window is `connectTimeout` wide — ten
  /// seconds by default — and a gateway coming back from a reboot is exactly
  /// what fills it: a panel shutting down mid-restart leaks one session per
  /// occurrence, and a control room shuts its panels down together.
  ///
  /// A [ConnectFailed] has no socket to close: `connect` has already drained
  /// the second copy of the exception off its stream and attached a handler to
  /// its `done`, which is the whole of that outcome's cleanup.
  ///
  /// Swallowed rather than reported, on [_retirePeer]'s reasoning: a close that
  /// fails is a socket that was already gone, which is the ordinary shape of a
  /// teardown after a cut cable.
  Future<void> _closeAbandonedDial(ConnectAttempt attempt) async {
    if (attempt is! ConnectSucceeded) return;
    try {
      await attempt.channel.sink.close();
    } catch (_) {
      // See above.
    }
  }

  /// What to put on the health line for a dial that produced no socket.
  ///
  /// **A certificate problem is not silence, and saying it is sends the wrong
  /// person.** "The gateway did not answer" is what this said for every
  /// failed dial, and for a `HandshakeException` it is actively wrong: the
  /// gateway answered, at length, and this panel refused to believe it. An
  /// integrator reading "did not answer" checks the cable, the switch and the
  /// service — three things that are all fine — before anybody thinks of the
  /// leaf that lapsed on Sunday.
  ///
  /// **The classification comes in as a `bool`, from the dial seam** (16-07,
  /// WSH-14). This method used to ask `error is HandshakeException` itself,
  /// which cost this file an `import 'dart:io' show HandshakeException` — one
  /// import, for one exception type, in the state machine a web build reuses
  /// through its own `dial:` seam. It would not compile there, for that line.
  /// `ws_transport.dart` is already `dart:io`-only and documents why at
  /// length — a pinned dial has no other seam — so the platform-specific
  /// judgement now lives in the platform-specific place and
  /// `ConnectFailed.certificateUntrusted` carries the answer across. Unlike
  /// `RemoteStateMan`'s `HttpClient` dependence (S11, deliberate debt with no
  /// browser equivalent), this one was avoidable today.
  ///
  /// The original text is kept whole — the `OS Error` line is what an
  /// integrator pastes into a ticket, and it is the only part of this a
  /// support engineer can act on remotely.
  ///
  /// **What it deliberately does not say is *which* certificate problem** —
  /// and the reason is not the one trap 16 gave. Trap 16 said wrong CA,
  /// expired leaf and an uncovered SAN are byte-identical here; that was
  /// measured on macOS only and it is false on the two platforms this product
  /// also ships to. Measured on all three (`tls_gate_test.dart`'s F15b): macOS
  /// routes every one of them through BoringSSL's *application* verification
  /// arm, which has no reason to report, while Linux and Windows route them
  /// through the built-in verifier and name all three — "certificate has
  /// expired", "unable to get local issuer certificate", "IP address
  /// mismatch".
  ///
  /// So the discrimination does exist, on two platforms out of three, and that
  /// is exactly why this sentence must not use it. A panel that named the fault
  /// where openssl volunteered one would say nothing on the macOS desktops and
  /// something confident on the eLinux panels, for the same broken certificate
  /// — an operator-facing message that varies by which machine is looking at
  /// the plant. The OS text is kept whole below for the integrator; the
  /// sentence stays one sentence.
  ///
  /// **And no `FailureKind` is added for it**, deliberately against
  /// 06-RESEARCH §C.5's recommendation. `classifyFailure` sorts *call*
  /// failures and never sees a `ConnectAttempt` (`failure_taxonomy.dart:
  /// 120-155`), so a TLS member of that enum would belong to a vocabulary
  /// nothing can ever produce — a constant that reads like
  /// coverage, which is the argument `suite_integrity_test.dart:104-108`
  /// makes about vacuous checks, applied to an enum. The connect path
  /// produces a link-state reason string, and this is it.
  static String _refusalReason(Object error,
      {required bool certificateUntrusted}) {
    if (certificateUntrusted) {
      return 'the gateway\'s certificate was not trusted by this panel: '
          '$error';
    }
    return 'the gateway did not answer: $error';
  }

  /// The socket is up: build the peer, arm it, and drive it to a snapshot.
  Future<void> _serve(int gen, StreamChannel<String> channel) async {
    final peer = rpc.Peer(channel);
    _peer = peer;

    peer.registerMethod(Methods.update,
        (rpc.Parameters p) => _armored(Methods.update, () => _update(p)));
    peer.registerMethod(Methods.tick,
        (rpc.Parameters p) => _armored(Methods.tick, () => _tick(p)));
    peer.registerMethod(Methods.resync,
        (rpc.Parameters p) => _armored(Methods.resync, () => _resynced(p)));
    peer.registerMethod(Methods.status,
        (rpc.Parameters p) => _armored(Methods.status, () => _status(p)));
    peer.registerMethod(Methods.bye,
        (rpc.Parameters p) => _armored(Methods.bye, () => _bye(p)));
    // 04-REVIEW WR-07. `ClientPreferencesApi.announce` documented itself as
    // "called from the notification handler and nowhere else", and there was
    // no such handler: `preferences.changed` fell through to the fallback
    // below and was answered `-32000 this panel does not answer
    // "preferences.changed"`, so `onPreferencesChanged` could never emit and a
    // settings page edited on one panel never reached a second. The gateway
    // has no preferences handlers until Phase 10, so nothing sends this yet —
    // but a handler that does not exist is a different defect from a feature
    // that has not shipped, and only one of the two is fixed by waiting.
    peer.registerMethod(
        DataServiceMethods.preferencesChanged,
        (rpc.Parameters p) => _armored(
            DataServiceMethods.preferencesChanged, () => _preferenceChanged(p)));
    // A name this build does not know is answered by us, inside the same
    // armor, rather than by the library — whose refusal echoes the raw request
    // back into the response, which is the unencodable-error hang when the
    // request held a non-finite number.
    peer.registerFallback((rpc.Parameters p) async {
      throw rpc.RpcException(
          _handlerFailed, 'this panel does not answer "${p.method}".',
          data: _substitute(p.method));
    });

    // Both completion paths, one teardown (`relay_session.dart:418-420`).
    unawaited(peer.listen().then(
          (_) => _transportEnded(gen),
          onError: (Object _) => _transportEnded(gen),
        ));

    _enter(LinkState.resyncing);

    try {
      final raw = await callWithDeadline(
        () => _peerFor(gen),
        Methods.hello,
        params: HelloParams(
          protocol: protocolVersion,
          supported: const [protocolVersion],
          client: client,
          // Null on a gateway with no token file, and then omitted from the
          // frame entirely, so this line changes nothing for a deployment
          // that has not configured one.
          token: config.token,
        ).toJson(),
        deadline: config.controlDeadline,
      );
      if (_disposed || gen != _generation) return;
      watchdog.sawFrame(InboundFrame.rpcResponse);

      final hello =
          HelloResult.fromJson(_asJson(sanitize(raw).value));
      // Who the gateway verified this session as, for attribution prose and
      // nothing else — see [verifiedAccount]. Assigned unconditionally so an
      // absent capability reads as "the gateway did not say" rather than as
      // a stale answer from a previous gateway.
      final account = hello.capabilities[HelloCapabilities.account];
      _verifiedAccount =
          account is String && account.isNotEmpty ? account : null;
      // The gateway's fan-out cadence, for the per-subscription staleness
      // limit and nothing else (04-REVIEW WR-06). The *link* deadline stays
      // configured and independent, as 04-CONTEXT rules.
      watchdog.learnedTickMs(hello.capabilities[HelloCapabilities.tickMs]);
      // The other capability, and the one the panel's own survival depends on:
      // how long this gateway lets a session go silent before its reaper
      // closes it. Learned on every hello, so a replacement gateway
      // configured differently is followed rather than beaten at the retired
      // one's cadence. `HelloResult` owns the tolerance rule, so a gateway
      // that advertises nothing usable leaves the pump on its own floor.
      heartbeat?.learnedDeadlineMs(hello.heartbeatDeadlineMs);
      // The gateway's clock, anchored against this panel's monotonic one. The
      // handshake is the least-delayed sample of it this connection will ever
      // see — half a round trip rather than a queue — which is why the anchor
      // is taken here and only refined from ticks (07-REVIEW CR-01).
      watchdog.anchorServerClock(hello.serverTime);
      _clockOffset = ClockOffset.fromHello(
        hello.serverTime,
        _now(),
        threshold: config.implausibleClockThreshold,
      );

      // The hello is answered and the peer is usable: open the session gate
      // NOW, before the resync that may not complete, so `session.login` can
      // cross on an awaiting session. The value barrier stays shut until
      // resync reaches `ready` below.
      _lastEpoch = hello.epoch;
      _awaitingSignIn = false;
      _openSession();

      // Adopts the epoch and re-establishes every page. It returns only when
      // all of them are holding a snapshot, which is the definition of ready.
      await _resync.onHello(hello.epoch);
      if (_disposed || gen != _generation) return;
    } on rpc.RpcException catch (error) {
      // The awaiting-sign-in refusal is neither a dead credential nor a dead
      // link: it is the resync subscribe hitting the gateway's gate on a
      // session nobody has signed in on. Recognised by the marker the gate
      // puts in every such refusal, and handled BEFORE the `unauthorized`
      // arm below — which would otherwise `_stop` the loop and turn a panel
      // that should show a sign-in screen into one that shows "credential
      // refused". The socket stays up (the session gate is already open, the
      // heartbeat keeps it alive), and a successful `session.login` drives
      // the deferred resync through [resumeAfterSignIn].
      if (error.message.contains(SessionAuthMarkers.awaitingSignIn)) {
        _awaitingSignIn = true;
        _lastDownReason = null;
        // Re-announce the state we are already in, so anything that keys off
        // the link re-evaluates now that `awaitingSignIn` is true.
        //
        // **Why an explicit re-emit and not a new state.** This branch keeps
        // the link in `resyncing` on purpose — socket up, hello answered,
        // nothing subscribed — and `_enter` de-duplicates, so entering
        // `resyncing` again emits nothing. That silence had a cost measured on
        // the rig: `RemoteStateMan` starts its heartbeat from this stream, the
        // stream never fired when a session became awaiting, the pump never
        // beat, and the gateway closed the session on its own deadline
        // (`4003 — no heartbeat for 6098 ms`). The panel reconnected, went
        // awaiting, fell silent and was reaped again, every six seconds,
        // which is not long enough for anyone to type a password.
        //
        // Listeners must therefore tolerate the same state twice. That is
        // already true of `_onLinkState`, whose work is idempotent by
        // construction (both heartbeat calls are, and `_wasReady` is a latch).
        if (!_states.isClosed) _states.add(_state);
        // Not `ready` and not `down`: the value barrier stays shut, nothing
        // is retried, and the connection is held. The state stays
        // `resyncing` — socket up, hello answered — which is the honest
        // description of a panel waiting at its sign-in screen.
        return;
      }
      // The gateway answered and said no. A version refusal is the one answer
      // that will not change on the next attempt, and it is taken from the
      // answer rather than from the close that follows it — Finding 2's
      // double signal is one event, and the number on the close means nothing.
      if (error.code == _versionMismatch) {
        _stop('the gateway refused this build\'s protocol version: '
            '${error.message}');
        return;
      }
      // The second answer that will not change on the next attempt. A refused
      // credential is not a transient fault: the gateway has already decided
      // about this token, and `error_codes.dart:31-34` says so from its end —
      // "reconnecting with the same token will be refused again, so a backoff
      // loop around it is a busy loop". Without this arm one mistyped station
      // token is a rejected hello every backoff ceiling, forever, against the
      // single process serving every screen in the factory, with nothing on
      // the panel to distinguish it from a pulled cable.
      //
      // The message is the gateway's, unmodified. This side holds the
      // credential in `config.token` and must never splice it in: `stopReason`
      // is displayed at the panel, and a panel stands where anybody can read
      // it.
      if (error.code == _unauthorized) {
        _stop('the gateway refused this panel\'s credential: '
            '${error.message}');
        return;
      }
      _down(gen, 'the handshake was refused: ${error.message}');
      return;
    } catch (error) {
      _down(gen, 'the link died before the snapshot landed: $error');
      return;
    }

    _enter(LinkState.ready);
  }

  /// Drives the resync an awaiting session deferred, after a `session.login`
  /// the gateway accepted — the client half of "the gate lifted".
  ///
  /// Called by `RemoteStateMan.sessionLogin` on a successful answer, and only
  /// then: the far end has replaced the sentinel identity with the verified
  /// person, so the subscribe that was refused a moment ago is now allowed.
  /// A no-op unless this session is actually awaiting — a login answered on
  /// an already-ready session (there is none today, but the guard is cheap)
  /// must not tear its snapshot down and rebuild it.
  ///
  /// On success it enters `ready`, which opens the value barrier and resets
  /// the backoff exactly as a first snapshot does. A resync that fails is
  /// taken down like any other, so a login accepted onto a gateway that then
  /// refuses the subscribe for some *other* reason does not leave a session
  /// wedged half-signed-in.
  Future<void> resumeAfterSignIn() async {
    if (_disposed || !_awaitingSignIn) return;
    final gen = _generation;
    _awaitingSignIn = false;
    try {
      await _resync.onHello(_lastEpoch);
      if (_disposed || gen != _generation) return;
    } catch (error) {
      _down(gen, 'the link died before the snapshot landed: $error');
      return;
    }
    _enter(LinkState.ready);
  }

  /// The peer this generation owns, or null once it has been retired.
  ///
  /// A call that started before a reconnect must not be retargeted at the
  /// replacement socket — for a write that is a second actuation of the
  /// machinery, which this client never performs on its own.
  rpc.Peer? _peerFor(int gen) => gen == _generation ? _peer : null;

  /// The subscribe the resync engine calls, deadline-wrapped.
  ///
  /// Through [_peerFor] like every other call in this file (04-REVIEW WR-05).
  /// This was the one place reading the bare `_peer`, and the invariant it
  /// skipped is the file's own: a call that started before a reconnect must
  /// not be retargeted at the replacement socket. The liveness reset below is
  /// guarded by the same capture, because a reply belonging to a retired
  /// connection must not tell the watchdog that *this* one is alive.
  ///
  /// **[ClientConfig.snapshotDeadline], not `controlDeadline`** (16-01, finding
  /// S1b). This call and the `hello` at [_serve] were bounded by the same one
  /// second, and they are not the same size: the hello is five fields, this
  /// answer is the whole page. On a link slow enough that the snapshot needs
  /// three seconds, sharing the number produced a panel that could never reach
  /// `ready` — every attempt abandoned the page and redialled, and
  /// `backoff.reset()` is reachable only from `_enter(ready)`, so the loop was
  /// self-sustaining — and, mid-connection, a page left permanently
  /// unestablished on a socket the heartbeat kept alive for days. The
  /// asymmetry was the tell: the identical expiry during `onHello` got
  /// infinite retries and mid-connection got none. `ClientConfig` carries the
  /// arithmetic for the number.
  Future<DecodedSubscribeResult> _subscribe(String sub, Set<String> keys) async {
    final gen = _generation;
    final raw = await callWithDeadline(
      () => _peerFor(gen),
      Methods.subscribe,
      params: SubscribeParams(sub: sub, keys: keys.toList(growable: false))
          .toJson(),
      deadline: config.snapshotDeadline,
    );
    if (gen == _generation) watchdog.sawFrame(InboundFrame.rpcResponse);
    return decodeSubscribeResult(raw);
  }

  /// An update frame: handles resolved to keys, then the sequence verdict —
  /// and a rebuild of the page if any handle in it was a stranger.
  ///
  /// **A skipped key is a diverged cache behind an intact sequence** (07-07,
  /// 07-RESEARCH-PUBSUB §A.4 item 2). The surviving changes are applied and the
  /// sequence advances, so nothing downstream can tell that anything was lost:
  /// the gap check has no gap to find and the tick advertises exactly the
  /// number this client holds. Until 07-07 the complaint below was the whole of
  /// the response, and a complaint is a thing somebody reads tomorrow, not a
  /// thing that heals the page tonight. Under a quiet plant the gateway will
  /// never re-send the value it believes it delivered, so the mimic keeps a
  /// number the plant has moved on from for as long as the shift lasts.
  ///
  /// **After the batch, never before.** Resyncing first and then applying a
  /// frame from the establishment the resync retired is the poisoning chain
  /// `resync_engine.dart` documents — the old frame takes the baseline and the
  /// genuine one at that sequence is discarded as a replay, which walks the
  /// mimic backwards. And the surviving changes are applied rather than dropped
  /// because dropping them makes a partial frame worse: the store is the only
  /// thing entitled to judge the sequence.
  ///
  /// **One batch, one resync.** The flag is set, not the call: a frame naming
  /// five strangers is one event and costs one rebuild, and it goes through the
  /// same coalesced [ResyncEngine.onResync] everything else does.
  ///
  /// **Not left to Phase 8's keyframes**, which is the alternative the survey
  /// names. They are opt-in and default off, so a deployment that never turned
  /// them on would never detect this at all — and this is the client that has
  /// to be right on the panel nobody configured.
  ///
  /// ## All four lanes, since 16-10 (finding S4, WSH-04)
  ///
  /// This method used to iterate `update.changes` and nothing else. A `u` frame
  /// can say four things and three of them were decoded into `UpdateParams` and
  /// then dropped on the floor here, with **no comment anywhere in the client
  /// recording a decision to drop them**. That absence is the finding: not a
  /// tradeoff somebody made, a seam nobody joined. The wire contract declares
  /// the lanes, `frame_encoder.dart:94-105` emits them, `SendBuffer` conflates
  /// them with real care — `putQuality` composes rather than replaces a
  /// `badNonFinite` band and explains why — and the server suite tests them.
  /// Every layer treated them as real except the one that has to render them.
  ///
  /// * **`qualities` (`q`)** — a quality transition on a value that has not
  ///   moved, which is the ordinary shape of a comm fault: the source drops
  ///   while the last reading stands. Dropping it applied an empty change set
  ///   and advanced the sequence *cleanly*, so nothing downstream could tell.
  ///   No gap for the gap check to find, no complaint, and no resync to heal
  ///   it: the widget kept the old number under [Quality.good] until something
  ///   unrelated forced a rebuild. A comm fault on the line is the one thing
  ///   this product exists to put on the screen and it was the one thing that
  ///   could not get there.
  /// * **`removed` (`r`)** — the handle is gone from availability. Dropping it
  ///   left the last value being served as good forever.
  /// * **`t`** — the batch timestamp, whose own doc (`messages.dart:373`) says
  ///   it applies "to values without their own". Slim pushes are *defined* by
  ///   omitting per-value timestamps, so dropping the batch stamp meant every
  ///   slim push landed with `sourceTime: null` — and value-age staleness
  ///   stopped being computable at the panel, which is the exact failure
  ///   [WireValue.toDynamicValue]'s doc says the type exists to prevent.
  ///
  /// **Latent, not live, and fixed anyway.** No shipping gateway can currently
  /// emit `q` or `r`: `SendBuffer.putQuality` / `.remove` have exactly one
  /// production caller between them (`tick_engine.dart:534/:537`, inside
  /// `_defer`) and `_defer`'s inputs come out of `buffer.drain()` — the same
  /// two lanes it is putting them back into, a closed loop with no entrance.
  /// The origin-side filler is `session_handlers.dart:241`, which calls
  /// `putValue`, and `putValue` *deletes* from both other lanes on the way past.
  /// A decoder that silently discards a declared lane is a defect the day the
  /// other end starts using it, and the other end is already built to.
  ///
  /// **One change-set, not three routes to the store.** All four lanes are
  /// folded into the same map handed to [ResyncEngine.onUpdate], so the store
  /// applies one batch and the sequence advances once. Three lanes reaching the
  /// store by three routes is three chances to disagree about ordering, and the
  /// store is the only thing entitled to judge the sequence.
  Future<void> _update(rpc.Parameters params) async {
    watchdog.sawFrame(InboundFrame.update);
    final update = UpdateParams.fromJson(_asJson(sanitize(params.asMap).value));
    final state = subscriptions[update.sub];
    if (state == null) return;

    // **The generation gate, resolved here rather than left to `onUpdate`**
    // (16-07, finding S14). It is the same rule `ResyncEngine.onUpdate`
    // applies — a frame from an establishment this client has already replaced
    // is dropped silently, without touching the sequence — moved to the front
    // of this method because the two things below it used to run *around* the
    // gate rather than behind it: the handle-resolution loop filed a complaint
    // per unknown handle, and the rebuild trigger asked for a full page
    // snapshot, both for a frame nothing was ever going to apply. A peer that
    // replays retired frames could therefore drive an unbounded rebuild storm
    // and an unbounded complaint list without a single frame being accepted.
    //
    // Resolved first rather than collected-and-appended-afterwards because it
    // is also cheaper: the handle lookups for a frame that is going nowhere are
    // skipped with it. `onUpdate` keeps its own copy of the check — this is a
    // detector shortcut, not a relocation of the rule, and the engine is
    // driven directly by `resync_test.dart` with no supervisor in front of it.
    if (update.generation != state.generation) return;

    // Whether this client still believes in the page at all. An unestablished
    // one has no handle table, so *every* handle in every frame the gateway
    // goes on pushing is unknown — and none of them is a fault anybody can act
    // on, because this client threw the table away itself.
    final established = state.lastSeq != null;

    var sawUnknownHandle = false;
    final changes = <String, DynamicValue>{};

    /// Resolves [handle] to its key, or records a stranger and returns null.
    ///
    /// Shared by all three handle-addressed lanes so a stranger costs the same
    /// wherever it is named. A lane with its own resolution would be a second
    /// door into [ResyncEngine.onResync], outside 16-07's shared budget —
    /// which is S14 reintroduced by the back way (T-16-10a, T-16-10b).
    String? keyFor(int handle) {
      final key = state.handles[handle];
      if (key != null) return key;
      // Never filed under a guess: a value on a mimic under a label the
      // gateway never agreed to is worse than a value missing from it.
      sawUnknownHandle = true;
      // Diagnostic, and only where there is something to diagnose: on an
      // unestablished page this is a line per handle per frame on an
      // unbounded list, for the life of the socket (07-REVIEW WR-07).
      if (established) {
        _resync.complain('update for "${update.sub}" named handle '
            '$handle, which this session never announced');
      }
      return null;
    }

    // The batch timestamp, as a `DateTime` or absent.
    //
    // **Range-checked, because `UpdateParams.fromJson` does not check this
    // one.** `WireValue` has carried [isRepresentableEpochMs] since 16-05 —
    // `1e17` is finite, passes an `isFinite` guard, and makes
    // `DateTime.fromMillisecondsSinceEpoch` throw — but the batch `t` is
    // decoded straight through `(json['t'] as num).toInt()` with no such
    // guard. Without this check a single hostile or broken batch stamp would
    // throw out of the fallback below and cost the whole frame through
    // `_armored`, once per frame, for as long as the gateway kept sending
    // them. Out of range is treated as **absent**, which is `WireValue.of`'s
    // own rule and for its reason: a clamped timestamp is a lie about
    // freshness, and `null` is the honest answer every consumer already
    // handles.
    final batchTime = isRepresentableEpochMs(update.t)
        ? DateTime.fromMillisecondsSinceEpoch(update.t, isUtc: true)
        : null;

    for (final entry in update.changes.entries) {
      final key = keyFor(entry.key);
      if (key == null) continue;
      final value = entry.value.toDynamicValue();
      // **The batch stamp is a fallback and never an override.**
      // `messages.dart:373` — "applying to values without their own" — is the
      // specification, and that sentence decides the direction. A batch stamp
      // that won would let one number at the top of a frame rewrite the source
      // times of every honestly-stamped value under it (T-16-10e).
      changes[key] = value.sourceTime == null && batchTime != null
          ? DynamicValue(
              value: value.value, quality: value.quality, sourceTime: batchTime)
          : value;
    }

    // **The quality lane: the quality changes, the value does not.**
    // Rebuilt from what the store already holds rather than from anything in
    // the frame, because a quality-only transition is by definition not news
    // about the value — inventing a null here would land an open-circuit
    // 4-20 mA reading as a blank box that looks like an unbound tag rather
    // than as a fault, which is the same substitution `SendBuffer.putQuality`
    // refuses to make at the other end.
    //
    // **The source time is the store's, not the batch's.** The plant measured
    // that number when it measured it; the gateway noticing a fault now does
    // not make the reading newer. Re-stamping it would make a frozen value
    // look freshly measured for as long as the fault lasted — the panel would
    // hold a number under `badCommFault` whose age it could no longer compute,
    // which is the other half of this very finding.
    for (final entry in update.qualities.entries) {
      final key = keyFor(entry.key);
      if (key == null) continue;
      final held = storeFor(update.sub).node(key).value;
      changes[key] = DynamicValue(
          value: held.value,
          quality: entry.value,
          sourceTime: held.sourceTime);
    }

    // **The removal lane: affirmatively gone, and the node stays.**
    // [Quality.errorConfig], not a dropped node and not
    // `uncertainNotYetKnown`. The store's own doc draws exactly this
    // distinction (`value_store.dart:28-41`): a key that has not arrived yet
    // is uncertain and waiting will help, while "a key the source has
    // affirmatively been told is gone is a different fact, and carries
    // [Quality.errorConfig]". An `r` entry is the gateway making that
    // statement, so the store's existing rule decides this and no new one was
    // invented for it.
    //
    // **And the node is not removed from the store.** Widgets hold
    // [ValueStoreNode] as a `ValueListenable` directly, with no adapter object
    // per key — so dropping it from the map detaches nobody: the widget keeps
    // its reference to the orphan, `node(key)` mints a fresh one for the next
    // arrival, and the mimic freezes on its last reading with no path back, on
    // a healthy link, silently. That is a worse version of the bug being fixed
    // here, arrived at while fixing it.
    //
    // The value goes to null with it: a number nobody stands behind is not a
    // number to leave on a screen.
    for (final handle in update.removed) {
      final key = keyFor(handle);
      if (key == null) continue;
      changes[key] = DynamicValue(
          value: null, quality: Quality.errorConfig, sourceTime: batchTime);
    }

    await _resync.onUpdate(update.sub,
        seq: update.seq, changes: changes, generation: update.generation);
    // **Only for a page this client still believes in** (07-REVIEW WR-07).
    // `ResyncEngine._recover` failing leaves the subscription unestablished on
    // purpose and does not unsubscribe server-side, so the gateway keeps
    // pushing `u` frames for the rest of the socket's life — every one of them
    // with all its handles unknown, every one of them restarting the recovery
    // that just failed, each with another complaint on an unbounded list.
    // `lastSeq == null` is the same "unestablished" signal `_tick`'s loop
    // skips on two methods down, so the two branches agree.
    //
    // **And through the same budget the tick detector uses** (16-07, finding
    // S14). This branch had no rate limit at all, while the detector two
    // methods down was capped at one rebuild per subscription per
    // `freshnessDeadline` because "the F9/G3 resync-storm hazard reached
    // through this detector" (07-REVIEW WR-02). The hazard reaches through
    // this one too, and harder: a tick arrives at the gateway's fan-out
    // cadence, while `u` frames arrive as fast as the plant moves. See
    // [_resyncAtMs] for why the two share one map rather than owning one each.
    if (sawUnknownHandle && state.lastSeq != null) {
      if (!_mayRebuild(update.sub)) {
        // Once per subscription per connection, like the tick path's, and
        // through the same set: one suppression is one operator-facing
        // sentence however many detectors noticed it.
        if (_resyncComplained.add(update.sub)) {
          _resync.complain('"${update.sub}" was rebuilt less than '
              '${config.freshnessDeadline.inMilliseconds} ms ago and the '
              'gateway is still sending handles this session never announced. '
              'Further rebuilds on this subscription are suppressed to one '
              'per ${config.freshnessDeadline.inMilliseconds} ms while that '
              'lasts. The complaints above name the handles; a page whose key '
              'list the gateway no longer agrees with is fixed by editing the '
              'page, not by rebuilding it.');
        }
        return;
      }
      await _resync.onResync(update.sub);
    }
  }

  /// A tick: the link is alive, every subscription is re-judged against the
  /// gateway's own clock, and any subscription the gateway has numbered past
  /// us is recovered.
  ///
  /// **The tick is the only thing that speaks while the plant is quiet.** It
  /// has carried each subscription's current sequence since Phase 3
  /// (`tick_engine.dart`'s `_writeTick`) and the client decoded it and threw it
  /// away until 07-07 (07-RESEARCH-PUBSUB §A.4). Every notification handler
  /// here is armored drop-not-throw, so a `u` that cannot be decoded is lost
  /// without a sound, and the only thing that would ever notice is the gap on
  /// the *next* `u` — of which a quiet plant sends none. The panel then holds a
  /// value the gateway has already superseded, under good quality, while
  /// `evaluatedAt` keeps advancing and the freshness watchdog keeps reporting
  /// fresh. MoldUDP64's heartbeat carries the next expected sequence for
  /// exactly this reason; this is that, on the frame we already send.
  ///
  /// **Ahead of, not different from.** A tick *behind* the client's own
  /// sequence would be a gateway that rewound — a different bug, and resyncing
  /// on it would hide it behind a page that rebuilds itself forever. It is also
  /// the ordinary shape of a same-socket re-establish seen from the wrong side:
  /// the replacement subscription numbers from zero while this client still
  /// holds the old baseline, for as long as it takes the snapshot to be
  /// adopted.
  ///
  /// **Awaited, and through [ResyncEngine.onResync].** `_recover` records its
  /// own failures into `complaints` rather than throwing
  /// (`resync_engine.dart`), so awaiting is safe in a handler that has nowhere
  /// to throw, where an unawaited future would need a `.catchError` or become
  /// an unhandled async error. `onResync` is the existing coalesced path, so a
  /// run of ticks arriving during one recovery costs one resubscribe and not
  /// one each.
  ///
  /// **Not in [FreshnessWatchdog].** Its own library doc draws a line above its
  /// subscription half: nothing below it schedules anything or asks for the
  /// stream to be rebuilt. This asks for exactly that, so it lives here, where
  /// the peer, the schedule and `_resync` already are.
  /// **Damped, and recorded.** [ResyncEngine._resubscribe]'s `_inFlight` map
  /// coalesces resyncs that *overlap*; it does not coalesce sequential ones.
  /// So any condition in which the gateway's advertised sequence stays ahead
  /// of what its own `subscribe` answer returns — a seq-bookkeeping bug, a
  /// misbehaving or hostile peer — was one full-page resubscribe per tick,
  /// indefinitely, at 10 Hz, against the one process serving every screen in
  /// the plant: the F9/G3 resync-storm hazard reached through this detector
  /// (07-REVIEW WR-02). One rebuild per subscription per
  /// [ClientConfig.freshnessDeadline] bounds it, and the first suppression
  /// says so on the surface `RemoteStateMan.complaints` publishes. On a
  /// healthy link this bookkeeping is never touched: G1c and G1d prove the
  /// comparison costs zero rebuilds when the two ends agree.
  ///
  /// **A page with no sequence at all is rebuilt too, and this is the door
  /// that used to be locked** (16-01, finding S1b). This loop used to skip
  /// `lastSeq == null` outright, on the reading that it meant "a subscribe
  /// whose snapshot has not landed yet". It means that, and it also means the
  /// opposite: `ResyncEngine._unestablish` sets it to null when a rebuild
  /// fails, deliberately, so the next frame is not read as a false gap. The
  /// one signal therefore carried both "not yet" and "given up on", and every
  /// path that could have healed the second was guarded against the first —
  /// `_update`'s rebuild at the method above, this loop here. A page dropped
  /// by one transient snapshot timeout was then blank until the socket
  /// happened to drop, which the heartbeat is specifically there to prevent,
  /// so in practice until somebody power-cycled the panel.
  ///
  /// **The gateway naming the page in its tick is what makes this safe.** A
  /// tick entry is the gateway stating, at its own cadence, that the
  /// subscription exists at its end — which is exactly the situation the
  /// defect produces, because the abandoned `subscribe` did arrive and was
  /// answered. A page the gateway has genuinely forgotten is never named, so
  /// this never asks for it and the reconnect path keeps that case.
  ///
  /// **Bounded by the same damper, and deliberately not by a retry counter.**
  /// One attempt per subscription per [ClientConfig.freshnessDeadline], the
  /// limit the mismatch case already uses. A counter would close the door
  /// again after N, and the condition this recovers from is congestion, which
  /// lasts as long as it lasts. `resync_test.dart`'s
  /// `costs nothing at all once the page has been left unestablished` keeps
  /// the *update* path shut, and it stays shut: what reopens here is the tick,
  /// at the tick's cadence, through the damper — not one rebuild per inbound
  /// frame, which is the storm that arm is about.
  Future<void> _tick(rpc.Parameters params) async {
    final tick = TickParams.fromJson(_asJson(sanitize(params.asMap).value));
    watchdog.sawTick(tick);
    for (final entry in tick.subs.entries) {
      // A subscription this client does not hold: skipped, and not a
      // complaint. It is a page somebody else opened on this session.
      final state = subscriptions[entry.key];
      if (state == null) continue;

      final lastSeq = state.lastSeq;
      // Established and no further along than this client: nothing to do. The
      // comparison is "ahead of", not "different from" — see above.
      if (lastSeq != null && entry.value.seq <= lastSeq) continue;

      // Null is the *other* reason to rebuild, and until 16-01 it was the
      // reason to give up. See this method's doc for the whole of it.
      final unestablished = lastSeq == null;

      if (!_mayRebuild(entry.key)) {
        // Once per subscription per connection, not once per suppressed tick:
        // a line at the tick cadence is the unbounded list WR-07 is about,
        // and every one of them would say the same thing.
        //
        // Only for the mismatch case, because only that one has anything to
        // report. A suppressed retry on an unestablished page is this client
        // pacing itself, and `_recover` has already said out loud why the page
        // is down.
        //
        // **And it says what is true, not what would be tidier** (16-07). This
        // sentence used to read "the mismatch survived the rebuild… the
        // disagreement is at the gateway", which is a claim about a rebuild
        // that has *finished*. The budget is stamped before the await, so on
        // any link where a rebuild's round trip outlasts one tick period —
        // which is every slow link, and slow links are what this client is
        // for — the rebuild it was talking about was still in flight. Saying
        // "the gateway is wrong" about a round trip that has not landed sends
        // the engineer to the wrong end of the plant.
        if (!unestablished && _resyncComplained.add(entry.key)) {
          _resync.complain('"${entry.key}" was rebuilt less than '
              '${config.freshnessDeadline.inMilliseconds} ms ago and the '
              'gateway is still advertising a sequence ahead of this client: '
              'it advertises ${entry.value.seq} and this client holds '
              '$lastSeq. Further rebuilds on this subscription are suppressed '
              'to one per ${config.freshnessDeadline.inMilliseconds} ms while '
              'that lasts. That rebuild may still be in flight — this line is '
              'stamped when a rebuild is declined, not when one has been '
              'proved not to help — so if the two ends agree again on the next '
              'tick, nothing further is said.');
        }
        continue;
      }
      await _resync.onResync(entry.key);
    }
  }

  /// The gateway announced that one page must be rebuilt.
  ///
  /// **The reason and duration are carried up, not dropped** (09-07 ruling 5a).
  /// Until now this decoded `ResyncParams` and used only `asked.sub`, throwing
  /// `asked.reason` and `asked.stalledMs` on the floor — so a panel could not
  /// say "gateway stalled" because nothing this side remembered that the
  /// gateway said so. The rebuild path is unchanged: it still goes through the
  /// one coalesced [ResyncEngine.onResync]. The stall surface is set *beside*
  /// it, on the existing getter seam `lastDownReason` uses, with no second
  /// notification channel and no stream.
  ///
  /// Only `gateway_stalled` touches the stall surface. A resync for any other
  /// reason — `epoch_changed`, `server_restart`, the ordinary ones — is not a
  /// stall and must leave the surface exactly as it was: neither cleared to a
  /// misleading default nor set to a bogus one. The reason vocabulary is
  /// `ResyncParams`' own (`messages.dart:455-464`).
  Future<void> _resynced(rpc.Parameters params) async {
    watchdog.sawFrame(InboundFrame.update);
    final asked = ResyncParams.fromJson(_asJson(sanitize(params.asMap).value));
    if (asked.reason == _gatewayStalled) {
      // The absolute figure the gateway sent, stored as-is: a panel renders it
      // as "the plant view was frozen for N ms", and recomputing it from this
      // panel's clock would drift (03-CONTEXT chose absolute).
      _stallReason = asked.reason;
      _stalledMs = asked.stalledMs;
      // The anchor stallAge measures from: this side's receipt instant, on
      // the monotonic clock. Re-stamped on every stall announcement, so a
      // second freeze on the same connection reads as freshly announced.
      _stallAtElapsedMs = _elapsed.elapsedMilliseconds;
      // Once per connection, not once per subscription: one stall is one
      // sentence, however many pages resync on it (07-REVIEW WR-02's damping
      // shape, applied to a new surface). Reset with the surface on the way
      // down. The duration also lives on the getter above, because a complaint
      // list is a diagnostic an engineer reads tomorrow, not a value a widget
      // binds to.
      if (!_stallComplained) {
        _stallComplained = true;
        _resync.complain(asked.stalledMs == null
            ? 'the gateway announced its event loop stalled; the plant view '
                'was frozen and every page on this connection is rebuilding '
                'from a fresh snapshot'
            : 'the gateway announced its event loop stalled for '
                '${asked.stalledMs} ms; the plant view was frozen for that '
                'long and every page on this connection is rebuilding from a '
                'fresh snapshot');
      }
    }
    await _resync.onResync(asked.sub);
  }

  /// An upstream device changed state. Carried up, never interpreted here.
  void _status(rpc.Parameters params) {
    watchdog.sawFrame(InboundFrame.update);
    final status = StatusParams.fromJson(_asJson(sanitize(params.asMap).value));
    _onStatus?.call(status);
  }

  /// The gateway is leaving on purpose. The close follows; the loop's answer
  /// to it is the same as to any other drop, because a draining gateway is a
  /// gateway that is coming back.
  void _bye(rpc.Parameters params) {
    watchdog.sawFrame(InboundFrame.update);
    final json = _asJson(sanitize(params.asMap).value);
    _onBye?.call('${json['reason'] ?? 'the gateway said goodbye'}');
  }

  /// Preferences changed somewhere else. Carried up, never interpreted here.
  ///
  /// **One frame, many keys, fanned out to one announcement each.** The frame
  /// carried a single `"key"` until Phase 10, which made a `clear()` over five
  /// hundred keys five hundred frames per connected client on the
  /// un-conflated priority lane — the way a settings page evicts every panel
  /// in the plant with `4004` (10-CONTEXT amendment 4). The list is the only
  /// shape: both ends of this wire are in one repository and nothing is
  /// deployed, so carrying a compatibility spelling forever would leave two
  /// names for one frame and every future reader to work out which they are
  /// looking at.
  ///
  /// **The fan-out is here; the coalescing is not.** Deciding what belongs in
  /// one frame is the gateway's job (10-05 task 2). A second buffer on this
  /// side would delay an edit an operator is watching for, to save nothing —
  /// the frames it would merge have already crossed the wire.
  void _preferenceChanged(rpc.Parameters params) {
    watchdog.sawFrame(InboundFrame.update);
    final json = _asJson(sanitize(params.asMap).value);
    final keys = json['keys'];
    if (keys is! List) {
      // Refused rather than announced under a guess, exactly as a frame with
      // no "key" was refused before: a settings listener told that "null"
      // changed goes and re-reads a preference nobody has.
      throw FormatException('preferences.changed carried no "keys" list');
    }
    // The whole frame or none of it. A frame this malformed came from a
    // gateway that is not sending what it thinks it is, and announcing the
    // readable half would hide that while leaving the other key stale.
    for (final key in keys) {
      if (key is! String || key.isEmpty) {
        throw FormatException(
            'preferences.changed named something that is not a key: $key');
      }
    }
    for (final key in keys) {
      _onPreferenceChanged?.call('$key');
    }
  }

  /// Wraps a handler body in the pre-substituted armor.
  Future<void> _armored(String name, FutureOr<void> Function() body) async {
    try {
      await body();
    } catch (error) {
      throw rpc.RpcException(
          _handlerFailed, 'this panel could not handle "$name": $error',
          data: _substitute(name));
    }
  }

  /// The request, replaced by the reason it is not here.
  ///
  /// Verbatim from `relay_session.dart:521-526`, including the reasoning: a
  /// request holding a non-finite number makes the error that echoes it
  /// unencodable, and an unencodable error is a hang on every error path that
  /// peer has.
  static Map<String, Object?> _substitute(String method) => {
        'method': method,
        'request': 'omitted: echoing a request that may carry a non-finite '
            'number is what makes the error itself unencodable, and an '
            'unencodable error on a path with no deadline is a hang',
      };

  /// The peer's `listen()` finished, either way. Same teardown for both.
  void _transportEnded(int gen) => _down(gen, 'the transport ended');

  /// [FreshnessWatchdog.freshnessDeadline] passed with no frame of any kind.
  ///
  /// **A half-open socket is not a connection** (04-REVIEW CR-06). Nothing
  /// below the application layer will say so — `readyState` lies after an OS
  /// sleep (STACK), and a NAT that dropped the flow sends nothing at all — so
  /// the only end of this the client controls is to stop believing in the peer
  /// and dial again. Routed through [_down] rather than through a bespoke
  /// path, so the barrier is re-armed, `LinkState` leaves `ready`, and the
  /// backoff schedule is the same one every other kind of drop uses. Without
  /// it the panel read `ready`, `isReady == true` and `Quality.good` over
  /// values that had stopped moving.
  void _linkWentQuiet() {
    if (_disposed || _stopped) return;
    // Only a connection that thinks it is up can go quiet. In `down` or
    // `connecting` there is a reconnect already scheduled, and a second one
    // here would halve the backoff the schedule just chose.
    if (_state != LinkState.ready && _state != LinkState.resyncing) return;
    _down(_generation,
        'no frame of any kind for ${config.freshnessDeadline.inMilliseconds} '
        'ms: the socket is open and the gateway has stopped speaking, which '
        'is the half-open case a close code never arrives for');
  }

  /// This connection is over: retire it, re-arm, and schedule the next.
  void _down(int gen, String why) {
    if (_disposed || gen != _generation) return;
    _generation++;
    _retirePeer();
    // Re-armed so the next caller waits for the new link rather than being
    // let through to a socket that is gone. Everyone already through stays
    // through — a completed future cannot un-complete. The session gate is
    // re-armed beside it and for the same reason: a sign-in queued against a
    // socket that has gone must wait for the next hello, not be sent into a
    // peer that is closing. `awaitingSignIn` is cleared — the next
    // connection re-derives it from its own hello.
    barrier.rearm();
    _rearmSession();
    _awaitingSignIn = false;
    _lastDownReason = why;
    _enter(LinkState.down);
    if (_stopped) return;
    _schedule();
  }

  /// The gateway refused this build. Retrying will not change its mind.
  ///
  /// Deliberately *not* guarded by generation: the refusal and the close that
  /// follows it are one event, and whichever of the two arrives first must be
  /// able to stop the loop — including cancelling a retry the other one had
  /// already scheduled.
  void _stop(String why) {
    if (_disposed || _stopped) return;
    _stopped = true;
    _stopReason = why;
    _generation++;
    _retry?.cancel();
    _retry = null;
    _retirePeer();
    barrier.rearm();
    _rearmSession();
    _awaitingSignIn = false;
    _enter(LinkState.down);
  }

  void _retirePeer() {
    final peer = _peer;
    _peer = null;
    if (peer == null) return;
    // Closing the peer closes the channel's sink, which closes the socket.
    // Nothing waits on it: a close that fails is a socket that was already
    // gone, which is the ordinary shape of a teardown after a cut cable.
    unawaited(peer.close().catchError((Object _) {}));
  }

  void _schedule() {
    _retry?.cancel();
    final wait = backoff.next();
    _waits.add(wait);
    // Bounded (04-REVIEW IN-02). One entry per attempt and never trimmed is a
    // leak with a diagnostic excuse: a panel whose gateway is down all shift
    // makes an attempt every backoffCap. What the list answers — "what has the
    // schedule been doing lately" — is a question about the recent past.
    if (_waits.length > _waitHistory) _waits.removeAt(0);
    _retry = Timer(wait, () {
      _retry = null;
      unawaited(_attempt());
    });
  }

  /// Announces a transition, and performs the two things that belong to
  /// entering a state rather than to the code path that got there.
  void _enter(LinkState next) {
    if (_disposed || _state == next) return;
    _state = next;
    if (next == LinkState.down) {
      // A genuine reconnect starts fresh: the next connection's first
      // divergent tick earns a rebuild and, if it survives one, its own
      // complaint. Carrying the suppression across would let a page that
      // recovered be refused the rebuild it needs.
      _resyncAtMs.clear();
      _resyncComplained.clear();
      // The stall surface is a fact about the socket that heard the
      // announcement (09-07): a new connection starts with no stall reason, and
      // the once-per-connection complaint damper re-arms.
      _stallReason = null;
      _stalledMs = null;
      _stallAtElapsedMs = null;
      _stallComplained = false;
    }
    if (next == LinkState.ready) {
      barrier.open();
      // **Here and nowhere else.** See the library doc: a link earns its
      // forgiveness by delivering a snapshot, not by answering the phone.
      backoff.reset();
      // And the badge clears on the same principle, for the same reason
      // (16-10, finding S9). Reaching `ready` is the only moment this client
      // knows every page has cleared its store and adopted a snapshot from
      // *this* connection; a frame arriving somewhere upstream of that proves
      // the link is alive and nothing at all about what is on the screen. The
      // link deadline is still fed by every inbound frame, including the hello
      // and subscribe responses — that is the half-open detector and it is a
      // different signal. See [FreshnessWatchdog.viewBecameFresh].
      watchdog.viewBecameFresh();
    }
    if (!_states.isClosed) _states.add(next);
  }

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  /// Narrows a decoded frame to the map shape the DTOs take.
  static Map<String, Object?> _asJson(Object? raw) => raw is Map
      ? {for (final entry in raw.entries) '${entry.key}': entry.value}
      : throw FormatException('expected a JSON object, got ${raw.runtimeType}');
}

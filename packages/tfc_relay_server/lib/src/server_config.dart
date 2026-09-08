/// Every number the gateway runs on, in one place, with the combinations that
/// cannot work refused at construction.
///
/// Pure data: no I/O, no clock — nothing here reads `DateTime.now` or starts a
/// `Timer`. The tick engine owns the clock and is handed one of these.
///
/// A number that lives at five call sites is a number that drifts, and three
/// of these were measured rather than chosen:
///
/// * **The heartbeat deadline must be shorter than the ping interval.**
///   03-RESEARCH Finding 7 measured a black-holed client — socket open,
///   traffic dropped both directions — being reaped 3.70 s after the blackhole
///   at a 2 s `pingInterval`. That is **1.85×** the interval, and at the
///   design's 20 s it extrapolates to a **~37 second** window in which the
///   gateway still believes a dead panel is alive: still holding its
///   subscriptions, its send buffer, and its upstream monitored items. The
///   project constraint is "half-open connections detected in seconds". So the
///   app-level heartbeat is the reaper and the WS ping is NAT keepalive plus a
///   backstop for the case where the client is alive but its heartbeat logic
///   is broken. Encoding that as a construction rule rather than a convention
///   is what stops the ~37 s hole being configured back in by someone who
///   reads `pingInterval` as the liveness deadline — which is exactly how it
///   reads.
/// * **The stall threshold sits above the noise floor.** Finding 10 measured
///   idle event-loop drift at ±2 ms. A threshold inside that reports a stalled
///   loop on a server doing nothing, and an alarm that is always on is an
///   alarm nobody reads.
/// * **The tick band is 50–100 ms** (SRV-03). Outside it the server still
///   runs and still passes every functional test; it is just a different
///   product. A 500 ms tick is a slideshow of the plant.
library;

import 'dart:io' show InternetAddress;

import 'auth/auth_config.dart';
import 'tls/tls_config.dart';
import 'tls/trust.dart';

/// The knobs a gateway is started with.
///
/// Named arguments with defaults, in the style of
/// `ConflatingSendBuffer` — the caller sets what it cares about and the rest
/// are the researched numbers.
final class ServerConfig {
  /// How often the tick engine drains, polls backpressure, sweeps heartbeats
  /// and samples event-loop lag. Must be within [minTick]–[maxTick].
  final Duration tick;

  /// How long a session may go without an app-level heartbeat before it is
  /// reaped. 6 s is OPC UA's 3× LifetimeCount ratio over a 2 s app heartbeat.
  /// This — not [pingInterval] — is the liveness deadline.
  ///
  /// Bounded above by [pingInterval] and below by [minHeartbeatDeadline].
  final Duration heartbeatDeadline;

  /// The shortest [heartbeatDeadline] this gateway will accept.
  ///
  /// **The bound the reaper was missing** (07-REVIEW WR-01). A panel that is
  /// only watching a page beats a `ping` at
  /// `ClientConfig.heartbeatFloor` at the fastest, and its skip-on-traffic
  /// rule means this gateway can see up to **two** floors of silence between
  /// beats. So a deadline at or below two floors reaps every healthy panel in
  /// the plant once a cycle — 07-08's measured three-reaps-in-twenty-one-
  /// seconds, reinstated by configuration alone, with the panel's pump running
  /// and its counters climbing. Nothing here noticed: the only bound was the
  /// one against [pingInterval], which is a bound from the other end.
  ///
  /// **A parameter rather than a constant**, for the reason
  /// `ClientConfig.deadlineFloor` is one: `liveness_test.dart` has to watch a
  /// reap happen inside its own budget and a suite that waited three seconds
  /// per arm is a suite somebody deletes. Going below the floor is then a
  /// sentence the caller writes rather than a default they inherit.
  final Duration minHeartbeatDeadline;

  /// WebSocket ping period: NAT keepalive, and a backstop for a client whose
  /// heartbeat logic is broken while its socket still works. Never the reaper.
  final Duration pingInterval;

  /// How far the event loop may drift past a scheduled tick before the lag
  /// monitor calls it a stall. An absolute duration (03-CONTEXT amendment),
  /// defaulting to three ticks.
  final Duration stallThreshold;

  /// Hard ceiling on entries pending for one client; exceeding it is an
  /// immediate disconnect (HA: MAX_PENDING_MSG). Handed straight to each
  /// session's `ConflatingSendBuffer`.
  ///
  /// **It bounds *production*, not client backlog** (03-REVIEW WR-11). The
  /// engine drains every tick and `ws.sink.add` never blocks, so the count
  /// this is compared against is what the server produced for one client
  /// during one tick. On `dart:io` WebSockets there is no observable client
  /// backlog at all — it sits in the socket's own unbounded write buffer — so
  /// **this is a production ceiling and not the slow-consumer defence.** That
  /// role now belongs to `ConflatingSendBuffer.ackGapThreshold`, which measures
  /// what the client says it has applied (`16-02-DECISION.md`, option (c));
  /// `tick_engine.dart`'s library doc carries the full statement, including
  /// which half of SRV-04 is closed and which is not.
  ///
  /// **It stays hard regardless** (T-16-02b). This is a memory ceiling: it
  /// bounds what one client can make this isolate hold, and the isolate serves
  /// every screen in the plant. No claim a client makes about itself can raise
  /// it or defer it.
  final int maxPending;

  /// Soft ceiling on **production**: how many entries this server may pile up
  /// for one client in one tick, sustained over [peakWindowMs].
  ///
  /// **Null by default since 16-08, and that is the fix rather than a
  /// loosening** (`16-02-DECISION.md` §5.4). This was documented as the
  /// slow-consumer defence and measurement showed it was the opposite of one.
  /// At the shipping 1024 a panel that had stopped reading altogether produced
  /// **41 pending entries a tick** — the defence sat two orders of magnitude
  /// from tripping on a comprehensively broken session — while a **healthy**
  /// 1100-key page was disconnected after 10.1 s with a 4004 that told it it
  /// could not keep up. Worse, survival did not depend on severity: 1100 and
  /// 1800 changed handles were both evicted after the same 202 ticks, because
  /// the verdict is a timer on being above a line and not a measure of how far
  /// above it. A 1500-key page — the size this project's own fan-out benchmark
  /// uses — was above the line on every tick it changed, so it was
  /// disconnected every ten seconds and reconnected into the same wall.
  ///
  /// **The field stays** because an operator may legitimately want a
  /// production ceiling, and setting it restores exactly the old behaviour
  /// under a name that no longer lies about what it measures. What replaced it
  /// as the slow-consumer defence is `ConflatingSendBuffer.ackGapThreshold`,
  /// which measures delivery. The two hard memory ceilings — [maxPending] and
  /// [maxPendingBytes] — did **not** move (T-16-02b) and are unaffected by any
  /// of this.
  final int? peakThreshold;

  /// How long [peakThreshold] may be exceeded continuously before the session
  /// is disconnected. Matches `ConflatingSendBuffer`'s own default.
  ///
  /// The window only accumulates because `drain()` no longer clears it
  /// (03-REVIEW WR-02): a drain is the server's own schedule, and only a poll
  /// that reads a count under the threshold counts as recovery.
  final int peakWindowMs;

  /// Ceiling on the size of one **inbound** frame, in bytes, enforced before
  /// `jsonDecode` ever sees it (03-REVIEW WR-04, threat T-03-29).
  ///
  /// There was no frame-size limit anywhere in the path: `shelf_web_socket`
  /// sets only `pingInterval`
  /// (`shelf_web_socket-3.0.0/lib/src/web_socket_handler.dart:93`). The
  /// default is generous against what legitimately arrives — the largest real
  /// request is a `subscribe` carrying [maxKeysPerSubscribe] keys, about
  /// 120 kB at 2000 keys — and small against the amplification shape, where
  /// one garbage frame is echoed back verbatim by json_rpc_2's parse-error
  /// responder and held in the priority lane until the next tick.
  ///
  /// Phase 6 owns the full ingress hardening; this is the number, in place,
  /// with a refusal that names itself.
  final int maxFrameBytes;

  /// Byte budget for one session's priority lane, handed to its
  /// `ConflatingSendBuffer`. See [ConflatingSendBuffer.maxPendingBytes]:
  /// [maxPending] counts entries, and 4096 arbitrarily large entries is a
  /// heap rather than a queue.
  final int maxPendingBytes;

  /// Browser origins allowed to open a WebSocket, passed to
  /// `shelf_web_socket`. Empty — the default — rejects every browser `Origin`
  /// with 403 while leaving the panels, which are not browsers and send no
  /// `Origin`, entirely unaffected (03-RESEARCH Finding 1). Phase 6 supplies
  /// the real list when the web bundle ships; until then an empty list is the
  /// cross-site-WebSocket-hijacking defence, not a gap.
  ///
  /// **Not nullable, and that is a tested property** (`origin_test.dart`).
  /// `shelf_web_socket` skips the check entirely when the list is `null`
  /// (`web_socket_handler.dart:71-77`: `origin != null && _allowedOrigins !=
  /// null && …`), measured in 06-RESEARCH §F.1 — so `null` is not "no
  /// restriction configured yet", it is "cross-site WebSocket hijacking is
  /// permitted". An empty list and a null list read almost identically in a
  /// diff and mean opposite things, and the type is the only thing standing
  /// between them. Anyone tidying `List<String>` into `List<String>?` to
  /// express "unset" is removing the defence; a structural pin fails first.
  final List<String> allowedOrigins;

  /// Ceiling on keys in a single `subscribe` call. A real panel carries about
  /// 1500 keys, so the default has headroom for the largest screen and still
  /// refuses an unbounded list — one of the two cheapest denial-of-service
  /// shapes against this server (03-05 threat register T-03-13). 03-05's
  /// handler is what enforces it; this is where the number lives.
  final int maxKeysPerSubscribe;

  /// Ceiling on live subscriptions held by one session. The other cheap
  /// denial-of-service shape: one authenticated client opening subscriptions
  /// until the server's memory is gone (T-03-14).
  final int maxSubscriptionsPerSession;

  /// Ceiling on `maxPoints` in one `queryTimeseriesDataDownsampled`.
  ///
  /// **Arithmetic, not taste.** The widest panel in this plant is 1920 px, a
  /// chart is at most that wide, and a downsampled bucket contributes three
  /// points — min, max and last (`database.dart`: "Each bucket produces 3
  /// points"). So 3 × 1920 = 5760 points is already more than a full-width
  /// chart can put on distinct columns, and this rounds that up. Above it the
  /// caller is not drawing a chart: it is asking for a raw query under the
  /// bounded method's name, which is exactly what having a separate bounded
  /// method is for (`state_man_api.dart:277-283` — "a month of one-second
  /// samples is millions of points and a chart has hundreds of pixels").
  ///
  /// The **floor** is [minTimeseriesPoints] and it is not configurable, for
  /// the reason stated there.
  final int maxTimeseriesPoints;

  /// The smallest `maxPoints` a downsampled query may ask for.
  ///
  /// **Three, and it is not a knob**, because it is a property of the code
  /// being called rather than of this deployment.
  /// `queryTimeseriesDataDownsampled` computes
  /// `numBuckets = (maxPoints / 3).floor()` and, when that is zero,
  /// **silently falls back to the unbounded raw query** (`database.dart`).
  /// A `maxPoints` of 0, 1 or 2 is therefore a month of one-second samples
  /// wearing the bounded method's name, and refusing it at the wire is what
  /// keeps the one bounded method bounded. The other three fallback branches
  /// in that method — a zero-width range, an unknown column type and a
  /// non-numeric column — are 10-10's, because none of them is decidable from
  /// a wire parameter.
  static const int minTimeseriesPoints = 3;

  /// How long the gateway remembers what became of a write, so `writeStatus`
  /// can answer about it after a reconnect.
  ///
  /// It is a window and not a permanent ledger because the log is per-session
  /// memory an authenticated client can grow one write at a time (T-04-06),
  /// and because the question it answers has a shelf life: an operator
  /// reconciling a button press does it within seconds of the link coming
  /// back, not the next morning.
  ///
  /// The number is also the boundary of a *safety* claim rather than of a
  /// convenience. `writeStatus` may answer `not_received` — the one outcome
  /// that tells an operator a re-send is safe — only for a command minted
  /// inside this window, because outside it the gateway cannot tell "never
  /// arrived" from "arrived, and forgotten". 60 s is the reconnect budget
  /// (backoff capped at 30 s, so one full retry cycle plus a resync) with
  /// room to spare.
  final Duration writeOutcomeTtl;

  /// The certificate and key the gateway presents, or `null` for plaintext
  /// `ws://`.
  ///
  /// **`null` is the default and it means plaintext.** Not because cleartext
  /// on a plant LAN is acceptable — it is what SEC-02 exists to end — but
  /// because the alternative is worse in exactly one way that matters: ten
  /// bind/dial fixture sites in this package construct a `ServerConfig` with
  /// no TLS argument and bind loopback on an ephemeral port, and a default
  /// that made them all TLS would rewrite ten fixtures for no requirement.
  /// A rewritten fixture is how a suite quietly stops testing what it used to.
  ///
  /// `null` here is therefore an **explicit choice, visible in a config
  /// diff** — and it is a categorically different thing from a gateway that
  /// was configured with TLS and fell back to plaintext because a path was
  /// misspelled. There is no such fallback: [RelayServer.start] lets the
  /// `FileSystemException` out (`tls_test.dart`, "a misspelled certificate
  /// path fails the start, it does not serve ws").
  final TlsConfig? tls;

  /// Where the per-station token file is mounted, or `null` for a gateway
  /// that checks no credential.
  ///
  /// `null` is the default for the same reason [tls]'s is: every fixture in
  /// this package builds a `ServerConfig` with no auth argument and runs on
  /// `PermissiveTokenValidator`, and a default that demanded a token file
  /// would rewrite them all for no requirement. A rewritten fixture is how a
  /// suite quietly stops testing what it used to.
  ///
  /// It is an **explicit choice, visible in a config diff** — and it is not a
  /// fallback. A gateway configured with a token file whose load fails does
  /// not admit everybody: [RelayServer.start] lets the exception out, exactly
  /// as a misspelled PEM path does.
  ///
  /// Supplying this *and* an explicit `validator:` to `RelayServer` is refused
  /// at construction: two sources of truth for the credential check is a
  /// configuration nobody can reason about.
  final AuthConfig? auth;

  /// Where the CA root this gateway serves for pinning is mounted, or `null`
  /// for a gateway that serves none.
  ///
  /// Non-null binds one extra plaintext listener at **[port] + 1** answering
  /// `GET /relay-trust` with the root and its fingerprint — the acquisition
  /// half of the one-URL configuration flow (`tls/trust.dart` argues why
  /// plaintext is correct there and nowhere else). `null` is the default for
  /// [tls]'s reason: every existing fixture and deployment constructs without
  /// it and must not grow a listener it did not ask for.
  ///
  /// Refused when [tls] is null: a plaintext gateway has no certificate for
  /// the served root to vouch for, so the endpoint would offer panels an
  /// anchor that anchors nothing — and the panel would then refuse the
  /// `ws://` dial for carrying it.
  final TrustConfig? trust;

  /// The interface the gateway binds.
  ///
  /// Loopback by default (threat T-03-11), and the default is deliberately
  /// **not** the deployment: exposing the gateway on a plant interface is a
  /// decision with a firewall attached to it, not something a default should
  /// do quietly. This field is what lets a deployment be deliberate about it.
  final InternetAddress address;

  /// The TCP port the gateway binds. `0` asks the operating system for an
  /// ephemeral one, which is why two servers can run in one test process
  /// without agreeing on a number.
  final int port;

  /// What this gateway calls itself on the wire, or null to say nothing.
  ///
  /// The Sparkplug `publisherId` adoption (07-RESEARCH-PUBSUB). A plant that
  /// runs two gateways has two things called `ST201` — the same alias, two
  /// different processes watching it — and a captured frame that does not say
  /// which one produced it is a frame nobody can attribute during the incident
  /// it was captured for.
  ///
  /// **Advisory, and additive.** Nothing routes on it: it rides at the top
  /// level of `HelloResult` and on `StatusParams`, both of which omit the key
  /// entirely when it is null. So a deployment that configures none sends
  /// exactly the bytes it sent before this field existed, which is what
  /// `final_tick_test.dart`'s captured literal pins — a `publisherId: null` on
  /// the wire would be a payment extracted from every deployment that did not
  /// ask for the feature.
  ///
  /// Null by default for the same reason [tls] and [auth] are: the default is
  /// deliberately not the deployment.
  final String? publisherId;

  // -------------------------------------------------------------------------
  // The pre-hello budget (16-09, WSH-13). Two knobs, one purpose.
  //
  // The token file gates `hello`, not the upgrade: `RelayServer._onConnect`
  // consults no credential, so anything that completes TLS gets a session
  // built for it — a `ConflatingSendBuffer`, a `SessionSink`, a per-session
  // health overlay and a `Peer` — before it has said who it is. These two
  // bound how long that costs and how many of them there may be at once.
  // What they cannot bound is the size of one assembled frame; that residual
  // is documented where it bites, at `RelaySession._underCeiling`.
  // -------------------------------------------------------------------------

  /// How long a connection may sit upgraded without saying `hello` before the
  /// gateway takes it back.
  ///
  /// **Strictly shorter than [heartbeatDeadline], and refused otherwise.** A
  /// pre-hello deadline at or above the heartbeat one is incoherent: the
  /// heartbeat reaper already closes an un-helloed socket at
  /// [heartbeatDeadline] — `RelaySession`'s `_LastSeen.touch` will not move
  /// until the session has helloed, so an un-helloed peer's silence is simply
  /// its age — and a second deadline that fires no earlier is a knob with no
  /// effect, which is worse than no knob.
  ///
  /// **The default is derived, not a number typed beside another number.**
  /// Absent an explicit value it is [heartbeatDeadline] divided by
  /// [preHelloShareOfHeartbeat], which at the 6 s shipping default is **2 s**.
  /// Deriving rather than fixing it buys the property that matters: every
  /// configuration that was coherent before this field existed is still
  /// coherent, including the deliberately fast ones a test runs
  /// (`liveness_test.dart` runs a 400 ms heartbeat deadline and now gets a
  /// 133 ms pre-hello one) — a fixed 2 s default would have refused those at
  /// construction, which is a config field breaking configurations it has
  /// nothing to say about.
  ///
  /// **The number, at the shipping defaults, is 2 s, and it is sized from the
  /// client end.** What has to fit between the upgrade completing and the
  /// `hello` arriving is the frame on the wire (about 300 bytes, so 24 ms even
  /// on the hundred-kilobit link `slow_link_gate_test.dart` measures a panel
  /// over — bandwidth is not the term that matters), the panel's own
  /// scheduling while it builds its first page, and a retransmit round trip.
  /// `ClientConfig.connectTimeout` sizes its own 10 s as "a generous hang
  /// guard rather than a tight bound" against the same client behaviour. 2 s
  /// is far past all three, and it lands below
  /// [defaultMinHeartbeatDeadline] — so the pre-hello deadline is shorter than
  /// *any* heartbeat deadline a real gateway is permitted to run, not merely
  /// shorter than the default one.
  ///
  /// `pre_hello_budget_test.dart`'s arm 3 is what keeps this honest from the
  /// other direction: a deadline of one millisecond satisfies every arm about
  /// the deadline biting, while disconnecting every panel in the plant before
  /// it can speak.
  final Duration preHelloDeadline;

  /// Ceiling on how many sessions may be un-helloed **at once**.
  ///
  /// Consulted by `RelayServer._onConnect` before the connection is
  /// registered, so a connection over the budget is refused rather than
  /// registered and then closed — one that is registered has already paid for
  /// everything the cap exists to avoid.
  ///
  /// **It counts un-helloed sessions, never sessions.** A cap on sessions
  /// would cap the plant: the twenty-first panel switched on in the morning
  /// would be refused by a defence aimed at an attacker. The count is derived
  /// from the connection table rather than kept as a counter, which is why
  /// there is no "decrement on hello" and no "decrement on teardown" to get
  /// wrong — see `RelayServer.unhelloedCount` for that argument in full.
  ///
  /// **Sized against the plant, and the product is the residual.** SVN runs
  /// tens of panels, and the worst legitimate burst is all of them
  /// reconnecting at once after a gateway restart — every one of them
  /// un-helloed for the same instant. 64 is several times that. It is also
  /// the number that makes the exposure sayable: 64 concurrent un-helloed
  /// peers times [maxFrameBytes] is **64 MiB** of assembled frames that this
  /// gateway can be made to hold by peers that have presented no credential,
  /// and that product — not either number alone — is what
  /// `RelaySession._underCeiling` documents as accepted.
  final int maxUnhelloedSessions;

  /// What fraction of [heartbeatDeadline] a peer gets to say `hello` in, when
  /// [preHelloDeadline] is not set explicitly.
  ///
  /// A third: it leaves the remaining two thirds of the silence budget to the
  /// thing that budget is actually about, and at the 6 s default it lands the
  /// pre-hello deadline at 2 s — below [defaultMinHeartbeatDeadline], which is
  /// the property worth having (see [preHelloDeadline]).
  static const int preHelloShareOfHeartbeat = 3;

  /// The default [maxUnhelloedSessions]. See it for the sizing.
  static const int defaultMaxUnhelloedSessions = 64;

  // ------------------------- end of the pre-hello budget -------------------

  /// The tick band's lower bound (SRV-03).
  static const Duration minTick = Duration(milliseconds: 50);

  /// The tick band's upper bound (SRV-03).
  static const Duration maxTick = Duration(milliseconds: 100);

  /// The measured idle event-loop drift noise floor is ±2 ms (Finding 10);
  /// this is the smallest stall threshold that means anything above it.
  static const Duration minStallThreshold = Duration(milliseconds: 10);

  /// Three times `ClientConfig.heartbeatFloor`'s 1 s default — the smallest
  /// deadline a panel on its floor can meet with any margin at all. See
  /// [minHeartbeatDeadline].
  static const Duration defaultMinHeartbeatDeadline = Duration(seconds: 3);

  ServerConfig({
    this.tick = const Duration(milliseconds: 100),
    this.heartbeatDeadline = const Duration(seconds: 6),
    this.minHeartbeatDeadline = defaultMinHeartbeatDeadline,
    this.pingInterval = const Duration(seconds: 20),
    this.stallThreshold = const Duration(milliseconds: 300),
    this.maxPending = 4096,
    this.peakThreshold,
    this.peakWindowMs = 10_000,
    this.allowedOrigins = const [],
    this.maxKeysPerSubscribe = 2000,
    this.maxSubscriptionsPerSession = 32,
    this.maxTimeseriesPoints = 6000,
    this.maxFrameBytes = 1024 * 1024,
    this.maxPendingBytes = 8 * 1024 * 1024,
    this.writeOutcomeTtl = const Duration(seconds: 60),
    this.tls,
    this.auth,
    this.trust,
    this.publisherId,
    // The pre-hello budget (16-09). `preHelloDeadline` is nullable in and
    // non-null out: null means "derive it from heartbeatDeadline", which is
    // not the same request as any particular duration and so cannot be
    // spelled as a default value here.
    Duration? preHelloDeadline,
    this.maxUnhelloedSessions = defaultMaxUnhelloedSessions,
    InternetAddress? address,
    this.port = 0,
  })  : address = address ?? InternetAddress.loopbackIPv4,
        preHelloDeadline = preHelloDeadline ??
            heartbeatDeadline ~/ preHelloShareOfHeartbeat {
    if (tick < minTick || tick > maxTick) {
      throw ArgumentError('tick (${_ms(tick)}) is outside the supported band '
          '${_ms(minTick)}–${_ms(maxTick)}: below it the server burns a core '
          'redrawing screens nobody reads that fast, above it the plant '
          'arrives as a slideshow');
    }
    if (heartbeatDeadline < minHeartbeatDeadline) {
      throw ArgumentError(
          'heartbeatDeadline (${_ms(heartbeatDeadline)}) is below '
          'minHeartbeatDeadline (${_ms(minHeartbeatDeadline)}): a panel that '
          'is only watching a page beats at its ClientConfig.heartbeatFloor '
          'and skips a beat whenever it has just sent something else, so this '
          'gateway can see two floors of silence from a perfectly healthy '
          'panel. A deadline that short reaps every screen in the plant once '
          'a cycle, for ever, and the only symptom from outside is that '
          'sessionCount keeps coming back. Lower minHeartbeatDeadline '
          'deliberately if this is a fault case rather than a gateway');
    }
    if (heartbeatDeadline >= pingInterval) {
      throw ArgumentError(
          'heartbeatDeadline (${_ms(heartbeatDeadline)}) must be shorter than '
          'pingInterval (${_ms(pingInterval)}): half-open detection through '
          'the ping was measured at 1.85x the interval, so a deadline the '
          'ping could beat leaves a window — ~37 s at a 20 s interval — in '
          'which the gateway serves a dead panel\'s subscriptions to nobody');
    }
    if (stallThreshold < minStallThreshold) {
      throw ArgumentError('stallThreshold (${_ms(stallThreshold)}) is inside '
          'the measured +/-2 ms idle drift; it must be at least '
          '${_ms(minStallThreshold)} or the lag monitor reports a stall on an '
          'idle server');
    }
    if (writeOutcomeTtl <= Duration.zero) {
      throw ArgumentError('writeOutcomeTtl (${_ms(writeOutcomeTtl)}) must be '
          'positive: a gateway that remembers no write outcome for any length '
          'of time answers every writeStatus with "never received", which is '
          'the one answer that tells an operator it is safe to actuate the '
          'machine a second time');
    }
    // Deliberately not `_positive` (trap 7): 0 is not a broken ceiling here,
    // it is the ephemeral-port request every fixture in the package depends
    // on. What is refused is a number no `bind` can accept — which otherwise
    // surfaces as a raw `SocketException` from deep inside `start()`.
    if (port < 0 || port > 65535) {
      throw ArgumentError('port ($port) is outside 0-65535: 0 asks the '
          'operating system for an ephemeral port and anything else must be '
          'a real one, or the gateway fails to bind at boot on a plant '
          'machine nobody is standing next to');
    }
    if (trust != null && tls == null) {
      throw ArgumentError('trust is configured on a plaintext gateway: the '
          'trust endpoint serves the CA root a pinned panel verifies this '
          'gateway under, and with no TlsConfig there is no certificate for '
          'that root to vouch for. Panels that fetched it would then refuse '
          'their own ws:// dial for carrying a root that is never consulted. '
          'Configure tls as well, or drop trust deliberately');
    }
    _positive('maxPending', maxPending);
    _positive('peakWindowMs', peakWindowMs);
    _positive('maxKeysPerSubscribe', maxKeysPerSubscribe);
    _positive('maxFrameBytes', maxFrameBytes);
    _positive('maxPendingBytes', maxPendingBytes);
    _positive('maxSubscriptionsPerSession', maxSubscriptionsPerSession);
    // --- the pre-hello budget (16-09) ---
    if (this.preHelloDeadline <= Duration.zero) {
      throw ArgumentError(
          'preHelloDeadline (${_ms(this.preHelloDeadline)}) must be positive: '
          'a non-positive deadline closes every connection at the instant it '
          'is upgraded, so no panel in the plant can ever say hello and the '
          'gateway serves nobody while looking perfectly healthy from the '
          'outside — sessionCount simply keeps coming back to zero');
    }
    if (this.preHelloDeadline >= heartbeatDeadline) {
      throw ArgumentError(
          'preHelloDeadline (${_ms(this.preHelloDeadline)}) must be shorter '
          'than heartbeatDeadline (${_ms(heartbeatDeadline)}): an un-helloed '
          'socket is already closed at the heartbeat deadline, because '
          'RelaySession\'s _LastSeen refuses to move until the handshake '
          'lands — so a pre-hello deadline that is not strictly shorter fires '
          'no earlier than the reaper that already existed and bounds '
          'nothing. Leave it unset to take heartbeatDeadline / '
          '$preHelloShareOfHeartbeat, or set it deliberately below the '
          'deadline it is supposed to beat');
    }
    _positive('maxUnhelloedSessions', maxUnhelloedSessions);
    // --- end of the pre-hello budget ---
    final peak = peakThreshold;
    if (peak != null && peak <= 0) {
      _positive('peakThreshold', peak);
    }
  }

  static void _positive(String name, int value) {
    if (value <= 0) {
      throw ArgumentError('$name ($value) must be positive: a non-positive '
          'ceiling refuses work the server exists to do');
    }
  }

  static String _ms(Duration d) => '${d.inMilliseconds} ms';
}

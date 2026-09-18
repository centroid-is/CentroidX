/// A TCP proxy that can break the connection on purpose, one lever at a time.
///
/// A fresh rewrite of `packages/tfc_dart/test/proxy.dart` rather than an
/// extension of it (CONTEXT). Two of that file's behaviours are hard-won and
/// deliberately kept — binding on port 0 with a [port] accessor, and
/// destroying both ends of every pair on close. Three of its habits are
/// deliberately not: the ungated `to.add(data)` in both directions (RESEARCH
/// Finding 7: 4463 MB of RSS in four seconds against a stalled consumer, which
/// is why every byte here goes through a [DelayLine]), the 100 ms sleep
/// inside `reject()` — a guess about someone else's scheduler, simultaneously
/// too slow for every run and too short for a loaded CI box, which is what
/// `within()` exists to replace — and the doc claiming `destroy()` sends a
/// reset
/// (Finding 1: on POSIX it is a clean FIN except by coincidence — see
/// `socket_ops.dart`).
///
/// **Every mode was declared before any was implemented.** [faultModes] names
/// all eight, each has its lever on this class, and until 02-11 the ones whose
/// behaviour had not landed threw [UnimplementedError] naming the plan they
/// would land in. All eight have landed now, so nothing here throws that any
/// more — but the rule the scaffolding enforced still holds for a ninth: a
/// lever that exists and quietly does nothing is worse than one that does not
/// compile, because the mode test passes, the fault was never injected, and CI
/// reports coverage of precisely the property that is missing.
/// `test/faults/proxy_core_test.dart` keeps that gate, and it re-arms by
/// itself the moment a name is added to [faultModes] without a test file
/// beside it.
///
/// **Loopback only.** The listener binds [InternetAddress.loopbackIPv4] and
/// there is no option to widen it. A process whose whole purpose is to sever
/// connections, withhold responses and reset sockets must not be reachable
/// from another machine, and a `bindAddress` parameter is how that becomes
/// possible by accident on somebody's laptop.
///
/// **Lever names echo `StateManHarness`** where the concepts overlap
/// (CONTEXT), and the correspondence is stated on both sides:
/// `StateManHarness.disconnectUpstream` already names `flap(down)` as its
/// proxy counterpart, and `reconnectUpstream` names `flap(up)`. A case written
/// against one transfers to the other unchanged, which is the entire reason
/// Phase 3 and Phase 4 can run their halves of the contract suite through
/// this proxy without rewriting their assertions.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'delay_line.dart';
import 'socket_ops.dart';

/// The eight fault modes, as data.
///
/// The one place that knows the proxy has eight modes — the same
/// registry-as-data argument `tfc_stateman_contract.dart:89-104` makes for the
/// seven contract sub-suites. Plan 02-14's integrity sweep iterates this list
/// in both directions: every named mode must have a test that proves it bites,
/// and every mode test must name a mode declared here. Both failures are
/// silent otherwise, and they are different failures — an unnamed mode is one
/// nobody is testing, a named mode with no test is one that reads as
/// delivered.
const faultModes = <String>[
  'flap',
  'latency',
  'throttle',
  'blackhole',
  'cutMidFrame',
  'killOnce',
  'reject',
  'bufferServerToClient',
];

/// Two modes that cannot be set at the same time, and the reason.
///
/// [why] is printed by the exception, so it is a sentence a caller reads at
/// the moment they are surprised, not a note to whoever maintains this file.
typedef ModeConflict = ({String a, String b, String why});

/// The pairs of modes that contradict each other, as data.
///
/// Declared here rather than left implicit in the setters, for the reason the
/// mode registry itself exists: a rule that lives in eight `if` statements is
/// a rule nobody can enumerate, and `composition_test.dart` iterates this list
/// in both orders and asserts its own case count against the length — so a
/// pair added below without a test is a failing suite rather than a silent
/// gap.
///
/// **Where the line is.** Modes compose wherever the combination describes a
/// link that could physically exist: latency, throttle and flap together are
/// an ordinary bad radio link, and Finding 7's single flush-gated delay line
/// per direction is what lets all three apply as gates on one queue. A pair is
/// listed here only when the combination has no behaviour anybody could have
/// intended — one mode discarding what the other withholds, or a mode shaping
/// traffic on a connection another mode guarantees does not exist. In those
/// cases a proxy that accepted both and behaved as one of them would produce a
/// test that passes for a reason its author did not choose, which costs more
/// than the refusal does.
///
/// The refusal is thrown **at set time**, by the lever being pulled. Deferring
/// it to forward time would report the contradiction from inside a socket
/// callback, with a stack that names neither of the two calls that caused it.
const exclusiveModePairs = <ModeConflict>[
  (
    a: 'blackhole',
    b: 'bufferServerToClient',
    why: 'blackhole discards the server→client bytes and '
        'bufferServerToClient holds the same bytes to release later, so the '
        'pair asks for a release of what was thrown away'
  ),
  (
    a: 'cutMidFrame',
    b: 'killOnce',
    why: 'both end the same connection by different means — cutMidFrame with '
        'a FIN so the delivered bytes survive at the peer, killOnce with an '
        'RST so they do not — and whichever fired first would decide what the '
        'other one meant'
  ),
  (a: 'reject', b: 'latency', why: _nothingToShape),
  (a: 'reject', b: 'throttle', why: _nothingToShape),
  (a: 'reject', b: 'flap', why: _nothingToShape),
  (a: 'reject', b: 'blackhole', why: _nothingToShape),
  (a: 'reject', b: 'cutMidFrame', why: _nothingToShape),
  (a: 'reject', b: 'killOnce', why: _nothingToShape),
  (a: 'reject', b: 'bufferServerToClient', why: _nothingToShape),
];

/// Why `reject` excludes every other mode.
///
/// One sentence shared by seven rows rather than seven near-identical ones:
/// they are the same contradiction, and writing it once is what makes it
/// obvious that the rule is "reject excludes the rest" and not a list somebody
/// assembled by hand and may have left a hole in.
const _nothingToShape =
    'reject refuses connections and destroys the ones that exist, so there is '
    'no traffic left for another mode to delay, meter, withhold, discard or '
    'cut — a scenario that wants a fault applied to a live connection wants '
    'reject off';

/// How long the proxy waits for the upstream server before giving up.
const _upstreamConnectTimeout = Duration(seconds: 5);

/// A loopback TCP proxy in front of an upstream server.
final class FaultProxy {
  FaultProxy({
    required this.targetPort,
    this.listenPort = 0,
  });

  /// The port of the upstream server this proxy forwards to, on loopback.
  final int targetPort;

  /// The port to bind. 0 — the default — lets the OS assign one.
  ///
  /// Tests should leave it at 0 and read [port]: a fixed port collides with
  /// the other tests in the suite and with whatever else is running on a CI
  /// box, and the collision surfaces as a fault-mode failure.
  final int listenPort;

  ServerSocket? _server;
  StreamSubscription<Socket>? _accepts;
  final Set<_ProxiedPair> _pairs = <_ProxiedPair>{};
  bool _shutDown = false;
  int? _lastUpstreamConnectErrno;

  /// Where jitter is drawn from.
  ///
  /// Not seeded: the property under test is that successive round trips
  /// *differ* and all land inside the band, which a fixed seed would turn into
  /// a check that one particular sequence of draws still lands there.
  final Random _jitterSource = Random();

  Duration? _latency;
  Duration? _jitter;
  int? _throttleBytesPerSec;
  int? _cutAfterBytes;

  /// Whether both directions are currently swallowing traffic.
  bool _blackholed = false;

  /// Whether the server→client direction is currently being withheld.
  bool _bufferServerToClient = false;

  /// Whether accepted connections are cut instead of being served.
  bool _rejecting = false;

  /// Whether the next connection accepted is to be reset on sight.
  ///
  /// Set only when [killOnce] found nothing open, and cleared the moment it
  /// fires. One flag rather than a counter: the mode is "once".
  bool _killOnceArmed = false;

  /// Whether a flap cycle is running.
  bool _flapping = false;

  /// Whether the flap cycle is currently in its down half.
  ///
  /// Separate from [_blackholed] on purpose: a blackhole keeps the sockets up
  /// and swallows, and a dropout takes the sockets away. They are different
  /// faults with different client code paths, and sharing one flag would make
  /// `flap` silently mean "blackhole, periodically".
  bool _flapDown = false;

  /// The timer carrying the cycle to its next transition.
  ///
  /// One chained [Timer] rather than a `Timer.periodic`, because up and down
  /// have different lengths and a periodic timer can only carry one interval.
  Timer? _flapTimer;

  /// How many times the flap cycle has changed half.
  int _flapTransitions = 0;

  /// The high-water reading of every pair that has already closed.
  int _retiredPeakPendingBytes = 0;
  int _retiredLargestChunkBytes = 0;

  /// The per-chunk delay every line gets, rebuilt when [latency] or [jitter]
  /// changes and handed to pairs accepted afterwards.
  ///
  /// Null when neither lever is set, which is how a line goes back to the
  /// undelayed write path rather than to a closure returning zero.
  Duration Function()? _perChunkDelay;

  /// The port this proxy is listening on.
  ///
  /// Throws [StateError] before [start] has completed, rather than the
  /// null-check failure the original proxy's `_server!.port` produced — a test
  /// that forgot to await `start()` should be told that, not shown a line
  /// number in this file.
  int get port {
    final server = _server;
    if (server == null) {
      throw StateError('the proxy has no port until start() has completed; '
          'bind first, then read port — the OS assigns it during the bind');
    }
    return server.port;
  }

  /// Whether the listener is up.
  bool get isRunning => _server != null;

  /// How many client↔upstream pairs are alive right now.
  ///
  /// The observable behind the socket-leak criterion's per-cycle half: a cycle
  /// that ends with a live pair has leaked two descriptors, and this says so
  /// before the fd count does.
  int get livePairs => _pairs.length;

  /// Pairs retired while their client socket had never been destroyed.
  ///
  /// **Always zero, and the one number that says why when it is not.** Every
  /// path to [_retire] is supposed to have destroyed the client first — by
  /// reset (`killWithReset`, `forceReset` in the accept path) or by
  /// [_ProxiedPair.close]. A pair that leaves `_pairs` without that having
  /// happened is a client still sitting on a socket nobody will ever end,
  /// while `livePairs` reports 0 — the exact triple the macOS fault lane
  /// fails on: *flap fired, no pairs held, client still connected*.
  ///
  /// This exists because `livePairs` alone cannot answer the question. It is
  /// read long after the event and cannot distinguish "the pair was dropped
  /// and the reset was lost on the way" from "the pair left without a reset
  /// being sent at all" — and those two have opposite fixes. This counter is
  /// only the second one. It costs a bool test per retire and changes no
  /// behaviour, so it can stand in the shipping proxy rather than in a
  /// debugging fork that is not there on the run that matters.
  int get pairsRetiredWithLiveClient => _pairsRetiredWithLiveClient;
  int _pairsRetiredWithLiveClient = 0;

  /// The most any one direction of any one pair has ever held.
  ///
  /// The bounded-memory criterion restated at the proxy, where a test can
  /// reach it: `DelayLine.peakPendingBytes` is the real observable, but the
  /// lines belong to pairs this class owns and a test has no other handle on
  /// them. Sampling RSS instead would measure the whole test host, including
  /// the payload the firehose is generating, and could not tell a bounded
  /// queue from a lucky garbage collection.
  ///
  /// Retired pairs are remembered. A pair whose peak vanished when its
  /// connection closed would let a test that tore its client down first read
  /// zero and pass, which is the worst kind of green: the run that actually
  /// grew is the one that ends with a closed connection.
  int get peakPendingBytes {
    var peak = _retiredPeakPendingBytes;
    for (final pair in _pairs) {
      final pairPeak = pair.peakPendingBytes;
      if (pairPeak > peak) peak = pairPeak;
    }
    return peak;
  }

  /// The largest single chunk any direction of any pair has ever been handed.
  ///
  /// The companion of [peakPendingBytes], and the reason the memory bound can
  /// be asserted exactly rather than approximated: the queue's peak is strictly
  /// below the high-water mark plus this. See `DelayLine.largestChunkBytes` —
  /// the number belongs to the runner's kernel, not to the proxy, so a test
  /// that hard-codes it is asserting which machine it is on.
  ///
  /// Retired pairs are remembered, for the same reason their peaks are.
  int get largestChunkBytes {
    var largest = _retiredLargestChunkBytes;
    for (final pair in _pairs) {
      final pairLargest = pair.largestChunkBytes;
      if (pairLargest > largest) largest = pairLargest;
    }
    return largest;
  }

  /// How many times [flap] has changed half since this proxy was created.
  ///
  /// Since the proxy, not since the cycle: [flap] cancels the old timer
  /// without zeroing the counter, so a proxy driven through two cycles reports
  /// the sum. That is deliberate now it is written down — the counter's job is
  /// the timer-hygiene assertion below, which compares it across a shutdown
  /// and would be weakened by anything that resets it — but a soak reading it
  /// as a per-cycle rate has to divide by the cycles it armed, and a generated
  /// storm that draws `flap` twice is two of them.
  ///
  /// The observable behind the timer-hygiene criterion. A cancelled timer is
  /// not otherwise visible from a test — `Timer` exposes nothing and package:
  /// test does not fail a case for leaving one behind; it simply keeps the
  /// isolate alive until the runner gives up, with no failure to attribute. So
  /// the counter is incremented at the *top* of the timer callback, ahead of
  /// the shutdown guard, and a test compares it across a shutdown: a timer
  /// that survived moves this number even though the transition it would have
  /// made is refused (T-02-31).
  ///
  /// Also worth printing in a soak: a minute of `flap(1s, 1s)` on a proxy that
  /// has been armed once should be around 59 transitions, and a number far off
  /// that — allowing for the earlier cycles it also counts — says it drifted
  /// before any client-side aggregate does.
  int get flapTransitions => _flapTransitions;

  /// The errno of the last failed upstream connection, or null if none failed.
  ///
  /// Read through `errnoOf` because `Socket.connect` throws a bare [OSError]
  /// against a resetting listener (RESEARCH Finding 9), which is not a
  /// [SocketException] and so escapes the natural catch clause entirely.
  int? get lastUpstreamConnectErrno => _lastUpstreamConnectErrno;

  /// Binds the listener. A second call while running is a no-op.
  Future<void> start() async {
    if (_server != null) return;
    if (_shutDown) {
      throw StateError('this proxy has been shut down; build a new one rather '
          'than restarting it, so a test cannot silently reuse a listener '
          'another test tore down');
    }
    final server =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, listenPort);
    _server = server;
    _accepts = server.listen(_accept);
  }

  /// Closes the listener and every live pair. Terminal, and idempotent.
  ///
  /// Registered with `addTearDown` immediately after [start] by every test in
  /// this phase, and called in the body by some of them, so a second call has
  /// to be a no-op rather than a throw — otherwise an ordinary teardown fails
  /// and the failure is attributed to whichever mode the test was about.
  Future<void> shutdown() async {
    if (_shutDown) return;
    _shutDown = true;
    // The mode primitives go first, before anything starts closing lines. A
    // timer left running past this point fires against a half-torn-down proxy
    // — and, worse, keeps the isolate alive after the test that owned it has
    // passed, so the runner hangs at the end of the suite with no failure to
    // point at (T-02-31).
    _flapTimer?.cancel();
    _flapTimer = null;
    _flapping = false;
    _flapDown = false;
    final accepts = _accepts;
    _accepts = null;
    final server = _server;
    _server = null;
    await accepts?.cancel();
    try {
      await server?.close();
    } catch (_) {
      // Cancelling the accept subscription already closed it on some
      // platforms. The listener is down either way, which is what was asked.
    }
    for (final pair in List.of(_pairs)) {
      await pair.close();
    }
    _pairs.clear();
  }

  // ---------------------------------------------------------------------
  // The eight levers. Declared now, implemented one plan at a time.
  // ---------------------------------------------------------------------

  /// The link goes down for [down], comes back for [up], and repeats.
  ///
  /// The proxy counterpart of `StateManHarness.disconnectUpstream` (the down
  /// half) and `reconnectUpstream` (the up half), which name it from the other
  /// side. A case written against either transfers unchanged.
  ///
  /// Assertions about a flapping proxy must be about windows, not instants:
  /// RESEARCH Finding 10 measured a connect attempt completing on the far side
  /// of a state transition — `t=1204ms forwarding=false connect OK in 189ms`
  /// — so the flag read at assertion time did not describe what the
  /// connection experienced. `test/faults/flap_test.dart` therefore counts
  /// dropouts, retries and escaped errors over a window and never reads a
  /// state at an instant, and a test "improved" into an instantaneous check
  /// here is measuring something other than what it names.
  ///
  /// **The down half is a dropout, not a blackhole.** Live pairs are reset and
  /// retired, and connections arriving during the down half are cut on sight,
  /// so a client experiences the link going away and has to reconnect —
  /// [blackhole] is the other fault, where the sockets stay up and the traffic
  /// vanishes. A flap built on blackholing would never exercise a reconnect
  /// path, which is the entire content of F2.
  ///
  /// **Real timers.** CONTEXT restricts injected clocks to pure state
  /// machines, and a cycle whose whole subject is wall-clock behaviour against
  /// live sockets is not one. The cycle starts in the up half, so a client
  /// that connects immediately gets a connection.
  ///
  /// Off is `flap(up, down, enabled: false)` — the same one-lever shape as
  /// [blackhole] and [reject], for the same reason: an off switch with its own
  /// name would be reachable without any entry in [faultModes] naming it. Off
  /// leaves the proxy **forwarding**, not in whichever half the cycle had
  /// reached, because every scenario that follows a flap needs a working link
  /// and none of them should have to ask which half it stopped in.
  void flap(Duration up, Duration down, {bool enabled = true}) {
    // Every refusal happens before anything is touched. A validation that ran
    // after the timer was cancelled would leave a rejected call having stopped
    // the cycle it refused to change — the caller handles an exception and the
    // proxy is in a third state neither of them asked for.
    if (enabled) {
      if (up <= Duration.zero || down <= Duration.zero) {
        throw ArgumentError('flap needs a positive duration for each half; '
            'got up=$up down=$down. A zero half is not a fast flap — it is a '
            'timer that fires in a loop for ever and starves the event loop '
            'the sockets run on');
      }
      _refuseConflict('flap');
    }
    _flapTimer?.cancel();
    _flapTimer = null;
    if (!enabled) {
      _flapping = false;
      _flapDown = false;
      return;
    }
    _flapping = true;
    _flapDown = false;
    _flapTimer = Timer(up, () => _onFlapTimer(up, down));
  }

  /// One transition of the cycle, and the scheduling of the next.
  void _onFlapTimer(Duration up, Duration down) {
    // Ahead of every guard, deliberately: this counter is how a test sees a
    // timer that outlived `shutdown()`. Counting after the guard would make a
    // leaked timer invisible to precisely the assertion written to catch it.
    _flapTransitions++;
    if (_shutDown || !_flapping) return;
    _flapDown = !_flapDown;
    if (_flapDown) {
      // Unawaited because a timer callback cannot await, and guarded because
      // an error on a future nobody holds is reported against whichever test
      // is running when it lands (T-02-33) — during a soak, that is never
      // this one.
      unawaited(_dropForFlap().catchError((Object _) {}));
    }
    _flapTimer = Timer(_flapDown ? down : up, () => _onFlapTimer(up, down));
  }

  /// Takes the link down: every live pair reset, then retired.
  ///
  /// Reset rather than closed, and in the order [reject] documents — the RST
  /// goes out before the lines are closed, because closing first wakes the
  /// teardown and destroys the socket out from under the linger option, which
  /// degrades the reset to a FIN intermittently. A dropout that arrived as a
  /// clean FIN would be an orderly shutdown, which is a different event on the
  /// client's side and the one thing this mode must not look like.
  Future<void> _dropForFlap() async {
    for (final pair in List.of(_pairs)) {
      pair.killWithReset();
      await pair.close();
      // Retired here rather than left to `_closeWhenEitherEnds`, for the same
      // reason `reject` does it: thirty cycles a minute means thirty chances
      // for a pair to be counted alive after it is gone.
      _retire(pair);
    }
  }

  /// One-way delay applied to every chunk in both directions.
  ///
  /// Applied per direction, so an application round trip through the proxy
  /// costs `2 * value`. Overhead is a small constant, 1–2.5 ms per direction
  /// (Finding 6), so tests assert `inInclusiveRange(2 * d, 2 * d + slack)`
  /// rather than a percentage band — the constant is bigger than a percentage
  /// allows at 50 ms and smaller than one allows at 500 ms. The slack itself
  /// belongs to the test, which sizes it for the runner it is on.
  ///
  /// Live: setting it reaches the pairs that are already open as well as the
  /// ones accepted later. A lever that only worked before connect could not
  /// express "the link degrades while the client is connected", which is the
  /// only shape the slow-link scenarios come in. Null turns it off.
  ///
  /// Setter-only. A getter would answer with the configured number, and the
  /// question worth asking — what did the connection actually experience — is
  /// answered by measuring a round trip, which is what `latency_test.dart`
  /// does.
  set latency(Duration? value) {
    if (value != null) _refuseConflict('latency');
    _latency = value;
    _applyDelay();
  }

  /// Random extra delay added on top of [latency], redrawn per chunk.
  ///
  /// Part of the `latency` mode rather than a ninth one — hence no separate
  /// entry in [faultModes] and no separate test file. Drawn uniformly from
  /// zero to this value, independently per chunk and per direction, so a round
  /// trip lands in `[2d, 2d + 2 * jitter + overhead]`.
  set jitter(Duration? value) {
    // Checked as `latency`, because it is that mode's second dial rather than
    // a mode of its own — a rule that excluded latency but let jitter through
    // would be a hole in the table with no row to fix.
    if (value != null) _refuseConflict('latency');
    _jitter = value;
    _applyDelay();
  }

  /// Bytes per second the proxy will forward, **per direction**.
  ///
  /// Per direction and not shared, because that is how a link is specified: a
  /// 1 Mbit/s line carries a megabit each way, and a shared budget would make
  /// a chatty client slow its own downloads for a reason no scenario asked
  /// for.
  ///
  /// Measured over a window of at least 3 s with a band of one twentieth
  /// (Assumption A5), because the interesting failure is a sustained rate and
  /// not an instant one — and because the bucket may bank up to a second of
  /// burst, which dominates anything shorter than about two.
  ///
  /// Live, like [latency]: it reaches the pairs that are already open. Null
  /// means unmetered, and a non-positive rate is refused — see below.
  set throttleBytesPerSec(int? value) {
    if (value != null && value <= 0) {
      throw ArgumentError.value(
          value,
          'throttleBytesPerSec',
          'a rate of zero is not a very slow link, it is an unmetered one: '
              'the token bucket is only consulted for a positive rate, so the '
              'lever would read as armed in the composition table and forward '
              'at full speed. Use blackhole for "no bytes get through", and '
              'null for unmetered');
    }
    if (value != null) _refuseConflict('throttle');
    _throttleBytesPerSec = value;
    for (final pair in _pairs) {
      pair.applyThrottle(value);
    }
  }

  /// The link goes silent while the sockets stay up — a true half-open.
  ///
  /// The proxy counterpart of `StateManHarness.disconnectUpstream`, which
  /// names this mode from the other side (`harness.dart:96-110`), and the
  /// counterpart of `reconnectUpstream` when called with [enabled] false. This
  /// is the fault the whole project is built against: a peer that has not
  /// closed anything and has simply stopped answering, which no `onDone` will
  /// ever report.
  ///
  /// **Read-the-bytes-and-drop-them, in both directions.** Not a paused read
  /// subscription: that would stall the sender's `flush()` within one socket
  /// buffer, which is *backpressure*, a different fault with different
  /// client-side code paths. RESEARCH Finding 4 measured this implementation
  /// producing `echoed=0 event=none write completed`, which is the shape
  /// F5/F7/F17 need — the sender keeps writing happily into nothing. A "the
  /// sender stalls too" variant is a separate lever with its own name and its
  /// own entry in [faultModes]; it is not a setting on this one.
  ///
  /// **Blackholed bytes are lost, not replayed.** Finding 4's third line —
  /// `recovered: echoed=100`, not 200. Recovery that flushed what had been
  /// swallowed would deliver a value from before the outage to a client that
  /// has just recovered, with nothing marking its age, which is the one
  /// outcome this project's core value forbids: never a stale reading
  /// rendered as current.
  ///
  /// Recovery is `blackhole(enabled: false)` rather than a lever of its own,
  /// so that the mode's on and off states cannot drift apart in [faultModes]
  /// — a `recover()` naming no mode would be reachable without any mode being
  /// named, which is exactly what the registry exists to prevent. Live in both
  /// directions: it reaches open pairs and the ones accepted afterwards, and
  /// the connection survives, because a half-open that required a reconnect
  /// to end would not be one.
  void blackhole({bool enabled = true}) {
    if (enabled) _refuseConflict('blackhole');
    _blackholed = enabled;
    for (final pair in _pairs) {
      pair.applyBlackhole(enabled);
    }
  }

  /// Deliver exactly [n] bytes of the next response, then end the connection.
  ///
  /// Cuts with FIN, never with a reset: Finding 3 measured an RST discarding
  /// the peer's unread data, so `cutMidFrame(137)` delivered 0 of 137 bytes in
  /// 50 of 50 runs against a peer that was not actively reading. A mode built
  /// on a reset passes a naive test and silently does nothing in production.
  ///
  /// The same mode cut with a FIN delivered 137 of 137 in 50 of 50 runs in
  /// *both* peer states, and held across n ∈ {1, 64, 4096, 200000}. So the
  /// implementation below reaches for `Socket.close()` and the pair keeps the
  /// client descriptor open until the peer has gone; nothing on this path may
  /// call `forceReset`, and `test/faults/cut_mid_frame_test.dart`'s paused arm
  /// is what says so out loud.
  ///
  /// Counts bytes on the **server → client** direction only, and splits a
  /// chunk that straddles the boundary — n is a byte count, not a chunk count.
  ///
  /// Live and sticky, like [latency]: it reaches connections that are already
  /// open, and it stays armed, so each connection accepted afterwards is cut
  /// after its own n bytes. A one-shot would need a way to say "the next one",
  /// and every scenario that wants a partial frame wants it on the connection
  /// it is holding.
  ///
  /// Null disarms it. The mode is sticky, and the composition rules are state
  /// checks rather than latches, so there has to be a way back — without one,
  /// a proxy that had ever been told to cut could never be told to reset, and
  /// the pair with [killOnce] would be a latch wearing a state check's name.
  void cutMidFrame(int? n) {
    if (n != null && n < 0) {
      throw ArgumentError.value(n, 'n',
          'a cut delivers a byte count, so it cannot be negative; 0 cuts '
              'before the first byte of the response, and null disarms');
    }
    if (n != null) _refuseConflict('cutMidFrame');
    _cutAfterBytes = n;
    for (final pair in _pairs) {
      pair.armCutMidFrame(n);
    }
  }

  /// Reset the current connection once, then serve normally again.
  ///
  /// The reset half of the pair [cutMidFrame] is the FIN half of:
  /// `SO_LINGER{1,0}` then `destroy()`, via `forceReset` in `socket_ops.dart`,
  /// which measured a genuine RST in 50 of 50 runs.
  ///
  /// **The one-sentence contrast:** [cutMidFrame] ends a connection so the
  /// bytes already delivered survive at the peer, and this ends one so they do
  /// not — a reset makes the kernel discard the peer's unread receive queue,
  /// which is what a crashed process or a yanked cable looks like and what
  /// `StateManHarness.disconnectUpstream` names from the other side.
  ///
  /// Fires once and disarms. If a connection is open it is reset now; if none
  /// is, the next one is reset as it is accepted, because a lever pulled a
  /// moment before the client connects must not evaporate. Either way the
  /// connection after it is forwarded normally, which is the half
  /// `test/faults/kill_once_test.dart` calls "and then normal service" — a
  /// mode that stayed armed would fail every scenario that follows the fault.
  void killOnce() {
    _refuseConflict('killOnce');
    final live = List.of(_pairs);
    if (live.isEmpty) {
      _killOnceArmed = true;
      return;
    }
    for (final pair in live) {
      pair.killWithReset();
    }
  }

  /// Destroy live connections and refuse new ones, keeping the listener open.
  ///
  /// The listener stays bound on purpose: on Windows a closed listener turns a
  /// connect attempt into a slow timeout instead of a fast refusal. The price
  /// is POSIX determinism — Finding 8 measured the handshake racing the reset,
  /// so a client sees either a failed connect or a connect that is immediately
  /// reset. Tests assert a terminal failure within a budget, never an errno.
  ///
  /// **Correcting the original's doc.** `tfc_dart/test/proxy.dart:11-14`
  /// describes this as sending a refusal the client will see as one. It does
  /// not: on POSIX `destroy()` is a clean FIN except by coincidence (Finding
  /// 1), and because the listener is still bound the kernel can complete the
  /// handshake out of the accept queue before this method's teardown reaches
  /// the new socket. Finding 8 measured both outcomes from consecutive
  /// attempts against one proxy — connect failing in 7 ms, and connect
  /// succeeding in 2 ms and then being reset. Both are the mode working. A
  /// caller that needs one specific outcome wants a closed listener, which is
  /// a different mode and is slow on the platform this one is for.
  ///
  /// **No sleep.** The original waited 100 ms here before returning, a guess
  /// about someone else's scheduler: too slow for every ordinary run and too
  /// short for a loaded CI box. This awaits the teardown of the pairs it is
  /// actually tearing down, so when it returns there are none — which is the
  /// property the sleep was approximating, stated exactly.
  ///
  /// Rejection is a state, not an event: `reject(enabled: false)` leaves it,
  /// and the connection after it is forwarded normally on the same port.
  ///
  /// **Not an `async` function, on purpose.** The composition check has to
  /// reach the caller as a synchronous throw at the moment the lever is
  /// pulled. Inside an `async` body every throw becomes an error on the
  /// returned future, so a caller who wrote `proxy.reject()` without awaiting
  /// it — which every other lever here allows — would get the refusal as an
  /// unhandled async error, attributed to whichever test was running when it
  /// landed rather than to the line that caused it.
  Future<void> reject({bool enabled = true}) {
    if (enabled) _refuseConflict('reject');
    _rejecting = enabled;
    if (!enabled) return Future<void>.value();
    return _tearDownForReject();
  }

  /// The awaited half of [reject]: every live pair reset, then retired.
  Future<void> _tearDownForReject() async {
    // The reset goes to the client before the pair's lines are closed, for the
    // reason `_ProxiedPair.killWithReset` documents: closing first wakes the
    // teardown, which destroys the socket out from under the linger option and
    // degrades this mode's reset to a FIN, intermittently.
    for (final pair in List.of(_pairs)) {
      pair.killWithReset();
      await pair.close();
      // Retired here rather than left to `_closeWhenEitherEnds`, which runs a
      // microtask or two later: a caller that awaits this method and then asks
      // `livePairs` is asking whether the teardown finished, and an answer
      // that is briefly wrong is worse than a slow one.
      _retire(pair);
    }
  }

  /// Withhold server→client traffic while still forwarding client→server.
  ///
  /// The asymmetry is the point, and it is why this is one mode rather than
  /// half of [blackhole]: forwarding client→server keeps the server side alive
  /// and answering, so the peer does not time out while its replies are held.
  /// Carried over from `tfc_dart/test/proxy.dart:118-154`, whose comment is
  /// the source of that reason — hold both directions and the upstream falls
  /// idle, times out, and the scenario becomes an ordinary disconnect instead
  /// of a client hearing nothing from a server that is demonstrably fine.
  ///
  /// **Withheld, not discarded, and not off to the side.** The bytes wait in
  /// the server→client [DelayLine]'s own queue and go on counting toward its
  /// `pendingBytes`, so a firehose into a withheld direction pauses its source
  /// at the high-water mark like any other traffic (T-02-24). Clearing this
  /// flag releases everything held; so does [flush], which releases and leaves
  /// the lever armed.
  ///
  /// Live, like the other levers: it reaches the pairs that are already open
  /// and the ones accepted afterwards.
  set bufferServerToClient(bool value) {
    if (value) _refuseConflict('bufferServerToClient');
    _bufferServerToClient = value;
    for (final pair in _pairs) {
      pair.applyWithhold(value);
    }
  }

  /// Releases what [bufferServerToClient] is holding, keeping it armed.
  ///
  /// The original proxy's `flushBuffer()`. Deliberately not a disarm: a
  /// release that also turned the mode off could only ever say "the fault is
  /// over", where this can say "a batch got through and the stall continues",
  /// which is the shape of a store-and-forward peer and the reason the mode
  /// has a release at all.
  ///
  /// A no-op when nothing is withheld, including when the lever was never
  /// pulled — teardown paths and scenario scripts both call it unconditionally.
  void flush() {
    for (final pair in _pairs) {
      pair.releaseWithheld();
    }
  }

  /// Throws if switching [mode] on would contradict a mode already set.
  ///
  /// Called by every lever, and only on the way **on**: an off switch is never
  /// refused. A proxy that would not let a scenario clear a mode because of
  /// what else was set would be a proxy a scenario can drive into a corner,
  /// and the corner would be reported as whichever fault the scenario was
  /// about.
  void _refuseConflict(String mode) {
    for (final conflict in exclusiveModePairs) {
      final String other;
      if (conflict.a == mode) {
        other = conflict.b;
      } else if (conflict.b == mode) {
        other = conflict.a;
      } else {
        continue;
      }
      if (!_isActive(other)) continue;
      throw StateError('$mode cannot be set while $other is: ${conflict.why}. '
          'Clear $other first — the rule is a state check, not a latch, so '
          'this proxy is usable for $mode the moment $other is off');
    }
  }

  /// Whether [mode] is switched on right now.
  ///
  /// The one place the eight modes' state is named uniformly. It throws on an
  /// unknown name rather than answering false: a ninth mode added to
  /// [exclusiveModePairs] without a line here would otherwise read as
  /// permanently off, and every exclusion naming it would quietly never fire —
  /// a rule that exists in the table, has a passing test generated from the
  /// table, and does nothing.
  bool _isActive(String mode) => switch (mode) {
        'flap' => _flapping,
        // Jitter is part of the latency mode rather than a ninth one, so it
        // makes the same mode active.
        'latency' => _latency != null || _jitter != null,
        'throttle' => _throttleBytesPerSec != null,
        'blackhole' => _blackholed,
        'cutMidFrame' => _cutAfterBytes != null,
        // Armed only while it is waiting for a connection to fire at; once it
        // has fired the mode is over, which is what "once" means.
        'killOnce' => _killOnceArmed,
        'reject' => _rejecting,
        'bufferServerToClient' => _bufferServerToClient,
        _ => throw StateError('no state predicate for mode "$mode"; it is '
            'named in exclusiveModePairs, so every rule mentioning it is '
            'inert until one is added here'),
      };

  /// Rebuilds the per-chunk delay and pushes it to every live pair.
  ///
  /// Both directions of every pair get the *same* closure, and it redraws its
  /// jitter on each call, so the two directions of one round trip draw
  /// independently rather than sharing one number.
  void _applyDelay() {
    _perChunkDelay = _buildDelay();
    for (final pair in _pairs) {
      pair.applyChunkDelay(_perChunkDelay);
    }
  }

  /// The delay function the current [latency] and [jitter] describe.
  Duration Function()? _buildDelay() {
    final base = _latency ?? Duration.zero;
    final spread = _jitter ?? Duration.zero;
    if (base <= Duration.zero && spread <= Duration.zero) return null;
    if (spread <= Duration.zero) return () => base;
    // `+ 1` because `nextInt` is exclusive at the top and the spread reads as
    // an inclusive maximum everywhere it is written down.
    final spreadMicros = spread.inMicroseconds;
    return () =>
        base + Duration(microseconds: _jitterSource.nextInt(spreadMicros + 1));
  }

  Future<void> _accept(Socket client) async {
    if (_shutDown) {
      client.destroy();
      return;
    }
    if (_rejecting) {
      // Answered here and not by closing the listener, which is the whole
      // mode: the SYN is accepted, so Windows gets an immediate answer instead
      // of a connect timeout, and the socket is cut before anything upstream
      // is touched — a rejecting proxy must not open a connection to the
      // server for a client it is about to refuse.
      forceReset(client);
      return;
    }
    if (_flapDown) {
      // The link is away for this half of the cycle. Cut on sight and never
      // touch the upstream: a proxy that opened a server connection for a
      // client it is about to drop would make the *server* see a connection
      // storm during an outage, which is the opposite of what a dropout does.
      forceReset(client);
      return;
    }
    final Socket upstream;
    try {
      upstream = await Socket.connect(
        InternetAddress.loopbackIPv4,
        targetPort,
        timeout: _upstreamConnectTimeout,
      );
    } catch (error) {
      // Object, not SocketException: Finding 9 measured a bare OSError here,
      // which a narrowed clause would let escape into an unhandled async error
      // attributed to whichever test was running.
      _lastUpstreamConnectErrno = errnoOf(error);
      client.destroy();
      return;
    }
    if (_shutDown) {
      client.destroy();
      upstream.destroy();
      return;
    }
    if (_rejecting || _flapDown) {
      // The lever moved while this connect was in flight. Nothing below this
      // line awaits before the pair joins `_pairs`, so a pair that gets past
      // here is one the next sweep can see — but a pair created *now* would
      // be a live, fully forwarding connection in the middle of a dropout,
      // and it would escape the sweep that has already run: `_dropForFlap`
      // and `_tearDownForReject` iterate the set as they find it, which is
      // why `reject`'s doc can promise "when it returns there are none" only
      // if the accept path stops adding them afterwards. In a soak this is
      // the shape "the client stayed connected through the outage" takes when
      // it is a false negative.
      //
      // forceReset rather than destroy, matching what the pre-connect checks
      // send: the client asked for a connection during a refusal and gets the
      // same answer whichever side of the await it was on.
      forceReset(client);
      upstream.destroy();
      return;
    }
    final pair = _ProxiedPair(client, upstream);
    // Before `start`, so the first chunk of a connection accepted while a
    // lever is set is already subject to it. A pair that picked its settings
    // up one event loop later would deliver the opening bytes of every
    // connection unmodified, which is exactly the traffic a handshake test
    // cares about.
    pair.applyChunkDelay(_perChunkDelay);
    pair.applyThrottle(_throttleBytesPerSec);
    pair.armCutMidFrame(_cutAfterBytes);
    pair.applyBlackhole(_blackholed);
    pair.applyWithhold(_bufferServerToClient);
    _pairs.add(pair);
    pair.start(_retire);
    if (_killOnceArmed) {
      // After `start`, so the pair owns its sockets before one of them is
      // destroyed: resetting a pair that had not begun would leave the
      // upstream socket with nothing watching it, which is the shape of the
      // descriptor leak Finding 11 measured.
      _killOnceArmed = false;
      pair.killWithReset();
    }
  }

  /// Drops a closed pair, keeping the one number that outlives it.
  void _retire(_ProxiedPair pair) {
    // Counted before anything else, for `_flapTransitions`' reason: a pair
    // that leaves the set without its client having been ended is invisible
    // afterwards — the set no longer holds it and the socket belongs to a
    // client this side cannot see.
    if (!pair.clientWasDestroyed) _pairsRetiredWithLiveClient++;
    final peak = pair.peakPendingBytes;
    if (peak > _retiredPeakPendingBytes) _retiredPeakPendingBytes = peak;
    final largest = pair.largestChunkBytes;
    if (largest > _retiredLargestChunkBytes) {
      _retiredLargestChunkBytes = largest;
    }
    _pairs.remove(pair);
  }
}

/// One client↔upstream conversation: two delay lines and two sockets.
final class _ProxiedPair {
  _ProxiedPair(this.client, this.upstream)
      : toUpstream = DelayLine(destination: upstream),
        toClient = DelayLine(destination: client);

  /// The socket this proxy's listener accepted from the client.
  final Socket client;

  /// The socket this proxy opened to the upstream server.
  ///
  /// The one RESEARCH Finding 11 measured leaking exactly one descriptor per
  /// cycle: when its peer went away the stream ended, and nothing destroyed
  /// the socket. [close] below is what stops that, and `test/faults/
  /// leak_test.dart` is what stops [close] from quietly losing the line again.
  final Socket upstream;

  final DelayLine toUpstream;
  final DelayLine toClient;
  bool _closed = false;
  bool _clientDestroyed = false;
  bool _cutFired = false;

  /// The most either direction of this pair has ever held.
  int get peakPendingBytes => toUpstream.peakPendingBytes > toClient.peakPendingBytes
      ? toUpstream.peakPendingBytes
      : toClient.peakPendingBytes;

  /// The largest single chunk either direction of this pair has been handed.
  int get largestChunkBytes =>
      toUpstream.largestChunkBytes > toClient.largestChunkBytes
          ? toUpstream.largestChunkBytes
          : toClient.largestChunkBytes;

  /// Applies a per-chunk delay to **both** directions.
  ///
  /// Both, because `latency` is documented as a one-way delay and a round trip
  /// crosses the proxy twice: setting it on one direction would halve the
  /// number every test measures, and the failure would read as a scheduler
  /// problem rather than as a missing line here.
  void applyChunkDelay(Duration Function()? delay) {
    toUpstream.chunkDelay = delay;
    toClient.chunkDelay = delay;
  }

  /// Applies a byte budget to **each** direction.
  ///
  /// Each direction gets its own bucket at the full rate, which is what "a
  /// 1 Mbit/s link" means. Sharing one bucket between them would make the two
  /// directions compete, so a test measuring a download would read a rate that
  /// depended on how talkative its own client was.
  void applyThrottle(int? bytesPerSecond) {
    toUpstream.bytesPerSecond = bytesPerSecond;
    toClient.bytesPerSecond = bytesPerSecond;
  }

  /// Swallows — or stops swallowing — traffic in **both** directions.
  ///
  /// Both, because a half-open in one direction only is a different fault: the
  /// scenarios this serves (F5, F7, F17) include the case where the client's
  /// requests vanish as well as the case where the answers do, and a mode that
  /// silently only did one of them would report the other as covered.
  void applyBlackhole(bool swallowing) {
    toUpstream.discardInsteadOfForward = swallowing;
    toClient.discardInsteadOfForward = swallowing;
  }

  /// Withholds the **server→client** direction only.
  ///
  /// Only that one. Withholding both would starve the upstream of the
  /// client's traffic, and an upstream that stops hearing from its peer stops
  /// answering — which turns "the server is fine and the client hears
  /// nothing" into a mutual silence indistinguishable from [applyBlackhole].
  void applyWithhold(bool withholding) {
    toClient.withholdUntilReleased = withholding;
  }

  /// Lets the withheld server→client bytes out, leaving the lever armed.
  void releaseWithheld() => toClient.releaseWithheld();

  /// Arms — or disarms, with null — the server→client byte cut.
  ///
  /// Only [toClient]. A cut counted across both directions would fire on the
  /// client's own request bytes, so `cutMidFrame(137)` would end the
  /// connection before the response existed.
  void armCutMidFrame(int? n) {
    toClient.cutAfterBytes = n;
    toClient.onCutReached = n == null ? null : _cutWithFin;
  }

  /// Ends the connection with a **FIN** once the cut's bytes have flushed.
  ///
  /// Two things here are load-bearing and both look removable.
  ///
  /// `client.close()` rather than `forceReset` or `destroy`: a reset makes the
  /// kernel discard the peer's unread receive queue, which is precisely the n
  /// bytes this mode just promised to deliver (Finding 3 — 0 of 137 delivered
  /// in 50 of 50 runs against a peer that was not reading).
  ///
  /// And the client descriptor is *left open*. `destroy()` is a clean FIN only
  /// while nothing sits unread in the socket's own receive queue (Finding 1);
  /// a client that is still writing its request when the cut fires leaves
  /// exactly that, and closing then would turn this mode's FIN into the very
  /// reset it must not send. So [toUpstream] keeps draining and the descriptor
  /// is closed later, in [_closeWhenEitherEnds], once the peer has gone.
  Future<void> _cutWithFin() async {
    if (_cutFired) return;
    _cutFired = true;
    unawaited(client.close().catchError((Object _) => client));
    await toClient.close();
  }

  /// Cuts the client with a genuine **RST**, then tears the pair down.
  ///
  /// `forceReset` — `SO_LINGER{1, 0}` then `destroy()` — and not `close()`,
  /// which ignores linger and sends a FIN (verified both ways in
  /// `socket_ops_test.dart`), and not a bare `destroy()`, which is a FIN in
  /// every state but a coincidental one (Finding 1).
  ///
  /// The reset goes out **before** the lines are closed, and synchronously.
  /// Closing them first completes `toClient.done`, which wakes
  /// [_closeWhenEitherEnds] and destroys this socket from under the linger
  /// option — the mode would then degrade to the FIN it exists not to send,
  /// intermittently, depending on which task ran first.
  void killWithReset() {
    if (_clientDestroyed) return;
    forceReset(client);
    _clientDestroyed = true;
    unawaited(close());
  }

  void start(void Function(_ProxiedPair pair) onClosed) {
    // A destroyed socket completes `done` with an error nobody is waiting for,
    // which package:test reports as an unhandled async error against whichever
    // test happens to be running when it lands.
    unawaited(client.done.catchError((Object _) => client));
    unawaited(upstream.done.catchError((Object _) => upstream));
    toUpstream.start(client);
    toClient.start(upstream);
    unawaited(_closeWhenEitherEnds(onClosed));
  }

  /// Tears the pair down as soon as either direction ends.
  ///
  /// This is the `onDone` / `onError` destroy Finding 11 called for, moved one
  /// level out: each [DelayLine] treats the end of its source — clean or
  /// errored — as the end of that direction, and the pair owns both sockets
  /// because both directions share them.
  /// After a FIN cut it waits for the *client* direction to end as well, so
  /// the descriptor is closed with nothing unread behind it — see [_cutWithFin]
  /// for why that is the difference between a FIN and a reset. `close()`
  /// completes `toUpstream.done` too, so a peer that never closes is still
  /// collected by `FaultProxy.shutdown` rather than held open for ever.
  Future<void> _closeWhenEitherEnds(
      void Function(_ProxiedPair pair) onClosed) async {
    await Future.any<void>([toUpstream.done, toClient.done]);
    if (_cutFired) await toUpstream.done;
    await close();
    onClosed(this);
  }

  /// Cancels both directions and destroys **both** sockets.
  ///
  /// Each destroy in its own try/catch: a first socket that throws must not
  /// leave the second one open, which is the shape the leak this file's tests
  /// exist to catch took in the first place.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await toUpstream.close();
    await toClient.close();
    _destroyClient();
    try {
      upstream.destroy();
    } catch (_) {
      // Same, and this is the one that leaked when it was missing: with this
      // block deleted, `test/faults/leak_test.dart` fails at the +10
      // checkpoint with a delta of 10 — one descriptor per cycle, the rate
      // RESEARCH Finding 11 measured before it was added.
    }
  }

  /// Closes the client descriptor, at most once.
  ///
  /// A flag rather than a bare `destroy()` because two paths reach it — an
  /// ordinary teardown and `killOnce`, which has already destroyed this socket
  /// through `forceReset`. Destroying twice is harmless; what is not harmless
  /// is the reverse, a reset socket being re-`close()`d, so the flag keeps the
  /// ownership statement in one place.
  /// Whether this pair's client socket has been ended by any route.
  ///
  /// Read by `FaultProxy._retire` to count the pairs that left without one.
  bool get clientWasDestroyed => _clientDestroyed;

  void _destroyClient() {
    if (_clientDestroyed) return;
    _clientDestroyed = true;
    try {
      client.destroy();
    } catch (_) {
      // Already gone. The descriptor is closed either way, which is the
      // question the leak criterion asks.
    }
  }
}

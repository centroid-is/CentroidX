/// The app heartbeat: the one periodic frame this client owes the gateway.
///
/// **Why it exists.** The gateway's reaper closes any session that has gone
/// longer than its `heartbeatDeadline` without an inbound *application* frame
/// (`relay_session.dart`'s `_lastSeen`, `tick_engine.dart`'s `reap`). A panel
/// that is only watching a page — which is what every panel in the plant does,
/// all shift — sends nothing after its handshake. Before this file existed the
/// consequence was measured on an idle single-panel fixture: **three reaps and
/// three redials in twenty-one seconds**, each one a full page resync, on every
/// panel in the factory, invisible from outside because the panel comes
/// straight back (07-08-SUMMARY deviation 3; `deferred-items.md` carries the
/// mechanism).
///
/// The design ruled on this at inception and CLAUDE.md still carries the
/// sentence: *"no browser ping frames — **server pings + app heartbeat**"*.
/// WebSocket ping/pong is not available to us as liveness — it is a
/// socket-level keepalive that `shelf` owns, a pong is not an application
/// frame, and Flutter web cannot send one at all. So the heartbeat is an
/// ordinary `ping` request, at the application layer, from here.
///
/// **Why a separate file, and the pin that goes with it.**
/// `no_retry_test.dart` pins `remote_state_man.dart` at zero `Timer(` — the
/// write path must schedule nothing of its own, because the only thing there
/// is to schedule about an unanswered write is sending it again. That pin is
/// not loosened. The heartbeat lives here instead, behind a **named carve-out**
/// in the same file: this file may hold exactly one `Timer.periodic(`, and its
/// send site may name `Methods.ping` and nothing else. A pump that could send
/// anything else would be a second, unbookkept way for a frame to reach the
/// plant, which is precisely what the write-path pins exist to forbid.
///
/// **Listener-gated, and that phrase is load-bearing here.** The timer exists
/// only while the link is `ready`: it is created on entry and cancelled on
/// exit, so an idle client, a disconnected client and a disposed client all
/// hold zero timers. A pump that ran unconditionally would keep a process alive
/// and would fail unrelated widget tests the moment this client reaches
/// Flutter — the discipline STATE.md records as "timers must be listener-gated".
///
/// **A gate, never a buffer, and never a `try`/`catch` for the gate.** This is
/// `HoldToRunController`'s discipline (05-07), restated because the failure it
/// prevents is the same one: `sendRequest` on a closed peer throws
/// `StateError` synchronously and `failure_taxonomy.dart` deliberately rethrows
/// unrecognised `StateError`s, so a `catch` around the send would swallow a
/// real defect in this process along with the condition it meant to ignore.
/// Every send is preceded by an explicit readiness check and an explicit
/// null-peer check. A beat that cannot go out is **dropped**, never stored: a
/// queued heartbeat is a lie about a moment that has passed, and `_WsSink.add`
/// buffers without bound and reports nothing (flutter#103306).
library;

import 'dart:async';

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'client_config.dart';
import 'deadline.dart';

/// Beats a `ping` at the gateway for as long as the link is ready.
final class HeartbeatPump {
  HeartbeatPump({
    required this.config,
    required bool Function() isReady,
    required CurrentPeer peer,
    int Function()? elapsed,
    Map<String, int> Function()? ackSource,
    void Function(String complaint)? onComplaint,
  })  : _isReady = isReady,
        _peer = peer,
        _ackSource = ackSource,
        _onComplaint = onComplaint,
        _now = elapsed ?? _elapsedClock() {
    _lastOutboundMs = _now();
  }

  /// A fresh monotonic clock. Only differences are ever read from it, so where
  /// it starts does not matter.
  static int Function() _elapsedClock() {
    final elapsed = Stopwatch()..start();
    return () => elapsed.elapsedMilliseconds;
  }

  /// The heartbeat floor and the deadline used on the ping itself.
  final ClientConfig config;

  /// Whether a frame issued right now would go straight out.
  ///
  /// Consulted at every beat rather than captured at [start], because the beat
  /// happens on a timer and the link may have gone in between. This is the
  /// gate, and it is the reason [start]/[stop] alone are not sufficient.
  final bool Function() _isReady;

  /// Where the current connection's peer lives, read at the moment of the
  /// call — `deadline.dart`'s seam, so a reconnect landing mid-beat cannot
  /// retarget the ping at the replacement socket.
  final CurrentPeer _peer;

  /// What this panel has actually **applied**, per subscription — the delivery
  /// ack every beat carries (`16-02-DECISION.md` §5.1).
  ///
  /// **Read, never counted.** The supplier is the supervisor's own
  /// `SubscriptionState.lastSeq`, which it already maintains for resync, so
  /// this pump learns nothing new and owns no state that could disagree with
  /// the rest of the client. A pump given no source says nothing, which is
  /// what a panel too old to send an ack says, and the gateway already knows
  /// how to answer it: a null `ackedSeq` is skipped by the delivery verdict.
  ///
  /// Null is "I have nothing to say", never "do not beat" — every existing
  /// case in `heartbeat_test.dart` builds a pump without one.
  final Map<String, int> Function()? _ackSource;

  /// Where a word about the gateway's configuration goes — the same list
  /// `RemoteStateMan.complaints` publishes. Null in a harness that wires none.
  final void Function(String complaint)? _onComplaint;

  /// Elapsed milliseconds from a clock that cannot be stepped.
  ///
  /// **A cadence is an elapsed-time question** (07-REVIEW WR-03), so it is
  /// asked of a `Stopwatch` and not of `DateTime.now()`. NTP correcting a fast
  /// RTC steps the wall clock backwards — the panel with a dead CMOS battery
  /// `clock_offset.dart:19-21` describes — and every difference measured
  /// across the step comes out negative, which the skip rule below reads as
  /// "the wire has carried something recently". The pump then sends nothing
  /// until real time catches up past the pre-step value, the gateway sees
  /// silence, and the panel is reaped for the difference. The same class of
  /// thing `FreshnessWatchdog.serverNowMs` is about, one file over.
  final int Function() _now;

  /// The one timer. Not `late`, not a list: the type is the design, and
  /// `FreshnessWatchdog._deadline` says the same thing for the same reason.
  Timer? _beat;

  bool _disposed = false;

  /// The gateway's advertised patience, or null until a `hello` has answered.
  int? _deadlineMs;

  /// When this client last put a frame on the wire, in [_now]'s clock.
  late int _lastOutboundMs;

  /// The ack as it stood at the previous tick of the beat timer.
  ///
  /// **Updated every tick the link is up, not only on the ticks that send** —
  /// otherwise the comparison is against the last ack *delivered*, a panel
  /// whose ack froze after its last beat compares against a different map for
  /// ever, and the stuck reader is skipped permanently: the exact failure this
  /// field exists to detect, reached through its own bookkeeping.
  ///
  /// Seeded at [_arm] rather than at construction, because "since the last
  /// beat" has no meaning before the timer exists, and a pump armed on a panel
  /// that is already holding pages would otherwise spend its first period
  /// deciding that every subscription had just moved.
  Map<String, int> _lastAckSent = const {};

  var _pings = 0;

  /// 0 while the link is anything but ready and after [dispose], 1 while it is
  /// ready — never more, whatever else the client is doing.
  ///
  /// The suite asserts this number because the count *is* the design: one
  /// periodic timer, owned here, gone the instant the link is.
  int get debugTimerCount => _beat == null ? 0 : 1;

  /// How many heartbeats reached the wire.
  ///
  /// Counted **after** the gate, so it measures beats the link actually
  /// carried rather than beats something asked for — `debugHoldTicksSent`'s
  /// rule, for the same reason.
  int get debugHeartbeatsSent => _pings;

  /// The deadline this pump learned from the gateway, or null if it has been
  /// told nothing usable.
  int? get debugLearnedDeadlineMs => _deadlineMs;

  /// Records the deadline the gateway advertised at `hello`.
  ///
  /// Takes the already-parsed value rather than the raw capabilities map:
  /// `HelloResult.heartbeatDeadlineMs` owns the tolerance rule (finite,
  /// positive, truncated), so a garbage advertisement arrives here as null and
  /// there is exactly one place that decides what garbage is.
  ///
  /// Applied to the running timer immediately. A gateway that came back from a
  /// restart with a different deadline would otherwise be beaten at the
  /// retired gateway's cadence until the next disconnect, which is the window
  /// in which the panel is reaped for the difference.
  void learnedDeadlineMs(int? advertised) {
    if (_deadlineMs == advertised) return;
    _deadlineMs = advertised;
    _complainIfUnbeatable(advertised);
    if (_beat != null) _arm();
  }

  /// Says so when the gateway's patience is shorter than this panel's floor
  /// can promise (07-REVIEW WR-01; the boundary is S13's).
  ///
  /// **The worst-case silence is two periods, not one.** [noteOutbound]'s skip
  /// rule means an outbound frame landing just after a beat suppresses the
  /// next one, so the gateway last sees a frame at `kp+e` and next sees one at
  /// `(k+2)p`. At the derived period that is two thirds of the deadline and
  /// safe by construction. At the floor it is a flat two floors against
  /// whatever the gateway chose.
  ///
  /// **So a full beat of margin needs three floors, and that is where this
  /// complains from.** The margin is `advertised - 2 x floor`; the panel can
  /// absorb one lost frame only when that is at least one whole period, which
  /// is `advertised >= floor * 3`. This gate used to be `floor * 2 <
  /// advertised` while the message below recommended raising the deadline
  /// above `floor * 3` — **the code disagreed with its own advice**, and the
  /// band in between was the quiet half: at 2500 ms against the default 1 s
  /// floor the period clamps to the floor, the gateway legitimately sees
  /// 2000 ms of silence, the margin is 500 ms, and one Wi-Fi retransmit reaps
  /// the session on every loss burst — the pump running, [debugHeartbeatsSent]
  /// climbing, and nothing said. That is the six-second-resync defect this
  /// class exists to fix wearing a green light. At `2f + 1` the margin is one
  /// millisecond.
  ///
  /// Three floors is not a round number picked here: it is exactly
  /// `ServerConfig.minHeartbeatDeadline`'s default of 3 s against this
  /// [ClientConfig.heartbeatFloor] default of 1 s. **The two ends' numbers
  /// meet at this boundary**, so a gateway that passes its own validation is a
  /// gateway this panel is silent about, and the only configurations that
  /// complain are the ones the server would have refused to hold itself to.
  ///
  /// Narrowing the skip rule (16-02 §6) does not move this: a narrower gate
  /// can only *un*-skip beats, so `2 x period` stays the bound and the
  /// boundary derived from it stays where it is.
  ///
  /// [period] does not bend for it: the floor is this panel's own limit on
  /// what it will do about somebody else's configuration, and a panel beating
  /// ten times a second because a gateway asked is a self-inflicted load
  /// multiplied by every screen in the factory. What changes is that the panel
  /// stops being silent about a configuration it cannot satisfy. `period`'s
  /// doc used to assert the floor "is faster than any deadline a sane gateway
  /// would set"; that was an unenforced assumption about someone else's
  /// config file, and `ServerConfig.minHeartbeatDeadline` is now the other
  /// half of it.
  void _complainIfUnbeatable(int? advertised) {
    final complain = _onComplaint;
    if (complain == null || advertised == null) return;
    final floorMs = config.heartbeatFloor.inMilliseconds;
    // The two quantities the boundary is made of, named rather than spelled
    // twice: the silence the skip rule allows at the floor, and the smallest
    // deadline that leaves a whole beat of margin against it.
    final worstCaseSilenceMs = floorMs * 2;
    final marginedDeadlineMs = floorMs * 3;
    if (marginedDeadlineMs <= advertised) return;
    complain('this gateway advertises a $advertised ms heartbeat deadline and '
        'this panel will not beat faster than its $floorMs ms floor. The '
        'skip-on-traffic rule means the gateway can see up to '
        '$worstCaseSilenceMs '
        'ms of silence between beats, so it will reap this session and the '
        'panel will resync its whole page every cycle. Raise the gateway\'s '
        'heartbeatDeadline above $marginedDeadlineMs ms, or lower '
        'ClientConfig.heartbeatFloor.');
  }

  /// How often this pump beats, given what the gateway has told it.
  ///
  /// **A third of the deadline, floored.** Three is OPC UA's ratio and the one
  /// `ServerConfig.heartbeatDeadline`'s own doc names ("6 s is OPC UA's 3x
  /// LifetimeCount ratio over a 2 s app heartbeat"), so the two ends already
  /// agreed on it before either had a pump. What a third buys is that **two
  /// consecutive beats may be lost** — to a GC pause, a Wi-Fi retransmit, a
  /// scheduler stall — before the panel is at risk. A half would tolerate none
  /// of that and a tenth would be nine wasted frames per deadline per panel.
  ///
  /// Against a gateway that advertises nothing, the floor is the whole answer:
  /// beating at [ClientConfig.heartbeatFloor] is conservative, and the
  /// alternative — not beating at all — is the defect this class exists to
  /// fix. Against a gateway that advertises a deadline the floor *cannot*
  /// beat, the floor still wins and [_complainIfUnbeatable] says so; that
  /// combination used to be an unenforced assumption written down here as
  /// "faster than any deadline a sane gateway would set".
  Duration get period {
    final learned = _deadlineMs;
    final derived =
        learned == null ? Duration.zero : Duration(milliseconds: learned ~/ 3);
    return derived > config.heartbeatFloor ? derived : config.heartbeatFloor;
  }

  /// Starts beating. Called on entry to `ready`, and idempotent.
  ///
  /// Idempotent because the alternative is a second timer, and two timers on
  /// this path is two heartbeats per period for ever — the count pin in
  /// `no_retry_test.dart` exists to make that a red rather than a slow leak.
  void start() {
    if (_disposed || _beat != null) return;
    // The link has just come up, which means a `hello` and a `subscribe` have
    // just crossed it. Those are inbound frames at the gateway and they have
    // already moved its deadline, so the first beat belongs one period from
    // now rather than immediately.
    _lastOutboundMs = _now();
    _arm();
  }

  /// Stops beating. Called on leaving `ready`, on dispose, and idempotent.
  void stop() {
    _beat?.cancel();
    _beat = null;
  }

  /// Stops beating for good. Idempotent, and nothing restarts after it.
  void dispose() {
    _disposed = true;
    stop();
  }

  /// Records that something else this client sent has just gone out.
  ///
  /// **So a busy panel sends no heartbeats at all.** The gateway's deadline is
  /// moved by *any* inbound application frame, so a `subscribe`, a write, a
  /// `writeStatus` sweep or a hold tick is already a heartbeat as far as the
  /// reaper is concerned. An operator jogging a machine sends ten deadman
  /// ticks a second; adding a ping on top of that would be pure cost. The beat
  /// below skips whenever the wire has carried anything within one period,
  /// which makes this a *silence* timer rather than a metronome — the same
  /// question the reaper is asking, asked from this end.
  void noteOutbound() => _lastOutboundMs = _now();

  /// What the panel would acknowledge if it beat right now.
  Map<String, int> _ackNow() => _ackSource?.call() ?? const {};

  static bool _sameAck(Map<String, int> a, Map<String, int> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  void _arm() {
    _beat?.cancel();
    // "Unchanged since the last beat" starts meaning something here and not
    // before: see [_lastAckSent].
    _lastAckSent = _ackNow();
    // The one Timer.periodic in this package's lib/, and the named carve-out
    // in no_retry_test.dart's pin. It schedules a liveness frame and it can
    // schedule nothing else: see this library's doc.
    _beat = Timer.periodic(period, (_) => _sendBeat());
  }

  /// One beat, or nothing at all.
  ///
  /// Reads as a sequence of gates on purpose, and each one is a different
  /// reason not to send rather than a defensive nicety:
  ///
  ///  * disposed — the panel is closing and there is no link left;
  ///  * not ready — the barrier is shut, and a frame offered to a socket that
  ///    is not there is buffered without bound and silently lost;
  ///  * no peer — `callWithDeadline` throws `LinkDown` **synchronously** for a
  ///    null peer, and catching that would be using an exception as a gate;
  ///  * recent traffic **and a moving ack** — see [noteOutbound] and below.
  ///
  /// The traffic gate is written as an unsigned window rather than a bare
  /// `< period`: a *negative* elapsed reading is not "traffic within the
  /// period", it is a clock that moved, and the safe answer to a clock that
  /// moved is to beat. [_now] is monotonic by default so the branch is unused
  /// in production, but the seam is injectable and a seam that can be handed a
  /// wall clock will be.
  ///
  /// ## Why traffic alone stopped being enough (§6)
  ///
  /// **A panel busy *writing* has proved nothing about whether it is
  /// *reading*.** Answering a jog button and decoding `u` frames are different
  /// code paths, so the skip rule above — correct for every panel that is
  /// keeping up — silenced precisely the panel the delivery verdict was built
  /// to catch: it sent no beats, so it sent no ack, so the gateway had nothing
  /// to judge it by and fell back on a 20–40 s pong timeout.
  ///
  /// The rule is now: beat when the wire has been quiet for a period **or**
  /// when the ack this beat would carry has not moved since the last one.
  /// Skip only when there was recent traffic **and** the ack has moved.
  ///
  /// **`16-CONTEXT.md` says this both ways round in consecutive sentences and
  /// the other way is wrong.** An *unchanged* ack is the signal that the panel
  /// may have stopped reading, and therefore the one case where the gateway
  /// most needs to hear from it; skipping on an unchanged ack would silence
  /// the stuck reader again by a shorter road. `heartbeat_test.dart`'s
  /// `_ackMoving` and `_ackFrozen` arms are opposite outcomes on identical
  /// traffic so that the wrong reading cannot pass.
  ///
  /// **No storm is available, structurally.** Both halves are evaluated inside
  /// the one `Timer.periodic(period)`, so the narrowed gate can only ever
  /// restore the un-skipped rate — 30 beats/min at shipping numbers, the
  /// ceiling §2.5 models and `heartbeat_test.dart` measures rather than
  /// argues.
  void _sendBeat() {
    if (_disposed) return;
    if (!_isReady()) return;
    final ack = _ackNow();
    final ackMoved = !_sameAck(ack, _lastAckSent);
    // Every tick, not only the ones that send. See [_lastAckSent].
    _lastAckSent = ack;
    // **An absent ack is not "an ack that has not moved".** §6's rule reads
    // literally as "beat whenever the ack has not moved", and an empty map
    // never moves — which would put every busy panel holding no pages back on
    // a full-rate heartbeat, the cost `noteOutbound` exists to avoid, in
    // exchange for telling the gateway a number it cannot act on. A panel with
    // nothing to acknowledge has no delivery to be judged on: `ackedSeq` stays
    // null for it and the delivery verdict skips it by design. So the frozen
    // ack only *forces* a beat when there is an ack to carry.
    //
    // Caught by `heartbeat_test.dart`'s pre-existing skip arm, which went from
    // 0 beats to 7 under the literal reading.
    final ackWorthSending = ack.isNotEmpty && !ackMoved;
    final sinceOutbound = _now() - _lastOutboundMs;
    if (sinceOutbound >= 0 &&
        sinceOutbound < period.inMilliseconds &&
        !ackWorthSending) {
      return;
    }
    final peer = _peer();
    if (peer == null) return;

    _lastOutboundMs = _now();
    _pings++;
    // Fire and forget, and it cannot wedge: `callWithDeadline` times the call
    // out on its own, and the answer is discarded because the *request* was
    // the point. A ping the gateway answers late still moved its deadline when
    // it arrived, and nothing here has a decision to make about the reply.
    //
    // Errors are discarded rather than caught around the gate — a distinction
    // this library's doc argues. The peer was live when it was read one line
    // above; if it died between then and the write, that is the reconnect's
    // business and not a fault this pump can act on.
    //
    // `Future.sync` and not a bare call (07-REVIEW IN-03): `callWithDeadline`
    // is deliberately not `async` (`deadline.dart:76-82`) and `sendRequest`
    // throws `StateError` **synchronously** on a closed peer, so a throw on
    // this line would escape into the `Timer.periodic` callback as an
    // unhandled zone error rather than a dropped beat. Not reachable today —
    // `_retirePeer` nulls `_peer` before `_enter(down)` in one synchronous
    // statement sequence, so the null check above covers the whole window —
    // but the invariant that makes it unreachable lives in another file.
    //
    // `PingParams.toJson` omits the map when there is nothing to acknowledge,
    // so a panel holding no pages beats with the same 47-byte frame it always
    // did and a gateway too old to read an ack sees no change at all.
    unawaited(Future.sync(() => callWithDeadline(
          () => peer,
          Methods.ping,
          params: PingParams(ack: ack).toJson(),
          deadline: config.controlDeadline,
        )).then((_) {}, onError: (Object _) {}));
  }
}

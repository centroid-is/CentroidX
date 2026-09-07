@TestOn('vm')

/// The app heartbeat: the one periodic frame this client owes the gateway.
///
/// **What is being asserted, and why it needed a plan of its own.** The gateway
/// reaps any session that has gone a `heartbeatDeadline` without an inbound
/// application frame. A panel that only watches a page sends nothing after its
/// handshake, so before `heartbeat_pump.dart` existed every healthy panel in
/// the plant was closed with `4003`, redialled and resynced its whole page once
/// every six seconds — measured, three reaps in twenty-one idle seconds, in
/// 07-08-SUMMARY deviation 3. `test/gate/herd_gate_test.dart`'s idle-liveness
/// case is that measurement inverted and is the end-to-end proof; this file is
/// the mechanism, case by case.
///
/// **Why the cases below are mostly unit cases over a scripted peer.** Every
/// property this pump has is a property about *what it does not do* — does not
/// beat while the link is down, does not buffer a beat it could not send, does
/// not send anything but a ping, does not hold a timer it is not using. Each of
/// those is a negative over a window, and a negative over a window costs
/// wall-clock seconds. Driven against a real gateway at a real cadence the set
/// would be a minute of lane time; driven over `StreamChannelController` with a
/// 40 ms floor it is under two seconds and the assertions are stronger, because
/// the frames are read off the wire rather than inferred from a counter. The
/// two arms that genuinely need a socket — the wiring to `LinkState` and the
/// pre-handshake silence — are at the bottom and use the real fixture.
///
/// The scripted-peer shape is `deadline_test.dart:55-111`'s, including the
/// reason its controller is not `sync: true`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:json_rpc_2/json_rpc_2.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:tfc_relay_client/src/client_config.dart';
import 'package:tfc_relay_client/src/heartbeat_pump.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'support/fault_fixture.dart';

/// The cadence every unit case in this file runs at.
///
/// Forty milliseconds, which is below `ClientConfig`'s own `deadlineFloor` and
/// is exactly why [ClientConfig.heartbeatFloor] is validated with `_positive`
/// rather than `_atLeastFloor` (05-07's lesson, restated in that field's doc).
/// A file that had to wait a second per beat would either be twenty seconds
/// long or would assert one beat where it means to assert a rhythm.
const Duration _floor = Duration(milliseconds: 40);

/// Long enough for several beats at [_floor] to have happened if any were
/// going to.
///
/// Used only for the shape a poll cannot establish — that *nothing* further
/// occurred. Polling for "no ping yet" would pass the instant it looked, which
/// is every instant before the one that matters. `no_retry_test.dart:312-320`
/// makes the same argument for the same kind of arm.
const Duration _severalBeats = Duration(milliseconds: 300);

ClientConfig _config({Duration floor = _floor}) => ClientConfig(
      heartbeatFloor: floor,
      // Below the default floor, so a ping that is never answered gives up
      // quickly instead of holding a pending future across the whole case.
      deadlineFloor: const Duration(milliseconds: 50),
      controlDeadline: const Duration(milliseconds: 100),
      writeDeadline: const Duration(milliseconds: 100),
      freshnessDeadline: const Duration(milliseconds: 200),
    );

/// A peer on the far end of an in-memory pair that records what it was asked.
final class _ScriptedPeer {
  _ScriptedPeer({this.answer = true})
      : _controller = StreamChannelController<String>() {
    peer = Peer(_controller.local);
    unawaited(peer.listen().catchError((Object _) {}));
    _controller.foreign.stream.listen((raw) {
      final request = jsonDecode(raw) as Map<String, Object?>;
      requests.add(request);
      if (!answer) return;
      _controller.foreign.sink
          .add(jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': {}}));
    });
  }

  /// Deliberately not `sync: true` — `deadline_test.dart:66-71`'s reason: on a
  /// synchronous channel a reply can arrive before the request it answers is on
  /// the peer's books and is dropped as an unknown id, which a real socket
  /// never does.
  final StreamChannelController<String> _controller;
  late final Peer peer;

  /// Whether this end answers at all. `false` is the gateway that has stopped
  /// talking while its socket is still up.
  final bool answer;

  /// Every request this peer was asked, decoded, in order.
  final List<Map<String, Object?>> requests = <Map<String, Object?>>[];

  /// The method names, in order — what the "only ping" pin reads.
  List<String> get methods => [for (final r in requests) '${r['method']}'];

  Future<void> dispose() => peer.close();
}

/// A real elapsed clock with an offset a case can move under the pump's feet.
///
/// Reads a `Stopwatch` — so time genuinely passes while the case waits — and
/// adds [stepMs], which is how a case reproduces a clock that jumps without
/// waiting out the jump.
final class _SteppableClock {
  final Stopwatch _elapsed = Stopwatch()..start();
  int stepMs = 0;
  int read() => _elapsed.elapsedMilliseconds + stepMs;
}

/// A pump wired to a scripted peer, with both switches a case needs to flip.
final class _Rig {
  _Rig({
    bool ready = true,
    bool withPeer = true,
    bool answer = true,
    Duration floor = _floor,
    int? deadlineMs,
    int Function()? elapsed,
  }) : scripted = _ScriptedPeer(answer: answer) {
    isReady = ready;
    hasPeer = withPeer;
    pump = HeartbeatPump(
      config: _config(floor: floor),
      isReady: () => isReady,
      peer: () => hasPeer ? scripted.peer : null,
      elapsed: elapsed,
      onComplaint: complaints.add,
    );
    if (deadlineMs != null) pump.learnedDeadlineMs(deadlineMs);
    addTearDown(pump.dispose);
    addTearDown(scripted.dispose);
  }

  final _ScriptedPeer scripted;
  late final HeartbeatPump pump;

  /// What the pump had to say about the gateway's configuration. Wired to the
  /// same list `RemoteStateMan.complaints` publishes.
  final List<String> complaints = <String>[];

  /// The link's readiness, as the pump sees it. Flipped by cases that want a
  /// beat to land on a link that has gone since the timer was armed.
  late bool isReady;

  /// Whether there is a peer to send down at all — the `null` the supervisor
  /// leaves behind between a socket dying and the next one coming up.
  late bool hasPeer;
}

void main() {
  group('the timer exists only while the link does', () {
    test('a pump that was never started holds no timer and sends nothing',
        () async {
      final rig = _Rig();
      expect(rig.pump.debugTimerCount, 0);

      await Future<void>.delayed(_severalBeats);

      expect(rig.pump.debugTimerCount, 0,
          reason: 'a pump nobody started armed itself. The lifetime is owned '
              'by RemoteStateMan\'s LinkState listener and by nothing else; a '
              'pump that arms on construction beats at a socket that has not '
              'been dialled');
      expect(rig.scripted.requests, isEmpty,
          reason: 'a pump nobody started put ${rig.scripted.methods} on the '
              'wire');
    });

    test('starting arms exactly one timer, and starting twice does not arm a '
        'second', () {
      final rig = _Rig();

      rig.pump.start();
      expect(rig.pump.debugTimerCount, 1);

      rig.pump.start();
      rig.pump.start();
      expect(rig.pump.debugTimerCount, 1,
          reason: 'a repeated transition into ready left more than one timer '
              'behind. Two timers is two heartbeats per period for ever, and '
              'the extra one is orphaned — nothing cancels a timer whose '
              'handle was overwritten, so it fires into a disposed pump for '
              'the life of the process');
    });

    test('stopping disarms it, and a stopped pump sends nothing', () async {
      final rig = _Rig();
      rig.pump.start();
      await Future<void>.delayed(_severalBeats);
      final sentWhileRunning = rig.pump.debugHeartbeatsSent;
      expect(sentWhileRunning, greaterThan(0),
          reason: 'the pump sent nothing at all while running, so the arm '
              'below would be measuring a pump that never worked');

      rig.pump.stop();
      expect(rig.pump.debugTimerCount, 0);
      await Future<void>.delayed(_severalBeats);

      expect(rig.pump.debugHeartbeatsSent, sentWhileRunning,
          reason: 'the pump went on beating after the link left ready. This '
              'is the leak that matters most on a panel: a link that flaps all '
              'shift accumulates one live timer per cycle, each of them '
              'pinging a peer that no longer exists');
    });

    test('dispose disarms it for good and nothing restarts after it', () async {
      final rig = _Rig();
      rig.pump.start();
      rig.pump.dispose();
      expect(rig.pump.debugTimerCount, 0);

      // The transition a racing LinkState event would deliver into a client
      // that is already closing. `RemoteStateMan.dispose` cancels its
      // subscription, but the ordering between a stream event already in
      // flight and a dispose is not something this class may assume.
      rig.pump.start();
      await Future<void>.delayed(_severalBeats);

      expect(rig.pump.debugTimerCount, 0,
          reason: 'a disposed pump was restartable, so a LinkState event that '
              'was already in flight when the panel closed leaves a timer '
              'running after dispose returned');
      expect(rig.scripted.requests, isEmpty);
    });
  });

  group('the gate, and what happens to a beat that cannot go out', () {
    test('a beat that lands while the link is down is dropped, never stored',
        () async {
      // The link goes *after* the timer is armed, which is the only ordering
      // that can produce this: `stop()` is called from the LinkState listener
      // and a beat can be scheduled for a moment that has already passed.
      final rig = _Rig();
      rig.pump.start();
      rig.isReady = false;

      await Future<void>.delayed(_severalBeats);
      expect(rig.pump.debugHeartbeatsSent, 0,
          reason: 'the pump sent ${rig.pump.debugHeartbeatsSent} beats down a '
              'link that was not ready');

      // The recovery. If the dropped beats had been stored they would arrive
      // now, in a burst — which is precisely the queue CLAUDE.md forbids and
      // `_WsSink.add` would swallow without reporting (flutter#103306).
      rig.isReady = true;
      await Future<void>.delayed(_floor * 2);

      expect(rig.pump.debugHeartbeatsSent, lessThanOrEqualTo(2),
          reason: 'the link came back and ${rig.pump.debugHeartbeatsSent} '
              'heartbeats arrived at once, so the beats dropped while it was '
              'down were buffered rather than discarded. A stored heartbeat is '
              'a claim about a moment that has passed');
    });

    test('a beat with no peer is dropped and does not throw', () async {
      // `callWithDeadline` throws LinkDown **synchronously** for a null peer
      // (deadline.dart:93-94). Inside a Timer callback that is an uncaught
      // async error, which takes down whatever zone the panel is running in.
      // The pump gates on the peer instead of catching the exception, which is
      // HoldToRunController's discipline: a catch here would also swallow the
      // StateError that means a real defect.
      final errors = <Object>[];
      await runZonedGuarded(() async {
        final rig = _Rig(withPeer: false);
        rig.pump.start();
        await Future<void>.delayed(_severalBeats);
        expect(rig.pump.debugHeartbeatsSent, 0);
      }, (error, _) => errors.add(error));

      expect(errors, isEmpty,
          reason: 'the pump threw $errors from inside its own timer while the '
              'supervisor had no peer. An uncaught error on a timer is not a '
              'failed beat, it is a panel whose zone handler fires once every '
              'period for as long as the link is down');
    });

    test('a gateway that never answers cannot wedge the pump', () async {
      // The half-open socket. The peer is live, the request goes out, and no
      // answer ever comes. A pump that awaited its own ping would beat once
      // and then stop for ever — and would stop precisely on the link where
      // being reaped is most likely.
      final rig = _Rig(answer: false);
      rig.pump.start();
      await Future<void>.delayed(_severalBeats);

      expect(rig.pump.debugHeartbeatsSent, greaterThan(1),
          reason: 'the pump sent ${rig.pump.debugHeartbeatsSent} beats to a '
              'gateway that answers nothing. The request is the point — it is '
              'what moves the reaper\'s deadline — and nothing here has a '
              'decision to make about the reply');
    });
  });

  group('the pump sends one method and no other', () {
    test('every frame it puts on the wire is a ping', () async {
      final rig = _Rig();
      rig.pump.start();
      await Future<void>.delayed(_severalBeats);

      expect(rig.scripted.methods, isNotEmpty,
          reason: 'nothing reached the wire, so the assertion below is about '
              'an empty list');
      expect(rig.scripted.methods.toSet(), {Methods.ping},
          reason: 'the pump put ${rig.scripted.methods.toSet()} on the wire. '
              'It may send `ping` and nothing else: a periodic timer that can '
              'reach any other method is a second, unbookkept way for a frame '
              'to reach the plant, which is what no_retry_test.dart\'s pins '
              'exist to forbid — and the pin over this file asserts the same '
              'thing structurally');
      expect(rig.scripted.requests.first.containsKey('id'), isTrue,
          reason: 'the heartbeat is a request rather than a notification, so '
              'a gateway that answers it proves the round trip and a gateway '
              'that does not is visible as silence to the freshness watchdog');
    });
  });

  group('the period follows the gateway, floored', () {
    test('the period is a third of the deadline the gateway advertised', () {
      final rig = _Rig(deadlineMs: 6000, floor: const Duration(seconds: 1));

      expect(rig.pump.period, const Duration(seconds: 2),
          reason: 'six seconds of patience buys three beats, so two of them '
              'may be lost to a GC pause or a Wi-Fi retransmit before the '
              'panel is at risk. Three is the ratio ServerConfig'
              '.heartbeatDeadline\'s own doc names, so both ends already '
              'agreed on it before either had a pump');
    });

    test('the floor wins against a gateway with very little patience', () {
      final rig = _Rig(deadlineMs: 300, floor: const Duration(seconds: 1));

      expect(rig.pump.period, const Duration(seconds: 1),
          reason: 'a gateway advertising 300 ms would have this panel beating '
              'ten times a second, which is a self-inflicted load multiplied '
              'by every screen in the factory. The floor is the panel\'s own '
              'limit on what it will do about somebody else\'s configuration');
    });

    test('a gateway the floor cannot beat is complained about, not ignored',
        () {
      // **07-REVIEW WR-01.** The traffic-skip rule means the worst-case
      // silence the gateway sees is *two* periods, not one: an outbound frame
      // landing just after a beat suppresses the next one, so the gateway last
      // sees a frame at `kp+e` and next sees one at `(k+2)p`. At the derived
      // period that is two thirds of the deadline and safe. At the floor it is
      // a flat two floors — so any gateway advertising a deadline of two
      // floors or less reaps this panel anyway, with the pump running and
      // `debugHeartbeatsSent` climbing, reinstating the exact six-second
      // resync defect the pump exists to fix.
      //
      // The pump cannot fix that from this end: the floor is the panel's own
      // limit on what it will do about somebody else's configuration. What it
      // can do is stop being silent about it.
      final rig = _Rig(floor: const Duration(seconds: 1), deadlineMs: 2000);

      expect(rig.pump.period, const Duration(seconds: 1),
          reason: 'the clamp itself is unchanged: the panel still refuses to '
              'beat faster than its floor');
      expect(rig.complaints, hasLength(1),
          reason: 'the gateway advertises a 2000 ms deadline and this panel '
              'cannot promise a frame more often than every 2000 ms, so it '
              'will be reaped for silence and resync its whole page every '
              'cycle — and said nothing about it. `RemoteStateMan.complaints` '
              'is the only diagnostic surface this client has');
      expect(rig.complaints.single, contains('2000'),
          reason: 'a complaint that does not name the number it is about '
              'sends whoever reads it back to the gateway\'s config file to '
              'guess which one');
      expect(rig.complaints.single, contains('heartbeatDeadline'),
          reason: 'the complaint has to name the setting to raise, or it is a '
              'report of a fault with no repair attached');
    });

    test('a gateway with enough patience for the floor is not complained about',
        () {
      final rig = _Rig(floor: const Duration(seconds: 1), deadlineMs: 6000);

      expect(rig.complaints, isEmpty,
          reason: 'the intended configuration produced a complaint. A '
              'diagnostic surface that fires on the healthy case is one an '
              'operator stops reading, which is the grey-that-cries-wolf '
              'failure in a different surface');
    });

    test('a gateway that advertises nothing leaves the pump on its floor', () {
      final rig = _Rig(floor: const Duration(seconds: 1));

      expect(rig.pump.debugLearnedDeadlineMs, isNull);
      expect(rig.pump.period, const Duration(seconds: 1),
          reason: 'against a gateway that advertises no deadline the pump '
              'beats at its floor. Not beating at all would be the defect '
              'this class exists to fix, and the floor is faster than any '
              'deadline a sane gateway would set');
    });

    test('a new deadline re-arms a pump that is already running', () async {
      final rig = _Rig(floor: const Duration(milliseconds: 10));
      rig.pump.learnedDeadlineMs(30_000);
      rig.pump.start();
      expect(rig.pump.period, const Duration(seconds: 10));

      // A replacement gateway, configured differently. Until this is applied
      // the panel is beating at the retired gateway's cadence, and the window
      // in which it is doing that is exactly the window in which it is reaped
      // for the difference.
      rig.pump.learnedDeadlineMs(90);
      expect(rig.pump.period, const Duration(milliseconds: 30));

      await Future<void>.delayed(_severalBeats);
      expect(rig.pump.debugHeartbeatsSent, greaterThan(0),
          reason: 'the pump kept the old ten-second period after learning a '
              'new deadline, so nothing went out inside the window. A pump '
              'that only applies a new cadence at the next reconnect learns it '
              'one reaping too late');
    });
  });

  /// The band between two floors and three, where the panel had nothing to say
  /// about a deadline it cannot honour (S13).
  ///
  /// **The boundary is arithmetic, not taste, and the next person to move it
  /// should have to argue with the numbers.** [HeartbeatPump.period] is
  /// `advertised ~/ 3` clamped up to [ClientConfig.heartbeatFloor]. The
  /// skip-on-traffic rule in `noteOutbound` means an outbound frame landing
  /// just after a beat suppresses the next one, so the worst-case silence the
  /// gateway sees is **two periods, never one**. The margin this panel has
  /// against the gateway's patience is therefore `advertised - 2 x period`.
  ///
  /// | advertised | period | worst-case silence | margin | complaint |
  /// |---|---|---|---|---|
  /// | 2500 | 1000, floored | 2000 | 500 — half a beat | yes |
  /// | 2999 | 1000, floored | 2000 | 999 — a beat less a millisecond | yes |
  /// | 3000 | 1000, floored | 2000 | 1000 — exactly one beat | no |
  /// | 6000 | 2000, derived | 4000 | 2000 — exactly one beat | no |
  ///
  /// For every advertised value in `(2f, 3f]` the derived period is at or below
  /// the floor, so the period is a flat `f`, the silence is a flat `2f`, and
  /// the margin is `advertised - 2f` — somewhere in `(0, f]`, and at `2f + 1`
  /// it is one millisecond, which a single Wi-Fi retransmit spends. **Below
  /// three floors the panel cannot promise a full beat of margin**, which is
  /// what the complaint's own text has always recommended (raise
  /// `heartbeatDeadline` above `floorMs * 3`) and what
  /// `ServerConfig.minHeartbeatDeadline` — 3 s, against this floor of 1 s —
  /// already enforces from the other end. The two ends' numbers meet at this
  /// boundary rather than at a rounder one.
  ///
  /// The 3000 ms arm is the one that stops the fix from being "complain about
  /// everything": at exactly three floors the margin is a full beat and there
  /// is nothing to say. Without it, a gate that complained at every deadline
  /// would satisfy the two complaining arms vacuously.
  group('the margin band between two floors and three', () {
    const floor = Duration(seconds: 1);

    for (final (deadlineMs, complains, periodMs, marginMs) in const [
      (2500, true, 1000, 500),
      (2999, true, 1000, 999),
      (3000, false, 1000, 1000),
      (6000, false, 2000, 2000),
    ]) {
      test(
          'a $deadlineMs ms deadline against a 1000 ms floor is '
          '${complains ? 'complained about' : 'left alone'}', () {
        // Pinned and never stepped. These arms assert configuration
        // arithmetic rather than cadence, so nothing in them may depend on
        // ambient time — 07-REVIEW WR-03's discipline applied to a case that
        // never starts the pump.
        final clock = _SteppableClock();
        final rig = _Rig(
            floor: floor, deadlineMs: deadlineMs, elapsed: clock.read);

        expect(rig.pump.period.inMilliseconds, periodMs,
            reason: 'the period is a third of $deadlineMs ms clamped up to the '
                '1000 ms floor, so it is $periodMs ms. The complaint boundary '
                'below is derived from this number; a change to `period` that '
                'quietly restores the margin has to come through here first');

        final worstCaseSilenceMs = rig.pump.period.inMilliseconds * 2;
        expect(deadlineMs - worstCaseSilenceMs, marginMs,
            reason: 'the skip rule means the gateway can see '
                '$worstCaseSilenceMs ms of silence between beats, so against '
                '$deadlineMs ms of patience the margin is $marginMs ms');
        expect(deadlineMs - worstCaseSilenceMs < rig.pump.period.inMilliseconds,
            complains,
            reason: 'the complaint and the arithmetic must agree: the panel '
                'says something exactly when the margin is short of one full '
                'beat. If these two ever disagree, one of them has been '
                'changed without the other');

        if (complains) {
          expect(rig.complaints, hasLength(1),
              reason: 'a gateway advertising $deadlineMs ms leaves this panel '
                  'with $marginMs ms of margin — less than the one beat it '
                  'would need to lose a frame and survive. One retransmit '
                  'reaps the session, the panel resyncs its whole page, and '
                  '`RemoteStateMan.complaints` — the only diagnostic surface '
                  'this client has — said nothing');
          expect(rig.complaints.single, contains('$deadlineMs'),
              reason: 'a complaint that does not name the number it is about '
                  'sends whoever reads it back to the gateway\'s config file '
                  'to guess which one');
        } else {
          expect(rig.complaints, isEmpty,
              reason: 'at $deadlineMs ms the margin is a full $marginMs ms '
                  'beat, which is the safe boundary and the value '
                  'ServerConfig.minHeartbeatDeadline already enforces. A '
                  'diagnostic surface that fires on the healthy case is one an '
                  'operator stops reading');
        }
      });
    }
  });

  group('a busy panel sends no heartbeats at all', () {
    test('other outbound traffic within the period skips the beat', () async {
      final rig = _Rig();
      rig.pump.start();

      // A panel doing what a panel does: an operator holding a jog button
      // sends ten deadman ticks a second, and every one of them is an inbound
      // application frame at the gateway — which is what the reaper is
      // measuring. A ping on top would be pure cost on the busiest path there
      // is.
      final chatter = Timer.periodic(
          const Duration(milliseconds: 10), (_) => rig.pump.noteOutbound());
      addTearDown(chatter.cancel);

      await Future<void>.delayed(_severalBeats);
      chatter.cancel();

      expect(rig.pump.debugHeartbeatsSent, 0,
          reason: 'the pump sent ${rig.pump.debugHeartbeatsSent} heartbeats '
              'while the client was already putting a frame on the wire every '
              'ten milliseconds. The heartbeat is a *silence* timer, not a '
              'metronome: it asks the same question the reaper asks, from this '
              'end');

      // And it resumes the moment the panel goes quiet, or the skip would be a
      // way to be reaped rather than a way to save frames.
      await Future<void>.delayed(_severalBeats);
      expect(rig.pump.debugHeartbeatsSent, greaterThan(0),
          reason: 'the chatter stopped and the pump did not resume, so a panel '
              'that was briefly busy is silent for ever afterwards — which is '
              'the reaping this whole file is about, reached by a different '
              'road');
    });

    test('a clock that steps backwards does not silence the pump', () async {
      // **07-REVIEW WR-03.** A cadence is an elapsed-time question and this
      // pump was asking it of `DateTime.now()`. NTP correcting a fast RTC —
      // the fish-factory panel with a dead CMOS battery `clock_offset.dart`
      // describes — steps the wall clock backwards, and every subsequent
      // `_now() - _lastOutboundMs` is negative and reads as "traffic within
      // the period". The pump then sends nothing until real time catches up
      // past the pre-step value; the gateway sees silence, reaps at 4003, and
      // the panel pays a full page resync — the exact defect this file exists
      // to prevent, reached through the clock instead of through the timer.
      final clock = _SteppableClock();
      final rig = _Rig(elapsed: clock.read);
      rig.pump.start();

      await Future<void>.delayed(_severalBeats);
      final beforeStep = rig.pump.debugHeartbeatsSent;
      expect(beforeStep, greaterThan(0),
          reason: 'the pump sent nothing before the step, so the step below '
              'would be measuring a pump that was never beating');

      // The correction. Ten seconds is a modest one for a panel that has been
      // running on an uncorrected crystal since the last power cut.
      clock.stepMs -= 10_000;

      await Future<void>.delayed(_severalBeats);
      expect(rig.pump.debugHeartbeatsSent, greaterThan(beforeStep),
          reason: 'the pump has sent nothing since the clock stepped back ten '
              'seconds. It will send nothing for ten more seconds of real '
              'time, which is longer than any deadline a gateway would set, '
              'so the panel is reaped for a silence its own clock invented');
    });
  });

  group('wired to the link, over a real gateway', () {
    test('the timer follows readiness and nothing beats before the handshake',
        () async {
      // The pre-handshake half, and it is the Phase 6 ingress posture from the
      // panel's side: a socket that has connected but not completed `hello` is
      // not a session, and a frame sent into that window is a frame the
      // gateway refuses with `helloRequired`. The blackhole is armed *before
      // the dial*, so the panel connects, sends its hello and is answered by
      // nothing — which parks it in `resyncing` for the whole case.
      final fixture = await faultFixture(
        keys: const {'ST101.CN01.MOT01.setpoint'},
        withProxy: true,
        seed: (plant) => plant.setValue('ST101.CN01.MOT01.setpoint', 1200),
        armBeforeDial: (proxy) => proxy.blackhole(),
      );

      await Future<void>.delayed(const Duration(seconds: 1));
      expect(fixture.client.debugHeartbeatTimerCount, 0,
          reason: 'a panel that has never completed a handshake is holding a '
              'heartbeat timer. Readiness is defined as hello answered and '
              'every page resynced; anything armed before that is a frame '
              'aimed at a session the gateway does not believe in yet');
      expect(fixture.client.debugHeartbeatsSent, 0,
          reason: 'the panel sent ${fixture.client.debugHeartbeatsSent} '
              'heartbeats before its handshake landed. Pre-hello frames must '
              'not exist — the gateway refuses them, and a session that never '
              'authenticates must not be able to hold its own slot open by '
              'shouting at a gate that keeps saying no');

      // Now let it through. Readiness is the trigger and the only trigger.
      fixture.proxy.blackhole(enabled: false);
      await until('the link', () => fixture.client.isReady,
          budget: const Duration(seconds: 10));

      expect(fixture.client.debugHeartbeatTimerCount, 1,
          reason: 'the link reached ready and no heartbeat was armed, so this '
              'panel is on the six-second reap cycle 07-08 measured');

      await until('the pump to beat at least once',
          () => fixture.client.debugHeartbeatsSent > 0,
          budget: const Duration(seconds: 10));

      // And it is disarmed the moment the link goes, rather than at the next
      // reconnect.
      fixture.proxy.killOnce();
      await until('the link to go down',
          () => fixture.client.debugHeartbeatTimerCount == 0,
          budget: const Duration(seconds: 10));
    }, timeout: const Timeout(Duration(seconds: 60)));
  }, tags: 'faults');
}

/// Silence is never ambiguous, and a frozen gateway says so.
///
/// **F25 / SRV-06.** A client that has heard nothing for a second has to be
/// able to tell "the tag has not moved" from "the server stopped evaluating
/// it". Those two states look identical on a socket that is still open, and
/// they call for opposite operator responses: one is a healthy plant, the
/// other is a screen quietly showing the past. So every tick carries, per live
/// subscription, that subscription's `seq` and the `evaluatedAt` of the tick
/// that just ran — and the two are asserted separately below, because
/// conflating them is precisely how a client's gap detector starts lying: a
/// `seq` that advanced on an idle tick would make the next real push look like
/// a gap and trigger a resync of a plant that never changed.
///
/// **Finding 10.** Idle event-loop drift was measured at ±2 ms
/// (`[2, 1, 0, -1, 0]`), and a deliberate 400 ms synchronous stall at a 100 ms
/// period produced exactly **one** oversized gap with **no catch-up burst** —
/// which is why one stall yields one announcement per subscription and no
/// debounce. `gateway_stalled` rides the **priority lane** because the client
/// most in need of it is the one already behind, and the telemetry lane is
/// where "already behind" lives.
///
/// **stalledMs is the absolute gap** (03-CONTEXT amendment). At a 50 ms period
/// a 400 ms freeze is reported as `400`, not as the 350 ms of excess: a panel
/// renders it as "the plant view was frozen for 400 ms", which is a statement
/// about the plant, while the excess is a statement about a tick period the
/// client does not know. The case below states both numbers so a monitor that
/// switched to excess fails with a readable difference rather than an
/// off-by-a-period nobody notices.
///
/// The stall is driven with an injected clock and `tickOnce`, not by blocking
/// the isolate: a real 400 ms synchronous freeze in every case is a flake
/// generator on a hosted runner. One case does induce a genuine freeze, tagged
/// `ws`, so the simulated path stays anchored to the thing it simulates.
library;

import 'dart:convert';
import 'dart:io';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/server_config.dart';
import 'package:tfc_relay_server/src/tick_engine.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

import 'support/bands.dart';
import 'support/fake_clock.dart';
import 'support/panels.dart';
import 'support/ws_harness.dart';

/// The wire literal a panel branches on. Written out rather than imported so
/// that a rename of the constant cannot silently change what goes over the
/// wire (`ResyncParams.reason`'s documented vocabulary).
const _gatewayStalled = 'gateway_stalled';

/// Waits for a frame matching [match] to reach the client, polling the
/// fixture's inbound log.
///
/// Wrapped in `within()` by the caller, which is where the named budget lives;
/// the poll interval here is not the measurement.
Future<String> _frame(RelayFixture fixture, bool Function(String) match) async {
  while (true) {
    for (final frame in fixture.inbound) {
      if (match(frame)) return frame;
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  group('idle liveness', () {
    test('an idle tick still carries seq and evaluatedAt per subscription',
        () async {
      final plant = Plant();
      final keys = plant.seed(2, prefix: 'CN01.PUMP');
      final panel = await plant.connect('page-1', keys);

      plant.api.setValues({for (final key in keys) key: 1});
      final pushedAt = plant.tick();
      expect(panel.updates.single.seq, 1,
          reason: 'the push that the idle tick is compared against');
      expect(panel.ticks.last.subs['page-1']?.evaluatedAt, plant.wall(pushedAt),
          reason: 'the tick that carried the push is evaluated at its own '
              'timestamp');

      plant.clearWires();
      final idleAt = plant.tick();

      final tick = panel.ticks.single;
      expect(panel.updates, isEmpty,
          reason: 'nothing changed, so nothing is pushed — an empty u frame '
              'would advance a seq for news that does not exist');
      expect(tick.subs['page-1']?.seq, 1,
          reason: 'seq counts pushes, not ticks; a seq that moved on an idle '
              'tick makes the next real push look like a gap and sends a '
              'healthy panel into a resync loop');
      expect(tick.subs['page-1']?.evaluatedAt, plant.wall(idleAt),
          reason: 'evaluatedAt is what tells the operator the gateway is '
              'still looking at this tag; frozen, it is indistinguishable '
              'from a dead server behind a live socket');
      expect(tick.serverTime, plant.wall(idleAt),
          reason: 'the tick timestamp is the tick that ran, so a client can '
              're-derive its clock offset without a second handshake');
    });

    test('ten idle ticks produce ten notifications and no u frames', () async {
      final plant = Plant();
      final keys = plant.seed(1, prefix: 'CN01.VALVE');
      final panel = await plant.connect('page-1', keys);
      plant.clearWires();

      for (var i = 0; i < 10; i++) {
        plant.tick();
      }

      expect(panel.ticks, hasLength(10),
          reason: 'the cadence is the liveness signal; a missed one is how a '
              'client decides the gateway died');
      expect(panel.updates, isEmpty,
          reason: 'a steady plant produces no telemetry, and most tags on a '
              'plant are steady most of the time');
      expect([for (final tick in panel.ticks) tick.subs['page-1']?.seq],
          everyElement(0),
          reason: 'nothing was ever pushed, so the sequence never moved');
    });

    test('a session with no live subscriptions is ticked without a frame',
        () async {
      final plant = Plant();
      final keys = plant.seed(1, prefix: 'CN01.FAN');
      final panel = await plant.connect('page-1', keys);
      await plant.ask(panel, Methods.unsubscribe, {'sub': 'page-1'});
      plant.clearWires();

      plant.tick();

      expect(panel.frames, isEmpty,
          reason: 'a client watching nothing is told nothing; a tick frame '
              'with an empty subs map is bytes on a link that exists to carry '
              'plant data');
    });

    test('a tick with no sessions at all is a no-op', () {
      final plant = Plant();
      expect(plant.tick, returnsNormally,
          reason: 'a gateway with no panels connected still ticks — that is '
              'every night shift on a quiet line');
      expect(plant.engine.ticks, 1,
          reason: 'the tick counter is the only evidence an idle engine is '
              'running at all');
    });
  });

  group('one session\'s failure is one session\'s failure', () {
    // 03-REVIEW CR-03. `tickOnce` had no containment: `_tickSession` reaches
    // `session.emit` → `writeFrame` → `ws.sink.add`, a socket write on a
    // connection that may have died since the last tick. Because the registry
    // preserves connection order the same session threw first on every
    // subsequent tick, so this was permanent starvation of everything after
    // it — and of the reaper, which is what would have removed the corpse
    // causing it.
    test('a session that throws on emit does not starve the ones after it',
        () async {
      final plant = Plant();
      final keys = plant.seed(1, prefix: 'CN01.CONV');
      final dead = await plant.connect('page-dead', keys);
      final healthy = await plant.connect('page-live', keys);
      dead.breakSocket();
      plant.clearWires();

      plant.api.setValues({keys.single: 7});
      plant.tick();

      expect(healthy.updates.single.changes.values.map((v) => v.v), [7],
          reason: 'the healthy panel is registered after the poisoned one, so '
              'before containment it received nothing at all — on this tick '
              'and on every tick afterwards, which reads on the plant floor '
              'as half the panels going still with no server-side trace');
      expect(dead.session.sentCloseCode, CloseCodes.serverDraining,
          reason: 'a session the server cannot write to is evicted rather '
              'than left to hold the tick; 4002 is the code that tells a panel '
              'to reconnect without alarming, which is the true instruction '
              'when the failure is on our side of the socket');
      expect(plant.errors.map((e) => e.where), contains('tick'),
          reason: 'containment that reported nothing would be a swallowed '
              'error wearing a fix\'s name: the throw went to the ambient zone '
              'before, and this package logs nowhere else');
    });

    test('the sweep still runs on a tick where a session threw', () async {
      final plant = Plant();
      final keys = plant.seed(1, prefix: 'CN01.PUMPX');
      final dead = await plant.connect('page-dead', keys);
      dead.breakSocket();

      // The sweep seam rather than the reaper itself: these panels carry the
      // session's own wall clock, so no amount of advancing the engine's
      // injected one makes them silent. What CR-03 broke is the tick's *last
      // step* not running at all, and that is what is asserted here —
      // `liveness_test.dart` owns the deadline arithmetic.
      var swept = 0;
      final engine = TickEngine(
        registry: plant.registry,
        config: plant.config,
        clock: plant.clock.now,
        sweep: (_) => swept++,
        onSessionError: (error, stack, where) =>
            plant.errors.add((where: where, error: error)),
      );

      plant.api.setValues({keys.single: 1});
      engine.tickOnce(plant.clock.nowMs);

      expect(swept, 1,
          reason: 'the sweep is the tick\'s last step, so an uncontained throw '
              'from any session skipped it entirely — and the session it would '
              'have reaped is the dead one whose socket is causing the throw, '
              'which is how the starvation became permanent rather than '
              'transient');
      expect(plant.errors.map((e) => e.where), contains('tick'),
          reason: 'the session that threw is still reported; containment is '
              'not silence');
    });

    test('a throwing sweep is contained too', () {
      final plant = Plant();
      var swept = 0;
      final engine = TickEngine(
        registry: plant.registry,
        config: plant.config,
        clock: plant.clock.now,
        sweep: (_) {
          swept++;
          throw StateError('the sweep failed');
        },
        onSessionError: (error, stack, where) =>
            plant.errors.add((where: where, error: error)),
      );

      expect(() {
        engine.tickOnce(plant.clock.nowMs);
        engine.tickOnce(plant.clock.nowMs);
      }, returnsNormally,
          reason: 'a sweep that threw took the tick down from the other end: '
              'every session served and none of them reaped, on every tick, '
              'permanently');
      expect(swept, 2, reason: 'the engine keeps ticking after a failed sweep');
      expect(plant.errors.map((e) => e.where), everyElement('reap'),
          reason: 'a contained sweep failure is still a failure, and it is '
              'reported under its own site so a reader can tell it from a '
              'session\'s');
    });
  });

  group('the poll comes before the drain', () {
    test('a full buffer produces the overflow verdict on that tick', () async {
      final plant = Plant();
      final keys = plant.seed(1, prefix: 'CN01.MIX');
      final panel = await plant.connect('page-1', keys,
          buffer: ConflatingSendBuffer(maxPending: 8));
      plant.clearWires();

      for (var i = 0; i < 20; i++) {
        panel.buffer.putPriority('{"jsonrpc":"2.0","method":"status"}');
      }
      plant.tick();

      expect(panel.session.sentCloseCode, CloseCodes.backpressureOverrun,
          reason: 'drain() empties the buffer by contract, so a poll placed '
              'after it reads zero every time and no client is ever evicted — '
              'the server\'s heap grows instead, in silence, which is the '
              'failure the buffer exists to convert into a visible reconnect');
      expect(panel.frames, isEmpty,
          reason: 'a session being disconnected for backpressure is not also '
              'handed the backlog that caused it: resync is a snapshot, never '
              'a replay');
    });
  });

  group('gateway_stalled', () {
    test('a stall announces an absolute duration on the priority lane',
        () async {
      final plant = Plant();
      final keys = plant.seed(2, prefix: 'CN02.MOT');
      final panel = await plant.connect('page-1', keys);
      plant.clearWires();

      // Telemetry pending *before* the late tick, so the announcement has
      // something to overtake. Both lanes are loaded when the tick runs.
      plant.api.setValues({for (final key in keys) key: 9});
      plant.tick(advance: 400);

      final announcement = panel.resyncs.single;
      expect(announcement.reason, _gatewayStalled,
          reason: 'the client branches on this string to decide whether to '
              'throw its cache away');
      expect(announcement.stalledMs, 400,
          reason: 'absolute: the gap was 400 ms at a 50 ms period, so the '
              'excess was 350 — a panel that rendered 350 would tell an '
              'operator the plant froze for a third of a second less than it '
              'did, and the number is the whole content of the sentence');
      expect(announcement.sub, 'page-1',
          reason: 'the announcement is per subscription, because resync is '
              'per subscription');
      expect(panel.indexOf(Methods.resync),
          lessThan(panel.indexOf(Methods.update)),
          reason: 'the client that most needs to hear the gateway stalled is '
              'the one whose telemetry is already backed up; behind the '
              'telemetry, the news arrives after the staleness it explains');
    });

    test('every live subscription on the session is told once', () async {
      final plant = Plant();
      final first = plant.seed(1, prefix: 'CN03.MOT');
      final second = plant.seed(1, prefix: 'CN04.MOT');
      final panel = await plant.connect('page-1', first);
      await plant.ask(panel, Methods.subscribe,
          SubscribeParams(sub: 'page-2', keys: second).toJson());
      plant.clearWires();

      plant.tick(advance: 400);

      expect([for (final r in panel.resyncs) r.sub], ['page-1', 'page-2'],
          reason: 'a page not told to resync keeps rendering values from '
              'before the freeze as if they were current');
      expect([for (final r in panel.resyncs) r.stalledMs], everyElement(400),
          reason: 'one freeze, one duration — two pages on one screen '
              'disagreeing about how long the plant view was frozen is worse '
              'than neither of them saying');
    });

    test('the tick after the stall announces nothing further', () async {
      final plant = Plant();
      final keys = plant.seed(1, prefix: 'CN05.MOT');
      final panel = await plant.connect('page-1', keys);

      plant.tick(advance: 400);
      plant.clearWires();
      plant.tick();

      expect(panel.resyncs, isEmpty,
          reason: 'Finding 10 measured no catch-up burst after a freeze: the '
              'timer fires once, late, and does not make up lost ground. A '
              'second announcement would be a resync storm across every panel '
              'on the plant for one 400 ms hiccup');
      expect(panel.ticks, hasLength(1),
          reason: 'the cadence resumes, unremarkably');
    });
  });

  group('the wake-up reaper forgives the gateway\'s own stall', () {
    // F22's reaper half, at the unit level. `RelaySession.silentForMs()` reads
    // a wall clock and `_lastSeen` advances only when a frame is *processed*,
    // so after a freeze every session looks as silent as the freeze was long —
    // its panel's bytes were in the kernel buffer, unread — and `tickOnce`
    // announces the stall and then reaps in the same synchronous callback. So
    // a woken gateway would 4003 every panel for silence the gateway itself
    // caused: the row's "synchronized false disconnect on every client",
    // reproduced by our own reaper. The fix credits the tick's own measured
    // `LagStalled.stalledMs` against every session's silence for that one
    // tick, and nothing else may (07-08b's only-dead-sessions property, and a
    // forgiveness a client could influence would be a reaper it could talk out
    // of reaping).
    //
    // Each panel accrues its silence on its own `FakeClock` handed to
    // `connect(now:)` — with no separate `monotonicNow` the liveness clock
    // falls back to it — while `plant.tick(advance:)` cranks the engine's,
    // so the forgiveness arithmetic is exercised with the two figures
    // produced independently. In production both figures live on the
    // engine's own clock (09-REVIEW WR-01; the clock-domain group below is
    // what pins that). `advance: N` past the stall threshold makes the
    // verdict `LagStalled(N)` — the stall magnitude is exactly `N`.
    const deadlineMs = 3000;
    const stallMs = 5000; // past the 300 ms threshold and past the deadline

    Plant reaperPlant() => Plant(
        config: ServerConfig(
            tick: ServerConfig.minTick,
            heartbeatDeadline: const Duration(milliseconds: deadlineMs),
            stallThreshold: const Duration(milliseconds: 300)));

    // A panel whose session runs on [clock], connected and subscribed, then
    // held silent for [silentMs] with no inbound frame — exactly what a freeze
    // does to `_lastSeen`.
    Future<Panel> silentPanel(
        Plant plant, String sub, List<String> keys, FakeClock clock,
        {required int silentMs}) async {
      final panel = await plant.connect(sub, keys, now: clock.now);
      // The last inbound frame (subscribe) touched _lastSeen at the clock's
      // current value; advancing it now is the silence, uninterrupted.
      clock.advance(silentMs);
      return panel;
    }

    test('a session that beat during the stall window is not reaped', () async {
      final plant = reaperPlant();
      final keys = plant.seed(1, prefix: 'CN10.MOT');
      final clock = FakeClock(start: 1_000_000);
      // Silence a little past the stall itself: the panel's last beat landed
      // 1 s before the freeze began, so its silence is the freeze plus that
      // gap — still well inside the deadline once the freeze is forgiven.
      final panel = await silentPanel(plant, 'page-1', keys, clock,
          silentMs: stallMs + 1000);

      plant.tick(advance: stallMs);
      await pumpEventQueue();

      expect(panel.session.sentCloseCode, isNull,
          reason: 'a panel that beat through the gateway\'s own freeze was '
              'reaped for silence the gateway caused — silentForMs '
              '(${stallMs + 1000}) exceeds the $deadlineMs ms deadline only '
              'because _lastSeen could not advance while the loop was frozen, '
              'and the wake-up tick must credit its own measured stall against '
              'that silence');
      expect(plant.registry.sessions, hasLength(1),
          reason: 'the forgiven session left the registry, which is a reap by '
              'another name');
    });

    test('a session already silent before the stall is still reaped', () async {
      final plant = reaperPlant();
      final keys = plant.seed(1, prefix: 'CN11.MOT');
      final clock = FakeClock(start: 1_000_000);
      // Dead well before the freeze: a full deadline of pre-stall silence on
      // top of the freeze. Crediting the freeze leaves that pre-stall silence
      // exposed, which still exceeds the deadline.
      const preStall = deadlineMs + 1000;
      final panel = await silentPanel(plant, 'page-1', keys, clock,
          silentMs: stallMs + preStall);

      plant.tick(advance: stallMs);
      await pumpEventQueue();

      expect(panel.session.sentCloseCode, CloseCodes.heartbeatTimeout,
          reason: 'the only-dead-sessions property (07-08b): a panel whose '
              'last frame predates the freeze is genuinely dead, and the '
              'forgiveness must not become a hole that keeps it alive — the '
              'stall credits its own duration and no more');
      final close = panel.closes.single;
      expect(close.code, CloseCodes.heartbeatTimeout,
          reason: 'the close code the reaper sends is unchanged');
      expect(close.reason, startsWith('no heartbeat for '),
          reason: 'the reason shape is unchanged — the fix changes the '
              'decision, never the sentence, so the 123-byte close-reason seam '
              'is not disturbed');
      final reasonBytes = utf8.encode(close.reason).length;
      print('F22 reaper reason: "${close.reason}" — $reasonBytes UTF-8 bytes '
          'against the 123-byte RFC 6455 seam');
      expect(reasonBytes, lessThanOrEqualTo(123),
          reason: 'a close reason over 123 UTF-8 bytes makes the close '
              'silently not happen on dart:io (relay_session.dart:1120), so '
              'the reaper\'s sentence must fit even at a freeze-inflated '
              'silence figure');
    });

    test('the forgiveness lasts one tick and then expires', () async {
      final plant = reaperPlant();
      final keys = plant.seed(1, prefix: 'CN12.MOT');
      final clock = FakeClock(start: 1_000_000);
      // Beat just before the freeze — forgiven on the wake-up tick.
      final panel = await silentPanel(plant, 'page-1', keys, clock,
          silentMs: stallMs + 500);

      // The wake-up tick: LagStalled, so the session is forgiven and survives.
      plant.tick(advance: stallMs);
      await pumpEventQueue();
      expect(panel.session.sentCloseCode, isNull,
          reason: 'the wake-up tick forgives the freeze; this is the same '
              'property as the first arm, restated as the precondition for '
              'what follows');

      // The next tick is on time — LagOk, no verdict to forgive by. The panel
      // still has not beaten, and by now its silence is a whole freeze plus a
      // normal tick past the deadline with no stall to excuse it.
      clock.advance(deadlineMs + 100);
      plant.tick();
      await pumpEventQueue();

      expect(panel.session.sentCloseCode, CloseCodes.heartbeatTimeout,
          reason: 'the forgiveness is bounded to the one tick that measured '
              'the stall: a session that never beats again is reaped on the '
              'next ordinary tick, so a single freeze does not buy a dead '
              'panel a permanent reprieve');
    });

    test('the forgiveness magnitude is exactly the measured stalledMs',
        () async {
      final plant = reaperPlant();
      final onEdge = plant.seed(1, prefix: 'CN13.EDGE');
      final overEdge = plant.seed(1, prefix: 'CN13.OVER');
      final edgeClock = FakeClock(start: 1_000_000);
      final overClock = FakeClock(start: 1_000_000);
      // Both sessions are connected BEFORE either clock is advanced: a
      // connect runs its own ticks, and a session made silent before the
      // other's connect would be reaped on one of those ordinary ticks rather
      // than on the stall tick under test.
      final onEdgePanel = await plant.connect('edge', onEdge, now: edgeClock.now);
      final overEdgePanel =
          await plant.connect('over', overEdge, now: overClock.now);
      // The credit is exactly stallMs, so a session gets exactly
      // stallMs + deadline of grace. On the edge (== that sum) it lives;
      // one millisecond past it, it dies. A forgiveness sourced from anything
      // a client could inflate would move this boundary.
      edgeClock.advance(stallMs + deadlineMs);
      overClock.advance(stallMs + deadlineMs + 1);

      plant.tick(advance: stallMs);
      await pumpEventQueue();

      expect(onEdgePanel.session.sentCloseCode, isNull,
          reason: 'silence of exactly stalledMs + deadline is forgiven down to '
              'exactly the deadline: the credit is the gateway\'s own measured '
              'stall and not a millisecond more');
      expect(overEdgePanel.session.sentCloseCode, CloseCodes.heartbeatTimeout,
          reason: 'one millisecond past stalledMs + deadline is reaped — the '
              'forgiveness is derived from LagStalled alone, so nothing a '
              'client can influence extends a session\'s life past the '
              'deadline (T-09-36). This is the security property, asserted '
              'directly rather than left as a comment');
    });

    test('on a tick with no stall the reaper behaves exactly as before',
        () async {
      final plant = reaperPlant();
      final dead = plant.seed(1, prefix: 'CN14.DEAD');
      final live = plant.seed(1, prefix: 'CN14.LIVE');
      final deadClock = FakeClock(start: 1_000_000);
      final liveClock = FakeClock(start: 1_000_000);
      // Connect both before advancing either, for the same reason as the
      // magnitude arm: a connect ticks, and a tick reaps.
      final deadPanel = await plant.connect('dead', dead, now: deadClock.now);
      final livePanel = await plant.connect('live', live, now: liveClock.now);
      deadClock.advance(deadlineMs + 1);
      liveClock.advance(deadlineMs - 1);

      // A normal, on-time tick: LagOk, so no forgiveness applies to anyone.
      plant.tick();
      await pumpEventQueue();

      expect(deadPanel.session.sentCloseCode, CloseCodes.heartbeatTimeout,
          reason: 'with no stall to forgive, a session past the deadline is '
              'reaped bit-for-bit as before the fix — the whole risk of the '
              'change is behaving differently on a tick where nothing '
              'happened');
      expect(livePanel.session.sentCloseCode, isNull,
          reason: 'and a session inside the deadline is left alone, exactly as '
              'the unmodified reaper did');
    });
  });

  group('the reap comparison lives in ONE clock domain (09-REVIEW WR-01)', () {
    // The forgiveness arms above drive the freeze shapes gate B can lever
    // (Isolate.pause, SIGSTOP), where the wall clock and the monotonic clock
    // observe the same stall — so they cannot see the two shapes where the
    // clocks disagree: a hypervisor stun on a guest whose monotonic clock
    // freezes across it (the Veeam-snapshot trigger the F22 row was written
    // for), and an NTP forward step with no event-loop stall at all. In both,
    // the wall clock jumps while the engine's uptime Stopwatch measures a
    // normal gap: `lag.poll` answers LagOk, `forgivenMs` is 0, and a reaper
    // whose silence figure is wall-clock 4003s every beating panel at once —
    // the synchronized false disconnect, produced by our own reaper, on the
    // exact trigger the forgiveness was built for.
    //
    // The fix measures the silence on the engine's own clock: production
    // injects `engine.now` as every session's `monotonicNow`, and
    // `silentForMs()` subtracts in that domain, so `silentMs - forgivenMs`
    // never crosses clocks. `lastSeenMs` stays wall-clock — the *reported*
    // instant is for humans, the *comparison* is monotonic.
    //
    // A full VM-snapshot stun is not achievable in a unit harness; these are
    // the clock-domain unit arms, and the reviewer's recommendation stands:
    // "Phase 11's soak rig should measure the two clocks across a real VM
    // snapshot before this is called closed" (09-REVIEW WR-01).
    const deadlineMs = 3000;

    Plant domainPlant() => Plant(
        config: ServerConfig(
            tick: ServerConfig.minTick,
            heartbeatDeadline: const Duration(milliseconds: deadlineMs),
            stallThreshold: const Duration(milliseconds: 300)));

    test('a wall-clock step the monotonic clock never saw does not reap a '
        'beating panel', () async {
      final plant = domainPlant();
      final keys = plant.seed(1, prefix: 'CN15.MOT');
      final wall = FakeClock(start: 1_000_000_000);
      final panel = await plant.connect('page-1', keys,
          now: wall.now, monotonicNow: plant.clock.now);

      // The stun/NTP shape: the wall clock steps forward well past the
      // deadline while the engine's clock advances one ordinary tick. The
      // panel's last frame (subscribe) is monotonically recent; `lag.poll`
      // sees a normal gap, so the verdict is LagOk and nothing is forgiven.
      wall.advance(42_000);
      plant.tick();
      await pumpEventQueue();

      expect(panel.session.sentCloseCode, isNull,
          reason: 'a wall-clock step of 42 s with no monotonic stall reaped a '
              'panel whose last frame is one tick old on the engine\'s clock — '
              'the silence figure crossed clock domains, and the forgiveness '
              'had nothing to credit because lag.poll (correctly, on the '
              'monotonic clock) measured no stall');
      expect(plant.registry.sessions, hasLength(1),
          reason: 'the beating session left the registry, which is a reap by '
              'another name');
    });

    test('a session monotonically silent past the deadline is reaped even '
        'while its wall clock stands still', () async {
      final plant = domainPlant();
      final keys = plant.seed(1, prefix: 'CN16.MOT');
      final wall = FakeClock(start: 1_000_000_000);
      final panel = await plant.connect('page-1', keys,
          now: wall.now, monotonicNow: plant.clock.now);

      // Ordinary near-time ticks — each gap's excess is inside the 300 ms
      // stall threshold, so every verdict is LagOk and nothing is ever
      // forgiven — until the engine's clock has moved a whole deadline past
      // the session's last frame. The wall clock never moves (a backwards
      // NTP step's limiting case): a reaper still reading wall silence would
      // hold this corpse forever, which is the only-dead-sessions property
      // lost from the other side.
      for (var advanced = 0; advanced <= deadlineMs; advanced += 300) {
        plant.tick(advance: 300);
      }
      await pumpEventQueue();

      expect(panel.session.sentCloseCode, CloseCodes.heartbeatTimeout,
          reason: 'a session that sent nothing for a whole deadline on the '
              'engine\'s clock must be reaped regardless of what the wall '
              'clock did — a wall clock standing still (or stepping back) '
              'must not extend a dead panel\'s life');
    });

    test('production wires the engine\'s clock as every session\'s liveness '
        'clock', () {
      final source = File('lib/src/relay_server.dart').readAsStringSync();
      expect(source, contains('monotonicNow: () => _engine!.now()'),
          reason: 'the two arms above prove the decision on injected clocks; '
              'this pin is what says production actually injects the '
              'engine\'s clock into `RelaySession.serve`. Remove the wiring '
              'and the reaper is back to subtracting a monotonic credit from '
              'a wall-clock silence (09-REVIEW WR-01)');
    });
  });

  group('maxRateHz is a promise the server keeps', () {
    // 03-REVIEW WR-07. `maxRateHz` was accepted from clients, stored on
    // SubscriptionState and read by nothing: a panel that asked for 1 Hz got
    // the full tick rate, silently. `grep -rn maxRateHz lib/` found the
    // declaration and the assignment and nothing else.
    test('a rate-limited subscription is pushed less often than the tick',
        () async {
      final plant = Plant(); // 50 ms tick — 20 Hz.
      final keys = plant.seed(1, prefix: 'CN03.FAST');
      final panel = await plant.connect('page-1', keys);
      await plant.ask(
          panel,
          Methods.subscribe,
          SubscribeParams(sub: 'slow', keys: keys, maxRateHz: 5).toJson());
      plant.clearWires();

      var value = 0;
      for (var tick = 0; tick < 8; tick++) {
        plant.api.setValues({keys.single: ++value});
        plant.tick();
      }
      // Four quiet ticks, so the last deferred change has a tick it is due on.
      for (var tick = 0; tick < 4; tick++) {
        plant.tick();
      }

      final fast = panel.updates.where((u) => u.sub == 'page-1').toList();
      final slow = panel.updates.where((u) => u.sub == 'slow').toList();

      expect(fast, hasLength(8),
          reason: 'the unlimited subscription is the control: it is pushed on '
              'every tick that carried a change');
      expect(slow.length, lessThan(fast.length),
          reason: 'a subscription that asked for 5 Hz on a 20 Hz tick must be '
              'pushed less often, or the field is decoration');
      expect(slow, isNotEmpty,
          reason: 'less often is not never — a rate limit that starved the '
              'subscription would be a worse bug than ignoring it');
      expect(slow.last.changes.values.single.v, value,
          reason: 'a skipped tick must defer the change, never drop it: the '
              'buffer has already been drained by the time the rate gate '
              'runs, so a gate that only skipped the emit would leave a panel '
              'holding the previous value forever if that tag never moved '
              'again — under a link that looks perfectly healthy');
    });

    test('a subscription with no rate is pushed on every tick', () async {
      final plant = Plant();
      final keys = plant.seed(1, prefix: 'CN03.PLAIN');
      final panel = await plant.connect('page-1', keys);
      plant.clearWires();

      for (var tick = 0; tick < 5; tick++) {
        plant.api.setValues({keys.single: tick + 1});
        plant.tick();
      }

      expect(panel.updates, hasLength(5),
          reason: 'the gate must be inert for the clients that did not ask '
              'for it, which is every panel today');
    });

    test('a non-positive maxRateHz is refused rather than ignored', () async {
      final plant = Plant();
      final keys = plant.seed(1, prefix: 'CN03.ZERO');
      final panel = await plant.connect('page-1', keys);

      await expectLater(
          plant.ask(panel, Methods.subscribe,
              SubscribeParams(sub: 'zero', keys: keys, maxRateHz: 0).toJson()),
          throwsA(isA<rpc.RpcException>()),
          reason: 'silently ignoring a client-supplied constraint is the one '
              'option that leaves nobody informed; zero pushes per second is '
              'either everything at once or nothing ever and the client could '
              'not tell which it got');
    });
  });

  group('the wire carries epoch ms, not uptime', () {
    // 03-REVIEW CR-04. `UpdateParams.t`, `TickParams.serverTime` and
    // `SubTick.evaluatedAt` are documented as UTC epoch ms and carried uptime
    // ms instead, while `HelloResult.serverTime` and every `WireValue.t` in
    // the same frame carried the real epoch — two clocks fifty-five years
    // apart inside one object. A client computing staleness got a nonsense
    // answer whichever field it trusted.
    test('an emitted tick timestamp is within a band of the wall clock',
        () async {
      final plant = Plant();
      final keys = plant.seed(1, prefix: 'CN01.SCREW');
      final panel = await plant.connect('page-1', keys);
      plant.clearWires();

      plant.api.setValues({keys.single: 3});
      plant.tick();

      final wallNow = DateTime.now().millisecondsSinceEpoch;
      const bandMs = 60_000;
      expect(panel.ticks.single.serverTime,
          closeTo(wallNow, bandMs),
          reason: 'uptime ms would be a few hundred here and epoch ms is '
              '~1.79e12; a band this wide cannot tell a slow runner from a '
              'fast one and cannot possibly pass on the wrong clock');
      expect(panel.ticks.single.subs['page-1']?.evaluatedAt,
          closeTo(wallNow, bandMs),
          reason: 'evaluatedAt is what a panel subtracts from its own clock to '
              'decide a tag has gone stale');
      expect(panel.updates.single.t, closeTo(wallNow, bandMs),
          reason: 'UpdateParams.t supplies the timestamp for values that do '
              'not carry their own, so it must be on the same clock as the '
              'WireValue.t of the ones that do');
    });

    test('a u frame\'s own t agrees with the WireValue.t inside it', () async {
      final fixture = relayFixture();
      await fixture.ready;
      final hello = await fixture.hello();
      const key = 'CN01.MOT01.speed';
      fixture.served.setValue(key, 1);
      await fixture.request(Methods.subscribe,
          params: const SubscribeParams(sub: 'page-1', keys: [key]).toJson());
      fixture.served.setValue(key, 2);

      final frame = await within(
          _frame(fixture, (f) => methodOf(f) == Methods.update),
          'a u frame carrying the changed value',
          budget: ceiling * 10);
      final update = UpdateParams.fromJson(paramsOf(frame));
      final value = update.changes.values.single;

      expect((update.t - hello.serverTime).abs(), lessThan(60_000),
          reason: 'hello.serverTime is the clock the client derives its offset '
              'from, and it always carried genuine epoch ms; a u frame stamped '
              'from a different clock makes that offset a lie');
      expect((update.t - (value.t ?? update.t)).abs(), lessThan(60_000),
          reason: 'WireValue.t comes from the source\'s own sourceTime in '
              'epoch ms (session_handlers.dart:266). Two clocks in one object '
              'is the shape of this bug that no single-field assertion could '
              'have caught');
    }, tags: 'ws');
  });

  group('the wall-clock anchor', () {
    test('a genuinely frozen event loop announces itself', () async {
      final fixture = relayFixture(
          config: ServerConfig(
              tick: ServerConfig.maxTick,
              stallThreshold: const Duration(milliseconds: 300)));
      await fixture.ready;
      await fixture.hello();
      const key = 'CN01.MOT01.speed';
      fixture.served.setValue(key, 1);
      await fixture.request(Methods.subscribe,
          params: const SubscribeParams(sub: 'page-1', keys: [key]).toJson(),
          what: 'the subscribe answer before the freeze');

      // The real thing: the isolate stops turning, exactly as it would under a
      // synchronous parse of a very large payload. 800 ms so the absolute
      // duration (~800) and the excess (~700) are far enough apart that the
      // assertion below can tell them apart on a noisy runner.
      const frozenMs = 800;
      final freeze = Stopwatch()..start();
      while (freeze.elapsedMilliseconds < frozenMs) {
        // Deliberately empty: a `sleep` would be the same thing with a nicer
        // name, and an `await` would not be a freeze at all.
      }

      final frame = await within(
          _frame(fixture, (f) => f.contains('"${Methods.resync}"')),
          'a gateway_stalled announcement after a real ${frozenMs}ms freeze '
              'on $platformName',
          budget: ServerConfig.maxTick + ceiling);
      final announcement = ResyncParams.fromJson(paramsOf(frame));

      expect(announcement.reason, _gatewayStalled,
          reason: 'the simulated cases are only worth anything if the real '
              'freeze produces the same announcement');
      expect(announcement.stalledMs,
          greaterThan(frozenMs - slack.inMilliseconds),
          reason: 'absolute, not excess: at a 100 ms period the excess would '
              'be about ${frozenMs - 100} and the absolute about $frozenMs, '
              'and a panel renders whichever it is given as a sentence about '
              'the plant');
    }, tags: 'ws');
  });
}

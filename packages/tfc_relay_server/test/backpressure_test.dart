/// SRV-04: the send buffer's verdicts, as behaviour a client can see.
///
/// Three arms, and they are deliberately different *kinds* of test:
///
///  * **F12/F19 hard overflow** — integration, over a real socket. The property
///    is not "the buffer returned a `BufferDisconnect`" (the protocol package
///    already owns that) but "a client that blew the ceiling learns why", and
///    only a real close frame carries a 4xxx code and a reason string.
///  * **F20 sustained peak** — a unit test with an injected clock.
///    `ConflatingSendBuffer.poll(nowMs)` takes its timestamp as an argument, so
///    the whole window is arithmetic; asserting it against wall time would be
///    a ten-second sleep that measures the runner (03-RESEARCH Finding 5).
///  * **F21 throttled client** — integration through a [FaultProxy], because
///    the property is about what a *slow link* does to a client, and a slow
///    link is not something a fake can be honest about.
///
/// **Whose close code these arms read.** The client's, always. Finding 6
/// measured a 4004 arriving intact at the far end while the server's own
/// `WebSocketChannel.closeCode` read `null` for the close it had just
/// initiated (`web_socket_channel` #1698) — so on the server side there is
/// nothing to assert, and `RelaySession.sentCloseCode` records an *intention*
/// rather than an observation. `RelayFixture.observedClose` is the evidence.
///
/// **The bite this file is proof against.** `tick_engine.dart` polls the buffer
/// *before* it drains it, and the overflow arm is what fails if that order is
/// ever swapped: `drain()` empties the buffer by contract, so a poll placed
/// after it reads a pending count of zero on every tick and no backpressure
/// verdict can fire again — the slow client then grows the server's heap in
/// silence, which is the exact failure `ConflatingSendBuffer` exists to convert
/// into a visible reconnect.
@Tags(['ws', 'faults'])
library;

import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/server_config.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

import 'support/bands.dart';
import 'support/fake_clock.dart';
import 'support/panels.dart';
import 'support/ws_harness.dart';

/// How long the throttled arm observes the link for.
///
/// Three seconds is the floor Phase 2's throttle leg settled on
/// (`throttle_test.dart:73`) and the reason carries over unchanged: a rate
/// measured over a shorter window is dominated by whatever the first TCP
/// window happened to carry, and this arm is a statement about a *cadence*.
const _throttleWindow = Duration(seconds: 3, milliseconds: 500);

/// The throttle applied to the link — 100 kbit/s, `throttle_test.dart`'s own
/// slow lane. Slow enough to be a real constraint on a loopback socket,
/// generous enough that the conflated frames this arm expects all arrive.
const _hundredKilobit = 12_500;

/// How long the tail of a throttled stream has to land after the writer stops.
const _tailBudget = Duration(seconds: 15);

/// Pumps the event queue until [ready], for a fixture whose tick is driven by
/// hand. Turn-based rather than timed: nothing here waits on wall time.
Future<void> _until(bool Function() ready, String what,
    {int turns = 500}) async {
  for (var turn = 0; turn < turns; turn++) {
    if (ready()) return;
    await pumpEventQueue(times: 1);
  }
  fail('$what did not happen within $turns turns of the event queue');
}

/// A future that completes when [ready] holds, polled on a real delay.
///
/// Only the throttled arm uses it, and only because a throttled socket
/// delivers on wall time. Handed to [within] by its caller, so the wait still
/// has a named budget rather than a bare loop that can hang.
Future<void> _untilTimed(bool Function() ready) async {
  while (!ready()) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Every `u` frame in [frames], decoded.
List<UpdateParams> _updates(List<String> frames) {
  final updates = <UpdateParams>[];
  for (final frame in frames) {
    final decoded = jsonDecode(frame);
    if (decoded is! Map) continue;
    if (decoded['method'] != Methods.update) continue;
    updates.add(UpdateParams.fromJson(
        (decoded['params'] as Map).cast<String, Object?>()));
  }
  return updates;
}

void main() {
  group('F12/F19 — a client that blows the hard ceiling is told so', () {
    test('hard overflow disconnects on the same tick with 4004', () async {
      // A ceiling low enough that ten changed handles clear it, and no soft
      // threshold at all: this arm is about the hard limit, and a peak verdict
      // firing first would pass the case for the wrong reason.
      final fixture = relayFixture(
          config: ServerConfig(
        tick: ServerConfig.maxTick,
        maxPending: 6,
        peakThreshold: null,
      ));
      await fixture.ready;

      // The server's own timer is stopped and the ticks are driven by hand:
      // "the disconnect happened on the tick that saw the overflow" is the
      // property, and a free-running timer decides that at random.
      final engine = fixture.server.engine!;
      await engine.stop();
      final session = fixture.server.sessions.sessions.single;
      final clock = FakeClock(start: 5_000_000);
      void tick() {
        clock.advance(100);
        engine.tickOnce(clock.nowMs);
      }

      final hello = fixture.request(Methods.hello, params: helloParams());
      await _until(() => session.buffer.pendingCount > 0,
          'the hello answer reaching the priority lane');
      tick();
      await within(hello, 'the hello answer over a real socket');

      final keys = [for (var i = 0; i < 10; i++) 'CN01.MOT${i + 1}.speed'];
      for (final key in keys) {
        fixture.served.setValue(key, 0);
      }

      final subscribed = fixture.request(Methods.subscribe,
          params: SubscribeParams(sub: 'page-1', keys: keys).toJson());
      await _until(() => session.buffer.pendingCount > 0,
          'the subscribe answer reaching the priority lane');
      tick();
      await within(subscribed, 'the subscribe answer over a real socket');
      expect(session.buffer.pendingCount, 0,
          reason: 'the drain leaves nothing behind, so the pending count the '
              'overflow tick reads is the plant push below and nothing else');

      // Ten distinct handles in one turn, with no tick in between: conflation
      // bounds pending by *handles*, so this is the only shape that reaches
      // the ceiling — a thousand writes to one key would still be one pending
      // entry, which is the whole point of the design.
      fixture.served.setValues({for (final key in keys) key: 1});
      await _until(() => session.buffer.pendingCount > 6,
          'ten changed handles reaching the telemetry lane');

      final ticksBefore = engine.ticks;
      tick();

      // Synchronously, before a single turn of the event loop has run: the
      // eviction is a decision the tick made, and a session still in the
      // registry is one the *next* tick — or the reaper, or a broadcast — can
      // still select. `close()` is asynchronous by necessity (it awaits the
      // peer), so a removal that waits for it leaves a window in which the
      // server is fanning out to a client it has already given up on.
      expect(fixture.server.sessions.sessionCount, 0,
          reason: 'the evicted session left the registry on the tick that '
              'evicted it, not on whichever later turn its teardown happened '
              'to finish in');

      final close = await fixture.awaitClose(
          'the client observing the overflow close',
          budget: const Duration(seconds: 2));

      expect(close.closeCode, CloseCodes.backpressureOverrun,
          reason: 'the client must be told which ceiling it hit. A bare 1006 '
              'is indistinguishable from a crashed gateway, and a panel that '
              'cannot tell those apart reconnects into the same wall forever');
      expect(close.closeReason, contains('exceeded hard limit'),
          reason: 'the reason string is the verdict\'s own, carried through '
              'unchanged — an operator reading it should learn the pending '
              'count and the limit without reading the server\'s source');
      expect(close.closeReason, contains('6'),
          reason: 'the limit the client actually hit, not a generic sentence');
      expect(engine.ticks, ticksBefore + 1,
          reason: 'the disconnect landed on the tick that saw the overflow, '
              'not a tick later: a client the server has decided to evict must '
              'not be handed one more frame');
      expect(session.sentCloseCode, CloseCodes.backpressureOverrun,
          reason: 'the session records what it sent, from the verdict rather '
              'than from a constant re-typed at the call site');
      await fixture.untilNoSessions();
    });
  });

  group('F20 — a sustained peak is judged by its window, not by an instant', () {
    // Deterministic by construction: `poll(nowMs)` takes the timestamp, so
    // every instant below is arithmetic and the arm has no wall clock in it.
    const window = 10_000;
    const threshold = 2;
    const start = 1_000_000;

    ConflatingSendBuffer overThreshold() {
      final buffer = ConflatingSendBuffer(
        maxPending: 1000,
        peakThreshold: threshold,
        peakWindowMs: window,
      );
      // Three distinct handles: above the soft threshold, nowhere near the
      // hard one, which is the only state the peak policy is about.
      for (var handle = 1; handle <= 3; handle++) {
        buffer.putValue('page-1', handle, WireValue.of(handle));
      }
      return buffer;
    }

    test('sustained peak does not disconnect before the window', () {
      final buffer = overThreshold();
      final clock = FakeClock(start: start);

      expect(buffer.poll(clock.nowMs), isA<BufferOk>(),
          reason: 'the first poll above the threshold opens the window; a '
              'client is not evicted for one busy tick');

      clock.advance(window);
      expect(buffer.poll(clock.nowMs), isA<BufferOk>(),
          reason: 'at exactly $window ms the window has been *reached*, not '
              'exceeded. A grace period that ends one instant early is a '
              'client disconnected for keeping the deal it was offered');
    });

    test('sustained peak disconnects after the window, not before', () {
      final buffer = overThreshold();
      final clock = FakeClock(start: start);

      expect(buffer.poll(clock.nowMs), isA<BufferOk>());

      clock.advance(window + 1);
      final verdict = buffer.poll(clock.nowMs);

      expect(verdict, isA<BufferDisconnect>(),
          reason: 'a client that has been over the soft threshold for longer '
              'than the whole window cannot keep up, and holding its queue '
              'open forever is the slow-loris shape T-03-26 names');
      expect((verdict as BufferDisconnect).closeCode,
          CloseCodes.backpressureOverrun,
          reason: 'the soft ceiling and the hard one are the same failure at '
              'different speeds, and a client should not have to learn two '
              'codes to handle one condition');
      // **Changed in 16-08, and the change is the finding being closed.** This
      // asserted `contains('unable to keep up')` — a sentence about the client
      // attached to a measurement of the server's own production. `poll` reads
      // a count that `drain()` empties every tick, so it can only ever say how
      // much this server produced for one client during one tick; 16-02
      // measured a healthy 1100-key page evicted by it after 10.1 s under
      // exactly that sentence, and a comprehensively stuck panel sitting at 41
      // pending against a threshold of 1024. The verdict still exists and
      // still measures production. It no longer blames the panel for it, and
      // it is no longer the slow-consumer defence — `slow_consumer_test.dart`
      // holds that, and it reads `delivery stalled`.
      expect(verdict.reason, contains('sustained production'),
          reason: 'the reason distinguishes the two arms for whoever reads the '
              'log, even though the code does not — and it names what was '
              'measured rather than who is at fault (T-16-08e)');
      expect(verdict.reason, isNot(contains('keep up')));
    });

    test('a dip below the threshold reopens the grace period', () {
      final buffer = overThreshold();
      final clock = FakeClock(start: start);

      expect(buffer.poll(clock.nowMs), isA<BufferOk>());

      // The client caught up: the drain empties the buffer, and the next poll
      // sees a pending count under the threshold.
      clock.advance(window - 1);
      buffer.drain();
      expect(buffer.poll(clock.nowMs), isA<BufferOk>());

      // Busy again, from zero. The old window must not still be running.
      for (var handle = 1; handle <= 3; handle++) {
        buffer.putValue('page-1', handle, WireValue.of(handle));
      }
      clock.advance(2);
      expect(buffer.poll(clock.nowMs), isA<BufferOk>(),
          reason: 'the window restarts when the client recovers. Carrying the '
              'old one forward would evict a panel that was briefly busy two '
              'shifts ago, which reads to an operator as a random disconnect');
    });
  });

  group('F20 end to end — the soft verdict fires through the engine', () {
    // 03-REVIEW WR-02. The three arms above construct a `ConflatingSendBuffer`
    // by hand and call `poll`/`drain` themselves; they would pass unchanged
    // whether the engine drains every tick or never, which is why the soft
    // verdict could be dead in production while STATE.md recorded it as
    // "pinned in a named test". These two are engine-driven: the buffer is
    // polled and drained by `tickOnce`, on the pacing the server actually
    // uses, so the whole path is what is being asserted.
    ConflatingSendBuffer peaky() => ConflatingSendBuffer(
        maxPending: 1000, peakThreshold: 2, peakWindowMs: 200);

    test('a client held above the soft ceiling every tick is evicted', () async {
      final plant = Plant();
      final keys = plant.seed(5, prefix: 'CN02.LOAD');
      final panel = await plant.connect('page-1', keys, buffer: peaky());

      // Well under maxPending on every tick — this is the soft ceiling's
      // territory and nothing else's — and above the soft one continuously.
      var value = 0;
      for (var tick = 0; tick < 12; tick++) {
        plant.api.setValues({for (final key in keys) key: ++value});
        plant.tick();
      }

      expect(panel.session.sentCloseCode, CloseCodes.backpressureOverrun,
          reason: 'the soft ceiling exists to catch the client the hard one '
              'never will. With drain() clearing the peak window this could '
              'not fire on any tick pacing at all, and the only test of it '
              'called poll() by hand — so nothing in the suite failed whether '
              'the verdict worked or not');
    });

    test('a client under the soft ceiling is never evicted for a long run',
        () async {
      final plant = Plant();
      final keys = plant.seed(1, prefix: 'CN02.QUIET');
      final panel = await plant.connect('page-1', keys, buffer: peaky());

      var value = 0;
      for (var tick = 0; tick < 40; tick++) {
        plant.api.setValues({keys.single: ++value});
        plant.tick();
      }

      expect(panel.session.sentCloseCode, isNull,
          reason: 'one changed handle a tick is a healthy panel on a steady '
              'line, for as long as it likes. A window that accumulated '
              'without a recovery signal would evict every panel eventually, '
              'which is the opposite failure and just as bad');
    });
  });

  group('F21 — a throttled client degrades, and is not evicted', () {
    test('a throttled client keeps receiving the latest value', () async {
      final fixture = relayFixture(withProxy: true);
      await fixture.ready;
      await fixture.hello();

      const key = 'CN01.MOT01.speed';
      fixture.served.setValue(key, 0);
      final handle = fixture.server.handles.handleFor(key);

      await fixture.request(Methods.subscribe,
          params: const SubscribeParams(sub: 'page-1', keys: [key]).toJson(),
          what: 'the subscribe answer over a real socket');

      fixture.proxy.throttleBytesPerSec = _hundredKilobit;

      // A monotonically increasing value, written far faster than the tick.
      // The plant is what is fast here; the client is what is slow. That is
      // the ordinary shape of this failure and the one conflation is for.
      final deadline = DateTime.now().add(_throttleWindow);
      var written = 0;
      while (DateTime.now().isBefore(deadline)) {
        written++;
        fixture.served.setValue(key, written);
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      int? latestSeen() {
        final updates = _updates(fixture.inbound);
        if (updates.isEmpty) return null;
        return updates.last.changes[handle]?.v as int?;
      }

      await within(_untilTimed(() => latestSeen() == written),
          'the final written value reaching a throttled client on '
          '$platformName',
          budget: _tailBudget);

      final updates = _updates(fixture.inbound);
      final values = [
        for (final update in updates)
          if (update.changes[handle]?.v case final int v) v,
      ];

      expect(fixture.server.sessions.sessionCount, 1,
          reason: 'a slow link is a degraded client, not a hostile one. '
              'Evicting it would take a panel off the wall for being on the '
              'far end of a busy switch');
      expect(fixture.observedClose.closeCode, isNull,
          reason: 'the socket is still open; nothing about a throttle is a '
              'backpressure verdict');
      expect(values.last, written,
          reason: 'the stream ends where the plant ended. A client whose last '
              'frame is stale is showing a number the plant has left behind, '
              'which is the failure this project exists to prevent');
      expect(values.length, lessThan(written),
          reason: 'sparse, not replayed: $written writes must not become '
              '$written frames. A queue that ships every intermediate value '
              'to a slow client is a backlog, and a backlog on a plant view '
              'is history rendered as the present');
      expect(values, orderedEquals(List.of(values)..sort()),
          reason: 'conflation reorders nothing — every frame carries a value '
              'at least as new as the one before it');
      expect(values.first, lessThan(values.last),
          reason: 'the arm measured a cadence rather than a single frame');
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}

/// What the gateway is allowed to say about its own event loop.
///
/// 03-RESEARCH Finding 10 measured the drift signature of a `Timer.periodic`
/// on this stack. Idle, the observed lags were `[2, 1, 0, -1, 0]` ms — a ±2 ms
/// noise floor. A 400 ms synchronous stall at a 100 ms period showed up as
/// **exactly one** oversized gap and **no catch-up burst** afterwards: the
/// timer does not fire four times in a row to make up lost ground. Those two
/// measurements are the whole design. The noise floor says any threshold above
/// ~50 ms is outside noise, and the absence of a burst says one stall produces
/// one verdict without any debounce.
///
/// The number the verdict carries is the one thing a reader has to get right,
/// because the two candidates differ by exactly one period and both look
/// plausible in a log. 03-CONTEXT settled it: **absolute**. A 400 ms freeze
/// reports 400, so a panel can tell an operator "the plant view was frozen for
/// 400 ms" — a sentence about the plant, not about our timer configuration.
/// Reporting the 300 ms excess would make the client's message depend on a
/// server tick period it does not know.
///
/// Every case here is arithmetic on injected timestamps. There is no sleep and
/// no timer in this file, so a 400 ms stall costs nothing to test and cannot
/// go flaky on a loaded runner.
library;

import 'package:tfc_relay_server/src/lag_monitor.dart';
import 'package:test/test.dart';

import 'support/bands.dart';
import 'support/fake_clock.dart';

/// The phase's working numbers: a 100 ms tick, and a threshold well clear of
/// Finding 10's ±2 ms noise floor.
const periodMs = 100;
const thresholdMs = 50;

LagMonitor primed(FakeClock clock) {
  final monitor =
      LagMonitor(periodMs: periodMs, thresholdMs: thresholdMs);
  monitor.poll(clock.nowMs);
  return monitor;
}

void main() {
  late FakeClock clock;

  setUp(() => clock = FakeClock(start: 1_000_000));

  group('the noise floor is not a stall', () {
    test('ticks exactly on period never announce', () {
      final monitor = primed(clock);
      for (var i = 0; i < 20; i++) {
        clock.advance(periodMs);
        expect(monitor.poll(clock.nowMs), isA<LagOk>(),
            reason: 'a healthy gateway that announced a freeze would send '
                'every panel into a full resync for nothing');
      }
    });

    test('+/-2 ms jitter never announces', () {
      final monitor = primed(clock);
      // The measured idle sequence from Finding 10, replayed.
      for (final lag in [2, 1, 0, -1, 0, 2, -2]) {
        clock.advance(periodMs + lag);
        expect(monitor.poll(clock.nowMs), isA<LagOk>(),
            reason: 'this is the drift a healthy loop was measured to have; '
                'if it reads as a stall, the alarm means nothing');
      }
    });

    test('the first poll after construction cannot report a stall', () {
      final monitor = LagMonitor(periodMs: periodMs, thresholdMs: thresholdMs);
      clock.advance(30_000);
      expect(monitor.poll(clock.nowMs), isA<LagOk>(),
          reason: 'there is no previous tick for the first one to be late '
              'against; a server that cried stall on its own startup would '
              'resync the plant every restart');
    });
  });

  group('a real freeze', () {
    test('a 400 ms stall reports 400 ms, not 300', () {
      final monitor = primed(clock);
      clock.advance(400);
      final verdict = monitor.poll(clock.nowMs);

      expect(verdict, isA<LagStalled>());
      expect((verdict as LagStalled).stalledMs, 400,
          reason: 'the operator has to be able to read "the plant view was '
              'frozen for 400 ms"; the 300 ms excess is a fact about our tick '
              'period, which no client knows');
    });

    test('one stall is one verdict, with no catch-up burst', () {
      final monitor = primed(clock);
      clock.advance(400);
      expect(monitor.poll(clock.nowMs), isA<LagStalled>());

      for (var i = 0; i < 5; i++) {
        clock.advance(periodMs);
        expect(monitor.poll(clock.nowMs), isA<LagOk>(),
            reason: 'the timer was measured not to fire in a burst after a '
                'stall, so a second announcement would be a phantom freeze '
                'and a second unnecessary resync');
      }
    });

    test('a second freeze later announces again', () {
      final monitor = primed(clock);
      clock.advance(400);
      expect(monitor.poll(clock.nowMs), isA<LagStalled>());
      clock.advance(periodMs);
      expect(monitor.poll(clock.nowMs), isA<LagOk>());
      clock.advance(250);

      final verdict = monitor.poll(clock.nowMs);
      expect(verdict, isA<LagStalled>());
      expect((verdict as LagStalled).stalledMs, 250,
          reason: 'a gateway that only ever reports its first freeze is worse '
              'than one that reports none, because it looks healthy');
    });
  });

  group('the threshold boundary', () {
    test('a gap just under the threshold is ok', () {
      final monitor = primed(clock);
      clock.advance(periodMs + thresholdMs);
      expect(monitor.poll(clock.nowMs), isA<LagOk>(),
          reason: 'the threshold is the point at which lateness becomes worth '
              'a resync; at the threshold exactly it is not yet');
    });

    test('a gap just over the threshold is stalled', () {
      final monitor = primed(clock);
      clock.advance(periodMs + thresholdMs + 1);
      final verdict = monitor.poll(clock.nowMs);

      expect(verdict, isA<LagStalled>());
      expect((verdict as LagStalled).stalledMs, periodMs + thresholdMs + 1,
          reason: 'the reported figure is the wall-clock gap at every '
              'magnitude, not only at large ones');
    });
  });

  group('the fixtures the wall-clock plans in this phase will use', () {
    test('FakeClock advances and only forwards', () {
      final c = FakeClock(start: 5);
      c.advance(10);
      expect(c.now(), 15);
      expect(() => c.advance(-1), throwsArgumentError,
          reason: 'a clock that ran backwards would let a test assert a stall '
              'the real system can never produce');
    });

    test('the platform bands are ordered and named', () {
      expect(slack, lessThan(ceiling),
          reason: 'slack is jitter tolerance and ceiling is a deadline; '
              'inverted, every wall-clock test in the phase is meaningless');
      expect(platformName, isNotEmpty);
    });
  });
}

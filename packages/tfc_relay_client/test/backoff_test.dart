/// The reconnect schedule: exponential, full jitter, hard ceiling.
///
/// Source: 04-PATTERNS "No Analog Found" — nothing in this repo retries
/// anything, and STACK rejected `web_socket_client` outright for an infinite
/// backoff loop. The spec is ~30 lines: exponential growth, full jitter, cap
/// 30 s, and a seedable `Random` so the schedule is a pure transform a test
/// can pin.
///
/// What breaks in the plant without the jitter: the gateway is a single
/// process, so when it restarts every panel in the factory loses its socket in
/// the same second. A schedule without jitter brings all of them back at the
/// same instant, again and again, each wave hitting a server still replaying
/// snapshots for the last one — the thundering herd, self-sustaining. Full
/// jitter (uniform over the whole window, lower bound zero) is what smears the
/// wave out. That is also why the bite-proof case below is not "values stay
/// under the cap" — a constant `min(cap, base * 2^n)` passes that — but
/// "values land below half the ceiling".
library;

import 'dart:math';

import 'package:tfc_relay_client/src/backoff.dart';
import 'package:test/test.dart';

/// A `Random` that always returns the largest value `nextInt` may produce, so
/// a case can read the ceiling the schedule computed rather than a sample
/// from under it.
final class _CeilingRandom implements Random {
  @override
  int nextInt(int max) => max - 1;

  @override
  bool nextBool() => true;

  @override
  double nextDouble() => 1.0;
}

void main() {
  group('the ceiling grows exponentially and then stops', () {
    test('each attempt doubles the window until the cap clamps it', () {
      final backoff = Backoff(
        base: const Duration(milliseconds: 250),
        cap: const Duration(seconds: 30),
        random: _CeilingRandom(),
      );

      final ceilings = [for (var i = 0; i < 10; i++) backoff.next().inMilliseconds];

      expect(ceilings.take(8).toList(), [249, 499, 999, 1999, 3999, 7999, 15999, 29999],
          reason: 'a panel that retries at a flat interval either hammers a '
              'gateway that is still starting up or waits far too long after '
              'a one-second blip');
      expect(ceilings.skip(8), everyElement(29999),
          reason: 'past the cap the window stops growing, so a panel that has '
              'been down all night still comes back within half a minute of '
              'the gateway returning');
    });

    test('the cap clamps a base that would overflow a shift', () {
      final backoff = Backoff(
        base: const Duration(milliseconds: 250),
        cap: const Duration(seconds: 30),
        random: _CeilingRandom(),
      );

      for (var i = 0; i < 200; i++) {
        backoff.next();
      }

      expect(backoff.next().inMilliseconds, 29999,
          reason: 'an attempt counter that keeps shifting eventually wraps to '
              'a negative window, and a negative window is a crash on the one '
              'code path that exists to survive an outage');
    });
  });

  group('full jitter puts values below the ceiling, so a herd does not '
      're-form', () {
    test('200 draws deep in the capped region stay under the cap and spread '
        'across it', () {
      final backoff = Backoff(
        base: const Duration(milliseconds: 250),
        cap: const Duration(seconds: 30),
        random: Random(20260814),
      );

      // Walk out to attempt index 12, where 250 ms * 2^12 is well past the
      // 30 s cap, so every remaining draw is uniform over the full ceiling.
      for (var i = 0; i < 12; i++) {
        backoff.next();
      }

      final samples = [for (var i = 0; i < 200; i++) backoff.next()];

      expect(samples, everyElement(lessThanOrEqualTo(const Duration(seconds: 30))),
          reason: 'a wait past the cap looks like a dead panel to the '
              'operator standing in front of it');
      expect(samples, everyElement(greaterThanOrEqualTo(Duration.zero)),
          reason: 'a negative delay is a timer that fires immediately, which '
              'is the reconnect storm the cap exists to prevent');
      expect(samples.any((d) => d < const Duration(seconds: 15)), isTrue,
          reason: 'this is the case a jitterless schedule fails: without full '
              'jitter every draw sits at the ceiling, every panel in the '
              'factory retries in the same instant, and the herd that took '
              'the gateway down re-forms on every wave');
    });

    test('the first attempt can be much shorter than the base window', () {
      final backoff = Backoff(
        base: const Duration(milliseconds: 250),
        cap: const Duration(seconds: 30),
        random: Random(7),
      );

      final firstDraws = [
        for (var i = 0; i < 50; i++) (Backoff(
          base: const Duration(milliseconds: 250),
          cap: const Duration(seconds: 30),
          random: Random(i),
        )).next()
      ];

      expect(firstDraws,
          everyElement(lessThanOrEqualTo(const Duration(milliseconds: 250))),
          reason: 'the first retry after a blip must be quick, or an operator '
              'watches a blank screen for a fault that already cleared');
      expect(firstDraws.any((d) => d < const Duration(milliseconds: 125)), isTrue,
          reason: 'the lower bound of full jitter is zero, so some panels come '
              'back almost immediately and the rest fill in behind them');
      expect(backoff.next(), lessThanOrEqualTo(const Duration(milliseconds: 250)));
    });
  });

  group('the schedule is reproducible and independent', () {
    test('the same seed replays exactly', () {
      List<Duration> tenFrom(int seed) {
        final backoff = Backoff(
          base: const Duration(milliseconds: 250),
          cap: const Duration(seconds: 30),
          random: Random(seed),
        );
        return [for (var i = 0; i < 10; i++) backoff.next()];
      }

      expect(tenFrom(99), tenFrom(99),
          reason: 'a schedule that cannot be pinned cannot be tested, and an '
              'untested reconnect path is the one that fails during an outage');
    });

    test('two panels seeded differently do not march in step', () {
      List<Duration> tenFrom(int seed) {
        final backoff = Backoff(
          base: const Duration(milliseconds: 250),
          cap: const Duration(seconds: 30),
          random: Random(seed),
        );
        return [for (var i = 0; i < 10; i++) backoff.next()];
      }

      expect(tenFrom(1), isNot(equals(tenFrom(2))),
          reason: 'two panels sharing a sequence is the herd with extra steps');
    });
  });

  group('reset', () {
    test('reset returns the next draw to the attempt-0 window', () {
      final backoff = Backoff(
        base: const Duration(milliseconds: 250),
        cap: const Duration(seconds: 30),
        random: _CeilingRandom(),
      );

      for (var i = 0; i < 6; i++) {
        backoff.next();
      }
      expect(backoff.next().inMilliseconds, 15999,
          reason: 'guard: the schedule really has climbed before reset is '
              'asked to undo it');

      backoff.reset();

      expect(backoff.next().inMilliseconds, 249,
          reason: 'backoff resets on entry to ready, so a link that flaps '
              'once an hour never accumulates its way to a 30 s stall');
    });
  });

  group('construction', () {
    test('a non-positive base is refused', () {
      expect(
        () => Backoff(base: Duration.zero, cap: const Duration(seconds: 30)),
        throwsA(isA<ArgumentError>()),
        reason: 'a zero base is a retry loop with no pause, which is the '
            'panel denying service to its own gateway',
      );
    });

    test('a cap below the base is refused', () {
      expect(
        () => Backoff(
          base: const Duration(seconds: 5),
          cap: const Duration(seconds: 1),
        ),
        throwsA(isA<ArgumentError>()),
        reason: 'a cap under the base makes the schedule a constant from the '
            'first attempt, and a constant is a herd',
      );
    });

    test('the default random still produces a legal schedule', () {
      final backoff = Backoff(
        base: const Duration(milliseconds: 250),
        cap: const Duration(seconds: 30),
      );

      expect(backoff.next(),
          lessThanOrEqualTo(const Duration(milliseconds: 250)),
          reason: 'production constructs this without a seed, so the unseeded '
              'path is the one that actually runs in the plant');
    });
  });
}

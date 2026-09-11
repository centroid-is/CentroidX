import 'dart:async';

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/testing/runner_budget.dart'
    show budgetScale;

/// Polls [probe] until its result satisfies [matcher], and returns that result.
///
/// These tests talk to a real Postgres through a write buffer and a retry
/// queue, so "the insert call returned" is a long way from "the row is
/// queryable". That gap is a millisecond on an idle laptop and can be seconds
/// on a loaded CI runner — which is exactly the shape that produces a test
/// passing here and failing there, one row short, twice a week.
///
/// The failing tests all shared one habit: sleep a fixed 50-200 ms, then
/// assert as if the sleep were a guarantee. It never was; it was a bet on the
/// runner being quick, and the bet is lost often enough to have trained
/// everyone to re-run CI instead of reading it. This waits for the condition
/// instead of guessing at a duration, so the fast path stays fast (it returns
/// on the first successful poll) and the slow path waits as long as it has to.
///
/// On timeout it fails with the **last observed value**, not just "timed out":
/// a flake that has become a real bug should say what it saw.
Future<T> eventually<T>(
  FutureOr<T> Function() probe,
  Object? matcher, {
  Duration timeout = const Duration(seconds: 15),
  Duration interval = const Duration(milliseconds: 50),
  String? reason,
}) async {
  final wrapped = wrapMatcher(matcher);
  // Scaled for a hosted runner, for the reason `check.dart`'s `budgetScale`
  // gives: this is a liveness bound, not a latency measurement, and a
  // 15 s default written on a developer's machine is a bet about someone
  // else's. `side_by_side_test` lost that bet on the macOS agent.
  final deadline = DateTime.now().add(timeout * budgetScale);

  Object? last;
  var everProbed = false;
  Object? lastError;

  while (true) {
    try {
      final value = await probe();
      last = value;
      everProbed = true;
      if (wrapped.matches(value, {})) return value;
    } catch (e) {
      // A probe may legitimately throw while the world is still settling —
      // querying a table the collector has not created yet, for instance.
      // Keep the error for the timeout message rather than failing on the
      // first attempt, but never swallow it silently.
      lastError = e;
    }

    if (!DateTime.now().isBefore(deadline)) {
      final saw = everProbed
          ? 'last value: $last'
          : 'the probe never returned; last error: $lastError';
      fail('Timed out after ${timeout.inSeconds}s waiting for a value matching '
          '$matcher — $saw'
          '${reason == null ? '' : '\n$reason'}');
    }

    await Future<void>.delayed(interval);
  }
}

/// Waits until [probe] returns true. A thin wrapper over [eventually] for the
/// common boolean case, kept so call sites read as a sentence.
Future<void> eventuallyTrue(
  FutureOr<bool> Function() probe, {
  Duration timeout = const Duration(seconds: 15),
  Duration interval = const Duration(milliseconds: 50),
  String? reason,
}) =>
    eventually(probe, isTrue,
        timeout: timeout, interval: interval, reason: reason);

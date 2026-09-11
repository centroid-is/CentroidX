import 'dart:async';

/// Polls [condition] until it holds, instead of sleeping for a guessed
/// duration and hoping.
///
/// A fixed `await Future.delayed(...)` in front of an assertion is a bet that
/// the work finishes inside that window on every machine that will ever run
/// the test. On a loaded CI runner the bet loses: `tfc-dart-test
/// (windows-latest)` went red twice on 2026-09-10 on exactly this shape, once
/// for `registered >= 1` (got 0) and once for `polls >= 3` (got 1). Neither
/// was a real defect — the work simply had not happened yet.
///
/// The timeout is deliberately far longer than any plausible real duration:
/// it exists to turn a hang into a readable failure, not to bound the work.
/// [what] is quoted in that failure so a timeout says which condition never
/// came true rather than just naming a line number.
Future<void> waitUntil(
  bool Function() condition, {
  required String what,
  Duration timeout = const Duration(seconds: 10),
  Duration interval = const Duration(milliseconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException(
        'timed out after ${timeout.inSeconds}s waiting until $what',
        timeout,
      );
    }
    await Future.delayed(interval);
  }
}

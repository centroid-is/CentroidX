/// The meta-assertion: proof that a contract check actually bites.
///
/// A contract suite is only worth what its checks catch. `expectContractViolation`
/// runs one check against a deliberately broken implementation and asserts that
/// the check noticed — and that is three separate assertions, not one, because
/// there are three distinct ways for a check to fail to do its job:
///
/// 1. it **hung** — waited on something that never arrived, so the sabotage
///    costs 30 seconds of CI and reports the wrong thing (see [within]);
/// 2. it **passed** — the sabotage went undetected, which is the check being
///    decorative;
/// 3. it threw something that is not a [TestFailure] — the violation surfaced
///    as a raw `StateError` or `TimeoutException` from deep inside the
///    implementation, so the failure message names a stack frame instead of the
///    property an operator lost.
///
/// The third clause is what makes the sabotage suites diagnostic rather than
/// merely red: it forces every check to report through `expect`/`fail`, so when
/// a real implementation breaks years from now the message says what broke in
/// operator terms.
///
/// Generic over the implementation type on purpose — no `StateManApi` import,
/// so this can be written and tested before the interface exists.
library;

import 'dart:async';

import 'package:test/test.dart';

import 'check.dart';

/// Asserts that [check] detects the violation in the deliberately broken [api].
///
/// Completes normally when the check reports a failure through `expect`/`fail`.
/// Otherwise fails this test with a message saying which of the three ways the
/// check let the sabotage through.
///
/// [budget] bounds the hang case: a check that never settles is reported as a
/// hang rather than left to the test-runner timeout.
Future<void> expectContractViolation<A>(
  Check<A> check,
  A api, {
  Duration budget = const Duration(seconds: 2),
}) async {
  Object? caught;
  final done = Completer<void>();

  // Detached on purpose: whatever the check throws is captured here rather than
  // propagating, so the clauses below can inspect it instead of the failure
  // escaping as this test's result.
  unawaited(Future<void>(() async {
    try {
      await check(api);
    } catch (error) {
      caught = error;
    }
    if (!done.isCompleted) done.complete();
  }));

  // Not `expectLater(done.future.timeout(budget), completes, reason: ...)`:
  // that form does not convert the future's error into a TestFailure — the
  // TimeoutException escapes raw, so the hang case would arrive as the very
  // undiagnosable error the third clause exists to forbid. Catch the deadline
  // here and assert on a plain bool, which does produce a TestFailure carrying
  // the reason.
  var settled = true;
  await done.future.timeout(budget, onTimeout: () {
    settled = false;
  });
  expect(
    settled,
    isTrue,
    reason: 'the contract check hung instead of failing',
  );
  expect(
    caught,
    isNotNull,
    reason: 'the check PASSED a deliberately broken implementation',
  );
  expect(
    caught,
    isA<TestFailure>(),
    reason: 'violation surfaced as ${caught.runtimeType}; checks must report '
        'through expect/fail so the message names the property',
  );
}

/// The shape of a contract check, and the deadline every check must wrap its
/// awaits in.
///
/// Why `within` exists: research reproduced a `BrokenStateMan` that drops a
/// subscription. The check waited on a stream that never emitted, so instead of
/// failing it **hung** — for the full 30-second `package:test` timeout, on
/// every CI run, ending with a message that named the test file rather than the
/// property the implementation had broken. A test-runner timeout is a safety
/// net for a runaway process, not an assertion mechanism.
///
/// Wrapped in `within`, the same sabotage fails in 200 ms saying which property
/// went unobserved. That difference is what makes the sabotage suites in this
/// package diagnostic instead of merely red.
///
/// Deliberately generic over the implementation type: this file must not import
/// `StateManApi`, so it can be written and tested before the interface exists.
library;

import 'dart:async';

import 'package:test/test.dart';

/// A single contract case, run against an implementation `api`.
///
/// Generic so the same helper serves `StateManApi` checks and the meta-tests
/// that prove those checks bite.
typedef Check<A> = Future<void> Function(A api);

/// Multiplies every [within] budget, for runners where the wall clock is not
/// the one these numbers were measured on.
///
/// Every budget in this suite is a **liveness** bound: it exists to turn a hang
/// into a named failure, not to measure latency. `within`'s own doc says so, so
/// stretching it on a slow box costs the suite nothing it claims to provide —
/// what it buys is that a genuinely hung await still fails by name instead of
/// running out the runner's own timeout with no sentence attached.
///
/// It is needed because the Windows CI runner is not this machine. The 200 ms
/// default is generous against a 50 ms measured round trip on a developer's
/// laptop and marginal against a real socket on a loaded Windows agent, where
/// it failed the ws leg of the parity sweep for a first value while the
/// in-memory leg passed — reported as a contract divergence between the two
/// legs, which is the one thing that sweep exists to detect and the one thing
/// that was not happening.
///
/// **A seam rather than a `Platform.isWindows` read here.** `check.dart` is
/// kept free of `dart:io` on purpose — `channel_harness.dart:16` states the
/// constraint and greps for it — so the platform question is answered by the
/// caller, which is already VM-only, and this file stays portable.
///
/// Scaling, not replacing: a call site that passed an explicit budget still has
/// its own number, multiplied by the same factor as everything else, so the
/// relative sizes the suite was written with survive.
double budgetScale = 1;

/// Awaits [f], but fails the test if it has not settled within [budget].
///
/// [what] names the property being waited for, in operator terms — "the first
/// value for a subscribed key", not "the future". It is what the failure
/// message will say.
///
/// Silence becomes a [TestFailure]. A genuine error is passed through
/// unchanged: this helper converts *nothing happening* into a named failure,
/// and leaves everything else alone.
///
/// [budget] is multiplied by [budgetScale] before it is applied.
Future<T> within<T>(
  Future<T> f,
  String what, {
  Duration budget = const Duration(milliseconds: 200),
}) async {
  final allowed = budget * budgetScale;
  try {
    return await f.timeout(allowed);
  } on TimeoutException {
    fail('$what did not happen within ${allowed.inMilliseconds} ms'
        '${budgetScale == 1 ? '' : ' (${budget.inMilliseconds} ms x '
            '$budgetScale for this runner)'}');
  }
}

/// The JSON-RPC 2.0 code for a method the peer has never heard of.
///
/// Spelled out rather than imported so this file stays free of a transport
/// dependency; it is a number fixed by the specification, not by a package.
const int methodNotFoundCode = -32601;

/// Runs [body] and asserts it fails with exactly [methodNotFoundCode].
///
/// **This is how a gap is proven rather than hidden.** A leg driving an
/// implementation that has not grown a whole family of methods yet has three
/// options for the checks that need them, and two of them rot:
///
///  * declare the capability `false` — the cases vanish from the report, and
///    the properties go unjudged over that transport for as long as anybody
///    forgets;
///  * leave them red — the suite never goes green, so nobody can tell a known
///    gap from a fresh regression, and the whole run stops being a signal;
///  * `skip` them — the same as the first, with a reason string.
///
/// This is the fourth: the case runs, and passing means *the gap is exactly
/// what it was claimed to be*. Not "something went wrong" — a peer that has
/// never heard of the method. A gap that starts to close fails here, loudly,
/// on the day the handler lands, which is the day the claim stopped being true
/// and the day the check should start being judged on its merits instead.
///
/// [property] is the check's own sentence, so a failure names the property
/// rather than the plumbing.
Future<void> expectUnreachableMethod(
  String property,
  Future<void> Function() body,
) async {
  Object? failure;
  try {
    await body();
  } catch (error) {
    failure = error;
  }

  if (failure == null) {
    fail('"$property" was declared unreachable over this transport and it '
        'passed. That is good news the gap list has not caught up with: the '
        'handler behind it exists now, so delete this check from the '
        'unreachable set and let it be judged on its merits. Left as it is, a '
        'property that works is permanently excused.');
  }

  expect(_isMethodNotFound(failure), isTrue,
      reason: '"$property" was declared unreachable because the peer has no '
          'handler for the method behind it, which is JSON-RPC '
          '$methodNotFoundCode. It failed for some other reason instead:\n\n'
          '$failure\n\n'
          'That is a different fault, and excusing it under a "not implemented '
          'yet" heading is how a real defect rides along inside a known gap. '
          'Either the method now exists and is broken, or the transport is.');
}

/// Whether [error] is the peer saying it has never heard of the method.
///
/// Two arms, because a check reaches this helper by two different routes.
///
/// The direct one: the transport error propagates out of the check untouched
/// and carries a `code`. Read dynamically on purpose — this package must not
/// depend on a particular RPC client to state a property about error codes, and
/// every implementation of one exposes `code`.
///
/// The indirect one: the check **caught** the transport error itself and failed
/// with its own sentence. Several browse cases do exactly that on purpose —
/// their property is "an unresolvable target degrades to null rather than
/// throwing", so *any* throw is the failure they are built to report, and they
/// report it in operator language with the original error quoted inside. That
/// is right, and it means the only evidence left is the text. Matching
/// [methodNotFoundCode] in it is precise enough to be worth doing: the number
/// is fixed by the JSON-RPC specification, it is not a value any of these
/// checks would otherwise mention, and the alternative is excusing those cases
/// with no evidence at all.
///
/// **On a word boundary, not anywhere in the string** (04-REVIEW IN-03). A
/// bare `contains` excused a check that failed for a completely different
/// reason as long as the digits turned up somewhere in the message — inside a
/// nested `data` echo of the request, inside a larger number, inside a
/// timestamp. An excused failure is worse than a red one: the suite reports
/// the gap it already knew about and the new defect leaves no trace at all.
bool _isMethodNotFound(Object? error) {
  try {
    if ((error as dynamic).code == methodNotFoundCode) return true;
  } catch (_) {
    // No `code` to read; fall through to the text.
  }
  return _codeInText.hasMatch('$error');
}

/// [methodNotFoundCode] as a standalone token: not preceded by a digit, a
/// minus or a dot, and not followed by a digit or a dot. `-32601` matches;
/// `-326013`, `1.32601` and `4-32601` do not.
final RegExp _codeInText =
    RegExp('(?<![-.0-9])${RegExp.escape('$methodNotFoundCode')}(?![.0-9])');

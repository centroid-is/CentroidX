/// The three ways a write implementation lies about what it did to the plant.
///
/// `broken_subscribe.dart` covers implementations that lose values and
/// `broken_freshness.dart` implementations that are wrong about whether a value
/// still means anything. These are worse than either, because they are wrong
/// about something that already happened to machinery. A frozen-fresh page
/// misleads an operator into a decision; a write that lies has already been
/// made, and the lie is about whether to make it again.
///
/// All three have shipped, repeatedly, in real client libraries:
///
///  * a transport that retries on timeout, switched on by default, because for
///    a GET that is obviously right;
///  * a client that maps every non-success onto an exception, because that is
///    what the language's error handling is for;
///  * a UI layer that renders anything that is not a success as a red X,
///    because there was no third state to render.
///
/// Each class replaces exactly one behavior of [FakeStateMan] and inherits the
/// rest, so `test/sabotage_write_test.dart` can assert both halves of a
/// sabotage — the targeted check fails, and an unrelated one still passes. A
/// variant that failed everything would prove nothing about any individual
/// check.
///
/// All three break the same seam, [FakeStateMan.attemptUpstreamWrite], which is
/// the point of there being one: every upstream attempt and every outcome comes
/// through it, so a bug on the write path is reachable by overriding one method
/// rather than by reimplementing the write.
library;

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'fake_state_man.dart';

/// Sends the write again when the first attempt does not come back applied.
///
/// The most important sabotage in this phase, and the reason the attempt
/// counter exists at all. Nothing about this variant is visible from the API
/// surface: the call signature is the same, the result type is the same, the
/// outcome is often *better* than the honest source's, and the only cost is a
/// few hundred milliseconds nobody measures. It is what a well-meaning retry
/// wrapper does, and every HTTP client ships one with sensible defaults.
///
/// On a plant it is a second actuation. The operator pressed start once; the
/// PLC timed out answering the first send, took it anyway, and the library —
/// helpfully, silently, in a layer nobody on the project wrote — sent it
/// again. `CLAUDE.md` states the constraint as "never auto-retried", and this
/// is the class that keeps that sentence enforceable.
///
/// It retries only on a non-applied outcome, which is what makes it realistic:
/// nobody writes a retry for a call that succeeded.
class AutoRetriesWrites extends FakeStateMan {
  AutoRetriesWrites({super.staleAfter});

  @override
  Future<WriteResult> attemptUpstreamWrite(
    String cmd,
    String key,
    Object? value, {
    Object? expected,
  }) async {
    final first =
        await super.attemptUpstreamWrite(cmd, key, value, expected: expected);
    if (first is WriteApplied) return first;
    // "It didn't work, so try once more" — the sentence that turns one
    // operator decision into two commands on the wire.
    return super.attemptUpstreamWrite(cmd, key, value, expected: expected);
  }
}

/// Throws when the outcome is one nobody knows.
///
/// Imitates a client that maps everything that is not a success onto an
/// exception, which is the default shape of almost every RPC library and is
/// correct for almost every other call. Here it destroys the distinction the
/// whole write path is built around: the caller's `catch` block cannot tell
/// "the device refused this" from "the device may have taken this", so it
/// writes one error message for both, and the message it writes is the wrong
/// one exactly when it matters — a write that may already have landed reported
/// as a write that failed.
///
/// What the operator does next is re-send. That is the failure this variant
/// exists to keep catchable.
class ThrowsOnUnknown extends FakeStateMan {
  ThrowsOnUnknown({super.staleAfter});

  @override
  Future<WriteResult> attemptUpstreamWrite(
    String cmd,
    String key,
    Object? value, {
    Object? expected,
  }) async {
    final result =
        await super.attemptUpstreamWrite(cmd, key, value, expected: expected);
    if (result is WriteUnknown) {
      throw StateError('write to $key failed: no response from device');
    }
    return result;
  }
}

/// Reports an outcome nobody knows as a refusal.
///
/// The same lie as [ThrowsOnUnknown] told politely. Nothing throws, the sealed
/// type is used, every switch is exhaustive, and the arm that runs is the wrong
/// one. It is the more likely of the two to survive review, because the code
/// reads as careful: it maps a failure onto the failure state.
///
/// "Rejected" tells the operator the device said no, which means the write did
/// not happen, which means trying again is safe. None of that is known. The
/// reason travels through intact, so even the diagnostic text looks right —
/// `plc_timeout`, reported as a refusal, is a sentence that will convince
/// somebody.
class CollapsesUnknownToRejected extends FakeStateMan {
  CollapsesUnknownToRejected({super.staleAfter});

  @override
  Future<WriteResult> attemptUpstreamWrite(
    String cmd,
    String key,
    Object? value, {
    Object? expected,
  }) async {
    final result =
        await super.attemptUpstreamWrite(cmd, key, value, expected: expected);
    if (result is WriteUnknown) {
      return WriteRejected(result.cmd, result.reason,
          at: DateTime.now().millisecondsSinceEpoch);
    }
    return result;
  }
}

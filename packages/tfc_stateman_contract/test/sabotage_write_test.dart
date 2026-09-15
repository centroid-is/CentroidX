/// Proof that the write checks bite.
///
/// Every case here runs a real contract check against an implementation that
/// is wrong in one specific way, and asserts the check noticed —
/// [expectContractViolation] holding it to all three clauses: it must not
/// hang, it must not pass, and it must report through `expect`/`fail` so the
/// message names the property an operator lost rather than a stack frame.
///
/// This is the file the phase's write-safety claim rests on. Nothing in the
/// current codebase distinguishes a write that may have landed from one that
/// did not — `StateMan.write` returns `Future<void>` and throws — so every
/// case in `write_contract.dart` was written from the design document against
/// behavior that does not exist yet. Until these pass, "the suite would catch
/// an implementation that re-sends an operator's write" is an untested claim
/// about untested code.
///
/// The surgical cases matter as much as the violation cases. A variant that
/// failed every check would prove nothing about any individual one; asserting
/// that each variant still passes a check it does not violate is what pins the
/// failure to the property under test.
@Tags(['meta'])
library;

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/testing/broken_write.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

void main() {
  group('a source that re-sends a write for the operator (CLAUDE.md: writes '
      'are never auto-retried)', () {
    test('is caught by the one-attempt-per-cmd check', () async {
      // The sabotage RESEARCH Risk 6 exists for. A retry is invisible from the
      // API surface — same call, same result type, slightly later — so without
      // the attempt counter this variant passes every other check in the file
      // while actuating the plant twice.
      final api = AutoRetriesWrites();
      addTearDown(api.dispose);
      await expectContractViolation(checkExactlyOneUpstreamAttemptPerCmd, api);
    });

    test('names the operator consequence, not a counter', () async {
      final api = AutoRetriesWrites();
      addTearDown(api.dispose);

      Object? caught;
      try {
        await checkExactlyOneUpstreamAttemptPerCmd(api);
      } catch (error) {
        caught = error;
      }

      expect(caught, isA<TestFailure>(),
          reason: 'a duplicated write must surface as a reportable failure, '
              'not as a raw error from inside the implementation');
      expect((caught as TestFailure).message,
          contains('actuates the machine a second time'),
          reason: 'the message must say what the extra attempt means, so an '
              'engineer reading CI in 2027 learns that a machine had decided '
              'to re-actuate on an operator\'s behalf — "expected 1, got 2" '
              'reads like an off-by-one and gets the assertion relaxed');
    });

    test('still reads a value back on an ordinary write — the sabotage is '
        'surgical', () async {
      // It retries what did not come back applied. A write that succeeds first
      // time is untouched, so if this ever fails the variant has stopped
      // demonstrating one bug.
      final api = AutoRetriesWrites();
      addTearDown(api.dispose);
      await checkAppliedCarriesReadback(api);
    });
  });

  group('a client that treats an exception as a failed write', () {
    test('is caught by the lost-link check', () async {
      final api = ThrowsOnUnknown();
      addTearDown(api.dispose);
      await expectContractViolation(
          checkLostLinkYieldsUnknownNeverFailure, api);
    });

    test('fails by name rather than as a raw error out of the implementation',
        () async {
      // The third clause of the meta-assertion, stated explicitly because this
      // is the variant that tests it: the violation arrives as a StateError
      // from inside the source, and the check has to convert it through
      // expect/fail or CI reports a stack frame instead of the promise.
      final api = ThrowsOnUnknown();
      addTearDown(api.dispose);

      Object? caught;
      try {
        await checkLostLinkYieldsUnknownNeverFailure(api);
      } catch (error) {
        caught = error;
      }

      expect(caught, isA<TestFailure>(),
          reason: 'a write that threw its outcome must surface as a '
              'reportable failure; a raw StateError names a line in the '
              'implementation, which is the one thing the person reading CI '
              'already has');
      expect((caught as TestFailure).message, contains('re-sends it'),
          reason: 'the message must name the consequence — an operator told a '
              'write failed re-sends it — rather than the exception type');
    });

    test('still refuses honestly when the device says no — the sabotage is '
        'surgical', () async {
      // It throws only where the honest answer is "nobody knows". A refusal is
      // a known outcome and must still come back as one.
      final api = ThrowsOnUnknown();
      addTearDown(api.dispose);
      await checkRejectedCarriesReasonAndDoesNotThrow(api);
    });
  });

  group('a source that reports an outcome nobody knows as a refusal', () {
    test('is caught by the distinguishability check', () async {
      // The polite version of the same lie: nothing throws, the sealed type is
      // used, the reason travels through intact, and the arm that runs is the
      // wrong one. "Rejected" tells the operator the write did not happen,
      // which is exactly what nobody knows.
      final api = CollapsesUnknownToRejected();
      addTearDown(api.dispose);
      await expectContractViolation(checkUnknownIsDistinctFromRejected, api);
    });

    test('still refuses honestly when the device really did say no — the '
        'sabotage is surgical', () async {
      final api = CollapsesUnknownToRejected();
      addTearDown(api.dispose);
      await checkRejectedCarriesReasonAndDoesNotThrow(api);
    });

    test('still attempts each write exactly once — the sabotage is surgical',
        () async {
      // It lies about the outcome, not about how many times it tried. Keeping
      // these two failures in separate variants is what lets a future CI run
      // say which of them regressed.
      final api = CollapsesUnknownToRejected();
      addTearDown(api.dispose);
      await checkExactlyOneUpstreamAttemptPerCmd(api);
    });
  });
}

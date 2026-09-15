/// Proof that the subscribe and store checks bite.
///
/// Every case here runs a real contract check against an implementation that is
/// wrong in one specific way, and asserts the check noticed —
/// [expectContractViolation] holding it to all three clauses: it must not hang,
/// it must not pass, and it must report through `expect`/`fail` so the message
/// names the property an operator lost rather than a stack frame.
///
/// The surgical cases matter as much as the violation cases. A variant that
/// failed every check would prove nothing about any individual one; asserting
/// that each variant still passes a check it does not violate is what pins the
/// failure to the property under test.
@Tags(['meta'])
library;

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/testing/broken_subscribe.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

void main() {
  group('a subscription that dies while the link stays up', () {
    test('is caught by the subsequent-changes check', () async {
      final api = DropsSubscriptions();
      addTearDown(api.dispose);
      await expectContractViolation(checkListenDeliversSubsequentChanges, api);
    });

    test('fails by name and inside its budget, rather than hanging', () async {
      // The whole reason `within` exists. Without it this sabotage waits on a
      // notification that never comes until the runner's 30-second timeout,
      // and reports the name of a test file instead of the promise that was
      // broken.
      final api = DropsSubscriptions();
      addTearDown(api.dispose);

      final elapsed = Stopwatch()..start();
      Object? caught;
      try {
        await checkListenDeliversSubsequentChanges(api);
      } catch (error) {
        caught = error;
      }
      elapsed.stop();

      expect(caught, isA<TestFailure>(),
          reason: 'a dropped subscription must surface as a reportable '
              'failure, not as a raw error from inside the implementation');
      expect((caught as TestFailure).message, contains('changed upstream'),
          reason: 'the message must name the property, so an engineer reading '
              'CI in 2027 learns what operators stopped seeing');
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 1)),
          reason: 'silence must cost 200 ms, not a runner timeout on every '
              'CI run');
    });

    test('still delivers the first value — the sabotage is surgical', () async {
      final api = DropsSubscriptions();
      addTearDown(api.dispose);
      await checkListenDeliversCurrentValue(api);
    });
  });

  group('a store whose equality guard never fires', () {
    test('is caught by the unchanged-value check', () async {
      final api = NotifiesOnUnchanged();
      addTearDown(api.dispose);
      await expectContractViolation(checkUnchangedValueNotifiesNobody, api);
    });

    test('still delivers real changes — the sabotage is surgical', () async {
      // It notifies too often, never too rarely, so the check about being
      // notified at all must still pass. If this ever fails, the variant has
      // stopped being a demonstration of one bug.
      final api = NotifiesOnUnchanged();
      addTearDown(api.dispose);
      await checkListenDeliversSubsequentChanges(api);
    });
  });

  group('the meta-assertion itself', () {
    test('reports a check that never fails, so an honest implementation '
        'cannot be mistaken for a caught violation', () async {
      final honest = FakeStateMan();
      addTearDown(honest.dispose);

      var reported = false;
      try {
        await expectContractViolation(
            checkListenDeliversSubsequentChanges, honest);
      } on TestFailure catch (failure) {
        reported = true;
        expect(failure.message,
            contains('PASSED a deliberately broken implementation'),
            reason: 'the meta-helper must say which of its three clauses the '
                'check fell foul of');
      }

      expect(reported, isTrue,
          reason: 'expectContractViolation accepted a check that caught '
              'nothing; every sabotage case in this file would then be '
              'vacuously green and the suite would have no teeth at all');
    });
  });
}

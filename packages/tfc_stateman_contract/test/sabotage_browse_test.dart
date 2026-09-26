/// Proof that the browse and preference checks bite.
///
/// Every case here runs a real contract check against an implementation that is
/// wrong in one specific way, and asserts the check noticed —
/// [expectContractViolation] holding it to all three clauses: it must not hang,
/// it must not pass, and it must report through `expect`/`fail` so the message
/// names the property that was lost rather than a stack frame.
///
/// These two variants are quieter than the write ones and that is why they
/// matter. Nothing here throws, nothing loses a value, nothing shows a wrong
/// number. One returns a pre-selection pointing at the parent of the bound tag;
/// the other stores every preference perfectly and never says so. Both are the
/// kind of bug that ships, and neither is visible from any check that only
/// exercises the happy path — which is exactly the shape of thing a contract
/// suite is for.
///
/// The surgical cases matter as much as the violation cases. A variant that
/// failed every check would prove nothing about any individual one; asserting
/// that each still passes a check it does not violate is what pins the failure
/// to the property under test.
///
/// One case here also measures. The silent change stream is the T-09-05
/// scenario — a check waiting on something that never arrives — and the
/// difference between `within`'s deadline and the runner's timeout is the
/// difference between a named failure in a fifth of a second and a file name
/// after thirty. The observed duration is printed rather than merely bounded,
/// so the number stays visible in CI instead of living in a summary nobody
/// reads twice.
@Tags(['meta'])
library;

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/testing/broken_browse.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

void main() {
  group('a browse source that resolves a binding to its parent (T-09-01)', () {
    test('is caught by the root-to-leaf check', () async {
      // The chain it returns is still a real path through the tree: ordered
      // root-first, expandable at every step, every entry the parent of the
      // next. Only the last node is missing, which is why the check has to
      // assert the target explicitly instead of trusting the list to be a path.
      final api = ChainMissesTheTarget();
      addTearDown(api.dispose);
      await expectContractViolation(checkResolvePathReturnsRootToLeafChain, api);
    });

    test('names what the engineer does next, not the list length', () async {
      final api = ChainMissesTheTarget();
      addTearDown(api.dispose);

      Object? caught;
      try {
        await checkResolvePathReturnsRootToLeafChain(api);
      } catch (error) {
        caught = error;
      }

      expect(caught, isA<TestFailure>(),
          reason: 'a wrong pre-selection must surface as a reportable failure, '
              'not as a raw error from inside the implementation');
      expect((caught as TestFailure).message, contains('binds without checking'),
          reason: 'the message must say what a wrong pre-selection costs — an '
              'engineer binding a highlighted node that looks deliberate — '
              'because "expected 4 entries, got 3" reads like an off-by-one in '
              'the test and gets the assertion relaxed');
    });

    test('still degrades a stale binding to null — the sabotage is surgical',
        () async {
      // It truncates a chain it found; it does not invent one it did not. A
      // renamed tag still resolves to null, which is what makes this bug
      // survive review: the error handling around it looks correct because it
      // is correct.
      final api = ChainMissesTheTarget();
      addTearDown(api.dispose);
      await checkResolvePathReturnsNullForUnknownTarget(api);
    });

    test('still expands a folder into its own children — the sabotage is '
        'surgical', () async {
      final api = ChainMissesTheTarget();
      addTearDown(api.dispose);
      await checkFetchChildrenReturnsChildrenOfTheParent(api);
    });
  });

  group('a preferences backend whose change stream was never wired (DB-03)',
      () {
    test('is caught by the second-listener check', () async {
      final api = PrefsChangeNeverNotifies();
      addTearDown(api.dispose);
      await expectContractViolation(
          checkPreferenceChangeNotifiesASecondListener, api);
    });

    test('fails fast by name instead of hanging to the runner timeout '
        '(T-09-05)', () async {
      // The case `within` exists for, stated explicitly because this is the
      // variant that demonstrates it. The stream is open and silent, so there
      // is no error to catch and nothing to wait for: without a deadline the
      // check waits out the runner's 30-second timeout on every CI run and
      // then reports a file name. With one it fails in a fifth of a second and
      // says which promise went unobserved.
      final api = PrefsChangeNeverNotifies();
      addTearDown(api.dispose);

      final elapsed = Stopwatch()..start();
      Object? caught;
      try {
        await checkPreferenceChangeNotifiesASecondListener(api);
      } catch (error) {
        caught = error;
      }
      elapsed.stop();

      // Recorded, not merely bounded: the number is the mitigation, so it
      // belongs in the run output where a regression is visible as a change in
      // it rather than as a slower suite nobody attributes to this.
      print('T-09-05: a silent change stream failed in '
          '${elapsed.elapsedMilliseconds} ms '
          '(runner timeout would be 30000 ms)');

      expect(caught, isA<TestFailure>(),
          reason: 'silence must become a named failure; a raw TimeoutException '
              'names a line in the helper, which is the one thing the person '
              'reading CI already has');
      expect((caught as TestFailure).message, contains('did not happen within'),
          reason: 'the failure must say that the thing waited for never '
              'happened, and name it — "a second listener hearing the same '
              'change" is the property, and it is what tells a reader this is '
              'DB-03 rather than a flaky test');
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 2)),
          reason: 'the silent stream took ${elapsed.elapsedMilliseconds} ms to '
              'fail. The deadline is what keeps a dead stream cheap; a check '
              'that drifts towards the runner timeout is one that will '
              'eventually be reported as a hang and disabled');
    });

    test('still stores and reads back every typed preference — the sabotage is '
        'surgical', () async {
      // It applies every write honestly and only withholds the news. That is
      // what makes it shippable: the page that sets a preference reads its own
      // value back immediately and concludes the notification works.
      final api = PrefsChangeNeverNotifies();
      addTearDown(api.dispose);
      await checkPreferenceSetGetRoundTrips(api);
    });

    test('still browses honestly — the sabotage is surgical', () async {
      final api = PrefsChangeNeverNotifies();
      addTearDown(api.dispose);
      await checkResolvePathReturnsRootToLeafChain(api);
    });
  });
}

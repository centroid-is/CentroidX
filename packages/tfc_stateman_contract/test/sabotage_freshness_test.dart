/// Proof that the freshness checks bite.
///
/// Every case here runs a real contract check against an implementation that is
/// wrong in one specific way, and asserts the check noticed —
/// [expectContractViolation] holding it to all three clauses: it must not hang,
/// it must not pass, and it must report through `expect`/`fail` so the message
/// names the property an operator lost rather than a stack frame.
///
/// This file carries more weight than its subscribe counterpart. The subscribe
/// cases were written against behavior that exists in the codebase today; the
/// freshness cases were written from a design document, because nothing in the
/// current code carries a quality or a timestamp on a value at all. Until these
/// pass, "the suite would catch a frozen-fresh page" is an assertion about
/// untested code that has never been tested.
///
/// The surgical cases matter as much as the violation cases. A variant that
/// failed every check would prove nothing about any individual one; asserting
/// that each variant still passes a check it does not violate is what pins the
/// failure to the property under test.
@Tags(['meta'])
library;

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/testing/broken_freshness.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

/// Short enough to keep the file fast where a case has to wait out a real
/// deadline. Used only where the sabotage is about *aging*; the link cases are
/// event-driven and left on the fake's default, so a sweep can never fire
/// inside the window they are measuring.
const _shortDeadline = Duration(milliseconds: 100);

void main() {
  group('a source that never ages a value (roadmap criterion 4: a broken fake '
      'that returns a stale read must make the suite fail)', () {
    test('is caught by the past-the-deadline check', () async {
      final api = ServesStaleReads(staleAfter: _shortDeadline);
      addTearDown(api.dispose);
      await expectContractViolation(checkValuePastDeadlineBecomesBadStale, api);
    });

    test('fails by name and inside its budget, rather than hanging', () async {
      // A frozen-fresh source produces no event at all, so without `within`
      // this case waits on a notification that never comes until the runner's
      // 30-second timeout — and then reports the name of a test file instead
      // of the promise that was broken.
      final api = ServesStaleReads(staleAfter: _shortDeadline);
      addTearDown(api.dispose);

      final elapsed = Stopwatch()..start();
      Object? caught;
      try {
        await checkValuePastDeadlineBecomesBadStale(api);
      } catch (error) {
        caught = error;
      }
      elapsed.stop();

      expect(caught, isA<TestFailure>(),
          reason: 'a value that never goes stale must surface as a reportable '
              'failure, not as a raw error from inside the implementation');
      expect((caught as TestFailure).message, contains('freshness deadline'),
          reason: 'the message must name the property, so an engineer reading '
              'CI in 2027 learns that operators would have been reading a '
              'number nobody had confirmed');
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 1)),
          reason: 'a source that never ages a value must be caught in a small '
              'multiple of its own deadline, not at a runner timeout on every '
              'CI run');
    });

    test('still degrades on a link loss — the sabotage is surgical', () async {
      // It has forgotten how to age a value, not how to notice a dead link.
      // If this ever fails, the variant has stopped demonstrating one bug.
      final api = ServesStaleReads(staleAfter: _shortDeadline);
      addTearDown(api.dispose);
      await checkUpstreamLossDegradesAffectedKeys(api);
    });
  });

  group('a source that treats no news as good news', () {
    test('is caught by the upstream-loss check', () async {
      final api = LiesAboutQuality();
      addTearDown(api.dispose);
      await expectContractViolation(
          checkUpstreamLossDegradesAffectedKeys, api);
    });

    test('still ages a value — the sabotage is surgical', () async {
      final api = LiesAboutQuality();
      addTearDown(api.dispose);
      await checkValuePastDeadlineBecomesBadStale(api);
    });

    test('still reports its own health honestly, which is what makes it '
        'dangerous', () async {
      // The variant updates PIPE.connected correctly and lies only about the
      // values. The one indicator that is right is on the page nobody has
      // open; every number in front of the operator still claims to be live.
      final api = LiesAboutQuality();
      addTearDown(api.dispose);
      await checkHealthKeysAreSubscribableLikeAnyTag(api);
    });
  });

  group('a source that fans its status out per key', () {
    test('is caught by the announce-once check', () async {
      final api = AnnouncesPerKey();
      addTearDown(api.dispose);
      await expectContractViolation(checkUpstreamLossAnnouncesOnce, api);
    });

    test('still degrades every affected key — the sabotage is surgical',
        () async {
      // It says the right thing far too many times. The check about the values
      // themselves must still pass, or the variant is demonstrating two bugs.
      final api = AnnouncesPerKey();
      addTearDown(api.dispose);
      await checkUpstreamLossDegradesAffectedKeys(api);
    });
  });
}

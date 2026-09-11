/// Proof that the hold-to-run checks bite.
///
/// Every case here runs a real contract check against an implementation that
/// is wrong in one specific way, and asserts the check noticed —
/// [expectContractViolation] holding it to all three clauses: it must not
/// hang, it must not pass, and it must report through `expect`/`fail` so the
/// message names the property an operator lost rather than a stack frame.
///
/// This file is where WRT-04 stops being a claim. A deadman is the one control
/// on a plant whose failure mode is *nothing happening* — a counter that keeps
/// advancing looks exactly like a counter that is being fed, and a hold that
/// never stops looks exactly like an operator with their finger down. Five
/// checks that all passed a source which quietly kept a machine running would
/// be five checks nobody could tell from coverage.
///
/// The surgical cases matter as much as the violation cases. A variant that
/// failed every check would prove nothing about any individual one; asserting
/// that each variant still passes a named neighbour is what pins the failure to
/// the property under test. Two of the five are *broad* by construction —
/// break the feed and every case that ticks as an anti-vacuity arm goes with
/// it — and each of those says so at its own case, with the neighbour it does
/// still pass named.
@Tags(['meta'])
library;

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/testing/broken_hold.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

void main() {
  group('a source that lights the button on the local click', () {
    test('is caught by the engage check', () async {
      // The shipped version of this bug is a UI that treats the press as the
      // event: the handle says applied, the operator sees a live hold, and the
      // engage never reached the plant. Every tick after that is a panel
      // feeding a deadman for a hold no device ever agreed to.
      final api = EngagesWithoutActuating();
      addTearDown(api.dispose);
      await expectContractViolation(
          checkEngageIsThreeStateAndARefusalHoldsNothing, api);
    });

    test('still refuses to advance an unfed counter — the sabotage is '
        'surgical', () async {
      // It lies about the engage, not about the feed: a tick still reaches the
      // plant and nothing advances the counter on its own. If this ever fails,
      // the variant has stopped demonstrating one bug.
      final api = EngagesWithoutActuating();
      addTearDown(api.dispose);
      await checkOnlyATickAdvancesTheCounter(api);
    });
  });

  group('a transport that drops every tick and reports nothing', () {
    test('is caught by the counter-advances check', () async {
      // The nastiest of the five on a plant: the machine simply refuses to
      // jog, the operator holds harder, and nothing anywhere says why.
      final api = NeverAdvancesTheCounter();
      addTearDown(api.dispose);
      await expectContractViolation(
          checkTheCounterAdvancesWhileTheHoldIsFed, api);
    });

    test('still engages and still refuses honestly — the sabotage is '
        'surgical', () async {
      // Broad by construction: every other hold case ticks once as its
      // anti-vacuity arm, so all of them go red against a source with no feed
      // at all. The engage check is the one that does not, and it passing is
      // what pins this variant's failure to the feed rather than to the source
      // being broken in general.
      final api = NeverAdvancesTheCounter();
      addTearDown(api.dispose);
      await checkEngageIsThreeStateAndARefusalHoldsNothing(api);
    });
  });

  group('a controller whose cancellation is asynchronous', () {
    test('is caught by the release check', () async {
      // The one that keeps a machine moving after the finger came off: the
      // release lands, the zero reaches the tag, and the timer nobody
      // cancelled in time fires once more behind it.
      final api = KeepsFeedingAfterRelease();
      addTearDown(api.dispose);
      await expectContractViolation(checkReleasingStopsTheCounter, api);
    });

    test('names the machine, not the counter value', () async {
      final api = KeepsFeedingAfterRelease();
      addTearDown(api.dispose);

      Object? caught;
      try {
        await checkReleasingStopsTheCounter(api);
      } catch (error) {
        caught = error;
      }

      expect(caught, isA<TestFailure>(),
          reason: 'a counter that keeps advancing after the operator let go '
              'must surface as a reportable failure, not as a raw error from '
              'inside the implementation');
      expect((caught as TestFailure).message,
          contains('still being told somebody is holding it'),
          reason: 'the message must say what the extra tick means — a machine '
              'still moving with nobody holding the button — because '
              '"expected 0, got 3" reads like an off-by-one and gets the '
              'assertion relaxed by whoever is trying to get CI green');
    });

    test('still advances the counter while the hold is fed — the sabotage is '
        'surgical', () async {
      // It is wrong about the release only. A hold nobody released is fed
      // exactly as it should be, which is why this failure is about
      // cancellation and not about the pump.
      final api = KeepsFeedingAfterRelease();
      addTearDown(api.dispose);
      await checkTheCounterAdvancesWhileTheHoldIsFed(api);
    });
  });

  group('a source that keeps the deadman fed by itself', () {
    test('is caught by the unfed-hold check', () async {
      // The sabotage assumption A5 exists for. A source that helpfully feeds
      // the counter on a timer of its own passes every case that asserts
      // something happens, and leaves a machine running unattended.
      final api = FeedsTheCounterOnATimer();
      addTearDown(api.dispose);
      await expectContractViolation(checkOnlyATickAdvancesTheCounter, api);
    });

    test('still engages and still refuses honestly — the sabotage is '
        'surgical', () async {
      // The engage is untouched and the pump only exists behind a hold that
      // took, so a refused engage is as inert here as anywhere.
      final api = FeedsTheCounterOnATimer();
      addTearDown(api.dispose);
      await checkEngageIsThreeStateAndARefusalHoldsNothing(api);
    });
  });

  group('a source that feeds a hold the device refused', () {
    test('is caught by the engage check', () async {
      // 05-REVIEW WR-04. Nothing else in this file covers "a refused engage is
      // still feedable": the engage check's last assertion was the only thing
      // standing between that bug and a green suite, and it was written as
      // `isNot(1)` while a leaked tick puts 2 on the tag — so it passed in
      // exactly the scenario its own reason described.
      final api = FeedsAHoldTheDeviceRefused();
      addTearDown(api.dispose);
      await expectContractViolation(
          checkEngageIsThreeStateAndARefusalHoldsNothing, api);
    });

    test('names the machine, not the counter value', () async {
      final api = FeedsAHoldTheDeviceRefused();
      addTearDown(api.dispose);

      Object? caught;
      try {
        await checkEngageIsThreeStateAndARefusalHoldsNothing(api);
      } catch (error) {
        caught = error;
      }

      expect(caught, isA<TestFailure>());
      expect((caught as TestFailure).message,
          contains('a hold that does not exist'),
          reason: 'the message has to say what a moved counter means here — a '
              'deadman being fed for a hold the device refused — because '
              '"expected 0, got 2" reads like an off-by-one and gets the '
              'assertion relaxed by whoever is trying to get CI green. Which '
              'is how it became `isNot(1)`');
    });

    test('still advances the counter while a real hold is fed — the sabotage '
        'is surgical', () async {
      // It acts only when the engage was refused. A hold the device took is
      // fed and released exactly as it should be, which is what pins this
      // failure to the refusal path rather than to the feed.
      final api = FeedsAHoldTheDeviceRefused();
      addTearDown(api.dispose);
      await checkTheCounterAdvancesWhileTheHoldIsFed(api);
    });
  });

  group('a source that hands out holds it does not track', () {
    test('is caught by the dispose check', () async {
      // The page closed and the counter kept going. A registry that is never
      // written to is the commonest way this happens, and it is invisible
      // until the one moment it matters.
      final api = LeavesHoldsRunningOnDispose();
      addTearDown(api.dispose);
      await expectContractViolation(checkDisposingTheSourceReleasesTheHold, api);
    });

    test('still stops the counter when the operator lets go — the sabotage is '
        'surgical', () async {
      // Releasing by hand works perfectly; it is only the teardown that has
      // nothing to release. Keeping those two failures in separate variants is
      // what lets a future CI run say which of them regressed.
      final api = LeavesHoldsRunningOnDispose();
      addTearDown(api.dispose);
      await checkReleasingStopsTheCounter(api);
    });
  });
}

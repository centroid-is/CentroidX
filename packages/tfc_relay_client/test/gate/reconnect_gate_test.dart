/// F1 and F8: a clean drop, and the value that changed while the link was down.
///
/// **F1 — Clean drop, single reconnect.** `killOnce()`. The catalogue asks for
/// a client that reconnects with backoff;
/// full resync (rule 2); banner shown and cleared.
///
/// **F8 — Value changes during outage.** Drop, change key server-side,
/// reconnect. The catalogue asks that resync delivers the new value (rule 2) —
/// the silent-permanent-staleness case; assert the *changed-while-down* key,
/// not just any key.
///
/// **Two arms.** `F1a/F8` is the recovery itself: the value that changed while
/// the link was down comes back. `F1b` is the clause `F1a` leaves open — "banner
/// shown and cleared" is a statement about *order*, and a case that only checks
/// the end state cannot tell a panel that raised the banner and lowered it from
/// one that never raised it at all. `F1b` records every `LinkState` the client
/// publishes and asserts down-then-resyncing-then-ready as a **subsequence**: a
/// redial that takes two attempts is the backoff working, and
/// `reconnect_test.dart:305` already owns the exact-sequence property against an
/// in-memory peer where the attempt count is not at the mercy of a real socket.
///
/// The two rows share `F1a` because they are one fault seen from two sides,
/// and the F8 clause is what stops the F1 clause being vacuous: a client that
/// reconnected, resynced and re-delivered the value it already had would
/// satisfy "full resync" on the report and leave an operator looking at a
/// setpoint the plant no longer holds. The case therefore changes the key while
/// the link is down and asserts the *changed* value came back, which is the
/// catalogue's own instruction for F8.
///
/// Moved here verbatim from `test/contract/fault_contract_test.dart` in Phase 7
/// (07-02). The body is unchanged: what it proves and how it proves it were
/// settled when it was written, and a move that edited the assertions would
/// make a red afterwards ambiguous between the move and the edit.

@TestOn('vm')
@Tags(['gate', 'faults'])
library;

import 'package:test/test.dart';
import 'package:tfc_relay_client/src/connection_supervisor.dart' show LinkState;

import '../support/fault_fixture.dart';
import '../support/gate_bands.dart';

void main() {
  group('F1/F8 — a clean drop, and what changed while it was down', () {
    test('F1a/F8: a clean drop mid-subscription reconnects, resyncs, and delivers '
        'what changed while it was down', () async {
      final fixture = await faultFixture(
        keys: const {scenarioKey},
        withProxy: true,
        seed: (plant) => plant.setValue(scenarioKey, 1200),
      );
      await until('the link', () => fixture.client.isReady);

      // Anti-vacuity: the page has to have been live before the drop, or
      // "it came back" is a statement about a client that never worked.
      expect(fixture.client.read(scenarioKey)?.value, 1200,
          reason: 'the subscription was not carrying the seeded value before '
              'the link was cut, so nothing below is about a recovery');
      final dialsBefore = fixture.seam.dials;
      expect(dialsBefore, greaterThan(0),
          reason: 'the client never dialled at all, so the fixture — not the '
              'fault — is what this case would be measuring');

      fixture.proxy.killOnce();
      // Changed while the link is down, which is F8's half of F1 and the only
      // reason the recovery assertion is not vacuous: a client that resynced
      // and re-delivered the *old* value would look identical without it.
      fixture.served.setValue(scenarioKey, 1500);

      await until(
          'the resync to deliver the value that changed during the outage',
          () => fixture.client.read(scenarioKey)?.value == 1500,
          budget: recovery);

      expect(fixture.seam.dials, greaterThan(dialsBefore),
          reason: 'the value arrived without a second dial, so the link was '
              'never actually cut and this case proves nothing about '
              'reconnecting');
      expect(fixture.client.isReady, isTrue, // window-exempt: the until() above already waited for the resynced value to arrive — a completed event; this asserts readiness is consistent with that arrival, not that readiness becomes true
          reason: 'the value arrived but the client is not back at ready, so '
              'the next call an operator makes still waits on the barrier');
    });

    test('F1b: the banner goes up and comes down, in that order, over a real '
        'socket', () async {
      final fixture = await faultFixture(
        keys: const {scenarioKey},
        withProxy: true,
        seed: (plant) => plant.setValue(scenarioKey, 1200),
      );

      final seen = <LinkState>[];
      final watching = fixture.client.linkStates.listen(seen.add);
      addTearDown(watching.cancel);

      await until('the link', () => fixture.client.isReady);

      // Anti-vacuity, first half: the recorder has to have been listening
      // before the fault. An empty list satisfies "contains the order" for
      // free, so without this the case below is a statement about nothing.
      expect(seen, isNotEmpty,
          reason: 'the recorder heard no transition at all on the way up, so '
              'it was not attached when the link was established and the '
              'sequence assertion below is being made against an empty list');
      final beforeTheKill = seen.length;
      final dialsBefore = fixture.seam.dials;

      fixture.proxy.killOnce();
      fixture.served.setValue(scenarioKey, 1500);

      await until('the resync after the kill to deliver the changed value',
          () => fixture.client.read(scenarioKey)?.value == 1500,
          budget: recovery);

      // Anti-vacuity, second half: a case that never lost the link would find
      // `ready` already in the list and pass the order assertion trivially.
      expect(fixture.seam.dials, greaterThan(dialsBefore),
          reason: 'the value came back without a second dial, so the socket '
              'was never actually cut and no banner was ever raised');
      expect(seen.length, greaterThan(beforeTheKill),
          reason: 'the recorder heard nothing after the kill, so whatever the '
              'panel showed during the outage, this case did not see it');

      // Read only after the until() above returned: the list is inspected as
      // a finished history, never polled while it is still being written.
      final afterTheKill = seen.sublist(beforeTheKill);
      expect(_inOrder(afterTheKill, const [
        LinkState.down,
        LinkState.resyncing,
        LinkState.ready,
      ]), isTrue,
          reason: 'the states after the kill were $afterTheKill, which does '
              'not contain down then resyncing then ready in that order. That '
              'order is the banner: down raises it, ready clears it, and a '
              'panel that never published down never told the operator to stop '
              'trusting the screen');

      // Asserted as a subsequence, not as equality: a redial that takes two
      // attempts adds another down/connecting pair and is the backoff working
      // as designed. `reconnect_test.dart:305` owns the exact-sequence
      // property against an in-memory peer, where the attempt count is not at
      // the mercy of a real socket.
      final firstReady = afterTheKill.indexOf(LinkState.ready);
      final firstResync = afterTheKill.indexOf(LinkState.resyncing);
      expect(firstReady, greaterThan(firstResync),
          reason: 'the panel published ready at position $firstReady, before '
              'the resync at $firstResync. Clearing the banner before the '
              'snapshot has landed is the screen saying the values are '
              'trustworthy while they are still the pre-outage ones');
    });
  });
}

/// Whether [pattern] appears in [states] in order, with anything in between.
bool _inOrder(List<LinkState> states, List<LinkState> pattern) {
  var next = 0;
  for (final state in states) {
    if (next < pattern.length && state == pattern[next]) next++;
  }
  return next == pattern.length;
}

/// The shared contract suite, judged against `RemoteStateMan` over a real
/// WebSocket, in front of a real `RelayServer`, in front of a real plant fake.
///
/// This is CLI-01's headline and the leg that makes it mean something: the
/// same 50 properties `LocalStateMan` is held to, driven through a socket, a
/// gateway session and a handle table. A defect in `RemoteStateMan` shows up
/// here as a *named property* failing rather than as a mystery on a socket.
///
/// **Why the count is asserted and not the greenness.** Copied wholesale from
/// `ws_contract_test.dart:18-27` in the server package, because the argument
/// transfers unchanged: a harness has one cheap way to look green, and it is
/// to declare a capability `false`. Doing that deletes cases, the report says
/// "skipped" rather than "passed", and the suite stays green while properties
/// go unjudged over this transport forever. So two numbers are checked from
/// two different places — what the umbrella *registered* under the flags it
/// was given, and what the runner actually *started* — and both against
/// [allContractChecks] rather than against a literal, because a literal is a
/// number somebody updates to match.
///
/// **The gap is named, not hidden.** [reachableChecks] is what this leg
/// currently *passes*, measured by running it, and [unreachableChecks] lists
/// every check it does not, by name and by cause. The two are asserted to add
/// up to `allContractChecks.length`, so neither can drift: a check that starts
/// passing must be deleted from the gap list for the arithmetic to hold, and a
/// check that regresses cannot be quietly absorbed. That is the whole point of
/// spelling the gap out — a leg that asserted a smaller number with no list
/// stays green forever while the gap never closes.
@TestOn('vm')
@Tags(['contract', 'ws'])
library;

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

import '../support/client_harness.dart';

/// The designated read-only key, carried across from the server package's
/// `ws_contract_test.dart:64` **character-identical**.
///
/// Supplied so the read-only case *runs*: `runWriteContract` drops it when no
/// key is declared, and a dropped case is one fewer than
/// `allContractChecks.length` — which the accounting below would then report
/// as a capability switched off. Correctly, because it would be one.
///
/// Identical on every leg by necessity rather than by tidiness: a leg that
/// judged a different set of cases would make the parity claim meaningless.
const _readOnlyKey = 'ST301.CN21.SEN01.temp';

/// What this leg passes today. Measured, not chosen.
///
/// [unreachableChecks] is now **empty**, which is the sentence this constant
/// existed to be able to say: there is no check on this leg that a missing
/// handler puts out of reach. The number must never go down without that list
/// growing to match, which the arithmetic case below enforces.
///
/// It was 21 when this leg was first measured (04-09). The other ten were
/// closed rather than excused, and what each of them turned out to be is worth
/// keeping here because the causes were not what the count suggested:
///
///  * **Two** were a real write-safety defect in the gateway. It minted its own
///    `cmd` when forwarding a write, so the id the operator's action was minted
///    under never reached the plant and no attempt count could ever be
///    attributed to it. Fixed in `value_handlers.dart` by forwarding the
///    client's id; `StateManApi.write` grew the `cmd` parameter that lets a
///    relay say "this action already has a name".
///  * **Five** were defects in this package. `WireValue.t` was dropped at all
///    three decode sites, so every value reached the store with no source time
///    and nothing downstream could age it. `readMany` discarded the gateway's
///    `rejected` map, so a key the source cannot serve came back as an absence
///    instead of a fault. And an applied write's readback was left to arrive on
///    the tick-quantised push path, so `await write(...)` routinely returned
///    while the store still held the old value under a pending badge.
///  * **Three** were the harness lying to the gateway rather than either of
///    them misbehaving: it handed the server a source with no address space, so
///    every key a case seeded after construction was classified as a typo and
///    silently never delivered. See `_PlantAddressSpace`.
///
/// **Which estimate 31 matched.** Three numbers were in circulation before this
/// leg ran: the phase brief's 36 (8 named missing), 04-RESEARCH's group table
/// (browse 6 + data services 7 = 13 unreachable, so 31), and 04-PATTERNS' 32.
/// The registries enumerate as 5 + 3 + 5 + 8 + 11 + 6 + 8 + 5 = 51, and every
/// unreachable check falls in the browse and data-services groups, so
/// **RESEARCH's table is the one that holds** and the other two were estimates
/// made before the read-only case and the browse group were counted the same
/// way. 36 in particular is not reachable from this registry by any grouping —
/// it would need five of the thirteen handler-less checks to be answerable, and
/// none is.
///
/// **Why 31 became 37 in Phase 5.** Six checks were added — five hold-to-run
/// properties in a registry of their own and one `writeStatus` property in
/// `write` — and every one of them is *reachable* rather than a new gap,
/// because the gateway handler behind them landed in the same phase (05-05's
/// hold branch, the `h` notification and the per-session hold map) rather than
/// being deferred to Phase 10 the way `browse.*` was. That is also why
/// `expectUnreachable`'s guard could stay narrowed to browse and data-services
/// names (`tfc_stateman_contract.dart:251-263`): a hold check cannot be excused
/// here even by somebody who wanted to.
///
/// **Why 37 became 43 in Phase 10.** 10-02 landed the four `browse.*` handlers
/// on the gateway — `data_handlers.dart`, registered through `RelaySession._on`
/// like every other method — and the six browse checks that used to sit in
/// [unreachableChecks] moved here in that same commit. Every one of them was
/// **closed by a handler, not excused**: none was renamed, none was skipped,
/// none was moved into the gap list to keep an arithmetic. The mechanism is why
/// the move had to be same-commit rather than tidied afterwards —
/// `expectUnreachableMethod` runs a named check and *fails* when it succeeds
/// (`check.dart:88-94`), so the instant `browse.fetchRoots` answered, leaving a
/// browse sentence in the list below would have reported a passing check as a
/// failure.
///
/// **And 43 became 46 in 10-03**, by exactly the same mechanism: the four
/// `timeseries.*` handlers landed and the three timeseries checks moved out of
/// [unreachableChecks] in that commit. **46 became 48 in 10-04**, when the
/// eleven `historyViews.*` handlers landed and took the two history-view
/// checks with them. **48 became 50 in 10-05**, when the fifteen
/// `preferences.*` handlers landed with the `preferences.changed` sender
/// behind them, and the last two entries left the gap list in that commit.
///
/// ## The Phase 10 ledger, closed
///
/// Thirteen entries were closed across four plans, and every one of them by a
/// handler that landed rather than by an excuse — none was renamed, none was
/// skipped, none was moved into the gap list to keep an arithmetic true. The
/// batch-by-batch arithmetic, in order:
///
///  * **37 → 43** (10-02): the four `browse.*` handlers, six checks.
///  * **43 → 46** (10-03): the four `timeseries.*` handlers, three checks.
///  * **46 → 48** (10-04): the eleven `historyViews.*` handlers, two checks.
///  * **48 → 50** (10-05): the fifteen `preferences.*` handlers and the
///    coalesced `preferences.changed` notification, the last two checks.
///
/// **`expectUnreachable`'s registration-time guard now has nothing left to
/// permit.** `tfc_stateman_contract.dart:249-263` narrows what may be excused
/// to browse and data-services names — a hold-to-run or freshness check could
/// never be excused here even by somebody who wanted to — and every name that
/// guard would have allowed is now a check this leg passes. The parameter is
/// still passed below, with an **empty** set rather than deleted, and that is
/// deliberate: a future gap should have a mechanism to declare itself through,
/// proven and self-policing, instead of a precedent for a leg quietly
/// asserting a smaller number.
///
/// **This number is proven to bite**, three ways rather than one. Raising it by
/// one with the gap list unchanged fails the arithmetic case below with
/// `Expected: <51> Actual: <52>` (run, recorded, reverted — at 43, again at 46
/// in 10-03, and again at 48 in 10-04). Moving a check into the gap list to
/// keep the arithmetic while lowering the count fails `expectUnreachable`,
/// which rejects a named check that passes. And a reachable check that
/// regresses fails as itself, because the suite is green only when all 48
/// pass.
/// **And 50 became 51 in the 10-REVIEW fix cycle** (CR-02), by the one
/// mechanism this file has not seen before: not a handler landing, but a
/// *check* landing. `preferences.clear` had no judge on any leg —
/// `dataServicesChecks` had seven entries and `clear` was in none of them —
/// which is how the widest method on the interface reached the wire behind the
/// role that sets a theme. `checkPreferenceClearCarriesItsAllowList` is the
/// eighth data-services check, and it is reachable here on the day it is
/// written because the `preferences.clear` handler landed back in 10-05. The
/// gap list stays empty.
const int reachableChecks = 51;

/// Every check this leg does not pass, by name. **It is empty**, and 10-05 is
/// the commit that emptied it.
///
/// It held thirteen entries when Phase 10 opened, every one of them a missing
/// *handler* rather than a missing behaviour: `browse.*` (six), `timeseries.*`
/// (three), `historyViews.*` (two) and `preferences.*` (two). Each batch was
/// deleted from here — deleted, never commented out — in the same commit that
/// registered the handlers behind it, and [reachableChecks] carries the
/// account of which plan closed which.
///
/// **The list is kept rather than the parameter deleted**, and so is the
/// `expectUnreachable:` argument below. Three things this arrangement does
/// that a deleted parameter would not: a check that regresses cannot be
/// quietly absorbed, because the arithmetic case would then need a name here
/// and a name here has to be a real check name; a future gap has a mechanism
/// to declare itself through instead of a precedent for lowering a constant;
/// and `expectUnreachableMethod` keeps its teeth, because it *fails a named
/// check that passes* — so an entry added here for a check that actually works
/// is caught rather than believed.
const List<String> unreachableChecks = <String>[];

void main() {
  var ran = 0;

  final before = contractCasesRegistered;
  group('the whole contract, against a real gateway over a real WebSocket', () {
    setUp(() => ran++);
    runStateManContract(
      relayServedFake,
      readOnlyKey: _readOnlyKey,
      browseFixture: defaultBrowseFixture,
      // The only override this leg takes, and it changes *when* the link is
      // cut, never what is asserted afterwards. See
      // `dropUpstreamUnderAWriteInFlight`: over a socket the default lever
      // disconnects before the write has reached the plant, so the case never
      // reaches the state it is named for.
      dropLinkWithWritesInFlight: dropUpstreamUnderAWriteInFlight,
      // Proven, not skipped: each of these runs and must fail with exactly
      // -32601. See [unreachableChecks].
      expectUnreachable: unreachableChecks.toSet(),
    );
  });
  final registered = contractCasesRegistered - before;

  group('the run itself', () {
    // The one named gap this leg carries: the access family 17-05 merged
    // into the kit roster (51 -> 78). RemoteStateMan serves no access surface
    // yet, so the umbrella's supportsAccessControl default (false) holds, and
    // the gap is pinned by NAME rather than absorbed into a lower count.
    // access checks — 17-06/17-08 opt this leg in; 17-14 empties the gap.
    final accessGap = accessChecks.keys.toSet();

    test('every check outside the named access gap was registered against '
        'the gateway, and the gap is pinned by name', () {
      final entitled = contractCases(readOnlyKey: _readOnlyKey);
      final gap =
          allContractChecks.keys.toSet().difference(entitled.keys.toSet());
      expect(gap, accessGap,
          reason: 'this leg is short of the full roster by cases that are '
              'not the access family. That is a second capability switched '
              'off inside the first one\'s arithmetic, and the cases behind '
              'it are unjudged for every panel that uses this client '
              'afterwards. Fix the forwarding; do not lower the flag');
      expect(registered + gap.length, allContractChecks.length,
          reason: 'the umbrella registered $registered and the named access '
              'gap holds ${gap.length}; together they must reconcile to the '
              'roster of ${allContractChecks.length}, or a check exists that '
              'is neither run nor accounted for');
    });

    test('every registered check actually started', () {
      expect(ran + accessGap.length, allContractChecks.length,
          reason: '$ran of $registered registered cases actually ran, and '
              'the named access gap holds ${accessGap.length}. The '
              'difference is a case registered and then skipped, which the '
              'registration count cannot see: the report shows a skip reason, '
              'the suite stays green, and the property is as unjudged as it '
              'would have been with the capability off');
    });

    test('the reachable set and the named gaps account for every check', () {
      expect(reachableChecks + unreachableChecks.length + accessGap.length,
          allContractChecks.length,
          reason: 'this leg claims to pass $reachableChecks checks, names '
              '${unreachableChecks.length} it does not, and carries the '
              '${accessGap.length}-check access gap (17-06/17-08 opt this '
              'leg in; 17-14 empties it), which is '
              '${reachableChecks + unreachableChecks.length + accessGap.length} of '
              '${allContractChecks.length}. The three must account for the whole '
              'suite or the gap is not a gap, it is a number somebody stopped '
              'maintaining — which is exactly the failure mode a named '
              'constant with no list has');
    });

    test('every named gap is a real check name, not a stale string', () {
      final names = allContractChecks.keys.toSet();
      final unknown =
          unreachableChecks.where((name) => !names.contains(name)).toList();
      expect(unknown, isEmpty,
          reason: 'these entries in the gap list match no check in the suite: '
              '$unknown. A gap entry that names nothing is how a list like '
              'this rots: the arithmetic still adds up, the constant still '
              'looks maintained, and a check that started passing years ago '
              'is still being excused');
    });
  });
}

/// The fourth contract leg: the same suite, over the gateway's plant side —
/// and the database-free one. `contract_db_test.dart` is the fifth, the same
/// fifty checks over the same class with a real TimescaleDB behind it; the two
/// share `buildHarnessedLocalStateMan` so they cannot drift into judging
/// different subjects.
///
/// Three implementations already pass it — the reference fake, the in-memory
/// channel and the real WebSocket. This is the fourth and the first with a
/// plant behind it, which is the moment `LocalStateMan` stops being this
/// phase's code and becomes an implementation of the interface the whole
/// project is built around.
///
/// The kit was designed for exactly this. `browseFixture` is a parameter
/// *"because a gateway browsing a real ST101 over OPC UA passes its own"*
/// (`tfc_stateman_contract.dart`), and `StateManHarness` is declared in the kit
/// rather than in any implementation so the kit keeps its defining property: it
/// imports no implementation, and the factory below is the only coupling to
/// one.
///
/// **One fake upstream link.** 08-CONTEXT ruling 8, and the conflicting pair of
/// freshness checks that forced it, are written out in
/// `support/harnessed_local_state_man.dart`. The per-alias half of the property
/// is `link_loss_test.dart`'s (08-09). Both; neither substitutes.
///
/// **Why the counts are asserted and not the greenness.** Copied from
/// `ws_contract_test.dart`, because the argument transfers unchanged: a harness
/// has one cheap way to look green, and it is to declare a capability false.
/// So two numbers from two different places — what the umbrella *registered*
/// under the flags it was given, and what the runner actually *started* — are
/// both compared against a number the kit computes, never against a literal,
/// *"because a literal is a number somebody updates to match"*.
@TestOn('vm')
@Tags(['contract'])
library;

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

import 'support/harnessed_local_state_man.dart';

void main() {
  var ran = 0;

  final before = contractCasesRegistered;
  group('the whole contract, over LocalStateMan and one fake upstream link',
      () {
    setUp(() => ran++);
    runStateManContract(
      makeHarnessedLocalStateMan,
      // The plant link takes writes; the read-only key's link does not, which
      // is what makes `checkReadOnlyKeyIsRejectedNotThrown` a device-level
      // refusal rather than a staged one.
      supportsWrites: true,
      readOnlyKey: contractReadOnlyKey,
      supportsBrowse: true,
      // The gateway's own tree, per the parameter's own doc.
      browseFixture: gatewayBrowseFixture,
      // ---------------------------------------------------------------------
      // STILL FALSE, and what was a reason is now a RESULT.
      //
      // 08-11 wrote this `false` because nothing existed behind it: Phase 10
      // owned timeseries, history views and preferences, and `LocalStateMan`'s
      // three getters threw an `UnimplementedError` naming `10-01` as the plan
      // that owed them. All three landed — the reader in 10-07, the view store
      // in 10-08, the preference store and its change feed in 10-09 — and
      // `freeze_test.dart`'s `declaredUnimplementedMembers` is **0** because of
      // it. `contract_db_test.dart` (10-11) runs this same suite with the flag
      // **true** against a real TimescaleDB, all fifty checks, empty gap list.
      //
      // So this `false` is no longer a gap. It is a true statement about the
      // subject *this* leg composes: a gateway with no `collection:` block, no
      // database object at all, which is the ordinary deployment and the one
      // `LocalStateMan.timeseries` refuses by name rather than answering with
      // an empty chart. The rule that decides it is the plan's:
      // **`dart test --exclude-tags db` must not need a database**, and this
      // file is that lane's contract coverage.
      //
      // **A FLAG, not a LIST, and the difference is the one thing to carry
      // away** (Trap 4). The socket legs each emptied an `expectUnreachable`
      // set of thirteen sentences asserting JSON-RPC `-32601`, retired batch by
      // batch across 10-02..10-05. This leg never had one and could not have:
      // `expectUnreachable` passes a case *only* by failing with exactly
      // `-32601`, and an in-process peer has no wire, no envelope and no error
      // code to produce with. There is no gap list here to find retired; the
      // flag is the whole record, and looking for the list is looking for
      // something that never existed.
      //
      // The consequence is arithmetic and is asserted below: this leg
      // registers `allContractChecks.length` minus the seven data-services
      // cases, and the gap is pinned BY NAME so a second capability quietly
      // going false cannot hide inside the same number.
      //
      // The fakes in `fake_data_services.dart` are **not** deleted by any of
      // this. `:11-18` says what must survive their replacement is the
      // contract and not the code, and they have two live jobs: they are
      // `parity_test.dart:107`'s reference leg, and they are the sabotage
      // baseline — an arm that breaks the database implementation has to be
      // able to show the same check still passing against something.
      supportsDataServices: false,
      // 08-06 task 3 landed `holdToRun`, so the deadman is real here.
      supportsHoldToRun: true,
      // Nothing is declared unreachable: see above.
      expectUnreachable: const <String>{},
    );
  });
  final registered = contractCasesRegistered - before;

  group('the run itself', () {
    /// What the flags above entitle this leg to run — computed by the kit from
    /// the same flags, never written down as a number.
    final entitled = contractCases(
      supportsWrites: true,
      readOnlyKey: contractReadOnlyKey,
      supportsBrowse: true,
      supportsDataServices: false,
      supportsHoldToRun: true,
    );

    test('every check the flags entitle this leg to ran against LocalStateMan',
        () {
      expect(registered, entitled.length,
          reason: 'the umbrella registered $registered of ${entitled.length} '
              'checks the declared capabilities entitle this leg to. A '
              'smaller number does not mean the gateway does less — it means '
              'a capability was switched off rather than met, and the cases '
              'behind it are unjudged against the one implementation with a '
              'plant behind it. Fix the forwarding; do not lower the flag');
    });

    test('every registered check actually started', () {
      expect(ran, entitled.length,
          reason: '$ran of $registered registered cases actually ran. The '
              'difference is a case registered and then skipped, which the '
              'registration count cannot see: the report shows a skip reason, '
              'the suite stays green, and the property is as unjudged as it '
              'would have been with the capability off');
    });

    test('the only gaps against the full roster are the data-services and '
        'access cases, named', () {
      final gap = allContractChecks.keys.toSet().difference(entitled.keys.toSet());

      // The named gap, as two named SETS and never as a count: the
      // data-services cases behind `supportsDataServices: false`, and the
      // access family 17-05 merged into the kit roster (51 -> 78), which
      // this leg does not serve yet.
      // access checks — 17-06/17-08 opt this leg in; 17-14 empties the gap.
      expect(gap, {...dataServicesChecks.keys, ...accessChecks.keys},
          reason: 'this leg is short of the full roster by cases that are not '
              'the ones Phase 10 and the access family own. That is a THIRD '
              'capability gone false, hiding inside the first two\'s '
              'arithmetic — which is exactly what comparing a single count '
              'against a single number cannot see, and why the gap is pinned '
              'by name as well as by size');
      expect(registered + gap.length, allContractChecks.length,
          reason: 'registered plus the named gap must reconcile to the whole '
              'roster; if it does not, a check exists that is neither run nor '
              'accounted for');
      // ignore: avoid_print
      print('leg 4 (LocalStateMan): $registered of '
          '${allContractChecks.length} checks registered and $ran ran; the '
          '${dataServicesChecks.length} data-services cases are off behind '
          'supportsDataServices: false, because this leg composes no '
          'database — they are judged over a real one by contract_db_test '
          'in the db lane. The ${accessChecks.length} access cases are off '
          'behind supportsAccessControl: false until 17-06/17-08 opt this '
          'leg in; 17-14 empties the gap');
    });
  });
}

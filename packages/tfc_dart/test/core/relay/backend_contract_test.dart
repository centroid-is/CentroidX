/// The sixth contract leg: the whole shared suite, over `BackendStateMan`.
///
/// ## What this leg is for, in one sentence
///
/// Every plan in this phase so far has run a *sub-suite* — 13-03 the thirteen
/// value checks, 13-04 the six browse checks, 13-07 the eight freshness
/// checks, 13-08 the eleven write and five hold checks. This file runs the
/// umbrella, counts what it registered against what actually started, and
/// reconciles both against `allContractChecks.length` — because a harness has
/// exactly one cheap way to look green, and it is to declare a capability
/// false.
///
/// ## Why the counts are asserted and not the greenness
///
/// Copied in shape from `ws_contract_test.dart` and `contract_test.dart`,
/// because the argument transfers unchanged. `supportsHoldToRun: false` here
/// would delete five cases, the report would say "skipped" rather than
/// "passed", and the suite would stay green while five properties went
/// unjudged against the one adapter the plant will actually run. So two
/// numbers from two different places — what the umbrella *registered* under
/// the flags it was given, and what the runner actually *started* — are both
/// compared against a number the kit computes, never against a literal,
/// because a literal is a number somebody updates to match.
///
/// The gap is pinned **by name** as well as by size. A count alone cannot see
/// a second capability going false inside the first one's arithmetic; the
/// named set can, and the sabotage below is the evidence that it does.
///
/// ## `expectUnreachable` is empty, and could not be anything else
///
/// The parameter passes a case by requiring it to fail with exactly JSON-RPC
/// `-32601`. This leg is in-process: `BackendStateMan` is reached by a method
/// call, there is no wire, no envelope and no error code for it to produce
/// with. So an empty set here is not a gap being tolerated — it is the only
/// honest value, and the same one `contract_db_test.dart:319` and
/// `contract_test.dart:103` carry for the identical reason.
///
/// ## What the one false flag means
///
/// `supportsDataServices: false`, and the rule that decides it is the plan's:
/// **`dart test --exclude-tags db` must not need a database.** This file is
/// the offline lane's contract coverage, and a backend composed without a
/// `Database` — which is the default deployment, and the one
/// `BackendStateMan.timeseries` refuses by name rather than answering with an
/// empty chart — genuinely has no data services. The eight cases behind the
/// flag are judged over a real TimescaleDB by
/// `test/integration/backend_contract_db_test.dart`, which is additive: it is
/// the same suite over the same class with the three services composed in.
@TestOn('vm')
@Tags(['contract'])
@Timeout(Duration(minutes: 5))
library;

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

import '../../support/harnessed_backend_state_man.dart';
import 'package:tfc_stateman_contract/testing/runner_budget.dart';

void main() {
  useRunnerBudgets();

  var ran = 0;

  final before = contractCasesRegistered;
  group('the whole contract, over BackendStateMan and one fake worker', () {
    setUp(() => ran++);
    runStateManContract(
      makeHarnessedBackendStateMan,
      // The pipe carries writes with their three-state outcome intact (13-08).
      supportsWrites: true,
      // Declared, so `checkReadOnlyKeyIsRejectedNotThrown` *runs*. The same
      // string every other leg names: a leg that judged a different set of
      // cases would make a parity sweep across legs meaningless, and a leg
      // that named none at all would drop the case and the accounting below
      // would report the drop as a capability switched off — correctly,
      // because it would be one.
      readOnlyKey: contractReadOnlyKey,
      // Mapping-backed, and it reaches nowhere upstream (13-04).
      supportsBrowse: true,
      // The conventional tree. `contractKeyMappings()` seeds exactly it, and
      // `contractMethodKeys` declares the one callable
      // `checkBrowseNodeTypesDistinguishFoldersFromVariables` needs — see
      // 13-04 Finding 1 for why a mapping cannot produce a method node on its
      // own and why production declares none.
      browseFixture: defaultBrowseFixture,
      // ---------------------------------------------------------------------
      // FALSE, and it is a statement about this lane rather than a gap.
      //
      // `dart test --exclude-tags db` must not need a database. This leg
      // composes no `Database`, so 13-05's three classes have nothing behind
      // them and `BackendStateMan`'s three getters refuse by name — which is
      // the honest answer for a backend deployed without TimescaleDB, the
      // ordinary case. The eight cases are not thereby unjudged: they run
      // against a real server in `test/integration/backend_contract_db_test.
      // dart`, and the arithmetic below pins this flag as the *only* thing
      // this leg is short of.
      supportsDataServices: false,
      // 13-08 landed the deadman on the write path, so it is real here.
      supportsHoldToRun: true,
      // The three plant-side observables the write cases need. Each is on the
      // harness rather than on `StateManApi`, because a count a connected
      // client could query would be an access-control decision and not a
      // testing convenience.
      upstreamWriteAttempts: (api, cmd) =>
          (api as HarnessedBackendStateMan).writes.upstreamAttempts(cmd),
      stallWrites: (api) => (api as HarnessedBackendStateMan).plant.stall(),
      // The worker isolate really dies. `disconnectUpstream` is the
      // announcement (13-07 Finding 1) and an announcement does not settle a
      // write that was already out, which is what this case is about.
      dropLinkWithWritesInFlight: (api) =>
          (api as HarnessedBackendStateMan).killUpstreamWorker(),
      // -------------------------------------------------------- THE GAP LIST
      //
      // EMPTY, written out rather than defaulted. Criterion 1 asks for an
      // empty gap list and this is where it is stated. The parameter is also
      // meaningless for an in-process leg — it passes a case only by requiring
      // exactly JSON-RPC -32601, and there is no wire here to produce one —
      // so there is no version of this file in which a name could honestly
      // appear. A check that cannot pass is a finding to record, not a name to
      // add here.
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

    test('every check the flags entitle this leg to ran against BackendStateMan',
        () {
      expect(registered, entitled.length,
          reason: 'the umbrella registered $registered of ${entitled.length} '
              'checks the declared capabilities entitle this leg to. A smaller '
              'number does not mean the backend adapter does less — it means a '
              'capability was switched off rather than met, and the cases '
              'behind it are unjudged against the object the plant will '
              'actually run. Fix the forwarding; do not lower the flag');
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
      final gap =
          allContractChecks.keys.toSet().difference(entitled.keys.toSet());

      // The named gap, as two named SETS and never as a count: the
      // data-services cases behind `supportsDataServices: false`, and the
      // access family 17-05 merged into the kit roster (51 -> 78), which
      // this leg does not serve yet.
      // access checks — 17-06/17-08 opt this leg in; 17-14 empties the gap.
      expect(gap, {...dataServicesChecks.keys, ...accessChecks.keys},
          reason: 'this leg is short of the full roster by cases that are not '
              'the ones `supportsDataServices` and `supportsAccessControl` '
              'own. That is a THIRD capability gone false, hiding inside the '
              'first two\'s arithmetic — which is exactly what comparing a '
              'single count against a single number cannot see, and why the '
              'gap is pinned by name as well as by size');
      expect(registered + gap.length, allContractChecks.length,
          reason: 'registered plus the named gap must reconcile to the whole '
              'roster; if it does not, a check exists that is neither run nor '
              'accounted for');
      // ignore: avoid_print
      print('leg 6 (BackendStateMan, in memory): $registered of '
          '${allContractChecks.length} checks registered and $ran ran; the '
          '${dataServicesChecks.length} data-services cases are off behind '
          'supportsDataServices: false, because this leg composes no database '
          '— they are judged over a real TimescaleDB by '
          'backend_contract_db_test in the db lane. The '
          '${accessChecks.length} access cases are off behind '
          'supportsAccessControl: false until 17-06/17-08 opt this leg in; '
          '17-14 empties the gap. The gap list (expectUnreachable) is empty');
    });
  });
}

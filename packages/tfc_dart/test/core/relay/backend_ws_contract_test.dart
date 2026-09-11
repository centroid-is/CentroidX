/// The eighth contract leg: the whole shared suite, over a real WebSocket, to
/// the composition `centroidx-backend` ships.
///
/// ## What passing here buys that the in-memory leg cannot
///
/// `backend_contract_test.dart` reaches `BackendStateMan` by a method call.
/// This file reaches it across a socket. A transport that passes the same suite
/// as the in-process one cannot be hiding a framing, ordering or lifetime
/// difference — and those are exactly the three ways a new transport breaks a
/// working protocol: a message split across frames and delivered in halves, two
/// notifications delivered out of order, or a socket whose close races the data
/// in front of it. Each turns a specific check red, **by name**, and the
/// sabotage record in 13-11's SUMMARY says which.
///
/// The rig protocol probes (criterion 3) are the only thing this phase cannot
/// prove offline. This leg is what makes their absence survivable: everything a
/// probe would ask about the wire, except the plant itself, is asked here.
///
/// ## Why the counts are asserted and not the greenness
///
/// Copied in shape and in argument from `ws_contract_test.dart` and
/// `backend_contract_test.dart`, because it transfers unchanged: a harness has
/// exactly one cheap way to look green, and it is to declare a capability
/// false. `supportsBrowse: false` here would delete six cases, the report would
/// say "skipped" rather than "passed", and the suite would stay green while six
/// properties went unjudged over the transport every panel in the plant will
/// use. So two numbers from two different places — what the umbrella
/// *registered* under the flags it was given, and what the runner actually
/// *started* — are compared against a number the kit computes from those same
/// flags, never against a literal, because a literal is a number somebody
/// updates to match.
///
/// **A red check here is not a check to exclude.** If something green in memory
/// goes red over the socket, that is a real transport defect or a defaults
/// mismatch in the harness, and both are fixable. `ws_contract_test.dart:99-101`
/// puts it in the only words that matter: excluding it converts this file into
/// a lie.
///
/// ## `expectUnreachable` is empty, and here that is a choice
///
/// On the in-memory leg the parameter was unusable — it passes a case only by
/// requiring exactly JSON-RPC `-32601`, and an in-process peer has no wire to
/// produce one with. **This leg has a wire.** `ChannelStateMan` forwards every
/// browse and data-service call as a request, and a method the served end did
/// not register would come back `-32601`, so a name here would be *technically*
/// honest in a way it never could be over there. That is exactly why the empty
/// set has to be written out: criterion 1 asks for an empty gap list on both
/// legs, and on this leg an empty one is earned rather than forced.
///
/// ## No budget was widened
///
/// `runStateManContract` takes no budget argument, and neither the TCP socket
/// leg nor the other WebSocket leg added one. Every case wraps its awaits in
/// `within()`, which names the property and gives it a deadline, so a transport
/// too slow for a case fails **that case, by name** instead of being papered
/// over by a wider suite-level number. Loopback WebSocket framing is the same
/// order of cost as a method call plus a microtask; this leg was written
/// expecting no change and needed none. If one is ever wanted it belongs in the
/// case that needs it, with the measurement that justified it — and that is an
/// edit to `tfc_stateman_contract`, outside this phase.
///
/// ## The one false flag, and the finding behind it
///
/// `supportsDataServices: false`, the same as the in-memory leg, and for the
/// same lane rule: **`dart test --exclude-tags db` must not need a database.**
/// The composition this leg serves *does* have the three data services behind a
/// real on-disk SQLite store, so the flag is not a statement that they are
/// absent — it is a statement that judging them needs `seedTimeseries` to put
/// rows in front of a reader, which is 13-09's `db` leg's machinery and a real
/// TimescaleDB. Setting the flag true here would also make this leg judge a
/// *different set* from the in-memory one, which is precisely what
/// `backend_ws_parity_test.dart` exists to forbid.
///
/// The consequence is a finding and is recorded as one: the eight
/// data-services checks are judged in memory (by `backend_contract_db_test`,
/// itself unexecuted for want of a Docker daemon — 13-09 Finding 1) and **never
/// over the wire**. The parity test's reconciliation names that group so no
/// reader has to rediscover it.
@TestOn('vm')
@Tags(['contract', 'ws'])
@Timeout(Duration(minutes: 6))
library;

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

import '../../support/backend_ws_harness.dart';
import '../../support/harnessed_backend_state_man.dart';
import 'package:tfc_stateman_contract/testing/runner_budget.dart';

void main() {
  useRunnerBudgets();

  // The real on-disk `Database` and `Preferences` `composeBackendRelay`
  // requires, once per file. Registered before anything else in `main` so the
  // ordering is visible rather than inferred.
  installBackendWsStore();

  var ran = 0;

  final before = contractCasesRegistered;
  group('the whole contract, over a real WebSocket to the shipping composition',
      () {
    setUp(() => ran++);
    runStateManContract(
      backendWsServed,
      // ----------------------------------------------------------------------
      // Every flag below is IDENTICAL to `backend_contract_test.dart`'s, and
      // the identity is load-bearing rather than tidy: a leg that judged a
      // different set of cases would make the parity sweep meaningless, and the
      // sweep is what turns "the same number of checks" into "the same checks".
      // ----------------------------------------------------------------------
      supportsWrites: true,
      readOnlyKey: contractReadOnlyKey,
      supportsBrowse: true,
      browseFixture: defaultBrowseFixture,
      supportsDataServices: false,
      supportsHoldToRun: true,
      // The three plant-side hooks. On this leg they must reach the SERVER
      // side: the pipe, the fake worker and the write router are all across the
      // socket, and a hook that reached for something on the client would be
      // measuring the client. `backendServerHarness` is the one function that
      // does the crossing, and it fails loudly rather than casting.
      upstreamWriteAttempts: (api, cmd) =>
          backendServerHarness(api).writes.upstreamAttempts(cmd),
      stallWrites: (api) => backendServerHarness(api).plant.stall(),
      // The worker isolate really dies. `disconnectUpstream` is the
      // announcement (13-07 Finding 1) and an announcement does not settle a
      // command that was already out, which is what this case is about.
      dropLinkWithWritesInFlight: (api) =>
          backendServerHarness(api).killUpstreamWorker(),
      // ---------------------------------------------------------- THE GAP LIST
      //
      // EMPTY, written out, and on this leg *earned* — see the library doc.
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

    test('every check the flags entitle this leg to ran over the WebSocket',
        () {
      expect(registered, entitled.length,
          reason: 'the umbrella registered $registered of ${entitled.length} '
              'checks the declared capabilities entitle this leg to. A smaller '
              'number does not mean the WebSocket carries less — it means a '
              'capability was switched off rather than met, and the cases '
              'behind it are unjudged over the transport every panel in the '
              'plant connects on. Fix the forwarding; do not lower the flag');
    });

    test('every registered check actually started', () {
      expect(ran, entitled.length,
          reason: '$ran of $registered registered cases actually ran. The '
              'difference is a case registered and then skipped, which the '
              'registration count cannot see: the report shows a skip reason, '
              'the suite stays green, and the property is as unjudged as it '
              'would have been with the capability off. Excluding a check that '
              'fails over a WebSocket converts this file into a lie — a '
              'failure here is a real transport defect or a defaults mismatch '
              'in the harness, and both are fixable');
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
      print('leg 8 (BackendStateMan from composeBackendRelay, over a real '
          'WebSocket): $registered of ${allContractChecks.length} checks '
          'registered and $ran ran; the ${dataServicesChecks.length} '
          'data-services cases are '
          'off behind supportsDataServices: false — the same flag, for the '
          'same lane rule, as the in-memory leg, so the two legs judge the '
          'same SET (backend_ws_parity_test). Those eight are judged in memory '
          'by backend_contract_db_test and NEVER over the wire: that is a '
          'FINDING, recorded in 13-11-SUMMARY, not a gap being tolerated. The '
          '${accessChecks.length} access cases are off behind '
          'supportsAccessControl: false until 17-06/17-08 opt this leg in; '
          '17-14 empties the gap. The gap list (expectUnreachable) is empty');
    });
  });
}

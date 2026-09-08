/// The whole contract suite, judged over a real WebSocket.
///
/// Phase 1 wrote 44 checks and ran them in memory. Phase 2 ran the same 44 over
/// a real TCP socket through a fault proxy. This file is the third leg, and it
/// costs one line of suite invocation for the reason RESEARCH Finding 12 gives:
/// `ChannelStateMan` and `ServedStateMan` both take a `StreamChannel<String>`,
/// so a WebSocket is a transport swap and nothing else. No framing layer is
/// needed on this leg — the frame *is* the message boundary, which is the one
/// job `lineChannel` had to do for TCP.
///
/// **What passing here buys.** A transport that passes the same suite as the
/// in-memory channel cannot be hiding a framing, ordering or lifetime
/// difference. Those are exactly the three ways a new transport breaks a
/// working protocol: a message split across frames and delivered in halves, two
/// notifications delivered out of order, or a socket whose close races the data
/// in front of it. Each of those turns a specific check red, by name.
///
/// **Why the count is asserted and not the greenness.** Copied wholesale from
/// `channel_full_contract_test.dart:11-31`, because the argument transfers
/// unchanged: a harness has one cheap way to look green, and it is to declare a
/// capability `false`. `supportsDataServices: false` here would delete seven
/// cases, the report would say "skipped" rather than "passed", and the suite
/// would stay green while seven properties went unjudged over this transport
/// forever. So two numbers are checked, from two different places — what the
/// umbrella *registered* under the flags it was given, and what the runner
/// actually *started* — and both against `allContractChecks.length` rather than
/// against a literal, because a literal is a number somebody updates to match.
///
/// The parity claim proper — that this leg passes the same *set* of checks as
/// the other two, not merely the same number — is `ws_parity_test.dart`.
///
/// **No budget argument.** `runStateManContract` takes none, and the socket leg
/// (`socket_contract_test.dart`) did not widen one either: every case wraps its
/// awaits in `within()`, which names the property and gives it a deadline, so a
/// transport too slow for a case fails that case by name instead of being
/// papered over by a wider suite-level number. Loopback WebSocket framing is
/// the same order of cost as loopback TCP, and this leg was written expecting
/// no budget change. If one is ever needed, it belongs in the check that needs
/// it, with the measurement that justified it.
///
/// This file lives in `tfc_relay_server/test/` and never in
/// `tfc_stateman_contract`: the contract package is a dev-dependency of the
/// server, and the reverse edge would make the test kit depend on the thing it
/// judges (T-03-17).
@TestOn('vm')
@Tags(['contract', 'ws'])
library;

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

import 'support/ws_harness.dart';

/// The designated read-only key, carried across from
/// `channel_full_contract_test.dart` and `socket_contract_test.dart` verbatim.
///
/// Supplied so the read-only case *runs*: `runWriteContract` drops it when no
/// key is declared, and a dropped case is one fewer than
/// `allContractChecks.length` — which the accounting below would then report as
/// a capability switched off. Correctly, because it would be one.
///
/// Identical on all three legs by necessity rather than by tidiness: a leg that
/// judged a different set of cases would make the parity sweep meaningless.
const _readOnlyKey = 'ST301.CN21.SEN01.temp';

void main() {
  var ran = 0;

  final before = contractCasesRegistered;
  group('the whole contract, over a real WebSocket', () {
    setUp(() => ran++);
    runStateManContract(
      wsServedFake,
      readOnlyKey: _readOnlyKey,
      browseFixture: defaultBrowseFixture,
    );
  });
  final registered = contractCasesRegistered - before;

  group('the run itself', () {
    // The one named gap this leg carries: the access family 17-05 merged
    // into the kit roster (51 -> 78). The WS harness serves no access surface
    // yet, so the umbrella's supportsAccessControl default (false) holds, and
    // the gap is pinned by NAME rather than absorbed into a lower count.
    // access checks — 17-06/17-08 opt this leg in; 17-14 empties the gap.
    final accessGap = accessChecks.keys.toSet();

    test('every check outside the named access gap ran over the WebSocket, '
        'and the gap is pinned by name', () {
      final entitled = contractCases(readOnlyKey: _readOnlyKey);
      final gap =
          allContractChecks.keys.toSet().difference(entitled.keys.toSet());
      expect(gap, accessGap,
          reason: 'this leg is short of the full roster by cases that are '
              'not the access family. That is a second capability switched '
              'off inside the first one\'s arithmetic, and the cases behind '
              'it are unjudged over this transport for every client that '
              'uses it afterwards. Fix the forwarding; do not lower the flag');
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
              'would have been with the capability off. Excluding a check that '
              'fails over a WebSocket converts this file into a lie — a '
              'failure here is a real transport defect in `wsChannel` or a '
              'defaults mismatch in the harness, and both are fixable');
    });
  });
}

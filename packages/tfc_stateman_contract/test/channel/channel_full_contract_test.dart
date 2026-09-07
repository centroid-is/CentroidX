/// The whole contract suite, against an implementation on the far side of a
/// channel.
///
/// The first half of roadmap criterion 3, and the file the phase is for. Every
/// other driver in `test/channel/` judges one sub-suite; this one points
/// `runStateManContract` — the entry point a real implementation will use — at
/// a `FakeStateMan` reachable only through a `StreamChannelController`, with
/// every capability declared, and asserts that the number of cases that ran is
/// the number the registry has.
///
/// ## Why the count is the assertion
///
/// A harness has one cheap way to look green, and it is not a bug in any file:
/// declare a capability `false`. The run stays honest-looking — the report even
/// says the capability was skipped rather than passed — and the property goes
/// unjudged for every implementation that follows. `supportsDataServices:
/// false` here would delete seven cases and nothing would complain, which is
/// the move this file exists to make impossible (T-02-23).
///
/// So two numbers are checked, and they come from different places on purpose:
///
///  * `contractCasesRegistered`'s delta is what `runStateManContract` says it
///    registered to run, under the flags it was given. It catches a flag left
///    false.
///  * `ran` is what the test runner actually started, counted by a `setUp` in
///    the enclosing group. It catches a case registered and then skipped, which
///    the first number cannot see.
///
/// Both are compared against `allContractChecks.length`: not against a literal,
/// because a literal is a number somebody updates to match, and the thing being
/// asserted is precisely that nobody had to.
@Tags(['contract'])
library;

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

/// The designated read-only key, carried across from
/// `test/channel/channel_write_contract_test.dart` verbatim.
///
/// Supplied so the read-only case *runs*: `runWriteContract` drops it when no
/// key is declared, and a dropped case is one fewer than
/// `allContractChecks.length`, which this file would then report as a
/// capability switched off — correctly, because it would be one.
const _readOnlyKey = 'ST301.CN21.SEN01.temp';

void main() {
  var ran = 0;

  final before = contractCasesRegistered;
  group('the whole contract, over a channel', () {
    setUp(() => ran++);
    runStateManContract(
      channelServedFake,
      readOnlyKey: _readOnlyKey,
      browseFixture: defaultBrowseFixture,
      // ChannelStateMan forwards the four access families over the same peer
      // (17-05) and reads the session lever off the served instance, so the
      // whole roster — access included — is judged across the message boundary.
      supportsAccessControl: true,
    );
  });
  final registered = contractCasesRegistered - before;

  group('the run itself', () {
    test('every check the suite has ran over the channel', () {
      expect(registered, allContractChecks.length,
          reason: 'the umbrella registered $registered of '
              '${allContractChecks.length} checks against a channel-served '
              'source that declared every capability. A smaller number does '
              'not mean the harness carries less — it means a capability was '
              'switched off rather than met, and the cases behind it are '
              'unjudged across a message boundary for every implementation '
              'that uses this entry point afterwards. Fix the forwarding; do '
              'not lower the flag');
    });

    test('every registered check actually started', () {
      expect(ran, allContractChecks.length,
          reason: '$ran of $registered registered cases actually ran. The '
              'difference is a case that was registered and then skipped, '
              'which the registration count cannot see: the report shows a '
              'skip reason, the suite stays green, and the property is as '
              'unjudged as it would have been with the capability off');
    });
  });
}

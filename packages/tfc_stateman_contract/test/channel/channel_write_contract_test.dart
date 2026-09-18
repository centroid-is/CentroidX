/// The write sub-suite, run across a message boundary.
///
/// The most load-bearing driver in the phase. Everything else in the suite is
/// about showing a number honestly; these eleven cases are about *changing the
/// plant*, and every one of their promises is a promise about something that
/// crosses a link:
///
///  * three outcomes stay three outcomes. A boundary that folded "nobody
///    knows" into "the device said no" would pass every case in
///    `test/write_contract_test.dart`, because in-process there is no encoding
///    to fold anything in.
///  * a link drop under an in-flight write produces `unknown`, not a throw.
///    In-process the "link" is a boolean; here it is a channel, and the write
///    is genuinely outstanding when it is cut.
///  * nothing re-sends an operator's write. The attempt counter that makes
///    this judgeable lives on the served source, so a client that helpfully
///    retried an unanswered request is counted where it happened rather than
///    where it was decided.
///
/// Getting this green now is what makes plan 02-10's truncated-write hang test
/// meaningful — a hang is only interesting against a path that otherwise
/// answers — and what gives Phase 4's `RemoteStateMan` a leg to run against
/// from its first line, including the CR-01 fix cycle.
///
/// [_readOnlyKey] is carried across from the direct driver verbatim, including
/// the reason it is a real tag name, so the read-only case *runs* here rather
/// than being skipped. A skipped case would leave the one write promise about
/// a device that refuses — the case whose real-world counterpart throws
/// `UnsupportedError` today — unjudged across a boundary, which is the leg
/// where a throw does the most damage.
@Tags(['contract'])
library;

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

/// A sensor reading on the post-freezer line: the designated read-only key.
///
/// A real one, not a synthetic name — read-only devices are why the case
/// exists (`M2400DeviceClientAdapter.write` throws `UnsupportedError` today),
/// and a temperature is the shape of thing that is genuinely never written.
const _readOnlyKey = 'ST301.CN21.SEN01.temp';

void main() {
  // What actually ran, as opposed to what was registered. A `setUp` declared
  // in the enclosing group fires once per case and never for a skipped one,
  // which makes it the only number available from inside this file that comes
  // from the test runner rather than from the code being measured — and the
  // read-only case being skipped is exactly the silent loss worth counting.
  var ran = 0;

  group('over a channel', () {
    setUp(() => ran++);
    runWriteContract(channelServedFake, readOnlyKey: _readOnlyKey);
  });

  group('the run itself', () {
    test('every write case ran, including the read-only one', () {
      expect(ran, writeChecks.length,
          reason: 'the channel-served write run executed $ran of '
              '${writeChecks.length} cases. The difference is a case nobody '
              'is running over a message boundary: `runWriteContract` skips '
              'the read-only case when no key is declared, and a skipped case '
              'leaves "a write to a read-only key is rejected, not thrown" '
              'judged in-process only — which is the leg where an '
              'UnsupportedError travelling up through a page\'s generic error '
              'handling costs the operator the one sentence they could have '
              'acted on');
    });
  });
}

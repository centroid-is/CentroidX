/// The browse sub-suite, run across a message boundary.
///
/// Six cases about navigating an address space that is no longer in this
/// process. Three of the six only mean anything once there is a boundary: a
/// `BrowseNode` that lost its `type` on the way across renders a disclosure
/// triangle next to a method, a chain that arrived reordered opens the panel
/// somewhere other than the bound tag, and a null `resolvePath` that arrived as
/// an empty list turns a stale binding into "this tag has no path" — none of
/// which an in-process run can distinguish, because in-process there is no
/// encoding to lose anything in.
///
/// The fixture is forwarded explicitly and deliberately. `runBrowseContract`
/// requires one, and the served source here is a `FakeStateMan` with the
/// default `FakeBrowse` tree behind it, so [defaultBrowseFixture] is the tree
/// this channel actually carries. Passing a different one would make every
/// case fail on the landmarks rather than on the property, and defaulting it
/// silently is what the required parameter exists to prevent.
@Tags(['contract'])
library;

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

void main() {
  // What actually ran, as opposed to what was registered — the same accounting
  // the write driver keeps, for the same reason: a `setUp` in the enclosing
  // group fires once per case and never for a skipped one, so this is the one
  // number available from inside the file that comes from the runner.
  var ran = 0;

  group('over a channel', () {
    setUp(() => ran++);
    runBrowseContract(channelServedFake, fixture: defaultBrowseFixture);
  });

  group('the run itself', () {
    test('every browse case ran', () {
      expect(ran, browseChecks.length,
          reason: 'the channel-served browse run executed $ran of '
              '${browseChecks.length} cases. The difference is a case nobody '
              'is running over a message boundary, which leaves the property '
              'it names judged in-process only — and in-process is precisely '
              'where a lost node type or a reordered chain cannot show up');
    });
  });
}

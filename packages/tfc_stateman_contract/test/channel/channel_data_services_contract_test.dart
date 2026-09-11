/// The data-services sub-suite, run across a message boundary.
///
/// Seven cases covering the two halves of what a history page is: recorded
/// samples, and the saved views that decide which of them get drawn. Both are
/// things a panel will genuinely fetch from another host, so the encodings are
/// the point — a `DateTime` that crossed as a local instant lands an operator
/// on the wrong shift, and a `double` tolerance that came back an int is a
/// weigher grading to the nearest whole gram.
///
/// `seedTimeseries` is **not** overridden here, and that is worth saying
/// because the hook exists for exactly this shape of implementation.
/// `ChannelStateMan` implements `StateManDataHarness` itself and forwards the
/// lever as a notification, so the default path — `dataHarnessOf(api)` — lands
/// on the served recorder through the channel. Passing a hook that reached
/// around to `both.served` would seed the far side without ever putting a
/// sample on the wire, which would leave the lever itself untested while
/// looking identical in the run report.
@Tags(['contract'])
library;

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

void main() {
  var ran = 0;

  group('over a channel', () {
    setUp(() => ran++);
    runDataServicesContract(channelServedFake);
  });

  group('the run itself', () {
    test('every data-services case ran', () {
      expect(ran, dataServicesChecks.length,
          reason: 'the channel-served data-services run executed $ran of '
              '${dataServicesChecks.length} cases. The difference is a case '
              'nobody is running over a message boundary, and every one of '
              'these seven is about an encoding that only exists once there '
              'is a boundary to encode for');
    });
  });
}

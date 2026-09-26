/// The subscribe sub-suite, run across a message boundary.
///
/// Same driver shape as `test/subscribe_contract_test.dart` and
/// `test/write_contract_test.dart`: build a factory, hand it to the sub-suite.
/// The difference is one word in the factory, and it is the difference the
/// whole phase is for. The direct driver proves the property holds when the
/// value is already in the same object as the check. This one proves it holds
/// when the value has to be encoded, sent, decoded and applied first — which is
/// the only version of the property `RemoteStateMan` will be able to satisfy in
/// Phase 4, and the version `LocalStateMan` will have to satisfy through a
/// gateway session in Phase 3.
///
/// No case is rewritten and no case is skipped; `lib/src/subscribe_contract.dart`
/// is untouched. That is the claim, and `channel_bite_test.dart` is what stops
/// it from being a claim about a factory that quietly hands back a local
/// object: cut the channel and these same five cases fail.
@Tags(['contract'])
library;

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

void main() {
  runSubscribeContract(channelServedFake);
}

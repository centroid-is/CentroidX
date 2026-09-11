/// The store sub-suite, run across a message boundary.
///
/// What this driver proves that `test/subscribe_contract_test.dart`'s store leg
/// does not is narrower than the subscribe one, and more load-bearing. The
/// store contract is entirely about *counts*: an unchanged value costs no
/// rebuild, a hundred-key batch carrying three real changes costs three. Both
/// of those survive a message boundary only if two separate things are true —
/// the batch is still one batch when it crosses (the served side does not fan
/// it out into a message per key), and the payload round-trips to a value that
/// is `==` to the original (or every re-delivery looks like a change).
///
/// Neither is true by construction. A serialization that dropped quality, or a
/// server that pushed per key, would pass every subscribe case in the sibling
/// driver and turn the busiest page in the plant into a slideshow. This driver
/// is where that is caught, and `test/channel/served_state_man_test.dart`
/// pins the same two facts one layer down, at the boundary, where a failure is
/// still attributable to the server rather than to the client's deduplication.
@Tags(['contract'])
library;

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

void main() {
  runStoreContract(channelServedFake);
}

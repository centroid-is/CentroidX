/// The read sub-suite, run across a message boundary.
///
/// The read contract is about arithmetic: ten cached reads cost nothing, one
/// forced read costs exactly one round trip, fifty keys cost one round trip
/// rather than fifty. `test/read_contract_test.dart` proves the reference
/// implementation does that arithmetic. What it cannot prove is that the
/// arithmetic is a property of the *source* rather than of the call being a
/// method call — in-process, `readMany` fanning out into fifty separate
/// upstream reads and `readMany` making one are the same instruction either
/// way, and the difference between them is invisible until a link is involved.
///
/// Here it is visible, and it is visible from the honest side. The round-trip
/// counter lives on the served source, so a client that quietly issued one
/// request per key would show up as fifty on a number it does not own and
/// cannot fix. That is the arrangement Phase 4 inherits, where the counter
/// genuinely will be on another host, and it is the reason this driver exists
/// a phase before there is a host.
@Tags(['contract'])
library;

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

void main() {
  runReadContract(channelServedFake);
}

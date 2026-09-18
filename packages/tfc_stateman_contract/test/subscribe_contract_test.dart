/// The contract suite run against its own reference implementation.
///
/// This is the driver every other implementation copies: build a factory, hand
/// it to the sub-suites, and the same cases that judge `FakeStateMan` here will
/// judge the server-side and client-side implementations — and, in Phase 2,
/// either of them through a fault-injection proxy — with no case rewritten.
@Tags(['contract'])
library;

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

void main() {
  runSubscribeContract(FakeStateMan.new);
  runStoreContract(FakeStateMan.new);
}

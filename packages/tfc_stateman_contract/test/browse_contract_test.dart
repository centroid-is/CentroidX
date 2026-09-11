/// The browse and data-service sub-suites run against the reference
/// implementation.
///
/// Same driver shape as `write_contract_test.dart`: build a factory, hand it to
/// each sub-suite, declare the capabilities this implementation has. The cases
/// that judge the reference source here are the ones that will judge
/// `LocalStateMan` browsing a real ST101 over OPC UA and `RemoteStateMan`
/// browsing it over the pipe, with nothing rewritten — which is the whole
/// reason the fixture and the seeding lever are *arguments* rather than
/// assumptions baked into a case.
///
/// The fixture is the default one: the reference tree is seeded with the
/// plant-realistic ids `defaultBrowseFixture` names, so the driver declares it
/// explicitly rather than relying on a default it happens to match. A gateway
/// browsing a real address space passes its own landmarks here instead.
///
/// No seeding hook is passed. The reference source answers for itself through
/// `StateManDataHarness`, which is the ordinary path; the hook exists for a
/// remote implementation whose recorder does not live in the same process as
/// the test.
@Tags(['contract'])
library;

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

void main() {
  FakeStateMan make() => FakeStateMan();

  runBrowseContract(make, fixture: defaultBrowseFixture);
  runDataServicesContract(make);
}

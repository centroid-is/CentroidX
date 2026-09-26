/// The write sub-suite run against the reference implementation.
///
/// Same driver shape as `read_contract_test.dart`: build a factory, hand it to
/// the sub-suite. The cases that judge `FakeStateMan` here are the ones that
/// will judge `LocalStateMan` and `RemoteStateMan`, and — in Phase 2 — either
/// of them through a fault-injection proxy, with nothing rewritten. That is
/// the point of the capability flags below being *arguments* rather than
/// conditions inside a case: an implementation that differs declares how, once,
/// at the point where it is registered.
///
/// No hook overrides are passed. `FakeStateMan` answers for itself through
/// `StateManWriteHarness`, which is the ordinary path; the hooks exist for a
/// remote implementation whose attempt count does not live in the same process
/// as the test.
@Tags(['contract'])
library;

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

/// A sensor reading on the post-freezer line: the designated read-only key.
///
/// A real one, not a synthetic name — read-only devices are why the case
/// exists (`M2400DeviceClientAdapter.write` throws `UnsupportedError` today),
/// and a temperature is the shape of thing that is genuinely never written.
const _readOnlyKey = 'ST301.CN21.SEN01.temp';

void main() {
  FakeStateMan make() => FakeStateMan();

  runWriteContract(make, readOnlyKey: _readOnlyKey);
}

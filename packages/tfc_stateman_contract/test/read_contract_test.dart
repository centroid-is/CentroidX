/// The read and freshness sub-suites run against the reference implementation.
///
/// Same driver shape as `subscribe_contract_test.dart`: build a factory, hand
/// it to the sub-suites. The cases that judge `FakeStateMan` here are the ones
/// that will judge the server-side and client-side implementations, and — in
/// Phase 2 — either of them through a fault-injection proxy, with nothing
/// rewritten.
///
/// The freshness cases are the only ones in the suite that spend real time:
/// they wait out a real deadline on the wall clock, because CONTEXT's
/// test-realism policy reserves injected clocks for pure state-machine unit
/// tests and a freshness watchdog is precisely the machinery a fake clock stops
/// exercising. [_staleAfter] is therefore the whole runtime budget of this
/// file, which is why it is far shorter here than the fake's own default.
@Tags(['contract'])
library;

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

/// 100 ms rather than the fake's 300 ms default.
///
/// Short enough that eight freshness cases cost well under a second, long
/// enough to sit comfortably above the sweep interval and above the scheduling
/// jitter of a loaded CI machine. The checks read it back from the harness, so
/// this number is declared once and never repeated inside a case.
const _staleAfter = Duration(milliseconds: 100);

void main() {
  FakeStateMan make() => FakeStateMan(staleAfter: _staleAfter);

  runReadContract(make);
  runFreshnessContract(make);
}

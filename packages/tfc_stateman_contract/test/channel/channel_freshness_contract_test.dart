/// The freshness sub-suite, run across a message boundary.
///
/// This is the driver the project's core value is measured by twice — values
/// are fresh or visibly stale — and crossing a channel is where the second
/// measurement earns its keep. A freshness watchdog that runs on the source
/// and never tells anybody produces a client whose store is full of confident
/// numbers nothing has confirmed for an hour, and that failure looks *exactly*
/// like a healthy one from the client's side. The direct driver cannot see it
/// at all: in-process, degrading the value and notifying the listener are the
/// same act. Over a channel they are two, and only the first of them is
/// guaranteed by the source being correct.
///
/// No deadline is declared here, and that omission is the point. Every
/// freshness case reads its budget off the harness, so this run judges the
/// channel-served source at the deadline that source declares — the reference
/// implementation's own default, unwidened. Passing a longer one to buy room
/// for the boundary is the single move that would make this harness lie in
/// precisely the way the whole project exists to prevent: a suite that grades
/// a slower pipe on a gentler curve reports "fresh" for exactly the extra
/// milliseconds it granted itself.
///
/// The absence is greppable on purpose — `grep -c` for the deadline's name
/// across `test/channel/` must return nothing — which is why the getter is
/// described here rather than named. A gate a comment can trip is a gate that
/// gets deleted the first time it fires on prose.
@Tags(['contract'])
library;

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

void main() {
  runFreshnessContract(channelServedFake);
}

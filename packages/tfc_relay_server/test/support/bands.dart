/// The timing bands every wall-clock test in this package asserts against,
/// with the argument for them in one place instead of re-derived per file.
///
/// Copied, deliberately, from `tfc_stateman_contract`'s
/// `test/faults/latency_test.dart` — same runners, same reasoning, and two
/// packages that disagree about what "on time" means would eventually
/// disagree about whether the gateway is healthy.
///
/// **Why the non-Linux band is nearly four times wider.** The Linux leg runs
/// on the runner this phase's numbers were measured on, and 20 ms is the
/// resolution that would notice a mechanism which had quietly stopped working.
/// The hosted macOS and Windows runners are neither quiet nor dedicated —
/// `dart_test.yaml`'s `concurrency: 1` removes this suite's self-inflicted
/// noise and nothing at all about a noisy neighbour — and tens of milliseconds
/// of event-loop jitter there is ordinary. At 20 ms those legs go red about
/// the runner while naming the mode under test, which is the expensive kind of
/// failure: it trains people to re-run CI until it passes, and a real
/// regression then gets re-run too.
///
/// Assert windows, not instants: `lessThan(ceiling)`, never an equality on a
/// duration.
library;

import 'dart:io';

/// How far either side of an expected instant a real event may land before the
/// test calls it wrong.
final Duration slack = Platform.isLinux
    ? const Duration(milliseconds: 20)
    : const Duration(milliseconds: 75);

/// The hard upper bound for "this must have happened by now".
final Duration ceiling = Platform.isLinux
    ? const Duration(milliseconds: 100)
    : const Duration(milliseconds: 150);

/// The platform name, for `reason:` strings that want to say which band they
/// were judged against.
final String platformName = Platform.operatingSystem;

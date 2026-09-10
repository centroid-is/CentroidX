/// The one place that decides how much slower a CI runner is allowed to be
/// than the machine these budgets were measured on.
///
/// Every `within` budget in this suite is a liveness bound — it turns a hang
/// into a named failure and does not measure latency; see `check.dart`'s
/// [budgetScale]. That makes stretching it on a slow box free of anything the
/// suite claims to provide, and the alternative is worse than free: a budget
/// that is marginal rather than generous fails cases for the runner's load and
/// reports it as whatever property the case was about.
///
/// Three cases were failing that way on the Windows agent and passing on macOS
/// and Linux — a first value over the ws leg of the parity sweep (reported as a
/// divergence between the two legs, which is the one thing that sweep exists to
/// find and the one thing that was not happening), three refused dials against
/// a dead port, and a stream completing on hang-up.
///
/// **Windows only, and by a stated factor.** Not a blanket raise: the tight
/// bound is achievable on the two platforms that achieve it, and it should keep
/// biting there. Four is the smallest round number that clears the observed
/// margin — the ws-leg first value is budgeted at 200 ms against a 50 ms
/// measured round trip — with room left for the agent being loaded rather than
/// merely slow.
library;

import 'dart:io';

import 'package:tfc_stateman_contract/tfc_stateman_contract.dart'
    show budgetScale;

/// How much longer than the measured machine this runner is allowed to take.
const double windowsRunnerFactor = 4;

/// Applies [windowsRunnerFactor] on Windows and leaves every other platform on
/// the numbers the cases were written with.
///
/// Call from `main()` before any case runs. Idempotent, so a file that is
/// loaded alongside another that also calls it is not scaled twice.
void useRunnerBudgets() {
  budgetScale = Platform.isWindows ? windowsRunnerFactor : 1;
}

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
/// **On CI, not on Windows — and that correction was itself measured.** The
/// first version of this scaled on `Platform.isWindows`, on the reasoning that
/// the tight bound is achievable on the platforms that achieve it. The macOS
/// runner then failed the ws leg of the parity sweep with the identical "did
/// not happen within 200 ms", which settles it: the discriminator was never the
/// operating system, it is whether this is the machine the numbers were
/// measured on. A hosted runner is not, on any platform.
///
/// Local runs stay on the numbers the cases were written with, so a developer
/// still sees a regression at its real size.
///
/// Four is the smallest round number that clears the observed margin — the
/// ws-leg first value is budgeted at 200 ms against a 50 ms measured round trip
/// — with room left for an agent that is loaded rather than merely slow.
///
/// **What this deliberately does not paper over.** A case that still fails with
/// the factor applied is not slow, and the message says so by naming the base
/// and the multiplier. Two were found that way and were fixed as the races they
/// were, not by raising the number again: `ws_transport`'s hang-up closed
/// nothing because the server had not registered the socket yet, and F26c
/// asserted that `Isolate.pause` takes effect at the call.
library;

import 'dart:io';

import 'package:tfc_stateman_contract/tfc_stateman_contract.dart'
    show budgetScale;

/// How much longer than the measured machine a hosted runner is allowed to
/// take.
const double hostedRunnerFactor = 4;

/// Whether this process is running on CI.
///
/// GitHub Actions sets `CI=true`, as does every other hosted runner worth
/// naming. Read as "is this the machine the budgets were measured on", which is
/// the question actually being asked.
bool get onHostedRunner => Platform.environment['CI'] == 'true';

/// Applies [hostedRunnerFactor] on a hosted runner and leaves a local run on
/// the numbers the cases were written with.
///
/// Call from `main()` before any case runs. Idempotent, so a file that is
/// loaded alongside another that also calls it is not scaled twice.
void useRunnerBudgets() {
  budgetScale = onHostedRunner ? hostedRunnerFactor : 1;
}

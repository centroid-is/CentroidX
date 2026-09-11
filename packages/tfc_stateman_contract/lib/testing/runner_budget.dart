/// The one place that decides how much slower a hosted runner may be than the
/// machine the contract's budgets were measured on.
///
/// Every budget `within` applies is a **liveness** bound — its own doc says it
/// "converts *nothing happening* into a named failure" — so stretching it on a
/// box that is not the one the numbers came from costs nothing the suite claims
/// to provide. What it buys is that a genuinely hung await still fails by name
/// instead of a healthy one failing for the runner's load.
///
/// **Why it lives here rather than in a consumer.** It started in
/// `tfc_relay_client/test/support/`, which put it out of reach of every other
/// package: another package's `test/` directory is not addressable by any
/// `package:` URI. `tfc_dart`'s `backend_contract_db_test` then failed on
/// `a downsampled series coming back did not happen within 200 ms` — the same
/// 200 ms default, on the same `within`, unscaled because the caller could not
/// see the switch. [budgetScale] is declared in `check.dart` beside `within`,
/// so the switch belongs beside it too.
///
/// `check.dart` itself is kept free of `dart:io` on purpose
/// (`channel_harness.dart:16` states the rule and greps for it), which is why
/// the platform read is here and not there.
library;

import 'dart:io';

import '../src/check.dart' show budgetScale;

/// How much longer than the measured machine a hosted runner is allowed to
/// take.
///
/// Four is the smallest round number that clears the observed margin — the
/// ws-leg first value is budgeted at 200 ms against a 50 ms measured round trip
/// — with room left for an agent that is loaded rather than merely slow.
const double hostedRunnerFactor = 4;

/// Whether this process is running on CI.
///
/// GitHub Actions sets `CI=true`, as does every other hosted runner worth
/// naming. Read as "is this the machine the budgets were measured on", which is
/// the question actually being asked — and the correction that matters: an
/// earlier version of this scaled on `Platform.isWindows`, and the macOS runner
/// then failed the parity sweep with the identical "did not happen within
/// 200 ms". The operating system was never the discriminator.
bool get onHostedRunner => Platform.environment['CI'] == 'true';

/// Applies [hostedRunnerFactor] on a hosted runner and leaves a local run on
/// the numbers the cases were written with, so a developer still sees a
/// regression at its real size.
///
/// Call from `main()` before any case runs. Idempotent.
///
/// **What this deliberately does not paper over.** A case that still fails with
/// the factor applied is not slow, and the timeout message names the base and
/// the multiplier so a reader can tell. Three were found that way and fixed as
/// the races they were rather than by raising the number again.
void useRunnerBudgets() {
  budgetScale = onHostedRunner ? hostedRunnerFactor : 1;
}

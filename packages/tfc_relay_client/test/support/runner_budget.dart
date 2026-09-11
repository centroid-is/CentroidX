/// Re-export of the contract package's runner-budget switch.
///
/// The switch itself moved to `tfc_stateman_contract/lib/testing/` once a
/// second package needed it: `budgetScale` is declared beside `within` in
/// `check.dart`, and a copy of the policy in one consumer's `test/support/`
/// was unreachable from every other package — which is exactly how
/// `tfc_dart`'s `backend_contract_db_test` ended up running the unscaled
/// 200 ms default on a hosted agent.
///
/// Kept as a file rather than deleted so the four call sites here read the same
/// as they did, and so there is one factor rather than two that can drift.
library;

export 'package:tfc_stateman_contract/testing/runner_budget.dart'
    show hostedRunnerFactor, onHostedRunner, useRunnerBudgets;

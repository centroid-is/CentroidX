#include "session_rebuild_policy.h"

#include "engine_rebuild_gate.h"
#include "test_harness.h"

namespace {

using tfc::AdapterCheck;
using tfc::SessionRebuildPolicy;
using Verdict = tfc::SessionRebuildPolicy::Verdict;

SessionRebuildPolicy::Config FastConfig() {
  SessionRebuildPolicy::Config config;
  config.reconnect_probation_ms = 15000;
  config.storm_detector_available = true;
  return config;
}

bool Mentions(const std::string& haystack, const char* needle) {
  return haystack.find(needle) != std::string::npos;
}

// A policy whose engine is up and has never seen a session change.
SessionRebuildPolicy SettledPolicy() {
  SessionRebuildPolicy policy(FastConfig());
  policy.EngineCreated(0);
  return policy;
}

// --- Disconnect -------------------------------------------------------------

TEST(a_remote_disconnect_defers_instead_of_rebuilding) {
  SessionRebuildPolicy policy = SettledPolicy();
  const SessionRebuildPolicy::Decision decision =
      policy.OnRemoteDisconnect(10000);
  CHECK(decision.verdict == Verdict::kDeferred);
  CHECK(policy.context_suspect());
  CHECK(!policy.probation_active());
  // Ticks while nobody is looking never turn into a rebuild.
  CHECK(policy.OnTick(20000).verdict == Verdict::kNone);
  CHECK(policy.OnTick(10000000).verdict == Verdict::kNone);
}

TEST(the_several_messages_one_disconnect_emits_say_it_once) {
  SessionRebuildPolicy policy = SettledPolicy();
  CHECK(policy.OnRemoteDisconnect(10000).verdict == Verdict::kDeferred);
  CHECK(policy.OnRemoteDisconnect(10100).verdict == Verdict::kNone);
  CHECK(policy.OnRemoteDisconnect(10900).verdict == Verdict::kNone);
  CHECK(policy.context_suspect());
}

// --- Connect ----------------------------------------------------------------

TEST(a_remote_connect_probes_and_a_frame_keeps_the_renderer) {
  SessionRebuildPolicy policy = SettledPolicy();
  policy.OnRemoteDisconnect(10000);

  const SessionRebuildPolicy::Decision probe =
      policy.OnRemoteConnect(50000, AdapterCheck::kSame);
  CHECK(probe.verdict == Verdict::kProbe);
  CHECK_EQ(probe.waited_ms, 15000ull);
  CHECK(policy.probation_active());

  // Still inside the probation: nothing.
  CHECK(policy.OnTick(55000).verdict == Verdict::kNone);

  const SessionRebuildPolicy::Decision kept = policy.OnFramePresented(50300);
  CHECK(kept.verdict == Verdict::kKeptRenderer);
  CHECK_EQ(kept.waited_ms, 300ull);
  CHECK(!policy.probation_active());
  CHECK(!policy.context_suspect());

  // And nothing later asks for the rebuild the old code would have done.
  CHECK(policy.OnTick(70000).verdict == Verdict::kNone);
  CHECK(policy.OnFramePresented(70000).verdict == Verdict::kNone);
}

TEST(a_remote_connect_with_no_frame_by_the_deadline_rebuilds) {
  SessionRebuildPolicy policy = SettledPolicy();
  policy.OnRemoteDisconnect(10000);
  CHECK(policy.OnRemoteConnect(50000, AdapterCheck::kSame).verdict ==
        Verdict::kProbe);

  CHECK(policy.OnTick(55000).verdict == Verdict::kNone);
  CHECK(policy.OnTick(60000).verdict == Verdict::kNone);
  CHECK(policy.OnTick(64999).verdict == Verdict::kNone);

  const SessionRebuildPolicy::Decision rebuild = policy.OnTick(65000);
  CHECK(rebuild.verdict == Verdict::kRebuildNow);
  CHECK(Mentions(rebuild.reason, "remote connect"));
  CHECK(Mentions(rebuild.reason, "no frame within"));
  CHECK_EQ(rebuild.waited_ms, 15000ull);
  CHECK(!policy.probation_active());

  // Once. The rebuild it asked for resets everything through EngineCreated.
  CHECK(policy.OnTick(70000).verdict == Verdict::kNone);
}

TEST(a_connect_that_was_never_preceded_by_a_disconnect_still_probes) {
  // The process may have started while disconnected.
  SessionRebuildPolicy policy = SettledPolicy();
  CHECK(policy.OnRemoteConnect(5000, AdapterCheck::kSame).verdict ==
        Verdict::kProbe);
}

TEST(duplicate_connect_messages_fold_into_the_open_probation) {
  SessionRebuildPolicy policy = SettledPolicy();
  CHECK(policy.OnRemoteConnect(50000, AdapterCheck::kSame).verdict ==
        Verdict::kProbe);
  CHECK(policy.OnRemoteConnect(50100, AdapterCheck::kSame).verdict ==
        Verdict::kNone);
  CHECK(policy.OnRemoteConnect(50800, AdapterCheck::kUnknown).verdict ==
        Verdict::kNone);
  // The deadline is the FIRST connect's, not the last duplicate's.
  CHECK(policy.OnTick(64999).verdict == Verdict::kNone);
  CHECK(policy.OnTick(65000).verdict == Verdict::kRebuildNow);
}

TEST(a_disconnect_during_probation_cancels_it) {
  // Connect, then drop again before the deadline: nobody is looking, so the
  // deadline must not rebuild an unattended engine.
  SessionRebuildPolicy policy = SettledPolicy();
  CHECK(policy.OnRemoteConnect(50000, AdapterCheck::kSame).verdict ==
        Verdict::kProbe);
  CHECK(policy.OnRemoteDisconnect(52000).verdict == Verdict::kDeferred);
  CHECK(!policy.probation_active());
  CHECK(policy.context_suspect());
  CHECK(policy.OnTick(65000).verdict == Verdict::kNone);
  CHECK(policy.OnTick(100000).verdict == Verdict::kNone);
  // The next connect opens a fresh probation.
  CHECK(policy.OnRemoteConnect(200000, AdapterCheck::kSame).verdict ==
        Verdict::kProbe);
}

// --- Evidence ---------------------------------------------------------------

TEST(an_adapter_that_positively_changed_rebuilds_at_once) {
  SessionRebuildPolicy policy = SettledPolicy();
  policy.OnRemoteDisconnect(10000);
  const SessionRebuildPolicy::Decision decision =
      policy.OnRemoteConnect(50000, AdapterCheck::kChanged);
  CHECK(decision.verdict == Verdict::kRebuildNow);
  CHECK(decision.adapter == AdapterCheck::kChanged);
  CHECK(Mentions(decision.reason, "render adapter changed"));
  CHECK(!policy.probation_active());
}

TEST(an_adapter_that_changes_during_probation_outranks_the_probation) {
  SessionRebuildPolicy policy = SettledPolicy();
  CHECK(policy.OnRemoteConnect(50000, AdapterCheck::kSame).verdict ==
        Verdict::kProbe);
  CHECK(policy.OnRemoteConnect(50500, AdapterCheck::kChanged).verdict ==
        Verdict::kRebuildNow);
  CHECK(!policy.probation_active());
}

TEST(an_unreadable_adapter_is_not_evidence) {
  // Measured: a third of session-change windows report no adapter at all,
  // and every one of those engines went on to draw. Unknown means probe.
  SessionRebuildPolicy policy = SettledPolicy();
  const SessionRebuildPolicy::Decision decision =
      policy.OnRemoteConnect(50000, AdapterCheck::kUnknown);
  CHECK(decision.verdict == Verdict::kProbe);
  CHECK(decision.adapter == AdapterCheck::kUnknown);
}

TEST(without_a_storm_detector_a_connect_rebuilds_as_before) {
  SessionRebuildPolicy::Config config = FastConfig();
  config.storm_detector_available = false;
  SessionRebuildPolicy policy(config);
  policy.EngineCreated(0);
  // The disconnect is still deferred: nobody is viewing.
  CHECK(policy.OnRemoteDisconnect(10000).verdict == Verdict::kDeferred);
  const SessionRebuildPolicy::Decision decision =
      policy.OnRemoteConnect(50000, AdapterCheck::kSame);
  CHECK(decision.verdict == Verdict::kRebuildNow);
  CHECK(Mentions(decision.reason, "no context-loss detector"));
}

TEST(the_detector_flag_can_be_set_after_construction) {
  SessionRebuildPolicy policy = SettledPolicy();
  policy.set_storm_detector_available(false);
  CHECK(policy.OnRemoteConnect(50000, AdapterCheck::kSame).verdict ==
        Verdict::kRebuildNow);
}

TEST(a_new_engine_clears_suspicion_and_probation) {
  SessionRebuildPolicy policy = SettledPolicy();
  policy.OnRemoteDisconnect(10000);
  policy.OnRemoteConnect(50000, AdapterCheck::kSame);
  CHECK(policy.probation_active());
  // The storm detector or the sentinel rebuilt the engine on its own.
  policy.EngineCreated(51000);
  CHECK(!policy.probation_active());
  CHECK(!policy.context_suspect());
  CHECK(policy.OnTick(70000).verdict == Verdict::kNone);
}

// --- Classification ---------------------------------------------------------

TEST(adapter_luids_classify_only_when_both_sides_are_known) {
  CHECK(tfc::ClassifyAdapterCheck(true, 42, true, 42) == AdapterCheck::kSame);
  CHECK(tfc::ClassifyAdapterCheck(true, 42, true, 43) ==
        AdapterCheck::kChanged);
  CHECK(tfc::ClassifyAdapterCheck(false, 0, true, 43) ==
        AdapterCheck::kUnknown);
  CHECK(tfc::ClassifyAdapterCheck(true, 42, false, 0) ==
        AdapterCheck::kUnknown);
  CHECK(tfc::ClassifyAdapterCheck(false, 0, false, 0) ==
        AdapterCheck::kUnknown);
}

// --- Through the gate -------------------------------------------------------

TEST(a_session_cycle_costs_at_most_one_gated_rebuild_and_usually_none) {
  // The whole path: policy decides whether to ask, gate decides when. A
  // healthy reconnect asks for nothing; a dead one asks once, and the
  // duplicate WM_WTSSESSION_CHANGE messages still collapse in the gate.
  SessionRebuildPolicy policy = SettledPolicy();
  tfc::EngineRebuildGate gate;
  gate.EngineCreated(0);
  gate.StartupComplete(1000);

  // Healthy cycle.
  CHECK(policy.OnRemoteDisconnect(10000).verdict == Verdict::kDeferred);
  CHECK(policy.OnRemoteConnect(50000, AdapterCheck::kSame).verdict ==
        Verdict::kProbe);
  CHECK(policy.OnFramePresented(50200).verdict == Verdict::kKeptRenderer);
  CHECK(!gate.has_queued_request());

  // Dead cycle: the deadline asks, the gate answers once.
  CHECK(policy.OnRemoteDisconnect(100000).verdict == Verdict::kDeferred);
  CHECK(policy.OnRemoteConnect(150000, AdapterCheck::kSame).verdict ==
        Verdict::kProbe);
  const SessionRebuildPolicy::Decision due = policy.OnTick(165000);
  CHECK(due.verdict == Verdict::kRebuildNow);
  const tfc::EngineRebuildGate::Decision first = gate.Request(due.reason, 165000);
  CHECK(first.verdict == tfc::EngineRebuildGate::Verdict::kRebuildNow);
  // A duplicate of the same event inside the debounce.
  CHECK(gate.Request(due.reason, 165100).verdict ==
        tfc::EngineRebuildGate::Verdict::kDebounced);
}

// --- Wording ----------------------------------------------------------------

TEST(the_lines_say_what_was_decided_and_why) {
  SessionRebuildPolicy policy = SettledPolicy();

  const std::string deferred =
      DescribeSessionRebuild(policy.OnRemoteDisconnect(10000));
  CHECK(Mentions(deferred, "NOT rebuilding"));
  CHECK(Mentions(deferred, "suspect"));

  CHECK(DescribeSessionRebuild(policy.OnRemoteDisconnect(10100)).empty());

  const std::string probing = DescribeSessionRebuild(
      policy.OnRemoteConnect(50000, AdapterCheck::kUnknown));
  CHECK(Mentions(probing, "PROBING"));
  CHECK(Mentions(probing, "could not be compared"));
  CHECK(Mentions(probing, "15.0 s"));

  const std::string kept = DescribeSessionRebuild(policy.OnFramePresented(50300));
  CHECK(Mentions(kept, "KEPT"));
  CHECK(Mentions(kept, "0.3 s"));

  policy.OnRemoteConnect(100000, AdapterCheck::kSame);
  const std::string rebuilt = DescribeSessionRebuild(policy.OnTick(115000));
  CHECK(Mentions(rebuilt, "REBUILDING"));
  CHECK(Mentions(rebuilt, "no frame within 15.0 s"));

  const std::string changed = DescribeSessionRebuild(
      policy.OnRemoteConnect(200000, AdapterCheck::kChanged));
  CHECK(Mentions(changed, "REBUILDING"));
  CHECK(Mentions(changed, "NO LONGER the session's display adapter"));

  CHECK(DescribeSessionRebuild(SessionRebuildPolicy::Decision()).empty());
}

}  // namespace

int main() { return tfc_test::RunAll(); }

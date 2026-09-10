#include "session_rebuild_gate.h"

#include "test_harness.h"

namespace {

using tfc::SessionRebuildGate;
using Verdict = tfc::SessionRebuildGate::Verdict;

SessionRebuildGate::Config FastConfig() {
  SessionRebuildGate::Config config;
  config.debounce_ms = 3000;
  config.startup_timeout_ms = 60000;
  return config;
}

bool Mentions(const std::string& haystack, const char* needle) {
  return haystack.find(needle) != std::string::npos;
}

// A gate whose first engine has already finished starting, which is the state
// a station spends almost all of its life in.
SessionRebuildGate SettledGate(unsigned long long now_ms) {
  SessionRebuildGate gate(FastConfig());
  gate.EngineCreated(0);
  gate.StartupComplete(now_ms);
  return gate;
}

TEST(a_session_change_on_a_settled_engine_rebuilds_immediately) {
  SessionRebuildGate gate = SettledGate(1000);
  const SessionRebuildGate::Decision decision =
      gate.Request("remote connect", 10000);
  CHECK(decision.verdict == Verdict::kRebuildNow);
  CHECK_EQ(decision.coalesced, 1u);
  CHECK(decision.reason == "remote connect");
  CHECK(!gate.has_queued_request());
}

TEST(the_several_messages_one_disconnect_emits_cost_one_rebuild) {
  SessionRebuildGate gate = SettledGate(1000);
  CHECK(gate.Request("remote disconnect", 10000).verdict ==
        Verdict::kRebuildNow);
  // Windows emits several WM_WTSSESSION_CHANGE messages for one event.
  CHECK(gate.Request("remote disconnect", 10100).verdict == Verdict::kDebounced);
  CHECK(gate.Request("remote disconnect", 11000).verdict == Verdict::kDebounced);
  CHECK(gate.Request("remote disconnect", 12999).verdict == Verdict::kDebounced);
  // Past the debounce, a genuinely new event is answered again.
  CHECK(gate.Request("remote connect", 13001).verdict == Verdict::kRebuildNow);
}

TEST(a_rebuild_never_interrupts_a_startup_that_is_still_running) {
  // This is the 2026-09-10 incident. Disconnect, rebuild, and 35 s later --
  // far outside any sane debounce -- a reconnect, while the fresh engine was
  // still bringing its OPC UA clients up.
  SessionRebuildGate gate = SettledGate(1000);

  const unsigned long long disconnect = 100000;
  CHECK(gate.Request("remote disconnect", disconnect).verdict ==
        Verdict::kRebuildNow);
  gate.EngineCreated(disconnect);

  const unsigned long long reconnect = disconnect + 35000;
  const SessionRebuildGate::Decision held =
      gate.Request("remote connect", reconnect);
  CHECK(held.verdict == Verdict::kQueued);
  CHECK(gate.has_queued_request());

  // Ticks while startup runs change nothing.
  CHECK(gate.Poll(reconnect + 1000).verdict == Verdict::kIdle);
  CHECK(gate.Poll(reconnect + 5000).verdict == Verdict::kIdle);

  // Startup finishes; now the held rebuild runs.
  const unsigned long long settled = reconnect + 10000;
  gate.StartupComplete(settled);
  const SessionRebuildGate::Decision released = gate.Poll(settled + 1);
  CHECK(released.verdict == Verdict::kRebuildNow);
  CHECK_EQ(released.coalesced, 1u);
  CHECK(released.reason == "remote connect");
  CHECK_EQ(released.waited_ms, 10001ull);
  CHECK(!released.startup_timed_out);
  CHECK(!gate.has_queued_request());

  // ...and only once.
  CHECK(gate.Poll(settled + 2).verdict == Verdict::kIdle);
}

TEST(two_rapid_session_changes_produce_at_most_one_rebuild) {
  SessionRebuildGate gate = SettledGate(1000);
  gate.EngineCreated(10000);

  const SessionRebuildGate::Decision first =
      gate.Request("remote disconnect", 20000);
  CHECK(first.verdict == Verdict::kQueued);
  const SessionRebuildGate::Decision second =
      gate.Request("remote connect", 24000);
  CHECK(second.verdict == Verdict::kCoalesced);
  CHECK_EQ(second.coalesced, 2u);

  gate.StartupComplete(30000);
  const SessionRebuildGate::Decision released = gate.Poll(30000);
  CHECK(released.verdict == Verdict::kRebuildNow);
  CHECK_EQ(released.coalesced, 2u);
  // The newest reason is the one the renderer has to end up matching.
  CHECK(released.reason == "remote connect");
  CHECK(gate.Poll(31000).verdict == Verdict::kIdle);
}

TEST(duplicates_during_a_startup_do_not_queue_a_rebuild_of_their_own) {
  SessionRebuildGate gate = SettledGate(1000);
  // A rebuild happens, then the duplicate messages for the SAME event arrive
  // while the new engine is starting. They must be debounced, not queued --
  // otherwise every rebuild would immediately schedule another one.
  CHECK(gate.Request("remote connect", 50000).verdict == Verdict::kRebuildNow);
  gate.EngineCreated(50000);
  CHECK(gate.Request("remote connect", 50100).verdict == Verdict::kDebounced);
  CHECK(gate.Request("remote connect", 51500).verdict == Verdict::kDebounced);
  CHECK(!gate.has_queued_request());
  gate.StartupComplete(60000);
  CHECK(gate.Poll(60000).verdict == Verdict::kIdle);
}

TEST(a_startup_that_never_finishes_does_not_lock_the_gate_forever) {
  // An app whose Dart side is broken must not leave a reconnected operator
  // looking at a renderer that is never rebuilt.
  SessionRebuildGate gate = SettledGate(1000);
  gate.EngineCreated(10000);
  CHECK(gate.Request("remote connect", 20000).verdict == Verdict::kQueued);

  // Inside the timeout: still waiting.
  CHECK(gate.Poll(60000).verdict == Verdict::kIdle);
  CHECK(gate.Poll(69999).verdict == Verdict::kIdle);

  // Past it: rebuild anyway, and say that is what happened.
  const SessionRebuildGate::Decision forced = gate.Poll(70001);
  CHECK(forced.verdict == Verdict::kRebuildNow);
  CHECK(forced.startup_timed_out);
}

TEST(a_request_after_the_startup_timeout_is_answered_at_once) {
  SessionRebuildGate gate = SettledGate(1000);
  gate.EngineCreated(10000);
  // Nothing asked during the startup, and it never completed. A session
  // change long afterwards must not be queued behind a startup that is never
  // going to finish.
  const SessionRebuildGate::Decision decision =
      gate.Request("remote connect", 200000);
  CHECK(decision.verdict == Verdict::kRebuildNow);
}

TEST(the_gate_is_idle_until_something_asks) {
  SessionRebuildGate gate(FastConfig());
  CHECK(gate.Poll(0).verdict == Verdict::kIdle);
  CHECK(gate.Poll(1000000).verdict == Verdict::kIdle);
  CHECK(!gate.has_queued_request());
}

TEST(the_very_first_session_change_is_not_debounced_against_nothing) {
  // last_rebuild_ms_ starts at zero; a tick count near zero right after boot
  // must not be read as "we just rebuilt".
  SessionRebuildGate gate = SettledGate(0);
  CHECK(gate.Request("remote connect", 5).verdict == Verdict::kRebuildNow);
}

TEST(the_lines_say_what_was_decided_and_why) {
  SessionRebuildGate gate = SettledGate(1000);

  const std::string immediate =
      DescribeSessionRebuild(gate.Request("remote connect", 10000));
  CHECK(Mentions(immediate, "REBUILDING"));
  CHECK(Mentions(immediate, "remote connect"));

  gate.EngineCreated(10000);
  const std::string queued =
      DescribeSessionRebuild(gate.Request("remote disconnect", 20000));
  CHECK(Mentions(queued, "QUEUED"));
  CHECK(Mentions(queued, "still starting up"));

  const std::string coalesced =
      DescribeSessionRebuild(gate.Request("remote connect", 25000));
  CHECK(Mentions(coalesced, "folded"));

  gate.StartupComplete(30000);
  const std::string released = DescribeSessionRebuild(gate.Poll(30000));
  CHECK(Mentions(released, "REBUILDING now"));
  CHECK(Mentions(released, "2 queued request(s)"));

  CHECK(DescribeSessionRebuild(gate.Poll(31000)).empty());
}

TEST(a_timed_out_startup_says_so_in_the_line) {
  SessionRebuildGate gate = SettledGate(1000);
  gate.EngineCreated(10000);
  gate.Request("remote connect", 20000);
  const std::string line = DescribeSessionRebuild(gate.Poll(200000));
  CHECK(Mentions(line, "never reported complete"));
}

}  // namespace

int main() { return tfc_test::RunAll(); }

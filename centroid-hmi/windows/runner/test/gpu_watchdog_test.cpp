// Tests for the GPU device-loss watchdog state machine.
//
// The watchdog decides *whether* the renderer is dead and *what* to do about
// it. It deliberately knows nothing about Win32 or Flutter so that the whole
// decision can be exercised here, on any platform, without a GPU — the failure
// it guards against (a VM resuming from host sleep, an RDP session swapping the
// display adapter) is not something a test can stage for real.

#include "../gpu_watchdog.h"

#include "test_harness.h"

namespace {

using tfc::GpuWatchdog;

// A fixed clock for the tests that are about the state machine rather than
// about time. The loop guard is the only rule that reads it, and it is turned
// off below for these; the tests that exercise it advance a real stamp.
constexpr unsigned long long kT = 1'000'000ULL;

GpuWatchdog::Config TestConfig() {
  GpuWatchdog::Config config;
  config.probe_interval_ms = 5000;
  config.missed_probes_before_recovery = 2;
  config.max_probe_interval_ms = 60000;
  // Never give up, so tests about probing and backoff are not cut short by the
  // give-up budget. Tests that are about giving up set this themselves.
  config.max_recovery_attempts = 0;
  // Everything below this line was written against the restart-in-place
  // behaviour, which is no longer the default -- CENTROID_GPU_ON_LOSS now
  // defaults to exiting so the loss report is the last thing in the log. Pin
  // it here so these stay tests of the restart state machine; the exit and
  // log-only paths have their own tests at the bottom of the file.
  config.on_loss = tfc::LossAction::kRestartEngine;
  // The repeat-loss guard is off for the legacy tests: they drive dozens of
  // losses through a frozen clock, which is exactly the pattern the guard
  // exists to stop. Its own tests below turn it back on and move time.
  config.max_losses_in_window = 0;
  return config;
}

}  // namespace

// --- Steady state -----------------------------------------------------------

TEST(started_arms_the_timer_and_probes_immediately) {
  GpuWatchdog watchdog(TestConfig());

  GpuWatchdog::Action action = watchdog.OnStarted(kT);

  CHECK(action.start_probe);
  CHECK(!action.restart_engine);
  CHECK_EQ(action.set_timer_ms, 5000u);
}

TEST(tick_starts_a_probe_when_none_is_outstanding) {
  GpuWatchdog watchdog(TestConfig());
  watchdog.OnStarted(kT);
  watchdog.OnFramePresented(kT);

  GpuWatchdog::Action action = watchdog.OnTick(kT);

  CHECK(action.start_probe);
  CHECK(!action.restart_engine);
}

TEST(a_presented_frame_clears_the_outstanding_probe) {
  GpuWatchdog watchdog(TestConfig());
  watchdog.OnStarted(kT);
  CHECK(watchdog.probe_outstanding());

  watchdog.OnFramePresented(kT);

  // A presented frame is the only positive proof that the renderer is alive.
  // If it does not clear the flag, every subsequent tick counts a phantom
  // miss and a perfectly healthy app drifts towards a restart.
  CHECK(!watchdog.probe_outstanding());
}

TEST(an_answered_probe_never_counts_as_missed) {
  GpuWatchdog watchdog(TestConfig());
  watchdog.OnStarted(kT);
  watchdog.OnFramePresented(kT);

  for (int i = 0; i < 100; i++) {
    GpuWatchdog::Action action = watchdog.OnTick(kT);
    CHECK(!action.restart_engine);
    // Checked every iteration, not just at the end: a miss that is counted on
    // the tick and cleared by the following frame would be invisible from
    // outside the loop, but it is exactly the bookkeeping bug that would make
    // the watchdog restart a healthy engine under a slower frame cadence.
    CHECK_EQ(watchdog.missed_probes(), 0);
    watchdog.OnFramePresented(kT);
  }

  CHECK_EQ(watchdog.missed_probes(), 0);
  CHECK_EQ(watchdog.recovery_attempts(), 0);
}

// --- Detecting a dead renderer ---------------------------------------------

TEST(one_unanswered_probe_is_not_enough_to_restart) {
  GpuWatchdog watchdog(TestConfig());
  watchdog.OnStarted(kT);  // probe outstanding, no frame answers it

  GpuWatchdog::Action action = watchdog.OnTick(kT);

  CHECK_EQ(watchdog.missed_probes(), 1);
  CHECK(!action.restart_engine);
  // Keep asking — the renderer may still come back on its own.
  CHECK(action.start_probe);
}

TEST(restarts_the_engine_after_the_configured_number_of_missed_probes) {
  GpuWatchdog watchdog(TestConfig());
  watchdog.OnStarted(kT);

  CHECK(!watchdog.OnTick(kT).restart_engine);      // missed 1
  GpuWatchdog::Action action = watchdog.OnTick(kT);  // missed 2 -> recover

  CHECK(action.restart_engine);
  CHECK_EQ(watchdog.recovery_attempts(), 1);
}

TEST(a_frame_arriving_late_cancels_the_pending_recovery) {
  GpuWatchdog watchdog(TestConfig());
  watchdog.OnStarted(kT);

  watchdog.OnTick(kT);          // missed 1
  watchdog.OnFramePresented(kT);  // renderer recovered on its own

  CHECK_EQ(watchdog.missed_probes(), 0);
  CHECK(!watchdog.OnTick(kT).restart_engine);
  CHECK_EQ(watchdog.recovery_attempts(), 0);
}

TEST(restart_treats_the_new_engine_as_probed_and_re_arms_the_count) {
  GpuWatchdog watchdog(TestConfig());
  watchdog.OnStarted(kT);
  watchdog.OnTick(kT);
  CHECK(watchdog.OnTick(kT).restart_engine);

  // Recreating the controller issues its own ForceRedraw, so the restart
  // itself counts as the next probe rather than needing a separate one.
  CHECK(watchdog.probe_outstanding());
  CHECK_EQ(watchdog.missed_probes(), 0);

  // A second restart must take another full round of missed probes.
  CHECK(!watchdog.OnTick(kT).restart_engine);
  CHECK(watchdog.OnTick(kT).restart_engine);
  CHECK_EQ(watchdog.recovery_attempts(), 2);
}

// --- Backoff ----------------------------------------------------------------

TEST(recovery_backs_off_geometrically_and_caps) {
  GpuWatchdog watchdog(TestConfig());
  watchdog.OnStarted(kT);

  const unsigned int expected[] = {5000, 10000, 20000, 40000, 60000, 60000};
  for (unsigned int want : expected) {
    GpuWatchdog::Action action;
    // Bounded: a watchdog that stops asking for restarts would otherwise spin
    // this loop forever and hang CI with no failure to read.
    int guard = 0;
    do {
      action = watchdog.OnTick(kT);
      guard++;
    } while (!action.restart_engine && guard < 100);
    CHECK(action.restart_engine);
    CHECK_EQ(action.set_timer_ms, want);
  }
}

TEST(a_healthy_frame_after_recovery_restores_the_base_interval) {
  GpuWatchdog watchdog(TestConfig());
  watchdog.OnStarted(kT);
  watchdog.OnTick(kT);
  CHECK(watchdog.OnTick(kT).restart_engine);
  CHECK_EQ(watchdog.recovery_attempts(), 1);

  GpuWatchdog::Action action = watchdog.OnFramePresented(kT);

  CHECK_EQ(watchdog.recovery_attempts(), 0);
  CHECK_EQ(action.set_timer_ms, 5000u);
}

TEST(a_healthy_frame_in_steady_state_does_not_touch_the_timer) {
  GpuWatchdog watchdog(TestConfig());
  watchdog.OnStarted(kT);

  GpuWatchdog::Action action = watchdog.OnFramePresented(kT);

  // 0 means "leave the timer alone" — re-arming it on every presented frame
  // would push the next tick out indefinitely on an animating page and the
  // watchdog would never probe.
  CHECK_EQ(action.set_timer_ms, 0u);
}

// --- Device-loss hints from window messages --------------------------------

// The test that used to stand here asserted the opposite of what the watchdog
// now does: that a hint re-arms the tick interval. That turned out to be the
// bug, not the feature -- SetTimer on an existing id restarts its countdown,
// so a burst of session-change messages postponed the judgement instead of
// hurrying it. See a_hint_no_longer_pushes_the_next_tick_out, below.

TEST(a_hint_probes_immediately) {
  GpuWatchdog watchdog(TestConfig());
  watchdog.OnStarted(kT);
  watchdog.OnFramePresented(kT);

  GpuWatchdog::Action action = watchdog.OnDeviceLossHint(kT);

  CHECK(action.start_probe);
  CHECK(!action.restart_engine);
}

TEST(a_hint_alone_never_restarts_the_engine) {
  GpuWatchdog watchdog(TestConfig());
  watchdog.OnStarted(kT);
  watchdog.OnFramePresented(kT);

  // WM_DISPLAYCHANGE fires for benign things like a resolution change. The
  // probe, not the message, decides whether anything actually broke.
  for (int i = 0; i < 50; i++) {
    CHECK(!watchdog.OnDeviceLossHint(kT).restart_engine);
    watchdog.OnFramePresented(kT);
  }
  CHECK_EQ(watchdog.recovery_attempts(), 0);
}

TEST(a_hint_does_not_reset_an_in_progress_failure_count) {
  GpuWatchdog watchdog(TestConfig());
  watchdog.OnStarted(kT);
  watchdog.OnTick(kT);  // missed 1

  watchdog.OnDeviceLossHint(kT);

  // A hint arriving while frames are already missing must not let a flood of
  // session-change messages hold the failure count at zero forever.
  CHECK_EQ(watchdog.missed_probes(), 1);
  CHECK(watchdog.OnTick(kT).restart_engine);
}

// --- Config parsing ---------------------------------------------------------

TEST(watchdog_is_enabled_unless_explicitly_switched_off) {
  CHECK(tfc::ParseWatchdogEnabled(nullptr, true));
  CHECK(tfc::ParseWatchdogEnabled("1", true));
  CHECK(tfc::ParseWatchdogEnabled("yes", true));
  CHECK(!tfc::ParseWatchdogEnabled("0", true));
  CHECK(!tfc::ParseWatchdogEnabled("false", true));
}

TEST(probe_interval_falls_back_when_absent_or_nonsensical) {
  CHECK_EQ(tfc::ParseProbeIntervalMs(nullptr, 5000), 5000u);
  CHECK_EQ(tfc::ParseProbeIntervalMs("", 5000), 5000u);
  CHECK_EQ(tfc::ParseProbeIntervalMs("banana", 5000), 5000u);
  CHECK_EQ(tfc::ParseProbeIntervalMs("-1", 5000), 5000u);
  // Below a second the probe just competes with real frames for no benefit.
  CHECK_EQ(tfc::ParseProbeIntervalMs("250", 5000), 5000u);
  CHECK_EQ(tfc::ParseProbeIntervalMs("1000", 5000), 1000u);
  CHECK_EQ(tfc::ParseProbeIntervalMs("30000", 5000), 30000u);
}

// --- Giving up --------------------------------------------------------------

TEST(stops_restarting_after_the_configured_number_of_consecutive_recoveries) {
  GpuWatchdog::Config config = TestConfig();
  config.max_recovery_attempts = 3;
  GpuWatchdog watchdog(config);
  watchdog.OnStarted(kT);

  int restarts = 0;
  for (int tick = 0; tick < 100; tick++) {
    if (watchdog.OnTick(kT).restart_engine) {
      restarts++;
    }
  }

  // Rebooting the engine forever on a GPU that is never coming back means
  // rebooting the Dart app forever: the operator gets a UI that wipes itself
  // every backoff interval instead of one that has visibly given up.
  CHECK_EQ(restarts, 3);
  CHECK(watchdog.has_given_up());
}

TEST(a_healthy_frame_makes_the_give_up_budget_whole_again) {
  GpuWatchdog::Config config = TestConfig();
  config.max_recovery_attempts = 3;
  GpuWatchdog watchdog(config);
  watchdog.OnStarted(kT);

  watchdog.OnTick(kT);
  CHECK(watchdog.OnTick(kT).restart_engine);  // recovery 1
  watchdog.OnFramePresented(kT);              // ...which worked

  // The budget is for *consecutive* failures. A device that drops out once an
  // hour must not exhaust it over a week of uptime.
  CHECK_EQ(watchdog.recovery_attempts(), 0);
  CHECK(!watchdog.has_given_up());
}

TEST(zero_max_recovery_attempts_means_never_give_up) {
  GpuWatchdog::Config config = TestConfig();
  config.max_recovery_attempts = 0;
  GpuWatchdog watchdog(config);
  watchdog.OnStarted(kT);

  int restarts = 0;
  for (int tick = 0; tick < 100; tick++) {
    if (watchdog.OnTick(kT).restart_engine) restarts++;
  }

  CHECK(restarts > 10);
  CHECK(!watchdog.has_given_up());
}

// --- Disabling --------------------------------------------------------------

TEST(a_disabled_watchdog_does_nothing_at_all) {
  GpuWatchdog watchdog(TestConfig());
  watchdog.OnStarted(kT);

  watchdog.Disable();

  // Disable is what the host reaches for when executing an action threw. If
  // any event still asked for work, the very next tick would re-enter the code
  // that just failed — and in a noexcept window proc that is a hard abort.
  GpuWatchdog::Action tick = watchdog.OnTick(kT);
  CHECK(!tick.start_probe);
  CHECK(!tick.restart_engine);
  CHECK_EQ(tick.set_timer_ms, 0u);

  GpuWatchdog::Action hint = watchdog.OnDeviceLossHint(kT);
  CHECK(!hint.start_probe);
  CHECK(!hint.restart_engine);
  CHECK_EQ(hint.set_timer_ms, 0u);

  GpuWatchdog::Action frame = watchdog.OnFramePresented(kT);
  CHECK(!frame.start_probe);
  CHECK(!frame.restart_engine);
  CHECK_EQ(frame.set_timer_ms, 0u);
}

TEST(a_disabled_watchdog_ignores_a_late_frame_even_after_a_recovery) {
  GpuWatchdog watchdog(TestConfig());
  watchdog.OnStarted(kT);
  watchdog.OnTick(kT);
  CHECK(watchdog.OnTick(kT).restart_engine);
  CHECK_EQ(watchdog.recovery_attempts(), 1);

  watchdog.Disable();

  // A frame can still land after the host has given up — the engine callback
  // is already in flight. Re-arming the timer here would resurrect a watchdog
  // that was disabled precisely because acting on it threw, sending the next
  // tick straight back into the code that aborted.
  GpuWatchdog::Action frame = watchdog.OnFramePresented(kT);
  CHECK_EQ(frame.set_timer_ms, 0u);
  CHECK(watchdog.has_given_up());
}

TEST(disabling_survives_any_number_of_missed_probes) {
  GpuWatchdog watchdog(TestConfig());
  watchdog.OnStarted(kT);
  watchdog.Disable();

  for (int tick = 0; tick < 50; tick++) {
    CHECK(!watchdog.OnTick(kT).restart_engine);
  }
}

TEST(exhausting_the_recovery_budget_exits_rather_than_going_quiet) {
  GpuWatchdog::Config config = TestConfig();
  config.max_recovery_attempts = 1;
  GpuWatchdog watchdog(config);
  watchdog.OnStarted(kT);

  watchdog.OnTick(kT);
  CHECK(watchdog.OnTick(kT).restart_engine);  // the one and only attempt
  // Still watching: the engine it just rebuilt has not been judged yet.
  CHECK(!watchdog.has_given_up());

  // That engine never presents a frame either. The budget is now spent, and
  // spending it used to mean the watchdog fell silent with a frozen screen in
  // front of the operator. It now hands the problem up instead: the process
  // ends, and whatever supervises it can do what this process cannot.
  watchdog.OnTick(kT);
  GpuWatchdog::Action action = watchdog.OnTick(kT);

  CHECK(action.exit_process);
  CHECK(!action.restart_engine);
  CHECK(action.escalation == tfc::LossEscalation::kRecoveryExhausted);
  CHECK(watchdog.has_given_up());
  CHECK(!watchdog.OnTick(kT).start_probe);
}


// --- What happens once the renderer is judged dead --------------------------

TEST(a_loss_is_reported_exactly_once_per_episode) {
  // The report replaces a flood of engine errors. Emitting it on every tick
  // would rebuild the flood in a different colour.
  GpuWatchdog::Config config = TestConfig();
  config.on_loss = tfc::LossAction::kLogOnly;
  GpuWatchdog watchdog(config);
  watchdog.OnStarted(kT);

  CHECK(!watchdog.OnTick(kT).report_loss);        // first missed probe
  CHECK(watchdog.OnTick(kT).report_loss);         // threshold reached
  CHECK(!watchdog.OnTick(kT).report_loss);        // still dead, already said so
  CHECK(!watchdog.OnTick(kT).report_loss);
  CHECK(watchdog.has_reported_loss());
}

TEST(a_recovered_renderer_re_arms_the_report) {
  // A second, later loss is a separate event and must be reported again --
  // otherwise a flapping GPU produces one line for the whole shift.
  GpuWatchdog::Config config = TestConfig();
  config.on_loss = tfc::LossAction::kLogOnly;
  GpuWatchdog watchdog(config);
  watchdog.OnStarted(kT);
  watchdog.OnTick(kT);
  CHECK(watchdog.OnTick(kT).report_loss);

  watchdog.OnFramePresented(kT);
  CHECK(!watchdog.has_reported_loss());

  // Three ticks, not two: OnFramePresented clears the outstanding probe, so
  // the first tick only re-arms one and the miss count starts from there.
  watchdog.OnTick(kT);
  watchdog.OnTick(kT);
  CHECK(watchdog.OnTick(kT).report_loss);
}

TEST(exit_mode_reports_then_asks_for_exit_and_stops) {
  GpuWatchdog::Config config = TestConfig();
  config.on_loss = tfc::LossAction::kExitProcess;
  GpuWatchdog watchdog(config);
  watchdog.OnStarted(kT);
  watchdog.OnTick(kT);

  GpuWatchdog::Action action = watchdog.OnTick(kT);
  CHECK(action.report_loss);
  CHECK(action.exit_process);
  CHECK(!action.restart_engine);

  // Disabled afterwards: a tick racing the shutdown must not ask twice.
  CHECK(watchdog.has_given_up());
  GpuWatchdog::Action after = watchdog.OnTick(kT);
  CHECK(!after.exit_process);
  CHECK(!after.report_loss);
}

TEST(log_only_mode_never_touches_the_engine) {
  GpuWatchdog::Config config = TestConfig();
  config.on_loss = tfc::LossAction::kLogOnly;
  GpuWatchdog watchdog(config);
  watchdog.OnStarted(kT);
  watchdog.OnTick(kT);

  for (int i = 0; i < 5; i++) {
    GpuWatchdog::Action action = watchdog.OnTick(kT);
    CHECK(!action.restart_engine);
    CHECK(!action.exit_process);
  }
  CHECK_EQ(watchdog.recovery_attempts(), 0);
  // Still watching, so the renderer coming back is still noticed.
  CHECK(!watchdog.has_given_up());
}

TEST(restart_mode_still_reports_the_reason_before_restarting) {
  // The report is the point of the change; restarting without one puts us back
  // where we started, with a log that says only that it happened.
  GpuWatchdog watchdog(TestConfig());  // TestConfig pins kRestartEngine
  watchdog.OnStarted(kT);
  watchdog.OnTick(kT);

  GpuWatchdog::Action action = watchdog.OnTick(kT);
  CHECK(action.report_loss);
  CHECK(action.restart_engine);
  CHECK(!action.exit_process);
}

// --- Reacting to the context loss directly ----------------------------------
//
// The regression tests for the 2026-08-31 freeze. The engine announced
// EGL_CONTEXT_LOST twice a frame for thirty-six minutes and the watchdog
// declared nothing, so the defining property of this route is that it does not
// depend on any of the machinery that was deaf.

TEST(a_reported_context_loss_is_acted_on_immediately) {
  GpuWatchdog watchdog(TestConfig());
  watchdog.OnStarted(kT);
  watchdog.OnFramePresented(kT);

  // No missed probes at all: the renderer was presenting a moment ago and the
  // probe count is zero. Waiting out two intervals to agree with the weaker
  // test would be two more intervals of a dead screen.
  CHECK_EQ(watchdog.missed_probes(), 0);
  GpuWatchdog::Action action =
      watchdog.OnRendererLost(tfc::LossCause::kContextLost, kT);

  CHECK(action.report_loss);
  CHECK(action.restart_engine);
  CHECK(action.cause == tfc::LossCause::kContextLost);
}

TEST(a_reported_context_loss_fires_even_while_frames_keep_arriving) {
  // HANDOFF.md's theory of the miss was that the surface keeps "presenting"
  // under RDP, holding the missed count at zero forever. That theory turned
  // out not to fit the evidence -- but a detector that would still be blind if
  // it were true is a detector with a known hole in it. This is that hole,
  // closed: frames arrive on every tick and the loss is still declared.
  GpuWatchdog watchdog(TestConfig());
  watchdog.OnStarted(kT);

  for (int i = 0; i < 20; i++) {
    watchdog.OnFramePresented(kT);
    CHECK(!watchdog.OnTick(kT).restart_engine);
  }
  CHECK_EQ(watchdog.missed_probes(), 0);

  GpuWatchdog::Action action =
      watchdog.OnRendererLost(tfc::LossCause::kContextLost, kT);
  CHECK(action.restart_engine);
  CHECK(action.report_loss);
}

TEST(a_wedged_platform_thread_is_its_own_cause) {
  GpuWatchdog watchdog(TestConfig());
  watchdog.OnStarted(kT);

  GpuWatchdog::Action action =
      watchdog.OnRendererLost(tfc::LossCause::kPlatformThreadWedged, kT);

  CHECK(action.report_loss);
  CHECK(action.cause == tfc::LossCause::kPlatformThreadWedged);
}

TEST(a_repeated_context_loss_inside_one_episode_reports_once) {
  // The host asks the device on every tick, so a device that stays removed
  // arrives here again and again. One freeze must not read as a thousand --
  // in the log or in the loop guard.
  GpuWatchdog::Config config = TestConfig();
  config.on_loss = tfc::LossAction::kLogOnly;
  config.max_losses_in_window = 3;
  GpuWatchdog watchdog(config);
  watchdog.OnStarted(kT);

  CHECK(watchdog.OnRendererLost(tfc::LossCause::kContextLost, kT).report_loss);
  for (int i = 0; i < 50; i++) {
    GpuWatchdog::Action action = watchdog.OnRendererLost(
        tfc::LossCause::kContextLost, kT + static_cast<unsigned long long>(i));
    CHECK(!action.report_loss);
    CHECK(!action.exit_process);
  }
  CHECK_EQ(watchdog.losses_in_window(), 1);
}

TEST(a_disabled_watchdog_ignores_a_reported_context_loss) {
  GpuWatchdog watchdog(TestConfig());
  watchdog.OnStarted(kT);
  watchdog.Disable();

  GpuWatchdog::Action action =
      watchdog.OnRendererLost(tfc::LossCause::kContextLost, kT);
  CHECK(!action.report_loss);
  CHECK(!action.restart_engine);
  CHECK(!action.exit_process);
}

// --- The loop guard ---------------------------------------------------------

TEST(recovery_that_works_but_does_not_hold_escalates_to_exit) {
  // In-place recovery is the right first move and a bad permanent state. A
  // context that dies, recovers, and dies again every couple of minutes wipes
  // the operator's screen each time; past the ceiling, hand it up.
  GpuWatchdog::Config config = TestConfig();
  config.max_losses_in_window = 3;
  config.loss_window_ms = 600000;
  GpuWatchdog watchdog(config);
  watchdog.OnStarted(0);

  unsigned long long now = 0;
  int restarts = 0;
  GpuWatchdog::Action action;
  for (int episode = 0; episode < 4; episode++) {
    now += 60000;  // a minute apart: comfortably inside the window
    action = watchdog.OnRendererLost(tfc::LossCause::kContextLost, now);
    if (action.restart_engine) {
      restarts++;
      // ...and the rebuilt engine draws, which is what makes this flapping
      // rather than one loss that was never recovered from.
      watchdog.OnFramePresented(now + 100);
    }
  }

  CHECK_EQ(restarts, 3);
  CHECK(action.exit_process);
  CHECK(!action.restart_engine);
  CHECK(action.escalation == tfc::LossEscalation::kRepeatedLosses);
  CHECK(watchdog.has_given_up());
}

TEST(losses_spread_beyond_the_window_never_escalate) {
  // A station that loses its context once a day for a year must still be
  // recovering in place on the last day. The guard is about thrash, not about
  // a lifetime total.
  GpuWatchdog::Config config = TestConfig();
  config.max_losses_in_window = 3;
  config.loss_window_ms = 600000;
  GpuWatchdog watchdog(config);
  watchdog.OnStarted(0);

  unsigned long long now = 0;
  for (int episode = 0; episode < 40; episode++) {
    now += 700000;  // comfortably outside the window
    GpuWatchdog::Action action =
        watchdog.OnRendererLost(tfc::LossCause::kContextLost, now);
    CHECK(action.restart_engine);
    CHECK(!action.exit_process);
    watchdog.OnFramePresented(now + 100);
  }
  CHECK(!watchdog.has_given_up());
  CHECK_EQ(watchdog.losses_in_window(), 1);
}

TEST(the_loop_guard_does_not_relabel_an_explicit_exit_policy) {
  // CENTROID_GPU_ON_LOSS=exit already exits on the first loss; there is
  // nothing for the guard to escalate, and it must not dress that exit up as
  // an escalation in the report.
  GpuWatchdog::Config config = TestConfig();
  config.on_loss = tfc::LossAction::kExitProcess;
  config.max_losses_in_window = 1;
  GpuWatchdog watchdog(config);
  watchdog.OnStarted(kT);

  GpuWatchdog::Action action =
      watchdog.OnRendererLost(tfc::LossCause::kContextLost, kT);
  CHECK(action.exit_process);
  CHECK(action.escalation == tfc::LossEscalation::kNone);
}

TEST(log_only_never_escalates_however_many_episodes_there_are) {
  // -DebugGpu exists so a loss can be watched without the app moving under the
  // observer. A guard that eventually exited anyway would take that away at
  // the least convenient moment.
  GpuWatchdog::Config config = TestConfig();
  config.on_loss = tfc::LossAction::kLogOnly;
  config.max_losses_in_window = 2;
  GpuWatchdog watchdog(config);
  watchdog.OnStarted(0);

  unsigned long long now = 0;
  for (int episode = 0; episode < 20; episode++) {
    now += 1000;
    GpuWatchdog::Action action =
        watchdog.OnRendererLost(tfc::LossCause::kContextLost, now);
    CHECK(!action.exit_process);
    CHECK(!action.restart_engine);
    watchdog.OnFramePresented(now + 1);
  }
  CHECK(!watchdog.has_given_up());
}

// --- Hints must not be able to defer the judgement --------------------------

TEST(a_hint_no_longer_pushes_the_next_tick_out) {
  // SetTimer on an existing id RESTARTS its countdown. The old hint handler
  // asked for exactly that on every WM_DISPLAYCHANGE and every session change
  // -- and an RDP reconnect delivers those in bursts. "Bring the probe
  // forward" was in fact "postpone the judgement, once per message". The probe
  // still fires immediately; the tick now keeps its own cadence.
  GpuWatchdog watchdog(TestConfig());
  watchdog.OnStarted(kT);
  watchdog.OnFramePresented(kT);

  GpuWatchdog::Action action = watchdog.OnDeviceLossHint(kT);

  CHECK(action.start_probe);
  CHECK_EQ(action.set_timer_ms, 0u);
}

TEST(a_storm_of_hints_cannot_hold_off_a_recovery) {
  GpuWatchdog watchdog(TestConfig());
  watchdog.OnStarted(kT);

  // A hundred hints between two ticks, which is what a reconnect looks like.
  for (int i = 0; i < 100; i++) {
    CHECK_EQ(watchdog.OnDeviceLossHint(kT).set_timer_ms, 0u);
  }

  CHECK(!watchdog.OnTick(kT).restart_engine);
  CHECK(watchdog.OnTick(kT).restart_engine);
}

// --- The default policy -----------------------------------------------------

TEST(the_default_policy_recovers_in_place) {
  // A plant HMI that kills itself twice a day leaves the same dead screen a
  // freeze does. Rebuilding the engine takes seconds and the operator gets a
  // screen back; exiting is the escalation, not the first move.
  GpuWatchdog watchdog;  // stock Config, exactly as a station runs it

  CHECK(watchdog.on_loss() == tfc::LossAction::kRestartEngine);
}

TEST(an_explicit_policy_still_wins) {
  CHECK(tfc::ParseLossAction("exit", tfc::LossAction::kRestartEngine) ==
        tfc::LossAction::kExitProcess);
  CHECK(tfc::ParseLossAction("log", tfc::LossAction::kRestartEngine) ==
        tfc::LossAction::kLogOnly);
  CHECK(tfc::ParseLossAction("restart", tfc::LossAction::kExitProcess) ==
        tfc::LossAction::kRestartEngine);
  // Unset and unrecognised both fall back, which is how a station with no
  // CENTROID_GPU_ON_LOSS at all ends up recovering in place.
  CHECK(tfc::ParseLossAction(nullptr, tfc::LossAction::kRestartEngine) ==
        tfc::LossAction::kRestartEngine);
  CHECK(tfc::ParseLossAction("banana", tfc::LossAction::kRestartEngine) ==
        tfc::LossAction::kRestartEngine);
}

// --- The judgement hold -----------------------------------------------------
//
// The 2026-09-11 08:28 recurrence: a station woke from sleep, and each
// recovery rebuild was judged 20 s later against an engine that had not yet
// reached Dart main(). Every judgement read "no frames presented", every one
// rebuilt, and every rebuild restarted the startup it had just interrupted.
// The watchdog was measuring startup latency and calling it device loss.

TEST(a_held_engine_is_probed_but_not_counted_against) {
  GpuWatchdog watchdog(TestConfig());
  watchdog.OnStarted(kT);
  watchdog.SetJudgeable(false, kT);

  for (int i = 1; i <= 10; i++) {
    const GpuWatchdog::Action action = watchdog.OnTick(kT + i * 5000);
    CHECK(action.start_probe);
    CHECK(!action.restart_engine);
    CHECK(!action.report_loss);
    CHECK_EQ(watchdog.missed_probes(), 0);
  }
  CHECK_EQ(watchdog.recovery_attempts(), 0);
}

TEST(releasing_the_hold_resumes_judgement) {
  GpuWatchdog watchdog(TestConfig());
  watchdog.OnStarted(kT);
  watchdog.SetJudgeable(false, kT);
  watchdog.OnTick(kT + 5000);
  CHECK_EQ(watchdog.missed_probes(), 0);

  // Dart main() reached: the engine can be judged again.
  watchdog.SetJudgeable(true, kT + 6000);
  watchdog.OnTick(kT + 10000);
  CHECK_EQ(watchdog.missed_probes(), 1);
  const GpuWatchdog::Action dead = watchdog.OnTick(kT + 15000);
  CHECK(dead.restart_engine);
}

TEST(re_holding_does_not_extend_the_cap) {
  // A caller that asks once per tick must not be able to hold the watchdog
  // off forever.
  GpuWatchdog::Config config = TestConfig();
  config.max_judgement_hold_ms = 20000;
  GpuWatchdog watchdog(config);
  watchdog.OnStarted(kT);

  for (int i = 0; i <= 4; i++) {
    watchdog.SetJudgeable(false, kT + i * 5000);
  }
  CHECK(!watchdog.judgement_held(kT + 20001));

  // ...and once the cap is spent, misses count again.
  watchdog.OnTick(kT + 25000);
  CHECK_EQ(watchdog.missed_probes(), 1);
}

TEST(an_expired_hold_is_reported_once) {
  GpuWatchdog::Config config = TestConfig();
  config.max_judgement_hold_ms = 10000;
  GpuWatchdog watchdog(config);
  watchdog.OnStarted(kT);
  watchdog.SetJudgeable(false, kT);

  CHECK(!watchdog.ConsumeJudgementHoldExpired());
  watchdog.OnTick(kT + 5000);
  CHECK(!watchdog.ConsumeJudgementHoldExpired());

  watchdog.OnTick(kT + 15000);
  CHECK(watchdog.ConsumeJudgementHoldExpired());
  CHECK(!watchdog.ConsumeJudgementHoldExpired());
}

TEST(a_hold_that_expired_can_be_opened_again) {
  GpuWatchdog::Config config = TestConfig();
  config.max_judgement_hold_ms = 10000;
  GpuWatchdog watchdog(config);
  watchdog.OnStarted(kT);
  watchdog.SetJudgeable(false, kT);
  watchdog.OnTick(kT + 15000);
  CHECK(watchdog.ConsumeJudgementHoldExpired());

  // A later rebuild starts a fresh engine, which deserves its own grace
  // rather than inheriting the spent one.
  watchdog.SetJudgeable(false, kT + 20000);
  CHECK(watchdog.judgement_held(kT + 25000));
}

TEST(a_presented_frame_ends_a_hold_whatever_the_host_believed) {
  GpuWatchdog watchdog(TestConfig());
  watchdog.OnStarted(kT);
  watchdog.SetJudgeable(false, kT);
  watchdog.OnFramePresented(kT + 1000);

  CHECK(!watchdog.judgement_held(kT + 2000));
  // The frame also consumed the outstanding probe, so the tick that re-arms
  // it counts nothing; the two after it are the ones that judge.
  watchdog.OnTick(kT + 5000);
  CHECK_EQ(watchdog.missed_probes(), 0);
  watchdog.OnTick(kT + 10000);
  CHECK_EQ(watchdog.missed_probes(), 1);
  CHECK(watchdog.OnTick(kT + 15000).restart_engine);
}

TEST(a_hold_does_not_suppress_a_positively_reported_loss) {
  // The hold exists because ABSENCE is unreadable during a startup. A device
  // that reports itself removed is not absence.
  GpuWatchdog watchdog(TestConfig());
  watchdog.OnStarted(kT);
  watchdog.SetJudgeable(false, kT);

  const GpuWatchdog::Action action =
      watchdog.OnRendererLost(tfc::LossCause::kContextLost, kT + 1000);
  CHECK(action.restart_engine);
  CHECK(action.report_loss);
}

TEST(the_wake_from_sleep_loop_does_not_happen_any_more) {
  // The recurrence itself, at the cadence the log recorded: rebuild, two
  // ticks at the backed-off 10 s interval, judged dead, rebuild again.
  // Replayed with the host holding judgement because Dart main() was never
  // seen -- which is exactly what the [engine] line said.
  GpuWatchdog::Config config = TestConfig();
  config.max_recovery_attempts = 5;
  GpuWatchdog watchdog(config);
  watchdog.OnStarted(kT);

  unsigned long long now = kT;
  for (int rebuild = 0; rebuild < 6; rebuild++) {
    watchdog.SetJudgeable(false, now);
    for (int tick = 0; tick < 2; tick++) {
      now += 10000;
      const GpuWatchdog::Action action = watchdog.OnTick(now);
      CHECK(!action.restart_engine);
      CHECK(!action.exit_process);
    }
  }
  CHECK_EQ(watchdog.recovery_attempts(), 0);
}

int main() {
  std::printf("gpu_watchdog_test\n");
  return tfc_test::RunAll();
}
#ifndef RUNNER_GPU_WATCHDOG_H_
#define RUNNER_GPU_WATCHDOG_H_

#include "gpu_diagnosis.h"

// GPU device-loss watchdog.
//
// The problem, as it appears in the logs:
//
//   [ERROR:...egl/egl.cc(57)] EGL Error: Context Lost (12302) in .../context.cc
//   [ERROR:...gpu_surface_gl_skia.cc(220)] Could not make the context current
//                                          to acquire the frame.
//
// repeating forever, with the process alive but the window frozen on its last
// frame. It means the D3D11 device ANGLE renders through was destroyed under
// it. In a VM that happens when the host sleeps and the virtual GPU resets,
// when an RDP session connects or disconnects and Windows swaps the session's
// display adapter, or when the graphics driver resets (TDR).
//
// Recovering requires rebuilding the EGL display, context and surface plus
// Skia's GrDirectContext. The Flutter Windows embedder does not do that -- it
// retries eglMakeCurrent every frame and fails every frame. Those sources ship
// as a prebuilt flutter_windows.dll, so we cannot fix it there without forking
// the engine. What the runner *can* do is destroy and recreate
// FlutterViewController: that runs egl::Manager's destructor (eglTerminate,
// releasing the dead device) and then its constructor (eglInitialize, creating
// a fresh one). The Dart VM restarts with it, so the app reboots -- which for a
// 24/7 HMI beats a permanently frozen screen.
//
// --- Why this was rewritten (2026-08-31) -----------------------------------
//
// The first version inferred death from the ABSENCE of frames: probe by asking
// the engine for one (ForceRedraw + the next-frame callback), and after two
// unanswered probes call it dead. On 2026-08-31 a station froze at 19:47 and
// was still frozen, still logging, thirty-six minutes later, with the default
// exit-on-loss policy in force. The watchdog never declared anything.
//
// Two properties of that inference turned out to be wrong:
//
//  1. ABSENCE IS NOT OBSERVABLE FROM A STARVED TIMER. The tick was a WM_TIMER
//     on the host window. WM_TIMER is the lowest-priority message there is:
//     GetMessage synthesises it only when no other message is waiting. A lost
//     context makes every frame fail in microseconds and immediately reschedule,
//     so the platform thread's posted-message queue never empties and the tick
//     is never generated. The failure that the watchdog exists to catch is
//     precisely the failure that silences it. (SendMessage jumps that queue,
//     which is why the frozen process still answered WM_NULL in 10 ms and
//     looked "responding" throughout -- and why the host now drives this class
//     from a timer-queue thread and marshals with SendMessageTimeout.)
//
//  2. ABSENCE IS THE SYMPTOM, NOT THE CONDITION. The engine knows the context
//     is lost -- it says so, twice a frame. Waiting to notice that frames
//     stopped is a slower and strictly weaker test than asking the device. So
//     OnRendererLost() now exists: a POSITIVE report that the context is gone,
//     which declares the loss immediately instead of waiting out a famine.
//     The probe survives as the backstop for losses no device query catches.
//
// This class owns only the decision: is the renderer dead, and what should the
// host do about it. It is deliberately free of Win32 and Flutter types so the
// decision can be unit tested without a GPU -- see test/gpu_watchdog_test.cpp.
// FlutterWindow is the adapter that feeds it events and executes its actions.
//
// Every entry point takes the host's monotonic clock in milliseconds. The
// watchdog never reads a clock itself: the repeat-loss guard needs one, and a
// class that cannot be run at a thousand times speed in a test is a class
// whose escalation rules never get tested.

namespace tfc {

class GpuWatchdog {
 public:
  struct Config {
    // How often to probe, and how long an unanswered probe is given.
    unsigned int probe_interval_ms = 5000;

    // Consecutive unanswered probes before the renderer is judged dead. At the
    // default interval that is ~10s of no presented frame: long enough not to
    // trip on one slow frame, short enough that an operator is not left
    // staring at a stale screen.
    int missed_probes_before_recovery = 2;

    // Ceiling for the post-recovery backoff, so a GPU that never comes back is
    // retried slowly instead of rebooting the engine every few seconds.
    unsigned int max_probe_interval_ms = 60000;

    // What to do once the renderer is judged dead. The diagnosis in
    // gpu_diagnosis.h is written either way; this is only about what happens
    // after it. See CENTROID_GPU_ON_LOSS in flutter_window.cpp.
    //
    // The default is to rebuild the engine in place. It used to be to end the
    // process, on the reasoning that the report should be the last thing in
    // the log and a supervisor should do the restarting. On a plant HMI that
    // trade is a bad one: a station that kills itself twice a day leaves the
    // same dead screen a freeze does, for as long as it takes something else
    // to notice. Rebuilding the engine takes seconds and the operator gets a
    // screen back. Exiting remains the escalation -- see max_recovery_attempts
    // and max_losses_in_window below -- rather than the first move.
    LossAction on_loss = LossAction::kRestartEngine;

    // Consecutive failed recoveries before the watchdog stops rebuilding the
    // engine and ends the process instead. Restarting the engine restarts the
    // Dart app with it, so a GPU that is never coming back would otherwise
    // wipe the operator's UI on every backoff interval, forever. Handing the
    // problem to whatever supervises the process -- which can do things this
    // process cannot, like waiting for the driver or rebooting -- is the
    // better end of that road. 0 means never escalate.
    int max_recovery_attempts = 5;

    // --- The loop guard ---------------------------------------------------
    //
    // Recovery that works is the point. Recovery that works, breaks, works,
    // breaks is thrash: the operator's screen wipes every couple of minutes
    // and no shift can be run against it. So separately from consecutive
    // FAILED recoveries, count SUCCESSFUL ones: more than |max_losses_in_window|
    // distinct loss episodes inside |loss_window_ms| means in-place recovery
    // is not holding, and the process exits so something above it can act.
    unsigned long long loss_window_ms = 600000;  // 10 minutes
    int max_losses_in_window = 3;

    // --- The judgement hold -----------------------------------------------
    //
    // Longest the host may keep the watchdog from judging (see SetJudgeable).
    // A backstop against a host bug, NOT the primary bound: the rebuild gate
    // releases a queued rebuild after its own, shorter timeout, so in normal
    // operation this never expires. If it does, judging resumes and says so,
    // because a watchdog that can be silenced indefinitely by the code it
    // watches is the 2026-08-31 failure with extra steps.
    unsigned long long max_judgement_hold_ms = 240000;  // 4 minutes
  };

  // What the host should do in response to an event.
  struct Action {
    // Call ForceRedraw and re-arm the next-frame callback.
    bool start_probe = false;

    // Gather the evidence and write the device-loss report. Set once per
    // episode, not once per tick: the whole point is to replace a flood of
    // engine errors with one block that says why.
    bool report_loss = false;

    // End the process, after the report has been written and flushed.
    bool exit_process = false;

    // Destroy and recreate the FlutterViewController.
    bool restart_engine = false;

    // Re-arm the tick timer with this period. 0 means "leave it alone".
    unsigned int set_timer_ms = 0;

    // Why the renderer was judged dead, for the report and the log. Only
    // meaningful on an action that reports, restarts or exits.
    LossCause cause = LossCause::kNoFramesPresented;

    // Set when this action is an ESCALATION: the configured on_loss was to
    // recover in place, and the watchdog overrode it and asked to exit
    // because recovery is not holding. Purely so the log can say which of the
    // two guards fired rather than leaving an unexplained exit in a run
    // configured to restart.
    LossEscalation escalation = LossEscalation::kNone;
  };

  // Two overloads rather than a defaulted argument: `Config()` cannot be named
  // as a default argument inside the class that encloses Config.
  GpuWatchdog();
  explicit GpuWatchdog(Config config);

  // The engine is up; begin watching.
  Action OnStarted(unsigned long long now_ms);

  // The tick timer fired: judge the outstanding probe, then start a new one.
  Action OnTick(unsigned long long now_ms);

  // The engine presented a frame -- the only positive proof of a live renderer.
  Action OnFramePresented(unsigned long long now_ms);

  // A window message arrived that commonly accompanies device loss (power
  // resume, display change, session change). This only brings the next probe
  // forward; the probe still decides whether anything actually broke, so a
  // benign resolution change cannot reboot the engine on its own.
  Action OnDeviceLossHint(unsigned long long now_ms);

  // Something positively established that the render context is gone -- the
  // D3D11 device ANGLE renders through reports itself removed, or the host
  // could not reach the platform thread at all. Unlike a missed probe this is
  // not an inference from silence, so it declares the loss on the spot: there
  // is nothing a second opinion could add, and every extra interval spent
  // confirming it is an interval the operator spends in front of a dead
  // screen.
  Action OnRendererLost(LossCause cause, unsigned long long now_ms);

  // Whether the absence of frames means anything right now.
  //
  // Set false by the host while a freshly created engine has not yet reached
  // Dart main(), and while a rebuild is already queued waiting for a startup
  // to finish. In both cases "no frames presented" measures something other
  // than a lost device, and acting on it is actively harmful:
  //
  // On 2026-09-11 08:28 a station woke from sleep, and each recovery rebuild
  // was judged 20 s later -- two ticks at the backed-off interval -- against
  // an engine that had not yet run main() at all. Every judgement said "no
  // frames presented", every one rebuilt, and every rebuild restarted the
  // startup it had just interrupted. Three attempts in, the tick period had
  // backed off to 20 s, the app had never started, and it never recovered:
  // an operator had to restart it. The watchdog was measuring startup latency
  // and calling it device loss.
  //
  // Idempotent: holding while already held does NOT restart the cap clock, so
  // a repeated call cannot extend the hold indefinitely.
  //
  // Deliberately does not touch OnRendererLost. A device that positively
  // reports itself removed is evidence, not an inference from silence, and it
  // is true whether or not the app has finished starting.
  void SetJudgeable(bool judgeable, unsigned long long now_ms);

  // True while the host has asked for judgement to be held AND the cap has
  // not run out. Exposed so the tick log can say why a probe went unjudged
  // rather than leaving a reader to wonder why the count is not moving.
  bool judgement_held(unsigned long long now_ms) const;

  // True exactly once, on the first tick after a hold outlived its cap, so
  // the host can say so without keeping a latch of its own. A hold that
  // expires means the app never became judgeable -- worth a line, because it
  // is the state in which this class resumes rebuilding an engine that may
  // simply be slow.
  bool ConsumeJudgementHoldExpired();

  // Stop watching, permanently. The host calls this when carrying out an
  // action threw: the window procedure that drives the watchdog is noexcept,
  // so an exception escaping it aborts the process. Failing safe here costs
  // the recovery feature and leaves the app exactly as it behaved before the
  // watchdog existed.
  void Disable();

  // True once the watchdog has stopped acting, whether from Disable() or from
  // exhausting max_recovery_attempts.
  bool has_given_up() const { return disabled_; }

  // True once this loss episode has been reported, so kLogOnly does not write
  // the same block on every tick. Cleared when a frame is presented again.
  bool has_reported_loss() const { return reported_loss_; }

  // The resolved CENTROID_GPU_ON_LOSS, so the host can name it in the log
  // without re-reading the environment.
  LossAction on_loss() const { return config_.on_loss; }

  int missed_probes() const { return missed_probes_; }
  int missed_probes_before_recovery() const {
    return config_.missed_probes_before_recovery;
  }
  int recovery_attempts() const { return recovery_attempts_; }
  bool probe_outstanding() const { return probe_outstanding_; }
  // Loss episodes counted inside the current loop-guard window.
  int losses_in_window() const { return losses_in_window_; }
  int max_losses_in_window() const { return config_.max_losses_in_window; }

 private:
  // Period to wait before judging the engine we just restarted.
  unsigned int BackoffMs() const;

  // The single place a loss becomes an Action, whether it was inferred from
  // missed probes or reported outright. Having one body means the escalation
  // rules cannot apply to one route and not the other -- which is exactly the
  // kind of asymmetry that let the previous version fail silently.
  Action DeclareLoss(LossCause cause, unsigned long long now_ms);

  Config config_;
  bool disabled_ = false;
  bool probe_outstanding_ = false;
  bool reported_loss_ = false;
  int missed_probes_ = 0;
  int recovery_attempts_ = 0;

  // Loop guard state: when the current counting window opened, and how many
  // distinct loss episodes have been declared inside it.
  unsigned long long loss_window_start_ms_ = 0;
  int losses_in_window_ = 0;
  bool window_open_ = false;

  // Judgement hold: whether the host has asked for it, and when it began.
  bool judgement_holding_ = false;
  unsigned long long judgement_hold_since_ms_ = 0;
  // Latched once a hold outlives its cap, so the host can say so exactly once.
  bool judgement_hold_expired_ = false;
};

// Parses CENTROID_GPU_WATCHDOG. Returns |fallback| when unset or unrecognised.
bool ParseWatchdogEnabled(const char* raw, bool fallback);

// Parses CENTROID_GPU_WATCHDOG_INTERVAL_MS. Returns |fallback| when unset,
// malformed, or below the one-second floor.
unsigned int ParseProbeIntervalMs(const char* raw, unsigned int fallback);

}  // namespace tfc

#endif  // RUNNER_GPU_WATCHDOG_H_

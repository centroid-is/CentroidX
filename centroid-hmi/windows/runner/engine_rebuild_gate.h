#ifndef RUNNER_ENGINE_REBUILD_GATE_H_
#define RUNNER_ENGINE_REBUILD_GATE_H_

#include <string>

// Decides WHEN the Flutter engine may be rebuilt, whatever asked for it.
//
// # The bug this exists to fix
//
// Rebuilding the engine is not a re-render. `DestroyController()` shuts the
// Dart isolate down and `CreateController()` starts a fresh one, so every
// rebuild is a whole new `main()` and everything the previous isolate had
// opened -- OPC UA clients above all -- is abandoned wherever it happened to
// be.
//
// On 2026-09-10 a station took an RDP disconnect at 15:55:04 and a reconnect
// 35 seconds later. The second rebuild landed on an engine that was still
// starting: at 15:55:37.938 the new isolate was on "ST101.PSU attempt 2" and
// still emitting `Subscribed` lines. Its half-built OPC UA clients were
// orphaned, and the wedged process was measured afterwards holding 124 sockets
// / 64 established / 7 CLOSE_WAIT against a healthy 56 / 31 / 0 -- the 7
// CLOSE_WAIT being exactly one abandoned generation's worth, on seven
// consecutive ephemeral ports, with no worker thread left alive to close them.
//
// The guard that was supposed to prevent this was a 3000 ms debounce. A
// debounce answers a different question: it collapses the several
// WM_WTSSESSION_CHANGE messages that ONE disconnect emits within a second. It
// cannot collapse a disconnect and a reconnect 35 seconds apart, and no amount
// of lengthening it would -- a longer debounce would just start dropping
// rebuilds that are genuinely needed. The healthy two-day run in the same
// archive had four rebuilds spaced 20+ minutes apart and never froze; the
// spacing was never the variable that mattered.
//
// So the guard here is a STATE gate, not a longer timer. A rebuild may not run
// while a previous engine's startup is still in flight. One that arrives
// during a startup is queued and coalesced -- however many arrive, at most one
// rebuild runs after startup finishes -- and the debounce is kept alongside it
// for the duplicates it was always good at.
//
// # Why every trigger goes through here, not just session changes
//
// The first version of this guarded the session-change path only. On
// 2026-09-11 08:28 a station woke from sleep and the SAME fault arrived by the
// other road:
//
//   08:28:30.579 RECOVERING in place: no frames presented ... attempt 3
//   08:28:30.580 [engine] epoch 3 STOPPING after 20.3 s, reason=gpu loss
//                recovery; Dart main() was NEVER seen, app startup was STILL
//                IN FLIGHT -- this teardown interrupts it.
//
// The GPU watchdog'"'"'s own recovery path tore down a startup that had not even
// reached main(), and did it three times, backing its tick off 5 s -> 10 s ->
// 20 s while the app never started. It did not self-recover; an operator had
// to restart it.
//
// A guard that covers one of two callers of DestroyController is not a guard.
// Every rebuild request -- session change, GPU-loss recovery, power resume --
// is asked here, and the reason string is the only thing that differs.
//
// Note what this gate does NOT fix about that recurrence: it stops the
// teardown, but the watchdog would go on declaring a fresh loss every couple
// of ticks while the rebuild sat queued, and `recovery_attempts_` would climb
// to the escalation limit. The other half of the fix lives in
// GpuWatchdog::SetJudgeable -- an engine that has not started cannot be
// judged by the absence of frames.
//
// "Startup finished" is reported by the app itself over the runner channel
// (see dart_liveness.h and lib/core/runner_liveness.dart) once its OPC UA
// clients have settled, because that is the work the interrupted teardown
// interrupted. A backstop timeout covers an app whose startup never completes,
// so that a station whose Dart side is broken still gets its renderer rebuilt
// rather than being locked out of one forever by the gate.
//
// Pure logic, no I/O and no Windows headers, so all of the above is testable
// the same way GpuWatchdog's and DartLiveness's decisions are.

namespace tfc {

class EngineRebuildGate {
 public:
  struct Config {
    // One disconnect or reconnect emits several WM_WTSSESSION_CHANGE messages
    // within a second or so. One rebuild answers all of them. Unchanged from
    // the value this replaced -- the debounce was never the broken part.
    unsigned long long debounce_ms = 3000;
    // How long a startup may be "in flight" before the gate stops waiting for
    // it. Generous, because the thing being waited for is a full OPC UA
    // bring-up across every endpoint on a plant network, and cutting it short
    // reintroduces exactly the interrupted teardown this exists to prevent.
    // Bounded, because an app that never reports completion must not leave a
    // remote session permanently without a working renderer.
    unsigned long long startup_timeout_ms = 180000;
  };

  enum class Verdict {
    // Nothing to do.
    kIdle,
    // Rebuild now. |coalesced| says how many requests this one answers.
    kRebuildNow,
    // Startup is in flight; the request is held and will be answered later.
    kQueued,
    // A request was already queued; this one folded into it.
    kCoalesced,
    // Within the debounce of the last rebuild: a duplicate of one the runner
    // has already acted on.
    kDebounced,
  };

  struct Decision {
    Verdict verdict = Verdict::kIdle;
    // Requests answered by this rebuild, including the one that triggered it.
    // 1 for an ordinary immediate rebuild.
    unsigned int coalesced = 0;
    // The reason of the most recent request, for the log line.
    std::string reason;
    // For a rebuild released from the queue: how long it waited.
    unsigned long long waited_ms = 0;
    // True when the gate gave up waiting for a startup that never completed.
    bool startup_timed_out = false;
  };

  EngineRebuildGate() : EngineRebuildGate(Config()) {}
  explicit EngineRebuildGate(Config config) : config_(config) {}

  // A new engine has been created; its startup is in flight from here.
  void EngineCreated(unsigned long long now_ms);

  // The app reported that it has finished starting up.
  void StartupComplete(unsigned long long now_ms);

  // A session change asks for a rebuild.
  Decision Request(const std::string& reason, unsigned long long now_ms);

  // Asked on every watchdog tick: has a queued rebuild become due?
  Decision Poll(unsigned long long now_ms);

  bool startup_in_flight() const { return startup_in_flight_; }
  bool has_queued_request() const { return queued_; }
  unsigned int queued_count() const { return queued_count_; }

 private:
  // Whether a startup is in flight *and* still within its timeout.
  bool StartupBlocking(unsigned long long now_ms) const;
  Decision Release(unsigned long long now_ms);

  Config config_;
  bool startup_in_flight_ = false;
  unsigned long long startup_started_ms_ = 0;
  unsigned long long last_rebuild_ms_ = 0;
  bool ever_rebuilt_ = false;

  bool queued_ = false;
  unsigned int queued_count_ = 0;
  unsigned long long queued_since_ms_ = 0;
  std::string queued_reason_;
};

// The log line for a decision, or an empty string when there is nothing to
// say. Beside the state machine so the wording is testable.
std::string DescribeEngineRebuild(const EngineRebuildGate::Decision& decision);

}  // namespace tfc

#endif  // RUNNER_ENGINE_REBUILD_GATE_H_

#ifndef RUNNER_SESSION_REBUILD_POLICY_H_
#define RUNNER_SESSION_REBUILD_POLICY_H_

#include <string>

// Decides WHETHER an RDP session change should rebuild the engine at all.
// EngineRebuildGate decides WHEN a rebuild that was asked for may run; this
// class decides whether to ask.
//
// # What a rebuild costs
//
// Destroying the FlutterViewController shuts the Dart isolate down and starts
// a new one: every pending proposal the operator had not decided on, every
// page they had navigated to, every dialog they had open is gone, and the
// native process's uptime hides that it happened. The app now persists the
// first two (lib/core/pending_proposals_store.dart, lib/core/last_route.dart)
// so a rebuild is survivable -- but survivable is not free, and until this
// class existed every RDP session cycle paid for it TWICE: once on the
// disconnect and once on the reconnect, both on speculation.
//
// # What the log actually shows
//
// The speculation was that a session change swaps the session's display
// adapter out from under ANGLE. Twelve session-change rebuilds in this
// machine's own hmi-runner.log say otherwise:
//
//   * the engine's reported adapter (FlutterDesktopEngineGetGraphicsAdapter)
//     was the same vendor/device id on every engine built while disconnected
//     as on every engine built while connected -- the adapter never moved;
//   * in four of the twelve, asked a fraction of a second after the session
//     change, the engine reported NO adapter at all, and each of those engines
//     went on to present frames normally -- so that query is unreliable in
//     exactly the window this class cares about, and its silence is not
//     evidence of anything;
//   * the frame probe was answered every five seconds through an entire
//     overnight disconnect (23:56 to 06:59) -- frames "flow" while nobody is
//     looking, so "no frames while disconnected" is not the state to react
//     to either;
//   * the sentinel D3D11 device never once reported itself removed across a
//     session change.
//
// The one genuine loss on record (2026-09-01: disconnect at 18:09:57, context
// lost at 18:18:08, 283,525 "could not make the context current" lines over
// 89 minutes while every probe still answered) is now caught by the stderr
// storm detector (egl_storm_detector.h), which did not exist when the
// unconditional rebuilds were added to stand in for it.
//
// # The policy
//
//   WTS_REMOTE_DISCONNECT   Nobody is viewing the session and nothing is
//                           expected of the renderer. Do NOT rebuild: mark the
//                           context suspect and let the next connect decide.
//                           The sentinel and the storm detector stay armed --
//                           a loss that is positively observed while
//                           disconnected is still recovered, through the
//                           watchdog's own path -- and the queue and the route
//                           survive that recovery now.
//
//   WTS_REMOTE_CONNECT      Somebody is looking. Probe first: arm the frame
//                           probe and open a bounded probation. A frame inside
//                           it keeps the renderer. No frame by the deadline
//                           rebuilds it. An adapter that positively differs
//                           from the one the engine was built on rebuilds at
//                           once -- that is evidence, not speculation -- and an
//                           adapter that cannot be read is treated as unknown,
//                           per the measurement above. Without a storm
//                           detector the connect rebuilds outright, because
//                           then the probe really is the only detector for
//                           the 2026-09-01 class and it is blind to it.
//
// The probation deadline is a backstop for a renderer that stops answering
// altogether (engines that never present -- the 2026-09-10 19:45 loop). It
// is NOT the detector for a lost context: the next-frame callback is answered
// whether or not rasterisation succeeded, so a dead context ends probation
// "healthy" too. The storm detector is what catches that, within its own
// window, and its rebuild goes through the same gate. That division is
// deliberate and this header is where it is written down.
//
// Duplicates: Windows emits several WM_WTSSESSION_CHANGE messages per event.
// A disconnect on an already-suspect context and a connect during an open
// probation are silent no-ops here, and the rebuild this class eventually
// asks for is still debounced by EngineRebuildGate like every other request.
//
// Pure logic, no Windows headers, so every branch above is tested in
// test/session_rebuild_policy_test.cpp.

namespace tfc {

// Whether the adapter the engine renders on is still the adapter the session
// displays on, from two LUIDs the host reads.
enum class AdapterCheck {
  // One side could not be read. Not evidence either way.
  kUnknown,
  kSame,
  kChanged,
};

AdapterCheck ClassifyAdapterCheck(bool engine_known,
                                  unsigned long long engine_luid,
                                  bool current_known,
                                  unsigned long long current_luid);

const char* DescribeAdapterCheck(AdapterCheck check);

class SessionRebuildPolicy {
 public:
  struct Config {
    // How long a reconnected renderer is given to present a frame. Three
    // probe intervals: one slow frame must not cost a rebuild, and an
    // operator who has just connected should not wait longer than that for
    // a screen that is never coming.
    unsigned long long reconnect_probation_ms = 15000;
    // Whether the host has a detector for the loss the probe cannot see.
    // False makes a connect rebuild unconditionally, as it did before.
    bool storm_detector_available = true;
  };

  enum class Verdict {
    // Nothing to do or say.
    kNone,
    // Disconnect: rebuild deferred, context marked suspect.
    kDeferred,
    // Connect: probation opened, arm the probe.
    kProbe,
    // A frame arrived inside the probation: the renderer is kept.
    kKeptRenderer,
    // Rebuild, for |reason|.
    kRebuildNow,
  };

  struct Decision {
    Verdict verdict = Verdict::kNone;
    // For kRebuildNow: the reason handed to EngineRebuildGate.
    std::string reason;
    // What the adapter comparison said, when a connect was decided.
    AdapterCheck adapter = AdapterCheck::kUnknown;
    // kProbe: the probation length. kKeptRenderer: how long after the connect
    // the frame came. kRebuildNow from a tick: how long was waited.
    unsigned long long waited_ms = 0;
  };

  SessionRebuildPolicy() : SessionRebuildPolicy(Config()) {}
  explicit SessionRebuildPolicy(Config config) : config_(config) {}

  void set_storm_detector_available(bool available) {
    config_.storm_detector_available = available;
  }

  // A new engine exists -- whoever built it. Nothing is suspect any more.
  void EngineCreated(unsigned long long now_ms);

  Decision OnRemoteDisconnect(unsigned long long now_ms);
  Decision OnRemoteConnect(unsigned long long now_ms, AdapterCheck adapter);
  Decision OnFramePresented(unsigned long long now_ms);
  // Asked on every watchdog tick: has a probation run out?
  Decision OnTick(unsigned long long now_ms);

  bool context_suspect() const { return suspect_; }
  bool probation_active() const { return probation_; }

 private:
  Config config_;
  bool suspect_ = false;
  bool probation_ = false;
  unsigned long long probation_since_ms_ = 0;
};

// The log line for a decision, or an empty string when there is nothing to
// say. Beside the state machine so the wording is testable.
std::string DescribeSessionRebuild(const SessionRebuildPolicy::Decision& decision);

}  // namespace tfc

#endif  // RUNNER_SESSION_REBUILD_POLICY_H_

#ifndef RUNNER_SHUTDOWN_POLICY_H_
#define RUNNER_SHUTDOWN_POLICY_H_

// How the runner ends its process, and when crash-restart stops applying.
//
// --- The loop this breaks --------------------------------------------------
//
// On 2026-09-11 every close of the window crashed. The Windows event log shows
// the fault in dcomp.dll, exception 0xE0464645 -- a deliberate fail-fast, not
// an access violation -- in the same second hmi-runner.log records "epoch 1
// STOPPING ... reason=window destroyed". ConfigureUnattendedOperation had
// registered the process with RegisterApplicationRestart, so Windows handled
// each of those crashes exactly as it was asked to: it started the app again.
// Three windows closed at 20:24:52, :55 and :58 came back as three new
// processes by 20:25:05, and they had themselves been relaunched by three
// identical close-crashes at 19:55:30-33. Closing the app did not close it.
//
// The crash is not in anything the runner owns. flutter_inappwebview_windows
// (WebView2, since #487/#489) builds a Windows.UI.Composition Compositor, a
// DispatcherQueueController bound to the platform thread, and an RoInitialize
// on that thread -- all in `inline static` members of InAppWebViewManager,
// created the first time the plugin registers and released by nothing but the
// DLL's own static destructors. Those run in module teardown, after wWinMain
// has returned and CoUninitialize has taken the apartment away, and releasing
// a Compositor into that fails fast. It happens whether or not a web page was
// ever on screen: registering the plugin is enough, and every engine start
// registers it.
//
// --- The two decisions -----------------------------------------------------
//
// 1. A deliberate close withdraws crash-restart. The top-level window being
//    destroyed is the one moment the process is known to be ending on
//    purpose, and it comes before the engine and its plugins are torn down.
//    From there on, whatever goes wrong -- this plugin, the next one, a driver
//    -- cannot put an app the operator just closed back on the screen. A
//    crash while RUNNING still restarts, which is what the registration is for.
//
// 2. The process never runs module teardown. Once the message loop has
//    returned, the window and the engine are already gone and the logs are
//    flushed; everything left is the OS reclaiming memory, plus other people's
//    static destructors running in an order nobody controls. The runner
//    flushes and calls TerminateProcess with the loop's exit code, which ends
//    the process without them. That removes this crash, and the whole class it
//    belongs to, rather than waiting for an upstream release to fix one plugin.
//
// Pure logic, no Windows headers, so it runs in the CTest suite on every
// platform. The two real calls -- UnregisterApplicationRestart and
// TerminateProcess -- live in utils.cpp and are made where this says.

#include <string>

namespace tfc {

class ShutdownPolicy {
 public:
  // What to do now that the top-level window is going away.
  struct Step {
    // Call UnregisterApplicationRestart now. True at most once per process.
    bool withdraw_restart = false;
  };

  // How to leave once the message loop has returned.
  struct ExitPlan {
    // Whatever PostQuitMessage carried: 0 for a close, the watchdog's own code
    // for its GPU-loss exit. Preserved so a supervisor can tell them apart.
    int exit_code = 0;
    // End with TerminateProcess instead of returning from wWinMain, so no
    // module's static destructors run. Always true; it is a field so that the
    // tests say so and the call site reads as a decision, not a habit.
    bool skip_module_teardown = true;
    // The runner's last log line.
    std::string description;
  };

  // The top-level window received WM_DESTROY. |window_existed| is false for
  // the Destroy() that Win32Window::Create runs before any window exists,
  // which is startup rather than a close.
  Step WindowDestroyed(bool window_existed);

  // The message loop returned carrying |exit_code|.
  ExitPlan LoopEnded(int exit_code) const;

  bool restart_withdrawn() const { return restart_withdrawn_; }

 private:
  bool restart_withdrawn_ = false;
};

}  // namespace tfc

#endif  // RUNNER_SHUTDOWN_POLICY_H_

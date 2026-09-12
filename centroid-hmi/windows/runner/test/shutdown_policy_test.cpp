// Tests for how the runner ends its process -- the 2026-09-11 close-crash loop.
//
// Every close of the window crashed in dcomp.dll (0xE0464645, a fail-fast)
// after wWinMain had returned: flutter_inappwebview_windows keeps its
// Compositor and DispatcherQueueController in function-less statics that are
// released only when its DLL is unloaded, after CoUninitialize. Windows
// treated each of those crashes as a crash, RegisterApplicationRestart
// relaunched the app, and three windows closed at 20:24:52-58 came back as
// three new processes seconds later.
//
// Two decisions fix it, and these tests pin both:
//   * a deliberate close withdraws crash-restart, so nothing that goes wrong
//     after it can bring the app back; and
//   * the process leaves without running module teardown, so the plugin's
//     statics are never released into a torn-down apartment at all.

#include "../shutdown_policy.h"

#include <string>

#include "test_harness.h"

namespace {

using tfc::ShutdownPolicy;

bool Contains(const std::string& haystack, const char* needle) {
  return haystack.find(needle) != std::string::npos;
}

// Win32Window::Create opens with Destroy(), which reaches the teardown path on
// a window that does not exist yet. That is startup, not a close, and must
// leave crash-restart alone -- otherwise every station would silently lose it
// before its first frame.
TEST(teardown_before_the_window_exists_keeps_crash_restart) {
  ShutdownPolicy policy;
  const ShutdownPolicy::Step step = policy.WindowDestroyed(false);
  CHECK(!step.withdraw_restart);
  CHECK(!policy.restart_withdrawn());
}

// The operator closing the window is the one moment the process is known to be
// ending on purpose. Restart is withdrawn right there, before the engine and
// its plugins are torn down, so a crash anywhere after it cannot relaunch.
TEST(closing_the_window_withdraws_crash_restart) {
  ShutdownPolicy policy;
  const ShutdownPolicy::Step step = policy.WindowDestroyed(true);
  CHECK(step.withdraw_restart);
  CHECK(policy.restart_withdrawn());
}

// UnregisterApplicationRestart is asked for once. A second WM_DESTROY (the
// window's destructor runs Destroy() again) has nothing left to do.
TEST(restart_is_withdrawn_once) {
  ShutdownPolicy policy;
  CHECK(policy.WindowDestroyed(true).withdraw_restart);
  CHECK(!policy.WindowDestroyed(true).withdraw_restart);
  CHECK(!policy.WindowDestroyed(false).withdraw_restart);
  CHECK(policy.restart_withdrawn());
}

// The startup teardown must not latch anything that would stop the real close
// from withdrawing restart later.
TEST(startup_teardown_does_not_stop_the_later_close) {
  ShutdownPolicy policy;
  policy.WindowDestroyed(false);
  CHECK(policy.WindowDestroyed(true).withdraw_restart);
}

// Whatever PostQuitMessage carried survives: 0 for a close, the GPU-loss code
// for the watchdog's exit. A supervisor reading the exit code must still be
// able to tell the two apart.
TEST(the_exit_code_survives) {
  ShutdownPolicy closed;
  closed.WindowDestroyed(true);
  CHECK_EQ(closed.LoopEnded(0).exit_code, 0);

  ShutdownPolicy lost;
  CHECK_EQ(lost.LoopEnded(109).exit_code, 109);
}

// The crash itself: module teardown after the message loop releases
// flutter_inappwebview's static Compositor after the apartment it belongs to
// is gone. The process never runs it, however it came to end.
TEST(the_process_never_runs_module_teardown) {
  ShutdownPolicy closed;
  closed.WindowDestroyed(true);
  CHECK(closed.LoopEnded(0).skip_module_teardown);

  ShutdownPolicy lost;
  CHECK(lost.LoopEnded(109).skip_module_teardown);
}

// The watchdog's GPU-loss exit posts its quit without destroying the window,
// so it is not an operator close and does not withdraw anything.
TEST(the_gpu_loss_exit_is_not_a_close) {
  ShutdownPolicy policy;
  policy.LoopEnded(109);
  CHECK(!policy.restart_withdrawn());
}

// The last line the runner writes says how it left, so a log that ends there
// reads as a deliberate exit rather than a process that vanished.
TEST(the_exit_is_described) {
  ShutdownPolicy closed;
  closed.WindowDestroyed(true);
  const std::string line = closed.LoopEnded(0).description;
  CHECK(Contains(line, "exit code 0"));
  CHECK(Contains(line, "crash-restart withdrawn"));

  ShutdownPolicy lost;
  const std::string other = lost.LoopEnded(109).description;
  CHECK(Contains(other, "exit code 109"));
  CHECK(Contains(other, "crash-restart still registered"));
}

}  // namespace

int main() { return tfc_test::RunAll(); }

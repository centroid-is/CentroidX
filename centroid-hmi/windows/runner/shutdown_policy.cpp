#include "shutdown_policy.h"

namespace tfc {

ShutdownPolicy::Step ShutdownPolicy::WindowDestroyed(bool window_existed) {
  Step step;
  if (window_existed && !restart_withdrawn_) {
    restart_withdrawn_ = true;
    step.withdraw_restart = true;
  }
  return step;
}

ShutdownPolicy::ExitPlan ShutdownPolicy::LoopEnded(int exit_code) const {
  ExitPlan plan;
  plan.exit_code = exit_code;
  plan.skip_module_teardown = true;
  plan.description =
      "message loop ended, exit code " + std::to_string(exit_code) + ", " +
      (restart_withdrawn_
           ? "crash-restart withdrawn (the window was closed)"
           : "crash-restart still registered (the window was not closed)") +
      ". Ending with TerminateProcess: module teardown would release "
      "flutter_inappwebview's static Compositor after COM is gone, which is "
      "the dcomp.dll fail-fast every close hit on 2026-09-11.";
  return plan;
}

}  // namespace tfc

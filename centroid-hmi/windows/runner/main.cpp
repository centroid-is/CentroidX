#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cstdlib>
#include <iostream>
#include <string>

#include "crash_handler.h"
#include "flutter_window.h"
#include "output_target.h"
#include "path_utils.h"
#include "runner_log.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Logging for MSIX/release builds:
  //   CENTROID_STDOUT=1          → also opens a console window
  //   CENTROID_LOG_FILE=<path>   → overrides the default log file location
  //   CENTROID_LOG_ARCHIVES=<n>  → previous runs to keep (default 5)
  //
  // A log file is written unconditionally. This is a windowed app: with no
  // console attached and no file, everything on stdout/stderr — including the
  // crash records installed below — is discarded, which is exactly how a
  // crash ends up with nothing to go on.
  char* debug_env = nullptr;
  size_t debug_env_len = 0;
  _dupenv_s(&debug_env, &debug_env_len, "CENTROID_STDOUT");

  char* log_file_env = nullptr;
  size_t log_file_env_len = 0;
  _dupenv_s(&log_file_env, &log_file_env_len, "CENTROID_LOG_FILE");

  char* archives_env = nullptr;
  size_t archives_env_len = 0;
  _dupenv_s(&archives_env, &archives_env_len, "CENTROID_LOG_ARCHIVES");

  bool debug_mode = debug_env != nullptr &&
                    (strcmp(debug_env, "1") == 0 || strcmp(debug_env, "true") == 0);

  int max_archives = 5;
  if (archives_env != nullptr && archives_env[0] != '\0') {
    int parsed = atoi(archives_env);
    if (parsed >= 0) {
      max_archives = parsed;
    }
  }

  const bool explicit_log_file =
      log_file_env != nullptr && log_file_env[0] != '\0';
  std::string log_path =
      explicit_log_file ? std::string(log_file_env) : DefaultLogPath();

  tfc::OutputTargetInputs target_inputs;
  target_inputs.explicit_log_file = explicit_log_file;
  target_inputs.console_requested = debug_mode;
  target_inputs.stdout_connected = StdoutIsConnected();
  const tfc::OutputTarget target = tfc::ChooseOutputTarget(target_inputs);

  // A console, when asked for or when launched from a terminal.
  if (debug_mode) {
    if (!::AttachConsole(ATTACH_PARENT_PROCESS)) {
      CreateAndAttachConsole();
    } else {
      RedirectIOToConsole();
    }
  } else if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  if (target == tfc::OutputTarget::kInherited) {
    // Something is already reading stdout — a terminal, or the pipe that
    // `flutter run` and the VS Code debugger set up. Leave the streams where
    // they are so Dart's output keeps reaching whoever is watching. Crash
    // handlers still install; their records go to the same place.
    tfc::InstallCrashHandlers(tfc::DirectoryOf(DefaultLogPath()), std::string());
    std::cerr << "[startup] logging to the attached console/pipe" << std::endl;
  } else if (!log_path.empty()) {
    // Rotate before opening: RedirectIOToFile truncates, and the previous
    // run's log is the one worth keeping after a crash.
    RotateLogs(log_path, max_archives);
    const bool engine_streams_follow = RedirectIOToFile(log_path.c_str());

    // Tell the Dart side where the log went. It previously discovered this
    // only from CENTROID_LOG_FILE being set by hand, so when the runner
    // started picking a default path the Dart half went back to having no
    // destination at all.
    ::SetEnvironmentVariableA("CENTROID_LOG_FILE", log_path.c_str());
    // ...and, only when the redirect also took the ENGINE's streams with
    // it, that the Dart side must not open and write the same file itself:
    // that would duplicate every line.
    //
    // Without a console the engine cannot be resynced (its resync reopens
    // CONOUT$), so print() output never reaches this file through the
    // runner. Claiming otherwise is what left every shortcut launch with a
    // zero-byte log: the runner said "I have got it" and the Dart writer
    // stood down, and neither wrote anything.
    if (engine_streams_follow) {
      ::SetEnvironmentVariableA("CENTROID_LOG_REDIRECTED", "1");
    }

    // Only now can crash records actually be written somewhere.
    tfc::InstallCrashHandlers(tfc::DirectoryOf(log_path), log_path);
    std::cerr << "[startup] logging to " << log_path << " (keeping "
              << max_archives << " previous runs)" << std::endl;
  }

  // Open the runner's own durable sink, whatever happened above.
  //
  // On the kInherited path -- a terminal, `flutter run`, VS Code -- nothing
  // above redirects anything, so every diagnostic the runner writes goes to a
  // console and nowhere else. That is exactly how the 2026-08-31 freeze was
  // investigated three times with the decisive line missing: it had been
  // printed, into scrollback, and %TEMP%\hmi-stderr.log was zero bytes. From
  // here on the GPU watchdog's lines and its loss report land in the log file
  // as well as on stderr, in every launch mode. See runner_log.h.
  tfc::InitRunnerLog(log_path);
  if (tfc::RunnerLogHasFile()) {
    std::cerr << "[startup] runner diagnostics also going to "
              << tfc::RunnerLogPath() << std::endl;
  }

  free(debug_env);
  free(log_file_env);
  free(archives_env);

  // Ask Windows to treat this as a station: no sleep, no background
  // throttling, and a restart if it dies. Done after logging is up so the
  // three results are recorded.
  ConfigureUnattendedOperation();

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1920, 1080);
  if (!window.Create(L"CentroidX", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  // Whatever PostQuitMessage carried, so a distinct exit reason survives to
  // whatever supervises this process. A normal close posts 0; the GPU device
  // loss path posts its own code so "the screen went black" and "the operator
  // closed it" are not the same event in a service log.
  //
  // And leave WITHOUT module teardown. The window and the engine are already
  // gone; what returning from here would add is every DLL's static
  // destructors, and flutter_inappwebview's among them release a Compositor
  // into an apartment that no longer exists -- the dcomp.dll fail-fast that
  // every close hit on 2026-09-11. Not CoUninitialize either: it is the thing that
  // takes that apartment away, and the OS reclaims it regardless. See
  // shutdown_policy.h.
  const tfc::ShutdownPolicy::ExitPlan plan =
      window.shutdown_policy().LoopEnded(static_cast<int>(msg.wParam));
  tfc::RunnerLogLine("[shutdown]", plan.description);
  if (plan.skip_module_teardown) {
    EndProcessWithoutTeardown(plan.exit_code);
  }
  ::CoUninitialize();
  return plan.exit_code;
}

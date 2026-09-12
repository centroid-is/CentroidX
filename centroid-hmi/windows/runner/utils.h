#ifndef RUNNER_UTILS_H_
#define RUNNER_UTILS_H_

#include <string>
#include <vector>

// Creates a console for the process, and redirects stdout and stderr to
// it for both the runner and the Flutter library.
void CreateAndAttachConsole();

// Redirects stdout and stderr to an already-attached console.
void RedirectIOToConsole();

// Redirects stdout and stderr to a log file. Truncates |path|; call
// RotateLogs first to keep the previous run.
// Redirects this process's stdout and stderr to the file at |path|.
//
// Returns whether the ENGINE's streams were resynced along with them, i.e.
// whether Dart's print() output will also reach the file. That is only
// possible when the process has a console (see the implementation), so a
// launch from a shortcut gets the C++ side only and the Dart side has to
// write the file itself.
bool RedirectIOToFile(const char* path);

// Default log file location: %LOCALAPPDATA%\centroid-hmi\logs\hmi.log,
// creating the directory. Returns an empty string if it cannot be created.
//
// Logging to a file by default is deliberate: this is a windowed app, so
// without a console and without CENTROID_LOG_FILE set, everything written to
// stdout/stderr — including crash records — goes nowhere at all.
std::string DefaultLogPath();

// Tells Windows this process is an unattended station, not a desktop app the
// user is sitting in front of. Three separate requests, none of which implies
// the others:
//
//   * the machine must not sleep or hibernate under a running line;
//   * this process must not be throttled when nothing is on screen. A
//     disconnected RDP session is the case that bites: Windows slows a
//     background session's timers, the OPC UA keepalives stop arriving, and
//     the servers drop their sessions — which is what an overnight log full of
//     "Inactivity" is a picture of;
//   * if it does crash, Windows should start it again rather than leave the
//     line without an HMI until somebody notices.
//
// Every part is best-effort: all of it is a request Windows may decline (group
// policy, a VM, an older build), and none of it is worth failing startup over.
void ConfigureUnattendedOperation();

// Takes back the crash-restart registration ConfigureUnattendedOperation made.
// Called when the operator closes the window: from then on the process is
// ending on purpose, and a crash while it tears down must not relaunch it.
// See shutdown_policy.h. Returns whether Windows accepted it.
bool WithdrawCrashRestart();

// Flushes stdout, stderr and every C stream, then ends the process with
// |exit_code| WITHOUT running module teardown -- no DLL static destructors, no
// atexit handlers. See shutdown_policy.h for the plugin whose statics crash if
// they are released after the message loop.
[[noreturn]] void EndProcessWithoutTeardown(int exit_code);

// True when stdout is already a valid handle — a console, or a pipe from a
// parent process such as the flutter tool. `flutter run` (and so the VS Code
// debugger) gives the app pipes and no console, so this, not the presence of a
// console, is what decides whether anything is listening.
bool StdoutIsConnected();

// Directory part of a path: tfc::DirectoryOf in path_utils.h. It lives there
// because it is pure string arithmetic and this file cannot be compiled off
// Windows.

// Moves previous runs aside so this run starts a fresh file, keeping
// |max_archives| generations (hmi.1.log, hmi.2.log, ...). Without this the
// log from the run that crashed is destroyed by the relaunch that goes
// looking for it.
void RotateLogs(const std::string& path, int max_archives);

// Takes a null-terminated wchar_t* encoded in UTF-16 and returns a std::string
// encoded in UTF-8. Returns an empty std::string on failure.
std::string Utf8FromUtf16(const wchar_t* utf16_string);

// Gets the command line arguments passed in as a std::vector<std::string>,
// encoded in UTF-8. Returns an empty std::vector<std::string> on failure.
std::vector<std::string> GetCommandLineArguments();

#endif  // RUNNER_UTILS_H_

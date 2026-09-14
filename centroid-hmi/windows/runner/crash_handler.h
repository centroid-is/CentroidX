#ifndef RUNNER_CRASH_HANDLER_H_
#define RUNNER_CRASH_HANDLER_H_

#include <string>

// Process-wide crash capture.
//
// Without this, the ways this app can die produce nothing at all in the log:
//
//   * abort()                     — CRT prints a message box, if anything
//   * uncaught C++ exception, or  — std::terminate, then abort
//     one escaping a noexcept fn
//   * access violation etc.       — process vanishes
//   * CRT invalid parameter       — silently calls abort
//   * pure virtual call           — silently calls abort
//
// Each handler installed here writes a one-line record to stderr (which the
// runner redirects to the log file) and a minidump next to the log, then ends
// the process deterministically. The record names the failure kind; for an
// uncaught exception it also recovers the exception's what() string, which is
// the difference between "abort() has been called" and knowing what threw.
//
// The modal abort dialog is suppressed — on a kiosk HMI a message box nobody
// can click is a hang, not a diagnostic.
//
// --- The one class this cannot catch ---------------------------------------
//
// A **fail-fast** is not dispatched. RaiseFailFastException and the __fastfail
// intrinsic hand the process straight to WER: no vectored handler runs, no
// unhandled-exception filter, no std::terminate, no signal. Nothing below sees
// it, so no [crash] record and no minidump are written and the log simply ends
// mid-run. That is not hypothetical here — 0xE0464645 is the fail-fast
// DirectComposition raises, and this app has produced it twice: at every close
// on 2026-09-11 (shutdown_policy.h) and once mid-run on 2026-09-14, after a
// second of UI-isolate work starved the platform thread the compositor's
// dispatcher queue is bound to.
//
// The evidence for that class is Windows' own and it is complete: the
// Application event log carries an "Application Error" (id 1000) naming the
// faulting module, exception code and offset, and WER keeps a Report.wer and
// a dump under %ProgramData%\Microsoft\Windows\WER. InstallCrashHandlers says
// so in the log at startup, so a reader who finds this file ending in the
// middle of a run knows where to go next instead of concluding the process
// vanished without trace.

namespace tfc {

// Installs the handlers. |dump_dir| is where minidumps are written; pass the
// directory containing the log file. Safe to call once, early in wWinMain,
// after stdio has been redirected so the records land in the log.
// |log_path| is the log file crash records are appended to directly, through a
// handle of this module's own. It is deliberately not the same mechanism as
// the process-wide stdout/stderr redirect: on a packaged, console-less launch
// that redirect delivered nothing, and a crash record is the last line that
// should depend on it. Empty disables the direct write, leaving stderr and
// OutputDebugString.
void InstallCrashHandlers(const std::string& dump_dir,
                          const std::string& log_path);

}  // namespace tfc

#endif  // RUNNER_CRASH_HANDLER_H_

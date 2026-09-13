#ifndef RUNNER_GPU_DIAGNOSIS_H_
#define RUNNER_GPU_DIAGNOSIS_H_

#include <cstddef>
#include <cstdint>
#include <string>

// Says *why* the renderer died, in the log, once.
//
// gpu_watchdog.h detects that no frames are being presented. That is the
// symptom. What the log shows today is only the engine's own version of the
// symptom, repeated forever at frame rate:
//
//   [ERROR:...egl/egl.cc(57)] EGL Error: Context Lost (12302) in .../context.cc
//   [ERROR:...gpu_surface_gl_skia.cc(220)] Could not make the context current
//                                          to acquire the frame.
//
// Thousands of those lines say nothing except "it is still broken", and they
// bury whatever was logged just before the loss -- which is the part worth
// reading. None of them says whether the graphics driver reset, whether the
// adapter went away, or whether an RDP session swapped the display adapter out
// from under us. Those are different bugs with different fixes.
//
// The authoritative answer to "why" is D3D11's GetDeviceRemovedReason(). We
// cannot ask ANGLE's device -- it lives inside flutter_windows.dll -- so the
// runner keeps a sentinel D3D11 device of its own on the default adapter and
// asks that one instead. A TDR, a driver restart or an adapter reset takes
// every device on the adapter with it, so the sentinel sees the same event.
//
// "We cannot ask ANGLE's device" was tested on 2026-08-31 and holds. The route
// that ought to work is EGL_EXT_device_query: eglQueryDisplayAttribEXT on the
// engine's EGLDisplay for EGL_DEVICE_EXT, then eglQueryDeviceAttribEXT for
// EGL_D3D11_DEVICE_ANGLE, which is exactly what the embedder does internally
// for FlutterDesktopEngineGetGraphicsAdapter. It cannot be done from the
// runner, for a reason worth writing down so nobody spends another evening on
// it: flutter_windows.dll STATICALLY LINKS its own ANGLE. It contains the
// string "eglGetPlatformDisplayEXT" but imports neither libEGL.dll nor
// libGLESv2.dll, and exports no EGL entry point. The libEGL.dll that is loaded
// in the process belongs to a plugin (media_kit), and it is a separate ANGLE
// with a separate display cache -- so every eglGetPlatformDisplayEXT the
// runner makes returns a fresh, uninitialised display and every query on it
// fails with EGL_NOT_INITIALIZED (0x3001). That was measured for ten
// attribute lists, including the two the engine's own .rdata contains. There
// is no reachable handle on ANGLE's device short of forking the engine.
//
// The consequence for detection: an adapter-wide loss is directly observable
// through the sentinel and is declared the moment it happens. A loss confined
// to ANGLE's device -- the RDP session/desktop swap, which is the case that
// produced "reason: S_OK / the adapter is healthy" -- is NOT directly
// observable, and for that class the frame probe is still the only detector.
//
// That gives the single most useful bit in the whole diagnosis:
//
//   * sentinel removed  -> the adapter itself went down. The reason code names
//                          which way (hang, removal, reset, driver bug).
//   * sentinel healthy  -> the adapter is fine and only ANGLE's device died.
//                          That points at the session/desktop swap path (RDP,
//                          fast user switching, session 0 isolation) rather
//                          than at the GPU.
//
// This header is the part of that with no Win32 in it: classifying a reason
// code and formatting the report. gpu_device_probe.h owns the sentinel device,
// and flutter_window.cpp gathers the evidence and decides what to do with it.

namespace tfc {

// DXGI reason codes, spelled out rather than included: this file is built by
// the standalone test project on Linux and macOS, where dxgi.h does not exist.
// Values are from winerror.h and are ABI-frozen.
//
// uint32_t, not HRESULT's own `long`: `long` is 64-bit on Unix but 32-bit on
// MSVC, where every one of these overflows it (they are negative as a signed
// 32-bit HRESULT). Carrying them as a fixed-width unsigned quantity means the
// same literal means the same thing on the machine that builds the tests and
// the machine that builds the app. GpuDeviceProbe casts the HRESULT on the way
// in; nothing here ever does arithmetic on it.
enum DxgiReason : std::uint32_t {
  kDxgiOk = 0u,
  kDxgiInvalidCall = 0x887A0001u,
  kDxgiDeviceRemoved = 0x887A0005u,
  kDxgiDeviceHung = 0x887A0006u,
  kDxgiDeviceReset = 0x887A0007u,
  kDxgiDriverInternalError = 0x887A0020u,
};

// What the sentinel device's reason code says about the adapter.
enum class AdapterVerdict {
  // The sentinel is still alive. The adapter did not go down, so whatever
  // killed ANGLE's context was narrower than the GPU.
  kHealthy,
  // The GPU stopped responding and Windows reset it (TDR).
  kHung,
  // The adapter went away: driver updated or restarted, VM GPU reset, device
  // disabled or physically removed.
  kRemoved,
  // The device was reset because of an invalid command from some process.
  kReset,
  // The driver itself failed.
  kDriverError,
  // A reason code we do not have a name for, or no sentinel to ask.
  kUnknown,
};

AdapterVerdict ClassifyRemovedReason(std::uint32_t reason);

// "DXGI_ERROR_DEVICE_HUNG (0x887a0006)". Returns |out| for unnamed codes, so
// |out| must outlive the returned pointer.
const char* DescribeRemovedReason(std::uint32_t reason, char* out,
                                  size_t out_len);

// The plain-English cause and, more usefully, what to go and look at next.
const char* ExplainVerdict(AdapterVerdict verdict);

// The window message that arrived shortly before the loss, if any. The
// correlation is most of the diagnosis: a loss that lands with a session
// change is a different bug from one that arrives out of a clear sky.
enum class LossHint {
  kNone,
  kPowerResume,
  kDisplayChange,
  kSessionChange,
};

const char* DescribeHint(LossHint hint);

// How the loss came to be known. This is the field the 2026-08-31 incident was
// missing: "no frames for ten seconds" and "the device says it is removed" are
// different qualities of evidence, and a report that does not say which one it
// acted on cannot be second-guessed later.
enum class LossCause {
  // Inferred: probes went unanswered for missed_probes_before_recovery ticks.
  // The original and weakest test -- it cannot tell a dead renderer from a
  // watchdog that is not being ticked.
  kNoFramesPresented,
  // Observed: the render device reports itself removed, asked directly. Only
  // reachable for adapter-wide losses -- see the note above on why ANGLE's own
  // device cannot be queried from the runner.
  kContextLost,
  // Observed: the host could not get a message through to the platform thread
  // at all, so nothing running on it -- including the engine -- can be
  // presumed alive.
  kPlatformThreadWedged,
  // Observed: the UI isolate asked the engine to rasterise a 1 x 1 picture on
  // consecutive liveness stamps and got an empty image back each time. The
  // isolate is alive and building frames; the engine cannot draw them. The
  // only detector that saw the 2026-09-12 freeze -- see DartLiveness.
  kRasterFailed,
};

const char* DescribeLossCause(LossCause cause);

// Why an exit happened in a run configured to recover in place. Without this
// the log shows a process configured to restart quietly ending instead.
enum class LossEscalation {
  kNone,
  // More distinct loss episodes inside the window than the guard allows:
  // in-place recovery works but does not hold.
  kRepeatedLosses,
  // Consecutive in-place recoveries that never produced a frame.
  kRecoveryExhausted,
};

const char* DescribeEscalation(LossEscalation escalation);

// "WTS_REMOTE_DISCONNECT (4)" for the codes WM_WTSSESSION_CHANGE carries.
// Returns |out| for codes with no name, so |out| must outlive the result.
const char* DescribeSessionChange(unsigned long code, char* out,
                                  size_t out_len);

// Milliseconds as something readable at 3am: "1h 2m 1s". Raw milliseconds stay
// in the report too -- this is for the human, that is for the diff.
std::string FormatDuration(unsigned long long ms);

// Everything the report is built from. The Win32 side fills this in; nothing
// here knows how any of it was obtained.
struct LossEvidence {
  // How the loss was established. See LossCause.
  LossCause cause = LossCause::kNoFramesPresented;

  // Set when a run configured to recover in place is exiting anyway.
  LossEscalation escalation = LossEscalation::kNone;

  // False when the sentinel device could not be created at startup, which
  // makes |device_removed_reason| meaningless rather than reassuring.
  bool sentinel_available = false;
  std::uint32_t device_removed_reason = kDxgiOk;

  // Distinct loss episodes counted inside the loop guard's window, including
  // this one, and the ceiling it is measured against.
  int losses_in_window = 0;
  int max_losses_in_window = 0;
  // Consecutive in-place recoveries attempted so far in this episode.
  int recovery_attempts = 0;

  LossHint last_hint = LossHint::kNone;
  // Only meaningful when |last_hint| is not kNone.
  unsigned long long ms_since_last_hint = 0;
  // The WTS_* code, when |last_hint| is kSessionChange.
  unsigned long session_change_code = 0;

  unsigned long long ms_since_start = 0;
  unsigned long long ms_since_last_frame = 0;
  int missed_probes = 0;

  bool remote_session = false;

  // Empty when the adapter could not be described.
  std::string adapter_description;
  unsigned int adapter_vendor_id = 0;
  unsigned int adapter_device_id = 0;
};

// The report block. Multi-line; every line carries the same prefix so one
// grep pulls the whole thing out of a log full of EGL noise.
std::string FormatLossReport(const LossEvidence& evidence);

// What to do once the report is written. CENTROID_GPU_ON_LOSS.
enum class LossAction {
  // Write the report and carry on. The screen stays frozen; the log stops
  // being useless.
  kLogOnly,
  // Write the report and end the process, so a supervisor restarts it and the
  // report is the last thing in the log.
  kExitProcess,
  // Write the report and rebuild the engine in place, the pre-existing
  // behaviour of the watchdog.
  kRestartEngine,
};

LossAction ParseLossAction(const char* raw, LossAction fallback);
const char* DescribeLossAction(LossAction action);

}  // namespace tfc

#endif  // RUNNER_GPU_DIAGNOSIS_H_

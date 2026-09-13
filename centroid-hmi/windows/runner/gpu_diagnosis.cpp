#include "gpu_diagnosis.h"

#include <cstdio>
#include <sstream>
#include <string>

namespace tfc {
namespace {

// Every line carries this. The log this lands in is full of the engine's own
// EGL errors at frame rate, so the report has to be greppable as a block.
constexpr const char* kTag = "[gpu-loss] ";

bool EqualsIgnoreCase(const char* a, const char* b) {
  for (; *a != '\0' && *b != '\0'; a++, b++) {
    char lhs = (*a >= 'A' && *a <= 'Z') ? static_cast<char>(*a + 32) : *a;
    char rhs = (*b >= 'A' && *b <= 'Z') ? static_cast<char>(*b + 32) : *b;
    if (lhs != rhs) {
      return false;
    }
  }
  return *a == *b;
}

void AppendLine(std::ostringstream& out, const std::string& text) {
  out << kTag << text << "\n";
}

}  // namespace

AdapterVerdict ClassifyRemovedReason(std::uint32_t reason) {
  switch (reason) {
    case kDxgiOk:
      return AdapterVerdict::kHealthy;
    case kDxgiDeviceHung:
      return AdapterVerdict::kHung;
    case kDxgiDeviceRemoved:
      return AdapterVerdict::kRemoved;
    case kDxgiDeviceReset:
      return AdapterVerdict::kReset;
    case kDxgiDriverInternalError:
      return AdapterVerdict::kDriverError;
    case kDxgiInvalidCall:
      return AdapterVerdict::kReset;
    default:
      // Non-zero and unmapped. Emphatically not kHealthy: the device is gone,
      // we just do not have a name for the way it went.
      return AdapterVerdict::kUnknown;
  }
}

const char* DescribeRemovedReason(std::uint32_t reason, char* out,
                                  size_t out_len) {
  const char* name = nullptr;
  switch (reason) {
    case kDxgiOk:
      name = "S_OK";
      break;
    case kDxgiInvalidCall:
      name = "DXGI_ERROR_INVALID_CALL";
      break;
    case kDxgiDeviceRemoved:
      name = "DXGI_ERROR_DEVICE_REMOVED";
      break;
    case kDxgiDeviceHung:
      name = "DXGI_ERROR_DEVICE_HUNG";
      break;
    case kDxgiDeviceReset:
      name = "DXGI_ERROR_DEVICE_RESET";
      break;
    case kDxgiDriverInternalError:
      name = "DXGI_ERROR_DRIVER_INTERNAL_ERROR";
      break;
    default:
      break;
  }

  if (out == nullptr || out_len == 0) {
    return name != nullptr ? name : "";
  }
  if (name != nullptr) {
    std::snprintf(out, out_len, "%s (0x%08x)", name,
                  static_cast<unsigned int>(reason));
  } else {
    // Unnamed, but the number is what gets looked up afterwards, so it must
    // survive into the log.
    std::snprintf(out, out_len, "unrecognised reason (0x%08x)",
                  static_cast<unsigned int>(reason));
  }
  return out;
}

const char* ExplainVerdict(AdapterVerdict verdict) {
  switch (verdict) {
    case AdapterVerdict::kHealthy:
      return "the adapter is healthy -- our sentinel D3D11 device survived, so "
             "the GPU did not go down and only ANGLE's device was lost. Look "
             "at the session/desktop swap path (RDP connect or disconnect, "
             "fast user switching, the console session moving), not at the "
             "graphics driver.";
    case AdapterVerdict::kHung:
      return "the GPU stopped responding and Windows reset it (TDR). Check the "
             "System event log for Display/nvlddmkm 'has stopped responding "
             "and has successfully recovered', and whether a heavy page or a "
             "shader is driving it.";
    case AdapterVerdict::kRemoved:
      return "the adapter went away: the driver was updated or restarted, a "
             "virtual GPU reset under the VM, or the device was disabled. "
             "Check the System event log around this timestamp for a driver "
             "install or a PnP removal.";
    case AdapterVerdict::kReset:
      return "the device was reset after an invalid command. That is usually "
             "another process on the same adapter rather than this one, but a "
             "driver bug presents the same way.";
    case AdapterVerdict::kDriverError:
      return "the graphics driver reported an internal error. This one is the "
             "driver's own fault -- note its version below and look for a "
             "known issue or an update.";
    case AdapterVerdict::kUnknown:
      return "the device is gone for a reason with no name in this build. The "
             "raw code above is the thing to look up in winerror.h.";
  }
  return "the device is gone for an unhandled reason.";
}

const char* DescribeHint(LossHint hint) {
  switch (hint) {
    case LossHint::kNone:
      return "none";
    case LossHint::kPowerResume:
      return "power resume";
    case LossHint::kDisplayChange:
      return "display change";
    case LossHint::kSessionChange:
      return "session change";
  }
  return "none";
}

const char* DescribeSessionChange(unsigned long code, char* out,
                                  size_t out_len) {
  // The WTS_* notification codes, in the order wtsapi32.h declares them. The
  // number alone is unreadable, and getting it wrong sends the next reader
  // after the wrong event entirely.
  static const char* kNames[] = {
      nullptr,                    // 0 is not used
      "WTS_CONSOLE_CONNECT",      // 1
      "WTS_CONSOLE_DISCONNECT",   // 2
      "WTS_REMOTE_CONNECT",       // 3
      "WTS_REMOTE_DISCONNECT",    // 4
      "WTS_SESSION_LOGON",        // 5
      "WTS_SESSION_LOGOFF",       // 6
      "WTS_SESSION_LOCK",         // 7
      "WTS_SESSION_UNLOCK",       // 8
      "WTS_SESSION_REMOTE_CONTROL",  // 9
      "WTS_SESSION_CREATE",       // 10
      "WTS_SESSION_TERMINATE",    // 11
  };
  const size_t count = sizeof(kNames) / sizeof(kNames[0]);
  const char* name = (code < count) ? kNames[code] : nullptr;

  if (out == nullptr || out_len == 0) {
    return name != nullptr ? name : "";
  }
  if (name != nullptr) {
    std::snprintf(out, out_len, "%s (%lu)", name, code);
  } else {
    std::snprintf(out, out_len, "unnamed WTS code (%lu)", code);
  }
  return out;
}

std::string FormatDuration(unsigned long long ms) {
  const unsigned long long seconds = ms / 1000;
  const unsigned long long h = seconds / 3600;
  const unsigned long long m = (seconds % 3600) / 60;
  const unsigned long long s = seconds % 60;

  std::ostringstream out;
  if (h > 0) {
    out << h << "h " << m << "m " << s << "s";
  } else if (m > 0) {
    out << m << "m " << s << "s";
  } else {
    // Under a minute the milliseconds are the interesting part -- a 900 ms
    // stall and a 59 s stall are different findings.
    out << (ms / 1000.0) << "s";
  }
  return out.str();
}

std::string FormatLossReport(const LossEvidence& evidence) {
  std::ostringstream out;
  char reason_buffer[96];

  AppendLine(out, "================ GPU DEVICE LOSS ================");
  AppendLine(out,
             "the renderer is dead. What follows is why, so that the EGL "
             "errors around it can be ignored.");

  // First, and deliberately before any of the evidence: HOW this was
  // established. A report that opens with a reason code invites the reader to
  // assume the strongest possible test produced it, and for four weeks the
  // only test there was could not distinguish a dead renderer from a watchdog
  // nobody was ticking.
  AppendLine(out,
             std::string("detected by: ") + DescribeLossCause(evidence.cause));

  if (!evidence.sentinel_available) {
    // Saying nothing here would leave reason 0 looking like S_OK.
    AppendLine(out,
               "adapter    : UNKNOWN -- no sentinel device (it could not be "
               "created at startup), so there is nothing to ask why it died.");
  } else {
    const AdapterVerdict verdict =
        ClassifyRemovedReason(evidence.device_removed_reason);
    AppendLine(out, std::string("reason     : ") +
                        DescribeRemovedReason(evidence.device_removed_reason,
                                              reason_buffer,
                                              sizeof(reason_buffer)));
    AppendLine(out, std::string("meaning    : ") + ExplainVerdict(verdict));
  }

  if (evidence.adapter_description.empty() && evidence.adapter_vendor_id == 0 &&
      evidence.adapter_device_id == 0) {
    AppendLine(out, "adapter    : unknown (could not be described)");
  } else {
    char ids[64];
    std::snprintf(ids, sizeof(ids), " [vendor 0x%04x device 0x%04x]",
                  evidence.adapter_vendor_id, evidence.adapter_device_id);
    AppendLine(out, "adapter    : " +
                        (evidence.adapter_description.empty()
                             ? std::string("unknown")
                             : evidence.adapter_description) +
                        ids);
  }

  AppendLine(out, std::string("session    : ") +
                      (evidence.remote_session ? "remote (RDP/terminal services)"
                                               : "console (local)"));

  if (evidence.last_hint == LossHint::kNone) {
    AppendLine(out,
               "preceded by: nothing -- no preceding power, display or session "
               "message. The loss arrived out of a clear sky, which rules "
               "those paths out.");
  } else {
    std::ostringstream hint;
    hint << "preceded by: " << DescribeHint(evidence.last_hint) << ", "
         << evidence.ms_since_last_hint << " ms before the loss was declared";
    if (evidence.last_hint == LossHint::kSessionChange) {
      char session_buffer[64];
      hint << " -- "
           << DescribeSessionChange(evidence.session_change_code,
                                    session_buffer, sizeof(session_buffer));
    }
    AppendLine(out, hint.str());
  }

  std::ostringstream timing;
  timing << "timing     : up " << FormatDuration(evidence.ms_since_start)
         << " (" << evidence.ms_since_start << " ms), last frame "
         << FormatDuration(evidence.ms_since_last_frame) << " ago ("
         << evidence.ms_since_last_frame << " ms), after "
         << evidence.missed_probes << " unanswered probe(s)";
  AppendLine(out, timing.str());

  std::ostringstream history;
  history << "history    : loss episode " << evidence.losses_in_window
          << " of at most " << evidence.max_losses_in_window
          << " allowed in the guard window; " << evidence.recovery_attempts
          << " consecutive in-place recovery attempt(s) so far";
  AppendLine(out, history.str());

  if (evidence.escalation != LossEscalation::kNone) {
    AppendLine(out, std::string("escalated  : ") +
                        DescribeEscalation(evidence.escalation));
  }

  AppendLine(out, "=================================================");
  return out.str();
}

const char* DescribeLossCause(LossCause cause) {
  switch (cause) {
    case LossCause::kNoFramesPresented:
      return "no frames presented -- consecutive probes went unanswered. This "
             "is an INFERENCE from silence: it is also what a watchdog that is "
             "not being ticked looks like, so treat it as the weaker finding.";
    case LossCause::kContextLost:
      return "the render adapter reported itself REMOVED -- asked directly, "
             "not inferred. This is the strong finding: the GPU or its driver "
             "went down, and the reason code below names which way.";
    case LossCause::kPlatformThreadWedged:
      return "the platform thread did not answer a sent message inside the "
             "timeout. Nothing running on that thread, the engine included, "
             "can be assumed alive.";
    case LossCause::kRasterFailed:
      return "the UI isolate reported, on consecutive liveness stamps, that "
             "the engine returned an EMPTY image for a 1 x 1 snapshot. "
             "Observed from inside the isolate, not inferred: Dart is alive "
             "and building frames, the engine cannot rasterise them, and no "
             "native probe can see that -- the next-frame callback answers, "
             "the sentinel adapter is healthy, stderr is quiet.";
  }
  return "unknown";
}

const char* DescribeEscalation(LossEscalation escalation) {
  switch (escalation) {
    case LossEscalation::kNone:
      return "not escalated";
    case LossEscalation::kRepeatedLosses:
      return "in-place recovery WORKS but does not HOLD -- too many separate "
             "losses inside the guard window. Exiting so a supervisor can do "
             "what this process cannot.";
    case LossEscalation::kRecoveryExhausted:
      return "in-place recovery was tried the configured number of times and "
             "never produced a frame. Exiting so a supervisor can restart the "
             "process from scratch.";
  }
  return "not escalated";
}

LossAction ParseLossAction(const char* raw, LossAction fallback) {
  if (raw == nullptr || *raw == '\0') {
    return fallback;
  }
  if (EqualsIgnoreCase(raw, "exit") || EqualsIgnoreCase(raw, "quit")) {
    return LossAction::kExitProcess;
  }
  if (EqualsIgnoreCase(raw, "restart")) {
    return LossAction::kRestartEngine;
  }
  if (EqualsIgnoreCase(raw, "log") || EqualsIgnoreCase(raw, "none")) {
    return LossAction::kLogOnly;
  }
  return fallback;
}

const char* DescribeLossAction(LossAction action) {
  switch (action) {
    case LossAction::kLogOnly:
      return "log only";
    case LossAction::kExitProcess:
      return "exit the process";
    case LossAction::kRestartEngine:
      return "restart the Flutter engine";
  }
  return "log only";
}

}  // namespace tfc

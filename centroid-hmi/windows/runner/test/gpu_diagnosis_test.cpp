// Tests for the GPU device-loss diagnosis.
//
// The point of this code is that it runs exactly once, on a machine nobody is
// watching, at the moment the GPU dies -- and that what it writes is enough to
// tell a TDR from an RDP session swap without going back to the site. So the
// assertions below are mostly about the *content* of the report: a report that
// formats beautifully and omits the reason code is worthless.

#include "../gpu_diagnosis.h"

#include <string>

#include "test_harness.h"

namespace {

using tfc::AdapterVerdict;
using tfc::LossAction;
using tfc::LossEvidence;
using tfc::LossHint;

bool Contains(const std::string& haystack, const std::string& needle) {
  return haystack.find(needle) != std::string::npos;
}

// A loss with the sentinel dead of a GPU hang -- the TDR case.
LossEvidence HungEvidence() {
  LossEvidence evidence;
  evidence.sentinel_available = true;
  evidence.device_removed_reason = tfc::kDxgiDeviceHung;
  evidence.ms_since_start = 3600000;
  evidence.ms_since_last_frame = 10000;
  evidence.missed_probes = 2;
  evidence.adapter_description = "NVIDIA GeForce RTX 3050";
  evidence.adapter_vendor_id = 0x10DE;
  evidence.adapter_device_id = 0x2507;
  return evidence;
}

}  // namespace

// --- Reason codes -----------------------------------------------------------

// These constants were originally declared `enum DxgiReason : long`, which is
// fine on Unix (64-bit long) and overflows on MSVC (32-bit long) -- so the
// tests passed on macOS and the Windows build failed with C4369. The macOS
// test run structurally cannot catch that, so pin the width and the values
// here: a static_assert fires on whichever platform is wrong, at compile time,
// including this one.
static_assert(sizeof(tfc::DxgiReason) == 4,
              "DXGI reason codes must stay a fixed 32 bits -- HRESULT is "
              "32-bit on Windows regardless of what `long` is locally");
static_assert(static_cast<unsigned long long>(tfc::kDxgiDeviceHung) ==
                  0x887A0006ull,
              "reason codes must survive their declared underlying type");
static_assert(static_cast<unsigned long long>(tfc::kDxgiDriverInternalError) ==
                  0x887A0020ull,
              "reason codes must survive their declared underlying type");

TEST(classifies_every_named_dxgi_reason) {
  CHECK(tfc::ClassifyRemovedReason(tfc::kDxgiOk) == AdapterVerdict::kHealthy);
  CHECK(tfc::ClassifyRemovedReason(tfc::kDxgiDeviceHung) ==
        AdapterVerdict::kHung);
  CHECK(tfc::ClassifyRemovedReason(tfc::kDxgiDeviceRemoved) ==
        AdapterVerdict::kRemoved);
  CHECK(tfc::ClassifyRemovedReason(tfc::kDxgiDeviceReset) ==
        AdapterVerdict::kReset);
  CHECK(tfc::ClassifyRemovedReason(tfc::kDxgiDriverInternalError) ==
        AdapterVerdict::kDriverError);
}

TEST(an_unrecognised_reason_is_unknown_not_healthy) {
  // Anything non-zero means the device is gone. Treating an unmapped code as
  // healthy would point the next reader at the session path for what is
  // actually an adapter failure.
  CHECK(tfc::ClassifyRemovedReason(0x887A00FFu) == AdapterVerdict::kUnknown);
  // 0xFFFFFFFF is what a signed -1 HRESULT arrives as once GpuDeviceProbe has
  // cast it; it must not fall through to "healthy" either.
  CHECK(tfc::ClassifyRemovedReason(0xFFFFFFFFu) == AdapterVerdict::kUnknown);
}

TEST(named_reasons_print_their_name_and_hex) {
  char buffer[64];
  const std::string hung =
      tfc::DescribeRemovedReason(tfc::kDxgiDeviceHung, buffer, sizeof(buffer));
  CHECK(Contains(hung, "DXGI_ERROR_DEVICE_HUNG"));
  CHECK(Contains(hung, "887a0006"));
}

TEST(an_unnamed_reason_still_prints_its_code) {
  // The whole point is to be able to look the thing up afterwards, so an
  // unmapped code must still reach the log as a number.
  char buffer[64];
  const std::string described =
      tfc::DescribeRemovedReason(0x887A00FFu, buffer, sizeof(buffer));
  CHECK(Contains(described, "887a00ff"));
}

TEST(every_verdict_explains_itself) {
  const AdapterVerdict all[] = {
      AdapterVerdict::kHealthy, AdapterVerdict::kHung,
      AdapterVerdict::kRemoved, AdapterVerdict::kReset,
      AdapterVerdict::kDriverError, AdapterVerdict::kUnknown};
  for (AdapterVerdict verdict : all) {
    const char* explanation = tfc::ExplainVerdict(verdict);
    CHECK(explanation != nullptr);
    CHECK(std::string(explanation).size() > 20);
  }
}

// --- The report -------------------------------------------------------------

TEST(report_names_the_reason_and_the_adapter) {
  const std::string report = tfc::FormatLossReport(HungEvidence());

  CHECK(Contains(report, "DXGI_ERROR_DEVICE_HUNG"));
  CHECK(Contains(report, "NVIDIA GeForce RTX 3050"));
  CHECK(Contains(report, "10de"));
  CHECK(Contains(report, "2507"));
}

TEST(report_is_greppable_on_every_line) {
  // A log where this is buried in EGL spam is the reason this exists. Every
  // line must carry the tag, so `findstr [gpu-loss]` yields the whole block
  // and not one line out of the middle of it.
  const std::string report = tfc::FormatLossReport(HungEvidence());

  size_t start = 0;
  int lines = 0;
  while (start < report.size()) {
    size_t end = report.find('\n', start);
    if (end == std::string::npos) {
      end = report.size();
    }
    const std::string line = report.substr(start, end - start);
    if (!line.empty()) {
      lines++;
      CHECK(Contains(line, "[gpu-loss]"));
    }
    start = end + 1;
  }
  CHECK(lines >= 5);
}

TEST(a_live_sentinel_points_away_from_the_adapter) {
  // The single most valuable distinction the report draws: the GPU is fine, so
  // stop reading driver logs and go look at the session/desktop swap.
  LossEvidence evidence;
  evidence.sentinel_available = true;
  evidence.device_removed_reason = tfc::kDxgiOk;
  evidence.last_hint = LossHint::kSessionChange;
  evidence.remote_session = true;

  const std::string report = tfc::FormatLossReport(evidence);

  CHECK(Contains(report, "adapter is healthy"));
  CHECK(Contains(report, "session"));
}

TEST(a_missing_sentinel_is_reported_as_unknown_not_as_healthy) {
  // Without a sentinel the reason code is zero because we never asked, which
  // must not read as "the GPU is fine".
  LossEvidence evidence;
  evidence.sentinel_available = false;
  evidence.device_removed_reason = tfc::kDxgiOk;

  const std::string report = tfc::FormatLossReport(evidence);

  CHECK(!Contains(report, "adapter is healthy"));
  CHECK(Contains(report, "no sentinel"));
}

TEST(report_names_the_window_message_that_preceded_the_loss) {
  LossEvidence evidence = HungEvidence();
  evidence.last_hint = LossHint::kSessionChange;
  evidence.ms_since_last_hint = 1500;
  evidence.session_change_code = 4;  // WTS_REMOTE_DISCONNECT

  const std::string report = tfc::FormatLossReport(evidence);

  CHECK(Contains(report, "session change"));
  CHECK(Contains(report, "1500"));
  // Named, not just numbered: "(4)" alone sends the next reader to the wrong
  // event, and this whole file exists so nobody has to guess.
  CHECK(Contains(report, "WTS_REMOTE_DISCONNECT"));
}

TEST(session_change_codes_are_named) {
  char buffer[64];
  CHECK(Contains(tfc::DescribeSessionChange(1, buffer, sizeof(buffer)),
                 "WTS_CONSOLE_CONNECT"));
  CHECK(Contains(tfc::DescribeSessionChange(4, buffer, sizeof(buffer)),
                 "WTS_REMOTE_DISCONNECT"));
  CHECK(Contains(tfc::DescribeSessionChange(8, buffer, sizeof(buffer)),
                 "WTS_SESSION_UNLOCK"));
  CHECK(Contains(tfc::DescribeSessionChange(11, buffer, sizeof(buffer)),
                 "WTS_SESSION_TERMINATE"));
}

TEST(an_out_of_range_session_code_still_reaches_the_log) {
  char buffer[64];
  // Reading one past the name table would be a crash in the one code path that
  // must never crash.
  CHECK(Contains(tfc::DescribeSessionChange(12, buffer, sizeof(buffer)), "12"));
  CHECK(Contains(tfc::DescribeSessionChange(9999, buffer, sizeof(buffer)),
                 "9999"));
  CHECK(Contains(tfc::DescribeSessionChange(0, buffer, sizeof(buffer)), "0"));
}

TEST(durations_read_as_time_not_as_milliseconds) {
  CHECK_EQ(tfc::FormatDuration(3721000), std::string("1h 2m 1s"));
  CHECK_EQ(tfc::FormatDuration(125000), std::string("2m 5s"));
  CHECK_EQ(tfc::FormatDuration(900), std::string("0.9s"));
  CHECK_EQ(tfc::FormatDuration(0), std::string("0s"));
}

TEST(report_shows_uptime_both_ways) {
  // The human form for reading, the raw milliseconds for comparing two logs.
  LossEvidence evidence = HungEvidence();
  const std::string report = tfc::FormatLossReport(evidence);
  CHECK(Contains(report, "1h 0m 0s"));
  CHECK(Contains(report, "3600000"));
}

TEST(report_says_so_when_nothing_preceded_the_loss) {
  // "Out of a clear sky" is itself a finding -- it rules out the session and
  // power paths, which is what most of the hints exist to test for.
  const std::string report = tfc::FormatLossReport(HungEvidence());

  CHECK(Contains(report, "no preceding"));
}

TEST(report_carries_the_uptime_and_the_stall_length) {
  const std::string report = tfc::FormatLossReport(HungEvidence());

  CHECK(Contains(report, "3600000"));
  CHECK(Contains(report, "10000"));
}

TEST(report_records_whether_the_session_is_remote) {
  LossEvidence local = HungEvidence();
  local.remote_session = false;
  LossEvidence remote = HungEvidence();
  remote.remote_session = true;

  CHECK(Contains(tfc::FormatLossReport(local), "console"));
  CHECK(Contains(tfc::FormatLossReport(remote), "remote"));
}

TEST(an_unknown_adapter_does_not_print_an_empty_field) {
  LossEvidence evidence = HungEvidence();
  evidence.adapter_description.clear();
  evidence.adapter_vendor_id = 0;
  evidence.adapter_device_id = 0;

  const std::string report = tfc::FormatLossReport(evidence);

  CHECK(Contains(report, "unknown"));
}

// --- The action -------------------------------------------------------------

TEST(loss_action_parses_its_words) {
  CHECK(tfc::ParseLossAction("exit", LossAction::kLogOnly) ==
        LossAction::kExitProcess);
  CHECK(tfc::ParseLossAction("EXIT", LossAction::kLogOnly) ==
        LossAction::kExitProcess);
  CHECK(tfc::ParseLossAction("restart", LossAction::kLogOnly) ==
        LossAction::kRestartEngine);
  CHECK(tfc::ParseLossAction("log", LossAction::kExitProcess) ==
        LossAction::kLogOnly);
}

TEST(loss_action_falls_back_on_nonsense_rather_than_guessing) {
  CHECK(tfc::ParseLossAction(nullptr, LossAction::kExitProcess) ==
        LossAction::kExitProcess);
  CHECK(tfc::ParseLossAction("", LossAction::kExitProcess) ==
        LossAction::kExitProcess);
  CHECK(tfc::ParseLossAction("reboot the building", LossAction::kLogOnly) ==
        LossAction::kLogOnly);
}

TEST(every_action_describes_itself) {
  const LossAction all[] = {LossAction::kLogOnly, LossAction::kExitProcess,
                            LossAction::kRestartEngine};
  for (LossAction action : all) {
    CHECK(tfc::DescribeLossAction(action) != nullptr);
    CHECK(std::string(tfc::DescribeLossAction(action)).size() > 0);
  }
}

// --- What the report says about how it knows -------------------------------
//
// Added after the 2026-08-31 freeze, where the report that DID get written on
// an earlier occurrence said "reason: S_OK / the adapter is healthy" and was
// read as reassuring. It was accurate and it was about the wrong device.

TEST(the_report_says_how_the_loss_was_established) {
  LossEvidence evidence = HungEvidence();
  evidence.cause = tfc::LossCause::kContextLost;

  const std::string report = tfc::FormatLossReport(evidence);

  CHECK(Contains(report, "detected by:"));
  CHECK(Contains(report, "asked directly"));
}

TEST(an_inferred_loss_is_labelled_as_the_weaker_finding) {
  // "No frames for ten seconds" is also what a watchdog nobody is ticking
  // looks like. A report that does not say so invites the next reader to make
  // the same mistake the last three made.
  LossEvidence evidence = HungEvidence();
  evidence.cause = tfc::LossCause::kNoFramesPresented;

  const std::string report = tfc::FormatLossReport(evidence);

  CHECK(Contains(report, "INFERENCE"));
}

TEST(a_healthy_sentinel_on_an_inferred_loss_is_not_read_as_reassurance) {
  // The exact shape of the 2026-08-31 incident: the adapter is fine, and the
  // renderer is dead anyway, because what died was ANGLE's own device -- which
  // the runner cannot reach (see the note in gpu_diagnosis.h). The report has
  // to carry both facts, or a reader finds "the adapter is healthy" and stops.
  LossEvidence evidence = HungEvidence();
  evidence.sentinel_available = true;
  evidence.device_removed_reason = tfc::kDxgiOk;
  evidence.cause = tfc::LossCause::kNoFramesPresented;

  const std::string report = tfc::FormatLossReport(evidence);

  CHECK(Contains(report, "S_OK"));
  CHECK(Contains(report, "the adapter is healthy"));
  // ...and, in the same block, that the finding it rests on is the weak one.
  CHECK(Contains(report, "INFERENCE"));
}

TEST(an_escalated_exit_says_which_guard_fired) {
  LossEvidence evidence = HungEvidence();
  evidence.escalation = tfc::LossEscalation::kRepeatedLosses;

  const std::string report = tfc::FormatLossReport(evidence);

  CHECK(Contains(report, "escalated"));
}

TEST(an_unescalated_report_carries_no_escalation_line) {
  LossEvidence evidence = HungEvidence();
  evidence.escalation = tfc::LossEscalation::kNone;

  CHECK(!Contains(tfc::FormatLossReport(evidence), "escalated  :"));
}

TEST(the_report_counts_the_episode_against_the_loop_guard) {
  LossEvidence evidence = HungEvidence();
  evidence.losses_in_window = 2;
  evidence.max_losses_in_window = 3;
  evidence.recovery_attempts = 1;

  const std::string report = tfc::FormatLossReport(evidence);

  CHECK(Contains(report, "history    :"));
  CHECK(Contains(report, "2"));
  CHECK(Contains(report, "3"));
}

TEST(every_line_of_the_report_still_carries_the_gpu_loss_prefix) {
  // run-hmi.ps1 -Report greps for the literal "[gpu-loss]" to tell a freeze
  // the watchdog explained from one it slept through. A line without the
  // prefix is a line that tool cannot see.
  LossEvidence evidence = HungEvidence();
  evidence.cause = tfc::LossCause::kContextLost;
  evidence.escalation = tfc::LossEscalation::kRecoveryExhausted;

  const std::string report = tfc::FormatLossReport(evidence);

  size_t start = 0;
  int lines = 0;
  while (start < report.size()) {
    const size_t end = report.find('\n', start);
    const std::string line = report.substr(
        start, end == std::string::npos ? std::string::npos : end - start);
    if (!line.empty()) {
      CHECK(line.rfind("[gpu-loss] ", 0) == 0);
      lines++;
    }
    if (end == std::string::npos) {
      break;
    }
    start = end + 1;
  }
  CHECK(lines > 8);
}

TEST(every_cause_and_escalation_has_something_to_say) {
  const tfc::LossCause causes[] = {tfc::LossCause::kNoFramesPresented,
                                   tfc::LossCause::kContextLost,
                                   tfc::LossCause::kPlatformThreadWedged,
                                   tfc::LossCause::kRasterFailed};
  for (tfc::LossCause cause : causes) {
    CHECK(std::string(tfc::DescribeLossCause(cause)).size() > 0);
  }
  const tfc::LossEscalation escalations[] = {
      tfc::LossEscalation::kNone, tfc::LossEscalation::kRepeatedLosses,
      tfc::LossEscalation::kRecoveryExhausted};
  for (tfc::LossEscalation escalation : escalations) {
    CHECK(std::string(tfc::DescribeEscalation(escalation)).size() > 0);
  }
}

int main() { return tfc_test::RunAll(); }

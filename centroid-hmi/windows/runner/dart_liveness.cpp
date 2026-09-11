#include "dart_liveness.h"

#include <cstdio>

namespace tfc {
namespace {

std::string Seconds(unsigned long long ms) {
  char buffer[32];
  std::snprintf(buffer, sizeof(buffer), "%.1f", ms / 1000.0);
  return buffer;
}

}  // namespace

void DartLiveness::EpochStarted(long long epoch, unsigned long long now_ms) {
  epoch_ = epoch;
  watching_ = true;
  epoch_started_ms_ = now_ms;
  last_stamp_ms_ = 0;
  last_report_ms_ = 0;
  ever_stamped_ = false;
  silent_ = false;
  last_ = DartLivenessStamp();
}

DartLiveness::Decision DartLiveness::Snapshot(Verdict verdict,
                                              unsigned long long now_ms) const {
  Decision decision;
  decision.verdict = verdict;
  const unsigned long long reference =
      ever_stamped_ ? last_stamp_ms_ : epoch_started_ms_;
  decision.silence_ms = now_ms > reference ? now_ms - reference : 0;
  decision.last = last_;
  decision.ever_stamped = ever_stamped_;
  return decision;
}

DartLiveness::Decision DartLiveness::OnStamp(const DartLivenessStamp& stamp,
                                             unsigned long long now_ms) {
  // A stamp from a generation we are no longer watching proves nothing about
  // the live one. It is not merely noise: the 2026-09-10 freeze left an
  // orphaned generation's work still running for a while after its engine was
  // destroyed, and counting that as liveness would have hidden the freeze
  // behind the corpse of the engine that caused it.
  if (stamp.epoch >= 0 && epoch_ >= 0 && stamp.epoch != epoch_) {
    Decision decision = Snapshot(Verdict::kNothingToSay, now_ms);
    decision.last = stamp;
    return decision;
  }

  const bool first = !ever_stamped_;
  const bool was_silent = silent_;
  // The gap this stamp CLOSES, measured before it is recorded. Taking it
  // afterwards reads zero by construction, which is the one number that can
  // never be interesting.
  const unsigned long long closed_gap = Snapshot(Verdict::kNothingToSay, now_ms)
                                            .silence_ms;

  last_ = stamp;
  last_stamp_ms_ = now_ms;
  ever_stamped_ = true;
  silent_ = false;
  last_report_ms_ = 0;

  Decision decision = Snapshot(
      first ? Verdict::kFirstStamp
            : (was_silent ? Verdict::kRecovered : Verdict::kNothingToSay),
      now_ms);
  decision.silence_ms = closed_gap;
  return decision;
}

DartLiveness::Decision DartLiveness::Evaluate(unsigned long long now_ms) {
  if (!watching_) {
    // No engine generation has been started yet, so there is nothing whose
    // silence would mean anything. Deliberately a flag rather than "the epoch
    // start tick is zero": GetTickCount64 is small right after a boot, and a
    // detector that stays asleep for the first stretch of a cold-booted
    // station would miss exactly the startup it is meant to watch.
    return Decision();
  }

  const unsigned long long reference =
      ever_stamped_ ? last_stamp_ms_ : epoch_started_ms_;
  const unsigned long long threshold =
      ever_stamped_ ? config_.silent_after_ms : config_.startup_grace_ms;
  const unsigned long long silence = now_ms > reference ? now_ms - reference : 0;

  if (silence <= threshold) {
    return Snapshot(Verdict::kNothingToSay, now_ms);
  }

  if (!silent_) {
    silent_ = true;
    last_report_ms_ = now_ms;
    return Snapshot(
        ever_stamped_ ? Verdict::kSilent : Verdict::kNeverArrived, now_ms);
  }

  if (now_ms - last_report_ms_ >= config_.repeat_ms) {
    last_report_ms_ = now_ms;
    return Snapshot(Verdict::kStillSilent, now_ms);
  }

  return Snapshot(Verdict::kNothingToSay, now_ms);
}

std::string DescribeLiveness(const DartLiveness::Decision& decision,
                             const DartLiveness::Config& config) {
  const DartLivenessStamp& stamp = decision.last;
  switch (decision.verdict) {
    case DartLiveness::Verdict::kNothingToSay:
      return std::string();

    case DartLiveness::Verdict::kFirstStamp:
      return "UI isolate is ALIVE: first liveness stamp for epoch " +
             std::to_string(stamp.epoch) + " after " +
             Seconds(decision.silence_ms) + " s, uptime " +
             Seconds(stamp.uptime_ms) + " s, startup " +
             (stamp.startup_complete ? "complete" : "still in progress");

    case DartLiveness::Verdict::kSilent:
      return "UI isolate has gone SILENT: no liveness stamp for " +
             Seconds(decision.silence_ms) + " s (one is due every " +
             Seconds(config.expected_interval_ms) +
             " s). Last stamp: epoch " + std::to_string(stamp.epoch) +
             ", tick " + std::to_string(stamp.ticks) + ", uptime " +
             Seconds(stamp.uptime_ms) + " s, lag " +
             std::to_string(stamp.lag_ms) +
             " ms. The Dart side has stopped running its own clock -- this is "
             "the freeze, and it is NOT visible to the frame probe, which "
             "counts the frames the watchdog itself forces.";

    case DartLiveness::Verdict::kStillSilent:
      return "UI isolate STILL silent: " + Seconds(decision.silence_ms) +
             " s since the last stamp (epoch " + std::to_string(stamp.epoch) +
             ", tick " + std::to_string(stamp.ticks) + ")";

    case DartLiveness::Verdict::kRecovered:
      return "UI isolate is stamping again after " +
             Seconds(decision.silence_ms) +
             " s of silence -- the stall reported above has ENDED (epoch " +
             std::to_string(stamp.epoch) + ", tick " +
             std::to_string(stamp.ticks) + ")";

    case DartLiveness::Verdict::kNeverArrived:
      return "UI isolate NEVER stamped: " + Seconds(decision.silence_ms) +
             " s since this engine generation was created and no liveness "
             "stamp has arrived at all. Dart main() did not reach the point "
             "where it arms its timer -- the engine started but the app did "
             "not.";
  }
  return std::string();
}

}  // namespace tfc

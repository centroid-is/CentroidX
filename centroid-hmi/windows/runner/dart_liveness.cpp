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
  raster_failures_ = 0;
  raster_lost_ = false;
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
  decision.raster_failures = raster_failures_;
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

  // The raster verdict. Only a stamp that actually probed moves it: an older
  // Dart build, or a probe that could not be run, leaves the count where it
  // was rather than resetting it -- "unknown" must neither clear a real run
  // of failures nor add to it.
  if (stamp.raster_probed) {
    if (stamp.raster_ok) {
      if (raster_lost_) {
        decision.raster_recovered = true;
      }
      raster_failures_ = 0;
      raster_lost_ = false;
    } else {
      raster_failures_++;
      if (!raster_lost_ && config_.raster_failures_before_loss > 0 &&
          raster_failures_ >= config_.raster_failures_before_loss) {
        raster_lost_ = true;
        decision.raster_lost = true;
      }
    }
    decision.raster_failures = raster_failures_;
  }
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

std::string DescribeRaster(const DartLiveness::Decision& decision,
                           const DartLiveness::Config& config) {
  const DartLivenessStamp& stamp = decision.last;
  if (decision.raster_lost) {
    return "the engine CANNOT RASTERISE: " +
           std::to_string(decision.raster_failures) +
           " consecutive liveness stamps (" +
           Seconds(static_cast<unsigned long long>(decision.raster_failures) *
                   config.expected_interval_ms) +
           " s) reported that a 1 x 1 snapshot came back empty or did not "
           "come back at all, while the UI isolate itself is alive (epoch " +
           std::to_string(stamp.epoch) + ", tick " +
           std::to_string(stamp.ticks) + ", " + std::to_string(stamp.frames) +
           " frame(s) it built since the last stamp that nobody could see). "
           "This is the 2026-09-12 freeze: the next-frame probe is answered, "
           "the sentinel adapter is healthy and the engine writes no errors. "
           "Declaring the renderer lost.";
  }
  if (decision.raster_recovered) {
    return "the engine is rasterising again on its own (epoch " +
           std::to_string(stamp.epoch) + ", tick " +
           std::to_string(stamp.ticks) +
           ") -- the raster loss reported above has ENDED without a rebuild";
  }
  return std::string();
}

}  // namespace tfc

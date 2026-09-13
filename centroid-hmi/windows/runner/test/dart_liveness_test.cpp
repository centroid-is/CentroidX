#include "dart_liveness.h"

#include "test_harness.h"

namespace {

using tfc::DartLiveness;
using tfc::DartLivenessStamp;
using Verdict = tfc::DartLiveness::Verdict;

DartLiveness::Config FastConfig() {
  DartLiveness::Config config;
  config.expected_interval_ms = 1000;
  config.silent_after_ms = 3000;
  config.repeat_ms = 5000;
  config.startup_grace_ms = 6000;
  return config;
}

DartLivenessStamp StampFor(long long epoch, unsigned long long tick,
                           unsigned long long uptime_ms) {
  DartLivenessStamp stamp;
  stamp.epoch = epoch;
  stamp.ticks = tick;
  stamp.uptime_ms = uptime_ms;
  stamp.startup_complete = true;
  return stamp;
}

bool Mentions(const std::string& haystack, const char* needle) {
  return haystack.find(needle) != std::string::npos;
}

TEST(says_nothing_before_an_epoch_starts) {
  DartLiveness liveness(FastConfig());
  CHECK(liveness.Evaluate(100000).verdict == Verdict::kNothingToSay);
  CHECK(!liveness.ever_stamped());
}

TEST(first_stamp_is_reported_once) {
  DartLiveness liveness(FastConfig());
  liveness.EpochStarted(1, 1000);

  const DartLiveness::Decision first =
      liveness.OnStamp(StampFor(1, 1, 500), 2000);
  CHECK(first.verdict == Verdict::kFirstStamp);
  CHECK_EQ(first.silence_ms, 1000ull);
  CHECK(liveness.ever_stamped());

  const DartLiveness::Decision second =
      liveness.OnStamp(StampFor(1, 2, 1500), 3000);
  CHECK(second.verdict == Verdict::kNothingToSay);
}

TEST(stays_quiet_while_stamps_keep_arriving) {
  DartLiveness liveness(FastConfig());
  liveness.EpochStarted(1, 0);
  liveness.OnStamp(StampFor(1, 1, 0), 1000);

  for (unsigned long long now = 2000; now < 60000; now += 1000) {
    liveness.OnStamp(StampFor(1, now / 1000, now), now);
    CHECK(liveness.Evaluate(now).verdict == Verdict::kNothingToSay);
  }
  CHECK(!liveness.silent());
}

TEST(silence_after_stamps_started_is_the_freeze) {
  DartLiveness liveness(FastConfig());
  liveness.EpochStarted(1, 0);
  liveness.OnStamp(StampFor(1, 7, 7000), 7000);

  // Inside the threshold: nothing yet.
  CHECK(liveness.Evaluate(9000).verdict == Verdict::kNothingToSay);

  const DartLiveness::Decision gone = liveness.Evaluate(11000);
  CHECK(gone.verdict == Verdict::kSilent);
  CHECK_EQ(gone.silence_ms, 4000ull);
  CHECK_EQ(gone.last.ticks, 7ull);
  CHECK(liveness.silent());

  // Reported once, not on every tick.
  CHECK(liveness.Evaluate(12000).verdict == Verdict::kNothingToSay);
  CHECK(liveness.Evaluate(13000).verdict == Verdict::kNothingToSay);
}

TEST(silence_is_repeated_so_it_has_a_duration) {
  DartLiveness liveness(FastConfig());
  liveness.EpochStarted(1, 0);
  liveness.OnStamp(StampFor(1, 1, 0), 1000);

  CHECK(liveness.Evaluate(5000).verdict == Verdict::kSilent);
  CHECK(liveness.Evaluate(9000).verdict == Verdict::kNothingToSay);

  const DartLiveness::Decision again = liveness.Evaluate(10000);
  CHECK(again.verdict == Verdict::kStillSilent);
  CHECK_EQ(again.silence_ms, 9000ull);

  CHECK(liveness.Evaluate(14000).verdict == Verdict::kNothingToSay);
  CHECK(liveness.Evaluate(15000).verdict == Verdict::kStillSilent);
}

TEST(a_returning_stamp_ends_the_episode) {
  DartLiveness liveness(FastConfig());
  liveness.EpochStarted(1, 0);
  liveness.OnStamp(StampFor(1, 1, 0), 1000);
  CHECK(liveness.Evaluate(5000).verdict == Verdict::kSilent);

  const DartLiveness::Decision back =
      liveness.OnStamp(StampFor(1, 2, 6000), 6000);
  CHECK(back.verdict == Verdict::kRecovered);
  CHECK_EQ(back.silence_ms, 5000ull);
  CHECK(!liveness.silent());

  // And the next silence is reported afresh rather than being swallowed by
  // the latch from the previous episode.
  CHECK(liveness.Evaluate(10000).verdict == Verdict::kSilent);
}

TEST(an_isolate_that_never_starts_is_its_own_finding) {
  DartLiveness liveness(FastConfig());
  liveness.EpochStarted(4, 1000);

  // The startup grace is longer than the silence threshold: a cold boot must
  // not be reported as a freeze.
  CHECK(liveness.Evaluate(5000).verdict == Verdict::kNothingToSay);

  const DartLiveness::Decision never = liveness.Evaluate(8000);
  CHECK(never.verdict == Verdict::kNeverArrived);
  CHECK_EQ(never.silence_ms, 7000ull);
  CHECK(!never.ever_stamped);
}

TEST(a_stamp_from_a_torn_down_generation_is_not_liveness) {
  DartLiveness liveness(FastConfig());
  liveness.EpochStarted(2, 0);

  // Epoch 1's isolate is still finishing work of its own after its engine was
  // destroyed. That says nothing about epoch 2.
  const DartLiveness::Decision stale =
      liveness.OnStamp(StampFor(1, 99, 500000), 1000);
  CHECK(stale.verdict == Verdict::kNothingToSay);
  CHECK(!liveness.ever_stamped());

  // ...and epoch 2's own silence is still reported.
  CHECK(liveness.Evaluate(8000).verdict == Verdict::kNeverArrived);
}

TEST(a_new_epoch_forgets_the_previous_one) {
  DartLiveness liveness(FastConfig());
  liveness.EpochStarted(1, 0);
  liveness.OnStamp(StampFor(1, 5, 5000), 5000);
  CHECK(liveness.Evaluate(20000).verdict == Verdict::kSilent);

  liveness.EpochStarted(2, 20000);
  CHECK(!liveness.ever_stamped());
  CHECK(!liveness.silent());
  CHECK_EQ(liveness.epoch(), 2ll);
  // The previous epoch's stamp must not keep the new one looking alive.
  CHECK(liveness.Evaluate(21000).verdict == Verdict::kNothingToSay);
  CHECK(liveness.Evaluate(27000).verdict == Verdict::kNeverArrived);
}

TEST(the_lines_say_what_happened) {
  const DartLiveness::Config config = FastConfig();
  DartLiveness liveness(config);
  liveness.EpochStarted(3, 0);

  const std::string first =
      DescribeLiveness(liveness.OnStamp(StampFor(3, 1, 900), 1000), config);
  CHECK(Mentions(first, "ALIVE"));
  CHECK(Mentions(first, "epoch 3"));

  const std::string silent =
      DescribeLiveness(liveness.Evaluate(20000), config);
  CHECK(Mentions(silent, "SILENT"));
  CHECK(Mentions(silent, "19.0 s"));
  // The line must name the trap that cost hours: the frame probe counting its
  // own forced frames.
  CHECK(Mentions(silent, "forces"));

  const std::string recovered =
      DescribeLiveness(liveness.OnStamp(StampFor(3, 2, 21000), 21000), config);
  CHECK(Mentions(recovered, "ENDED"));

  CHECK(DescribeLiveness(liveness.Evaluate(21500), config).empty());
}

TEST(a_never_arrived_line_blames_dart_not_the_engine) {
  const DartLiveness::Config config = FastConfig();
  DartLiveness liveness(config);
  liveness.EpochStarted(9, 0);
  const std::string line = DescribeLiveness(liveness.Evaluate(10000), config);
  CHECK(Mentions(line, "NEVER stamped"));
  CHECK(Mentions(line, "main()"));
}

// --- The raster verdict -----------------------------------------------------
//
// The 2026-09-12 freeze: the isolate stamps on time with frames counted, the
// next-frame probe answers, the sentinel is healthy, stderr is quiet -- and
// the engine returns an empty image for every snapshot. The stamp now carries
// that answer, and the verdict below is the only detector that saw it.

DartLivenessStamp RasterStamp(unsigned long long tick, bool ok) {
  DartLivenessStamp stamp = StampFor(1, tick, tick * 1000);
  stamp.raster_probed = true;
  stamp.raster_ok = ok;
  stamp.frames = 25;
  return stamp;
}

TEST(three_consecutive_failed_raster_probes_declare_the_renderer_lost) {
  DartLiveness liveness(FastConfig());
  liveness.EpochStarted(1, 0);
  liveness.OnStamp(RasterStamp(1, true), 1000);

  DartLiveness::Decision one = liveness.OnStamp(RasterStamp(2, false), 2000);
  CHECK(!one.raster_lost);
  CHECK_EQ(one.raster_failures, 1);
  DartLiveness::Decision two = liveness.OnStamp(RasterStamp(3, false), 3000);
  CHECK(!two.raster_lost);
  CHECK_EQ(two.raster_failures, 2);

  DartLiveness::Decision three = liveness.OnStamp(RasterStamp(4, false), 4000);
  CHECK(three.raster_lost);
  CHECK_EQ(three.raster_failures, 3);
  CHECK(liveness.raster_lost());
  // The isolate is fine throughout: the silence verdict has nothing to say.
  CHECK(three.verdict == Verdict::kNothingToSay);
}

TEST(the_raster_loss_is_declared_once_per_episode) {
  DartLiveness liveness(FastConfig());
  liveness.EpochStarted(1, 0);
  for (unsigned long long tick = 1; tick <= 3; tick++) {
    liveness.OnStamp(RasterStamp(tick, false), tick * 1000);
  }
  CHECK(liveness.raster_lost());
  // The loss path is rebuilding; until a new epoch, keep counting quietly.
  DartLiveness::Decision fourth = liveness.OnStamp(RasterStamp(4, false), 4000);
  CHECK(!fourth.raster_lost);
  CHECK_EQ(fourth.raster_failures, 4);
}

TEST(a_successful_probe_resets_the_run) {
  DartLiveness liveness(FastConfig());
  liveness.EpochStarted(1, 0);
  liveness.OnStamp(RasterStamp(1, false), 1000);
  liveness.OnStamp(RasterStamp(2, false), 2000);
  DartLiveness::Decision ok = liveness.OnStamp(RasterStamp(3, true), 3000);
  CHECK(!ok.raster_lost);
  CHECK(!ok.raster_recovered);
  CHECK_EQ(ok.raster_failures, 0);
  // Two more failures are two, not four.
  liveness.OnStamp(RasterStamp(4, false), 4000);
  DartLiveness::Decision second = liveness.OnStamp(RasterStamp(5, false), 5000);
  CHECK(!second.raster_lost);
  CHECK_EQ(second.raster_failures, 2);
}

TEST(a_stamp_that_did_not_probe_is_not_evidence_either_way) {
  // An older Dart build, or a probe that threw: the count neither grows nor
  // resets. "Unknown" must not clear a real run, and must not add to it.
  DartLiveness liveness(FastConfig());
  liveness.EpochStarted(1, 0);
  liveness.OnStamp(RasterStamp(1, false), 1000);
  liveness.OnStamp(RasterStamp(2, false), 2000);
  DartLiveness::Decision unknown = liveness.OnStamp(StampFor(1, 3, 3000), 3000);
  CHECK(!unknown.raster_lost);
  CHECK_EQ(liveness.raster_failures(), 2);
  DartLiveness::Decision third = liveness.OnStamp(RasterStamp(4, false), 4000);
  CHECK(third.raster_lost);

  // And a build that never probes never declares, however long it runs.
  DartLiveness plain(FastConfig());
  plain.EpochStarted(1, 0);
  for (unsigned long long tick = 1; tick <= 50; tick++) {
    CHECK(!plain.OnStamp(StampFor(1, tick, tick * 1000), tick * 1000).raster_lost);
  }
  CHECK(!plain.raster_lost());
}

TEST(a_renderer_that_recovers_on_its_own_says_so_once) {
  DartLiveness liveness(FastConfig());
  liveness.EpochStarted(1, 0);
  for (unsigned long long tick = 1; tick <= 3; tick++) {
    liveness.OnStamp(RasterStamp(tick, false), tick * 1000);
  }
  DartLiveness::Decision back = liveness.OnStamp(RasterStamp(4, true), 4000);
  CHECK(back.raster_recovered);
  CHECK(!liveness.raster_lost());
  CHECK(!liveness.OnStamp(RasterStamp(5, true), 5000).raster_recovered);
}

TEST(a_new_epoch_forgets_the_raster_run) {
  DartLiveness liveness(FastConfig());
  liveness.EpochStarted(1, 0);
  liveness.OnStamp(RasterStamp(1, false), 1000);
  liveness.OnStamp(RasterStamp(2, false), 2000);
  // The loss path rebuilt the engine: its context is a new question.
  liveness.EpochStarted(2, 3000);
  CHECK_EQ(liveness.raster_failures(), 0);
  DartLivenessStamp stamp = RasterStamp(1, false);
  stamp.epoch = 2;
  CHECK(!liveness.OnStamp(stamp, 4000).raster_lost);
  CHECK_EQ(liveness.raster_failures(), 1);
}

TEST(a_zero_threshold_disables_the_raster_verdict) {
  DartLiveness::Config config = FastConfig();
  config.raster_failures_before_loss = 0;
  DartLiveness liveness(config);
  liveness.EpochStarted(1, 0);
  for (unsigned long long tick = 1; tick <= 20; tick++) {
    CHECK(!liveness.OnStamp(RasterStamp(tick, false), tick * 1000).raster_lost);
  }
}

TEST(the_raster_lines_say_what_happened) {
  DartLiveness liveness(FastConfig());
  liveness.EpochStarted(1, 0);
  CHECK(DescribeRaster(liveness.OnStamp(RasterStamp(1, false), 1000),
                       liveness.config())
            .empty());
  liveness.OnStamp(RasterStamp(2, false), 2000);
  const std::string lost = DescribeRaster(
      liveness.OnStamp(RasterStamp(3, false), 3000), liveness.config());
  CHECK(Mentions(lost, "CANNOT RASTERISE"));
  CHECK(Mentions(lost, "3 consecutive"));
  CHECK(Mentions(lost, "3.0 s"));
  CHECK(Mentions(lost, "25 frame(s)"));

  const std::string back = DescribeRaster(
      liveness.OnStamp(RasterStamp(4, true), 4000), liveness.config());
  CHECK(Mentions(back, "rasterising again"));
  CHECK(Mentions(back, "ENDED without a rebuild"));

  CHECK(DescribeRaster(liveness.OnStamp(RasterStamp(5, true), 5000),
                       liveness.config())
            .empty());
}

}  // namespace

int main() { return tfc_test::RunAll(); }

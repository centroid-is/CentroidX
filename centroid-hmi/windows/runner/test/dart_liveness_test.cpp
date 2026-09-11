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

}  // namespace

int main() { return tfc_test::RunAll(); }

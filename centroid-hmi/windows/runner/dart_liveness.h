#ifndef RUNNER_DART_LIVENESS_H_
#define RUNNER_DART_LIVENESS_H_

#include <string>

// Decides whether the UI isolate is still alive, from stamps the isolate
// sends of its own accord.
//
// WHY THIS EXISTS, and why the existing detectors could not answer it.
//
// On 2026-09-10 a station froze at 16:01:36. Every native health signal read
// healthy for the whole incident, and a full dump of the wedged process
// confirmed they were right to: the platform thread was idle in
// NtUserGetMessage, the other 34 threads were parked in ordinary condition
// waits, and no lock was held by anyone. Nothing was blocked. Nothing was
// scheduling frames either. The Dart side had simply stopped doing anything,
// and every watcher in the runner watches native code.
//
// The GPU watchdog's frame counter is specifically NOT a substitute. It calls
// ForceRedraw() itself on every tick and then counts the frames it forced, so
// it reads "1 frame per 5 s" on a healthy station and "1 frame per 5 s" on a
// frozen one -- measured identical across days of both. A detector whose input
// is its own output cannot distinguish anything.
//
// So the signal here is one the runner does not produce and cannot provoke: a
// periodic Timer inside the UI isolate posts a stamp over a method channel. If
// the isolate is gone, wedged, or was torn down by an engine rebuild that
// never came back, the stamps simply stop, and their absence is the finding.
// The runner notices the absence from its timer-queue thread, which nothing in
// the message queue can starve.
//
// Pure logic, no I/O and no Windows headers, so the thresholds are testable
// the same way GpuWatchdog's and EglStormDetector's are.

namespace tfc {

// One stamp exactly as the UI isolate reported it.
struct DartLivenessStamp {
  // Which engine generation sent it. The runner hands each engine its epoch
  // as a Dart entrypoint argument, so a stamp from a torn-down generation is
  // recognisable rather than being mistaken for the live one.
  long long epoch = -1;
  // Milliseconds since Dart main() began, by the isolate's own clock.
  unsigned long long uptime_ms = 0;
  // How many times the isolate's stamp timer has fired since main(). Its
  // steady increase is the liveness; a gap says the event loop stalled.
  unsigned long long ticks = 0;
  // Frames the engine has reported to Dart's own timings callback since the
  // previous stamp. Contaminated by the watchdog's ForceRedraw and read only
  // as colour on the line -- `ticks` and the stamp's arrival are the signal.
  unsigned long long frames = 0;
  // How late this stamp's timer fired against its ideal deadline. A healthy
  // UI isolate is within a few ms; hundreds of ms means the event loop is
  // congested even though it has not stopped.
  unsigned long long lag_ms = 0;
  // Whether Dart has finished its own startup (see FlutterWindow's runner
  // channel). False stamps are still liveness -- they say the isolate is
  // running, just not ready.
  bool startup_complete = false;
};

class DartLiveness {
 public:
  struct Config {
    // What the isolate promises. Only used to phrase the log line.
    unsigned long long expected_interval_ms = 10000;
    // Silence past this, once stamps have started, is a finding. Three missed
    // stamps: long enough that a garbage collection or a slow page build does
    // not cry wolf, short enough that an operator's "it's frozen" phone call
    // arrives after the log already said so.
    unsigned long long silent_after_ms = 30000;
    // While silent, say so again this often rather than once and never again
    // -- the run that froze at 16:01 was looked at the next morning, and a
    // single line at the moment of failure is easy to scroll past.
    unsigned long long repeat_ms = 60000;
    // A fresh engine gets this long to produce its FIRST stamp before the
    // silence is reported. Covers engine boot, the Dart snapshot loading and
    // main() reaching the point where it arms the timer. Measured on the
    // plant boxes that is a couple of seconds; the allowance is generous
    // because a false "Dart never started" on a slow cold boot would teach
    // people to ignore the line.
    unsigned long long startup_grace_ms = 60000;
  };

  enum class Verdict {
    // Nothing worth a log line.
    kNothingToSay,
    // The first stamp of this epoch: the UI isolate is confirmed running.
    kFirstStamp,
    // Stamps were arriving and have stopped. This is the freeze.
    kSilent,
    // Still stopped, repeated so the silence has a duration in the log.
    kStillSilent,
    // Stamps came back without an engine rebuild.
    kRecovered,
    // No stamp has EVER arrived for this epoch and the grace is spent: the
    // isolate did not start, or was torn down before it could arm its timer.
    kNeverArrived,
  };

  struct Decision {
    Verdict verdict = Verdict::kNothingToSay;
    // Since the last stamp, or since the epoch began when there was none.
    unsigned long long silence_ms = 0;
    // The most recent stamp; default-constructed when none has arrived.
    DartLivenessStamp last;
    bool ever_stamped = false;
  };

  DartLiveness() : DartLiveness(Config()) {}
  explicit DartLiveness(Config config) : config_(config) {}

  // Begin watching a fresh engine generation. Clears everything: a stamp
  // from the previous generation must not make the new one look alive.
  void EpochStarted(long long epoch, unsigned long long now_ms);

  // Feed a stamp as it arrives on the platform thread.
  Decision OnStamp(const DartLivenessStamp& stamp, unsigned long long now_ms);

  // Ask, from the watchdog tick, whether the silence is worth reporting.
  Decision Evaluate(unsigned long long now_ms);

  bool ever_stamped() const { return ever_stamped_; }
  bool silent() const { return silent_; }
  long long epoch() const { return epoch_; }
  const DartLivenessStamp& last_stamp() const { return last_; }
  const Config& config() const { return config_; }

 private:
  Decision Snapshot(Verdict verdict, unsigned long long now_ms) const;

  Config config_;
  // Whether an engine generation is being watched at all. See Evaluate.
  bool watching_ = false;
  long long epoch_ = -1;
  unsigned long long epoch_started_ms_ = 0;
  unsigned long long last_stamp_ms_ = 0;
  unsigned long long last_report_ms_ = 0;
  bool ever_stamped_ = false;
  bool silent_ = false;
  DartLivenessStamp last_;
};

// The log line for a decision, or an empty string for kNothingToSay. Kept
// beside the state machine and away from the window so the wording is
// testable -- the wording IS the deliverable here.
std::string DescribeLiveness(const DartLiveness::Decision& decision,
                             const DartLiveness::Config& config);

}  // namespace tfc

#endif  // RUNNER_DART_LIVENESS_H_

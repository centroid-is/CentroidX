#include "engine_rebuild_gate.h"

#include <cstdio>

namespace tfc {
namespace {

std::string Seconds(unsigned long long ms) {
  char buffer[32];
  std::snprintf(buffer, sizeof(buffer), "%.1f", ms / 1000.0);
  return buffer;
}

}  // namespace

void EngineRebuildGate::EngineCreated(unsigned long long now_ms) {
  startup_in_flight_ = true;
  startup_started_ms_ = now_ms;
}

void EngineRebuildGate::StartupComplete(unsigned long long now_ms) {
  (void)now_ms;
  startup_in_flight_ = false;
}

bool EngineRebuildGate::StartupBlocking(unsigned long long now_ms) const {
  if (!startup_in_flight_) {
    return false;
  }
  const unsigned long long elapsed =
      now_ms > startup_started_ms_ ? now_ms - startup_started_ms_ : 0;
  return elapsed < config_.startup_timeout_ms;
}

EngineRebuildGate::Decision EngineRebuildGate::Release(
    unsigned long long now_ms) {
  Decision decision;
  decision.verdict = Verdict::kRebuildNow;
  decision.coalesced = queued_count_ == 0 ? 1 : queued_count_;
  decision.reason = queued_reason_;
  decision.waited_ms = queued_ ? (now_ms > queued_since_ms_
                                      ? now_ms - queued_since_ms_
                                      : 0)
                               : 0;
  decision.startup_timed_out = queued_ && startup_in_flight_;

  queued_ = false;
  queued_count_ = 0;
  queued_since_ms_ = 0;
  queued_reason_.clear();

  last_rebuild_ms_ = now_ms;
  ever_rebuilt_ = true;
  return decision;
}

EngineRebuildGate::Decision EngineRebuildGate::Request(
    const std::string& reason, unsigned long long now_ms) {
  // The debounce still earns its place: one disconnect emits several
  // WM_WTSSESSION_CHANGE messages inside a second, and they all describe the
  // same event. Checked first so a duplicate never even reaches the queue --
  // otherwise five duplicates during a startup would queue a rebuild that
  // nothing actually asked for.
  if (ever_rebuilt_ && now_ms >= last_rebuild_ms_ &&
      now_ms - last_rebuild_ms_ < config_.debounce_ms) {
    Decision decision;
    decision.verdict = Verdict::kDebounced;
    decision.reason = reason;
    return decision;
  }

  if (StartupBlocking(now_ms)) {
    Decision decision;
    decision.verdict = queued_ ? Verdict::kCoalesced : Verdict::kQueued;
    if (!queued_) {
      queued_ = true;
      queued_since_ms_ = now_ms;
    }
    queued_count_++;
    // The newest reason wins: a disconnect followed by a reconnect must be
    // logged as having been answered by a rebuild for the reconnect, which is
    // the state the renderer has to end up matching.
    queued_reason_ = reason;
    decision.coalesced = queued_count_;
    decision.reason = reason;
    decision.waited_ms = now_ms > queued_since_ms_ ? now_ms - queued_since_ms_ : 0;
    return decision;
  }

  // Nothing in the way. Note that a queued request may exist here if the
  // startup timed out between the last Poll and now; releasing folds it in
  // rather than dropping it.
  queued_count_++;
  queued_reason_ = reason;
  if (!queued_) {
    queued_since_ms_ = now_ms;
  }
  queued_ = true;
  return Release(now_ms);
}

EngineRebuildGate::Decision EngineRebuildGate::Poll(
    unsigned long long now_ms) {
  if (!queued_) {
    return Decision();
  }
  if (StartupBlocking(now_ms)) {
    return Decision();
  }
  return Release(now_ms);
}

std::string DescribeEngineRebuild(
    const EngineRebuildGate::Decision& decision) {
  const std::string& reason =
      decision.reason.empty() ? std::string("unspecified") : decision.reason;
  switch (decision.verdict) {
    case EngineRebuildGate::Verdict::kIdle:
      return std::string();

    case EngineRebuildGate::Verdict::kDebounced:
      return "rebuild request (" + reason +
             ") ignored: a duplicate of the one the rebuild just above "
             "already answered";

    case EngineRebuildGate::Verdict::kQueued:
      return "rebuild request (" + reason +
             ") QUEUED: the current engine is still starting up. Tearing one "
             "down mid-startup orphaned a generation of OPC UA clients on "
             "2026-09-10, and on 2026-09-11 it restarted a startup three "
             "times over until the app never came up at all. The rebuild will "
             "run once startup reports complete.";

    case EngineRebuildGate::Verdict::kCoalesced:
      return "rebuild request (" + reason +
             ") folded into the queued rebuild -- " +
             std::to_string(decision.coalesced) +
             " request(s) will now cost one rebuild, not " +
             std::to_string(decision.coalesced);

    case EngineRebuildGate::Verdict::kRebuildNow:
      if (decision.waited_ms == 0 && decision.coalesced <= 1) {
        return "rebuild request (" + reason +
               ") -- REBUILDING the renderer rather than probing it. The probe "
               "cannot see this class of loss: the next-frame callback is "
               "answered whether or not rasterisation succeeded.";
      }
      return "rebuild request (" + reason + ") -- REBUILDING now, answering " +
             std::to_string(decision.coalesced) +
             " queued request(s) after waiting " +
             Seconds(decision.waited_ms) +
             " s for startup" +
             (decision.startup_timed_out
                  ? ", which never reported complete -- rebuilding anyway "
                    "rather than leaving the operator without a renderer"
                  : " to finish");
  }
  return std::string();
}

}  // namespace tfc

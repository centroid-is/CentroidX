#include "session_rebuild_policy.h"

#include <cstdio>

namespace tfc {
namespace {

std::string Seconds(unsigned long long ms) {
  char buffer[32];
  std::snprintf(buffer, sizeof(buffer), "%.1f", ms / 1000.0);
  return buffer;
}

}  // namespace

AdapterCheck ClassifyAdapterCheck(bool engine_known,
                                  unsigned long long engine_luid,
                                  bool current_known,
                                  unsigned long long current_luid) {
  if (!engine_known || !current_known) {
    return AdapterCheck::kUnknown;
  }
  return engine_luid == current_luid ? AdapterCheck::kSame
                                     : AdapterCheck::kChanged;
}

const char* DescribeAdapterCheck(AdapterCheck check) {
  switch (check) {
    case AdapterCheck::kUnknown:
      return "the render adapter could not be compared (the engine or DXGI "
             "did not report one -- measured to happen in a third of "
             "session-change windows, so this is not evidence)";
    case AdapterCheck::kSame:
      return "the engine still renders on the session's display adapter";
    case AdapterCheck::kChanged:
      return "the engine renders on an adapter that is NO LONGER the "
             "session's display adapter";
  }
  return "";
}

void SessionRebuildPolicy::EngineCreated(unsigned long long now_ms) {
  (void)now_ms;
  suspect_ = false;
  probation_ = false;
  probation_since_ms_ = 0;
}

SessionRebuildPolicy::Decision SessionRebuildPolicy::OnRemoteDisconnect(
    unsigned long long now_ms) {
  (void)now_ms;
  Decision decision;
  // A disconnect during a probation makes the probation moot: nobody is
  // looking any more, so its deadline must not rebuild an unattended engine.
  const bool was_probing = probation_;
  probation_ = false;
  probation_since_ms_ = 0;
  if (suspect_ && !was_probing) {
    // One of the several messages one disconnect emits. Already handled.
    return decision;
  }
  suspect_ = true;
  decision.verdict = Verdict::kDeferred;
  return decision;
}

SessionRebuildPolicy::Decision SessionRebuildPolicy::OnRemoteConnect(
    unsigned long long now_ms, AdapterCheck adapter) {
  Decision decision;
  decision.adapter = adapter;

  if (adapter == AdapterCheck::kChanged) {
    // Positive evidence outranks everything, an open probation included.
    suspect_ = false;
    probation_ = false;
    decision.verdict = Verdict::kRebuildNow;
    decision.reason = "session change: remote connect (render adapter changed)";
    return decision;
  }

  if (!config_.storm_detector_available) {
    // The probe is blind to the loss this connect might reveal, and nothing
    // else is watching for it. The old unconditional rebuild is the right
    // answer here; it is the ONLY place it still is.
    suspect_ = false;
    probation_ = false;
    decision.verdict = Verdict::kRebuildNow;
    decision.reason =
        "session change: remote connect (no context-loss detector installed)";
    return decision;
  }

  if (probation_) {
    // A duplicate of the connect that opened the probation.
    return decision;
  }

  probation_ = true;
  probation_since_ms_ = now_ms;
  decision.verdict = Verdict::kProbe;
  decision.waited_ms = config_.reconnect_probation_ms;
  return decision;
}

SessionRebuildPolicy::Decision SessionRebuildPolicy::OnFramePresented(
    unsigned long long now_ms) {
  Decision decision;
  if (!probation_) {
    return decision;
  }
  decision.verdict = Verdict::kKeptRenderer;
  decision.waited_ms =
      now_ms > probation_since_ms_ ? now_ms - probation_since_ms_ : 0;
  probation_ = false;
  probation_since_ms_ = 0;
  suspect_ = false;
  return decision;
}

SessionRebuildPolicy::Decision SessionRebuildPolicy::OnTick(
    unsigned long long now_ms) {
  Decision decision;
  if (!probation_) {
    return decision;
  }
  const unsigned long long waited =
      now_ms > probation_since_ms_ ? now_ms - probation_since_ms_ : 0;
  if (waited < config_.reconnect_probation_ms) {
    return decision;
  }
  probation_ = false;
  probation_since_ms_ = 0;
  suspect_ = false;
  decision.verdict = Verdict::kRebuildNow;
  decision.waited_ms = waited;
  decision.reason = "session change: remote connect (no frame within " +
                    Seconds(config_.reconnect_probation_ms) + " s)";
  return decision;
}

std::string DescribeSessionRebuild(
    const SessionRebuildPolicy::Decision& decision) {
  switch (decision.verdict) {
    case SessionRebuildPolicy::Verdict::kNone:
      return std::string();

    case SessionRebuildPolicy::Verdict::kDeferred:
      return "session change (remote disconnect) -- NOT rebuilding: nobody is "
             "viewing this session and no frames are owed. The context is "
             "marked suspect and the next remote connect decides. The "
             "sentinel device and the stderr storm detector stay armed, so a "
             "loss that is actually observed while disconnected is still "
             "recovered -- and the operator's page and pending proposals now "
             "survive that recovery.";

    case SessionRebuildPolicy::Verdict::kProbe:
      return std::string("session change (remote connect) -- PROBING before "
                         "rebuilding: ") +
             DescribeAdapterCheck(decision.adapter) +
             ". The renderer has " + Seconds(decision.waited_ms) +
             " s to present a frame; the storm detector is watching for a "
             "context the frame probe cannot see. Until the 2026-09-12 change "
             "this connect rebuilt the engine unconditionally.";

    case SessionRebuildPolicy::Verdict::kKeptRenderer:
      return "remote connect: the renderer presented a frame " +
             Seconds(decision.waited_ms) +
             " s after the reconnect -- KEPT, no rebuild. The operator is "
             "still on their page with their proposals.";

    case SessionRebuildPolicy::Verdict::kRebuildNow:
      return std::string("session change -- REBUILDING: ") +
             (decision.reason.empty() ? std::string("unspecified")
                                      : decision.reason) +
             (decision.adapter == AdapterCheck::kChanged
                  ? std::string(". ") + DescribeAdapterCheck(decision.adapter)
                  : std::string());
  }
  return std::string();
}

}  // namespace tfc

#include "flutter_window.h"

#include <windows.h>
#include <ole2.h>
#include <wtsapi32.h>

#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <optional>
#include <sstream>
#include <string>
#include <typeinfo>
#include <utility>
#include <variant>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "runner_log.h"

// The GPU device-loss problem this file guards against is described in
// gpu_watchdog.h. Everything below is adapter: window messages, engine
// callbacks and the watchdog's own timer thread in, tfc::GpuWatchdog decisions
// out.
//
// Tunables, read once at startup:
//   CENTROID_GPU_WATCHDOG=0               disable the watchdog entirely
//   CENTROID_GPU_WATCHDOG_INTERVAL_MS=n   probe interval, default 5000
//   CENTROID_GPU_ON_LOSS=restart|exit|log what to do once the renderer is
//                                         judged dead, default restart

namespace {

// The tick, sent from the timer-queue thread to the platform thread. WM_APP is
// the range reserved for an application's own messages; nothing in the engine
// or in Win32Window claims it.
constexpr UINT kWatchdogTickMessage = WM_APP + 0x47;

// Posted from the stderr reader thread when the engine's own error output
// crosses the context-lost storm threshold. wparam carries the match count.
constexpr UINT kEglStormMessage = WM_APP + 0x48;

// Posted to ourselves when a session-change rebuild that was queued behind an
// unfinished startup becomes due. Posted, never done inline, because the point
// at which it becomes due is inside a method call from the very engine the
// rebuild destroys.
constexpr UINT kSessionRebuildDueMessage = WM_APP + 0x49;

// The stale WM_TIMER id. Nothing arms it any more -- see the note on the tick
// in flutter_window.h -- but a build that rolls back and forward could leave
// one running, so teardown still kills it.
constexpr UINT_PTR kLegacyWatchdogTimerId = 1;

// How long the timer thread waits for the platform thread to take the tick.
// Generous: the platform thread may legitimately be inside a long frame or a
// modal resize loop, and being wrong here means declaring a healthy renderer
// dead. On the frozen station a sent message came back in 10 ms.
constexpr UINT kTickSendTimeoutMs = 4000;

// Consecutive unanswered sends before the platform thread is declared wedged.
// At a 5s period that is a minute of a thread that will not accept a message
// even ahead of its posted queue.
constexpr int kUnansweredSendsBeforeWedged = 12;

std::optional<std::string> GetEnvVar(const char* name) {
  char* value = nullptr;
  size_t len = 0;
  if (_dupenv_s(&value, &len, name) != 0 || value == nullptr) {
    return std::nullopt;
  }
  std::string result(value);
  free(value);
  return result;
}

const char* CStrOrNull(const std::optional<std::string>& value) {
  return value.has_value() ? value->c_str() : nullptr;
}

tfc::GpuWatchdog::Config WatchdogConfigFromEnvironment() {
  tfc::GpuWatchdog::Config config;
  config.probe_interval_ms = tfc::ParseProbeIntervalMs(
      CStrOrNull(GetEnvVar("CENTROID_GPU_WATCHDOG_INTERVAL_MS")),
      config.probe_interval_ms);
  config.on_loss = tfc::ParseLossAction(
      CStrOrNull(GetEnvVar("CENTROID_GPU_ON_LOSS")), config.on_loss);
  return config;
}

bool WatchdogEnabledFromEnvironment() {
  // On by default. Probing costs one ForceRedraw every five seconds, and the
  // payoff is that a device loss is recovered from in seconds and explained in
  // one block instead of thousands of engine errors saying that it happened.
  // CENTROID_GPU_ON_LOSS still governs what is done about it.
  return tfc::ParseWatchdogEnabled(
      CStrOrNull(GetEnvVar("CENTROID_GPU_WATCHDOG")), true);
}

// Distinct enough to be recognisable in a service manager's log next to a
// normal shutdown (0) and a crash-handler exit.
constexpr int kGpuLossExitCode = 109;

constexpr const char* kTag = "[gpu-watchdog]";

// Engine-generation boundaries and everything the UI isolate reports about
// itself get their own tag, because they answer a different question from the
// GPU watchdog's and are read at a different time. `findstr [engine]` on
// hmi-runner.log now lists every restart of a run in order, with reasons.
constexpr const char* kEngineTag = "[engine]";
constexpr const char* kDartTag = "[dart]";

// The method channel the UI isolate reports on. Its Dart half lives in
// lib/core/runner_liveness.dart.
constexpr const char* kRunnerChannel = "centroid/runner";

void LogWatchdog(const std::string& message) {
  tfc::RunnerLogLine(kTag, message);
}

void LogEngine(const std::string& message) {
  tfc::RunnerLogLine(kEngineTag, message);
}

void LogDart(const std::string& message) {
  tfc::RunnerLogLine(kDartTag, message);
}

// --- Reading a method call's arguments without trusting them ----------------
//
// Everything below tolerates a missing or wrongly typed field rather than
// throwing: this is diagnostics, and a diagnostic that can end the process it
// is diagnosing is worse than none.

const flutter::EncodableMap* ArgumentsOf(
    const flutter::MethodCall<flutter::EncodableValue>& call) {
  return std::get_if<flutter::EncodableMap>(call.arguments());
}

long long IntArg(const flutter::EncodableMap* args, const char* name,
                 long long fallback) {
  if (args == nullptr) {
    return fallback;
  }
  const auto it = args->find(flutter::EncodableValue(name));
  if (it == args->end()) {
    return fallback;
  }
  if (const auto* wide = std::get_if<int64_t>(&it->second)) {
    return static_cast<long long>(*wide);
  }
  if (const auto* narrow = std::get_if<int32_t>(&it->second)) {
    return static_cast<long long>(*narrow);
  }
  return fallback;
}

unsigned long long UnsignedArg(const flutter::EncodableMap* args,
                               const char* name) {
  const long long value = IntArg(args, name, 0);
  return value < 0 ? 0ull : static_cast<unsigned long long>(value);
}

bool BoolArg(const flutter::EncodableMap* args, const char* name) {
  if (args == nullptr) {
    return false;
  }
  const auto it = args->find(flutter::EncodableValue(name));
  if (it == args->end()) {
    return false;
  }
  const auto* value = std::get_if<bool>(&it->second);
  return value != nullptr && *value;
}

std::string StringArg(const flutter::EncodableMap* args, const char* name) {
  if (args == nullptr) {
    return std::string();
  }
  const auto it = args->find(flutter::EncodableValue(name));
  if (it == args->end()) {
    return std::string();
  }
  const auto* value = std::get_if<std::string>(&it->second);
  return value == nullptr ? std::string() : *value;
}

std::string SecondsSince(unsigned long long then, unsigned long long now) {
  char buffer[32];
  std::snprintf(buffer, sizeof(buffer), "%.1f",
                (now > then ? now - then : 0) / 1000.0);
  return buffer;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project),
      watchdog_(WatchdogConfigFromEnvironment()),
      watchdog_enabled_(WatchdogEnabledFromEnvironment()) {
  // Throttles sized for the two very different cadences here: ticks are one
  // every few seconds and worth seeing, frames can be sixty a second and are
  // only worth sampling.
  tick_log_ = tfc::LogThrottle(tfc::LogThrottle::Config{8, 12, 60000});
  frame_log_ = tfc::LogThrottle(tfc::LogThrottle::Config{3, 600, 300000});
  hint_log_ = tfc::LogThrottle(tfc::LogThrottle::Config{10, 20, 30000});
  send_failure_log_ = tfc::LogThrottle(tfc::LogThrottle::Config{5, 10, 30000});
  timer_thread_log_ = tfc::LogThrottle(tfc::LogThrottle::Config{3, 60, 300000});
  // Stamps arrive every 10 s. A handful in full at the start of an episode,
  // then one in sixty (ten minutes) -- enough to prove the isolate is still
  // there overnight without adding 8,640 lines a day to the file.
  liveness_log_ = tfc::LogThrottle(tfc::LogThrottle::Config{3, 60, 600000});
}

FlutterWindow::~FlutterWindow() {
  // Belt and braces: the timer callback holds a raw `this`, so it must not
  // outlive the object even if OnDestroy never ran.
  StopWatchdogTimer();
}

bool FlutterWindow::CreateController(const char* reason) {
  RECT frame = GetClientArea();

  engine_epoch_++;
  epoch_started_tick_ = ::GetTickCount64();
  // Startup is in flight from here until Dart says otherwise. A session
  // change arriving in that window is queued rather than acted on -- see
  // session_rebuild_gate.h.
  session_gate_.EngineCreated(epoch_started_tick_);
  dart_startup_complete_ = false;
  dart_main_seen_ = false;
  dart_liveness_.EpochStarted(engine_epoch_, epoch_started_tick_);
  liveness_log_.Reset();

  // The boundary, on the native side of it. Its Dart counterpart is the
  // "main() starting" line the app writes when it reads the arguments below.
  LogEngine("epoch " + std::to_string(engine_epoch_) +
            " STARTING, reason=" + (reason == nullptr ? "unspecified" : reason) +
            ". A new engine is a new Dart isolate: everything the app was "
            "doing is gone and main() runs again from the top.");

  // Told to Dart rather than inferred by it. Flutter passes these straight to
  // main(List<String> args), which is the earliest point the app can know
  // which generation it is -- earlier than any channel could tell it, and the
  // first log line it writes therefore already carries the epoch.
  project_.set_dart_entrypoint_arguments(
      {"--engine-epoch=" + std::to_string(engine_epoch_),
       std::string("--engine-reason=") +
           (reason == nullptr ? "unspecified" : reason)});

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    flutter_controller_ = nullptr;
    LogEngine("epoch " + std::to_string(engine_epoch_) +
              " did NOT start: FlutterViewController came back without an "
              "engine or a view");
    LogWatchdog(
        "engine did NOT start: FlutterViewController came back without an "
        "engine or a view");
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Opened before the first frame, because the messages worth having are the
  // ones from a generation that never reaches one.
  runner_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kRunnerChannel,
          &flutter::StandardMethodCodec::GetInstance());
  runner_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { this->OnRunnerChannelCall(call, std::move(result)); });

  // The engine posts this back to the platform thread, so it is safe to touch
  // watchdog state from it. It doubles as the stock runner template's "show the
  // window once the first frame is ready" hook.
  probe_armed_ = true;
  flutter_controller_->engine()->SetNextFrameCallback(
      [this]() { this->OnFramePresented(); });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  sentinel_loss_logged_ = false;

  // Say which adapter the engine is actually rendering on, so the sentinel's
  // verdict can be read against the right GPU rather than assumed to be about
  // it. Cheap, and it is the one piece of the renderer's graphics state the
  // embedder does expose.
  IDXGIAdapter* engine_adapter = nullptr;
  if (flutter_controller_->engine()->GetGraphicsAdapter(&engine_adapter) &&
      engine_adapter != nullptr) {
    DXGI_ADAPTER_DESC desc = {};
    if (SUCCEEDED(engine_adapter->GetDesc(&desc))) {
      char described[160];
      std::snprintf(described, sizeof(described),
                    "engine renders on adapter [vendor 0x%04x device 0x%04x]",
                    desc.VendorId, desc.DeviceId);
      LogWatchdog(described);
    }
    engine_adapter->Release();
  } else {
    LogWatchdog("the engine did not report a graphics adapter");
  }

  return true;
}

void FlutterWindow::DestroyController(const char* reason) {
  if (flutter_controller_ != nullptr) {
    const unsigned long long now = ::GetTickCount64();
    // The one line that was missing. On 2026-09-10 the second teardown landed
    // 35 s into a startup that had not finished -- and the log had to be
    // reconstructed from elapsed-since-logger-init arithmetic to see it at
    // all. Now the teardown says how far Dart got before it was cut off.
    LogEngine(
        "epoch " + std::to_string(engine_epoch_) + " STOPPING after " +
        SecondsSince(epoch_started_tick_, now) +
        " s, reason=" + (reason == nullptr ? "unspecified" : reason) +
        "; Dart main() " + (dart_main_seen_ ? "had started" : "was NEVER seen") +
        ", app startup " +
        (dart_startup_complete_
             ? "had completed"
             : "was STILL IN FLIGHT -- this teardown interrupts it") +
        ". Everything this isolate opened, including its OPC UA clients, goes "
        "with it; whatever it had not finished opening is orphaned.");
  }

  // The channel borrows the engine's messenger, so it is dropped first.
  if (runner_channel_ != nullptr) {
    runner_channel_->SetMethodCallHandler(nullptr);
    runner_channel_ = nullptr;
  }

  // Destroying the controller shuts the engine down, which takes egl::Manager
  // with it: eglTerminate() releases the lost D3D device so the next
  // eglInitialize() can create a healthy one.
  //
  // The armed callback belonged to that engine and dies with it; the fresh
  // engine needs its own, so the flag must not survive the recreate.
  probe_armed_ = false;

  // Return the Flutter child window to a clean drag-and-drop state before the
  // engine tears its plugins down.
  //
  // This is the fix for the 2026-09-02 crash (see drag_drop_lifetime.h for the
  // reference-count model, and windows/runner/test). The minidump caught the
  // platform thread inside desktop_drop's DesktopDropPlugin destructor calling
  // target_->Release() through a DANGLING pointer -- an execute/DEP access
  // violation, the freed target's memory already recycled to point at itself.
  //
  // desktop_drop's IDropTarget is a Win32/OLE drop target: its constructor
  // calls RegisterDragDrop(view_hwnd, this) (an AddRef) and the plugin adds a
  // second reference; teardown is meant to undo both. That balances exactly
  // ONCE per process. The GPU watchdog now destroys and recreates the whole
  // FlutterViewController -- on every RDP session change (RebuildForSession
  // change) and on device-loss recovery -- so it runs more than once, and the
  // second cycle re-registers on a child HWND whose prior registration was
  // never revoked. The stale registration throws the reference count off by
  // one; the target is freed a step early and the plugin destructor then
  // releases through the corpse. This process had rebuilt once already (an RDP
  // disconnect at 16:25:43) when the 16:52:26 reconnect rebuilt a second time
  // and crashed.
  //
  // Revoking here, while we still own the controller and its view window,
  // releases the OS registration deterministically before the engine's plugin
  // teardown runs, so desktop_drop's reference count is balanced across every
  // rebuild and the next RegisterDragDrop starts from a clean HWND. Idempotent:
  // the plugin's own destructor also revokes, and a second RevokeDragDrop just
  // returns DRAGDROP_E_NOTREGISTERED. Harmless when nothing registered a drop
  // target, which is why it is unconditional rather than desktop_drop-specific.
  if (flutter_controller_ != nullptr && flutter_controller_->view() != nullptr) {
    HWND view_hwnd = flutter_controller_->view()->GetNativeWindow();
    if (view_hwnd != nullptr) {
      ::RevokeDragDrop(view_hwnd);
    }
  }

  flutter_controller_ = nullptr;
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  if (!CreateController("initial start")) {
    return false;
  }

  start_tick_ = ::GetTickCount64();
  last_frame_tick_ = start_tick_;

  // Say what was read from the environment and what it resolved to, always.
  // The 2026-08-31 run had CENTROID_GPU_ON_LOSS unset, took the default, and
  // then did nothing at all -- and there was no single line anywhere saying
  // what the policy even was.
  const std::optional<std::string> raw_policy = GetEnvVar("CENTROID_GPU_ON_LOSS");
  LogWatchdog(std::string("policy: CENTROID_GPU_ON_LOSS=") +
              (raw_policy.has_value() ? ("\"" + *raw_policy + "\"")
                                      : "<unset>") +
              " -> on loss will " + tfc::DescribeLossAction(watchdog_.on_loss()) +
              "; escalates to exit after repeated losses. Durable log: " +
              (tfc::RunnerLogHasFile() ? tfc::RunnerLogPath()
                                       : std::string("<stderr only>")));

  if (!watchdog_enabled_) {
    LogWatchdog(
        "DISABLED via CENTROID_GPU_WATCHDOG. A lost render context will "
        "freeze the UI and nothing will notice.");
    return true;
  }

  // Created before anything can go wrong, because its whole job is to be an
  // already-open channel to the driver at the moment one cannot be opened.
  if (device_probe_.Create()) {
    LogWatchdog("sentinel D3D11 device created on " +
                (device_probe_.adapter_description().empty()
                     ? std::string("an unnamed adapter")
                     : device_probe_.adapter_description()));
  } else {
    // Not fatal. The loss is still detected and still reported; the report
    // just cannot name the reason, and says so rather than implying health.
    LogWatchdog(
        "sentinel D3D11 device could NOT be created -- a device loss will be "
        "detected but its reason will be unavailable");
  }

  watchdog_hwnd_.store(GetHandle());

  // Device loss usually -- but not always -- comes with one of these messages.
  // They only bring the next probe forward; the probe still decides whether
  // anything actually broke.
  if (::WTSRegisterSessionNotification(watchdog_hwnd_.load(),
                                       NOTIFY_FOR_THIS_SESSION)) {
    session_notifications_registered_ = true;
    LogWatchdog("registered for RDP/console session change notifications");
  } else {
    // Not fatal: the periodic probe still catches the loss, just later.
    LogWatchdog("WTSRegisterSessionNotification failed (error " +
                std::to_string(::GetLastError()) +
                "); relying on the periodic probe only");
  }

  LogWatchdog(std::string("session at startup: ") +
              (::GetSystemMetrics(SM_REMOTESESSION) != 0
                   ? "remote (RDP/terminal services)"
                   : "console (local)"));

  // The engine's stderr is the only witness for a context loss the sentinel
  // and the frame probe both miss (see egl_storm_detector.h). Read it.
  if (watchdog_enabled_) {
    const HWND storm_hwnd = watchdog_hwnd_.load();
    if (stderr_interposer_.Install(
            tfc::EglStormDetector::Config(),
            [storm_hwnd](unsigned int matches) {
              ::PostMessage(storm_hwnd, kEglStormMessage,
                            static_cast<WPARAM>(matches), 0);
            })) {
      LogWatchdog(
          "stderr storm detector installed -- a burst of engine context-lost "
          "errors now declares the renderer lost even when every probe "
          "answers");
    } else {
      LogWatchdog(
          "stderr storm detector could NOT be installed -- an EGL context "
          "loss is only caught by the session-change rebuild");
    }
  }

  Dispatch(WatchdogEvent::kStarted);
  return true;
}

void FlutterWindow::OnDestroy() {
  StopWatchdogTimer();

  HWND hwnd = watchdog_hwnd_.exchange(nullptr);
  if (hwnd != nullptr) {
    ::KillTimer(hwnd, kLegacyWatchdogTimerId);
    if (session_notifications_registered_) {
      ::WTSUnRegisterSessionNotification(hwnd);
      session_notifications_registered_ = false;
    }
  }
  DestroyController("window destroyed");

  Win32Window::OnDestroy();
}

// --- The tick thread --------------------------------------------------------

void CALLBACK FlutterWindow::WatchdogTimerThunk(void* context, BOOLEAN fired) {
  (void)fired;
  static_cast<FlutterWindow*>(context)->OnWatchdogTimerThread();
}

void FlutterWindow::OnWatchdogTimerThread() {
  // The first thing this thread does is say that it ran. If the tick ever goes
  // missing again, the absence of THIS line separates "the timer never fired"
  // from "the timer fired and the platform thread did not take the message" --
  // a distinction that cost three investigations to not have.
  const tfc::LogThrottle::Decision fired =
      timer_thread_log_.Record(::GetTickCount64());
  const bool stopping = watchdog_stopping_.load();
  HWND hwnd = watchdog_hwnd_.load();
  if (fired.emit) {
    char detail[128];
    std::snprintf(detail, sizeof(detail), "hwnd=0x%p stopping=%s",
                  static_cast<void*>(hwnd), stopping ? "yes" : "no");
    LogWatchdog(std::string("timer thread fired; ") + detail +
                tfc::LogThrottle::DescribeSuppression(fired));
  }

  if (stopping || hwnd == nullptr) {
    return;
  }

  // SendMessageTimeout, not PostMessage. A posted message would sit behind
  // whatever has saturated the queue -- which, during exactly the failure this
  // watches for, is an engine failing frames as fast as it can schedule them.
  // Sent messages jump that queue.
  DWORD_PTR result = 0;
  const LRESULT sent = ::SendMessageTimeoutW(
      hwnd, kWatchdogTickMessage, 0, 0, SMTO_ABORTIFHUNG | SMTO_NORMAL,
      kTickSendTimeoutMs, &result);

  if (sent != 0) {
    unanswered_sends_.store(0);
    if (fired.emit) {
      LogWatchdog("...and the platform thread answered the tick (result " +
                  std::to_string(static_cast<long long>(result)) + ")");
    }
    return;
  }

  // The platform thread did not take a sent message. That is a much stronger
  // statement than "it is busy", and it is logged every time it happens --
  // throttled, because a wedged thread will do it on every tick.
  const int unanswered = unanswered_sends_.fetch_add(1) + 1;
  const tfc::LogThrottle::Decision decision =
      send_failure_log_.Record(::GetTickCount64());
  if (decision.emit) {
    LogWatchdog("the platform thread did NOT answer a sent tick within " +
                std::to_string(kTickSendTimeoutMs) + " ms (GetLastError " +
                std::to_string(::GetLastError()) + "); " +
                std::to_string(unanswered) + " consecutive, wedged at " +
                std::to_string(kUnansweredSendsBeforeWedged) +
                tfc::LogThrottle::DescribeSuppression(decision));
  }

  if (unanswered < kUnansweredSendsBeforeWedged) {
    return;
  }

  // Nothing on the platform thread can be trusted now, the engine included, so
  // this path deliberately touches neither. Write the report from here and end
  // the process: a supervised restart is the only move left, and it is
  // strictly better than a screen that stays dead until someone walks over.
  //
  // Latched by resetting the counter so a second pass cannot re-enter while
  // the first is still writing.
  unanswered_sends_.store(0);
  LogWatchdog(
      "the platform thread is WEDGED -- it has refused sent messages for "
      "long enough that the message loop cannot be assumed alive. Reporting "
      "from the watchdog thread and ending the process.");

  // Reads device_probe_ and the tick stamps from this thread, which the
  // platform thread also writes. Racy in principle; in practice this path is
  // only reached once the platform thread has stopped answering at all, and a
  // slightly torn report beats no report -- which is what the last three
  // investigations had.
  tfc::LossEvidence evidence;
  evidence.cause = tfc::LossCause::kPlatformThreadWedged;
  evidence.sentinel_available = device_probe_.available();
  evidence.device_removed_reason = device_probe_.GetRemovedReason();
  evidence.adapter_description = device_probe_.adapter_description();
  evidence.adapter_vendor_id = device_probe_.vendor_id();
  evidence.adapter_device_id = device_probe_.device_id();
  evidence.remote_session = ::GetSystemMetrics(SM_REMOTESESSION) != 0;
  evidence.ms_since_start = ::GetTickCount64() - start_tick_;
  evidence.ms_since_last_frame = ::GetTickCount64() - last_frame_tick_;
  tfc::RunnerLogBlock(tfc::FormatLossReport(evidence));

  // Not PostQuitMessage: that needs the message loop this has just concluded
  // is not running. ExitProcess after the report has been flushed.
  std::cerr.flush();
  std::fflush(nullptr);
  ::ExitProcess(static_cast<UINT>(kGpuLossExitCode));
}

bool FlutterWindow::StartWatchdogTimer(unsigned int period_ms) {
  // Clear the stop latch before arming, because OnDestroy runs BEFORE the
  // window is ever created: Win32Window::Create opens with Destroy(), which
  // calls OnDestroy() on a window that does not exist yet. Leaving the latch
  // set there meant the timer thread fired on schedule and bowed out every
  // time -- a watchdog that looked armed in the log and was not. Caught by
  // running it; no unit test of this class could have.
  watchdog_stopping_.store(false);

  if (watchdog_timer_queue_ == nullptr) {
    watchdog_timer_queue_ = ::CreateTimerQueue();
    if (watchdog_timer_queue_ == nullptr) {
      LogWatchdog("CreateTimerQueue failed (error " +
                  std::to_string(::GetLastError()) +
                  ") -- the watchdog cannot tick and is disabling itself");
      return false;
    }
  }
  if (watchdog_timer_ != nullptr) {
    SetWatchdogPeriod(period_ms);
    return true;
  }
  if (!::CreateTimerQueueTimer(&watchdog_timer_, watchdog_timer_queue_,
                               &FlutterWindow::WatchdogTimerThunk, this,
                               period_ms, period_ms, WT_EXECUTEDEFAULT)) {
    watchdog_timer_ = nullptr;
    LogWatchdog("CreateTimerQueueTimer failed (error " +
                std::to_string(::GetLastError()) +
                ") -- the watchdog cannot tick and is disabling itself");
    return false;
  }
  watchdog_period_ms_ = period_ms;
  LogWatchdog("tick armed on a timer-queue thread, every " +
              std::to_string(period_ms) +
              " ms (not WM_TIMER: that is starved by exactly the failure this "
              "watches for)");
  return true;
}

void FlutterWindow::SetWatchdogPeriod(unsigned int period_ms) {
  if (watchdog_timer_ == nullptr || period_ms == 0 ||
      period_ms == watchdog_period_ms_) {
    return;
  }
  if (::ChangeTimerQueueTimer(watchdog_timer_queue_, watchdog_timer_, period_ms,
                              period_ms)) {
    LogWatchdog("tick period now " + std::to_string(period_ms) + " ms (was " +
                std::to_string(watchdog_period_ms_) + " ms)");
    watchdog_period_ms_ = period_ms;
  } else {
    LogWatchdog("ChangeTimerQueueTimer failed (error " +
                std::to_string(::GetLastError()) + "); keeping " +
                std::to_string(watchdog_period_ms_) + " ms");
  }
}

void FlutterWindow::StopWatchdogTimer() {
  // Nothing armed means nothing to stop. Without this, the OnDestroy that
  // Win32Window::Create runs before the window exists would latch the stop
  // flag for the life of the process. StartWatchdogTimer clears it too; both,
  // because a watchdog that silently does not run is the failure mode this
  // whole change exists to remove.
  if (watchdog_timer_ == nullptr && watchdog_timer_queue_ == nullptr) {
    return;
  }

  watchdog_stopping_.store(true);
  if (watchdog_timer_ != nullptr) {
    // INVALID_HANDLE_VALUE waits for a callback that is already running. A
    // callback blocked in SendMessageTimeout to this very thread would
    // deadlock, except that the send has its own timeout, so the wait is
    // bounded by kTickSendTimeoutMs.
    ::DeleteTimerQueueTimer(watchdog_timer_queue_, watchdog_timer_,
                            INVALID_HANDLE_VALUE);
    watchdog_timer_ = nullptr;
  }
  if (watchdog_timer_queue_ != nullptr) {
    ::DeleteTimerQueueEx(watchdog_timer_queue_, INVALID_HANDLE_VALUE);
    watchdog_timer_queue_ = nullptr;
  }
}

// --- Driving the watchdog ---------------------------------------------------

bool FlutterWindow::RenderDeviceIsLost() {
  if (!device_probe_.available()) {
    return false;
  }
  const std::uint32_t reason = device_probe_.GetRemovedReason();
  if (reason == tfc::kDxgiOk) {
    return false;
  }
  if (!sentinel_loss_logged_) {
    sentinel_loss_logged_ = true;
    char named[96];
    LogWatchdog(
        std::string("the render adapter reports itself REMOVED: ") +
        tfc::DescribeRemovedReason(reason, named, sizeof(named)) +
        ". Asked directly, not inferred -- declaring the loss now instead of "
        "waiting two probe intervals for the frames to stop.");
  }
  return true;
}

void FlutterWindow::Dispatch(WatchdogEvent event, tfc::LossCause cause) {
  if (!watchdog_enabled_ || watchdog_.has_given_up()) {
    return;
  }
  const unsigned long long now = ::GetTickCount64();
  try {
    switch (event) {
      case WatchdogEvent::kStarted:
        ApplyAction(watchdog_.OnStarted(now));
        break;
      case WatchdogEvent::kTick:
        ApplyAction(watchdog_.OnTick(now));
        break;
      case WatchdogEvent::kFramePresented:
        ApplyAction(watchdog_.OnFramePresented(now));
        break;
      case WatchdogEvent::kDeviceLossHint:
        ApplyAction(watchdog_.OnDeviceLossHint(now));
        break;
      case WatchdogEvent::kRendererLost:
        ApplyAction(watchdog_.OnRendererLost(cause, now));
        break;
    }
  } catch (const std::exception& e) {
    // MessageHandler is noexcept and the frame callback runs inside the
    // engine's task runner: letting anything escape either one calls
    // std::terminate, which is an abort with no explanation attached. Failing
    // safe costs the recovery feature and leaves the app behaving exactly as
    // it did before the watchdog existed -- which is why it is now impossible
    // for that to happen quietly.
    DisableWatchdog(std::string("an action threw ") + typeid(e).name() + ": " +
                    e.what());
  } catch (...) {
    DisableWatchdog("an action threw an exception of unknown type");
  }
}

void FlutterWindow::DisableWatchdog(const std::string& why) {
  // The loudest line in this file. A watchdog that switches itself off is the
  // worst possible failure -- the screen dies and nothing is watching -- and
  // for the 2026-08-31 incident this path could not be ruled out because it
  // never said anything.
  LogWatchdog(
      "DISARMED -- from here on a lost render context will freeze the UI and "
      "NOTHING will detect it. Cause: " +
      why);
  watchdog_.Disable();
  StopWatchdogTimer();
  HWND hwnd = watchdog_hwnd_.load();
  if (hwnd != nullptr) {
    ::KillTimer(hwnd, kLegacyWatchdogTimerId);
  }
}

void FlutterWindow::ApplyAction(const tfc::GpuWatchdog::Action& action) {
  // Before anything else: the report is the reason this code exists, and a
  // restart or an exit would otherwise destroy the evidence it reads.
  if (action.report_loss) {
    ReportDeviceLoss(action.cause, action.escalation);
  }

  if (action.exit_process) {
    if (action.escalation != tfc::LossEscalation::kNone) {
      LogWatchdog(std::string("ESCALATING to exit although the policy is to ") +
                  tfc::DescribeLossAction(watchdog_.on_loss()) + " -- " +
                  tfc::DescribeEscalation(action.escalation));
    }
    ExitAfterDeviceLoss();
    return;
  }

  if (action.restart_engine) {
    LogWatchdog(std::string("RECOVERING in place: ") +
                tfc::DescribeLossCause(action.cause) +
                " Rebuilding the Flutter engine, attempt " +
                std::to_string(watchdog_.recovery_attempts()) +
                " (loss episode " + std::to_string(watchdog_.losses_in_window()) +
                " in the guard window).");
    DestroyController("gpu loss recovery");
    // Deliberately does not touch first_frame_shown_. If the window was already
    // shown it stays shown, and re-running Show() would undo an operator's
    // maximise. If the GPU was dead before the very first frame, the flag is
    // still false and the window has never appeared — then we do want the next
    // successful frame to show it.
    if (!CreateController("gpu loss recovery")) {
      LogWatchdog(
          "engine restart FAILED -- will retry on the next tick, and escalate "
          "to exit once the attempts are exhausted");
    } else {
      LogWatchdog(
          "engine rebuilt; waiting for it to present a frame before calling "
          "this a recovery");
      // The old sentinel may be a corpse on a dead adapter. A fresh one gives
      // the next report something true to say.
      device_probe_.Reset();
      device_probe_.Create();
    }
    // CreateController's own ForceRedraw is the next probe; the watchdog
    // already accounted for that.
  }

  if (action.start_probe) {
    StartProbe();
  }

  if (action.set_timer_ms != 0) {
    if (watchdog_timer_ == nullptr) {
      if (!StartWatchdogTimer(action.set_timer_ms)) {
        DisableWatchdog("the tick timer could not be created");
      }
    } else {
      SetWatchdogPeriod(action.set_timer_ms);
    }
  }
}

void FlutterWindow::ReportDeviceLoss(tfc::LossCause cause,
                                     tfc::LossEscalation escalation) {
  const unsigned long long now = ::GetTickCount64();

  tfc::LossEvidence evidence;
  evidence.cause = cause;
  evidence.escalation = escalation;

  evidence.sentinel_available = device_probe_.available();
  evidence.device_removed_reason = device_probe_.GetRemovedReason();
  evidence.adapter_description = device_probe_.adapter_description();
  evidence.adapter_vendor_id = device_probe_.vendor_id();
  evidence.adapter_device_id = device_probe_.device_id();

  evidence.last_hint = last_hint_;
  evidence.session_change_code = session_change_code_;
  evidence.ms_since_last_hint =
      last_hint_tick_ == 0 ? 0ULL : now - last_hint_tick_;

  evidence.ms_since_start = now - start_tick_;
  evidence.ms_since_last_frame = now - last_frame_tick_;
  evidence.missed_probes = watchdog_.missed_probes();
  evidence.losses_in_window = watchdog_.losses_in_window();
  evidence.max_losses_in_window = watchdog_.max_losses_in_window();
  evidence.recovery_attempts = watchdog_.recovery_attempts();

  evidence.remote_session = ::GetSystemMetrics(SM_REMOTESESSION) != 0;

  // Both sinks: the console for whoever is watching, and CENTROID_LOG_FILE for
  // whoever reads it tomorrow. The [gpu-loss] prefix on every line is what
  // run-hmi.ps1 -Report greps for; do not change it.
  tfc::RunnerLogBlock(tfc::FormatLossReport(evidence));
}

void FlutterWindow::ExitAfterDeviceLoss() {
  LogWatchdog("ending the process so the report above is the last thing in "
              "this log; exit code " +
              std::to_string(kGpuLossExitCode) +
              ". RegisterApplicationRestart should bring it back.");

  StopWatchdogTimer();

  // Take the engine down first: that runs egl::Manager's destructor, which
  // releases the dead D3D device, and it stops the raster thread producing
  // more EGL errors after the report.
  DestroyController("exiting after gpu loss");

  std::cerr.flush();
  std::fflush(nullptr);

  // Through the message loop rather than ExitProcess: wWinMain returns
  // normally, destructors run, and the log file is closed by the CRT instead
  // of being left to the OS.
  ::PostQuitMessage(kGpuLossExitCode);
}

void FlutterWindow::NoteLossHint(tfc::LossHint hint,
                                 unsigned long session_code) {
  last_hint_ = hint;
  last_hint_tick_ = ::GetTickCount64();
  session_change_code_ = session_code;
}

void FlutterWindow::StartProbe() {
  if (!flutter_controller_ || !flutter_controller_->engine()) {
    return;
  }
  // Re-arm only when the previous probe has actually been answered.
  //
  // Every SetNextFrameCallback registers a FRESH callback with the engine,
  // while the client wrapper keeps just one std::function behind them all. Its
  // trampoline invokes that function and then nulls it, with no null check --
  // so the second of two pending callbacks calls an empty std::function and
  // throws std::bad_function_call, which nothing catches and which ends the
  // process.
  //
  // Arming repeatedly without a frame in between is exactly what this watchdog
  // does when the renderer is down: probes stack up, one per interval, unseen
  // because no frame is presented to consume them. They come due together the
  // moment the device works again -- which is why the crash landed on the
  // morning an RDP session was reconnected, not on the evening it was dropped.
  //
  // Note that this guard does NOT weaken detection: the watchdog's own
  // probe_outstanding_ is what counts misses, and it is set whether or not a
  // new callback was armed here.
  if (!probe_armed_) {
    probe_armed_ = true;
    flutter_controller_->engine()->SetNextFrameCallback(
        [this]() { this->OnFramePresented(); });
  }
  flutter_controller_->ForceRedraw();
}

void FlutterWindow::RebuildForSessionChange(const char* why) {
  if (!watchdog_enabled_ || flutter_controller_ == nullptr) {
    return;
  }

  const unsigned long long now = ::GetTickCount64();
  const tfc::SessionRebuildGate::Decision decision =
      session_gate_.Request(why == nullptr ? "unspecified" : why, now);
  const std::string line = DescribeSessionRebuild(decision);
  if (!line.empty()) {
    LogWatchdog(line);
  }
  if (decision.verdict != tfc::SessionRebuildGate::Verdict::kRebuildNow) {
    return;
  }
  PerformSessionRebuild(decision.reason);
}

void FlutterWindow::PerformSessionRebuild(const std::string& reason) {
  if (flutter_controller_ == nullptr) {
    return;
  }
  const std::string rebuild_reason = "session change: " + reason;
  DestroyController(rebuild_reason.c_str());
  // As in the loss recovery: leave first_frame_shown_ alone so an already
  // visible window stays visible and an operator's maximise survives.
  if (!CreateController(rebuild_reason.c_str())) {
    LogWatchdog(
        "session-change rebuild FAILED -- the window has no renderer; the "
        "tick will keep trying and the loss path can still escalate");
  } else {
    LogWatchdog("renderer rebuilt after session change");
    // The old sentinel may belong to the session's departed adapter.
    device_probe_.Reset();
    device_probe_.Create();
  }
}

void FlutterWindow::OnRunnerChannelCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const flutter::EncodableMap* args = ArgumentsOf(call);
  const unsigned long long now = ::GetTickCount64();
  const std::string& method = call.method_name();

  if (method == "mainStarting") {
    dart_main_seen_ = true;
    const long long epoch = IntArg(args, "epoch", -1);
    const std::string reason = StringArg(args, "reason");
    const std::string version = StringArg(args, "version");
    // The line the 2026-09-10 investigation had to reconstruct by arithmetic.
    LogDart("main() STARTING, epoch " + std::to_string(epoch) + ", reason=" +
            (reason.empty() ? "unspecified" : reason) +
            (version.empty() ? "" : ", build " + version) +
            (epoch == engine_epoch_
                 ? ""
                 : " -- WARNING: the runner is on epoch " +
                       std::to_string(engine_epoch_) +
                       ", so this isolate belongs to an engine that is "
                       "already gone"));
    result->Success();
    return;
  }

  if (method == "startupComplete") {
    const long long epoch = IntArg(args, "epoch", -1);
    if (epoch == engine_epoch_) {
      dart_startup_complete_ = true;
      session_gate_.StartupComplete(now);
      // A rebuild held back waiting for exactly this is now due. It is POSTED
      // rather than done here: this handler is running inside a call from the
      // engine, on the messenger owned by the controller a rebuild destroys.
      // Tearing that down under its own call frame is how the last three
      // engine-lifecycle bugs in this file were written. The posted message is
      // handled once the engine's frame has unwound.
      if (session_gate_.has_queued_request()) {
        ::PostMessage(GetHandle(), kSessionRebuildDueMessage, 0, 0);
      }
    }
    LogDart("app startup COMPLETE for epoch " + std::to_string(epoch) +
            " after " + SecondsSince(epoch_started_tick_, now) +
            " s (runner clock). Until this line, a rebuild of this engine "
            "interrupts an unfinished startup.");
    result->Success();
    return;
  }

  if (method == "liveness") {
    tfc::DartLivenessStamp stamp;
    stamp.epoch = IntArg(args, "epoch", -1);
    stamp.uptime_ms = UnsignedArg(args, "uptimeMs");
    stamp.ticks = UnsignedArg(args, "ticks");
    stamp.frames = UnsignedArg(args, "frames");
    stamp.lag_ms = UnsignedArg(args, "lagMs");
    stamp.startup_complete = BoolArg(args, "startupComplete");

    const tfc::DartLiveness::Decision decision =
        dart_liveness_.OnStamp(stamp, now);
    const std::string line = DescribeLiveness(decision, dart_liveness_.config());
    if (!line.empty()) {
      // First stamp and recovery are transitions: always worth a line.
      LogDart(line);
      liveness_log_.Reset();
    } else if (decision.verdict ==
               tfc::DartLiveness::Verdict::kNothingToSay) {
      // The steady state. Sampled rather than printed in full, because the
      // whole point of the previous incident's 9.7 MB log was that
      // instrumentation must not become the fault it documents.
      const tfc::LogThrottle::Decision throttle = liveness_log_.Record(now);
      if (throttle.emit) {
        LogDart("alive: epoch " + std::to_string(stamp.epoch) + ", tick " +
                std::to_string(stamp.ticks) + ", uptime " +
                SecondsSince(0, stamp.uptime_ms) + " s, " +
                std::to_string(stamp.frames) +
                " frame(s) since the last stamp, timer lag " +
                std::to_string(stamp.lag_ms) + " ms" +
                tfc::LogThrottle::DescribeSuppression(throttle));
      }
    }
    result->Success();
    return;
  }

  result->NotImplemented();
}

void FlutterWindow::EvaluateDartLiveness(unsigned long long now_ms) {
  const tfc::DartLiveness::Decision decision = dart_liveness_.Evaluate(now_ms);
  const std::string line = DescribeLiveness(decision, dart_liveness_.config());
  if (!line.empty()) {
    LogDart(line);
  }
}

void FlutterWindow::OnFramePresented() {
  // The engine consumed the armed callback to get here, so the next probe is
  // free to arm a new one.
  probe_armed_ = false;
  last_frame_tick_ = ::GetTickCount64();
  const int attempts_before = watchdog_.recovery_attempts();
  const bool was_reported = watchdog_.has_reported_loss();

  const tfc::LogThrottle::Decision decision = frame_log_.Record(last_frame_tick_);
  if (decision.emit) {
    LogWatchdog("frame presented; missed-probe count reset from " +
                std::to_string(watchdog_.missed_probes()) + "/" +
                std::to_string(watchdog_.missed_probes_before_recovery()) +
                tfc::LogThrottle::DescribeSuppression(decision));
  }

  Dispatch(WatchdogEvent::kFramePresented);

  if (was_reported) {
    // The counterpart to the loss report: the episode is over. Without this a
    // log shows losses and never recoveries, and nobody can tell a station
    // that healed from one that is still dead.
    LogWatchdog(
        "renderer is presenting frames again -- the loss episode reported "
        "above has ENDED");
    frame_log_.Reset();
    tick_log_.Reset();
  }
  if (attempts_before > 0 && !watchdog_.has_given_up()) {
    LogWatchdog("renderer healthy again after " +
                std::to_string(attempts_before) + " recovery attempt(s)");
  }

  if (!first_frame_shown_) {
    first_frame_shown_ = true;
    this->Show();
  }
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Handled before Flutter sees it. Sent from the watchdog's timer thread; see
  // the note on the tick in flutter_window.h.
  if (message == kWatchdogTickMessage) {
    const unsigned long long now = ::GetTickCount64();
    const tfc::LogThrottle::Decision decision = tick_log_.Record(now);
    if (decision.emit) {
      LogWatchdog(
          "tick: missed " + std::to_string(watchdog_.missed_probes()) + "/" +
          std::to_string(watchdog_.missed_probes_before_recovery()) +
          ", probe outstanding=" +
          (watchdog_.probe_outstanding() ? "yes" : "no") + ", last frame " +
          std::to_string(now - last_frame_tick_) + " ms ago, sentinel " +
          (device_probe_.available() ? "watched" : "UNAVAILABLE") +
          tfc::LogThrottle::DescribeSuppression(decision));
    }

    // A rebuild held back while an engine was starting is released here when
    // that startup finishes without ever saying so -- the backstop for an app
    // whose Dart side never reports completion. The channel's own
    // startupComplete handler is the fast path.
    const tfc::SessionRebuildGate::Decision released = session_gate_.Poll(now);
    if (released.verdict == tfc::SessionRebuildGate::Verdict::kRebuildNow) {
      LogWatchdog(DescribeSessionRebuild(released));
      PerformSessionRebuild(released.reason);
      return 0;
    }

    // The Dart side is asked separately, because it is the half that the
    // device probe, the frame probe and the sentinel are all blind to. This
    // runs on the platform thread, driven by the timer-queue thread, so it
    // keeps working while the message queue is saturated.
    EvaluateDartLiveness(now);

    // Ask the device before counting silence. A positive answer is better
    // evidence than any number of unanswered probes, and it arrives sooner.
    if (RenderDeviceIsLost()) {
      Dispatch(WatchdogEvent::kRendererLost, tfc::LossCause::kContextLost);
    } else {
      Dispatch(WatchdogEvent::kTick);
    }
    return 0;
  }

  if (message == kSessionRebuildDueMessage) {
    const tfc::SessionRebuildGate::Decision released =
        session_gate_.Poll(::GetTickCount64());
    if (released.verdict == tfc::SessionRebuildGate::Verdict::kRebuildNow) {
      LogWatchdog(DescribeSessionRebuild(released));
      PerformSessionRebuild(released.reason);
    }
    return 0;
  }

  if (message == kEglStormMessage) {
    if (watchdog_enabled_ && flutter_controller_ != nullptr) {
      LogWatchdog(
          "EGL context-lost STORM on the engine's stderr (" +
          std::to_string(static_cast<unsigned int>(wparam)) +
          " matching lines inside the detector window) -- the engine says "
          "its context is gone, whatever the probes say. Declaring the "
          "renderer lost.");
      Dispatch(WatchdogEvent::kRendererLost, tfc::LossCause::kContextLost);
    }
    return 0;
  }

  // A WM_TIMER can still arrive from a timer this build no longer arms.
  if (message == WM_TIMER && wparam == kLegacyWatchdogTimerId) {
    ::KillTimer(hwnd, kLegacyWatchdogTimerId);
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      // Null while the engine is being restarted; the fresh engine picks up
      // the current fonts on its own.
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;

    case WM_POWERBROADCAST:
      // Resuming from sleep is the classic way a VM's virtual GPU comes back
      // as a reset (or different) device.
      if (wparam == PBT_APMRESUMEAUTOMATIC || wparam == PBT_APMRESUMESUSPEND) {
        if (watchdog_enabled_ && flutter_controller_) {
          const tfc::LogThrottle::Decision decision =
              hint_log_.Record(::GetTickCount64());
          if (decision.emit) {
            LogWatchdog("hint: power resume -- probing" +
                        tfc::LogThrottle::DescribeSuppression(decision));
          }
          NoteLossHint(tfc::LossHint::kPowerResume, 0);
          Dispatch(WatchdogEvent::kDeviceLossHint);
        }
      }
      break;

    case WM_DISPLAYCHANGE:
      if (watchdog_enabled_ && flutter_controller_) {
        const tfc::LogThrottle::Decision decision =
            hint_log_.Record(::GetTickCount64());
        if (decision.emit) {
          LogWatchdog("hint: WM_DISPLAYCHANGE -- probing" +
                      tfc::LogThrottle::DescribeSuppression(decision));
        }
        NoteLossHint(tfc::LossHint::kDisplayChange, 0);
        Dispatch(WatchdogEvent::kDeviceLossHint);
      }
      break;

    case WM_WTSSESSION_CHANGE:
      // Connecting or disconnecting an RDP session swaps the session's display
      // adapter, tearing down the D3D device ANGLE was rendering with.
      switch (wparam) {
        case WTS_CONSOLE_CONNECT:
        case WTS_CONSOLE_DISCONNECT:
        case WTS_REMOTE_CONNECT:
        case WTS_REMOTE_DISCONNECT:
        case WTS_SESSION_UNLOCK:
          if (watchdog_enabled_ && flutter_controller_) {
            char named[64];
            const tfc::LogThrottle::Decision decision =
                hint_log_.Record(::GetTickCount64());
            if (decision.emit) {
              LogWatchdog(
                  std::string("hint: session change -- ") +
                  tfc::DescribeSessionChange(static_cast<unsigned long>(wparam),
                                             named, sizeof(named)) +
                  " -- probing" +
                  tfc::LogThrottle::DescribeSuppression(decision));
            }
            NoteLossHint(tfc::LossHint::kSessionChange,
                         static_cast<unsigned long>(wparam));
            Dispatch(WatchdogEvent::kDeviceLossHint);

            // Console lock/unlock keeps the same adapter, so a probe is the
            // right response there. A REMOTE connect or disconnect swaps it,
            // and that is the case the probe is blind to.
            if (wparam == WTS_REMOTE_CONNECT) {
              RebuildForSessionChange("remote connect");
            } else if (wparam == WTS_REMOTE_DISCONNECT) {
              RebuildForSessionChange("remote disconnect");
            }
          }
          break;
        default:
          break;
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

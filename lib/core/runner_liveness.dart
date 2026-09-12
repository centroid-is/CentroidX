/// The UI isolate's own proof that it is still running, and the engine
/// generation it belongs to.
///
/// # Why this exists
///
/// A station froze on 2026-09-10 at 16:01:36 and it took hours to establish
/// what had happened, because every detector the runner had watches native
/// code and native code was healthy throughout. A full dump of the wedged
/// process showed the platform thread idle in `NtUserGetMessage`, the other 34
/// threads parked in ordinary condition waits, and no lock held by anyone.
/// Nothing was blocked. Nothing was scheduling frames either — the Dart side
/// had simply stopped, and nothing in the process was watching the Dart side.
///
/// The GPU watchdog's frame counter is not a substitute and cannot be made
/// into one: it calls `ForceRedraw()` itself every five seconds and then
/// counts the frames it forced, so it reads exactly one frame per five seconds
/// on a healthy station and exactly one frame per five seconds on a frozen
/// one. Measured identical across days of each.
///
/// So this is a clock the app runs for itself. A [Timer.periodic] in the UI
/// isolate posts a stamp over a method channel; the Windows runner writes it
/// into `hmi-runner.log`, which survives a windowed MSIX build with no
/// console, and notices when the stamps stop. Nothing native drives the timer,
/// which is the property the frame counter lacked.
///
/// # Engine generations
///
/// Every RDP session change destroys the `FlutterViewController` and builds a
/// new one, and destroying it shuts the isolate down: a "rebuild" is a whole
/// new `main()`. The frozen process contained three generations' worth of log
/// lines, and separating them meant doing elapsed-time arithmetic across
/// thousands of lines. The runner now hands each engine its generation number
/// as a Dart entrypoint argument, so the app can say which one it is in its
/// very first line — see [EngineEpoch.fromArguments].
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';

/// The channel the Windows runner listens on. Absent on every other platform,
/// which [RunnerLiveness] treats as "nothing to report to" rather than as an
/// error.
const MethodChannel kRunnerChannel = MethodChannel('centroid/runner');

/// The default cadence. Ten seconds is three stamps inside the runner's 30 s
/// silence threshold, so one missed stamp — a long garbage collection, a slow
/// page build — never reads as a freeze, while a real stall is named within
/// half a minute.
const Duration kLivenessInterval = Duration(seconds: 10);

/// Asks the engine to rasterise something, and says whether it could.
///
/// Returns true when a pixel came back, false when the engine handed back an
/// empty image, and null when the probe could not be run at all (no engine,
/// or it threw) -- which is "unknown", never "failed".
typedef RasterProbe = Future<bool?> Function();

/// How long a raster probe is given before it counts as failed. Longer than
/// any healthy 1 x 1 snapshot by orders of magnitude, shorter than the stamp
/// interval so probes never overlap.
const Duration kRasterProbeTimeout = Duration(seconds: 5);

/// The default [RasterProbe]: a 1 x 1 picture through the engine's snapshot
/// path, which is the same GPU context, render target and context-current
/// call the screen goes through.
///
/// # Why this exists
///
/// On 2026-09-12 a station's renderer died silently: the screen froze on its
/// last frame while every detector read healthy. The Dart isolate stamped
/// every 10 s with 20-30 frames per stamp, the watchdog's next-frame probe
/// was answered every 5 s, the sentinel adapter was fine, and the engine
/// wrote no context-lost errors for the stderr storm detector to see. The
/// only thing that said "dead" was the MCP screenshot tool: its
/// `RepaintBoundary.toImage` came back as a 0 x 0 image.
///
/// That is the engine's one honest tell. When a snapshot cannot be made --
/// the context will not go current, or no render target can be made --
/// `SnapshotControllerSkia::DoMakeRasterSnapshot` ends at a null `SkImage`,
/// which surfaces in Dart as an ordinary [ui.Image] reporting 0 x 0 from a
/// future that completed normally (see `lib/mcp/app_capture.dart` for the
/// engine-side trace). A healthy engine returns a real 1 x 1; an engine with
/// no GPU surface at all rasterises on the CPU and also returns one, so a
/// software-rendered station never reads as dead.
///
/// The image is disposed WITHOUT calling `toByteData`: encoding the empty
/// image dereferences null on the IO thread and takes the process down.
/// `toImageSync` is deliberately not used -- its deferred GPU image reports
/// the requested size whether or not anything was drawn.
Future<bool?> probeRasterisation() async {
  ui.Picture? picture;
  try {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
      const ui.Rect.fromLTWH(0, 0, 1, 1),
      ui.Paint()..color = const ui.Color(0xFF000000),
    );
    picture = recorder.endRecording();
    final image = await picture.toImage(1, 1);
    try {
      return image.width > 0 && image.height > 0;
    } finally {
      image.dispose();
    }
  } catch (_) {
    // Could not ask. Not evidence of anything; the stamp says "not probed".
    return null;
  } finally {
    picture?.dispose();
  }
}

/// Which engine generation this isolate is, and why it was started.
@immutable
class EngineEpoch {
  const EngineEpoch({required this.epoch, required this.reason});

  /// No runner told us. Non-Windows platforms, `flutter test`, and any build
  /// whose runner predates the argument. Deliberately distinguishable from
  /// epoch 1 so a log line can say "unknown" rather than claim to be first.
  static const EngineEpoch unknown = EngineEpoch(epoch: -1, reason: '');

  /// 1 for the process's first engine, incremented on every rebuild.
  final int epoch;

  /// What the runner said caused this generation: `initial start`,
  /// `session change: remote connect`, `gpu loss recovery`, ...
  final String reason;

  bool get isKnown => epoch >= 0;

  /// Reads `--engine-epoch=N` and `--engine-reason=...` out of the Dart
  /// entrypoint arguments.
  ///
  /// Tolerant on purpose: an unparseable or missing argument yields
  /// [unknown] rather than throwing. This runs in the first few statements of
  /// `main()`, where an exception is a station that does not start, and the
  /// value is only ever used to label a log line.
  factory EngineEpoch.fromArguments(List<String> arguments) {
    int epoch = -1;
    String reason = '';
    for (final argument in arguments) {
      final separator = argument.indexOf('=');
      if (separator < 0) continue;
      final name = argument.substring(0, separator);
      final value = argument.substring(separator + 1);
      switch (name) {
        case '--engine-epoch':
          final parsed = int.tryParse(value);
          if (parsed != null && parsed >= 0) epoch = parsed;
        case '--engine-reason':
          reason = value;
      }
    }
    if (epoch < 0) return unknown;
    return EngineEpoch(epoch: epoch, reason: reason);
  }

  /// One phrase for a log line.
  String describe() => isKnown
      ? 'epoch $epoch, reason=${reason.isEmpty ? 'unspecified' : reason}'
      : 'epoch unknown (no runner argument), reason=unspecified';

  @override
  bool operator ==(Object other) =>
      other is EngineEpoch && other.epoch == epoch && other.reason == reason;

  @override
  int get hashCode => Object.hash(epoch, reason);

  @override
  String toString() => 'EngineEpoch(${describe()})';
}

/// Sends periodic liveness stamps, plus the two lifecycle events that let a
/// log say where one engine generation ends and the next begins.
///
/// Every dependency is injectable so the whole thing is testable without a
/// platform channel and without a real clock.
class RunnerLiveness {
  RunnerLiveness({
    this.epoch = EngineEpoch.unknown,
    this.interval = kLivenessInterval,
    Future<void> Function(String method, Map<String, Object?> arguments)? invoke,
    int Function()? readFrames,
    RasterProbe? probeRaster,
    Logger? logger,
  })  : _invoke = invoke ?? _invokeOverChannel,
        _readFrames = readFrames,
        _probeRaster = probeRaster ?? probeRasterisation,
        _logger = logger ?? Logger();

  final EngineEpoch epoch;
  final Duration interval;
  final Future<void> Function(String, Map<String, Object?>) _invoke;
  final int Function()? _readFrames;
  final RasterProbe _probeRaster;
  final Logger _logger;

  /// Consecutive stamps whose raster probe failed. Reported on every stamp so
  /// the runner's line can carry it; the runner keeps its own count and makes
  /// the decision, because a probe that HANGS produces no stamp to count.
  int _rasterFailures = 0;

  /// Consecutive failed raster probes so far.
  int get rasterFailures => _rasterFailures;

  Timer? _timer;
  DateTime? _startedAt;
  int _ticks = 0;
  int _framesAtLastStamp = 0;
  int _unacknowledged = 0;
  bool _startupComplete = false;
  bool _channelMissing = false;
  TimingsCallback? _timingsCallback;
  int _frames = 0;

  /// Whether the stamp timer is running.
  bool get isRunning => _timer != null;

  /// Stamps sent since [start], including ones the platform side has not
  /// answered.
  int get ticks => _ticks;

  /// Announces the generation and starts the clock.
  ///
  /// Call as early in `main()` as a binding allows: the most valuable stamp is
  /// the one that never arrives, and it can only fail to arrive from a timer
  /// that was armed.
  void start({String? version}) {
    if (_timer != null) return;
    _startedAt = clock.now();

    // Into the app's own log as well as the runner's. The two logs are read at
    // different times by different people, and an engine restart is the fact
    // that makes every other line in either of them interpretable.
    _logger.i('Dart main() starting, ${epoch.describe()}'
        '${version == null ? '' : ', build $version'}');
    unawaited(_send('mainStarting', <String, Object?>{
      'epoch': epoch.epoch,
      'reason': epoch.reason,
      if (version != null) 'version': version,
    }));

    _attachFrameCounter();

    // Periodic rather than a self-rescheduling chain: a chain that misses one
    // link stops for good, which would turn a single slow tick into a
    // permanent false "frozen".
    _timer = Timer.periodic(interval, (_) => _stamp());
  }

  /// Says the app has finished its own startup — routes loaded, StateMan
  /// built, first page on screen.
  ///
  /// This is not decoration. The 2026-09-10 teardown landed on an engine that
  /// was still 35 s into starting up, still opening OPC UA clients, and
  /// nothing anywhere recorded that startup had not finished.
  void reportStartupComplete() {
    if (_startupComplete) return;
    _startupComplete = true;
    final started = _startedAt;
    final elapsed =
        started == null ? Duration.zero : clock.now().difference(started);
    _logger.i('App startup complete for ${epoch.describe()} '
        'after ${elapsed.inMilliseconds} ms');
    unawaited(_send('startupComplete', <String, Object?>{
      'epoch': epoch.epoch,
      'uptimeMs': elapsed.inMilliseconds,
    }));
  }

  /// Stops the clock. Idempotent.
  void stop() {
    _timer?.cancel();
    _timer = null;
    _detachFrameCounter();
  }

  Future<void> _stamp() async {
    _ticks++;
    final started = _startedAt;
    final now = clock.now();
    final uptime = started == null ? Duration.zero : now.difference(started);

    // How late this fire was against the cadence it promised. A healthy UI
    // isolate is within a few milliseconds; hundreds of milliseconds is an
    // event loop that is congested but not dead, which is worth seeing before
    // it becomes the other thing.
    final expected = interval * _ticks;
    final lag = uptime - expected;

    final frames = _drainFrames();

    // The one question none of the other signals can answer: did the engine
    // actually draw a pixel? Awaited with a timeout so a raster thread that
    // has stopped answering reads as a failed probe rather than as a Dart
    // isolate that stopped stamping -- those are different faults with
    // different recoveries, and the 2026-09-12 freeze was the first kind.
    final raster = await _probeRasterisation();
    if (raster == false) {
      _rasterFailures++;
    } else if (raster == true) {
      _rasterFailures = 0;
    }

    unawaited(_send('liveness', <String, Object?>{
      'epoch': epoch.epoch,
      'uptimeMs': uptime.inMilliseconds,
      'ticks': _ticks,
      'frames': frames,
      'lagMs': lag.isNegative ? 0 : lag.inMilliseconds,
      'startupComplete': _startupComplete,
      'unacked': _unacknowledged,
      'rasterProbed': raster != null,
      'rasterOk': raster ?? false,
      'rasterFailures': _rasterFailures,
    }));
  }

  Future<bool?> _probeRasterisation() async {
    try {
      return await _probeRaster().timeout(
        kRasterProbeTimeout,
        // A snapshot that does not come back in five seconds is a renderer
        // that is not drawing, whatever it would eventually say.
        onTimeout: () => false,
      );
    } catch (_) {
      return null;
    }
  }

  /// Frames the engine has reported to Dart since the previous stamp.
  ///
  /// Read as colour, never as the liveness signal: the GPU watchdog's
  /// `ForceRedraw()` manufactures frames of its own, so this number is not
  /// zero even on a station that is doing nothing. The stamp's ARRIVAL is the
  /// signal; this only distinguishes an isolate that is running and painting
  /// from one that is running and idle.
  int _drainFrames() {
    final read = _readFrames;
    final total = read != null ? read() : _frames;
    final delta = total - _framesAtLastStamp;
    _framesAtLastStamp = total;
    return delta < 0 ? 0 : delta;
  }

  void _attachFrameCounter() {
    if (_readFrames != null) return;
    final binding = SchedulerBinding.instance;
    void callback(List<FrameTiming> timings) => _frames += timings.length;
    _timingsCallback = callback;
    binding.addTimingsCallback(callback);
  }

  void _detachFrameCounter() {
    final callback = _timingsCallback;
    if (callback == null) return;
    SchedulerBinding.instance.removeTimingsCallback(callback);
    _timingsCallback = null;
  }

  Future<void> _send(String method, Map<String, Object?> arguments) async {
    if (_channelMissing) return;
    _unacknowledged++;
    try {
      await _invoke(method, arguments);
      _unacknowledged--;
    } on MissingPluginException {
      // No runner half: every platform but Windows, and any older Windows
      // build. Stop trying rather than throwing once per tick forever.
      _unacknowledged--;
      _channelMissing = true;
      _logger.d('Runner liveness channel is not present on this platform; '
          'stamps will not be recorded in hmi-runner.log');
    } catch (error) {
      // Never let a diagnostic take the app down with it. A stamp that could
      // not be delivered is not itself a fault: the runner's own detector
      // reads the ABSENCE of stamps, so a failure here is reported by the
      // silence it causes.
      _unacknowledged--;
      _logger.w('Runner liveness stamp "$method" failed: $error');
    }
  }

  static Future<void> _invokeOverChannel(
      String method, Map<String, Object?> arguments) {
    return kRunnerChannel.invokeMethod<void>(method, arguments);
  }
}

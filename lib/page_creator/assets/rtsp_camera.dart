/// A live RTSP camera view on the page.
///
/// Playback is media_kit (libmpv), which is what actually plays RTSP on the
/// desktop platforms (macOS/Windows/Linux — Linux needs the distro's libmpv
/// package at runtime) and, through package:media_kit_video_elinux, on the
/// flutter-elinux stations. Platforms without the native pieces — the
/// ivi-homescreen stations, `flutter test` — get a "playback unavailable"
/// placeholder instead of a crash. libmpv missing shows up when the player is
/// constructed, which happens inside a try/catch and never at import time; a
/// missing video output only shows up later, asynchronously, and lands on the
/// same placeholder via [RtspCameraStatus.unavailable].
///
/// A dropped stream retries on its own, on [RtspLiveness.retryDelay]'s
/// 5s-doubling-to-60s ladder; an
/// operator should never have to touch a camera tile to bring it back.
///
/// Liveness is decided by [RtspLiveness] from frames arriving, not from
/// libmpv's error stream — see that class for why the error stream cannot be
/// trusted when a page carries more than one camera.
library;

import 'dart:async';

import 'package:flutter/foundation.dart'
    show ValueListenable, debugPrint, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/media_kit_stale_refs.dart';
import '../../theme.dart';
import 'common.dart';

part 'rtsp_camera.g.dart';

@JsonSerializable(explicitToJson: true)
class RtspCameraConfig extends BaseAsset {
  @override
  String get displayName => 'RTSP camera';
  @override
  String get category => 'Visualization';
  @override
  List<String> get searchKeywords =>
      const ['camera', 'video', 'cctv', 'stream', 'surveillance'];

  /// Stream URL, e.g. `rtsp://user:pass@10.0.0.5:554/stream1`. Empty means
  /// not configured yet and renders a placeholder.
  String url;

  BoxFit fit;

  /// Plant cameras rarely carry useful audio, and eight tiles of compressor
  /// hum would be a nuisance — sound is opt-in.
  bool muted;

  RtspCameraConfig({
    this.url = '',
    this.fit = BoxFit.cover,
    this.muted = true,
  }) {
    size = const RelativeSize(width: 0.2, height: 0.15);
  }

  RtspCameraConfig.preview()
      : url = '',
        fit = BoxFit.cover,
        muted = true {
    size = const RelativeSize(width: 0.2, height: 0.15);
  }

  factory RtspCameraConfig.fromJson(Map<String, dynamic> json) =>
      _$RtspCameraConfigFromJson(json);
  @override
  Map<String, dynamic> toJson() => _$RtspCameraConfigToJson(this);

  @override
  Widget build(BuildContext context) => RtspCameraView(config: this);

  @override
  Widget configure(BuildContext context) =>
      _RtspCameraConfigEditor(config: this);
}

/// [unavailable] is a property of the platform, not of the camera: the video
/// output could not be created at all, so no amount of retrying will produce a
/// picture. Everything else is a property of the stream.
enum RtspCameraStatus { connecting, live, noSignal, unavailable }

/// What [RtspCameraView] needs from a video backend, so tests (and platforms
/// where libmpv cannot load) never touch media_kit.
abstract class RtspCameraPlayback {
  ValueListenable<RtspCameraStatus> get status;
  Widget buildVideo(BuildContext context, BoxFit fit);
  Future<void> dispose();
}

/// Decides whether a camera counts as live, from the only signal that turned
/// out to be trustworthy: frames arriving.
///
/// libmpv's error stream is not a death signal. FFmpeg's log callback is
/// process-global, so an `ffmpeg:`-prefixed failure raised by *one* player
/// surfaces on an unrelated player's error stream. Observed against a real
/// UniFi camera on 2026-09-01: a page with one healthy camera and one
/// unreachable one blanked the healthy tile to "No signal" and restarted its
/// stream every 5 s, indefinitely — the healthy player kept being handed
/// `tcp: Connection to tcp://10.50.1.1:554 failed` from the dead one, a port
/// it never dials. Alone, the same camera ran for minutes without a single
/// error. On a plant page of eight tiles, one camera off its PoE port would
/// take down all eight.
///
/// So: frames arriving beat any error, an error only counts while nothing is
/// decoding, and a stream that goes quiet for [stallTimeout] without saying so
/// is dead. The class is pure — it holds no timers and reads no clock — so the
/// whole policy is testable without libmpv.
@visibleForTesting
class RtspLiveness {
  RtspLiveness({this.stallTimeout = const Duration(seconds: 10)});

  /// How long frames may stop arriving before a live stream counts as dead.
  /// Generous next to a 30 fps feed: this catches a silent death, it is not a
  /// dropped-frame detector.
  final Duration stallTimeout;

  RtspCameraStatus _status = RtspCameraStatus.connecting;
  RtspCameraStatus get status => _status;

  /// Open attempts that have died without ever painting a picture, in a row.
  /// Feeds [retryDelay]; reset the moment frames flow.
  int _consecutiveFailures = 0;

  /// The attempt underway has already been counted — mpv surfaces several
  /// ffmpeg lines per failed open, and one failed attempt is one rung on the
  /// ladder, however loudly it fails.
  bool _diedThisAttempt = false;

  /// How long the owner should wait before the retry it is being asked for.
  ///
  /// 5s doubling to a 60s clamp. A flat 5s is what this was, and a flat
  /// interval against a dead stream is the same defect the subscribe ladder in
  /// tfc_dart's state_man.dart exists for: on 2026-09-07 an NVR refused opens
  /// for ~50 minutes and the tile ran ~150 full mpv reopens — demuxer threads,
  /// an audio-subsystem probe and a TLS dial each — at one per ~6s while the
  /// operator stood at the panel. The first rung stays short so a genuine blip
  /// still recovers in seconds; the clamp stays at a minute because an
  /// operator is looking at this tile, unlike a key subscription, so ten
  /// minutes between attempts would read as broken long after the camera is
  /// back.
  Duration get retryDelay {
    const base = Duration(seconds: 5);
    const cap = Duration(seconds: 60);
    final rung = _consecutiveFailures < 1 ? 0 : _consecutiveFailures - 1;
    // 5s << 4 overflows nothing and 5 * 2^4 = 80 > cap, so walk at most 4.
    final delay = base * (1 << (rung > 4 ? 4 : rung));
    return delay > cap ? cap : delay;
  }

  /// Frames have been seen at least once since the last [reopened].
  bool _decoding = false;
  Duration? _lastPosition;
  DateTime? _lastFrameAt;

  /// A retry is owed: the stream died and has not come back on its own.
  bool _retryPending = false;
  bool get retryPending => _retryPending;

  /// libmpv reported a frame size — a socket that connected is not a picture,
  /// so nothing counts as live before this.
  void videoSized() => _decoding = true;

  /// Playback position moved, i.e. a frame decoded. Cancels any pending retry:
  /// restarting a stream that is painting pictures is never right.
  void frame(Duration position, DateTime now) {
    if (position == _lastPosition) return;
    _lastPosition = position;
    // Media time moves before the first picture does — libmpv emits a position
    // while it is still negotiating. Counting that as a heartbeat would make an
    // unreachable camera look alive and swallow the very error that proves it
    // is not, leaving the tile spinning forever instead of retrying.
    if (!_decoding) return;
    _lastFrameAt = now;
    _status = RtspCameraStatus.live;
    _retryPending = false;
    // Pictures are proof the camera is healthy: a later death starts a new
    // outage at the bottom of the ladder, it is not the tail of the last one.
    _consecutiveFailures = 0;
    _diedThisAttempt = false;
  }

  /// An error arrived on the player's error stream. Only believed while
  /// nothing is decoding — see the class doc.
  void error(DateTime now) {
    if (_isFlowing(now)) return;
    _die();
  }

  /// libmpv reached the end of the stream. A finished feed is a dead camera,
  /// not a completed movie, and unlike the error stream this one is scoped to
  /// the player that raised it.
  void completed() => _die();

  /// Called on a timer: has a live stream gone quiet without saying so?
  void tick(DateTime now) {
    if (_status != RtspCameraStatus.live) return;
    if (_isFlowing(now)) return;
    _die();
  }

  /// The stream is being (re)opened. Deliberately not a ladder reset —
  /// reopening IS the retry, and only frames prove it worked.
  void reopened() {
    _status = RtspCameraStatus.connecting;
    _decoding = false;
    _lastPosition = null;
    _lastFrameAt = null;
    _retryPending = false;
    _diedThisAttempt = false;
  }

  /// The owner has armed the retry it was owed.
  void retryArmed() => _retryPending = false;

  bool _isFlowing(DateTime now) {
    final last = _lastFrameAt;
    return last != null && now.difference(last) < stallTimeout;
  }

  void _die() {
    _status = RtspCameraStatus.noSignal;
    _decoding = false;
    _lastFrameAt = null;
    _retryPending = true;
    if (!_diedThisAttempt) {
      _diedThisAttempt = true;
      _consecutiveFailures++;
    }
  }
}

class RtspCameraView extends StatefulWidget {
  final RtspCameraConfig config;
  const RtspCameraView({super.key, required this.config});

  /// Test hook: replaces the media_kit backend. Reset to null in tearDown.
  @visibleForTesting
  static RtspCameraPlayback Function(RtspCameraConfig config)?
      debugPlaybackFactory;

  @override
  State<RtspCameraView> createState() => _RtspCameraViewState();
}

class _RtspCameraViewState extends State<RtspCameraView> {
  RtspCameraPlayback? _playback;

  /// libmpv failed to load (or the player failed to construct) — a permanent
  /// condition on this platform, not a stream drop, so no retry.
  bool _unavailable = false;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void didUpdateWidget(RtspCameraView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.config.url != widget.config.url ||
        oldWidget.config.muted != widget.config.muted) {
      _close();
      _open();
    }
  }

  void _open() {
    if (widget.config.url.isEmpty) return;
    try {
      _playback = (RtspCameraView.debugPlaybackFactory ??
          _MediaKitPlayback.new)(widget.config);
    } catch (_) {
      _unavailable = true;
    }
  }

  void _close() {
    unawaited(_playback?.dispose().catchError((_) {}));
    _playback = null;
    _unavailable = false;
  }

  @override
  void dispose() {
    _close();
    super.dispose();
  }

  Widget _unavailablePlaceholder() => Tooltip(
        message: 'Video playback is not available on this platform',
        child: _Glyph(icon: Icons.videocam_off_outlined),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final playback = _playback;
    final Widget content;
    if (widget.config.url.isEmpty) {
      content = _Glyph(icon: Icons.videocam_outlined);
    } else if (_unavailable || playback == null) {
      content = _unavailablePlaceholder();
    } else {
      content = ValueListenableBuilder<RtspCameraStatus>(
        valueListenable: playback.status,
        builder: (context, status, _) {
          // Same placeholder as a player that never constructed: from the
          // operator's side there is no difference between libmpv missing and
          // its frames having nowhere to go.
          if (status == RtspCameraStatus.unavailable) {
            return _unavailablePlaceholder();
          }
          return Stack(
            fit: StackFit.expand,
            children: [
              playback.buildVideo(context, widget.config.fit),
              if (status == RtspCameraStatus.connecting)
                const Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              if (status == RtspCameraStatus.noSignal)
                _Glyph(icon: Icons.videocam_off_outlined, caption: 'No signal'),
              if (status == RtspCameraStatus.live)
                Positioned(left: 6, bottom: 6, child: _LiveBadge()),
            ],
          );
        },
      );
    }
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        // Video letterbox ground; the glyph states inherit it so a wall of
        // camera tiles reads uniformly whether or not streams are up.
        color: Colors.black87,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(4),
      ),
      child: content,
    );
  }
}

/// Centered icon (plus optional caption) sized off the box like the image
/// asset's placeholder — a glyph is a font glyph, scaling it via FittedBox
/// would resample it like text.
class _Glyph extends StatelessWidget {
  final IconData icon;
  final String? caption;
  const _Glyph({required this.icon, this.caption});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final shortest = constraints.biggest.shortestSide;
      final side = shortest.isFinite && shortest > 0 ? shortest : 48.0;
      final iconSide = caption == null ? side * 0.6 : side * 0.45;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: iconSide.clamp(16.0, 96.0), color: Colors.white38),
            if (caption != null && side >= 72) ...[
              const SizedBox(height: 4),
              Text(
                caption!,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Colors.white38),
              ),
            ],
          ],
        ),
      );
    });
  }
}

/// Small "LIVE" chip: muted running-green dot (the fleet's "in operation"
/// color — saturated red stays reserved for faults) on a translucent scrim.
class _LiveBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final running = HmiStateColors.of(context).green;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: running, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
          const Text(
            'LIVE',
            style: TextStyle(
                color: Colors.white70,
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.2),
          ),
        ],
      ),
    );
  }
}

/// The real backend. Construction throws where libmpv cannot load — the view
/// catches that and shows the unavailable placeholder.
class _MediaKitPlayback implements RtspCameraPlayback {
  static bool _initialized = false;

  /// How often the stall watchdog asks [RtspLiveness] whether frames are still
  /// arriving. Coarse on purpose — it is a death check, not a frame counter.
  static const Duration _tickInterval = Duration(seconds: 2);

  final Player _player;
  late final VideoController _controller;
  final _status = ValueNotifier<RtspCameraStatus>(RtspCameraStatus.connecting);
  final _subscriptions = <StreamSubscription<void>>[];
  final String _url;
  final _liveness = RtspLiveness();
  Timer? _retryTimer;
  Timer? _watchdog;
  bool _disposed = false;
  bool _videoUnavailable = false;

  _MediaKitPlayback(RtspCameraConfig config)
      : _url = config.url,
        _player = _construct() {
    _controller = VideoController(_player);
    // The native video output is created asynchronously, so a platform that
    // has libmpv but no way to render its frames (ivi-homescreen; an eLinux
    // build without package:media_kit_video_elinux) fails here rather than in
    // _construct. Nothing else listens to this future: without the handler the
    // failure is an unhandled async error and the tile spins forever.
    unawaited(_controller.platform.future.then<void>(
      (_) {},
      onError: (Object _) => _markVideoUnavailable(),
    ));
    if (config.muted) {
      unawaited(_player.setVolume(0).catchError((_) {}));
    }
    _subscriptions.add(_player.stream.error.listen((_) {
      _liveness.error(DateTime.now());
      _publish();
    }));
    // A finished stream is a dead camera feed, not a completed movie.
    _subscriptions.add(_player.stream.completed.listen((completed) {
      if (!completed) return;
      _liveness.completed();
      _publish();
    }));
    // Width flips non-null when frames actually decode — "connected" at the
    // socket level is not a picture.
    _subscriptions.add(_player.stream.width.listen((width) {
      if (width == null || width <= 0) return;
      _liveness.videoSized();
      _publish();
    }));
    // Position advances once per decoded frame: the heartbeat that says the
    // camera is genuinely up, and the only thing that can clear a spurious
    // error raised by another player.
    _subscriptions.add(_player.stream.position.listen((position) {
      _liveness.frame(position, DateTime.now());
      _publish();
    }));
    _watchdog = Timer.periodic(_tickInterval, (_) {
      _liveness.tick(DateTime.now());
      _publish();
    });
    _openMedia();
  }

  static Player _construct() {
    if (!_initialized) {
      // Before media_kit wakes up: delete the NativeReferenceHolder file a
      // dead predecessor with our pid left in /tmp, which the holder would
      // otherwise dereference. On stations the pid never changes between
      // container restarts, so without this the first camera tile after a
      // restart segfaults the whole app — see media_kit_stale_refs.dart.
      final purged = purgeStaleNativeReferenceFile();
      if (purged != null) {
        debugPrint('rtsp: deleted stale media_kit reference file from a '
            'previous process: $purged');
      }
      MediaKit.ensureInitialized();
      _initialized = true;
    }
    return Player(
      configuration: const PlayerConfiguration(logLevel: MPVLogLevel.error),
    );
  }

  void _openMedia() {
    _liveness.reopened();
    _publish();
    unawaited(_player.open(Media(_url), play: true).catchError((_) {
      _liveness.error(DateTime.now());
      _publish();
    }));
  }

  /// Mirrors [RtspLiveness] onto the widget, and arms or stands down the retry
  /// it asks for. A stream that came back on its own cancels its own retry —
  /// restarting a tile that is painting pictures is what made a healthy camera
  /// blank every 5 s.
  /// A permanent condition of the platform: stop the watchdog and the retry,
  /// they cannot fix a missing video output.
  void _markVideoUnavailable() {
    if (_disposed || _videoUnavailable) return;
    _videoUnavailable = true;
    _watchdog?.cancel();
    _watchdog = null;
    _publish();
  }

  void _publish() {
    if (_disposed) return;
    if (_videoUnavailable) {
      _status.value = RtspCameraStatus.unavailable;
      _retryTimer?.cancel();
      _retryTimer = null;
      return;
    }
    _status.value = _liveness.status;
    if (_liveness.retryPending) {
      if (_retryTimer == null) {
        // The delay comes from the liveness ladder, not a constant: a camera
        // that keeps refusing opens is asked again at 5s, 10s, ..., 60s, so a
        // dead NVR costs one mpv reopen a minute instead of ten.
        _retryTimer = Timer(_liveness.retryDelay, () {
          _retryTimer = null;
          if (!_disposed) _openMedia();
        });
        _liveness.retryArmed();
      }
    } else if (_liveness.status == RtspCameraStatus.live) {
      _retryTimer?.cancel();
      _retryTimer = null;
    }
  }

  @override
  ValueListenable<RtspCameraStatus> get status => _status;

  @override
  Widget buildVideo(BuildContext context, BoxFit fit) => Video(
        controller: _controller,
        fit: fit,
        controls: NoVideoControls,
        // The HMI never sleeps; skip the wakelock plugin round-trip.
        wakelock: false,
      );

  @override
  Future<void> dispose() async {
    _disposed = true;
    _watchdog?.cancel();
    _retryTimer?.cancel();
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _status.dispose();
    await _player.dispose();
  }
}

class _RtspCameraConfigEditor extends StatefulWidget {
  final RtspCameraConfig config;
  const _RtspCameraConfigEditor({required this.config});

  @override
  State<_RtspCameraConfigEditor> createState() =>
      _RtspCameraConfigEditorState();
}

class _RtspCameraConfigEditorState extends State<_RtspCameraConfigEditor> {
  RtspCameraConfig get config => widget.config;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextFormField(
            initialValue: config.url,
            decoration: const InputDecoration(
              labelText: 'Stream URL',
              hintText: 'rtsp://user:pass@10.0.0.5:554/stream1',
            ),
            onChanged: (value) => setState(() => config.url = value.trim()),
          ),
          const SizedBox(height: 16),
          Text('Fit', style: theme.textTheme.titleMedium),
          DropdownButton<BoxFit>(
            value: config.fit,
            isExpanded: true,
            onChanged: (value) => setState(() => config.fit = value!),
            items: const [BoxFit.cover, BoxFit.contain, BoxFit.fill]
                .map((f) =>
                    DropdownMenuItem<BoxFit>(value: f, child: Text(f.name)))
                .toList(),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Muted'),
            value: config.muted,
            onChanged: (value) => setState(() => config.muted = value),
          ),
          const SizedBox(height: 8),
          TextFormField(
            initialValue: config.text,
            decoration: const InputDecoration(labelText: 'Label'),
            onChanged: (value) => setState(() => config.text = value),
          ),
          const SizedBox(height: 8),
          DropdownButton<TextPos>(
            value: config.textPos,
            hint: const Text('Label position'),
            isExpanded: true,
            onChanged: (value) => setState(() => config.textPos = value),
            items: TextPos.values
                .map((e) =>
                    DropdownMenuItem<TextPos>(value: e, child: Text(e.name)))
                .toList(),
          ),
          const SizedBox(height: 16),
          SizeField(
            initialValue: config.size,
            onChanged: (size) => setState(() => config.size = size),
          ),
          const SizedBox(height: 16),
          CoordinatesField(
            initialValue: config.coordinates,
            onChanged: (c) => setState(() => config.coordinates = c),
          ),
        ],
      ),
    );
  }
}

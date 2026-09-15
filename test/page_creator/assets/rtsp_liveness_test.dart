import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/rtsp_camera.dart';

/// The liveness policy behind the camera tile. Every case here was written
/// against a real UniFi camera on 2026-09-01 — see [RtspLiveness] for what the
/// end-to-end run turned up.
void main() {
  final t0 = DateTime(2026, 9, 1, 12);
  DateTime at(int seconds) => t0.add(Duration(seconds: seconds));

  /// Walks a stream from opening to painting pictures.
  RtspLiveness live({Duration stallTimeout = const Duration(seconds: 10)}) {
    final l = RtspLiveness(stallTimeout: stallTimeout);
    l.videoSized();
    l.frame(const Duration(milliseconds: 33), at(0));
    return l;
  }

  test('a socket that connected is not a picture', () {
    final l = RtspLiveness();
    expect(l.status, RtspCameraStatus.connecting);
    // Position can move before any frame is sized; that is not a live camera.
    l.frame(const Duration(milliseconds: 33), at(0));
    expect(l.status, RtspCameraStatus.connecting);
    l.videoSized();
    l.frame(const Duration(milliseconds: 66), at(0));
    expect(l.status, RtspCameraStatus.live);
  });

  test('an unreachable camera goes to no signal and asks for a retry', () {
    final l = RtspLiveness();
    l.error(at(0));
    expect(l.status, RtspCameraStatus.noSignal);
    expect(l.retryPending, isTrue);
  });

  test("another player's error cannot blank a camera that is decoding", () {
    // The defect: ffmpeg's log callback is process-global, so an unreachable
    // camera elsewhere on the page raised `tcp: ... Connection refused` on this
    // player, which never dials that port.
    final l = live();
    l.error(at(1));
    expect(l.status, RtspCameraStatus.live);
    expect(l.retryPending, isFalse);
  });

  test('frames arriving stand the retry down', () {
    // The other half of the defect: a spurious error during connect armed a
    // 5 s retry that then tore down a stream which had come up in the meantime.
    final l = RtspLiveness();
    l.error(at(0));
    expect(l.retryPending, isTrue);
    l.videoSized();
    l.frame(const Duration(milliseconds: 33), at(1));
    expect(l.status, RtspCameraStatus.live);
    expect(l.retryPending, isFalse);
  });

  test('a stream that goes quiet without saying so is dead', () {
    final l = live(stallTimeout: const Duration(seconds: 10));
    l.tick(at(5));
    expect(l.status, RtspCameraStatus.live);
    l.tick(at(11));
    expect(l.status, RtspCameraStatus.noSignal);
    expect(l.retryPending, isTrue);
  });

  test('the watchdog leaves a flowing stream alone', () {
    final l = live();
    for (var s = 1; s <= 60; s++) {
      l.frame(Duration(milliseconds: 33 * s), at(s));
      l.tick(at(s));
    }
    expect(l.status, RtspCameraStatus.live);
    expect(l.retryPending, isFalse);
  });

  test('a repeated position is not a new frame', () {
    // mpv re-emits the same position when playback is paused or stalled;
    // that must not keep the watchdog happy.
    final l = live(stallTimeout: const Duration(seconds: 10));
    const frozen = Duration(milliseconds: 33);
    l.frame(frozen, at(30));
    l.tick(at(30));
    expect(l.status, RtspCameraStatus.noSignal);
  });

  test('end of stream is a dead camera, even mid-flow', () {
    // Unlike the error stream, `completed` is scoped to the player that raised
    // it, so it is believed straight away.
    final l = live();
    l.completed();
    expect(l.status, RtspCameraStatus.noSignal);
    expect(l.retryPending, isTrue);
  });

  test('reopening clears the retry and every liveness signal', () {
    final l = live();
    l.completed();
    l.reopened();
    expect(l.status, RtspCameraStatus.connecting);
    expect(l.retryPending, isFalse);
    // A frame from before the reopen must not be enough to call it live.
    l.frame(const Duration(milliseconds: 33), at(20));
    expect(l.status, RtspCameraStatus.connecting);
  });

  test('the owner marks the retry armed so it is not armed twice', () {
    final l = RtspLiveness();
    l.error(at(0));
    expect(l.retryPending, isTrue);
    l.retryArmed();
    expect(l.retryPending, isFalse);
    // A further error while still dead asks again.
    l.error(at(1));
    expect(l.retryPending, isTrue);
  });

  test('a camera that keeps failing backs off instead of retrying every 5s',
      () {
    // 2026-09-07 on hq-skjar: the NVR at 10.50.1.1:7441 refused opens for
    // ~50 minutes and the tile re-opened mpv every ~6.2s the whole time —
    // demuxer threads, an audio-subsystem probe and a TLS dial per attempt,
    // ~150 attempts, on both deployed images. A flat retry interval is what
    // froze the HMI once before (see kSubscribeBackoffSeconds in
    // tfc_dart's state_man.dart); the camera tile had the same flat 5s.
    final l = RtspLiveness();
    var t = 0;
    // Each cycle: the owner arms the retry it was asked for, the timer fires,
    // the stream is reopened, and the open fails again.
    Duration failOnce() {
      l.error(at(t++));
      expect(l.retryPending, isTrue);
      final delay = l.retryDelay;
      l.retryArmed();
      l.reopened();
      return delay;
    }

    expect(failOnce(), const Duration(seconds: 5),
        reason: 'a genuine blip must still recover quickly');
    expect(failOnce(), const Duration(seconds: 10));
    expect(failOnce(), const Duration(seconds: 20));
    expect(failOnce(), const Duration(seconds: 40));
    expect(failOnce(), const Duration(seconds: 60));
    expect(failOnce(), const Duration(seconds: 60),
        reason: 'the ladder is clamped, not unbounded');
  });

  test('many error events in one open attempt climb the ladder once', () {
    // mpv surfaces several ffmpeg lines per failed open; each lands on the
    // error stream. One failed attempt is one rung, however loudly it fails.
    final l = RtspLiveness();
    l.error(at(0));
    l.error(at(0));
    l.error(at(1));
    expect(l.retryDelay, const Duration(seconds: 5));
  });

  test('frames flowing reset the ladder', () {
    // A camera that came back and later blips again is a healthy camera
    // having a bad moment, not the tail of the previous outage.
    final l = RtspLiveness();
    for (var i = 0; i < 4; i++) {
      l.error(at(i));
      l.retryArmed();
      l.reopened();
    }
    expect(l.retryDelay, greaterThan(const Duration(seconds: 5)));
    l.videoSized();
    l.frame(const Duration(milliseconds: 33), at(10));
    expect(l.status, RtspCameraStatus.live);
    l.completed();
    expect(l.retryDelay, const Duration(seconds: 5));
  });

  test('media time moving is not a heartbeat before the first picture', () {
    // Regression from the first cut of this fix: libmpv emits a position while
    // it is still negotiating, which made an unreachable camera look alive,
    // swallowed its error, and left the tile spinning forever with no retry.
    final l = RtspLiveness();
    l.frame(const Duration(milliseconds: 33), at(0));
    l.error(at(1));
    expect(l.status, RtspCameraStatus.noSignal);
    expect(l.retryPending, isTrue);
  });
}

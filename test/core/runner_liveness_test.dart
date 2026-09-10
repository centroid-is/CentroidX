import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/runner_liveness.dart';

/// Records every call the liveness clock makes, so a test can assert on what
/// the runner would have seen without a platform channel behind it.
class _Recorder {
  final List<(String, Map<String, Object?>)> calls = [];

  /// Set to throw instead of recording, to model a platform that has no
  /// runner half.
  Object? throwThis;

  /// When true, calls never complete — the shape of a platform thread that
  /// has stopped answering.
  bool hang = false;

  Future<void> invoke(String method, Map<String, Object?> arguments) {
    if (throwThis != null) {
      return Future<void>.error(throwThis!);
    }
    calls.add((method, arguments));
    if (hang) return Completer<void>().future;
    return Future<void>.value();
  }

  List<Map<String, Object?>> of(String method) =>
      [for (final call in calls) if (call.$1 == method) call.$2];
}

void main() {
  group('EngineEpoch.fromArguments', () {
    test('reads the epoch and reason the runner passed', () {
      final epoch = EngineEpoch.fromArguments(
          ['--engine-epoch=3', '--engine-reason=session change: remote connect']);
      expect(epoch.epoch, 3);
      expect(epoch.reason, 'session change: remote connect');
      expect(epoch.isKnown, isTrue);
      expect(epoch.describe(), contains('epoch 3'));
      expect(epoch.describe(), contains('remote connect'));
    });

    test('is unknown when no runner passed anything', () {
      expect(EngineEpoch.fromArguments(const []), EngineEpoch.unknown);
      expect(EngineEpoch.fromArguments(const []).isKnown, isFalse);
      // Must not claim to be the first generation when it simply does not
      // know which one it is.
      expect(EngineEpoch.fromArguments(const []).epoch, isNot(1));
      expect(EngineEpoch.fromArguments(const []).describe(), contains('unknown'));
    });

    test('tolerates junk rather than failing to start the station', () {
      expect(EngineEpoch.fromArguments(['nonsense']), EngineEpoch.unknown);
      expect(EngineEpoch.fromArguments(['--engine-epoch=']), EngineEpoch.unknown);
      expect(EngineEpoch.fromArguments(['--engine-epoch=x']), EngineEpoch.unknown);
      expect(EngineEpoch.fromArguments(['--engine-epoch=-2']), EngineEpoch.unknown);
      expect(EngineEpoch.fromArguments(['--unrelated=1']), EngineEpoch.unknown);
    });

    test('takes an epoch even when the reason is missing', () {
      final epoch = EngineEpoch.fromArguments(['--engine-epoch=1']);
      expect(epoch.epoch, 1);
      expect(epoch.reason, isEmpty);
      expect(epoch.describe(), contains('unspecified'));
    });

    test('keeps a reason containing an equals sign intact', () {
      final epoch =
          EngineEpoch.fromArguments(['--engine-reason=a=b', '--engine-epoch=2']);
      expect(epoch.reason, 'a=b');
    });
  });

  group('RunnerLiveness', () {
    const epoch = EngineEpoch(epoch: 2, reason: 'session change: remote connect');

    RunnerLiveness build(_Recorder recorder, {int Function()? frames}) =>
        RunnerLiveness(
          epoch: epoch,
          interval: const Duration(seconds: 10),
          invoke: recorder.invoke,
          readFrames: frames ?? () => 0,
        );

    testWidgets('announces the engine generation the moment it starts',
        (tester) async {
      final recorder = _Recorder();
      final liveness = build(recorder);
      liveness.start(version: '0.2026.9.400');
      await tester.pump();

      final started = recorder.of('mainStarting');
      expect(started, hasLength(1));
      expect(started.single['epoch'], 2);
      expect(started.single['reason'], 'session change: remote connect');
      expect(started.single['version'], '0.2026.9.400');

      liveness.stop();
    });

    testWidgets('stamps on its own clock, with a rising tick count',
        (tester) async {
      final recorder = _Recorder();
      final liveness = build(recorder);
      liveness.start();

      // Nothing yet: the first stamp is due one interval in.
      await tester.pump(const Duration(seconds: 9));
      expect(recorder.of('liveness'), isEmpty);

      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 10));
      await tester.pump(const Duration(seconds: 10));

      final stamps = recorder.of('liveness');
      expect(stamps, hasLength(3));
      expect([for (final s in stamps) s['ticks']], [1, 2, 3]);
      expect([for (final s in stamps) s['epoch']], [2, 2, 2]);
      // Uptime is the isolate's own, and it advances.
      expect(stamps.first['uptimeMs'], 10000);
      expect(stamps.last['uptimeMs'], 30000);
      expect(liveness.ticks, 3);

      liveness.stop();
    });

    testWidgets('keeps stamping after a stamp that is never acknowledged',
        (tester) async {
      // A platform thread that stops answering must not silence the clock:
      // the runner reads the ABSENCE of stamps, so a Dart side that gave up
      // sending them would make a healthy engine look frozen and, worse,
      // would stop reporting the moment things got interesting.
      final recorder = _Recorder();
      final liveness = build(recorder);
      liveness.start();
      recorder.hang = true;

      await tester.pump(const Duration(seconds: 10));
      await tester.pump(const Duration(seconds: 10));
      await tester.pump(const Duration(seconds: 10));

      expect(recorder.of('liveness'), hasLength(3));
      liveness.stop();
    });

    testWidgets('reports startup completion once, and carries it afterwards',
        (tester) async {
      final recorder = _Recorder();
      final liveness = build(recorder);
      liveness.start();

      await tester.pump(const Duration(seconds: 10));
      expect(recorder.of('liveness').single['startupComplete'], isFalse);

      liveness.reportStartupComplete();
      liveness.reportStartupComplete(); // idempotent
      await tester.pump(const Duration(seconds: 10));

      final completed = recorder.of('startupComplete');
      expect(completed, hasLength(1));
      expect(completed.single['epoch'], 2);
      expect(completed.single['uptimeMs'], 10000);
      expect(recorder.of('liveness').last['startupComplete'], isTrue);

      liveness.stop();
    });

    testWidgets('reports frames as a delta, never as a running total',
        (tester) async {
      var frames = 0;
      final recorder = _Recorder();
      final liveness = build(recorder, frames: () => frames);
      liveness.start();

      frames = 12;
      await tester.pump(const Duration(seconds: 10));
      frames = 15;
      await tester.pump(const Duration(seconds: 10));
      await tester.pump(const Duration(seconds: 10));

      expect([for (final s in recorder.of('liveness')) s['frames']], [12, 3, 0]);
      liveness.stop();
    });

    testWidgets('measures how late its own timer fired', (tester) async {
      // fake_async runs a periodic timer at exactly its scheduled instant, so
      // lateness cannot be produced by pumping; the wall clock has to be moved
      // independently of the timer queue, which is what a congested event loop
      // does for real.
      final recorder = _Recorder();
      var now = DateTime.utc(2026, 9, 10, 16);
      late RunnerLiveness liveness;
      await withClock(Clock(() => now), () async {
        liveness = build(recorder);
        liveness.start();

        now = now.add(const Duration(seconds: 10));
        await tester.pump(const Duration(seconds: 10));
        expect(recorder.of('liveness').single['lagMs'], 0);

        // A tick the event loop only got to four seconds late. The stamp is
        // still liveness -- the point is that it says so rather than hiding
        // it behind a punctual-looking tick count.
        now = now.add(const Duration(seconds: 14));
        await tester.pump(const Duration(seconds: 10));
        expect(recorder.of('liveness').last['lagMs'], 4000);
      });

      liveness.stop();
    });

    testWidgets('stops when told to', (tester) async {
      final recorder = _Recorder();
      final liveness = build(recorder);
      liveness.start();
      await tester.pump(const Duration(seconds: 10));
      expect(liveness.isRunning, isTrue);

      liveness.stop();
      await tester.pump(const Duration(seconds: 60));

      expect(liveness.isRunning, isFalse);
      expect(recorder.of('liveness'), hasLength(1));
    });

    testWidgets('goes quiet on a platform with no runner half',
        (tester) async {
      // Linux, macOS, and any Windows build older than the runner change.
      // One missed call, then nothing -- not an exception per tick forever.
      final recorder = _Recorder();
      final liveness = build(recorder);
      recorder.throwThis = MissingPluginException('no runner');
      liveness.start();
      await tester.pump(const Duration(seconds: 10));
      recorder.throwThis = null;
      await tester.pump(const Duration(seconds: 10));
      await tester.pump(const Duration(seconds: 10));

      expect(recorder.calls, isEmpty);
      liveness.stop();
    });

    testWidgets('a failing channel does not stop the clock', (tester) async {
      // A diagnostic that can take the app down with it is worse than none.
      final recorder = _Recorder();
      final liveness = build(recorder);
      liveness.start();
      recorder.throwThis = PlatformException(code: 'boom');
      await tester.pump(const Duration(seconds: 10));
      recorder.throwThis = null;
      await tester.pump(const Duration(seconds: 10));

      expect(recorder.of('liveness'), hasLength(1));
      expect(liveness.ticks, 2);
      liveness.stop();
    });

    testWidgets('counts real engine frames when nothing is injected',
        (tester) async {
      // The default path: the frame counter comes from SchedulerBinding's
      // timings callback rather than from anything the runner drives.
      final recorder = _Recorder();
      final liveness = RunnerLiveness(
        epoch: epoch,
        interval: const Duration(seconds: 10),
        invoke: recorder.invoke,
      );
      liveness.start();
      await tester.pump(const Duration(seconds: 10));

      expect(recorder.of('liveness').single['frames'], isA<int>());
      liveness.stop();
    });
  });
}

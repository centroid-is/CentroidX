/// Lifecycle properties of the acquisition supervisor that the pipe rests on.
///
/// PIPE-12 (death is an event, not decay) and PIPE-13 (shutdown by kill) both
/// need things `_spawnWithRespawn` did not provide: something to kill, a death
/// notice that is ordered against the worker's own data, and a way to tell a
/// deliberate kill from a crash. These arms pin exactly those, and nothing
/// about the backoff ladder — that behaviour is deliberately untouched and is
/// covered where it already was.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:isolate';

import 'package:test/test.dart';
import 'package:tfc_dart/core/data_acquisition_isolate.dart';

/// How many data messages the chatty worker sends before it exits.
///
/// Large enough that "the last batch before death" is a real ordering claim
/// rather than a single message that could arrive either way by luck.
const kBurst = 200;

DataAcquisitionIsolateConfig _config() => DataAcquisitionIsolateConfig(
      dbConfigJson: const {},
      keyMappingsJson: const {},
    );

/// Hands back a control port, floods the data port, then returns — so the
/// isolate dies on its own and `onExit` fires right behind the last message.
@pragma('vm:entry-point')
void chattyThenExitEntry(DataAcquisitionIsolateConfig config) {
  final toMain = config.toMain!;
  final control = ReceivePort();
  toMain.send(control.sendPort);
  for (var i = 0; i < kBurst; i++) {
    toMain.send('data-$i');
  }
  // Nothing is left to keep the isolate alive, so it terminates here.
  control.close();
}

/// Hands back a control port and then stays up forever. The stand-in for a
/// healthy worker: only a kill (or an error) can end it.
@pragma('vm:entry-point')
void parkingEntry(DataAcquisitionIsolateConfig config) {
  final control = ReceivePort();
  control.listen((_) {});
  config.toMain!.send(control.sendPort);
}

/// Alive, talking, but never completes the handshake — a worker wedged inside
/// its own startup. Without a deadline this is the shape that hangs main.
@pragma('vm:entry-point')
void wedgedEntry(DataAcquisitionIsolateConfig config) {
  final control = ReceivePort();
  control.listen((_) {});
  config.toMain!.send('alive-but-never-ready');
}

/// Polls [predicate] until it holds or [within] elapses. Used instead of a
/// flat delay so a fast machine does not pay for the slow machine's margin.
Future<void> waitUntil(bool Function() predicate, Duration within,
    {String? reason}) async {
  final deadline = DateTime.now().add(within);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Condition not met within ${within.inMilliseconds}ms'
          '${reason == null ? '' : ': $reason'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void main() {
  group('worker handle', () {
    test('the supervisor hands back a live, killable worker', () async {
      final worker = await spawnWorkerForTest(_config(), 'handle',
          entryPoint: parkingEntry);
      addTearDown(worker.kill);

      await worker.ready.timeout(const Duration(seconds: 10));

      expect(worker.isolate, isNotNull,
          reason: 'PIPE-13 has nothing to Isolate.kill until the value '
              'Isolate.spawn returns is captured');
      expect(worker.controlPort, isNotNull,
          reason: "the worker's first message is its control SendPort");
      expect(worker.generation, 1);
    });
  });

  group('death ordering (A1)', () {
    test('every data message arrives before the null death sentinel',
        () async {
      final worker = await spawnWorkerForTest(_config(), 'fifo',
          entryPoint: chattyThenExitEntry);
      addTearDown(worker.kill);

      final seen = <Object?>[];
      final died = Completer<void>();
      worker.messages.listen((m) {
        seen.add(m);
        if (m == null && !died.isCompleted) died.complete();
      });

      await died.future.timeout(const Duration(seconds: 10));

      final deathIndex = seen.indexOf(null);
      expect(deathIndex, greaterThan(0));
      final beforeDeath = seen.sublist(0, deathIndex);
      expect(beforeDeath.whereType<SendPort>().length, 1,
          reason: 'the handshake leads');
      expect(
        beforeDeath.whereType<String>().toList(),
        [for (var i = 0; i < kBurst; i++) 'data-$i'],
        reason: 'onExit rides the SAME ReceivePort as the data, so FIFO '
            'within one port puts the whole last batch ahead of the null. '
            'On two ports this ordering is not guaranteed and main would '
            'mark keys bad while their final values were still in flight.',
      );
    });
  });

  group('respawn vs deliberate kill', () {
    test('an unexpected exit is still respawned', () async {
      final worker = await spawnWorkerForTest(_config(), 'respawn',
          entryPoint: chattyThenExitEntry);
      addTearDown(worker.kill);

      // The backoff floor is 2s and is deliberately not touched by this plan.
      await waitUntil(() => worker.generation >= 2, const Duration(seconds: 20),
          reason: 'a worker that dies on its own must come back');
    });

    test('a deliberately killed worker is NOT respawned', () async {
      final worker =
          await spawnWorkerForTest(_config(), 'kill', entryPoint: parkingEntry);
      await worker.ready.timeout(const Duration(seconds: 10));
      expect(worker.generation, 1);

      final seen = <Object?>[];
      worker.messages.listen(seen.add);

      worker.kill();

      // The death is still announced — shutdown is not silence.
      await waitUntil(() => seen.contains(null), const Duration(seconds: 5),
          reason: 'onExit fires on kill, so main still learns the worker died');

      // Well past the 2s backoff floor.
      await Future<void>.delayed(const Duration(seconds: 4));
      expect(worker.generation, 1,
          reason: 'without the _shuttingDown guard the exit listener cannot '
              'tell a kill from a crash and resurrects the worker main just '
              'shut down, so the process never exits');
      expect(worker.isolate, isNull);
    });
  });
}

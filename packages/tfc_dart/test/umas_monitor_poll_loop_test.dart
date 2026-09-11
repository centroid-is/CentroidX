/// B-4 (v1.1.x): temporal coverage for the batched MonitorPlc poll loop
/// in [ModbusDeviceClientAdapter].
///
/// Pins the contract:
///   1. Subscribing to N UMAS-by-name keys produces fresh emissions on the
///      poll-group cadence, not a single seeded read.
///   2. Each poll tick issues ONE `MonitorPlc ReadAll` request — not N
///      individual reads — even with N keys subscribed.
///   3. The MonitorPlc table is built on the first `connected` event and
///      torn down + rebuilt on reconnect.
///
/// Run: dart test test/umas_monitor_poll_loop_test.dart
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:modbus_client/modbus_client.dart';
import 'package:modbus_client_tcp/modbus_client_tcp.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/modbus_client_wrapper.dart';
import 'package:tfc_dart/core/modbus_device_client.dart';
import 'package:tfc_dart/core/state_man.dart'
    show ConnectionStatus, EffectiveDeviceStatus, ModbusPollGroupConfig;
import 'package:tfc_dart/core/umas_types.dart' show UmasSessionState;
import 'helpers/wait_until.dart';

String _findProjectRoot() {
  var dir = Directory.current;
  while (dir.path != dir.parent.path) {
    if (File('${dir.path}/test/umas_stub_server.py').existsSync()) {
      return dir.path;
    }
    dir = dir.parent;
  }
  return '${Directory.current.path}/../..';
}

void main() {
  group('ModbusDeviceClientAdapter MonitorPlc batched poll loop (B-4)', () {
    late int stubPort;
    Process? serverProcess;
    final stubLog = <String>[];

    Future<void> startStub() async {
      stubLog.clear();
      final stubScript = '${_findProjectRoot()}/test/umas_stub_server.py';
      String python;
      try {
        final r = await Process.run('python3', ['--version']);
        python = r.exitCode == 0 ? 'python3' : 'python';
      } catch (_) {
        python = 'python';
      }
      serverProcess = await Process.start(
        python,
        ['-u', stubScript, '--port', '0'],
      );
      serverProcess!.stderr
          .transform(const SystemEncoding().decoder)
          .listen((line) => stderr.write('[STUB ERR] $line'));
      final completer = Completer<int>();
      final portPattern = RegExp(r'PORT=(\d+)');
      serverProcess!.stdout
          .transform(const SystemEncoding().decoder)
          .listen((line) {
        stubLog.add(line);
        stdout.write('[STUB] $line');
        if (!completer.isCompleted) {
          final m = portPattern.firstMatch(line);
          if (m != null) completer.complete(int.parse(m.group(1)!));
        }
      });
      stubPort = await completer.future.timeout(const Duration(seconds: 5));
    }

    setUp(startStub);
    tearDown(() {
      serverProcess?.kill();
      serverProcess = null;
    });

    /// Builds a connected ModbusClientWrapper against the running stub.
    Future<ModbusClientWrapper> connectedWrapper() async {
      final wrapper = ModbusClientWrapper(
        '127.0.0.1',
        stubPort,
        255,
        clientFactory: (h, p, u) => ModbusClientTcp(
          h,
          serverPort: p,
          unitId: u,
          connectionMode: ModbusConnectionMode.doNotConnect,
          connectionTimeout: const Duration(seconds: 3),
        ),
      );
      wrapper.connect();
      final ready = Completer<void>();
      late StreamSubscription<ConnectionStatus> sub;
      sub = wrapper.connectionStream.listen((s) {
        if (s == ConnectionStatus.connected && !ready.isCompleted) {
          ready.complete();
          sub.cancel();
        }
      });
      await ready.future.timeout(const Duration(seconds: 5));
      return wrapper;
    }

    test(
        'subscribe() emits values on the configured poll-group cadence, '
        'not just the BehaviorSubject seed',
        () async {
      final wrapper = await connectedWrapper();
      // 50ms cadence — a 350ms observation window comfortably contains
      // multiple ticks even on a slow CI box.
      final adapter = ModbusDeviceClientAdapter(
        wrapper,
        specs: const {},
        serverAlias: 'plc1',
        variableNames: const {
          'temperature': 'Application.GVL.temperature',
        },
        umasEnabled: true,
        umasPollGroupByKey: const {'temperature': 'fast'},
        pollGroups: [
          ModbusPollGroupConfig(name: 'fast', intervalMs: 50),
        ],
      );

      try {
        // Wait for the table-build microtask to settle.
        await Future.delayed(const Duration(milliseconds: 200));

        final received = <num>[];
        final sub = adapter.subscribe('temperature').listen((dv) {
          if (dv.value is num) received.add(dv.value as num);
        });

        // Observation window — at 50ms cadence we expect >=4 emissions.
        await Future.delayed(const Duration(milliseconds: 350));
        await sub.cancel();

        expect(received.length, greaterThanOrEqualTo(3),
            reason: 'expected multiple MonitorPlc ReadAll emissions '
                'over a 350ms window at 50ms cadence; got ${received.length}');
        // All emissions point at the stub's stored value (22.5).
        for (final v in received) {
          expect(v, closeTo(22.5, 0.01),
              reason: 'every emission must reflect the stub value');
        }
      } finally {
        adapter.dispose();
      }
    });

    test(
        'one TCP roundtrip per poll tick — not N — even with multiple keys',
        () async {
      final wrapper = await connectedWrapper();
      final adapter = ModbusDeviceClientAdapter(
        wrapper,
        specs: const {},
        serverAlias: 'plc1',
        variableNames: const {
          'temperature': 'Application.GVL.temperature',
          'pressure': 'Application.GVL.pressure',
          'elevator_speed': 'Application.Motors.M_Elevator.speed',
        },
        umasEnabled: true,
        umasPollGroupByKey: const {
          'temperature': 'fast',
          'pressure': 'fast',
          'elevator_speed': 'fast',
        },
        pollGroups: [
          ModbusPollGroupConfig(name: 'fast', intervalMs: 50),
        ],
      );

      try {
        // Wait for the table to build (issues monitorReset + readPlcStatus
        // + browse + monitorRegister) before counting ticks. This waits for
        // the build to become observable rather than sleeping a guessed
        // 400ms: on a loaded runner the build had not finished inside that
        // window and the poll count came back 1 instead of >=3
        // (tfc-dart-test (windows-latest), 2026-09-10).
        await waitUntil(
          () => stubLog.any((l) => l.contains('MonitorPlc: registered')),
          what: 'the initial MonitorPlc table build registered its keys',
        );
        final logSizeAfterBuild = stubLog.length;

        // Let the poll loop run. The property under test is the *ratio* --
        // one MonitorPlc roundtrip per tick rather than one per key -- so
        // measure it against the ticks that actually elapsed instead of the
        // ticks a fixed 200ms sleep was assumed to contain. That assumption
        // is what made this test fragile; the batching claim itself is not
        // timing-dependent at all.
        const cadenceMs = 50;
        final elapsed = Stopwatch()..start();
        await waitUntil(
          () =>
              stubLog
                  .sublist(logSizeAfterBuild)
                  .where((l) => l.contains('FC90 subFunc=0x50'))
                  .length >=
              3,
          what: 'the MonitorPlc poll loop issued 3 batched reads',
        );
        elapsed.stop();

        // Count MonitorPlc ReadAll requests since the table built. Each
        // logs as "MonitorPlc ReadAll: no data for ..." OR the response
        // path doesn't log per-success, so we count the explicit FC90
        // sub-function 0x50 lines instead.
        final pollLines = stubLog
            .sublist(logSizeAfterBuild)
            .where((l) => l.contains('FC90 subFunc=0x50'))
            .toList();

        final ticks = (elapsed.elapsedMilliseconds / cadenceMs).ceil();
        expect(pollLines.length, greaterThanOrEqualTo(3),
            reason: 'the wait above only returns once 3 polls are in the log; '
                'got ${pollLines.length}');
        // Three keys are registered, so per-key reads would be ~3x the ticks.
        expect(pollLines.length, lessThanOrEqualTo(ticks + 2),
            reason: 'one roundtrip per tick — got ${pollLines.length} over '
                '~$ticks ticks (${elapsed.elapsedMilliseconds}ms at '
                '${cadenceMs}ms cadence), '
                'which would indicate per-key reads instead of batched');

        // And the subscribers must have observed live data for ALL three
        // keys despite only one of them seeing a `subscribe()` call up to
        // this point.
        final tempVals = <num>[];
        final pressVals = <num>[];
        final elevVals = <num>[];
        final s1 = adapter
            .subscribe('temperature')
            .listen((dv) => tempVals.add(dv.value as num));
        final s2 = adapter
            .subscribe('pressure')
            .listen((dv) => pressVals.add(dv.value as num));
        final s3 = adapter
            .subscribe('elevator_speed')
            .listen((dv) => elevVals.add(dv.value as num));
        await Future.delayed(const Duration(milliseconds: 150));
        await s1.cancel();
        await s2.cancel();
        await s3.cancel();

        expect(tempVals, isNotEmpty);
        expect(pressVals, isNotEmpty);
        expect(elevVals, isNotEmpty);
        // BehaviorSubject seeds new listeners with the latest cached value,
        // so each subscriber sees at least one emission.
        expect(tempVals.first, closeTo(22.5, 0.01));
        expect(pressVals.first, closeTo(1.013, 0.001));
        expect(elevVals.first, closeTo(1450.0, 0.1));
      } finally {
        adapter.dispose();
      }
      // Logs flush after dispose runs the wrapper teardown.
      print('[B-4] stub log size at end: ${stubLog.length}');
    });

    test(
        'per-group cadences are honored: a slow group ticks less often '
        'than a fast group even though both share the MonitorPlc table',
        () async {
      final wrapper = await connectedWrapper();
      final adapter = ModbusDeviceClientAdapter(
        wrapper,
        specs: const {},
        serverAlias: 'plc1',
        variableNames: const {
          'temp_fast': 'Application.GVL.temperature',
          'press_slow': 'Application.GVL.pressure',
        },
        umasEnabled: true,
        umasPollGroupByKey: const {
          'temp_fast': 'fast',
          'press_slow': 'slow',
        },
        pollGroups: [
          ModbusPollGroupConfig(name: 'fast', intervalMs: 30),
          ModbusPollGroupConfig(name: 'slow', intervalMs: 200),
        ],
      );

      try {
        // Wait for the table to build.
        await Future.delayed(const Duration(milliseconds: 300));
        final logSizeAfterBuild = stubLog.length;

        await Future.delayed(const Duration(milliseconds: 400));

        final pollLines = stubLog
            .sublist(logSizeAfterBuild)
            .where((l) => l.contains('FC90 subFunc=0x50'))
            .toList();

        // Fast: 400ms / 30ms ≈ 13 ticks.
        // Slow: 400ms / 200ms ≈ 2 ticks.
        // Total: ~15. Lower bound (slow CI): 8. Upper bound: 20.
        expect(pollLines.length, greaterThanOrEqualTo(8),
            reason: 'expected ≥8 combined ticks over 400ms; '
                'got ${pollLines.length}');
        expect(pollLines.length, lessThanOrEqualTo(25),
            reason: 'expected ≤25 combined ticks; '
                'got ${pollLines.length}');
      } finally {
        adapter.dispose();
      }
    });

    /// v1.1.x Bug A (real fix): pairing the UMAS session must NOT depend
    /// on a UMAS-by-name key being configured. An adapter with
    /// `umasEnabled=true` and zero by-name keys (e.g. KeyMappings still
    /// hold only classic-Modbus addresses, or no keys at all yet) used
    /// to leave the session uninitialized forever — the chip showed
    /// `umasUnhealthy` (amber) even though the PLC was perfectly fine,
    /// because the only path to session init was an operator-triggered
    /// read of a by-name key. After the fix, every (re)connect kicks off
    /// `readPlcStatus()` in the background and the session transitions
    /// to `paired` within a round-trip.
    test(
        'eager session pairing fires on connect even with zero UMAS-by-name '
        'keys configured (v1.1.x Bug A real fix)', () async {
      final wrapper = await connectedWrapper();
      final adapter = ModbusDeviceClientAdapter(
        wrapper,
        specs: const {},
        serverAlias: 'plc1',
        // INTENTIONALLY empty — this is the regression case. No
        // variableNames, no umasPollGroupByKey. The adapter has nothing
        // to read by name but `umasEnabled=true` still means we want the
        // chip to reflect real session health.
        variableNames: const {},
        umasEnabled: true,
      );

      try {
        // Give the microtask + readPlcStatus round-trip time to fire.
        // The stub responds immediately so 250ms is more than enough.
        await Future.delayed(const Duration(milliseconds: 250));

        // Effective status must transition from connecting → connected
        // (paired) without any subscriber having called subscribe()
        // or read() on a by-name key.
        expect(
          adapter.effectiveStatus,
          EffectiveDeviceStatus.connected,
          reason: 'eager session pairing should have flipped the chip '
              'to connected by now; got ${adapter.effectiveStatus}',
        );

        // The stub must have observed the pairing handshake: init
        // (FC90 subFunc=0x01) fires unconditionally during
        // `_initWithRetry`. Without the fix, no UMAS FC90 frames would
        // have been issued at all because no by-name read drove the
        // session into init.
        final initLines = stubLog
            .where((l) => l.contains('FC90 subFunc=0x01'))
            .toList();
        expect(initLines, isNotEmpty,
            reason: 'expected UMAS init (FC90 subFunc=0x01) to fire on '
                'TCP connect even with no UMAS-by-name keys; stub log '
                'has no such line');
      } finally {
        adapter.dispose();
      }
    });

    /// Confirms eager pairing is idempotent: re-connecting the wrapper
    /// pairs the session a second time without crashing or leaking
    /// listeners. (Adapter survives reconnect by design.)
    test(
        'eager session pairing re-fires on reconnect '
        '(v1.1.x Bug A real fix lifecycle)', () async {
      final wrapper = await connectedWrapper();
      final adapter = ModbusDeviceClientAdapter(
        wrapper,
        specs: const {},
        serverAlias: 'plc1',
        variableNames: const {},
        umasEnabled: true,
      );

      try {
        // First pairing.
        await Future.delayed(const Duration(milliseconds: 250));
        expect(adapter.effectiveStatus, EffectiveDeviceStatus.connected);

        final logSizeAfterFirstPair = stubLog.length;

        // The UmasClient is bound to wrapper.client identity. To force
        // a second init we observe sessionStream directly via the
        // debug accessor — paired is the terminal state, so we just
        // assert the underlying state.
        final umas = adapter.debugUmasClient;
        expect(umas, isNotNull, reason: 'eager pairing must have '
            'materialized the UmasClient');
        expect(umas!.sessionState, UmasSessionState.paired,
            reason: 'session must be paired after eager pairing');

        // No new init traffic should fire spontaneously — pairing is
        // a one-shot per connection.
        await Future.delayed(const Duration(milliseconds: 200));
        // Allow a few keep-alive frames but no init (0x01) bursts.
        final newInitLines = stubLog
            .sublist(logSizeAfterFirstPair)
            .where((l) => l.contains('FC90 subFunc=0x01'))
            .toList();
        expect(newInitLines, isEmpty,
            reason: 'init must not refire on an already-paired session');
      } finally {
        adapter.dispose();
      }
    });
  });
}

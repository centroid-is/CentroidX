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
///   4. Each poll group keeps its OWN cadence while sharing that one table.
///
/// Contracts 1-3 are wire-level, so they run against the Python UMAS stub
/// over a real socket. Contract 4 is not: it is `Timer.periodic` and nothing
/// else, so it runs on a virtual clock (`package:fake_async`) where the tick
/// counts are exact and a loaded runner cannot change them. See the group
/// doc comment on that first group for the flake this replaced.
///
/// Run: dart test test/umas_monitor_poll_loop_test.dart
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:modbus_client/modbus_client.dart';
import 'package:modbus_client_tcp/modbus_client_tcp.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/modbus_client_wrapper.dart';
import 'package:tfc_dart/core/modbus_device_client.dart';
import 'package:tfc_dart/core/state_man.dart'
    show ConnectionStatus, EffectiveDeviceStatus, ModbusPollGroupConfig;
import 'package:tfc_dart/core/umas_client.dart';
import 'package:tfc_dart/core/umas_types.dart';
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

// ---------------------------------------------------------------------------
// Deterministic (virtual-clock) harness for the per-group cadence contract.
//
// The poll loop is nothing but `Timer.periodic(interval)` per group, so the
// cadence claim can — and must — be measured on a virtual clock. Everything
// below exists so the adapter can be driven to the point where those timers
// are running WITHOUT a socket, a subprocess, or a single millisecond of real
// time: `FakeAsync.elapse` then reports exact tick counts.
// ---------------------------------------------------------------------------

/// Wrapper stand-in that reports a live connection without opening one.
///
/// Two overrides are load-bearing:
///  * `connectionStatus` — `_pollUmasGroup`'s first guard returns early on
///    anything but `connected`.
///  * `client` — `debugSetUmasClient` binds `_umasClientFor` to
///    `wrapper.client`, and the table build compares it against
///    `_umasTableBuiltFor` by identity. A null here would make both sides
///    `null`, `identical(null, null)` would short-circuit the build, and the
///    adapter would fall back to per-key reads instead of the MonitorPlc
///    path this test is about. A stable non-null instance keeps us on the
///    batched path.
class _OfflineWrapper extends ModbusClientWrapper {
  _OfflineWrapper()
      : super('mock', 0, 1,
            clientFactory: (h, p, u) => ModbusClientTcp(h,
                serverPort: p,
                unitId: u,
                connectionMode: ModbusConnectionMode.doNotConnect));

  final ModbusClientTcp _fixedClient = ModbusClientTcp('mock',
      serverPort: 0,
      unitId: 1,
      connectionMode: ModbusConnectionMode.doNotConnect);

  @override
  ConnectionStatus get connectionStatus => ConnectionStatus.connected;

  @override
  ModbusClientTcp? get client => _fixedClient;
}

/// UmasClient stand-in that counts the calls the poll loop makes instead of
/// putting them on a wire. Every method returns an already-completed future,
/// so a `flushMicrotasks()` is enough to settle a whole table build.
class _CountingUmasClient extends UmasClient {
  _CountingUmasClient()
      : super(sendFn: (_) async => ModbusResponseCode.requestSucceed) {
    // Pre-prime the session so the adapter never reaches for a real
    // handshake.
    debugSetBlockCrcs(const <int>[0xDEADBEEF]);
    debugSetProjectCrc(0xCAFEBABE);
    debugSetSessionState(UmasSessionState.paired);
  }

  int monitorResetCalls = 0;
  int monitorRegisterCalls = 0;
  int monitorReadAllCalls = 0;
  final List<String> registered = <String>[];

  @override
  Future<void> monitorReset() async => monitorResetCalls++;

  @override
  Future<PlcStatusResult> readPlcStatus() async => PlcStatusResult(
        statusByte: 0,
        numberOfBlocks: 1,
        blockCrcs: const <int>[0xDEADBEEF],
        additionalData: Uint8List(0),
      );

  @override
  Future<List<int>> monitorRegister(
      List<(UmasVariable, UmasDataTypeRef)> refs) async {
    monitorRegisterCalls++;
    for (final r in refs) {
      registered.add(r.$1.name);
    }
    return List<int>.generate(refs.length, (i) => i);
  }

  @override
  Future<List<TypedVariableValue>> monitorReadAll() async {
    monitorReadAllCalls++;
    return List<TypedVariableValue>.generate(
      registered.length,
      (_) => TypedVariableValue(
        value: 22.5,
        typeName: 'REAL',
        rawBytes: Uint8List(4),
      ),
    );
  }
}

/// Put [path] in the client's symbol cache so `lookupSymbol` resolves it
/// without browsing the data dictionary.
void _injectScalar(UmasClient umas, String path, int offset) {
  umas.debugInjectSymbol(ResolvedSymbol(
    path: path,
    variable: UmasVariable(
      name: path.split('.').last,
      blockNo: 0x30,
      offset: offset,
      dataTypeId: 6,
    ),
    dataType: const UmasDataTypeRef(id: 6, name: 'REAL', byteSize: 4),
  ));
}

/// Build an adapter for [pollGroupByKey] / [pollGroups], drive it to the
/// point where the MonitorPlc table is registered and the per-group timers
/// are running, then advance the virtual clock by [window].
///
/// Returns the number of batched `monitorReadAll` round-trips that happened
/// inside [window] — i.e. the total number of poll ticks across all groups.
int _tickCountOver(
  FakeAsync async, {
  required Map<String, String> pollGroupByKey,
  required List<ModbusPollGroupConfig> pollGroups,
  required Duration window,
}) {
  final wrapper = _OfflineWrapper();
  final variableNames = <String, String>{
    for (final key in pollGroupByKey.keys) key: 'Application.GVL.$key',
  };
  final adapter = ModbusDeviceClientAdapter(
    wrapper,
    specs: const {},
    serverAlias: 'plc1',
    variableNames: variableNames,
    umasEnabled: true,
    umasPollGroupByKey: pollGroupByKey,
    pollGroups: pollGroups,
  );
  final umas = _CountingUmasClient();
  var offset = 0;
  for (final path in variableNames.values) {
    _injectScalar(umas, path, offset += 4);
  }
  adapter.debugSetUmasClient(umas);

  try {
    // The first tick finds "table not built for this client identity", kicks
    // the build, and returns. The build ends by starting one Timer.periodic
    // per configured group — which is the machinery under test.
    unawaited(adapter.debugPumpPollTick(pollGroups.first.name));
    async.flushMicrotasks();

    // Sanity: we are on the batched MonitorPlc path, with ONE shared table
    // covering every group's keys. If this ever fails the tick counts below
    // would be measuring the per-key fallback poll instead.
    expect(umas.monitorRegisterCalls, 1,
        reason: 'all groups must share ONE MonitorPlc table');
    expect(umas.registered, hasLength(variableNames.length),
        reason: 'every configured key must be in the shared table');

    final before = umas.monitorReadAllCalls;
    async.elapse(window);
    return umas.monitorReadAllCalls - before;
  } finally {
    adapter.dispose();
  }
}

void main() {
  /// The per-group cadence contract, measured on a virtual clock.
  ///
  /// WHY THIS IS NOT THE STUB-SERVER TEST BELOW: this used to run against the
  /// Python stub, sleep 400ms of real time, count `FC90 subFunc=0x50` lines in
  /// the stub log and assert the total landed in `[8, 25]`. Two things were
  /// wrong with that. First, the stub cannot tell you WHICH group issued a
  /// read — every group sends the identical `monitorReadAll` frame — so the
  /// only thing countable was a combined total, and "slow ticks less often
  /// than fast" had to be inferred from a magic number. Second, the count was
  /// a function of how much CPU the runner felt like giving us: a loaded box
  /// produced fewer ticks and the lower bound went red. It did, on
  /// `tfc-dart-test (windows-latest)` — 6 ticks against a floor of 8 — while
  /// testing a PR that does not touch this package.
  ///
  /// The cadence claim has nothing to do with sockets or wall-clock time: the
  /// poll loop is `Timer.periodic(interval)` per group and nothing else. On a
  /// virtual clock those timers fire an exactly known number of times, so the
  /// counts below are equalities, not bounds, and a slow machine cannot move
  /// them — `FakeAsync.elapse` advances time by fiat, so there is no CPU
  /// budget to lose.
  ///
  /// Per-group attribution comes from running the same window three ways:
  /// fast-only, slow-only, and both-sharing-one-table. The combined total
  /// being exactly the sum of the two singles is what proves each group kept
  /// its own configured cadence while sharing a single MonitorPlc table.
  group('ModbusDeviceClientAdapter per-group poll cadence (B-4)', () {
    // 600ms divides evenly by both cadences, so there is no partial tick to
    // reason about: 600/30 = 20 and 600/200 = 3, exactly.
    const window = Duration(milliseconds: 600);
    const fastMs = 30;
    const slowMs = 200;
    const expectedFastTicks = 600 ~/ fastMs; // 20
    const expectedSlowTicks = 600 ~/ slowMs; // 3

    test('a group ticks exactly window/interval times', () {
      fakeAsync((async) {
        final fastOnly = _tickCountOver(
          async,
          pollGroupByKey: const {'temp_fast': 'fast'},
          pollGroups: [ModbusPollGroupConfig(name: 'fast', intervalMs: fastMs)],
          window: window,
        );
        expect(fastOnly, expectedFastTicks,
            reason: '${window.inMilliseconds}ms at ${fastMs}ms cadence is '
                'exactly $expectedFastTicks ticks');
      });

      fakeAsync((async) {
        final slowOnly = _tickCountOver(
          async,
          pollGroupByKey: const {'press_slow': 'slow'},
          pollGroups: [ModbusPollGroupConfig(name: 'slow', intervalMs: slowMs)],
          window: window,
        );
        expect(slowOnly, expectedSlowTicks,
            reason: '${window.inMilliseconds}ms at ${slowMs}ms cadence is '
                'exactly $expectedSlowTicks ticks');
      });
    });

    test(
        'per-group cadences are honored: a slow group ticks less often '
        'than a fast group even though both share the MonitorPlc table', () {
      fakeAsync((async) {
        final combined = _tickCountOver(
          async,
          pollGroupByKey: const {
            'temp_fast': 'fast',
            'press_slow': 'slow',
          },
          pollGroups: [
            ModbusPollGroupConfig(name: 'fast', intervalMs: fastMs),
            ModbusPollGroupConfig(name: 'slow', intervalMs: slowMs),
          ],
          window: window,
        );

        // The decomposition IS the assertion. Anything other than
        // "fast kept 30ms and slow kept 200ms" lands on a different number:
        // both groups at the fast cadence would be 40, both at the slow
        // cadence 6, a single shared timer 20 or 3.
        expect(combined, expectedFastTicks + expectedSlowTicks,
            reason: 'two groups sharing one MonitorPlc table must each keep '
                'their own cadence: $expectedFastTicks fast ticks + '
                '$expectedSlowTicks slow ticks');

        // And the named property, stated in its own right.
        expect(expectedSlowTicks, lessThan(expectedFastTicks),
            reason: 'the slow group must tick less often than the fast one');
      });
    });
  });

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
      // Generous on purpose: this bounds a Python interpreter cold-start on
      // a contended Windows runner, which is nothing like the ~100ms it takes
      // locally. The timeout exists to turn a hang into a readable failure,
      // not to police how fast the runner is.
      stubPort = await completer.future.timeout(const Duration(seconds: 60));
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
      // Same reasoning as the stub-port wait above: a ceiling that makes a
      // hang legible, not a budget the runner has to hit.
      await ready.future.timeout(const Duration(seconds: 60));
      return wrapper;
    }

    test(
        'subscribe() emits values on the configured poll-group cadence, '
        'not just the BehaviorSubject seed',
        () async {
      final wrapper = await connectedWrapper();
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
        // Wait for the table build to become observable rather than sleeping
        // a guessed 200ms in front of it.
        await waitUntil(
          () => stubLog.any((l) => l.contains('MonitorPlc: registered')),
          what: 'the initial MonitorPlc table build registered its keys',
        );

        final received = <num>[];
        final sub = adapter.subscribe('temperature').listen((dv) {
          if (dv.value is num) received.add(dv.value as num);
        });

        // The claim is "the subject keeps emitting on the poll cadence",
        // i.e. more than the single BehaviorSubject seed. That is a claim
        // about emissions happening at all, not about how many fit inside
        // some window — so wait for the third one to arrive instead of
        // sleeping 350ms and counting whatever the runner managed. A slow
        // box now takes longer to get here; it does not fail.
        await waitUntil(
          () => received.length >= 3,
          what: 'the subject emitted 3 values from the poll loop '
              '(seed + at least two fresh MonitorPlc reads)',
        );
        await sub.cancel();

        // All emissions point at the stub's stored value (22.5).
        expect(received, isNotEmpty);
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
        // Wait for each subject to produce a value rather than sleeping
        // 150ms and asserting isNotEmpty — the assertion below is a count,
        // and a count after a fixed sleep is exactly the shape that goes red
        // on a loaded runner.
        await waitUntil(
          () =>
              tempVals.isNotEmpty && pressVals.isNotEmpty && elevVals.isNotEmpty,
          what: 'all three subscribers received a value from the shared '
              'MonitorPlc table',
        );
        await s1.cancel();
        await s2.cancel();
        await s3.cancel();
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
        // This used to sleep 250ms ("the stub responds immediately so 250ms
        // is more than enough") and then assert `effectiveStatus ==
        // connected`. That was a race between THREE states, not two, and
        // only one of the three is the property this test is named for:
        //
        //   * before pairing starts, `effectiveStatus` falls back to
        //     `_mapTcpStatus(wrapper.connectionStatus)` — and TCP is already
        //     up, so it reads `connected`. The assertion passes having
        //     proven nothing.
        //   * mid-handshake the session is uninitialized/identified, so the
        //     chip reads `umasUnhealthy` and the assertion fails. That is
        //     what `tfc-dart-test (windows-latest)` hit on a PR that does
        //     not touch this package.
        //   * only once the session is `paired` does `connected` actually
        //     mean what the test claims.
        //
        // So wait for the pairing itself to be observable, and assert the
        // chip afterwards. Then `connected` can only be the paired one.

        // The stub must observe the pairing handshake: init (FC90
        // subFunc=0x01) fires unconditionally during `_initWithRetry`.
        // Without the fix no UMAS frames are issued at all, because no
        // by-name read drives the session into init — so this wait, not a
        // sleep, is what pins the regression.
        await waitUntil(
          () => stubLog.any((l) => l.contains('FC90 subFunc=0x01')),
          what: 'eager pairing issued UMAS init (FC90 subFunc=0x01) on TCP '
              'connect even with no UMAS-by-name keys',
        );
        await waitUntil(
          () =>
              adapter.debugUmasClient?.sessionState == UmasSessionState.paired,
          what: 'the eagerly-paired UMAS session reached `paired`',
        );

        // Now the chip's `connected` is derived from a paired session
        // rather than from the TCP fallback.
        expect(
          adapter.effectiveStatus,
          EffectiveDeviceStatus.connected,
          reason: 'a paired UMAS session must render the chip connected; '
              'got ${adapter.effectiveStatus}',
        );
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
        // First pairing. Wait for the session to actually reach `paired`
        // rather than sleeping 250ms at it — and wait on the SESSION, not
        // on `effectiveStatus`, which reads `connected` from the TCP
        // fallback before pairing has even begun (see the test above).
        await waitUntil(
          () =>
              adapter.debugUmasClient?.sessionState == UmasSessionState.paired,
          what: 'the first eager pairing reached `paired`',
        );
        expect(adapter.effectiveStatus, EffectiveDeviceStatus.connected,
            reason: 'a paired session must render the chip connected; '
                'got ${adapter.effectiveStatus}');

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
        //
        // This sleep stays, deliberately. It is a NEGATIVE assertion: the
        // window exists to give a spurious re-init a chance to show up, and
        // a slower runner only makes the assertion easier to satisfy. It can
        // never turn a green into a red, which is what separates it from the
        // count-after-a-sleep assertions elsewhere in this file. There is no
        // observable event to anchor it to either — the adapter never calls
        // `startKeepAlive`, so once pairing settles the socket goes quiet.
        await Future.delayed(const Duration(milliseconds: 200));
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

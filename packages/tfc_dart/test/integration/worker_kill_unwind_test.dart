/// Killing a subscribing acquisition worker must not abort the process.
///
/// ## The crash this file exists because of
///
/// `tfc-dart-test (macos-latest, 1)` on the Relay Pipe branch exited 134 with
/// no test report, inside `pipe_shutdown_test.dart`'s first arm:
///
///     ../../runtime/vm/runtime_entry.cc: error: Cannot invoke native
///     callback while unwind error propagates.
///     isolate=shutdownWorkerEntry
///       … UA_Client_run_iterate → processServiceResponse
///         → backgroundPublish → processPublishResponse → [Dart] → FATAL
///
/// `Isolate.kill(priority: Isolate.immediate)` interrupts the isolate by
/// injecting an unwind error. open62541's Dart binding registers its
/// subscription callbacks as `NativeCallable.isolateLocal`, and the VM will
/// not enter one while an unwind is in flight — it aborts the **process**,
/// main isolate and all. A worker is inside `run_iterate` about half its wall
/// time (`state_man.dart:590`: 10 ms iterate, 10 ms delay), so before the fix
/// this was a coin flip on every shutdown with a live subscription attached.
/// Nothing about it was macOS-specific; macOS is only where it landed first.
///
/// ## What is measured here, and why a source scan is not enough
///
/// `pipe_shutdown_structure_test.dart` pins the two priorities in the source,
/// which is cheap and deterministic — but a string in a file cannot say that
/// the VM survives the kill. This file kills thirty live workers, each with a
/// session and a running subscription, at a random offset inside the pump's
/// 20 ms cycle.
///
/// **It has been shown to bite, and it is NOT the gate.** Both halves of that
/// sentence are measured, and the second one is why this header is long.
///
/// With `Isolate.immediate` alone this file aborted the process on kill cycle
/// 6 of 30, with exactly the stack above — that is where the diagnosis stops
/// being a theory. But three further 30-cycle runs against the same reverted
/// source, on a quieter machine, survived all ninety kills. So the honest
/// figure is roughly **one abort in a hundred kills on this hardware**, and a
/// single green run of this file is worth very little.
///
/// The deterministic gate is therefore the source scan in
/// `pipe_shutdown_structure_test.dart`, which pins both priorities and fails
/// the instant either is dropped. This file is the evidence behind that scan:
/// it is what says the VM actually survives a kill landing inside
/// `run_iterate`, which no string in a file can say. It runs on CI because CI
/// runners are slower and busier than the machine those ninety kills passed
/// on, and the original crash landed there and not here.
///
/// A regression does not fail this test — it kills the process running it, so
/// the reporter never writes its report. That is a lane that goes red with no
/// results, which is exactly what the original CI failure looked like.
/// `print`ing every surviving cycle is how the log names the last kill that
/// worked.
@TestOn('vm')
@Timeout(Duration(minutes: 20))
library;

import 'dart:async';
import 'dart:math';

import 'package:postgres/postgres.dart' show Endpoint;
import 'package:test/test.dart';
import 'package:tfc_dart/core/data_acquisition_isolate.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/pipe_main_endpoint.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../support/free_port.dart';
import '../support/opcua_server_fixture.dart';

class _NoopDatabase implements Database {
  @override
  Future<void> registerRetentionPolicy(String t, RetentionPolicy r) async {}

  @override
  Future<void> insertTimeseriesData(String t, DateTime time, dynamic v) async {}

  @override
  Future<List<TimeseriesData<dynamic>>> queryTimeseriesData(
          String tableName, DateTime to,
          {String? orderBy = 'time ASC', DateTime? from}) async =>
      [];

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

@pragma('vm:entry-point')
Future<void> stressWorkerEntry(DataAcquisitionIsolateConfig config) =>
    runAcquisitionIsolate(config, database: _NoopDatabase());

const String _key = 'stress.counter';
const String _alias = 'PLC-STRESS';

void main() {
  test('killing a subscribing worker thirty times never aborts the VM',
      () async {
    final server =
        await OpcUaServerFixture.start(valueKeys: const <String>[_key]);
    addTearDown(server.dispose);

    var tick = 0;
    final pump = Timer.periodic(const Duration(milliseconds: 20), (_) {
      tick++;
      server.setValue(_key, tick);
    });
    addTearDown(pump.cancel);

    final mappings = KeyMappings(nodes: <String, KeyMappingEntry>{
      _key: KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(namespace: fixtureNamespace, identifier: _key)
          ..serverAlias = _alias,
      ),
    });

    final rng = Random(7);
    for (var i = 0; i < 30; i++) {
      final worker = await spawnWorkerForTest(
        DataAcquisitionIsolateConfig(
          serverJson: (OpcUAConfig()
                ..endpoint = server.endpoint
                ..serverAlias = _alias)
              .toJson(),
          dbConfigJson: DatabaseConfig(
            postgres: Endpoint(
                host: '127.0.0.1', port: await freePort(), database: 'nowhere'),
          ).toJson(),
          keyMappingsJson: mappings.toJson(),
        ),
        '$_alias-$i',
        entryPoint: stressWorkerEntry,
      );
      await worker.ready.timeout(const Duration(seconds: 60),
          onTimeout: () => fail('worker $i never handed back its control port'));

      // Let the worker's OPC UA client get a session and a live subscription
      // up, so the binding's isolate-local callbacks are actually firing when
      // the kill lands.
      final pipe = PipeMainEndpoint();
      pipe.addWorker(AcquisitionWorkerLink(worker), mappings.keys);
      pipe.subscribe(_key);
      final upBy = DateTime.now().add(const Duration(seconds: 30));
      while (pipe.read(_key).value == null) {
        if (DateTime.now().isAfter(upBy)) {
          fail('worker $i never piped a first reading');
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // Land the kill at an arbitrary point inside the pump's 10 ms iterate /
      // 10 ms delay cycle.
      await Future<void>.delayed(Duration(microseconds: rng.nextInt(20000)));
      worker.kill();

      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (worker.isolate != null) {
        if (DateTime.now().isAfter(deadline)) {
          fail('worker $i outlived its kill');
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      // Per cycle, not a tearDown: thirty endpoints all listening to thirty
      // dead workers is thirty leaks the next cycle would have to share a
      // machine with. `dispose()` stops reading the workers and kills nothing
      // (pipe_main_endpoint.dart:799), so it cannot mask the kill above.
      pipe.dispose();
      print('kill cycle $i survived');
    }
  });
}

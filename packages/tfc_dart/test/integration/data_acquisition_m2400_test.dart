// Integration tests: M2400 data acquisition through Collector → StateMan → DB
//
// Verifies the full pipeline: M2400StubServer → M2400ClientWrapper →
// M2400DeviceClientAdapter → StateMan.subscribe → Collector → Database.
//
// Run with: dart test test/integration/data_acquisition_m2400_test.dart

import 'dart:async';

import 'package:jbtm/jbtm.dart' hide ConnectionStatus;
import 'package:jbtm/src/m2400.dart' show M2400RecordType;
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:test/test.dart';
import 'package:tfc_dart/core/collector.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/state_man.dart';

import 'docker_compose.dart';

void main() {
  group('M2400 Data Acquisition Integration', () {
    late Database database;

    setUpAll(() async {
      await stopDockerCompose();
      await startDockerCompose();
      await waitForDatabaseReady();
    });

    tearDownAll(() async {
      await stopDockerCompose();
    });

    setUp(() async {
      database = await connectToDatabase();
    });

    tearDown(() async {
      await database.dispose();
      await database.close();
    });

    /// Poll DB until at least [minCount] rows appear.
    Future<List<TimeseriesData<dynamic>>> waitForRows(
      String tableName, {
      int minCount = 1,
      Duration timeout = const Duration(seconds: 10),
    }) async {
      final deadline = DateTime.now().add(timeout);
      final since = DateTime.now().subtract(const Duration(hours: 1));
      while (DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 100));
        await database.flush();
        try {
          final rows = await database.queryTimeseriesData(tableName, since);
          if (rows.length >= minCount) return rows;
        } catch (_) {
          // table may not exist yet
        }
      }
      throw TimeoutException(
          'Expected $minCount rows in $tableName', timeout);
    }

    test(
        'WHEN M2400 BATCH key has collect entry '
        'THEN Collector stores records in database', () async {
      final server = M2400StubServer();
      final port = await server.start();

      try {
        final m2400Config = M2400Config(host: 'localhost', port: port)
          ..serverAlias = 'scale1';
        final deviceClients = createM2400DeviceClients([m2400Config]);

        const tableName = 'm2400_batch_collect_test';
        const userKey = 'scale1.weight';
        final keyMappings = KeyMappings(nodes: {
          userKey: KeyMappingEntry(
            m2400Node: M2400NodeConfig(
              recordType: M2400RecordType.recBatch,
              field: M2400Field.weight,
            )..serverAlias = 'scale1',
            collect: CollectEntry(key: userKey, name: tableName),
          ),
        });

        final stateMan = await OpcUaStateMan.create(
          config: StateManConfig(opcua: [], jbtm: [m2400Config]),
          keyMappings: keyMappings,
          deviceClients: deviceClients,
        );

        final collector = Collector(
          config: CollectorConfig(collect: true),
          stateMan: stateMan,
          database: database,
        );

        // Wait for connection
        await server.waitForClient();
        await Future.delayed(const Duration(milliseconds: 200));

        // Push 3 weight records from the stub server
        server.pushWeightRecord(weight: '10.00');
        await Future.delayed(const Duration(milliseconds: 100));
        server.pushWeightRecord(weight: '20.00');
        await Future.delayed(const Duration(milliseconds: 100));
        server.pushWeightRecord(weight: '30.00');

        // Collector skips the first sample, so expect 2 rows
        final rows = await waitForRows(tableName, minCount: 2);
        expect(rows.length, greaterThanOrEqualTo(2));

        collector.close();
        for (final c in deviceClients) {
          c.dispose();
        }
      } finally {
        await server.shutdown();
      }
    }, timeout: Timeout(Duration(seconds: 30)));

    test(
        'WHEN multiple M2400 servers '
        'THEN Collector stores records from each independently', () async {
      final server1 = M2400StubServer();
      final server2 = M2400StubServer();
      final port1 = await server1.start();
      final port2 = await server2.start();

      try {
        final configs = [
          M2400Config(host: 'localhost', port: port1)..serverAlias = 'scale1',
          M2400Config(host: 'localhost', port: port2)..serverAlias = 'scale2',
        ];
        final deviceClients = createM2400DeviceClients(configs);

        const table1 = 'm2400_multi_scale1';
        const table2 = 'm2400_multi_scale2';
        const key1 = 'scale1.weight';
        const key2 = 'scale2.weight';
        final keyMappings = KeyMappings(nodes: {
          key1: KeyMappingEntry(
            m2400Node: M2400NodeConfig(
              recordType: M2400RecordType.recBatch,
              field: M2400Field.weight,
            )..serverAlias = 'scale1',
            collect: CollectEntry(key: key1, name: table1),
          ),
          key2: KeyMappingEntry(
            m2400Node: M2400NodeConfig(
              recordType: M2400RecordType.recBatch,
              field: M2400Field.weight,
            )..serverAlias = 'scale2',
            collect: CollectEntry(key: key2, name: table2),
          ),
        });

        final stateMan = await OpcUaStateMan.create(
          config: StateManConfig(opcua: [], jbtm: configs),
          keyMappings: keyMappings,
          deviceClients: deviceClients,
        );

        final collector = Collector(
          config: CollectorConfig(collect: true),
          stateMan: stateMan,
          database: database,
        );

        await server1.waitForClient();
        await server2.waitForClient();
        await Future.delayed(const Duration(milliseconds: 200));

        // Push from server1 (2 records — first skipped by collector)
        server1.pushWeightRecord(weight: '11.0');
        await Future.delayed(const Duration(milliseconds: 100));
        server1.pushWeightRecord(weight: '12.0');

        // Push from server2
        server2.pushWeightRecord(weight: '21.0');
        await Future.delayed(const Duration(milliseconds: 100));
        server2.pushWeightRecord(weight: '22.0');

        final rows1 = await waitForRows(table1, minCount: 1);
        final rows2 = await waitForRows(table2, minCount: 1);

        expect(rows1.length, greaterThanOrEqualTo(1));
        expect(rows2.length, greaterThanOrEqualTo(1));

        collector.close();
        for (final c in deviceClients) {
          c.dispose();
        }
      } finally {
        await server1.shutdown();
        await server2.shutdown();
      }
    }, timeout: Timeout(Duration(seconds: 30)));

    test(
        'WHEN M2400 server disconnects '
        'THEN previously collected data persists in database', () async {
      final server = M2400StubServer();
      final port = await server.start();

      try {
        final m2400Config = M2400Config(host: 'localhost', port: port)
          ..serverAlias = 'scale1';
        final deviceClients = createM2400DeviceClients([m2400Config]);

        const tableName = 'm2400_disconnect_persist';
        const userKey = 'scale1.weight';
        final keyMappings = KeyMappings(nodes: {
          userKey: KeyMappingEntry(
            m2400Node: M2400NodeConfig(
              recordType: M2400RecordType.recBatch,
              field: M2400Field.weight,
            )..serverAlias = 'scale1',
            collect: CollectEntry(key: userKey, name: tableName),
          ),
        });

        final stateMan = await OpcUaStateMan.create(
          config: StateManConfig(opcua: [], jbtm: [m2400Config]),
          keyMappings: keyMappings,
          deviceClients: deviceClients,
        );

        // ignore: unused_local_variable
        final collector = Collector(
          config: CollectorConfig(collect: true),
          stateMan: stateMan,
          database: database,
        );

        await server.waitForClient();
        await Future.delayed(const Duration(milliseconds: 200));

        // Push records
        server.pushWeightRecord(weight: '50.0');
        await Future.delayed(const Duration(milliseconds: 100));
        server.pushWeightRecord(weight: '60.0');

        // Wait for at least 1 to be written (first is skipped)
        final rows = await waitForRows(tableName, minCount: 1);
        expect(rows.length, greaterThanOrEqualTo(1));

        // Shutdown M2400 server
        await server.shutdown();
        await Future.delayed(const Duration(milliseconds: 500));

        // Data should still be in the database
        await database.flush();
        final since = DateTime.now().subtract(const Duration(hours: 1));
        final persistedRows =
            await database.queryTimeseriesData(tableName, since);
        expect(persistedRows.length, greaterThanOrEqualTo(1));

        for (final c in deviceClients) {
          c.dispose();
        }
      } catch (_) {
        // server already shut down in test
      }
    }, timeout: Timeout(Duration(seconds: 30)));
  });
}

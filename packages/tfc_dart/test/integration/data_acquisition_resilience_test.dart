// TDD Tests for Data Acquisition Resilience (Issue #60)
//
// These tests verify that the data acquisition system properly handles:
// 1. Database unavailability at startup
// 2. Database going down during operation
// 3. Isolate crashes and respawn
// 4. Data queuing during outages
//
// Run with: dart test test/integration/data_acquisition_resilience_test.dart

import 'dart:async';
import 'dart:isolate';

import 'package:open62541/open62541.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/collector.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/state_man.dart';

import 'docker_compose.dart';
import 'eventually.dart';

void main() {
  group('Data Acquisition Resilience', () {
    setUpAll(() async {
      // Start TimescaleDB
      await stopDockerCompose();
      await startDockerCompose();
      await waitForDatabaseReady();
    });

    tearDownAll(() async {
      await stopDockerCompose();
    });

    group('Database retry queue', () {
      late Database database;

      setUp(() async {
        database = await connectToDatabase();
      });
      tearDown(() async {
        await database.dispose();
        await database.close();
      });
      test(
          'WHEN database is down THEN inserts are queued and flushed on recovery',
          () async {
        // Arrange
        const tableName = 'resilience_test_1';
        final stateMan = await OpcUaStateMan.create(
          config: StateManConfig(opcua: []),
          keyMappings: KeyMappings(nodes: {}),
        );
        final collector = Collector(
          config: CollectorConfig(collect: true),
          stateMan: stateMan,
          database: database,
        );

        final streamController = StreamController<DynamicValue>();
        final entry = CollectEntry(key: tableName, name: tableName);

        // Start collecting
        await collector.collectEntryImpl(entry, streamController.stream,
            skipFirstSample: false);

        // Insert one value while DB is up (creates table)
        streamController.add(DynamicValue(value: 'before'));
        await Future.delayed(const Duration(milliseconds: 200));
        await database.flush();

        // Verify initial insert
        var data = await _queryTable(database, tableName);
        expect(data.length, 1);

        // Stop database
        await stopTimescaleDb();
        await Future.delayed(const Duration(seconds: 1));

        // Insert values during outage - should be queued
        for (var i = 0; i < 5; i++) {
          streamController.add(DynamicValue(value: 'during_$i'));
          await Future.delayed(const Duration(milliseconds: 50));
        }

        // Restart database
        await startTimescaleDb();
        await waitForDatabaseReady();

        // Wait for retry queue to flush
        await Future.delayed(const Duration(seconds: 8));
        await database.flush();

        // Verify all data was inserted
        data = await _queryTable(database, tableName);
        expect(data.length, 6, reason: 'Should have 1 + 5 items');

        // Cleanup
        streamController.close();
        collector.close();

        // Ensure DB is back up for next test
        await startTimescaleDb();
        await waitForDatabaseReady();
      }, timeout: Timeout(Duration(seconds: 60)));

      test('WHEN the DB is down for a burst THEN nothing is lost',
          () async {
        // Exercise the full production path: Collector → DynamicValue →
        // stream listener → unawaited insertTimeseriesData → auto-flush →
        // retry queue overflow.  With maxRetries: 1 on auto-flush, failed
        // flushes complete instantly (one attempt, no backoff delay).
        const tableName = 'resilience_test_2';
        final stateMan = await OpcUaStateMan.create(
          config: StateManConfig(opcua: []),
          keyMappings: KeyMappings(nodes: {}),
        );
        final collector = Collector(
          config: CollectorConfig(collect: true),
          stateMan: stateMan,
          database: database,
        );

        final streamController = StreamController<DynamicValue>();
        final entry = CollectEntry(key: tableName, name: tableName);

        // collectEntryImpl registers a retention policy and sets up stream
        // listener that fires unawaited inserts into the Database.
        await collector.collectEntryImpl(entry, streamController.stream,
            skipFirstSample: false);

        // Insert one value while DB is up (creates table).
        //
        // The collector's listener fires an *unawaited* insert, so there is
        // no future to await between adding to the stream and the row being
        // buffered. A fixed 200 ms here is what made this test fail on CI
        // one row short: flush() flushed an empty buffer because the listener
        // had not run yet, and the query then found nothing.
        streamController.add(DynamicValue(value: 'init'));
        var data = await eventually(
          () async {
            await database.flush();
            return _queryTable(database, tableName);
          },
          hasLength(1),
          reason: 'the seed row must land before the DB is stopped — '
              'everything after this depends on the table existing',
        );
        expect(data.length, 1);

        // Stop database — keep it down for the entire insert phase.
        await stopTimescaleDb();
        await Future.delayed(const Duration(seconds: 5));

        // 120 items during a total outage. This used to be MORE than the
        // queue could hold: the cap was 100 per table, so 20 items were
        // discarded oldest-first and this test asserted that they were.
        //
        // The cap is now kMaxQueuedRowsPerTable (10 000), so the whole burst
        // survives and the assertion below is the opposite of what it was.
        // That is the point of the change, not an accommodation to it: a
        // thirty-second outage losing the first two thirds of a tag's samples
        // was the defect.
        //
        // The trimming policy itself -- oldest-first within a table, fullest
        // queue first across tables, and the counters that record it -- is
        // covered in packages/tfc_dart/test/core/database_write_queue_test.dart,
        // which injects small caps so it can exercise the real code without a
        // database. Making a pure in-memory list-trimming policy require Docker
        // was never a good trade.
        const totalItems = 120;
        for (var i = 0; i < totalItems; i++) {
          streamController.add(DynamicValue(value: 'item_$i'));
        }

        // Wait for ALL pool queries to fail and complete the retry cycle:
        //   - Auto/periodic flushes fail within queryTimeout (5s)
        //   - Items enter retry queue, retry scheduled after 5s delay
        //   - Retry flush fires, fails within queryTimeout (5s)
        //   - Items re-queued, next retry scheduled after 5s delay
        // Total: queryTimeout + retryDelay + queryTimeout + margin = 16s
        // During the next 5s retry delay window, no pool queries are active
        // so it's safe to restart the proxy.
        await Future.delayed(const Duration(seconds: 16));

        // Flush any remaining buffer while DB is still down
        await database.flush();

        // NOW restart database — all items are safely in the retry queue,
        // no pool queries are in-flight to bridge the restart.
        await startTimescaleDb();
        await waitForDatabaseReady();

        // Wait for retry queue to flush (5 s retry delay + queryTimeout)
        await Future.delayed(const Duration(seconds: 12));
        await database.flush();

        // Verify: 1 init + all 120 items = 121, none discarded.
        data = await _queryTable(database, tableName);
        expect(data.length, totalItems + 1);

        final values = data.map((d) => d.value as String).toSet();
        for (var i = 0; i < totalItems; i++) {
          expect(values.contains('item_$i'), isTrue,
              reason: 'item_$i was produced during the outage and should have '
                  'survived it. The start of an outage is exactly the part '
                  'that used to be thrown away.');
        }

        // And the counters agree, against a real server: the drop counter is
        // the instrument an operator would check, so it has to be right when
        // nothing was lost, not only when something was.
        final stats = database.getStats();
        expect(stats['dropped_rows'], 0);
        expect(stats['poisoned_rows'], 0);

        // Cleanup
        streamController.close();
        collector.close();

        // Ensure DB is back up for next test
        await startTimescaleDb();
        await waitForDatabaseReady();
      }, timeout: Timeout(Duration(seconds: 90)));
    });

    group('Isolate startup retry', () {
      test('WHEN DB is down at startup THEN isolate retries until DB is up',
          () async {
        // Stop DB and wait for all connections to be truly dead
        await stopTimescaleDb();
        await Future.delayed(const Duration(seconds: 3));

        final messagePort = ReceivePort();
        final timestamps = <String>[];

        messagePort.listen((msg) {
          if (msg == 'initialized') {
            timestamps.add(DateTime.now().toIso8601String());
          }
        });

        // Spawn isolate - it should retry connecting to DB
        final errorPort = ReceivePort();
        final exitPort = ReceivePort();

        await Isolate.spawn(
          _isolateWithDbRetry,
          _IsolateConfig(
            dbConfigJson: getTestConfig().toJson(),
            sendPort: messagePort.sendPort,
          ),
          onError: errorPort.sendPort,
          onExit: exitPort.sendPort,
        );

        // Wait 2 seconds - isolate should NOT have connected yet (retry delay is 2s)
        await Future.delayed(const Duration(seconds: 2));
        final beforeDbStart = timestamps.length;

        // Start DB
        await startTimescaleDb();
        await waitForDatabaseReady();

        // Wait for isolate to connect
        await Future.delayed(const Duration(seconds: 8));
        final afterDbStart = timestamps.length;

        // Isolate should have connected AFTER we started the DB
        expect(afterDbStart, greaterThan(beforeDbStart),
            reason: 'Isolate should connect after DB starts');

        // Cleanup
        messagePort.close();
        errorPort.close();
        exitPort.close();
      }, timeout: Timeout(Duration(seconds: 60)));
    });

    group('Database edge cases', () {
      late Database database;

      setUp(() async {
        database = await connectToDatabase();
      });
      tearDown(() async {
        try {
          await database.dispose();
          await database.close();
        } catch (_) {
          // Database may already be disposed/closed by the test
        }
      });

      test('WHEN dispose is called THEN pending data is flushed', () async {
        const tableName = 'dispose_flush_test';
        final stateMan = await OpcUaStateMan.create(
          config: StateManConfig(opcua: []),
          keyMappings: KeyMappings(nodes: {}),
        );
        final collector = Collector(
          config: CollectorConfig(collect: true),
          stateMan: stateMan,
          database: database,
        );

        final streamController = StreamController<DynamicValue>();
        final entry = CollectEntry(key: tableName, name: tableName);

        await collector.collectEntryImpl(entry, streamController.stream,
            skipFirstSample: false);

        // Insert values (will be buffered, not flushed yet).
        for (var i = 0; i < 3; i++) {
          streamController.add(DynamicValue(value: 'item_$i'));
        }

        // Wait for all three to reach the write buffer before disposing.
        //
        // This is the whole test: dispose() must flush what is *pending*, so
        // the three rows have to be pending before it is called. Sleeping
        // 50 ms per item did not guarantee that — the inserts are unawaited,
        // and on a loaded runner the third had not been buffered yet, so
        // dispose flushed two and the test failed asserting three. Waiting on
        // the buffer depth asks the question the test actually means.
        await eventually(
          () => database.queuedRowCount,
          greaterThanOrEqualTo(3),
          reason: 'all three rows must be pending before dispose() is called, '
              'or this asserts on a flush that had nothing to lose',
        );

        // Don't call flush - just dispose
        await database.dispose();

        // Reconnect and verify data was flushed
        final db2 = await connectToDatabase();
        final data = await _queryTable(db2, tableName);
        expect(data.length, 3, reason: 'dispose() should flush pending data');

        streamController.close();
        collector.close();
      }, timeout: Timeout(Duration(seconds: 30)));

      test('WHEN DB is down THEN registerRetentionPolicy does not throw',
          () async {
        await stopTimescaleDb();
        await Future.delayed(const Duration(seconds: 2));

        // This should NOT throw
        await database.registerRetentionPolicy(
          'nonexistent_table',
          const RetentionPolicy(
              dropAfter: Duration(days: 30), scheduleInterval: null),
        );

        // Restart DB for next tests
        await startTimescaleDb();
        await waitForDatabaseReady();
      }, timeout: Timeout(Duration(seconds: 30)));

      test(
          'WHEN retention policy registered during outage THEN applied when table created',
          () async {
        const tableName = 'retention_recovery_test';

        // Stop DB
        await stopTimescaleDb();
        await Future.delayed(const Duration(seconds: 2));

        // Register retention policy while DB is down (should not throw)
        await database.registerRetentionPolicy(
          tableName,
          const RetentionPolicy(
              dropAfter: Duration(days: 7), scheduleInterval: null),
        );

        // Start DB
        await startTimescaleDb();
        await waitForDatabaseReady();

        // Insert data - this should create table WITH the retention policy
        await database.insertTimeseriesData(
            tableName, DateTime.now().toUtc(), 'test_value');
        await database.flush();

        // Verify table was created
        final data = await _queryTable(database, tableName);
        expect(data.length, 1, reason: 'Table should be created with data');
      }, timeout: Timeout(Duration(seconds: 30)));
    });

    group('Isolate respawn on crash', () {
      test('WHEN isolate crashes THEN it is respawned automatically', () async {
        // Ensure DB is up for this test
        await startTimescaleDb();
        await waitForDatabaseReady();
        var spawnCount = 0;
        final spawnPort = ReceivePort();

        spawnPort.listen((msg) {
          if (msg == 'spawned') spawnCount++;
        });

        // Spawn with respawn wrapper
        _spawnWithRespawn(
          dbConfigJson: getTestConfig().toJson(),
          spawnPort: spawnPort.sendPort,
          shouldCrash: true,
        );

        // Wait for crash + respawn cycle
        await Future.delayed(const Duration(seconds: 10));

        expect(spawnCount, greaterThanOrEqualTo(2),
            reason: 'Should have respawned after crash');

        spawnPort.close();
      }, timeout: Timeout(Duration(seconds: 30)));
    });

  });
}

Future<List<TimeseriesData<dynamic>>> _queryTable(
    Database db, String tableName) async {
  try {
    return await db.queryTimeseriesData(
        tableName, DateTime.now().subtract(const Duration(hours: 1)));
  } catch (e) {
    return [];
  }
}


class _IsolateConfig {
  final Map<String, dynamic> dbConfigJson;
  final SendPort sendPort;
  final bool shouldCrash;

  _IsolateConfig({
    required this.dbConfigJson,
    required this.sendPort,
    this.shouldCrash = false,
  });
}

@pragma('vm:entry-point')
Future<void> _isolateWithDbRetry(_IsolateConfig config) async {
  final dbConfig = DatabaseConfig.fromJson(config.dbConfigJson);

  var delay = const Duration(seconds: 2);
  const maxDelay = Duration(seconds: 30);
  const maxAttempts = 15;

  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      final appDb = await AppDatabase.create(dbConfig);
      // Force actual connection by running a query
      await appDb.tableExists('_connection_test');

      // ignore: unused_local_variable
      final db = Database(appDb);
      config.sendPort.send('initialized');

      // Crash OUTSIDE try-catch to actually terminate the isolate
      if (config.shouldCrash) {
        await Future.delayed(const Duration(milliseconds: 100));
        break; // Exit loop, crash below
      }

      await Completer<void>().future;
      return;
    } catch (e) {
      if (attempt == maxAttempts) rethrow;
      await Future.delayed(delay);
      delay = delay * 2;
      if (delay > maxDelay) delay = maxDelay;
    }
  }

  // Intentional crash outside try-catch
  if (config.shouldCrash) {
    throw Exception('Intentional crash for testing respawn');
  }
}

Future<void> _spawnWithRespawn({
  required Map<String, dynamic> dbConfigJson,
  required SendPort spawnPort,
  bool shouldCrash = false,
}) async {
  var restartDelay = const Duration(seconds: 2);
  const maxDelay = Duration(seconds: 30);

  Future<void> spawn() async {
    final errorPort = ReceivePort();
    final exitPort = ReceivePort();

    void scheduleRespawn() {
      errorPort.close();
      exitPort.close();
      Future.delayed(restartDelay, () {
        restartDelay = restartDelay * 2;
        if (restartDelay > maxDelay) restartDelay = maxDelay;
        spawn();
      });
    }

    errorPort.listen((_) => scheduleRespawn());
    exitPort.listen((_) => scheduleRespawn());

    spawnPort.send('spawned');

    await Isolate.spawn(
      _isolateWithDbRetry,
      _IsolateConfig(
        dbConfigJson: dbConfigJson,
        sendPort: ReceivePort().sendPort,
        shouldCrash: shouldCrash,
      ),
      onError: errorPort.sendPort,
      onExit: exitPort.sendPort,
    );

    restartDelay = const Duration(seconds: 2);
  }

  await spawn();
}

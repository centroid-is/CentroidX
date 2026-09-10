import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:test/test.dart';
import 'package:postgres/postgres.dart';
import 'package:tfc_dart/core/alarm.dart' show alarmHistoryOverlaps;
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/database_notification.dart'
    show kNotificationWatchdogInterval;
import 'docker_compose.dart';
import 'eventually.dart';

// To poke at the database of a running suite, find its container first -- the
// name is per-run now (`tfcdart-it-<pid>-timescaledb-1`), not the fixed
// `test-db` it used to be, so that two copies of this lane can run at once:
//
//   docker ps --filter name=tfcdart-it
//   docker exec -it <name> /bin/ash -c \
//     "psql -d testdb --user testuser -c 'select * from test_timeseries;'"

/// One line per row, for the `reason:` of a row-count expectation.
///
/// A bare `Expected: <3> Actual: <4>` on CI says nothing about which row is
/// the extra one, and the runner is gone by the time anyone looks.
String _describe(List<QueryRow> rows) =>
    rows.map((r) => r.data).join('\n  ');

/// Polls [condition] every 50 ms until it returns true or [timeout] elapses.
/// Throws [TimeoutException] if the condition is not met in time.
Future<void> waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException(
          'Condition not met within ${timeout.inSeconds}s', timeout);
    }
    await Future.delayed(const Duration(milliseconds: 50));
  }
}

/// Subscribes to [channelName] and returns only after the PostgreSQL LISTEN
/// is confirmed active.
///
/// Because [AppDatabase.listenToChannel] establishes the connection
/// asynchronously in its onListen callback, there is no reliable moment when
/// the LISTEN is live from the outside. This helper sends pg_notify pings via
/// the main connection and waits for one to echo back through the notification
/// connection, which proves LISTEN is active. All non-ping payloads are
/// forwarded to [onData].
Future<StreamSubscription<String>> subscribeWhenReady(
  AppDatabase db,
  String channelName,
  void Function(String) onData, {
  Duration timeout = const Duration(seconds: 5),
  void Function()? onDone,
}) async {
  final readyCompleter = Completer<void>();
  const pingPayload = '__ping__';

  final sub = db.listenToChannel(channelName).listen((payload) {
    if (payload == pingPayload) {
      if (!readyCompleter.isCompleted) readyCompleter.complete();
    } else {
      onData(payload);
    }
  }, onDone: onDone);

  final deadline = DateTime.now().add(timeout);
  while (!readyCompleter.isCompleted) {
    if (DateTime.now().isAfter(deadline)) {
      await sub.cancel();
      throw TimeoutException(
          'Channel $channelName not ready within ${timeout.inSeconds}s',
          timeout);
    }
    // Fire a ping via the main connection; once it echoes back we know
    // the LISTEN subscription is active.
    await db
        .customSelect("SELECT pg_notify('$channelName', '$pingPayload')")
        .get();
    await Future.delayed(const Duration(milliseconds: 50));
  }

  return sub;
}

void main() {
  group('Database Integration Tests', () {
    late Database database;

    // Test table names
    const testTableName = 'test_timeseries';
    const testTableName2 = 'test_timeseries_2';

    setUpAll(() async {
      await stopDockerCompose();
      await startDockerCompose();
      await waitForDatabaseReady(); // More reliable than a fixed delay
      database = await connectToDatabase();
      // Verify connection
      expect(await database.db.isOpen, true);
    });

    setUp(() async {
      // Start every test from tables that do not exist.
      //
      // The tearDown below already drops them, but it is best-effort: it
      // swallows every error and gives the DROP five seconds. When that
      // silently fails the next test inherits the last one's rows, and the
      // assertions go wrong in ways that read like logic bugs — CI has failed
      // here expecting min=8.0 and getting 42.0, a value written by a
      // different test in the same group.
      //
      // Flush *before* dropping, and the order matters. The write buffer is
      // shared by every test in this file, so a row still sitting in it when
      // the table is dropped is not discarded — it is written into whatever
      // table exists when the buffer next drains, which is the next test's
      // freshly recreated one. Flushing first sends those stragglers to the
      // table that is about to be destroyed, where they belong.
      try {
        await database.flush().timeout(const Duration(seconds: 10));
      } catch (_) {/* a failed flush must not fail the test that follows */}
      for (final t in [testTableName, testTableName2]) {
        try {
          await database.db
              .customStatement('DROP TABLE IF EXISTS "$t" CASCADE')
              .timeout(const Duration(seconds: 10));
        } catch (_) {/* the test recreates what it needs */}
      }
    });

    tearDown(() async {
      // Flush any pending writes before dropping tables
      try {
        await database.flush();
      } catch (_) {}
      // Clean up test tables
      try {
        // Remove retention policies first
        await database.db
            .customStatement('DROP TABLE IF EXISTS $testTableName CASCADE')
            .timeout(const Duration(seconds: 5));
        await database.db
            .customStatement('DROP TABLE IF EXISTS $testTableName2 CASCADE')
            .timeout(const Duration(seconds: 5));
      } catch (e) {
        // Ignore cleanup errors
      }
    });

    tearDownAll(() async {
      await database.close();
      await stopDockerCompose();
    });

    group('Connection Tests', () {
      test('should connect to PostgreSQL database', () async {
        expect(await database.db.isOpen, true);

        // Test basic query
        final result =
            await database.db.customSelect('SELECT 1 as test_value').get();
        expect(result[0].read<int>('test_value'), 1);
      });

      test('should handle connection errors gracefully', () async {
        final badConfig = DatabaseConfig(
          postgres: Endpoint(
            host: 'invalid-host',
            port: 5432,
            database: 'testdb',
            username: 'testuser',
            password: 'testpass',
          ),
        );

        final badDatabase = Database(await AppDatabase.spawn(badConfig));

        expect(
          () async => await badDatabase.open(),
          throwsA(isA<DatabaseException>()),
        );
      });
    });

    group('Table Operations', () {
      test('should check if table exists', () async {
        // Table should not exist initially
        expect(await database.db.tableExists(testTableName), false);

        // Create table
        await database.db.customStatement('''
          CREATE TABLE "$testTableName" (
            id SERIAL PRIMARY KEY,
            name TEXT NOT NULL
          )
        ''');

        // Table should exist now
        expect(await database.db.tableExists(testTableName), true);

        // Clean up
        await database.db.customStatement('DROP TABLE "$testTableName"');
      });

      test('should handle table operations with special characters', () async {
        const specialTableName = 'test-table_with.special_chars';

        expect(await database.db.tableExists(specialTableName), false);

        await database.db.customStatement('''
          CREATE TABLE "$specialTableName" (
            id SERIAL PRIMARY KEY
          )
        ''');

        expect(await database.db.tableExists(specialTableName), true);

        await database.db.customStatement('DROP TABLE "$specialTableName"');
      });
    });

    group('TimescaleDB Integration', () {
      test('should create timeseries table with retention policy', () async {
        const retention = Duration(minutes: 5);

        await database.registerRetentionPolicy(
            testTableName, const RetentionPolicy(dropAfter: retention));
        await database.insertTimeseriesData(
            testTableName, DateTime.now(), 42); // This should create the table

        // Verify table exists
        expect(await database.db.tableExists(testTableName), true);

        // Verify it's a hypertable (TimescaleDB specific)
        final hypertableResult = await database.db.customSelect(r'''
          SELECT EXISTS (
            SELECT FROM timescaledb_information.hypertables 
            WHERE hypertable_name = $1
          )
        ''', variables: [Variable.withString(testTableName)]).get();

        expect(hypertableResult[0].read<bool>('exists'), true);

        // Verify retention policy
        final retentionResult = await database.db.customSelect(r'''
          SELECT EXISTS (
            SELECT FROM timescaledb_information.jobs 
            WHERE hypertable_name = $1 
            AND proc_name = 'policy_retention'
          )
        ''', variables: [Variable.withString(testTableName)]).get();

        expect(retentionResult[0].read<bool>('exists'), true);
      });

      test('should handle updating retention policy gracefully', () async {
        var retention = const RetentionPolicy(
            dropAfter: Duration(minutes: 10),
            scheduleInterval: Duration(minutes: 1));

        // Create table twice - should not fail
        await database.registerRetentionPolicy(testTableName, retention);
        await database.insertTimeseriesData(
            testTableName, DateTime.now(), 42); // This should create the table

        expect(await database.db.getRetentionPolicy(testTableName), retention);

        retention = const RetentionPolicy(
            dropAfter: Duration(minutes: 30),
            scheduleInterval: Duration(minutes: 15));

        await database.registerRetentionPolicy(testTableName, retention);

        expect(await database.db.getRetentionPolicy(testTableName), retention);
      });
    });

    group('Timeseries Data Operations', () {
      setUp(() async {
        // Create test table before each test
        await database.registerRetentionPolicy(testTableName,
            const RetentionPolicy(dropAfter: Duration(hours: 1)));
      });

      tearDown(() async {
        // Flush any pending writes before dropping table
        await database.flush();
        // Clean up after each test
        await database.db
            .customStatement('DROP TABLE IF EXISTS "$testTableName" CASCADE');
      });

      test('should insert int data', () async {
        final now = DateTime.now();
        const testData = 42;

        await database.insertTimeseriesData(testTableName, now, testData);
        await database.flush(); // Flush buffer to write data immediately

        final result = await database.queryTimeseriesData(
            testTableName, now.subtract(const Duration(days: 1)));
        expect(result.length, 1);
        expect(result[0].value, testData);
      });

      test('should insert double data', () async {
        final now = DateTime.now();
        const testData = 24.5;

        await database.insertTimeseriesData(testTableName, now, testData);
        await database.flush();

        final result = await database.queryTimeseriesData(
            testTableName, now.subtract(const Duration(days: 1)));
        expect(result.length, 1);
        expect(result[0].value, testData);
      });

      test('should insert array of doubles data', () async {
        final now = DateTime.now();
        const testData = [24.5, 10.2, 99.9, 3.14159];

        await database.insertTimeseriesData(testTableName, now, testData);
        await database.flush();

        final result = await database.queryTimeseriesData(
            testTableName, now.subtract(const Duration(days: 1)));
        expect(result.length, 1);
        expect(result[0].value, testData);
      });

      test('should insert boolean data', () async {
        final now = DateTime.now();
        const testData = true;

        await database.insertTimeseriesData(testTableName, now, testData);
        await database.flush();

        final result = await database.queryTimeseriesData(
            testTableName, now.subtract(const Duration(days: 1)));
        expect(result.length, 1);
        expect(result[0].value, testData);
      });

      test('should insert string data', () async {
        final now = DateTime.now();
        const testData = "test_value";

        await database.insertTimeseriesData(testTableName, now, testData);
        await database.flush();

        final result = await database.queryTimeseriesData(
            testTableName, now.subtract(const Duration(days: 1)));
        expect(result.length, 1);
        expect(result[0].value, testData);
      });

      test('should insert timeseries data', () async {
        final now = DateTime.now();
        final testData = {'value': 42, 'unit': 'celsius'};

        await database.insertTimeseriesData(testTableName, now, testData);
        await database.flush();

        // Verify data was inserted
        final result = await database.queryTimeseriesData(
            testTableName, now.subtract(const Duration(days: 1)));
        expect(result.length, 1);
        expect(result[0].time, isA<DateTime>());
        expect(result[0].value, testData);
      });

      test('insert different types of data results in error', () async {
        final now = DateTime.now();
        const testData = true;
        const testData2 = 42;

        await database.insertTimeseriesData(testTableName, now, testData);
        await database.flush();

        // With buffering, insertTimeseriesData doesn't throw immediately.
        // The error occurs during flush when the type mismatch is detected by PostgreSQL.
        await database.insertTimeseriesData(testTableName, now, testData2);

        // The flush will fail due to type mismatch, but it logs the error and continues
        await database.flush();

        // Verify only the first data point was inserted (second was rejected)
        final result = await database.queryTimeseriesData(
            testTableName, now.subtract(const Duration(days: 1)));
        expect(result.length, 1);
        expect(result[0].time, isA<DateTime>());
        expect(result[0].value, testData);
      });

      test('insert couple of strings', () async {
        final now = DateTime.now();
        const testData = "test_value";
        const testData2 = true;
        const testData3 = 42;

        // Use distinct timestamps so ORDER BY time ASC is deterministic.
        await database.insertTimeseriesData(testTableName, now, testData);
        await database.insertTimeseriesData(
            testTableName, now.add(const Duration(milliseconds: 1)), testData2);
        await database.insertTimeseriesData(
            testTableName, now.add(const Duration(milliseconds: 2)), testData3);
        await database.flush();

        final result = await database.queryTimeseriesData(
            testTableName, now.subtract(const Duration(days: 1)));
        expect(result.length, 3);
        // All values are cast to TEXT when inserted into a TEXT column.
        final values = result.map((r) => r.value as String).toList();
        expect(values, containsAll([testData, testData2.toString(), testData3.toString()]));
      });

      test('should insert multiple data points', () async {
        final baseTime = DateTime.now();
        final dataPoints = [
          {'value': 10, 'unit': 'celsius'},
          {'value': 20, 'unit': 'celsius'},
          {'value': 30, 'unit': 'celsius'},
        ];

        for (int i = 0; i < dataPoints.length; i++) {
          await database.insertTimeseriesData(
            testTableName,
            baseTime.add(Duration(minutes: i)),
            dataPoints[i],
          );
        }
        await database.flush();

        final result = await database.queryTimeseriesData(
            testTableName, baseTime.subtract(const Duration(days: 1)));
        expect(result.length, 3);

        // Verify data is in correct order
        for (int i = 0; i < result.length; i++) {
          expect(result[i].value, dataPoints[i]);
        }
      });

      test('should query data with since parameter', () async {
        final baseTime = DateTime.now();
        final oldData = {'value': 10, 'unit': 'celsius'};
        final newData = {'value': 20, 'unit': 'celsius'};

        // Insert old data
        await database.insertTimeseriesData(
          testTableName,
          baseTime.subtract(Duration(hours: 2)),
          oldData,
        );

        // Insert new data
        await database.insertTimeseriesData(
          testTableName,
          baseTime,
          newData,
        );
        await database.flush();

        // Query only recent data
        final result = await database.queryTimeseriesData(
          testTableName,
          baseTime.subtract(Duration(hours: 1)),
        );

        expect(result.length, 1);
        expect(result[0].value, newData);
      });

      test('should query data with custom order', () async {
        final baseTime = DateTime.now();
        final dataPoints = [
          {'value': 10, 'unit': 'celsius'},
          {'value': 20, 'unit': 'celsius'},
          {'value': 30, 'unit': 'celsius'},
        ];

        for (int i = 0; i < dataPoints.length; i++) {
          await database.insertTimeseriesData(
            testTableName,
            baseTime.add(Duration(minutes: i)),
            dataPoints[i],
          );
        }
        await database.flush();

        // Query in descending order
        final result = await database.queryTimeseriesData(
          testTableName,
          baseTime.subtract(const Duration(days: 1)),
          orderBy: 'time DESC',
        );

        expect(result.length, 3);
        expect(result[0].value, dataPoints[2]); // Most recent first
        expect(result[2].value, dataPoints[0]); // Oldest last
      });

      test('should handle complex JSON data', () async {
        final now = DateTime.now();
        final complexData = {
          'sensor_id': 'temp_001',
          'readings': {
            'temperature': 25.5,
            'humidity': 60.2,
            'pressure': 1013.25,
          },
          'metadata': {
            'location': 'room_a',
            'calibration_date': '2024-01-01',
            'active': true,
          },
          'alerts': ['high_temp', 'low_humidity'],
        };

        await database.insertTimeseriesData(testTableName, now, complexData);

        final result = await database.queryTimeseriesData(
            testTableName, now.subtract(const Duration(days: 1)));
        expect(result.length, 1);
        expect(result[0].value, complexData);
      }, skip: "Todo: fix Drift to handle JSON data in postgres");

      test('should handle null values in JSON data', () async {
        final now = DateTime.now();
        final dataWithNulls = {
          'value': 42,
          'description': null,
          'tags': ['tag1', null, 'tag3'],
        };

        await database.insertTimeseriesData(testTableName, now, dataWithNulls);

        final result = await database.queryTimeseriesData(
            testTableName, now.subtract(const Duration(days: 1)));
        expect(result.length, 1);
        expect(result[0].value, {
          'value': 42,
          'description': null,
          'tags': [
            '"tag1"',
            'null',
            '"tag3"'
          ], // not sure it needs to be quoted but lets continue
        });
      }, skip: "Todo: fix Drift to handle JSON data in postgres");

      test('should count timeseries data in regular time intervals', () async {
        final baseTime = DateTime.now();

        // Insert data at different times
        await database.insertTimeseriesData(testTableName,
            baseTime.subtract(const Duration(hours: 3, minutes: 30)), 1);
        await database.insertTimeseriesData(testTableName,
            baseTime.subtract(const Duration(hours: 2, minutes: 30)), 2);
        await database.insertTimeseriesData(testTableName,
            baseTime.subtract(const Duration(hours: 1, minutes: 30)), 3);
        await database.insertTimeseriesData(
            testTableName, baseTime.subtract(const Duration(minutes: 30)), 4);
        await database.flush();

        // Count in 1-hour intervals for the last 4 hours from baseTime
        final counts = await database.countTimeseriesDataMultiple(
          testTableName,
          const Duration(hours: 1),
          6,
          since: baseTime,
        );

        // Extract just the count values from the map, maintaining order
        final countValues = counts.values.toList();

        // Should return [0, 0, 1, 1] - counts from oldest to newest bucket
        // Bucket 0 (3-4 hours ago): 0 records (no data in this range)
        // Bucket 1 (2-3 hours ago): 0 records (no data in this range)
        // Bucket 2 (1-2 hours ago): 1 record
        // Bucket 3 (0-1 hours ago): 1 record
        expect(countValues, [0, 0, 1, 1, 1, 1]);

        // Test with a different end time
        final pastTime = baseTime.subtract(const Duration(hours: 1));
        final countsFromPast = await database.countTimeseriesDataMultiple(
          testTableName,
          const Duration(hours: 1),
          2,
          since: pastTime,
        );

        // Extract count values
        final pastCountValues = countsFromPast.values.toList();

        // Should return [0, 1] - counts from 2-3 hours ago and 1-2 hours ago
        expect(pastCountValues, [1, 1]);
      });
    });

    group('Downsampled Query', () {
      setUp(() async {
        await database.registerRetentionPolicy(testTableName,
            const RetentionPolicy(dropAfter: Duration(hours: 2)));
      });

      tearDown(() async {
        await database.flush();
        await database.db
            .customStatement('DROP TABLE IF EXISTS "$testTableName" CASCADE');
      });

      test('should downsample 100 points to ~30 using time_bucket', () async {
        final baseTime = DateTime.now().subtract(const Duration(minutes: 60));

        // Insert 100 points over 60 minutes (~36s apart)
        for (int i = 0; i < 100; i++) {
          final t = baseTime.add(Duration(seconds: i * 36));
          await database.insertTimeseriesData(
              testTableName, t, (i % 20).toDouble());
        }
        await database.flush();

        final from = baseTime.subtract(const Duration(seconds: 1));
        final to = baseTime.add(const Duration(minutes: 61));

        // Request maxPoints=30 → 10 buckets × 3 points = 30
        final result = await database.queryTimeseriesDataDownsampled(
            testTableName, from, to,
            maxPoints: 30);

        // Should get at most 30 points (10 buckets * 3), not 100.
        //
        // This used to allow 33 as a "small tolerance". The tolerance was the
        // defect: buckets were aligned to time_bucket's own origin rather
        // than to the window, so a window that did not begin on a boundary
        // spanned one bucket more than it was sized for and every chart could
        // be handed maxPoints + 3. 13-12 made the bound real; see
        // test/integration/database_downsample_bound_test.dart.
        expect(result.length, lessThanOrEqualTo(30));
        expect(result.length, greaterThan(3)); // at least one bucket

        // Results should be time-ordered
        for (int i = 1; i < result.length; i++) {
          expect(result[i].time.millisecondsSinceEpoch,
              greaterThanOrEqualTo(result[i - 1].time.millisecondsSinceEpoch));
        }

        // All values should be doubles
        for (final point in result) {
          expect(point.value, isA<double>());
        }
      });

      test('should preserve min/max spike in downsampled output', () async {
        final baseTime = DateTime.now().subtract(const Duration(minutes: 60));

        // Insert 60 points: all 10.0 except one spike at 999.0
        for (int i = 0; i < 60; i++) {
          final t = baseTime.add(Duration(minutes: i));
          final value = (i == 30) ? 999.0 : 10.0;
          await database.insertTimeseriesData(testTableName, t, value);
        }
        await database.flush();

        final from = baseTime.subtract(const Duration(seconds: 1));
        final to = baseTime.add(const Duration(minutes: 61));

        // Downsample to 15 points (5 buckets)
        final result = await database.queryTimeseriesDataDownsampled(
            testTableName, from, to,
            maxPoints: 15);

        // The spike at 999.0 must be preserved as a max value
        final values = result.map((r) => r.value as double).toList();
        expect(values, contains(999.0));

        // The min value of 10.0 should also be present
        expect(values, contains(10.0));
      });

      test('should return empty list for empty table', () async {
        // Create the table by inserting and removing
        await database.insertTimeseriesData(
            testTableName, DateTime.now(), 1.0);
        await database.flush();
        await database.db.customStatement(
            'DELETE FROM "$testTableName"');

        final result = await database.queryTimeseriesDataDownsampled(
            testTableName,
            DateTime.now().subtract(const Duration(hours: 1)),
            DateTime.now());

        expect(result, isEmpty);
      });

      test('should downsample array columns per-element', () async {
        final baseTime = DateTime.now().subtract(const Duration(minutes: 60));

        // Insert 30 array data points over 60 minutes
        for (int i = 0; i < 30; i++) {
          final t = baseTime.add(Duration(minutes: i * 2));
          // Array with 3 elements, middle element spikes at i==15
          await database.insertTimeseriesData(testTableName, t, [
            (i % 5).toDouble(),
            i == 15 ? 999.0 : 10.0,
            50.0 + i,
          ]);
        }
        await database.flush();

        final from = baseTime.subtract(const Duration(seconds: 1));
        final to = baseTime.add(const Duration(minutes: 61));

        final result = await database.queryTimeseriesDataDownsampled(
            testTableName, from, to,
            maxPoints: 15);

        // Should get downsampled results, not all 30 raw rows
        expect(result.length, lessThan(30));
        expect(result.length, greaterThan(3));

        // Results should be time-ordered
        for (int i = 1; i < result.length; i++) {
          expect(result[i].time.millisecondsSinceEpoch,
              greaterThanOrEqualTo(result[i - 1].time.millisecondsSinceEpoch));
        }

        // Each value should be a list with 3 elements
        for (final point in result) {
          expect(point.value, isA<List>());
          final arr = point.value as List;
          expect(arr.length, 3);
        }

        // The spike at 999.0 should be preserved in element [1]
        final allElement1 =
            result.map((r) => (r.value as List)[1] as double).toList();
        expect(allElement1, contains(999.0));
      });

      test('should return correct min, max, and last per bucket', () async {
        // Use a time range that fits exactly 1 bucket when maxPoints=3.
        // We use a 24-hour range so time_bucket produces exactly 1 ~24h bucket
        // regardless of epoch alignment, preventing the ~40% flakiness seen
        // with ~10-minute ranges where epoch-aligned boundaries can split data.
        final baseTime =
            DateTime.now().subtract(const Duration(minutes: 10));

        // Insert 5 values within a small window (all within 1 bucket):
        //   t+0: 5.0, t+1: 2.0, t+2: 8.0, t+3: 3.0, t+4: 6.0
        // Expected per bucket: min=2.0, max=8.0, last=6.0
        final values = [5.0, 2.0, 8.0, 3.0, 6.0];
        for (int i = 0; i < values.length; i++) {
          final t = baseTime.add(Duration(minutes: i));
          await database.insertTimeseriesData(testTableName, t, values[i]);
        }
        await database.flush();

        final from = baseTime.subtract(const Duration(seconds: 1));
        final to = baseTime.add(const Duration(hours: 24));

        // maxPoints=3 → 1 bucket → 3 points (min, max, last)
        final result = await database.queryTimeseriesDataDownsampled(
            testTableName, from, to,
            maxPoints: 3);

        // Should get exactly 3 points from 1 bucket
        expect(result.length, 3);

        final resultValues =
            result.map((r) => r.value as double).toList();

        // The three points should be: min=2.0 (at bucket), max=8.0 (at bucket+0.5*interval), last=6.0 (at bucket+interval)
        expect(resultValues[0], 2.0, reason: 'First point should be min');
        expect(resultValues[1], 8.0, reason: 'Second point should be max');
        expect(resultValues[2], 6.0, reason: 'Third point should be last');

        // Timestamps should be strictly ordered
        expect(result[0].time.isBefore(result[1].time), isTrue,
            reason: 'min timestamp < max timestamp');
        expect(result[1].time.isBefore(result[2].time), isTrue,
            reason: 'max timestamp < last timestamp');
      });

      test('should fall back to raw query for boolean columns', () async {
        final baseTime = DateTime.now().subtract(const Duration(minutes: 10));

        for (int i = 0; i < 10; i++) {
          final t = baseTime.add(Duration(minutes: i));
          await database.insertTimeseriesData(
              testTableName, t, i.isEven);
        }
        await database.flush();

        // Should not throw, should fall back to raw query
        final result = await database.queryTimeseriesDataDownsampled(
            testTableName,
            baseTime.subtract(const Duration(seconds: 1)),
            baseTime.add(const Duration(minutes: 11)),
            maxPoints: 6);

        // Falls back to raw → returns all 10 points
        expect(result.length, 10);
      });

      test('should handle swapped from/to arguments', () async {
        final baseTime = DateTime.now().subtract(const Duration(minutes: 10));
        final values = [1.0, 5.0, 3.0];
        for (int i = 0; i < values.length; i++) {
          final t = baseTime.add(Duration(minutes: i));
          await database.insertTimeseriesData(testTableName, t, values[i]);
        }
        await database.flush();

        final from = baseTime.subtract(const Duration(seconds: 1));
        final to = baseTime.add(const Duration(hours: 24));

        // Pass to before from — should still work
        final result = await database.queryTimeseriesDataDownsampled(
            testTableName, to, from,
            maxPoints: 3);

        expect(result.length, 3);
        final resultValues = result.map((r) => r.value as double).toList();
        expect(resultValues[0], 1.0, reason: 'min');
        expect(resultValues[1], 5.0, reason: 'max');
        expect(resultValues[2], 3.0, reason: 'last');
      });

      test('should handle single data point', () async {
        final baseTime = DateTime.now().subtract(const Duration(minutes: 5));
        await database.insertTimeseriesData(testTableName, baseTime, 42.0);
        await database.flush();

        final result = await database.queryTimeseriesDataDownsampled(
            testTableName,
            baseTime.subtract(const Duration(minutes: 1)),
            baseTime.add(const Duration(minutes: 1)),
            maxPoints: 3);

        // 1 bucket → 3 points, but min=max=last=42.0
        expect(result.length, 3);
        for (final point in result) {
          expect(point.value, 42.0);
        }
      });

      test('should handle all identical values', () async {
        final baseTime = DateTime.now().subtract(const Duration(minutes: 10));
        for (int i = 0; i < 20; i++) {
          final t = baseTime.add(Duration(seconds: i * 30));
          await database.insertTimeseriesData(testTableName, t, 7.0);
        }
        await database.flush();

        final result = await database.queryTimeseriesDataDownsampled(
            testTableName,
            baseTime.subtract(const Duration(seconds: 1)),
            baseTime.add(const Duration(minutes: 11)),
            maxPoints: 9);

        expect(result, isNotEmpty);
        // Every point should be 7.0 since min=max=last=7.0
        for (final point in result) {
          expect(point.value, 7.0);
        }
      });

      test('should handle negative values correctly', () async {
        final baseTime = DateTime.now().subtract(const Duration(minutes: 10));
        // Insert: -10, 5, -20, 15, -3
        final values = [-10.0, 5.0, -20.0, 15.0, -3.0];
        for (int i = 0; i < values.length; i++) {
          final t = baseTime.add(Duration(minutes: i));
          await database.insertTimeseriesData(testTableName, t, values[i]);
        }
        await database.flush();

        final result = await database.queryTimeseriesDataDownsampled(
            testTableName,
            baseTime.subtract(const Duration(seconds: 1)),
            baseTime.add(const Duration(hours: 24)),
            maxPoints: 3);

        expect(result.length, 3);
        final resultValues = result.map((r) => r.value as double).toList();
        expect(resultValues[0], -20.0, reason: 'min should be -20.0');
        expect(resultValues[1], 15.0, reason: 'max should be 15.0');
        expect(resultValues[2], -3.0, reason: 'last should be -3.0');
      });

      test('should fallback when maxPoints is 1 or 2', () async {
        final baseTime = DateTime.now().subtract(const Duration(minutes: 10));
        for (int i = 0; i < 5; i++) {
          final t = baseTime.add(Duration(minutes: i));
          await database.insertTimeseriesData(
              testTableName, t, i.toDouble());
        }
        await database.flush();

        final from = baseTime.subtract(const Duration(seconds: 1));
        final to = baseTime.add(const Duration(minutes: 10));

        // maxPoints=1 → numBuckets=(1/3).floor()=0 → fallback to raw
        final result1 = await database.queryTimeseriesDataDownsampled(
            testTableName, from, to,
            maxPoints: 1);
        expect(result1.length, 5, reason: 'maxPoints=1 should fallback to raw');

        // maxPoints=2 → numBuckets=(2/3).floor()=0 → fallback to raw
        final result2 = await database.queryTimeseriesDataDownsampled(
            testTableName, from, to,
            maxPoints: 2);
        expect(result2.length, 5, reason: 'maxPoints=2 should fallback to raw');
      });

      test('should handle from == to (zero range)', () async {
        final baseTime = DateTime.now().subtract(const Duration(minutes: 5));
        await database.insertTimeseriesData(testTableName, baseTime, 1.0);
        await database.flush();

        // from == to → rangeMs=0 → fallback to raw
        final result = await database.queryTimeseriesDataDownsampled(
            testTableName, baseTime, baseTime,
            maxPoints: 3);

        // Raw query with from==to might return 0 or 1 row depending on
        // exact timestamp matching; should not throw
        expect(result, isA<List>());
      });

      test('should handle non-existent table', () async {
        // The table doesn't exist at all
        expect(
          () => database.queryTimeseriesDataDownsampled(
              'non_existent_table_xyz',
              DateTime.now().subtract(const Duration(hours: 1)),
              DateTime.now(),
              maxPoints: 3),
          throwsA(anything),
        );
      });

      test('should handle query range with no data', () async {
        final baseTime = DateTime.now().subtract(const Duration(minutes: 60));
        // Insert data in the past
        for (int i = 0; i < 5; i++) {
          final t = baseTime.add(Duration(minutes: i));
          await database.insertTimeseriesData(testTableName, t, i.toDouble());
        }
        await database.flush();

        // Query a future range where there is no data
        final result = await database.queryTimeseriesDataDownsampled(
            testTableName,
            DateTime.now().add(const Duration(hours: 1)),
            DateTime.now().add(const Duration(hours: 2)),
            maxPoints: 3);

        expect(result, isEmpty);
      });

      test('should handle multiple buckets with precise values', () async {
        // Place two groups of data far apart so they definitely land in
        // separate buckets regardless of epoch alignment.
        final baseTime = DateTime.now().subtract(const Duration(hours: 2));

        // Group A: 4 points within a 1-minute window → min=1, max=20, last=5
        final groupA = [10.0, 1.0, 20.0, 5.0];
        for (int i = 0; i < groupA.length; i++) {
          final t = baseTime.add(Duration(seconds: i * 10));
          await database.insertTimeseriesData(testTableName, t, groupA[i]);
        }

        // Group B: 4 points ~1 hour later → min=50, max=200, last=75
        final groupB = [100.0, 50.0, 200.0, 75.0];
        for (int i = 0; i < groupB.length; i++) {
          final t = baseTime.add(Duration(hours: 1, seconds: i * 10));
          await database.insertTimeseriesData(testTableName, t, groupB[i]);
        }
        await database.flush();

        final from = baseTime.subtract(const Duration(minutes: 1));
        final to = baseTime.add(const Duration(hours: 1, minutes: 1));

        // maxPoints=6 → 2 buckets. Each bucket ~30 minutes, groups are 1h apart
        // so they'll be in separate buckets.
        final result = await database.queryTimeseriesDataDownsampled(
            testTableName, from, to,
            maxPoints: 6);

        // Buckets are aligned to the window start since 13-12, so this is
        // exactly 2 buckets rather than the 2-3 the epoch alignment used to
        // give. Each group's points are <1min apart, so they stay together
        // either way. Result count must be a multiple of 3.
        expect(result.length % 3, 0, reason: 'Points come in triples');
        expect(result.length, greaterThanOrEqualTo(6));
        expect(result.length, lessThanOrEqualTo(6),
            reason: 'maxPoints was 6 and the bound is not a suggestion');

        final vals = result.map((r) => r.value as double).toList();

        // Group A values must be present: min=1.0, max=20.0, last=5.0
        expect(vals, contains(1.0));
        expect(vals, contains(20.0));
        expect(vals, contains(5.0));

        // Group B values must be present: min=50.0, max=200.0, last=75.0
        expect(vals, contains(50.0));
        expect(vals, contains(200.0));
        expect(vals, contains(75.0));

        // Results must be time-ordered
        for (int i = 1; i < result.length; i++) {
          expect(result[i].time.millisecondsSinceEpoch,
              greaterThanOrEqualTo(result[i - 1].time.millisecondsSinceEpoch));
        }
      });

      // The per-bucket "last" is TimescaleDB's last(value, time) rather than
      // (array_agg(value ORDER BY time DESC))[1], which forced a full external
      // merge sort of every row in range. The two are equivalent; these pin
      // the corners of that equivalence, because the one thing that would make
      // the optimisation unsafe is a case where they disagree.
      group('per-bucket last() semantics', () {
        /// Runs the same aggregation both ways, straight against the server,
        /// and asserts they agree row for row. `IS NOT DISTINCT FROM` so two
        /// NULLs count as agreement.
        Future<void> expectAggregatesAgree(String table) async {
          final rows = await database.db.customSelect('''
            SELECT
              time_bucket('1 minute'::interval, time)  AS bucket,
              (array_agg(value ORDER BY time DESC))[1] AS old_last,
              last(value, time)                        AS new_last,
              ((array_agg(value ORDER BY time DESC))[1]
                 IS NOT DISTINCT FROM last(value, time)) AS same
            FROM "$table"
            GROUP BY bucket
            ORDER BY bucket
          ''').get();

          expect(rows, isNotEmpty, reason: 'nothing to compare');
          for (final row in rows) {
            expect(row.data['same'], true,
                reason: 'array_agg and last() disagreed on bucket '
                    '${row.data['bucket']}: ${row.data['old_last']} vs '
                    '${row.data['new_last']}');
          }
        }

        // Recent, not a fixed date: the enclosing setUp puts a two-hour
        // retention policy on this table, and anything older is fair game for
        // the retention job to drop mid-test.
        DateTime recentBase() =>
            DateTime.now().toUtc().subtract(const Duration(minutes: 30));

        test('agrees with array_agg on plain, distinct-timestamp data',
            () async {
          final base = recentBase();
          for (var i = 0; i < 30; i++) {
            await database.insertTimeseriesData(
                testTableName, base.add(Duration(seconds: i * 10)), i * 1.5);
          }
          await database.flush();
          await expectAggregatesAgree(testTableName);
        });

        test('both carry a NULL value on the newest row, neither skips back',
            () async {
          // The interesting case: last() could plausibly have been defined to
          // ignore NULL values and fall back to an older non-null sample. It
          // is not — it returns whatever the greatest-time row holds. A
          // collector writing a null on a dropped read must keep reading as a
          // gap in the chart, not as the previous value held forever.
          final base = recentBase();
          await database.insertTimeseriesData(testTableName, base, 10.0);
          await database.insertTimeseriesData(
              testTableName, base.add(const Duration(seconds: 10)), 20.0);
          await database.flush();
          // insertTimeseriesData has no null path, so write it directly.
          await database.db.customStatement(
              'INSERT INTO "$testTableName" (time, value) VALUES '
              "('${base.add(const Duration(seconds: 20)).toIso8601String()}'::timestamptz, NULL)");

          await expectAggregatesAgree(testTableName);

          final row = await database.db.customSelect(
              'SELECT last(value, time) AS v FROM "$testTableName"').get();
          expect(row.single.data['v'], isNull,
              reason: 'last() must propagate the newest NULL');
        });

        test('agrees when every value in a bucket is NULL', () async {
          final base = recentBase();
          await database.insertTimeseriesData(testTableName, base, 1.0);
          await database.flush();
          await database.db
              .customStatement('DELETE FROM "$testTableName"');
          for (var i = 0; i < 3; i++) {
            await database.db.customStatement(
                'INSERT INTO "$testTableName" (time, value) VALUES '
                "('${base.add(Duration(seconds: i * 10)).toIso8601String()}'::timestamptz, NULL)");
          }
          await expectAggregatesAgree(testTableName);
        });

        test('agrees on NaN and Infinity', () async {
          final base = recentBase();
          await database.insertTimeseriesData(testTableName, base, 1.0);
          await database.flush();
          for (final (i, literal) in [
            "'NaN'",
            "'Infinity'",
            "'-Infinity'",
          ].indexed) {
            await database.db.customStatement(
                'INSERT INTO "$testTableName" (time, value) VALUES '
                "('${base.add(Duration(seconds: (i + 1) * 10)).toIso8601String()}'::timestamptz, $literal)");
          }
          await expectAggregatesAgree(testTableName);
        });

        test('a hypertable cannot hold a NULL time', () async {
          // This is what makes the equivalence total. ORDER BY time DESC sorts
          // NULLs *first*, so a NULL time would make array_agg[1] pick that
          // row while last() skips it. Timescale forbids it outright, because
          // time is the partitioning column.
          await database.insertTimeseriesData(
              testTableName, recentBase(), 1.0);
          await database.flush();

          await expectLater(
            database.db.customStatement(
                'INSERT INTO "$testTableName" (time, value) VALUES (NULL, 1)'),
            throwsA(anything),
          );
        });
      });

      // The information_schema lookup that picks the scalar-vs-array SQL used
      // to run once per series per query — 2 ms each, queued behind everything
      // else on a pool of one.
    });

    // The Downtime view is the only reader that bounds `alarm_history` by a
    // window, and it was the only thing broken by drift rewriting datetime
    // comparisons into `JULIANDAY(...)` — a function Postgres does not have.
    // A sqlite-only test cannot see that, so this one runs the real query
    // against the real server. See `alarmHistoryOverlaps`.
    group('Alarm history window', () {
      /// A closed activation, written the way `AlarmMan._addToDb` writes one:
      /// raw SQL through a `::timestamp` cast, which Postgres stores back as
      /// its own `2026-08-29 10:00:00` text rather than ISO-8601.
      Future<void> insertLikeAlarmMan(
          String uid, DateTime start, DateTime? end) async {
        await database.db.customInsert(
          r'INSERT INTO alarm (uid, title, description, rules) '
          r'VALUES ($1, $2, $3, $4) ON CONFLICT (uid) DO NOTHING',
          variables: [
            Variable.withString(uid),
            Variable.withString(uid),
            Variable.withString(uid),
            Variable.withString('[]'),
          ],
        );
        await database.db.customInsert(
          r'INSERT INTO alarm_history (alarm_uid, alarm_title, '
          r'alarm_description, alarm_level, expression, active, pending_ack, '
          r'created_at, deactivated_at) '
          r'VALUES ($1, $2, $3, $4, $5, $6, $7, $8::timestamp, $9::timestamp)',
          variables: [
            Variable.withString(uid),
            Variable.withString(uid),
            Variable.withString(uid),
            Variable.withString('error'),
            Variable.withString('a'),
            Variable.withBool(false),
            Variable.withBool(false),
            Variable.withString(start.toIso8601String()),
            // NULL for a standing alarm; `_addToDb` only ever writes closed ones.
            Variable<String>(end?.toIso8601String()),
          ],
        );
      }

      Future<List<String>> inWindow({DateTime? from, DateTime? to}) async {
        final query = database.db.select(database.db.alarmHistory)
          ..where((t) => alarmHistoryOverlaps(t, from: from, to: to));
        final rows = await query.get();
        return rows.map((r) => r.alarmUid).toList()..sort();
      }

      final day = DateTime(2026, 8, 29);
      DateTime at(int hour) => day.add(Duration(hours: hour));

      setUp(() async {
        await database.db.customStatement('DELETE FROM alarm_history');
        await database.db.customStatement('DELETE FROM alarm');
        await insertLikeAlarmMan('before', at(2), at(4));
        await insertLikeAlarmMan('straddles-start', at(6), at(9));
        await insertLikeAlarmMan('inside', at(10), at(11));
        await insertLikeAlarmMan('after', at(20), at(22));
        await insertLikeAlarmMan('standing', at(7), null);
      });

      tearDown(() async {
        try {
          await database.db.customStatement('DELETE FROM alarm_history');
          await database.db.customStatement('DELETE FROM alarm');
        } catch (_) {}
      });

      test('a bounded window runs at all', () async {
        // Before the fix this threw
        // `function julianday(text) does not exist` and the Downtime tab
        // showed the error instead of a timeline.
        expect(await inWindow(from: at(8), to: at(16)),
            ['inside', 'standing', 'straddles-start']);
      });

      test('an unbounded query is unaffected', () async {
        expect(await inWindow(), hasLength(5));
      });

      test('an open-ended window bounds only the side it names', () async {
        expect(await inWindow(to: at(5)), ['before']);
        expect(await inWindow(from: at(21)), ['after', 'standing']);
      });

      test('rows drift itself inserted compare the same', () async {
        // drift stores ISO-8601 in the same text column; `::timestamp` has to
        // parse both spellings or half the history sorts wrong.
        await database.db.into(database.db.alarm).insert(
              AlarmCompanion.insert(
                  uid: 'drift-written',
                  title: 'drift-written',
                  description: 'drift-written',
                  rules: '[]'),
            );
        await database.db.into(database.db.alarmHistory).insert(
              AlarmHistoryCompanion.insert(
                alarmUid: 'drift-written',
                alarmTitle: 'drift-written',
                alarmDescription: 'drift-written',
                alarmLevel: 'error',
                expression: const Value('a'),
                active: false,
                pendingAck: false,
                createdAt: at(10),
                deactivatedAt: Value(at(11)),
              ),
            );

        expect(await inWindow(from: at(8), to: at(16)),
            contains('drift-written'));
        expect(await inWindow(to: at(5)), isNot(contains('drift-written')));
      });
    });

    group('Error Handling', () {
      test('should handle invalid table names', () async {
        expect(
          () => database
              .insertTimeseriesData('', DateTime.now(), {'test': 'data'}),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('should handle invalid JSON data', () async {
        await database.registerRetentionPolicy(
            testTableName, RetentionPolicy(dropAfter: Duration(hours: 1)));

        // This should work - Dart handles JSON serialization
        await database.insertTimeseriesData(
          testTableName,
          DateTime.now(),
          {'test': 'data'},
        );
      });
    });

    group('Performance Tests', () {
      test('should handle bulk insertions', () async {
        await database.registerRetentionPolicy(
            testTableName, RetentionPolicy(dropAfter: Duration(hours: 1)));

        final baseTime = DateTime.now();
        const numRecords = 100;

        // Insert multiple records
        for (int i = 0; i < numRecords; i++) {
          await database.insertTimeseriesData(
            testTableName,
            baseTime.add(Duration(seconds: i)),
            {'value': i, 'batch': 'bulk_test'},
          );
        }
        await database.flush();

        final result = await database.queryTimeseriesData(
            testTableName, baseTime.subtract(const Duration(days: 1)));
        expect(result.length, numRecords);
      }, timeout: Timeout(Duration(minutes: 2)));

      test('should handle large JSON payloads', () async {
        await database.registerRetentionPolicy(
            testTableName, RetentionPolicy(dropAfter: Duration(hours: 1)));

        final largeData = {
          'large_array': List.generate(1000, (i) => i),
          'large_string': 'x' * 10000,
          'nested_object': {
            'level1': {
              'level2': {
                'level3': List.generate(100, (i) => {'id': i, 'value': 'test'}),
              },
            },
          },
        };

        await database.insertTimeseriesData(
            testTableName, DateTime.now(), largeData);

        final result = await database.queryTimeseriesData(
            testTableName, DateTime.now().subtract(const Duration(days: 1)));
        expect(result.length, 1);
        expect(result[0].value, largeData);
      }, skip: "Todo: fix Drift to handle JSON data in postgres");
    });

    group('Materialized View (createView)', () {
      const mvName = 'mv_join_test';

      setUp(() async {
        // The outer setUp has already dropped both base tables, so the view
        // below spans only what this test writes. That matters here more than
        // anywhere else in the file: `all_times` is a UNION over the base
        // tables, so one leftover row becomes one extra view row — this test
        // has failed on CI with four rows as well as with two.

        // Make sure base tables exist as hypertables
        await database.registerRetentionPolicy(
          testTableName,
          const RetentionPolicy(dropAfter: Duration(hours: 1)),
        );
        await database.registerRetentionPolicy(
          testTableName2,
          const RetentionPolicy(dropAfter: Duration(hours: 1)),
        );
      });

      tearDown(() async {
        // Clean up the MV explicitly (tables are dropped by outer tearDown)
        try {
          await database.db.customStatement(
              'DROP MATERIALIZED VIEW IF EXISTS "$mvName" CASCADE');
        } catch (_) {/* ignore */}
      });

      test('should create MV over two timeseries and join on time', () async {
        final base = DateTime.now();

        // Insert into table 1 at t0, t1
        final t0 = base;
        final t1 = base.add(const Duration(minutes: 1));
        await database.insertTimeseriesData(testTableName, t0, 10);
        await database.insertTimeseriesData(testTableName, t1, 20);

        // Insert into table 2 at t1, t2
        final t2 = base.add(const Duration(minutes: 2));
        await database.insertTimeseriesData(testTableName2, t1, 200);
        await database.insertTimeseriesData(testTableName2, t2, 300);
        await database.flush();

        // Both base tables must hold exactly what this test wrote before the
        // view is built over them.
        //
        // `CREATE MATERIALIZED VIEW` snapshots the base tables at that
        // instant, so a row still sitting in the write buffer is a row the
        // view will never have — which is how this failed on CI with two rows
        // instead of three. flush() ought to be enough; asserting that it was
        // costs one query and turns "the view is short" into "the insert had
        // not landed", which is a different bug with a different fix.
        for (final t in [testTableName, testTableName2]) {
          await eventually(
            () => database.queryTimeseriesData(
                t, base.subtract(const Duration(minutes: 1))),
            hasLength(2),
            reason: 'base table "$t" must hold its two rows before the view '
                'is created over it',
          );
        }

        // Create MV with columns {table: column}
        await database.createView(mvName, {
          testTableName: 'value',
          testTableName2: 'value',
        });

        await database.queryTimeseriesData(mvName, base);

        // Query MV
        final rows = await database.db.customSelect('''
      SELECT * FROM "$mvName" ORDER BY "time" ASC
    ''').get();

        // Expect union of times: t0, t1, t2.
        //
        // This has failed on CI with 4 rows. Print the rows when it does — an
        // extra row is either a base-table timestamp this test did not write,
        // or a duplicate insert at one of these timestamps fanning out through
        // the LEFT JOIN, and the bare count cannot tell those apart.
        expect(rows.length, 3, reason: 'view rows: ${_describe(rows)}');

        // Column names are <table>_<column> per implementation
        final c1 = '${testTableName}_value'; // test_timeseries_value
        final c2 = '${testTableName2}_value'; // test_timeseries_2_value

        // Row 0 -> t0: value from table1 only
        expect(rows[0].read<int?>(c1), 10);
        expect(rows[0].read<int?>(c2), isNull);

        // Row 1 -> t1: values from both tables
        expect(rows[1].read<int?>(c1), 20);
        expect(rows[1].read<int?>(c2), 200);

        // Row 2 -> t2: value from table2 only
        expect(rows[2].read<int?>(c1), isNull);
        expect(rows[2].read<int?>(c2), 300);
      });

      test('should be safe to call createView again and reflect new data',
          () async {
        final base = DateTime.now();

        // Seed some data
        final t0 = base;
        final t1 = base.add(const Duration(minutes: 1));
        await database.insertTimeseriesData(testTableName, t0, 10);
        await database.insertTimeseriesData(testTableName, t1, 20);

        await database.insertTimeseriesData(testTableName2, t1, 200);
        await database.flush();

        // First create
        await database.createView(mvName, {
          testTableName: 'value',
          testTableName2: 'value',
        });

        // Verify initial row count
        var rows = await database.db
            .customSelect(
              'SELECT * FROM "$mvName" ORDER BY "time" ASC',
            )
            .get();
        expect(rows.length, 2, reason: 'view rows: ${_describe(rows)}');

        // Add new data and call createView again (old impl drops & recreates)
        final t2 = base.add(const Duration(minutes: 2));
        await database.insertTimeseriesData(testTableName, t2, 40);
        await database.flush();

        await database.createView(mvName, {
          testTableName: 'value',
          testTableName2: 'value',
        });

        // MV should now include the new timestamp
        rows = await database.db
            .customSelect(
              'SELECT * FROM "$mvName" ORDER BY "time" ASC',
            )
            .get();
        expect(rows.length, 3, reason: 'view rows: ${_describe(rows)}');

        final c1 = '${testTableName}_value';
        final c2 = '${testTableName2}_value';

        // Last row corresponds to t2 -> value only from table1
        expect(rows.last.read<int?>(c1), 40);
        expect(rows.last.read<int?>(c2), isNull);
      });
    });

    group('LISTEN/NOTIFY Tests', () {
      const notifyTestTable = 'test_notify_table';

      setUp(() async {
        // Create test table before each test
        await database.registerRetentionPolicy(
          notifyTestTable,
          const RetentionPolicy(dropAfter: Duration(hours: 1)),
        );

        // Insert one row to create the table
        await database.insertTimeseriesData(
          notifyTestTable,
          DateTime.now(),
          42,
        );
        await database.flush();
      });

      tearDown(() async {
        // Flush before cleanup
        try {
          await database.flush();
        } catch (_) {}
        // Clean up after each test
        try {
          await database.db.customStatement(
            'DROP TABLE IF EXISTS "$notifyTestTable" CASCADE',
          );
        } catch (_) {
          // Ignore cleanup errors
        }
      });

      test('should enable notification channel and create trigger', () async {
        // Enable notifications
        await database.db.enableNotificationChannel(notifyTestTable);

        // Verify function exists
        final functionResult = await database.db.customSelect(r'''
      SELECT EXISTS (
        SELECT FROM pg_proc 
        WHERE proname = $1
      )
    ''', variables: [
          Variable.withString('notify_${notifyTestTable}_change')
        ]).get();

        expect(functionResult[0].read<bool>('exists'), true);

        // Verify trigger exists
        final triggerResult = await database.db.customSelect(r'''
      SELECT EXISTS (
        SELECT FROM pg_trigger
        WHERE tgname = $1
      )
    ''', variables: [Variable.withString('${notifyTestTable}_notify')]).get();

        expect(triggerResult[0].read<bool>('exists'), true);
      });

      test('should receive notification on INSERT', () async {
        await database.db.enableNotificationChannel(notifyTestTable);

        final channelName = 'table_${notifyTestTable}_changes';
        final notifications = <String>[];

        final subscription = await subscribeWhenReady(
            database.db, channelName, notifications.add);

        // Insert data to trigger notification
        await database.insertTimeseriesData(
          notifyTestTable,
          DateTime.now(),
          100,
        );
        await database.flush();

        // Poll until notification arrives instead of using a fixed delay.
        await waitUntil(() => notifications.isNotEmpty);

        // Verify notification received
        expect(notifications.length, 1);

        final notification = jsonDecode(notifications[0]);
        expect(notification['action'], 'INSERT');
        expect(notification['data'], isA<Map>());
        expect(notification['data']['value'], 100);
        await subscription.cancel();
      });

      test('should receive notification on UPDATE', () async {
        await database.db.enableNotificationChannel(notifyTestTable);

        final channelName = 'table_${notifyTestTable}_changes';
        final notifications = <String>[];

        final subscription = await subscribeWhenReady(
            database.db, channelName, notifications.add);

        // Update data
        await database.db.customStatement('''
      UPDATE "$notifyTestTable"
      SET value = 999
      WHERE value = 42
    ''');

        await waitUntil(() => notifications.isNotEmpty);

        expect(notifications.length, 1);

        final notification = jsonDecode(notifications[0]);
        expect(notification['action'], 'UPDATE');
        expect(notification['data']['value'], 999);

        await subscription.cancel();
      });

      test('should receive notification on DELETE', () async {
        await database.db.enableNotificationChannel(notifyTestTable);

        final channelName = 'table_${notifyTestTable}_changes';
        final notifications = <String>[];

        final subscription = await subscribeWhenReady(
            database.db, channelName, notifications.add);

        // Delete data
        await database.db.customStatement('''
      DELETE FROM "$notifyTestTable" WHERE value = 42
    ''');

        await waitUntil(() => notifications.isNotEmpty);

        expect(notifications.length, 1);

        final notification = jsonDecode(notifications[0]);
        expect(notification['action'], 'DELETE');
        expect(notification['data']['value'], 42);

        await subscription.cancel();
      });

      test('should handle multiple notifications', () async {
        await database.db.enableNotificationChannel(notifyTestTable);

        final channelName = 'table_${notifyTestTable}_changes';
        final notifications = <String>[];

        final subscription = await subscribeWhenReady(
            database.db, channelName, notifications.add);

        // Insert multiple records
        for (int i = 0; i < 5; i++) {
          await database.insertTimeseriesData(
            notifyTestTable,
            DateTime.now().add(Duration(seconds: i)),
            100 + i,
          );
        }
        await database.flush();

        await waitUntil(() => notifications.length >= 5);

        expect(notifications.length, 5);

        // Verify all are INSERT actions
        for (final notif in notifications) {
          final decoded = jsonDecode(notif);
          expect(decoded['action'], 'INSERT');
        }

        await subscription.cancel();
      });

      test('should work with complex timeseries data', () async {
        // Create a table with multiple columns
        const complexTable = 'test_complex_notify';

        await database.registerRetentionPolicy(
          complexTable,
          const RetentionPolicy(dropAfter: Duration(hours: 1)),
        );

        // Insert complex data to create table structure
        final testData = {
          'temperature': 25.5,
          'humidity': 60.2,
          'pressure': 1013.25,
        };

        await database.insertTimeseriesData(
          complexTable,
          DateTime.now(),
          testData,
        );
        await database.flush();

        // Enable notifications
        await database.db.enableNotificationChannel(complexTable);

        final channelName = 'table_${complexTable}_changes';
        final notifications = <String>[];

        final subscription = await subscribeWhenReady(
            database.db, channelName, notifications.add);

        // Insert new data
        final newData = {
          'temperature': 30.0,
          'humidity': 55.0,
          'pressure': 1015.0,
        };

        await database.insertTimeseriesData(
          complexTable,
          DateTime.now(),
          newData,
        );
        await database.flush();

        await waitUntil(() => notifications.isNotEmpty);

        expect(notifications.length, 1);

        final notification = jsonDecode(notifications[0]);
        expect(notification['action'], 'INSERT');
        expect(notification['data']['temperature'], 30.0);
        expect(notification['data']['humidity'], 55.0);
        expect(notification['data']['pressure'], 1015.0);

        await subscription.cancel();

        // Cleanup
        await database.db.customStatement(
          'DROP TABLE IF EXISTS "$complexTable" CASCADE',
        );
      });

      test('ends every channel stream when the notification connection dies',
          () async {
        // The LISTEN/NOTIFY connection is not in the pool: it has no
        // reconnect of its own, and the driver does not close the channel
        // listeners when its socket goes. Left alone, every subscriber sat
        // on a stream that would never emit, error, or end -- which is how
        // the readouts on the mimic froze on their last count while the same
        // readouts freshly mounted in a side pane showed the right one.
        await database.db.enableNotificationChannel(notifyTestTable);
        final channelName = 'table_${notifyTestTable}_changes';
        final notifications = <String>[];
        var ended = 0;

        final sub1 = await subscribeWhenReady(
            database.db, channelName, notifications.add,
            onDone: () => ended++);
        final sub2 = await subscribeWhenReady(
            database.db, channelName, notifications.add,
            onDone: () => ended++);

        // Kill the backend server-side: what a Postgres restart, or a
        // firewall dropping the idle flow, looks like from the client.
        final killed = await database.db.customSelect(
          "SELECT pg_terminate_backend(pid) AS ok FROM pg_stat_activity "
          "WHERE application_name LIKE '%:notify'",
        ).get();
        expect(killed, isNotEmpty, reason: 'no notification backend to kill');

        // Both streams end -- done, not error -- once the watchdog notices.
        await waitUntil(() => ended == 2,
            timeout: kNotificationWatchdogInterval * 3);
        expect(notifications, isEmpty);

        // The next subscriber rides a fresh connection, and it delivers.
        final sub3 = await subscribeWhenReady(
            database.db, channelName, notifications.add);
        await database.insertTimeseriesData(
          notifyTestTable,
          DateTime.now(),
          909,
        );
        await database.flush();
        await waitUntil(() => notifications.isNotEmpty);
        expect(jsonDecode(notifications.single)['data']['value'], 909);

        // One notify backend, not two: the dead one was let go of.
        final backends = await database.db.customSelect(
          "SELECT count(*) AS n FROM pg_stat_activity "
          "WHERE application_name LIKE '%:notify'",
        ).get();
        expect(backends.single.read<int>('n'), 1);

        await sub1.cancel();
        await sub2.cancel();
        await sub3.cancel();
      });

      test('should handle multiple listeners on same channel', () async {
        await database.db.enableNotificationChannel(notifyTestTable);

        final channelName = 'table_${notifyTestTable}_changes';
        final notifications1 = <String>[];
        final notifications2 = <String>[];

        // Two listeners on same channel — each waits until its own LISTEN is live.
        final sub1 = await subscribeWhenReady(
            database.db, channelName, notifications1.add);
        final sub2 = await subscribeWhenReady(
            database.db, channelName, notifications2.add);

        await database.insertTimeseriesData(
          notifyTestTable,
          DateTime.now(),
          777,
        );
        await database.flush();

        await waitUntil(
            () => notifications1.isNotEmpty && notifications2.isNotEmpty);

        // Both listeners should receive the notification
        expect(notifications1.length, 1);
        expect(notifications2.length, 1);

        final notif1 = jsonDecode(notifications1[0]);
        final notif2 = jsonDecode(notifications2[0]);

        expect(notif1['data']['value'], 777);
        expect(notif2['data']['value'], 777);

        await sub1.cancel();
        await sub2.cancel();
      });

      test('should not receive notifications after canceling subscription',
          () async {
        await database.db.enableNotificationChannel(notifyTestTable);

        final channelName = 'table_${notifyTestTable}_changes';
        final notifications = <String>[];

        final subscription = await subscribeWhenReady(
            database.db, channelName, notifications.add);

        // Insert first record
        await database.insertTimeseriesData(
          notifyTestTable,
          DateTime.now(),
          111,
        );
        await database.flush();

        await waitUntil(() => notifications.isNotEmpty);
        expect(notifications.length, 1);

        // Cancel subscription
        await subscription.cancel();
        await Future.delayed(const Duration(milliseconds: 100));

        // Insert second record
        await database.insertTimeseriesData(
          notifyTestTable,
          DateTime.now(),
          222,
        );
        await database.flush();

        // Give some time to confirm no extra notification arrives.
        await Future.delayed(const Duration(milliseconds: 500));

        // Should still be 1 (didn't receive second notification)
        expect(notifications.length, 1);
      });

      test('should handle rapid succession of changes', () async {
        await database.db.enableNotificationChannel(notifyTestTable);

        final channelName = 'table_${notifyTestTable}_changes';
        final notifications = <String>[];

        final subscription = await subscribeWhenReady(
            database.db, channelName, notifications.add);

        // Rapid inserts - flush after each to test notification throughput
        for (int i = 0; i < 20; i++) {
          await database.insertTimeseriesData(
            notifyTestTable,
            DateTime.now().add(Duration(milliseconds: i)),
            i,
          );
          await database.flush();
        }

        await waitUntil(() => notifications.length >= 20,
            timeout: const Duration(seconds: 15));

        // Should receive all 20 notifications
        expect(notifications.length, 20);

        await subscription.cancel();
      });

      test('should handle simultaneous changes from many tables', () async {
        // Create 5 test tables
        final tableNames = List.generate(5, (i) => 'test_notify_multi_$i');

        // Setup: Create all tables and enable notifications
        var i = 0;
        for (final tableName in tableNames) {
          await database.registerRetentionPolicy(
            tableName,
            const RetentionPolicy(dropAfter: Duration(hours: 1)),
          );

          // Insert initial data to create the table
          await database.insertTimeseriesData(
            tableName,
            DateTime.now(),
            i++ * 10,
          );
          await database.flush();

          // Enable notifications for this table
          await database.db.enableNotificationChannel(tableName);
        }

        // Set up listeners for all tables and wait until each LISTEN is live.
        final allNotifications = <String, List<String>>{};
        final subscriptions = <StreamSubscription>[];

        for (final tableName in tableNames) {
          final channelName = 'table_${tableName}_changes';
          allNotifications[tableName] = [];

          final subscription = await subscribeWhenReady(
            database.db,
            channelName,
            (payload) => allNotifications[tableName]!.add(payload),
          );
          subscriptions.add(subscription);
        }

        // Insert data into each table simultaneously
        final now = DateTime.now();
        for (int i = 0; i < tableNames.length; i++) {
          await database.insertTimeseriesData(
            tableNames[i],
            now.add(Duration(milliseconds: i)),
            100 + i,
          );
        }
        await database.flush();

        await waitUntil(() => allNotifications.values.every((n) => n.isNotEmpty));

        // Verify each table received exactly one notification
        for (int i = 0; i < tableNames.length; i++) {
          final tableName = tableNames[i];
          final notifications = allNotifications[tableName]!;

          expect(notifications.length, 1,
              reason: 'Table $tableName should receive exactly 1 notification');

          final notification = jsonDecode(notifications[0]);
          expect(notification['action'], 'INSERT');
          expect(notification['data']['value'], 100 + i,
              reason: 'Table $tableName should have value ${100 + i}');
        }

        // Test cross-table isolation: update one table, verify only it gets notification
        final notifications1Before = allNotifications[tableNames[0]]!.length;

        await database.db.customStatement('''
          UPDATE "${tableNames[2]}"
          SET value = 999
          WHERE value = 102
        ''');

        await waitUntil(() => allNotifications[tableNames[2]]!.length >= 2);

        // Table 0 should not receive new notification
        expect(allNotifications[tableNames[0]]!.length, notifications1Before,
            reason:
                'Table ${tableNames[0]} should not receive notification from another table update');

        // Table 2 should receive UPDATE notification
        expect(allNotifications[tableNames[2]]!.length, 2,
            reason:
                'Table ${tableNames[2]} should have 2 notifications (INSERT + UPDATE)');

        final updateNotif = jsonDecode(allNotifications[tableNames[2]]![1]);
        expect(updateNotif['action'], 'UPDATE');
        expect(updateNotif['data']['value'], 999);

        // Cleanup subscriptions
        for (final sub in subscriptions) {
          await sub.cancel();
        }

        // Cleanup tables
        for (final tableName in tableNames) {
          try {
            await database.db.customStatement(
              'DROP TABLE IF EXISTS "$tableName" CASCADE',
            );
          } catch (_) {
            // Ignore cleanup errors
          }
        }
      });
    });
  });

  group('Schema Evolution', () {
    late Database database;
    const tableA = 'schema_evo_motor';
    const tableB = 'schema_evo_sensor'; // unrelated table, used to prove flush is not blocked

    setUpAll(() async {
      await startDockerCompose();
      await waitForDatabaseReady();
      database = await connectToDatabase();
    });

    setUp(() async {
      await database.registerRetentionPolicy(
          tableA, const RetentionPolicy(dropAfter: Duration(hours: 1)));
      await database.registerRetentionPolicy(
          tableB, const RetentionPolicy(dropAfter: Duration(hours: 1)));
    });

    tearDown(() async {
      try { await database.flush(); } catch (_) {}
      try { await database.db.customStatement('DROP TABLE IF EXISTS "$tableA" CASCADE'); } catch (_) {}
      try { await database.db.customStatement('DROP TABLE IF EXISTS "$tableB" CASCADE'); } catch (_) {}
    });

    tearDownAll(() async {
      await database.close();
      await stopDockerCompose();
    });

    // TDD test 1: schema evolution — new OPC UA struct fields are persisted
    //
    // Scenario: PLC struct initially has {sensor: double}. After a PLC code
    // update it gains a new field {sensor: double, new_field: bool}.
    // The table was created from the first shape, so the second insert
    // hits PostgreSQL error 42703 (undefined_column).
    //
    // Expected (after fix): the missing column is added automatically and both
    // rows are present in the database.
    // Without the fix: the second insert is permanently lost.
    test('new struct field is persisted after schema evolution', () async {
      final t0 = DateTime.now().subtract(const Duration(seconds: 2));
      final t1 = DateTime.now();

      // Establish table with initial struct shape
      await database.insertTimeseriesData(tableA, t0, {'sensor': 1.0});
      await database.flush();

      expect(await database.db.tableExists(tableA), true);

      // PLC struct gained a new field — this triggers 42703 without the fix
      await database.insertTimeseriesData(tableA, t1, {'sensor': 2.0, 'new_field': true});
      await database.flush();

      final rows = await database.queryTimeseriesData(
          tableA, t0.subtract(const Duration(seconds: 1)));

      // Both rows must be stored
      expect(rows.length, 2, reason: 'Both the original and the evolved struct must be persisted');

      // The second row must contain the new field
      final second = rows.firstWhere((r) => (r.value as Map)['sensor'] == 2.0);
      expect((second.value as Map)['new_field'], true,
          reason: 'new_field column should have been added via ALTER TABLE');
    });

    // TDD test 2: the flush loop must not block other tables when one table
    // has a permanent schema mismatch.
    //
    // Without the fix: _withRetry blocks for 1+2+4+8 = 15 s per failing table
    // because it retries 42703 (undefined_column) with exponential back-off.
    // During that time tableB cannot flush either because _flushInProgress=true.
    //
    // Expected (after fix): flush completes in well under 5 s even when tableA
    // has a 42703, and tableB data is still committed.
    test('flush loop is not blocked by a permanent schema error', () async {
      final t0 = DateTime.now().subtract(const Duration(seconds: 2));
      final t1 = DateTime.now();

      // Establish tableA with initial struct
      await database.insertTimeseriesData(tableA, t0, {'sensor': 1.0});
      await database.flush();

      // Seed tableB with healthy data
      await database.insertTimeseriesData(tableB, t0, 99);
      await database.flush();
      final beforeCount = (await database.queryTimeseriesData(
              tableB, t0.subtract(const Duration(seconds: 1))))
          .length;

      // Now queue a write that will cause 42703 on tableA…
      await database.insertTimeseriesData(tableA, t1, {'sensor': 2.0, 'new_field': true});
      // …and a healthy write on tableB in the same flush cycle
      await database.insertTimeseriesData(tableB, t1, 100);

      final sw = Stopwatch()..start();
      await database.flush();
      sw.stop();

      // Flush must complete quickly — not wait through 15 s of back-off retries
      expect(sw.elapsed.inSeconds, lessThan(5),
          reason: 'Flush blocked for ${sw.elapsed.inSeconds}s — '
              '_withRetry is retrying a permanent 42703 error');

      // tableB data must be committed despite tableA erroring
      final tableBRows = await database.queryTimeseriesData(
          tableB, t0.subtract(const Duration(seconds: 1)));
      expect(tableBRows.length, greaterThan(beforeCount),
          reason: 'tableB flush was blocked by tableA schema error');
    });
  });
}

import 'dart:async';
import 'dart:collection';

import 'package:test/test.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:tfc_dart/core/collector.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/boolean_expression.dart';

import 'docker_compose.dart';
import 'eventually.dart';

/// Polls [condition] every 50 ms until it returns true or [timeout] elapses.
Future<void> waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition not met within ${timeout.inSeconds}s', timeout);
    }
    await Future.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  group('Collector Integration', () {
    late Collector collector;
    late CollectorConfig config;
    late StateMan stateMan;
    late Database database;

    setUpAll(() async {
      stateMan = await OpcUaStateMan.create(
          config: StateManConfig(opcua: []),
          keyMappings: KeyMappings(nodes: {}));
      await stopDockerCompose();
      await startDockerCompose();
      await waitForDatabaseReady();
      database = await connectToDatabase();
    });

    setUp(() {
      // Create a basic config for testing
      config = CollectorConfig(collect: true);

      collector = Collector(
        config: config,
        stateMan: stateMan,
        database: database,
      );
    });

    tearDownAll(() async {
      await stopDockerCompose();
    });

    Future<List<TimeseriesData<dynamic>>> waitUntilInserted(String tableName,
        {DateTime? sinceTime, int minCount = 1}) async {
      List<TimeseriesData<dynamic>> insertedData = [];
      sinceTime ??= DateTime.now().subtract(const Duration(days: 1));
      for (var i = 0; i < 20; i++) {
        // Wait for async stream handlers to execute and add data to buffer
        await Future.delayed(const Duration(milliseconds: 100));
        // Flush the write buffer to ensure data is written
        await database.flush();
        try {
          insertedData =
              await database.queryTimeseriesData(tableName, sinceTime);
          if (insertedData.length >= minCount) {
            break;
          }
        } catch (e) {
          // Ignore - table might not exist yet
        }
      }
      return insertedData;
    }

    test('collectImpl should create subscription and handle data collection',
        () async {
      // Arrange
      const testName = 'test_collection';
      final testValue = DynamicValue(value: 'test_value');
      final streamController = StreamController<DynamicValue>();

      final entry = CollectEntry(key: testName, name: testName);
      // Act
      await collector.collectEntryImpl(entry, streamController.stream,
          skipFirstSample: false);

      // Simulate data stream
      streamController.add(testValue);
      final insertedData = await waitUntilInserted(testName);
      expect(insertedData.length, 1);
      expect(insertedData[0].value, 'test_value');

      // Clean up
      streamController.close();
      collector.stopCollect(entry);
    });

    test('sample_members collects chosen struct members into ONE table',
        () async {
      // The motor case: the subscribed key is the HMI struct, the timeseries
      // carries frequency + current as one row per sample in one table.
      const testName = 'sample_members_test';
      final streamController = StreamController<DynamicValue>();

      final entry = CollectEntry(
        key: testName,
        name: testName,
        sampleMembers: ['p_stat_Frequency', 'p_stat_Current'],
      );
      await collector.collectEntryImpl(entry, streamController.stream,
          skipFirstSample: false);

      DynamicValue struct(double freq, double current) =>
          DynamicValue.fromMap(LinkedHashMap<String, dynamic>.from({
            'p_stat_Frequency': freq,
            'p_stat_Current': current,
            'p_stat_xRunning': true,
          }));

      streamController.add(struct(25.0, 3.2));
      await waitUntilInserted(testName);
      // A sample where no member resolves must be skipped, not inserted.
      streamController.add(DynamicValue(value: 'not a struct'));
      streamController.add(struct(50.0, 6.4));

      final insertedData = await waitUntilInserted(testName, minCount: 2);
      expect(insertedData.length, 2,
          reason: 'The non-struct sample must have been skipped.');
      // Each row is an object keyed by the member paths — the unchosen
      // members do not ride along.
      expect(insertedData[0].value, contains('p_stat_Frequency'));
      expect(insertedData[0].value, contains('p_stat_Current'));
      expect(insertedData[0].value, isNot(contains('p_stat_xRunning')));

      streamController.close();
      collector.stopCollect(entry);
    });

    test('collectImpl fail if value type is not same', () async {
      // Arrange
      const testName = 'multi_test';
      final values = [
        DynamicValue(value: 'value1'),
        DynamicValue(value: 42),
        DynamicValue(value: true),
      ];
      final streamController = StreamController<DynamicValue>();

      // Act
      final entry = CollectEntry(key: testName, name: testName);
      await collector.collectEntryImpl(entry, streamController.stream,
          skipFirstSample: false);

      // Add multiple values
      for (final value in values) {
        streamController.add(value);
        await waitUntilInserted(testName); // Not sure why this is needed
      }

      final insertedData = await waitUntilInserted(testName);

      expect(insertedData.length, 3);
      expect(insertedData[0].value, 'value1');
      expect(insertedData[1].value, '42');
      expect(insertedData[2].value, 'true');

      // Clean up
      streamController.close();
      collector.stopCollect(entry);
    });

    test('collectImpl should handle stream errors', () async {
      // Arrange
      const testName = 'error_test';
      final streamController = StreamController<DynamicValue>();
      final testError = Exception('Test error');

      // Act
      final entry = CollectEntry(key: testName, name: testName);
      await collector.collectEntryImpl(entry, streamController.stream,
          skipFirstSample: false);

      streamController
          .add(DynamicValue(value: 'test_value')); // Create the table

      // Add an error to the stream
      streamController.addError(testError);

      final insertedData = await waitUntilInserted(testName);
      expect(insertedData.length, 1);

      // Clean up
      streamController.close();
      collector.stopCollect(entry);
    });

    test('collectImpl should handle stream completion', () async {
      // Arrange
      const testName = 'completion_test';
      final streamController = StreamController<DynamicValue>();

      // Act
      final entry = CollectEntry(key: testName, name: testName);
      await collector.collectEntryImpl(entry, streamController.stream,
          skipFirstSample: false);

      streamController
          .add(DynamicValue(value: 'test_value')); // Create the table

      // Complete the stream
      streamController.close();

      // Verify no data was inserted since no values were added
      final insertedData = await waitUntilInserted(testName);
      expect(insertedData.length, 1);

      // Clean up
      collector.stopCollect(entry);
    });

    test('collectImpl should handle complex DynamicValue objects', () async {
      // Arrange
      const testName = 'complex_test2';
      final complexValue = DynamicValue.fromMap(
        LinkedHashMap<String, DynamicValue>.from(
          {
            'string': DynamicValue(value: 'hello'),
            'number': DynamicValue(value: 123.45),
            'boolean': DynamicValue(value: false),
          },
        ),
      );
      final streamController = StreamController<DynamicValue>();

      // Act
      final entry = CollectEntry(key: testName, name: testName);
      await collector.collectEntryImpl(entry, streamController.stream,
          skipFirstSample: false);
      streamController.add(complexValue);

      // Assert - verify complex object was inserted correctly
      final insertedData = await waitUntilInserted(testName);

      expect(insertedData.length, 1);
      final insertedValue = insertedData[0].value;
      expect(insertedValue, isA<Map>());
      expect(insertedValue['string'], 'hello');
      expect(insertedValue['number'], 123.45);
      expect(insertedValue['boolean'], false);

      // Clean up
      streamController.close();
      collector.stopCollect(entry);
    });

    test(
        'collectImpl should respect sample interval and only collect latest value within interval',
        () async {
      // Arrange
      const testName = 'sampling_test';
      const sampleInterval = Duration(milliseconds: 100);

      final values = [
        DynamicValue(value: 'value1'),
        DynamicValue(value: 'value2'),
        DynamicValue(value: 'value3'),
      ];
      final streamController = StreamController<DynamicValue>();

      // Act - Create collection with sample interval
      final entry = CollectEntry(
        key: testName,
        name: testName,
        sampleInterval: sampleInterval,
      );
      await collector.collectEntryImpl(entry, streamController.stream,
          skipFirstSample: false);

      // Add first value
      streamController.add(values[0]);
      await Future.delayed(sampleInterval * 1.5); // wait long enough

      // Add second value (should be ignored due to sample interval)
      streamController.add(values[1]);
      await Future.delayed(const Duration(milliseconds: 1));

      // Add third value (should be ignored due to sample interval)
      streamController.add(values[2]);
      await Future.delayed(const Duration(milliseconds: 1));

      // Add another value after the interval (should be collected)
      streamController.add(DynamicValue(value: 'value4'));

      // Wait for async processing
      await Future.delayed(sampleInterval * 1);

      // Assert - Only the first and last values should be collected
      final insertedData = await waitUntilInserted(testName);

      // With proper sampling implementation, we should only see 2 values:
      // 1. The first value (immediately collected)
      // 2. The last value after the sample interval
      expect(insertedData.length, 2);
      expect(insertedData[0].value, 'value1'); // First value
      expect(insertedData[1].value, 'value4'); // Last value after interval

      // The intermediate values (value2, value3) should be dropped due to sampling

      // Clean up
      streamController.close();
      collector.stopCollect(entry);
    }, skip: true); // flaky test

    test('collectStream should return historical data initially', () async {
      // Arrange
      const testKey = 'historical_test';
      const testName = 'historical_test';
      final entry = CollectEntry(key: testKey, name: testName);

      database.registerRetentionPolicy(
          testName,
          const RetentionPolicy(
            dropAfter: Duration(days: 1),
          ));

      // Insert some historical data
      final historicalData = [
        TimeseriesData<dynamic>('value1',
            DateTime.now().toUtc().subtract(const Duration(hours: 2))),
        TimeseriesData<dynamic>('value2',
            DateTime.now().toUtc().subtract(const Duration(hours: 1))),
        TimeseriesData<dynamic>('value3',
            DateTime.now().toUtc().subtract(const Duration(minutes: 30))),
      ];

      for (final data in historicalData) {
        await database.insertTimeseriesData(testName, data.time, data.value);
      }

      await database.flush();

      // Act
      await collector.collectEntryImpl(entry, const Stream.empty());
      final stream =
          collector.collectStream(testKey, since: const Duration(hours: 3));

      // Assert
      final result = await stream.first;
      expect(result.length, 3);
      expect(result[0].value, 'value1');
      expect(result[1].value, 'value2');
      expect(result[2].value, 'value3');

      // Clean up
      collector.stopCollect(entry);
    });

    test('collectStream should combine historical and real-time data',
        () async {
      // Arrange
      const testKey = 'combined_test';
      const testName = 'combined_test';
      final entry = CollectEntry(key: testKey, name: testName);
      final streamController = StreamController<DynamicValue>();

      database.registerRetentionPolicy(
          testName,
          const RetentionPolicy(
            dropAfter: Duration(days: 1),
          ));

      // Insert historical data
      final historicalData = [
        TimeseriesData<dynamic>('historical1',
            DateTime.now().toUtc().subtract(const Duration(hours: 1))),
        TimeseriesData<dynamic>('historical2',
            DateTime.now().toUtc().subtract(const Duration(minutes: 30))),
      ];

      for (final data in historicalData) {
        await database.insertTimeseriesData(testName, data.time, data.value);
      }

      await database.flush();

      // Act
      await collector.collectEntryImpl(entry, streamController.stream);
      final stream =
          collector.collectStream(testKey, since: const Duration(hours: 2));

      // Latest emission, not emission ordinals — see the note on the complex
      // DynamicValue test above.
      List<dynamic>? latest;
      final sub = stream.listen((data) => latest = data);
      addTearDown(sub.cancel);

      await eventually(() => latest, hasLength(2),
          reason: 'the stream replays both historical rows first');
      expect(latest![0].value, 'historical1');
      expect(latest![1].value, 'historical2');

      streamController.add(DynamicValue(value: 'realtime1'));

      await eventually(() => latest, hasLength(3),
          reason: 'the live sample joins the two historical ones');
      expect(latest![0].value, 'historical1');
      expect(latest![1].value, 'historical2');
      expect(latest![2].value, 'realtime1');
      // Clean up
      streamController.close();
      collector.stopCollect(entry);
    });

    test('collectStream should respect since parameter for historical data',
        () async {
      // Arrange
      const testKey = 'since_test';
      const testName = 'since_test';
      final entry = CollectEntry(key: testKey, name: testName);

      database.registerRetentionPolicy(
          testName,
          const RetentionPolicy(
            dropAfter: Duration(days: 1),
          ));

      // Insert data with different timestamps
      final now = DateTime.now().toUtc();
      final data = [
        TimeseriesData<dynamic>('old', now.subtract(const Duration(hours: 3))),
        TimeseriesData<dynamic>(
            'recent', now.subtract(const Duration(hours: 1))),
        TimeseriesData<dynamic>(
            'very_recent', now.subtract(const Duration(minutes: 30))),
      ];

      for (final d in data) {
        await database.insertTimeseriesData(testName, d.time, d.value);
      }

      await database.flush();

      // Act - query with since = 2 hours
      await collector.collectEntryImpl(entry, Stream.empty());
      final stream =
          collector.collectStream(testKey, since: const Duration(hours: 2));

      // Assert - should only get data from last 2 hours
      final result = await stream.first;
      expect(result.length, 2);
      expect(result[0].value, 'recent');
      expect(result[1].value, 'very_recent');

      // Clean up
      collector.stopCollect(entry);
    });

    test('collectStream should handle multiple real-time updates', () async {
      // Arrange
      const testKey = 'multiple_updates_test';
      const testName = 'multiple_updates_test';
      final entry = CollectEntry(key: testKey, name: testName);
      final streamController = StreamController<DynamicValue>();

      database.registerRetentionPolicy(
          testName,
          const RetentionPolicy(
            dropAfter: Duration(days: 1),
          ));

      // Insert historical data
      await database.insertTimeseriesData(
          testName,
          DateTime.now().toUtc().subtract(const Duration(hours: 1)),
          'historical');

      await database.flush();

      // Act
      await collector.collectEntryImpl(entry, streamController.stream);
      final stream =
          collector.collectStream(testKey, since: const Duration(hours: 2));

      // Latest emission, not emission ordinals — see the note on the complex
      // DynamicValue test above.
      List<dynamic>? latest;
      final sub = stream.listen((data) => latest = data);
      addTearDown(sub.cancel);

      await eventually(() => latest, hasLength(1),
          reason: 'the stream replays the historical row first');
      expect(latest![0].value, 'historical');

      // Each update is added only once the previous one has arrived, so the
      // accumulated list is asserted at every step rather than only at the
      // end — that is what makes this test about *accumulation* and not just
      // about the final count.
      var expected = <String>['historical'];
      for (final update in ['update1', 'update2', 'update3']) {
        streamController.add(DynamicValue(value: update));
        expected = [...expected, update];

        await eventually(() => latest, hasLength(expected.length),
            reason: 'expected the stream to accumulate $expected');
        expect(
          [for (final d in latest!) d.value],
          expected,
        );
      }

      // Clean up
      streamController.close();
      collector.stopCollect(entry);
    });

    test('collectStream should handle complex DynamicValue objects', () async {
      // Arrange
      const testKey = 'complex_test';
      const testName = 'complex_test';
      final entry = CollectEntry(key: testKey, name: testName);
      final streamController = StreamController<DynamicValue>();

      database.registerRetentionPolicy(
          testName,
          const RetentionPolicy(
            dropAfter: Duration(days: 1),
          ));

      // Insert historical complex data
      final complexHistoricalData = {
        'temperature': 25.5,
        'humidity': 60.2,
        'pressure': 1013.25,
      };
      await database.insertTimeseriesData(
          testName,
          DateTime.now().toUtc().subtract(const Duration(hours: 1)),
          complexHistoricalData);

      await database.flush();

      // Act
      await collector.collectEntryImpl(entry, streamController.stream);
      final stream =
          collector.collectStream(testKey, since: const Duration(hours: 2));

      // Hold the latest emission rather than asserting inside the listener.
      //
      // This test used to number the emissions and assert on the ordinal —
      // "the 1st emission has 1 row, the 2nd has 2". That coupled the
      // assertions to *how many times the stream happened to fire*, which is
      // not something the test controls: one extra frame (an empty initial
      // emission before the historical query resolves, a re-query, a
      // debounce boundary) shifted every expectation by one and CI failed
      // with "expected 1, actual 0" then "expected 2, actual 1".
      //
      // What the test actually means is "eventually the stream carries the
      // historical row, and eventually it carries both". Assert that, and the
      // emission count stops mattering. Asserting on the newest value also
      // moves the failure into the test body, where `expect` belongs — thrown
      // from inside a stream listener it is reported against whatever
      // happened to be running.
      List<dynamic>? latest;
      final sub = stream.listen((data) => latest = data);
      addTearDown(sub.cancel);

      // The historical row, once the initial DB query has resolved.
      await eventually(() => latest, hasLength(1),
          reason: 'the stream must first replay what was already in the table');
      expect(latest![0].value, complexHistoricalData);

      // Add complex real-time data
      final complexRealtimeData = DynamicValue.fromMap(
        LinkedHashMap<String, DynamicValue>.from({
          'temperature': DynamicValue(value: 26.0),
          'humidity': DynamicValue(value: 65.0),
          'pressure': DynamicValue(value: 1012.0),
        }),
      );
      streamController.add(complexRealtimeData);

      // And then the live one alongside it.
      await eventually(() => latest, hasLength(2),
          reason: 'the live sample must join the historical one');
      expect(latest![0].value, complexHistoricalData);
      expect(latest![1].value, isA<Map>());
      expect(latest![1].value['temperature'], 26.0);
      expect(latest![1].value['humidity'], 65.0);
      expect(latest![1].value['pressure'], 1012.0);

      // Clean up
      streamController.close();
      collector.stopCollect(entry);
    });

    test('collectStream should handle simple arrays of doubles', () async {
      // Arrange
      const testKey = 'array_doubles_test';
      const testName = 'array_doubles_test';
      final entry = CollectEntry(key: testKey, name: testName);
      final streamController = StreamController<DynamicValue>();

      database.registerRetentionPolicy(
          testName,
          const RetentionPolicy(
            dropAfter: Duration(days: 1),
          ));

      // Insert historical array data
      final historicalArrayData = [1.5, 2.7, 3.9, 4.2];
      await database.insertTimeseriesData(
          testName,
          DateTime.now().toUtc().subtract(const Duration(hours: 1)),
          historicalArrayData);

      await database.flush();

      // Act
      await collector.collectEntryImpl(entry, streamController.stream);
      final stream =
          collector.collectStream(testKey, since: const Duration(hours: 2));

      // Latest emission, not emission ordinals — see the note on the complex
      // DynamicValue test above.
      List<dynamic>? latest;
      final sub = stream.listen((data) => latest = data);
      addTearDown(sub.cancel);

      await eventually(() => latest, hasLength(1),
          reason: 'the stream replays the historical array first');
      expect(latest![0].value, historicalArrayData);

      // Add real-time array data
      final realtimeArrayData = DynamicValue.fromList([
        DynamicValue(value: 5.1),
        DynamicValue(value: 6.3),
        DynamicValue(value: 7.8),
        DynamicValue(value: 8.4),
      ]);
      streamController.add(realtimeArrayData);

      await eventually(() => latest, hasLength(2),
          reason: 'the live array joins the historical one');
      expect(latest![0].value, historicalArrayData);
      expect(latest![1].value, isA<List<dynamic>>());
      expect(latest![1].value, [5.1, 6.3, 7.8, 8.4]);
      // Clean up
      streamController.close();
      collector.stopCollect(entry);
    });

    test('collectStream should handle real-time stream errors', () async {
      // Arrange
      const testKey = 'stream_error_test';
      const testName = 'stream_error_test';
      final entry = CollectEntry(key: testKey, name: testName);
      final streamController = StreamController<DynamicValue>();

      database.registerRetentionPolicy(
          testName,
          const RetentionPolicy(
            dropAfter: Duration(days: 1),
          ));

      // Insert historical data
      await database.insertTimeseriesData(
          testName,
          DateTime.now().toUtc().subtract(const Duration(hours: 1)),
          'historical');

      await database.flush();

      // Act
      await collector.collectEntryImpl(entry, streamController.stream);
      final stream =
          collector.collectStream(testKey, since: const Duration(hours: 2));

      // Get initial data
      final initialData = await stream.first;
      expect(initialData.length, 1);
      expect(initialData[0].value, 'historical');

      // Add error to the stream
      streamController.addError(Exception('Stream error'));
      await Future.delayed(const Duration(milliseconds: 100));

      // Clean up
      streamController.close();
      collector.stopCollect(entry);
    });

    test('should collect data only when sample expression evaluates to true',
        () async {
      // Arrange
      const testKey = 'temperature_sensor';
      const testName = 'temperature_data';
      const conditionKey = 'system_running';

      // Create streams for the condition and data
      final conditionController = StreamController<DynamicValue>();
      final dataController = StreamController<DynamicValue>();

      // Stub the StateMan to return our test streams
      stateMan.addSubscription(
        key: conditionKey,
        subscription: conditionController.stream,
        firstValue: DynamicValue(value: false),
      );

      stateMan.addSubscription(
        key: testKey,
        subscription: dataController.stream,
        firstValue: DynamicValue(value: 25.0),
      );

      // Create sample expression: "system_running == true AND temperature_sensor > 20"
      final entry = CollectEntry(
        key: testKey,
        name: testName,
        sampleExpression: ExpressionConfig(
          value: Expression(formula: '$conditionKey == true AND $testKey > 20'),
        ),
      );

      // Act
      await collector.collectEntry(entry);

      // Register retention policy and insert random data to make sure the table is created
      database.registerRetentionPolicy(
          testName,
          const RetentionPolicy(
            dropAfter: Duration(days: 1),
          ));
      await database.insertTimeseriesData(
          testName, DateTime.now().toUtc(), 25.0);

      // Test 1: System not running, data should not be collected
      dataController.add(DynamicValue(value: 30.0));
      await Future.delayed(const Duration(milliseconds: 100));

      await database.flush();

      var insertedData =
          await waitUntilInserted(testName).timeout(const Duration(seconds: 5));
      expect(insertedData.length, 1,
          reason: 'Data should not be collected when system is not running');

      // Set to value that should not be collected
      dataController.add(DynamicValue(value: 19.0));
      await Future.delayed(const Duration(milliseconds: 100));

      // System starts, the data shouldnt be collected
      conditionController.add(DynamicValue(value: true));
      await Future.delayed(const Duration(milliseconds: 100));

      await database.flush();

      insertedData =
          await waitUntilInserted(testName).timeout(const Duration(seconds: 5));
      expect(insertedData.length, 1,
          reason:
              'Data should not be collected when system is running and the data is below 20');

      // BAAAAAM
      dataController.add(DynamicValue(value: 35.0));
      await database.flush();

      // Insert the same data again because the first value is skipped
      // That is because the first value is a value that we do not know when arrived,
      // the stream controller caches always the last value, so we skip the first value
      dataController.add(DynamicValue(value: 35.0));
      await Future.delayed(const Duration(milliseconds: 100));

      await database.flush();

      insertedData =
          await waitUntilInserted(testName, minCount: 2).timeout(const Duration(seconds: 5));
      expect(insertedData.length, 2,
          reason:
              'Data should be collected when system is running and the data is above 20');
      expect(insertedData[0].value, 25.0);
      expect(insertedData[1].value, 35.0);

      // Test 3: System stops running, data should not be collected
      conditionController.add(DynamicValue(value: false));
      await Future.delayed(const Duration(milliseconds: 100));

      insertedData =
          await waitUntilInserted(testName).timeout(const Duration(seconds: 5));
      expect(insertedData.length, 2,
          reason: 'Data should not be collected when system is not running');

      // Clean up
      conditionController.close();
      dataController.close();
      collector.stopCollect(entry);
    });
  });
}

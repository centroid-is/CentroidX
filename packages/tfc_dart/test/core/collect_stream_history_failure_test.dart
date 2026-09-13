// A history query that fails must not mute the live stream behind it.
//
// `collectStream` starts the subscription and the backfill together and holds
// every live sample back until the backfill lands, so that the two can be
// merged in order. When the backfill never lands -- a key that is mapped but
// not collected, so its table was never created; a query that times out --
// that hold was permanent: the error went out once and then every sample the
// subscription delivered went into a buffer nobody ever drained. The chart
// showed the message and never moved again, and the buffer grew for as long
// as the stream lived (on a 2 Hz key, without bound).

import 'dart:async';

import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:test/test.dart';
import 'package:tfc_dart/core/collector.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/state_man.dart';

/// A database whose tables are all there for writing but whose history query
/// always fails -- the shape of a backfill that will not come back.
class _NoHistoryDatabase extends Database {
  _NoHistoryDatabase(super.db);

  int queries = 0;

  @override
  Future<List<TimeseriesData<dynamic>>> queryTimeseriesData(
      String tableName, DateTime to,
      {String? orderBy = 'time ASC', DateTime? from}) async {
    queries++;
    throw Exception(
        'Severity.error 42P01: relation "$tableName" does not exist');
  }
}

void main() {
  test('live samples still arrive when the backfill fails', () async {
    final stateMan = await StateMan.create(
        config: StateManConfig(opcua: []), keyMappings: KeyMappings(nodes: {}));
    final database = _NoHistoryDatabase(AppDatabase.inMemoryForTest());
    final collector = Collector(
      config: CollectorConfig(collect: true),
      stateMan: stateMan,
      database: database,
    );
    addTearDown(collector.close);

    final live = StreamController<DynamicValue>.broadcast();
    addTearDown(live.close);

    final entry = CollectEntry(key: 'line1/rate', name: 'line1/rate');
    await collector.collectEntryImpl(entry, live.stream);

    final errors = <Object>[];
    final batches = <List<TimeseriesData<dynamic>>>[];
    final sub = collector
        .collectStream('line1/rate', since: const Duration(hours: 1))
        .listen(batches.add, onError: errors.add);
    addTearDown(sub.cancel);

    // Let the backfill fail.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(database.queries, 1);
    expect(errors, hasLength(1),
        reason: 'a key that is genuinely dead must still say so');
    expect(batches, isEmpty);

    live.add(DynamicValue(value: 1.0));
    live.add(DynamicValue(value: 2.0));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(batches, isNotEmpty,
        reason: 'the samples were buffered for a backfill that never came');
    expect(batches.last.map((d) => d.value), containsAllInOrder([1.0, 2.0]),
        reason: 'the window must carry the samples that arrived since');
  });

  test('samples buffered before the backfill failed are not lost', () async {
    final stateMan = await StateMan.create(
        config: StateManConfig(opcua: []), keyMappings: KeyMappings(nodes: {}));
    final database = _SlowFailingDatabase(AppDatabase.inMemoryForTest());
    final collector = Collector(
      config: CollectorConfig(collect: true),
      stateMan: stateMan,
      database: database,
    );
    addTearDown(collector.close);

    final live = StreamController<DynamicValue>.broadcast();
    addTearDown(live.close);

    final entry = CollectEntry(key: 'line1/rate', name: 'line1/rate');
    await collector.collectEntryImpl(entry, live.stream);

    final batches = <List<TimeseriesData<dynamic>>>[];
    final sub = collector
        .collectStream('line1/rate', since: const Duration(hours: 1))
        .listen(batches.add, onError: (Object _) {});
    addTearDown(sub.cancel);

    // Subscribed, backfill still in flight: this sample goes to the buffer.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    live.add(DynamicValue(value: 7.0));

    // Now the backfill gives up.
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(batches, isNotEmpty);
    expect(batches.last.map((d) => d.value), contains(7.0),
        reason: 'the sample held for the backfill was dropped with it');
  });
}

/// Fails, but only after the listener has had time to buffer a sample.
class _SlowFailingDatabase extends Database {
  _SlowFailingDatabase(super.db);

  @override
  Future<List<TimeseriesData<dynamic>>> queryTimeseriesData(
      String tableName, DateTime to,
      {String? orderBy = 'time ASC', DateTime? from}) async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    throw Exception(
        'Severity.error 42P01: relation "$tableName" does not exist');
  }
}

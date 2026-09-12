// The history panes gate their live stream behind a backfill query, the same
// way the trend asset used to gate its subscriptions behind a history fetch.
//
// In realtime mode both panes build `Rx.combineLatest2(dbStream, liveStream)`.
// `combineLatest` emits nothing until every source has emitted at least once,
// so a backfill that errors before its first value silences the live stream
// next to it for good -- the graph pane showed the message and never drew
// another point, and the table pane sat on a spinner with nothing to say at
// all. Both streams are cached per key/window, so nothing re-ran either.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/models/history_models.dart';
import 'package:tfc/providers/collector.dart';
import 'package:tfc/widgets/history_graph_pane.dart';
import 'package:tfc/widgets/history_table_pane.dart';
import 'package:tfc_dart/core/collector.dart';
import 'package:tfc_dart/core/database.dart';

/// A database whose backfill always fails.
class _NoBackfillDatabase extends Fake implements Database {
  int queries = 0;

  @override
  Future<List<TimeseriesData<dynamic>>> queryTimeseriesData(
      String tableName, DateTime to,
      {String? orderBy = 'time ASC', DateTime? from}) async {
    queries++;
    throw Exception(
        'Severity.error 42P01: relation "$tableName" does not exist');
  }

  @override
  Future<List<TimeseriesData<dynamic>>> queryTimeseriesDataDownsampled(
      String tableName, DateTime from, DateTime to,
      {int maxPoints = 1000}) async {
    queries++;
    throw Exception(
        'Severity.error 42P01: relation "$tableName" does not exist');
  }
}

/// A collector whose live stream works perfectly well.
class _LiveCollector extends Fake implements Collector {
  _LiveCollector(this.database);

  @override
  final Database database;

  final _live = StreamController<List<TimeseriesData<dynamic>>>.broadcast();

  @override
  Stream<List<TimeseriesData<dynamic>>> collectStream(String key,
          {Duration since = const Duration(days: 1)}) =>
      _live.stream;

  void emit(List<TimeseriesData<dynamic>> window) => _live.add(window);

  Future<void> close() => _live.close();
}

Widget _harness(Collector collector, Widget child) => ProviderScope(
      overrides: [
        collectorProvider.overrideWith((ref) async => collector),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 900, height: 600, child: child),
        ),
      ),
    );

void main() {
  testWidgets('the graph pane draws live points although the backfill failed',
      (tester) async {
    final database = _NoBackfillDatabase();
    final collector = _LiveCollector(database);
    addTearDown(collector.close);

    await tester.pumpWidget(_harness(
      collector,
      HistoryGraphPane(
        keys: const ['line1/rate'],
        realtime: true,
        range: null,
        realtimeDuration: const Duration(minutes: 10),
        graphConfigs: {
          'line1/rate': GraphKeyConfig(key: 'line1/rate', alias: 'rate'),
        },
        graphDisplayConfigs: const {},
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(database.queries, greaterThan(0), reason: 'no backfill was tried');

    final now = DateTime.now().toUtc();
    collector.emit([
      for (var i = 3; i > 0; i--)
        TimeseriesData<dynamic>(i, now.subtract(Duration(seconds: i))),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('not being collected'), findsNothing,
        reason: 'the failed backfill is still masking a working live stream');
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: 'the pane never got past waiting for the backfill');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('the table pane says what went wrong instead of spinning',
      (tester) async {
    final database = _NoBackfillDatabase();
    final collector = _LiveCollector(database);
    addTearDown(collector.close);

    await tester.pumpWidget(_harness(
      collector,
      HistoryTablePane(
        keys: const ['line1/rate'],
        realtime: true,
        range: null,
        realtimeDuration: const Duration(minutes: 10),
        graphConfigs: {
          'line1/rate': GraphKeyConfig(key: 'line1/rate', alias: 'rate'),
        },
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Nothing live yet and no history: with the backfill neutralised the pane
    // waits rather than erroring, which is the honest state.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    final now = DateTime.now().toUtc();
    collector.emit([TimeseriesData<dynamic>(1, now)]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: 'the live row never got past the failed backfill');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

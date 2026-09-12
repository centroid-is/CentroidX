// A trend that cannot load its history is not a trend that is broken.
//
// Live points do not come out of the history query at all -- they arrive on
// the table's change notifications, which `_init` only ever set up *after*
// the history had come back. So one failed query killed the live feed for the
// life of the widget: the chart put up a message and never moved again, even
// though its key was producing values the whole time. The only way back was a
// rebuild or a config edit, and a pane trend tile has neither.
//
// The shape of the failure that triggered it is a key that is mapped but not
// collected: the collector never created the table, so the query throws. With
// no table there is no trigger to listen on either, so that case is still a
// dead chart and still says so. What must not happen is the other cases --
// a backfill that times out, a downsample that will not run, one line of
// three whose table is missing -- taking the live feed with them.

import 'dart:async';
import 'dart:convert' show jsonEncode;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/graph.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/widgets/graph.dart' show GraphType;
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/state_man.dart';

// ---------------------------------------------------------------------------
// Doubles
// ---------------------------------------------------------------------------

/// LISTEN/NOTIFY stand-in.
///
/// [missingTables] are tables that do not exist: `enableNotificationChannel`
/// creates a trigger ON the table, so against a missing one it throws the
/// same 42P01 the history query does. Everything else gets a channel and a
/// controller the test can push rows into.
class _FakeAppDatabase extends Fake implements AppDatabase {
  _FakeAppDatabase({this.missingTables = const {}});

  Set<String> missingTables;

  /// Tables a channel was asked for, in order, successes and failures alike.
  final List<String> channelsAsked = [];

  final Map<String, StreamController<String>> _channels = {};

  /// How many listeners are attached to [table]'s channel right now.
  int listenerCount(String table) =>
      (_channels['${table}_notify']?.hasListener ?? false) ? 1 : 0;

  bool hasChannel(String table) => _channels.containsKey('${table}_notify');

  @override
  Future<String> enableNotificationChannel(String tableName) async {
    channelsAsked.add(tableName);
    if (missingTables.contains(tableName)) {
      throw Exception(
          'Severity.error 42P01: relation "$tableName" does not exist');
    }
    final channel = '${tableName}_notify';
    _channels.putIfAbsent(
        channel, () => StreamController<String>.broadcast(sync: true));
    return channel;
  }

  @override
  Stream<String> listenToChannel(String channelName) =>
      _channels
          .putIfAbsent(
              channelName, () => StreamController<String>.broadcast(sync: true))
          .stream;

  /// One inserted row, as the trigger would send it.
  void emitRow(String table, DateTime time, Object value) {
    _channels['${table}_notify']?.add(jsonEncode({
      'action': 'INSERT',
      'data': {'time': time.toIso8601String(), 'value': value},
    }));
  }
}

/// Answers history per table. A table in [missingTables] throws; anything
/// else returns whatever [rows] holds for it.
class _FakeDatabase extends Fake implements Database {
  _FakeDatabase({Set<String> missingTables = const {}, this.rows = const {}})
      : db = _FakeAppDatabase(missingTables: missingTables);

  @override
  final _FakeAppDatabase db;

  Map<String, List<TimeseriesData<dynamic>>> rows;

  /// Queries that reached a table, in order -- so a test can prove a retry
  /// happened without reaching into the widget.
  final List<String> queried = [];

  Set<String> get missingTables => db.missingTables;
  set missingTables(Set<String> value) => db.missingTables = value;

  @override
  Future<List<TimeseriesData<dynamic>>> queryTimeseriesData(
      String tableName, DateTime to,
      {String? orderBy = 'time ASC', DateTime? from}) async {
    queried.add(tableName);
    if (missingTables.contains(tableName)) {
      throw Exception(
          'Severity.error 42P01: relation "$tableName" does not exist');
    }
    return rows[tableName] ?? const [];
  }
}

class _FakeStateMan extends Fake implements StateMan {
  final _subs = StreamController<Map<String, String>>.broadcast();

  @override
  String resolveKey(String key) => key;

  @override
  String? getSubstitution(String key) => null;

  @override
  Stream<Map<String, String>> get substitutionsChanged => _subs.stream;
}

Widget _harness(Database database, Widget child) => ProviderScope(
      overrides: [
        databaseProvider.overrideWith((ref) async => database),
        stateManProvider.overrideWith((ref) async => _FakeStateMan()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 900, height: 600, child: child),
        ),
      ),
    );

GraphAssetConfig _config(List<String> keys) => GraphAssetConfig(
      graphType: GraphType.timeseries,
      primarySeries: [
        for (final key in keys) GraphSeriesConfig(key: key, label: key),
      ],
      timeWindowMinutes: const Duration(minutes: 10),
    );

/// Lets the init's awaits resolve. `pumpAndSettle` cannot be used: the chart
/// runs a 1 Hz throttle timer for as long as it is mounted.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

/// Drops the widget so its timers and subscriptions go with it;
/// flutter_test fails a test that leaves one behind.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

void main() {
  testWidgets('a history query that throws still leaves the chart subscribed',
      (tester) async {
    final database = _FakeDatabase(missingTables: {'line1/rate'});

    await tester
        .pumpWidget(_harness(database, GraphAsset(_config(['line1/rate']))));
    await _settle(tester);

    expect(database.queried, contains('line1/rate'),
        reason: 'the history was never asked for');
    expect(database.db.channelsAsked, contains('line1/rate'),
        reason: 'the failed history query skipped the live subscription -- '
            'this is the bug');

    await _unmount(tester);
  });

  testWidgets('live points draw although the history never loaded',
      (tester) async {
    // The table exists and is being written to; only the backfill fails --
    // a query that timed out, a downsample that would not run.
    final failing = _FailHistoryOnly();

    await tester
        .pumpWidget(_harness(failing, GraphAsset(_config(['line1/rate']))));
    await _settle(tester);

    // Nothing drawn yet, so the notice stands in for the footer -- and it is
    // a notice, not the error panel.
    expect(find.textContaining('No stored history'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off), findsNothing,
        reason: 'a chart with a live feed is not a dead chart');

    failing.db.emitRow('line1/rate', DateTime.now(), 42);
    // The chart batches live points at 1 Hz.
    await tester.pump(const Duration(milliseconds: 1100));

    expect(find.textContaining('No stored history'), findsNothing,
        reason: 'the live point never reached the chart');

    await _unmount(tester);
  });

  testWidgets('one missing table does not blank the lines that do have one',
      (tester) async {
    final now = DateTime.now();
    final database = _FakeDatabase(
      missingTables: {'line2/rate'},
      rows: {
        'line1/rate': [
          for (var i = 10; i > 0; i--)
            TimeseriesData<dynamic>(i, now.subtract(Duration(seconds: i))),
        ],
      },
    );

    await tester.pumpWidget(_harness(
        database, GraphAsset(_config(['line1/rate', 'line2/rate']))));
    await _settle(tester);

    expect(find.byIcon(Icons.cloud_off), findsNothing,
        reason: 'one missing table replaced a chart that had ten points');
    // The working line is drawn, so there is no empty-chart footer at all.
    expect(find.textContaining('No stored history'), findsNothing);
    expect(database.db.channelsAsked, contains('line1/rate'),
        reason: 'the good line lost its live feed to the bad one');

    await _unmount(tester);
  });

  testWidgets('no history and no feed is still an error, in operator words',
      (tester) async {
    // The reported trigger: mapped but not collected. With no table there is
    // neither a row to read nor a trigger to listen on, so this chart really
    // is dead and must keep saying so.
    final database = _FakeDatabase(missingTables: {'line1/rate'});

    await tester
        .pumpWidget(_harness(database, GraphAsset(_config(['line1/rate']))));
    await _settle(tester);

    expect(find.byIcon(Icons.cloud_off), findsOneWidget);
    expect(find.textContaining('not being collected'), findsOneWidget);

    await _unmount(tester);
  });

  testWidgets('a table that appears later is picked up by the bounded retry',
      (tester) async {
    final now = DateTime.now();
    final database = _FakeDatabase(missingTables: {'line1/rate'});

    await tester
        .pumpWidget(_harness(database, GraphAsset(_config(['line1/rate']))));
    await _settle(tester);
    expect(find.byIcon(Icons.cloud_off), findsOneWidget);
    final asked = database.queried.length;

    // Collection is switched on: the table exists from here.
    database.missingTables = const {};
    database.rows = {
      'line1/rate': [
        for (var i = 5; i > 0; i--)
          TimeseriesData<dynamic>(i, now.subtract(Duration(seconds: i))),
      ],
    };

    // First retry is 30 s out.
    await tester.pump(const Duration(seconds: 31));
    await _settle(tester);

    expect(database.queried.length, greaterThan(asked),
        reason: 'nothing ever asked again');
    expect(find.byIcon(Icons.cloud_off), findsNothing,
        reason: 'the chart stayed on its message after the table appeared');
    expect(database.db.channelsAsked, contains('line1/rate'));
    expect(database.db.hasChannel('line1/rate'), isTrue,
        reason: 'the late table never got its live feed');

    await _unmount(tester);
  });

  testWidgets('the retry gives up rather than polling for the whole shift',
      (tester) async {
    final database = _FakeDatabase(missingTables: {'line1/rate'});

    await tester
        .pumpWidget(_harness(database, GraphAsset(_config(['line1/rate']))));
    await _settle(tester);

    // 30 s, 2 min, 5 min -- and then no more, however long the page is left
    // open.
    for (final _ in const [1, 2, 3]) {
      await tester.pump(const Duration(minutes: 6));
      await _settle(tester);
    }
    final settled = database.queried.length;
    expect(settled, 4, reason: 'the first fetch plus exactly three retries');

    await tester.pump(const Duration(minutes: 30));
    await _settle(tester);
    expect(database.queried.length, settled,
        reason: 'the chart is polling the database forever');

    await _unmount(tester);
  });

  testWidgets('unmounting drops the live subscription', (tester) async {
    final database = _FakeDatabase();

    await tester
        .pumpWidget(_harness(database, GraphAsset(_config(['line1/rate']))));
    await _settle(tester);
    expect(database.db.listenerCount('line1/rate'), 1);

    await _unmount(tester);
    expect(database.db.listenerCount('line1/rate'), 0,
        reason: 'the chart left its channel subscription behind');
  });
}

/// A database whose history query always fails but whose notification channel
/// works -- the transient-failure case, where the table is there and being
/// written to but the backfill will not come back.
class _FailHistoryOnly extends Fake implements Database {
  @override
  final _FakeAppDatabase db = _FakeAppDatabase();

  @override
  Future<List<TimeseriesData<dynamic>>> queryTimeseriesData(
      String tableName, DateTime to,
      {String? orderBy = 'time ASC', DateTime? from}) async {
    throw TimeoutException('history query timed out');
  }
}

/// Shared fakes for pumping the real [HistoryViewBody] in widget tests.
///
/// Until now the history page was only tested through hand-copied layout
/// replicas, because the monolithic page demanded a live StateMan / OPC UA
/// stack. The page needs three providers:
///
///  - [stateManProvider]   → key list + which keys are collected
///  - [databaseProvider]   → saved views/periods (real in-memory drift db)
///                           and the retention horizon
///  - [collectorProvider]  → timeseries data for the graph and table panes
///
/// The [Database] wrapper is faked rather than constructed: the real wrapper
/// starts flush timers and connection-health machinery that trip the
/// pending-timer check in widget tests, and the page only ever touches
/// `.db` (the drift [AppDatabase]) plus the two timeseries queries.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc_dart/core/collector.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/preferences.dart' show InMemoryPreferences;
import 'package:tfc_dart/core/state_man.dart';

import 'package:tfc/pages/history_view.dart';
import 'package:tfc/providers/collector.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/state_man.dart';

class FakeHistoryStateMan extends Fake implements StateMan {
  FakeHistoryStateMan(this.keyMappings);

  @override
  final KeyMappings keyMappings;

  @override
  List<String> get keys => keyMappings.nodes.keys.toList();
}

class FakeHistoryDatabase extends Fake implements Database {
  FakeHistoryDatabase(this.db, this.samples);

  @override
  final AppDatabase db;

  final Map<String, List<TimeseriesData<dynamic>>> samples;

  @override
  Future<List<TimeseriesData<dynamic>>> queryTimeseriesData(
          String tableName, DateTime to,
          {String? orderBy = 'time ASC', DateTime? from}) async =>
      samples[tableName] ?? const [];

  @override
  Future<List<TimeseriesData<dynamic>>> queryTimeseriesDataDownsampled(
          String tableName, DateTime from, DateTime to,
          {int maxPoints = 1000}) async =>
      samples[tableName] ?? const [];
}

class FakeHistoryCollector extends Fake implements Collector {
  FakeHistoryCollector(this.database, this.samples);

  @override
  final Database database;

  final Map<String, List<TimeseriesData<dynamic>>> samples;

  @override
  Stream<List<TimeseriesData<dynamic>>> collectStream(String key,
          {Duration since = const Duration(days: 1)}) =>
      Stream.value(samples[key] ?? const []);
}

/// Keys under two top-level folders. line1's three keys are collected,
/// line2's key is not — so the default "Only collected" filter has something
/// to hide.
KeyMappings historyKeyMappings() {
  KeyMappingEntry collected(String key) => KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(namespace: 2, identifier: key)
          ..serverAlias = 'main',
        collect: CollectEntry(
          key: key,
          sampleInterval: const Duration(seconds: 1),
          retention: const RetentionPolicy(
            dropAfter: Duration(days: 30),
            scheduleInterval: null,
          ),
        ),
      );
  return KeyMappings(nodes: {
    'line1.motor.speed': collected('line1.motor.speed'),
    'line1.motor.running': collected('line1.motor.running'),
    'line1.temperature': collected('line1.temperature'),
    'line2.pressure': KeyMappingEntry(
      opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'line2.pressure')
        ..serverAlias = 'main',
    ),
  });
}

/// An in-memory drift database; closed automatically at test teardown.
AppDatabase inMemoryAppDatabase() {
  final appDb = AppDatabase.inMemoryForTest();
  addTearDown(() async => appDb.close());
  return appDb;
}

Widget buildHistoryView({
  required KeyMappings keyMappings,
  required AppDatabase appDb,
  Map<String, List<TimeseriesData<dynamic>>> samples = const {},
  ThemeData? theme,
  bool initialRealtime = true,
  DateTimeRange? initialRange,
}) {
  final fakeDb = FakeHistoryDatabase(appDb, samples);
  return ProviderScope(
    overrides: [
      stateManProvider
          .overrideWith((ref) async => FakeHistoryStateMan(keyMappings)),
      databaseProvider.overrideWith((ref) async => fakeDb),
      // The device-local store: `historyViewsProvider` and
      // `timeseriesSourceProvider` consult the transport row before they
      // decide where saved views and history come from, and an empty
      // in-memory store reads as direct mode — this harness's station.
      localPreferencesProvider.overrideWithValue(InMemoryPreferences()),
      collectorProvider
          .overrideWith((ref) async => FakeHistoryCollector(fakeDb, samples)),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: Scaffold(
        body: HistoryViewBody(
          initialRealtime: initialRealtime,
          initialRange: initialRange,
        ),
      ),
    ),
  );
}

/// Pumps frames without requiring animations to settle — the graph pane can
/// hold an indeterminate spinner that starves pumpAndSettle.
Future<void> settleHistory(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Expands [folder] in the key tree by tapping its header row.
Future<void> expandFolder(WidgetTester tester, String folder) async {
  await tester.tap(find.text(folder));
  await settleHistory(tester);
}

/// Ticks the leaf [leafName] (last key segment) in the tree.
Future<void> tickKey(WidgetTester tester, String leafName) async {
  await tester.tap(find.text(leafName));
  await settleHistory(tester);
}

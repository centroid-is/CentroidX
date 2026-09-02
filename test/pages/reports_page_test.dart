import 'package:beamer/beamer.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/pages/reports_page.dart';
import 'package:tfc/providers/alarm.dart';
import 'package:tfc/providers/report.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_dart/tfc_dart.dart' hide KeyMappings, StateMan;

class _Db extends AppDatabase {
  _Db() : super.forTest(DatabaseConfig(), NativeDatabase.memory());
}

class _FakeAlarmMan implements AlarmMan {
  @override
  Stream<Set<AlarmActive>> activeAlarms() => Stream.value(const {});

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeStateMan implements StateMan {
  @override
  String resolveKey(String key) => key;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Wednesday mid-morning: inside the Day shift of the test calendar.
final _clock = DateTime(2026, 9, 2, 10);

void main() {
  late _Db db;
  late ReportStore store;
  late ReportEngine engine;

  setUp(() async {
    db = _Db();
    store = ReportStore(db, isPostgres: false);
    engine = ReportEngine(db, isPostgres: false);

    await db.customStatement(
        'CREATE TABLE "line.throughput" ("value" REAL, "time" TEXT)');
    await db.customStatement(
        'INSERT INTO "line.throughput" ("time", "value") VALUES (?, ?)', [
      DateTime(2026, 9, 2, 8).toUtc().toIso8601String(),
      950.0,
    ]);

    await store.saveShifts(ShiftManConfig(shifts: [
      ShiftDef(name: 'Day', startMinutes: 7 * 60, durationMinutes: 8 * 60),
      ShiftDef(
          name: 'Night', startMinutes: 23 * 60, durationMinutes: 8 * 60),
    ]));

    final registry = RouteRegistry();
    registry.menuItems.clear();
    registry.addMenuItem(
        const MenuItem(label: 'Home', path: '/', icon: Icons.home));
    registry.addMenuItem(
        const MenuItem(label: 'Reports', path: '/reports', icon: Icons.summarize));
  });

  tearDown(() async {
    RouteRegistry().menuItems.clear();
    await db.close();
  });

  Future<void> pump(WidgetTester tester) async {
    final delegate = BeamerDelegate(
      locationBuilder: RoutesLocationBuilder(routes: {
        '/': (context, state, data) => BeamPage(
              key: const ValueKey('/'),
              title: 'Reports',
              child: ReportsPage(debugClock: _clock),
            ),
      }).call,
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        reportStoreProvider.overrideWithValue(store),
        reportEngineProvider.overrideWithValue(engine),
        alarmManProvider.overrideWith((ref) async => _FakeAlarmMan()),
        stateManProvider.overrideWith((ref) async => _FakeStateMan()),
      ],
      child: BeamerProvider(
        routerDelegate: delegate,
        child: MaterialApp.router(
          routerDelegate: delegate,
          routeInformationParser: BeamerParser(),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('no definitions: the empty state invites the editor',
      (tester) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('reports-empty')), findsOneWidget);
    expect(find.text('No reports defined yet'), findsOneWidget);
  });

  testWidgets('a shift report generates and navigates backwards',
      (tester) async {
    await store.saveReports(ReportManConfig(reports: [
      ReportConfig(id: 'r1', name: 'Shift report', sections: [
        KpiSectionConfig(metrics: [
          ReportMetricConfig(
              key: 'line.throughput',
              label: 'Rate',
              aggregate: ReportAggregate.last),
        ]),
        TextSectionConfig(title: 'Notes', text: 'hello'),
      ]),
    ]));

    await pump(tester);

    // Current shift: Wednesday's Day shift, still running at the clock.
    expect(find.textContaining('Day 2026-09-02'), findsOneWidget);
    expect(find.text('Rate'), findsOneWidget);
    expect(find.text('950.0'), findsOneWidget);
    expect(find.text('hello'), findsOneWidget);
    expect(find.text('So far'), findsOneWidget);

    // One step back is Tuesday's Night shift, closed — no "so far" chip.
    await tester.tap(find.byTooltip('Previous'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Night 2026-09-01'), findsOneWidget);
    expect(find.text('So far'), findsNothing);

    // Forward returns to the current shift.
    await tester.tap(find.byTooltip('Next'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Day 2026-09-02'), findsOneWidget);
  });

  testWidgets('a day report without shifts still resolves', (tester) async {
    await store.saveShifts(ShiftManConfig());
    await store.saveReports(ReportManConfig(reports: [
      ReportConfig(
          id: 'r1',
          name: 'Daily',
          range: ReportRangeKind.day,
          sections: [TextSectionConfig(text: 'daily body')]),
    ]));
    await pump(tester);
    expect(find.textContaining('Today'), findsOneWidget);
    expect(find.text('daily body'), findsOneWidget);
  });

  testWidgets('a shift report with no calendar falls back to days',
      (tester) async {
    await store.saveShifts(ShiftManConfig());
    await store.saveReports(ReportManConfig(reports: [
      ReportConfig(
          id: 'r1',
          name: 'Shift report',
          sections: [TextSectionConfig(text: 'body')]),
    ]));
    await pump(tester);
    expect(find.textContaining('No shifts configured'), findsOneWidget);
    expect(find.text('body'), findsOneWidget);
  });
}

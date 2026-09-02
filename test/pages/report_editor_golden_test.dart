/// Goldens of the report editor over the same demo configuration the
/// report-view goldens render: the shift calendar card with a three-shift
/// pattern, and the packing-hall report expanded so every section editor —
/// KPI metrics, table rows, chart series, alarm/downtime, text — is visible.
///
/// To update:
///   flutter test test/pages/report_editor_golden_test.dart --update-goldens
@Tags(['golden'])
library;

import 'dart:io' show File, Platform;
import 'dart:typed_data' show ByteData;

import 'package:beamer/beamer.dart';
import 'package:clock/clock.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/pages/report_editor.dart';
import 'package:tfc/providers/report.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/theme.dart' show muted;
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_dart/tfc_dart.dart' hide KeyMappings, StateMan;

import '../helpers/golden_tolerance.dart';

class _Db extends AppDatabase {
  _Db() : super.forTest(DatabaseConfig(), NativeDatabase.memory());
}

class _FakeStateMan implements StateMan {
  /// Collected keys so the key autocomplete fields have real content.
  @override
  final KeyMappings keyMappings = KeyMappings(nodes: {
    for (final spb in ['SPB01', 'SPB02', 'SPB03'])
      '$spb.BoxCounter':
          KeyMappingEntry(collect: CollectEntry(key: '$spb.BoxCounter')),
    for (final cn in ['CN04', 'CN07'])
      'Line3.$cn.drive': KeyMappingEntry(
          collect: CollectEntry(
              key: 'Line3.$cn.drive',
              sampleMembers: ['stat.speed', 'stat.current'])),
  });

  @override
  String resolveKey(String key) => key;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The configuration whose *rendered output* is the report_view golden — so
/// the two golden pairs read as before/after of the same report.
ShiftManConfig _shifts() => ShiftManConfig(shifts: [
      ShiftDef(name: 'Day', startMinutes: 7 * 60, durationMinutes: 8 * 60),
      ShiftDef(
          name: 'Evening', startMinutes: 15 * 60, durationMinutes: 8 * 60),
      ShiftDef(
          name: 'Night',
          startMinutes: 23 * 60,
          durationMinutes: 8 * 60,
          weekdays: [
            DateTime.monday,
            DateTime.tuesday,
            DateTime.wednesday,
            DateTime.thursday,
            DateTime.friday,
          ]),
    ]);

ReportManConfig _reports() => ReportManConfig(reports: [
      ReportConfig(
        id: 'packing-shift',
        name: 'Packing hall shift report',
        description: 'Per-shift production, drives, alarms and downtime',
        sections: [
          KpiSectionConfig(metrics: [
            // The multi-key fold: three SpeedBatchers summed into one figure.
            ReportMetricConfig(
                key: 'SPB01.BoxCounter',
                additionalKeys: ['SPB02.BoxCounter', 'SPB03.BoxCounter'],
                label: 'Produced (all lines)',
                aggregate: ReportAggregate.delta,
                unit: 'boxes',
                decimals: 0),
            ReportMetricConfig(
                key: 'SPB01.BoxCounter',
                member: 'rate',
                label: 'Throughput',
                aggregate: ReportAggregate.timeWeightedMean,
                unit: 'boxes/h'),
            ReportMetricConfig(
                key: 'SPB01.Multivac.Run',
                label: 'Line running',
                aggregate: ReportAggregate.durationTrue),
          ]),
          TableSectionConfig(
            title: 'Drives',
            rows: [
              TableRowConfig(
                  key: 'Line3.CN04.drive',
                  member: 'stat.speed',
                  label: 'CN04 speed',
                  unit: 'Hz'),
              TableRowConfig(
                  key: 'Line3.CN07.drive',
                  member: 'stat.speed',
                  label: 'CN07 speed',
                  unit: 'Hz'),
            ],
          ),
          ChartSectionConfig(title: 'Throughput', series: [
            ReportChartSeriesConfig(
                key: 'SPB01.BoxCounter', member: 'rate', label: 'boxes/h'),
          ]),
          AlarmSummarySectionConfig(title: 'Alarms'),
          DowntimeSectionConfig(title: 'Downtime'),
          SqlSectionConfig(
              title: 'Per-product totals',
              query: 'SELECT product, count(*) AS boxes\n'
                  'FROM "SPB01.PackLog"\n'
                  'WHERE time > :from::timestamptz '
                  'AND time <= :to::timestamptz\n'
                  'GROUP BY product ORDER BY boxes DESC'),
          TextSectionConfig(
              title: 'Handover', text: 'Filled in by the outgoing shift.'),
        ],
      ),
    ]);

Future<void> _loadFonts() async {
  Future<void> load(String family, String path) async {
    final file = File(path);
    if (!file.existsSync()) return;
    await (FontLoader(family)
          ..addFont(Future.value(ByteData.view(file.readAsBytesSync().buffer))))
        .load();
  }

  await load('Roboto', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');
  await load('roboto-mono', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');

  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    await load('MaterialIcons',
        '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  }
}

void main() {
  useTolerantGoldenComparator(tolerance: 0.002);

  late _Db db;
  late ReportStore store;

  setUp(() async {
    db = _Db();
    store = ReportStore(db, isPostgres: false);
    await store.saveShifts(_shifts());
    await store.saveReports(_reports());
    final registry = RouteRegistry();
    registry.menuItems.clear();
    registry.addMenuItem(
        const MenuItem(label: 'Home', path: '/', icon: Icons.home));
    registry.addMenuItem(const MenuItem(
        label: 'Reports', path: '/reports', icon: Icons.summarize));
  });

  tearDown(() async {
    RouteRegistry().menuItems.clear();
    await db.close();
  });

  Future<void> pump(WidgetTester tester, {required bool dark}) async {
    await _loadFonts();
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final delegate = BeamerDelegate(
      locationBuilder: RoutesLocationBuilder(routes: {
        '/': (context, state, data) => const BeamPage(
              key: ValueKey('/'),
              title: 'Report Editor',
              child: ReportEditorPage(),
            ),
      }).call,
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        reportStoreProvider.overrideWithValue(store),
        stateManProvider.overrideWith((ref) async => _FakeStateMan()),
      ],
      child: BeamerProvider(
        routerDelegate: delegate,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: dark ? muted().$2 : muted().$1,
          routerDelegate: delegate,
          routeInformationParser: BeamerParser(),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Expand the report so the section editors are in the picture.
    await tester.tap(find.text('Packing hall shift report'));
    await tester.pumpAndSettle();
  }

  // The scaffold's header clock renders clock.now(); pinned so the golden
  // does not churn every run — see page_organizer_golden_test.dart.
  final goldenClock = Clock.fixed(DateTime(2026, 9, 1, 12, 20));

  group('report editor goldens',
      skip: !Platform.isMacOS ? 'Golden tests only run on macOS' : null, () {
    testWidgets('shift calendar and expanded report — light',
        (tester) => withClock(goldenClock, () async {
              await pump(tester, dark: false);
              await expectLater(find.byType(ReportEditorPage),
                  matchesGoldenFile('goldens/report_editor_light.png'));
            }));

    testWidgets('shift calendar and expanded report — dark',
        (tester) => withClock(goldenClock, () async {
              await pump(tester, dark: true);
              await expectLater(find.byType(ReportEditorPage),
                  matchesGoldenFile('goldens/report_editor_dark.png'));
            }));
  });
}

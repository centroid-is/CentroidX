/// Goldens of the report view over a fixed, realistic shift result: KPI
/// tiles (one of them errored), an aggregate table, a chart, the alarm
/// summary, the downtime pareto, and a handover text block — the full
/// vocabulary of report sections in one image, in both themes.
///
/// To update:
///   flutter test test/widgets/report_view_golden_test.dart --update-goldens
@Tags(['golden'])
library;

import 'dart:io' show File, Platform;
import 'dart:typed_data' show ByteData;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/theme.dart' show muted;
import 'package:tfc/widgets/report_view.dart';
import 'package:tfc_dart/tfc_dart.dart';

import '../helpers/golden_tolerance.dart';

final _start = DateTime(2026, 9, 1, 7);
final _end = DateTime(2026, 9, 1, 15);
DateTime _at(int minutes) => _start.add(Duration(minutes: minutes));

ReportResult _fixture() => ReportResult(
      reportId: 'shift',
      reportName: 'Packing hall shift report',
      rangeStart: _start,
      rangeEnd: _end,
      rangeLabel: 'Day 2026-09-01 07:00–15:00',
      generatedAt: _at(320),
      partial: true,
      sections: [
        KpiSectionResult(metrics: [
          const MetricResult(
              label: 'Produced',
              aggregate: ReportAggregate.delta,
              unit: 'boxes',
              decimals: 0,
              value: 5231),
          const MetricResult(
              label: 'Throughput',
              aggregate: ReportAggregate.timeWeightedMean,
              unit: 'boxes/h',
              value: 981.2),
          const MetricResult(
              label: 'Line running',
              aggregate: ReportAggregate.durationTrue,
              value: 17423),
          const MetricResult(
              label: 'Giveaway',
              aggregate: ReportAggregate.timeWeightedMean,
              unit: '%',
              decimals: 2,
              value: 1.87),
          const MetricResult(
              label: 'Freezer temp',
              aggregate: ReportAggregate.max,
              unit: '°C',
              error: 'no collected data for "FR01.temp"'),
        ]),
        TableSectionResult(
          title: 'Drives',
          aggregates: const [
            ReportAggregate.timeWeightedMean,
            ReportAggregate.min,
            ReportAggregate.max,
          ],
          rows: const [
            TableRowResult(label: 'CN04 speed', cells: [
              MetricResult(
                  label: 'CN04 speed',
                  aggregate: ReportAggregate.timeWeightedMean,
                  unit: 'Hz',
                  value: 42.1),
              MetricResult(
                  label: 'CN04 speed',
                  aggregate: ReportAggregate.min,
                  unit: 'Hz',
                  value: 0),
              MetricResult(
                  label: 'CN04 speed',
                  aggregate: ReportAggregate.max,
                  unit: 'Hz',
                  value: 50),
            ]),
            TableRowResult(label: 'CN07 speed', cells: [
              MetricResult(
                  label: 'CN07 speed',
                  aggregate: ReportAggregate.timeWeightedMean,
                  unit: 'Hz',
                  value: 38.6),
              MetricResult(
                  label: 'CN07 speed',
                  aggregate: ReportAggregate.min,
                  unit: 'Hz',
                  value: 12.5),
              MetricResult(
                  label: 'CN07 speed',
                  aggregate: ReportAggregate.max,
                  unit: 'Hz',
                  value: 50),
            ]),
          ],
        ),
        ChartSectionResult(title: 'Throughput', series: [
          ChartSeriesResult(label: 'boxes/h', points: [
            for (var i = 0; i < 32; i++)
              ReportChartPoint(
                time: _at(i * 10),
                min: 800 + 60 * (i % 5),
                avg: 900 + 40 * (i % 7),
                max: 1050 + 30 * (i % 3),
              ),
          ]),
        ]),
        AlarmSummarySectionResult(
          totalActivations: 23,
          distinctAlarms: 6,
          openNow: 1,
          perHour: 4.3,
          topByCount: [
            AlarmStat(
                uid: 'film',
                title: 'Film reel empty',
                level: 'error',
                count: 9,
                total: const Duration(minutes: 34),
                openNow: false),
            AlarmStat(
                uid: 'jam',
                title: 'Infeed jam',
                level: 'warning',
                count: 7,
                total: const Duration(minutes: 12),
                openNow: true),
          ],
          topByDuration: [
            AlarmStat(
                uid: 'film',
                title: 'Film reel empty',
                level: 'error',
                count: 9,
                total: const Duration(minutes: 34),
                openNow: false),
            AlarmStat(
                uid: 'strap',
                title: 'Strapper stopped',
                level: 'error',
                count: 2,
                total: const Duration(minutes: 21),
                openNow: false),
          ],
        ),
        DowntimeSectionResult(
          totalDown: const Duration(minutes: 52),
          fraction: 0.108,
          stops: 11,
          openNow: true,
          topByDuration: [
            AlarmStat(
                uid: 'film',
                title: 'Film reel empty',
                level: 'error',
                count: 9,
                total: const Duration(minutes: 34),
                openNow: false),
            AlarmStat(
                uid: 'strap',
                title: 'Strapper stopped',
                level: 'error',
                count: 2,
                total: const Duration(minutes: 21),
                openNow: true),
            AlarmStat(
                uid: 'jam',
                title: 'Infeed jam',
                level: 'warning',
                count: 7,
                total: const Duration(minutes: 12),
                openNow: false),
          ],
        ),
        const TextSectionResult(
            title: 'Handover',
            text: 'Film tracking drifted all morning; reel changed at 11:40. '
                'Strapper PSU replaced during the second stop.'),
      ],
    );

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

Future<void> _pump(WidgetTester tester, {required bool dark}) async {
  await _loadFonts();
  tester.view.physicalSize = const Size(1280, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: dark ? muted().$2 : muted().$1,
    home: Scaffold(body: ReportView(result: _fixture())),
  ));
  await tester.pumpAndSettle();
}

void main() {
  useTolerantGoldenComparator(tolerance: 0.002);

  group('report view goldens',
      skip: !Platform.isMacOS ? 'Golden tests only run on macOS' : null, () {
    testWidgets('every section type over a shift — light', (tester) async {
      await _pump(tester, dark: false);
      await expectLater(find.byType(ReportView),
          matchesGoldenFile('goldens/report_view_light.png'));
    });

    testWidgets('every section type over a shift — dark', (tester) async {
      await _pump(tester, dark: true);
      await expectLater(find.byType(ReportView),
          matchesGoldenFile('goldens/report_view_dark.png'));
    });
  });
}

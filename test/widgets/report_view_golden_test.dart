/// Goldens of the report view over five shifts a plant actually has.
///
/// The five are chosen because each one is a different answer to "how did the
/// shift go", and the layout has to make that answer readable before any
/// number is:
///
///   * `full`    — ran to the end of the shift, every section type, a
///                 one-series chart and a two-series chart.
///   * `early`   — the headline case: production finished at 13:42 and the
///                 wash followed, so the last hour of the range is not
///                 downtime and the figures do not cover it.
///   * `empty`   — nothing was produced at all.
///   * `current` — a shift still running, with a conclusion inferred but not
///                 final.
///   * `legacy`  — a definition with no production window, which is what every
///                 report saved before windows existed deserialises to. No
///                 band, no scope captions, the plain header.
///
/// To update:
///   flutter test test/widgets/report_view_golden_test.dart --update-goldens
@Tags(['golden'])
library;

import 'dart:io' show File, Platform;
import 'dart:math' as math;
import 'dart:typed_data' show ByteData;

import 'package:clock/clock.dart';
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

// ---------------------------------------------------------------------------
// Sections
// ---------------------------------------------------------------------------

/// Bucketed rate points, with the buckets inside [gaps] left out so the chart
/// has a real hole in it to draw as a gap rather than a straight line.
List<ReportChartPoint> _rate(
  int fromMin,
  int toMin, {
  double base = 980,
  double swing = 110,
  double phase = 0,
  int step = 10,
  List<(int, int)> gaps = const [],
}) {
  final out = <ReportChartPoint>[];
  for (var m = fromMin; m <= toMin; m += step) {
    if (gaps.any((g) => m >= g.$1 && m < g.$2)) continue;
    final i = m / step;
    final avg = base + swing * math.sin(i / 2.7 + phase);
    out.add(ReportChartPoint(
      time: _at(m),
      min: avg - 40,
      avg: avg,
      max: avg + 55,
    ));
  }
  return out;
}

KpiSectionResult _kpi({ReportScope scope = ReportScope.effective}) =>
    KpiSectionResult(title: 'Key figures', scope: scope, metrics: const [
      MetricResult(
          label: 'Produced',
          aggregate: ReportAggregate.delta,
          unit: 'boxes',
          decimals: 0,
          value: 5231),
      MetricResult(
          label: 'Throughput',
          aggregate: ReportAggregate.timeWeightedMean,
          unit: 'boxes/h',
          value: 981.2),
      MetricResult(
          label: 'Line running',
          aggregate: ReportAggregate.durationTrue,
          value: 17423),
      MetricResult(
          label: 'Giveaway',
          aggregate: ReportAggregate.timeWeightedMean,
          unit: '%',
          decimals: 2,
          value: 1.87),
      MetricResult(
          label: 'Freezer temp',
          aggregate: ReportAggregate.max,
          unit: '°C',
          error: 'no collected data for "FR01.temp" in this range'),
    ]);

TableSectionResult _drives() => const TableSectionResult(
      title: 'Drives',
      aggregates: [
        ReportAggregate.timeWeightedMean,
        ReportAggregate.min,
        ReportAggregate.max,
      ],
      rows: [
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
        TableRowResult(label: 'Multivac cycle', cells: [
          MetricResult(
              label: 'Multivac cycle',
              aggregate: ReportAggregate.timeWeightedMean,
              unit: 's',
              decimals: 2,
              value: 4.18),
          MetricResult(
              label: 'Multivac cycle',
              aggregate: ReportAggregate.min,
              unit: 's',
              decimals: 2,
              value: 3.9),
          MetricResult(
              label: 'Multivac cycle',
              aggregate: ReportAggregate.max,
              unit: 's',
              decimals: 2,
              value: 6.44),
        ]),
      ],
    );

ChartSectionResult _throughput(int fromMin, int toMin,
        {List<(int, int)> gaps = const []}) =>
    ChartSectionResult(title: 'Throughput', series: [
      ChartSeriesResult(
          label: 'boxes/h', points: _rate(fromMin, toMin, gaps: gaps)),
    ]);

ChartSectionResult _speeds(int fromMin, int toMin) =>
    ChartSectionResult(title: 'Drive speeds', series: [
      ChartSeriesResult(
          label: 'CN04 Hz',
          points: _rate(fromMin, toMin, base: 42, swing: 8)),
      ChartSeriesResult(
          label: 'CN07 Hz',
          points: _rate(fromMin, toMin, base: 36, swing: 11, phase: 1.4)),
    ]);

AlarmSummarySectionResult _alarms({int afterConclusion = 0}) =>
    AlarmSummarySectionResult(
      title: 'Alarms',
      scope: ReportScope.nominal,
      totalActivations: 23,
      distinctAlarms: 6,
      openNow: 1,
      perHour: 2.9,
      afterConclusion: afterConclusion,
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
        AlarmStat(
            uid: 'label',
            title: 'Labeller out of ribbon',
            level: 'warning',
            count: 4,
            total: const Duration(minutes: 6),
            openNow: false),
      ],
      // Still populated by the engine; the view deliberately no longer renders
      // it, because it is the downtime section's question in other words.
      topByDuration: const [],
    );

DowntimeSectionResult _downtime({bool openNow = true}) =>
    DowntimeSectionResult(
      title: 'Downtime',
      totalDown: const Duration(minutes: 52),
      fraction: 0.108,
      stops: 11,
      openNow: openNow,
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
            openNow: openNow),
        AlarmStat(
            uid: 'jam',
            title: 'Infeed jam',
            level: 'warning',
            count: 7,
            total: const Duration(minutes: 12),
            openNow: false),
      ],
    );

const _products = SqlSectionResult(
  title: 'Per-product totals',
  columns: ['product', 'boxes', 'avg_weight_g'],
  rows: [
    ['Cod loins 5kg', '2841', '5012.4'],
    ['Cod fillets 3kg', '1610', '3004.1'],
    ['Haddock 5kg', '780', '5018.9'],
  ],
);

const _handover = TextSectionResult(
    title: 'Handover',
    text: 'Film tracking drifted all morning; reel changed at 11:40. '
        'Strapper PSU replaced during the second stop. Washed down from '
        '13:42, ready for the evening shift.');

// ---------------------------------------------------------------------------
// Windows
// ---------------------------------------------------------------------------

StateSegment _seg(int from, int to, ProductionState state) =>
    StateSegment(from: _at(from), to: _at(to), state: state);

Duration _total(List<StateSegment> segments, ProductionState state) =>
    segments.where((s) => s.state == state).fold(
        Duration.zero, (a, s) => a + s.length);

/// Assembles a window the way the engine does, so the totals in the header
/// always agree with the band beside them.
ProductionWindow _window({
  required List<StateSegment> segments,
  required ConclusionReason reason,
  DateTime? actualStart,
  DateTime? concludedAt,
  DateTime? cap,
  bool tentative = false,
  List<SignalLane> lanes = const [],
}) {
  final effStart = actualStart ?? _start;
  final effEnd = concludedAt ?? cap ?? _end;
  final running = _total(segments, ProductionState.running);
  final cleaning = _total(segments, ProductionState.cleaning);
  var washUs = 0;
  for (final s in segments) {
    if (s.state != ProductionState.cleaning) continue;
    final lo = s.from.isAfter(effStart) ? s.from : effStart;
    final hi = s.to.isBefore(effEnd) ? s.to : effEnd;
    if (hi.isAfter(lo)) washUs += hi.difference(lo).inMicroseconds;
  }
  final denom = effEnd.difference(effStart).inMicroseconds - washUs;
  return ProductionWindow(
    nominalStart: _start,
    nominalEnd: _end,
    cap: cap ?? _end,
    actualStart: actualStart,
    concludedAt: concludedAt,
    reason: reason,
    tentative: tentative,
    segments: segments,
    lanes: lanes,
    running: running,
    idle: _total(segments, ProductionState.idle),
    cleaning: cleaning,
    fault: _total(segments, ProductionState.fault),
    noData: _total(segments, ProductionState.noData),
    availability: reason == ConclusionReason.noProduction || denom <= 0
        ? null
        : running.inMicroseconds / denom,
  );
}

ReportResult _result({
  required String id,
  required List<ReportSectionResult> sections,
  ProductionWindow? window,
  bool partial = false,
  DateTime? generatedAt,
}) =>
    ReportResult(
      reportId: id,
      reportName: 'Packing hall shift report',
      rangeStart: _start,
      rangeEnd: _end,
      rangeLabel: 'Day 2026-09-01 07:00–15:00',
      generatedAt: generatedAt ?? _end,
      partial: partial,
      window: window,
      sections: sections,
    );

/// Ran to the end of the shift, with two ordinary stops in it.
ReportResult _full() => _result(
      id: 'full',
      window: _window(
        reason: ConclusionReason.shiftEnd,
        actualStart: _at(12),
        concludedAt: _end,
        segments: [
          _seg(0, 12, ProductionState.idle),
          _seg(12, 150, ProductionState.running),
          _seg(150, 172, ProductionState.fault),
          _seg(172, 280, ProductionState.running),
          _seg(280, 292, ProductionState.fault),
          _seg(292, 440, ProductionState.running),
          _seg(440, 452, ProductionState.idle),
          _seg(452, 480, ProductionState.running),
        ],
      ),
      sections: [
        _kpi(),
        _drives(),
        _throughput(10, 480, gaps: const [(150, 175)]),
        _speeds(10, 480),
        _alarms(),
        _downtime(),
        _products,
        _handover,
      ],
    );

/// The headline case: finished at 13:42 and washed until ten to three.
ReportResult _endedEarly() => _result(
      id: 'early',
      window: _window(
        reason: ConclusionReason.cleaning,
        actualStart: _at(32),
        concludedAt: _at(402),
        segments: [
          _seg(0, 32, ProductionState.idle),
          _seg(32, 135, ProductionState.running),
          _seg(135, 167, ProductionState.fault),
          _seg(167, 305, ProductionState.running),
          _seg(305, 320, ProductionState.noData),
          _seg(320, 402, ProductionState.running),
          _seg(402, 470, ProductionState.cleaning),
          _seg(470, 480, ProductionState.idle),
        ],
      ),
      sections: [
        _kpi(),
        _throughput(30, 400),
        _alarms(afterConclusion: 3),
        _downtime(openNow: false),
        _handover,
      ],
    );

/// Nothing ran at all — a boat that never landed.
ReportResult _noProduction() => _result(
      id: 'empty',
      window: _window(
        reason: ConclusionReason.noProduction,
        segments: [
          _seg(0, 240, ProductionState.idle),
          _seg(240, 330, ProductionState.noData),
          _seg(330, 480, ProductionState.idle),
        ],
      ),
      sections: [
        KpiSectionResult(title: 'Key figures', metrics: const [
          MetricResult(
              label: 'Produced',
              aggregate: ReportAggregate.delta,
              unit: 'boxes',
              decimals: 0,
              error: 'no production in this range'),
          MetricResult(
              label: 'Line running',
              aggregate: ReportAggregate.durationTrue,
              value: 0),
        ]),
        const ChartSectionResult(title: 'Throughput', series: []),
        DowntimeSectionResult(
          title: 'Downtime',
          totalDown: Duration.zero,
          fraction: 0,
          stops: 0,
          openNow: false,
          topByDuration: const [],
        ),
        _handover,
      ],
    );

/// A shift still running, concluded on inference the line could still undo.
ReportResult _currentShift() => _result(
      id: 'current',
      partial: true,
      generatedAt: _at(380),
      window: _window(
        reason: ConclusionReason.idle,
        actualStart: _at(5),
        concludedAt: _at(330),
        cap: _at(380),
        tentative: true,
        segments: [
          _seg(0, 5, ProductionState.idle),
          _seg(5, 260, ProductionState.running),
          _seg(260, 275, ProductionState.fault),
          _seg(275, 330, ProductionState.running),
          _seg(330, 380, ProductionState.idle),
        ],
        lanes: [
          SignalLane(label: 'Packing line 3', segments: [
            _seg(0, 5, ProductionState.idle),
            _seg(5, 260, ProductionState.running),
            _seg(260, 275, ProductionState.fault),
            _seg(275, 330, ProductionState.running),
            _seg(330, 380, ProductionState.idle),
          ]),
          SignalLane(label: 'Freezer tunnel', segments: [
            _seg(0, 40, ProductionState.idle),
            _seg(40, 300, ProductionState.running),
            _seg(300, 380, ProductionState.idle),
          ]),
        ],
      ),
      sections: [
        _kpi(),
        _throughput(10, 330),
        _alarms(afterConclusion: 2),
        _downtime(),
        _handover,
      ],
    );

/// A definition saved before production windows existed.
ReportResult _legacy() => _result(
      id: 'legacy',
      partial: true,
      generatedAt: _at(380),
      sections: [
        _kpi(),
        _drives(),
        _throughput(10, 380),
        _alarms(),
        _downtime(),
        _products,
        _handover,
      ],
    );

// ---------------------------------------------------------------------------

Future<void> _loadFonts() async {
  Future<void> load(String family, String path) async {
    final file = File(path);
    if (!file.existsSync()) return;
    await (FontLoader(family)
          ..addFont(Future.value(ByteData.view(file.readAsBytesSync().buffer))))
        .load();
  }

  // Regular only, deliberately. The app's pubspec declares no roboto-mono
  // faces at all, so loading Medium and Bold here would golden a page heavier
  // than the one the HMI renders.
  await load('Roboto', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');
  await load('roboto-mono', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');

  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    await load('MaterialIcons',
        '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  }
}

Future<void> _pump(
  WidgetTester tester,
  ReportResult result, {
  required bool dark,
  required double height,
}) async {
  await _loadFonts();
  tester.view.physicalSize = Size(1280, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: dark ? muted().$2 : muted().$1,
    home: Scaffold(body: ReportView(result: result)),
  ));
  await tester.pumpAndSettle();
}

void main() {
  useTolerantGoldenComparator(tolerance: 0.002);

  // Nothing in the view reads the wall clock — every instant comes from the
  // fixture — but it is pinned anyway so a stray `clock.now()` added later
  // cannot make these churn every run.
  final goldenClock = Clock.fixed(DateTime(2026, 9, 1, 13, 20));

  void scenario(String name, String file, ReportResult Function() build,
      double height) {
    testWidgets('$name — light',
        (tester) => withClock(goldenClock, () async {
              await _pump(tester, build(), dark: false, height: height);
              await expectLater(find.byType(ReportView),
                  matchesGoldenFile('goldens/report_view_${file}_light.png'));
            }));

    testWidgets('$name — dark',
        (tester) => withClock(goldenClock, () async {
              await _pump(tester, build(), dark: true, height: height);
              await expectLater(find.byType(ReportView),
                  matchesGoldenFile('goldens/report_view_${file}_dark.png'));
            }));
  }

  group('report view goldens',
      skip: !Platform.isMacOS ? 'Golden tests only run on macOS' : null, () {
    // Heights are chosen to hold the whole report: the view is a ListView, so
    // anything past the viewport is silently cropped out of the golden, and a
    // handover note cut in half is exactly the kind of thing a golden is
    // supposed to catch.
    scenario('a shift that ran to the end', 'full', _full, 1920);
    scenario('production finished early, then washing', 'early', _endedEarly,
        1260);
    scenario('no production at all', 'empty', _noProduction, 920);
    scenario('the current shift, conclusion not final', 'current',
        _currentShift, 1320);
    scenario('a report with no production window', 'legacy', _legacy, 1680);
  });
}

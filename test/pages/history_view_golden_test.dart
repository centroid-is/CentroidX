/// Golden images of the reworked history view, for design review and PR
/// descriptions.
///
/// Frames: the full page plotting three keys over a fixed historical range
/// (including a boolean drawn as square steps, not the old sawtooth), the
/// quick-preset range menu open, and the table with a multi-day range
/// carrying dates in the Timestamp column.
///
/// Every timestamp is anchored to a fixed date via the body's
/// `initialRange` test hook — goldens run in macOS CI, so nothing here may
/// derive from DateTime.now().
///
/// To update: flutter test test/pages/history_view_golden_test.dart --update-goldens --run-skipped
@Tags(['golden'])
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc_dart/core/database.dart';

import '../helpers/golden_tolerance.dart';
import 'history_view_harness.dart';

const Size _viewport = Size(1400, 900);

/// The fixed "now" every frame is anchored to.
final DateTime _anchor = DateTime(2026, 8, 30, 12);

/// Real letterforms instead of the test font's black boxes; MaterialIcons so
/// the folder / chip / menu icons don't render as tofu.
Future<void> _loadRealFonts() async {
  final data = File('lib/fonts/roboto-mono/RobotoMono-Regular.ttf')
      .readAsBytesSync()
      .buffer
      .asByteData();
  final loader = FontLoader('Roboto')..addFont(Future.value(data));
  await loader.load();
  final chartLoader = FontLoader('roboto-mono')..addFont(Future.value(data));
  await chartLoader.load();

  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  final iconFont = File(
      '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (flutterRoot != null && iconFont.existsSync()) {
    final iconLoader = FontLoader('MaterialIcons')
      ..addFont(Future.value(iconFont.readAsBytesSync().buffer.asByteData()));
    await iconLoader.load();
  }
}

/// Six hours before the anchor: a sine for the speed, a slow drift for the
/// temperature and a square wave for the running flag — enough to judge
/// legibility and the boolean step rendering.
Map<String, List<TimeseriesData<dynamic>>> _sixHourSamples() {
  final speed = <TimeseriesData<dynamic>>[];
  final temp = <TimeseriesData<dynamic>>[];
  final running = <TimeseriesData<dynamic>>[];
  for (var i = 0; i < 120; i++) {
    final t = _anchor.subtract(Duration(minutes: 3 * (120 - i)));
    speed.add(TimeseriesData(1200 + 300 * math.sin(i / 12), t));
    temp.add(TimeseriesData(4.0 + i * 0.01, t));
    running.add(TimeseriesData(i % 40 < 30, t));
  }
  return {
    'line1.motor.speed': speed,
    'line1.temperature': temp,
    'line1.motor.running': running,
  };
}

/// Two days of hourly temperatures for the multi-day table format.
Map<String, List<TimeseriesData<dynamic>>> _twoDaySamples() {
  final temp = <TimeseriesData<dynamic>>[];
  for (var i = 0; i < 48; i++) {
    temp.add(TimeseriesData(
        4.0 + math.sin(i / 5), _anchor.subtract(Duration(hours: 48 - i))));
  }
  return {'line1.temperature': temp};
}

Future<void> _pump(
  WidgetTester tester,
  Map<String, List<TimeseriesData<dynamic>>> samples, {
  DateTimeRange? initialRange,
}) async {
  await _loadRealFonts();
  await tester.binding.setSurfaceSize(_viewport);
  tester.view.physicalSize = _viewport;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final appDb = inMemoryAppDatabase();
  await appDb.createHistoryView(
      'Freezer shift', ['line1.motor.speed', 'line1.temperature'], {}, {});
  await tester.pumpWidget(buildHistoryView(
    keyMappings: historyKeyMappings(),
    appDb: appDb,
    samples: samples,
    initialRealtime: initialRange == null,
    initialRange: initialRange,
  ));
  await settleHistory(tester);
}

Future<void> _selectLine1Keys(WidgetTester tester) async {
  await expandFolder(tester, 'line1');
  await expandFolder(tester, 'motor');
  await tickKey(tester, 'speed');
  await tickKey(tester, 'running');
  await tickKey(tester, 'temperature');
}

Future<void> _expectGolden(WidgetTester tester, String name) =>
    expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name'));

void main() {
  useTolerantGoldenComparator();

  testWidgets('full page — historical graph with three keys', (tester) async {
    await _pump(
      tester,
      _sixHourSamples(),
      initialRange: DateTimeRange(
          start: _anchor.subtract(const Duration(hours: 6)), end: _anchor),
    );
    await _selectLine1Keys(tester);
    await settleHistory(tester);
    await _expectGolden(tester, 'history_graph_page.png');
  });

  testWidgets('historical — quick preset menu open', (tester) async {
    await _pump(tester, _sixHourSamples());
    await _selectLine1Keys(tester);
    await tester.tap(find.text('Historical'));
    await settleHistory(tester);
    await tester.tap(find.text('Pick range…'));
    await settleHistory(tester);
    await _expectGolden(tester, 'history_range_presets_menu.png');
  });

  testWidgets('table — multi-day range carries dates', (tester) async {
    await _pump(
      tester,
      _twoDaySamples(),
      initialRange: DateTimeRange(
          start: _anchor.subtract(const Duration(days: 2)), end: _anchor),
    );
    await expandFolder(tester, 'line1');
    await tickKey(tester, 'temperature');
    await tester.tap(find.text('Table'));
    await settleHistory(tester);
    await _expectGolden(tester, 'history_table_dates.png');
  });
}

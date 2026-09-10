import 'dart:io' show File, Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show ByteData, FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/widgets/stop_timeline.dart';
import 'package:tfc/theme.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/alarm_interval.dart';
import 'package:tfc_dart/core/alarm_tree.dart';
import 'package:tfc_dart/core/boolean_expression.dart';
import 'package:tfc_dart/core/stop_interval_source.dart';

/// Fixed clock, so a golden of a live-edge chart is reproducible.
final now = DateTime(2026, 8, 29, 14, 22);
DateTime ago(int minutes) => now.subtract(Duration(minutes: minutes));

/// The muted theme sets `fontFamily: 'roboto-mono'`, so the font has to be
/// registered under that family too or every glyph renders as an Ahem box.
Future<void> loadFonts() async {
  final data = ByteData.view(
      File('lib/fonts/roboto-mono/RobotoMono-Regular.ttf')
          .readAsBytesSync()
          .buffer);
  for (final family in ['Roboto', 'roboto-mono']) {
    await (FontLoader(family)..addFont(Future.value(data))).load();
  }
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  final icons = File(
      '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (flutterRoot != null && icons.existsSync()) {
    await (FontLoader('MaterialIcons')
          ..addFont(
              Future.value(ByteData.view(icons.readAsBytesSync().buffer))))
        .load();
  }
}

AlarmConfig alarm(
  String title, {
  required List<String> group,
  bool bindToGroup = false,
  AlarmLevel level = AlarmLevel.error,
  String? description,
}) =>
    AlarmConfig(
      uid: title.toLowerCase().replaceAll(' ', '-'),
      title: title,
      description: description ?? title,
      group: group,
      bindToGroup: bindToGroup,
      rules: [
        AlarmRule(
          level: level,
          expression: ExpressionConfig(value: Expression(formula: 'a')),
          acknowledgeRequired: false,
        )
      ],
    );

/// The packing hall the design was drawn against: a group with its own alarm
/// AND diagnoses under it, a group with only diagnoses, and a group whose only
/// alarm is its own.
final alarms = [
  alarm('Multivac stopped', group: ['Line 3', 'Multivac'], bindToGroup: true),
  alarm('Film reel empty', group: ['Line 3', 'Multivac']),
  alarm('Film tracking error',
      group: ['Line 3', 'Multivac'], level: AlarmLevel.warning),
  alarm('Seal temperature out of band',
      group: ['Line 3', 'Multivac'],
      description: 'The sealing bar left its band while the cycle was '
          'running. Product sealed in this state may not hold vacuum.'),
  alarm('Blank magazine empty', group: ['Line 3', 'Box erector BER01']),
  alarm('Glue temperature low',
      group: ['Line 3', 'Box erector BER01'], level: AlarmLevel.warning),
  alarm('Strapper stopped', group: ['Line 3', 'Afak SL-15-3'], bindToGroup: true),
  alarm('Line stopped from panel',
      group: ['Line 3'], level: AlarmLevel.warning),
  alarm('Link error', group: ['Infrastructure'], level: AlarmLevel.warning),
  alarm('Air cabinet is off', group: ['Infrastructure'], level: AlarmLevel.info),
];

/// A shift's worth of activations, including one still standing.
StopIntervalSource sampleSource() {
  AlarmInterval closed(int from, int to, AlarmLevel level) => AlarmInterval(
      start: ago(from), end: ago(to), level: level);

  final byUid = <String, List<AlarmInterval>>{
    'film-reel-empty': [
      closed(160, 148, AlarmLevel.error),
      closed(64, 52, AlarmLevel.error),
    ],
    'film-tracking-error': [
      for (var i = 0; i < 9; i++)
        AlarmInterval(
            start: ago(120 - i),
            end: ago(120 - i).add(const Duration(seconds: 20)),
            level: AlarmLevel.warning),
    ],
    'seal-temperature-out-of-band': [
      closed(95, 71, AlarmLevel.error),
      AlarmInterval(start: ago(9), end: null, level: AlarmLevel.error),
    ],
    'multivac-stopped': [closed(140, 133, AlarmLevel.error)],
    'blank-magazine-empty': [closed(175, 164, AlarmLevel.error)],
    'glue-temperature-low': [closed(40, 31, AlarmLevel.warning)],
    'strapper-stopped': [
      closed(110, 101, AlarmLevel.error),
      closed(22, 16, AlarmLevel.error),
    ],
    'line-stopped-from-panel': [closed(150, 146, AlarmLevel.warning)],
    'link-error': [closed(88, 86, AlarmLevel.warning)],
    'air-cabinet-is-off': [closed(60, 45, AlarmLevel.info)],
  };

  final closedOnes = <StopActivation>[];
  final openOnes = <StopActivation>[];
  byUid.forEach((uid, intervals) {
    for (final interval in intervals) {
      final activation = StopActivation(alarmUid: uid, interval: interval);
      (interval.isOpen ? openOnes : closedOnes).add(activation);
    }
  });
  return StopIntervalSource(closed: closedOnes, open: openOnes);
}

Widget harness(
  StopTimelineSpec config,
  Brightness brightness, {
  Size size = const Size(900, 420),
  DateTimeRange? range,
}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: brightness == Brightness.dark ? muted().$2 : muted().$1,
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: StopTimelineView(
            config: config,
            tree: AlarmTree.fromConfigs(alarms),
            source: sampleSource(),
            range: range,
            onRangeChanged: (_) {},
            onIntervalChanged: (_) {},
            clock: now,
          ),
        ),
      ),
    ),
  );
}

Future<void> pump(WidgetTester tester, Widget widget, Size view) async {
  await loadFonts();
  tester.view.physicalSize = view;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(widget);
  await tester.pumpAndSettle();
}

void main() {
  group('stop timeline goldens', () {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      final name = brightness == Brightness.light ? 'light' : 'dark';

      testWidgets('collapsed groups ($name)', (tester) async {
        await pump(tester, harness(StopTimelineSpec(), brightness),
            const Size(960, 480));
        await expectLater(find.byType(StopTimelineView),
            matchesGoldenFile('goldens/stop_timeline_collapsed_$name.png'));
      }, skip: !Platform.isMacOS);

      testWidgets('drilled into Multivac ($name)', (tester) async {
        await pump(tester, harness(StopTimelineSpec(), brightness),
            const Size(960, 480));
        // Line 3, then Multivac: the drill-down the design is built around.
        await tester.tap(find.byKey(
            const ValueKey('stop-timeline-row-g:Line 3')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(
            const ValueKey('stop-timeline-row-g:Line 3/Multivac')));
        await tester.pumpAndSettle();

        await expectLater(find.byType(StopTimelineView),
            matchesGoldenFile('goldens/stop_timeline_expanded_$name.png'));
      }, skip: !Platform.isMacOS);
    }

    for (final brightness in [Brightness.light, Brightness.dark]) {
      final name = brightness == Brightness.light ? 'light' : 'dark';
      testWidgets('pareto table ($name)', (tester) async {
        await pump(tester, harness(StopTimelineSpec(), brightness),
            const Size(960, 480));
        await tester
            .tap(find.byKey(const ValueKey('stop-timeline-view-table')));
        await tester.pumpAndSettle();
        await expectLater(find.byType(StopTimelineView),
            matchesGoldenFile('goldens/stop_timeline_table_$name.png'));
      }, skip: !Platform.isMacOS);
    }

    testWidgets('pareto ranked by count instead of lost time', (tester) async {
      await pump(tester, harness(StopTimelineSpec(), Brightness.dark),
          const Size(960, 480));
      await tester
          .tap(find.byKey(const ValueKey('stop-timeline-view-table')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(const ValueKey('stop-timeline-rank-count')));
      await tester.pumpAndSettle();
      await expectLater(find.byType(StopTimelineView),
          matchesGoldenFile('goldens/stop_timeline_table_by_count.png'));
    }, skip: !Platform.isMacOS);

    testWidgets('scoped to one group', (tester) async {
      await pump(
          tester,
          harness(
              StopTimelineSpec(groups: [
                ['Line 3', 'Multivac']
              ]),
              Brightness.dark),
          const Size(960, 400));
      await expectLater(find.byType(StopTimelineView),
          matchesGoldenFile('goldens/stop_timeline_scoped.png'));
    }, skip: !Platform.isMacOS);

    testWidgets('an alarm standing since yesterday', (tester) async {
      // The bar reaches the window edge and stops there — it used to paint
      // straight across the label column — and the detail row names the day
      // it started, because "Since 12:22:00" alone reads as today.
      final sinceYesterday = StopIntervalSource(
        closed: const [],
        open: [
          StopActivation(
            alarmUid: 'seal-temperature-out-of-band',
            interval: AlarmInterval(
                start: now.subtract(const Duration(hours: 26)),
                end: null,
                level: AlarmLevel.error),
          ),
        ],
      );
      await pump(
          tester,
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: muted().$2,
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 900,
                  height: 420,
                  child: StopTimelineView(
                    config: StopTimelineSpec(),
                    tree: AlarmTree.fromConfigs(alarms),
                    source: sinceYesterday,
                    onRangeChanged: (_) {},
                    onIntervalChanged: (_) {},
                    clock: now,
                  ),
                ),
              ),
            ),
          ),
          const Size(960, 480));
      final label = tester
          .getRect(find.byKey(const ValueKey('stop-timeline-row-g:Line 3')));
      await tester.tapAt(Offset(label.right + 120, label.center.dy));
      await tester.pumpAndSettle();
      await expectLater(find.byType(StopTimelineView),
          matchesGoldenFile('goldens/stop_timeline_standing_since_yesterday.png'));
    }, skip: !Platform.isMacOS);

    // --- callouts -------------------------------------------------------

    /// Where the middle of an interval lands, in pixels right of the label
    /// column, in the window the view opens on: the last three hours plus the
    /// live pad for the configured twelve-hour period (10 minutes).
    double xOfInterval(WidgetTester tester, DateTime start, DateTime end) {
      final laneWidth =
          tester.getRect(find.byType(StopTimelineView)).width - 210;
      final windowStart = now.subtract(const Duration(hours: 3));
      final windowEnd = now.add(const Duration(minutes: 10));
      final span = windowEnd.difference(windowStart).inMicroseconds;
      final mid = start.add(end.difference(start) ~/ 2);
      return mid.difference(windowStart).inMicroseconds / span * laneWidth;
    }

    Future<void> tapLane(
        WidgetTester tester, String rowKey, double dx) async {
      final label =
          tester.getRect(find.byKey(ValueKey('stop-timeline-row-$rowKey')));
      await tester.tapAt(Offset(label.right + dx, label.center.dy));
      await tester.pumpAndSettle();
    }

    Future<void> drillIntoMultivac(WidgetTester tester) async {
      await tester
          .tap(find.byKey(const ValueKey('stop-timeline-row-g:Line 3')));
      await tester.pumpAndSettle();
      await tester.tap(
          find.byKey(const ValueKey('stop-timeline-row-g:Line 3/Multivac')));
      await tester.pumpAndSettle();
    }

    for (final brightness in [Brightness.light, Brightness.dark]) {
      final name = brightness == Brightness.light ? 'light' : 'dark';

      testWidgets('an activation callout ($name)', (tester) async {
        await pump(tester, harness(StopTimelineSpec(), brightness),
            const Size(960, 480));
        await drillIntoMultivac(tester);
        // 'Film reel empty', 64..52 minutes ago.
        await tapLane(tester, 'a:film-reel-empty',
            xOfInterval(tester, ago(64), ago(52)));
        await expectLater(find.byType(StopTimelineView),
            matchesGoldenFile('goldens/stop_timeline_callout_$name.png'));
      }, skip: !Platform.isMacOS);

      testWidgets('an alarm identity callout ($name)', (tester) async {
        await pump(tester, harness(StopTimelineSpec(), brightness),
            const Size(960, 480));
        await drillIntoMultivac(tester);
        await tester.tap(find.byKey(const ValueKey(
            'stop-timeline-row-a:seal-temperature-out-of-band')));
        await tester.pumpAndSettle();
        await expectLater(
            find.byType(StopTimelineView),
            matchesGoldenFile(
                'goldens/stop_timeline_leaf_callout_$name.png'));
      }, skip: !Platform.isMacOS);
    }

    // Light, where the edge golden below is dark: "still standing" is the one
    // saturated colour in the bubble and has to hold in both schemes.
    testWidgets('a callout on a standing activation', (tester) async {
      await pump(tester, harness(StopTimelineSpec(), Brightness.light),
          const Size(960, 480));
      await drillIntoMultivac(tester);
      // 'Seal temperature out of band' has been standing for nine minutes.
      await tapLane(tester, 'a:seal-temperature-out-of-band',
          xOfInterval(tester, ago(9), now));
      await expectLater(find.byType(StopTimelineView),
          matchesGoldenFile('goldens/stop_timeline_callout_standing.png'));
    }, skip: !Platform.isMacOS);

    testWidgets('a callout on the top row opens downward', (tester) async {
      await pump(tester, harness(StopTimelineSpec(), Brightness.light),
          const Size(960, 480));
      // Line 3, collapsed and first: there is no room above it.
      await tapLane(tester, 'g:Line 3', xOfInterval(tester, ago(64), ago(52)));
      await expectLater(find.byType(StopTimelineView),
          matchesGoldenFile('goldens/stop_timeline_callout_flipped.png'));
    }, skip: !Platform.isMacOS);

    testWidgets('a callout near the edge is clamped, tail off centre',
        (tester) async {
      await pump(tester, harness(StopTimelineSpec(), Brightness.dark),
          const Size(960, 480));
      await drillIntoMultivac(tester);
      // The standing alarm runs to the live edge, hard against the right.
      await tapLane(tester, 'a:seal-temperature-out-of-band',
          xOfInterval(tester, ago(1), now));
      await expectLater(find.byType(StopTimelineView),
          matchesGoldenFile('goldens/stop_timeline_callout_edge.png'));
    }, skip: !Platform.isMacOS);

    testWidgets('a collapsed group callout counts what stood under it',
        (tester) async {
      await pump(tester, harness(StopTimelineSpec(), Brightness.light),
          const Size(960, 480));
      await tester
          .tap(find.byKey(const ValueKey('stop-timeline-row-g:Line 3')));
      await tester.pumpAndSettle();
      // Multivac collapsed: its bar is the union of everything inside it.
      await tapLane(tester, 'g:Line 3/Multivac',
          xOfInterval(tester, ago(120), ago(111)));
      await expectLater(find.byType(StopTimelineView),
          matchesGoldenFile('goldens/stop_timeline_group_callout.png'));
    }, skip: !Platform.isMacOS);

    testWidgets('a callout at strip height, where nothing else fits',
        (tester) async {
      await pump(
          tester,
          harness(StopTimelineSpec(), Brightness.dark,
              size: const Size(620, 150)),
          const Size(700, 240));
      await tapLane(tester, 'g:Line 3', 300);
      await expectLater(find.byType(StopTimelineView),
          matchesGoldenFile('goldens/stop_timeline_callout_compact.png'));
    }, skip: !Platform.isMacOS);

    // --- hiding rows ----------------------------------------------------

    testWidgets('rows switched off go pale and empty', (tester) async {
      await pump(tester, harness(StopTimelineSpec(), Brightness.light),
          const Size(960, 480));
      await drillIntoMultivac(tester);
      await tester.tap(
          find.byKey(const ValueKey('stop-timeline-show-a:film-reel-empty')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(
          const ValueKey('stop-timeline-show-g:Line 3/Afak SL-15-3')));
      await tester.pumpAndSettle();
      await expectLater(find.byType(StopTimelineView),
          matchesGoldenFile('goldens/stop_timeline_hidden_rows.png'));
    }, skip: !Platform.isMacOS);

    testWidgets('a week-long picked range labels the days', (tester) async {
      // Seven midnight ticks all reading "00:00" said nothing; they name
      // their day instead.
      await pump(
          tester,
          harness(StopTimelineSpec(), Brightness.dark,
              range: DateTimeRange(
                  start: DateTime(2026, 8, 22, 14),
                  end: DateTime(2026, 8, 29, 14))),
          const Size(960, 480));
      await expectLater(find.byType(StopTimelineView),
          matchesGoldenFile('goldens/stop_timeline_week_range.png'));
    }, skip: !Platform.isMacOS);

    testWidgets('strip height drops the brush and detail row', (tester) async {
      await pump(
          tester,
          harness(StopTimelineSpec(), Brightness.dark,
              size: const Size(620, 150)),
          const Size(700, 240));
      await expectLater(find.byType(StopTimelineView),
          matchesGoldenFile('goldens/stop_timeline_strip.png'));
    }, skip: !Platform.isMacOS);

    // The box a freshly dropped asset gets: const StopTimelineSpec()'s
    // 40% x 30% of a 1920x1080 page. The size is only worth having as a
    // default if the chart is readable in it, so the golden is what says so.
    testWidgets('at the size it is dropped onto a page', (tester) async {
      await pump(
          tester,
          harness(const StopTimelineSpec(), Brightness.dark,
              size: const Size(768, 324)),
          const Size(860, 400));
      await expectLater(find.byType(StopTimelineView),
          matchesGoldenFile('goldens/stop_timeline_drop_size.png'));
    }, skip: !Platform.isMacOS);

    testWidgets('a group with no alarms says so', (tester) async {
      await pump(
          tester,
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: muted().$2,
            home: Scaffold(
              body: SizedBox(
                width: 700,
                height: 260,
                child: StopTimelineView(
                  config: StopTimelineSpec(groups: [
                    ['Line 9']
                  ]),
                  tree: AlarmTree.fromConfigs(alarms),
                  source: sampleSource(),
                  clock: now,
                ),
              ),
            ),
          ),
          const Size(760, 320));
      await expectLater(find.byType(StopTimelineView),
          matchesGoldenFile('goldens/stop_timeline_empty_group.png'));
    }, skip: !Platform.isMacOS);

    testWidgets('a picked range dates itself in the header and the strip',
        (tester) async {
      // Yesterday's night shift: the case the asset could not reach at all
      // before, and the one where an undated read-out would be a lie.
      await pump(
          tester,
          harness(
            StopTimelineSpec(),
            Brightness.dark,
            range: DateTimeRange(
                start: DateTime(2026, 8, 28, 22), end: DateTime(2026, 8, 29, 6)),
          ),
          const Size(960, 480));
      await expectLater(find.byType(StopTimelineView),
          matchesGoldenFile('goldens/stop_timeline_picked_range.png'));
    }, skip: !Platform.isMacOS);

    testWidgets('the period menu offers intervals and the date picker',
        (tester) async {
      // Whole-app, not the view: the menu lives in the overlay above it.
      await pump(tester, harness(StopTimelineSpec(), Brightness.dark),
          const Size(960, 480));
      await tester
          .tap(find.byKey(const ValueKey('stop-timeline-period-menu')));
      await tester.pumpAndSettle();
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('goldens/stop_timeline_period_menu.png'));
    }, skip: !Platform.isMacOS);
  });
}

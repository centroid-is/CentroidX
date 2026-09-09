import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/widgets/stop_timeline.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/alarm_interval.dart';
import 'package:tfc_dart/core/alarm_tree.dart';
import 'package:tfc_dart/core/boolean_expression.dart';
import 'package:tfc_dart/core/stop_interval_source.dart';

final now = DateTime(2026, 8, 29, 14, 22);
DateTime ago(int minutes) => now.subtract(Duration(minutes: minutes));

AlarmConfig alarm(
  String title, {
  required List<String> group,
  bool bindToGroup = false,
  AlarmLevel level = AlarmLevel.error,
}) =>
    AlarmConfig(
      uid: title.toLowerCase().replaceAll(' ', '-'),
      title: title,
      description: title,
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

final alarms = [
  alarm('Multivac stopped', group: ['Line 3', 'Multivac'], bindToGroup: true),
  alarm('Film reel empty', group: ['Line 3', 'Multivac']),
  alarm('Seal temperature out of band', group: ['Line 3', 'Multivac']),
  alarm('Link error', group: ['Infrastructure'], level: AlarmLevel.warning),
];

StopIntervalSource source() => StopIntervalSource(
      closed: [
        StopActivation(
          alarmUid: 'film-reel-empty',
          interval: AlarmInterval(
              start: ago(90), end: ago(70), level: AlarmLevel.error),
        ),
        StopActivation(
          alarmUid: 'multivac-stopped',
          interval: AlarmInterval(
              start: ago(150), end: ago(140), level: AlarmLevel.error),
        ),
        StopActivation(
          alarmUid: 'link-error',
          interval: AlarmInterval(
              start: ago(60), end: ago(50), level: AlarmLevel.warning),
        ),
      ],
      open: [
        StopActivation(
          alarmUid: 'seal-temperature-out-of-band',
          interval: AlarmInterval(
              start: ago(10), end: null, level: AlarmLevel.error),
        ),
      ],
    );

Future<void> pumpTimeline(
  WidgetTester tester, {
  StopTimelineSpec? config,
  List<AlarmConfig>? configs,
  StopIntervalSource? intervals,
  Size size = const Size(900, 420),
  DateTimeRange? range,
  Duration? interval,
  ValueChanged<DateTimeRange?>? onRangeChanged,
  ValueChanged<Duration>? onIntervalChanged,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: StopTimelineView(
            config: config ?? StopTimelineSpec(),
            tree: AlarmTree.fromConfigs(configs ?? alarms),
            source: intervals ?? source(),
            range: range,
            interval: interval,
            onRangeChanged: onRangeChanged,
            onIntervalChanged: onIntervalChanged,
            clock: now,
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

/// Opens the period menu in the header.
Future<void> openPeriodMenu(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('stop-timeline-period-menu')));
  await tester.pumpAndSettle();
}

void main() {
  group('StopTimelineView', () {
    testWidgets('starts collapsed, showing only the top-level groups',
        (tester) async {
      await pumpTimeline(tester);
      expect(find.text('Line 3'), findsOneWidget);
      expect(find.text('Infrastructure'), findsOneWidget);
      expect(find.text('Multivac'), findsNothing);
      expect(find.text('Film reel empty'), findsNothing);
    });

    testWidgets('expanding a group reveals what is inside it', (tester) async {
      await pumpTimeline(tester);
      await tester
          .tap(find.byKey(const ValueKey('stop-timeline-row-g:Line 3')));
      await tester.pumpAndSettle();

      expect(find.text('Multivac'), findsOneWidget);
      // still collapsed one level down
      expect(find.text('Film reel empty'), findsNothing);
    });

    testWidgets('drilling into a machine reaches the diagnosis',
        (tester) async {
      await pumpTimeline(tester);
      await tester
          .tap(find.byKey(const ValueKey('stop-timeline-row-g:Line 3')));
      await tester.pumpAndSettle();
      await tester.tap(
          find.byKey(const ValueKey('stop-timeline-row-g:Line 3/Multivac')));
      await tester.pumpAndSettle();

      expect(find.text('Film reel empty'), findsOneWidget);
      expect(find.text('Seal temperature out of band'), findsOneWidget);
    });

    testWidgets('a group with its own alarm lists it as well as its members',
        (tester) async {
      await pumpTimeline(tester);
      await tester
          .tap(find.byKey(const ValueKey('stop-timeline-row-g:Line 3')));
      await tester.pumpAndSettle();
      await tester.tap(
          find.byKey(const ValueKey('stop-timeline-row-g:Line 3/Multivac')));
      await tester.pumpAndSettle();

      // otherwise Multivac's lane would show intervals nothing under it
      // explains
      expect(find.text('Multivac stopped'), findsOneWidget);
    });

    testWidgets('collapsing again hides the subtree', (tester) async {
      await pumpTimeline(tester);
      final line3 =
          find.byKey(const ValueKey('stop-timeline-row-g:Line 3'));
      await tester.tap(line3);
      await tester.pumpAndSettle();
      expect(find.text('Multivac'), findsOneWidget);

      await tester.tap(line3);
      await tester.pumpAndSettle();
      expect(find.text('Multivac'), findsNothing);
    });

    testWidgets('the header counts only the alarms in scope', (tester) async {
      await pumpTimeline(tester,
          config: StopTimelineSpec(groups: [
            ['Infrastructure']
          ]));
      // one warning activation lives under Infrastructure; the three errors
      // are all in Line 3
      expect(find.text('Warning 1'), findsOneWidget);
      expect(find.text('Error 0'), findsOneWidget);
    });

    testWidgets('a scoped group is re-indented to the top level',
        (tester) async {
      await pumpTimeline(tester,
          config: StopTimelineSpec(groups: [
            ['Line 3', 'Multivac']
          ]));
      expect(find.text('Multivac'), findsOneWidget);
      expect(find.text('Line 3'), findsNothing);
      expect(find.text('Infrastructure'), findsNothing);
    });

    testWidgets('a group that no longer exists says so rather than drawing '
        'a convincing empty chart', (tester) async {
      await pumpTimeline(tester,
          config: StopTimelineSpec(groups: [
            ['Line 9']
          ]));
      expect(
          find.textContaining('No alarms are defined under'), findsOneWidget);
    });

    testWidgets('with no alarms configured at all it says that instead',
        (tester) async {
      await pumpTimeline(tester, configs: const []);
      expect(find.text('No alarms are configured yet.'), findsOneWidget);
    });

    testWidgets('a standing alarm is announced in the header', (tester) async {
      await pumpTimeline(tester);
      expect(find.text('1 standing'), findsOneWidget);
    });

    testWidgets('turning a severity off removes it from the lanes',
        (tester) async {
      await pumpTimeline(tester);
      // Infrastructure holds only the warning, so hiding warnings empties it
      expect(find.textContaining('10m · 1×'), findsWidgets);

      await tester.tap(
          find.byKey(const ValueKey('stop-timeline-level-warning')));
      await tester.pumpAndSettle();

      final infra = tester.widgetList<Text>(find.byType(Text)).map((t) => t.data);
      expect(infra.where((t) => t != null && t.contains('10m · 1×')), isEmpty);
    });

    testWidgets('the custom header text is used when set', (tester) async {
      await pumpTimeline(tester,
          config: StopTimelineSpec(headerText: 'Packing hall stops'));
      expect(find.text('Packing hall stops'), findsOneWidget);
      expect(find.text('Downtime'), findsNothing);
    });

    testWidgets('at strip height the brush and detail row are dropped',
        (tester) async {
      await pumpTimeline(tester, size: const Size(620, 150));
      expect(find.text('Select an activation to inspect it.'), findsNothing);
      // the lanes themselves survive
      expect(find.text('Line 3'), findsOneWidget);
    });

    testWidgets('at full height the detail row invites a selection',
        (tester) async {
      await pumpTimeline(tester);
      expect(
          find.text('Select an activation to inspect it.'), findsOneWidget);
    });
  });

  group('the Pareto table', () {
    Future<void> openTable(WidgetTester tester) async {
      await tester
          .tap(find.byKey(const ValueKey('stop-timeline-view-table')));
      await tester.pumpAndSettle();
    }

    testWidgets('switching to it replaces the lanes', (tester) async {
      await pumpTimeline(tester);
      await openTable(tester);
      expect(find.byKey(const ValueKey('stop-timeline-pareto')),
          findsOneWidget);
      // the detail row belongs to the timeline, not the table
      expect(find.text('Select an activation to inspect it.'), findsNothing);
    });

    testWidgets('ranks the most expensive alarm first', (tester) async {
      await pumpTimeline(tester);
      await openTable(tester);
      // film reel empty ran 20m; seal temperature has been standing 10m;
      // multivac stopped ran 10m; link error ran 10m
      final labels = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .whereType<String>()
          .toList();
      expect(labels, contains('Film reel empty'));
      expect(labels.indexOf('Film reel empty'),
          lessThan(labels.indexOf('Link error')));
    });

    testWidgets('grouping by group collapses a machine into one line',
        (tester) async {
      await pumpTimeline(tester);
      await openTable(tester);
      await tester
          .tap(find.byKey(const ValueKey('stop-timeline-pareto-group')));
      await tester.pumpAndSettle();

      expect(find.text('Line 3 › Multivac'), findsOneWidget);
      expect(find.text('Film reel empty'), findsNothing);
    });

    testWidgets('grouping by severity collapses to the three levels',
        (tester) async {
      await pumpTimeline(tester);
      await openTable(tester);
      await tester
          .tap(find.byKey(const ValueKey('stop-timeline-pareto-severity')));
      await tester.pumpAndSettle();

      expect(find.text('Error'), findsOneWidget);
      expect(find.text('Warning'), findsOneWidget);
    });

    testWidgets('ranking by count asks a different question than by time',
        (tester) async {
      await pumpTimeline(tester);
      await openTable(tester);
      await tester
          .tap(find.byKey(const ValueKey('stop-timeline-rank-count')));
      await tester.pumpAndSettle();
      // still a table, now ordered by frequency
      expect(find.byKey(const ValueKey('stop-timeline-pareto')),
          findsOneWidget);
    });

    testWidgets('an alarm that did not fire in the window is not listed',
        (tester) async {
      await pumpTimeline(tester,
          config: StopTimelineSpec(groups: [
            ['Infrastructure']
          ]));
      await openTable(tester);
      expect(find.text('Link error'), findsOneWidget);
      expect(find.text('Film reel empty'), findsNothing);
    });

    testWidgets('a severity turned off drops out of the ranking',
        (tester) async {
      await pumpTimeline(tester);
      await openTable(tester);
      expect(find.text('Link error'), findsOneWidget);

      await tester.tap(
          find.byKey(const ValueKey('stop-timeline-level-warning')));
      await tester.pumpAndSettle();
      expect(find.text('Link error'), findsNothing);
    });

    testWidgets('an empty window says so rather than showing a blank table',
        (tester) async {
      await pumpTimeline(tester, configs: const []);
      // no alarms at all, so the lanes say so and there is no table to open
      expect(find.text('No alarms are configured yet.'), findsOneWidget);
    });
  });


  group('the period picker', () {
    testWidgets('the live window reads out as bare times', (tester) async {
      await pumpTimeline(tester);
      // Three hours back plus the ten-minute lead over the live edge.
      expect(find.text('11:22 – 14:32'), findsOneWidget);
    });

    testWidgets('a picked range is shown whole, and dated', (tester) async {
      await pumpTimeline(
        tester,
        range: DateTimeRange(
            start: DateTime(2026, 8, 28, 6), end: DateTime(2026, 8, 28, 14)),
      );
      // Without the date this reads as today, which is the one thing the
      // operator who went looking for yesterday must not be told.
      expect(find.text('28/08 06:00 – 14:00'), findsOneWidget);
    });

    testWidgets('a range across midnight names both days', (tester) async {
      await pumpTimeline(
        tester,
        range: DateTimeRange(
            start: DateTime(2026, 8, 28, 22), end: DateTime(2026, 8, 29, 6)),
      );
      expect(find.text('28/08 22:00 – 29/08 06:00'), findsOneWidget);
    });

    testWidgets('the overview strip is labelled with the days it covers',
        (tester) async {
      await pumpTimeline(
        tester,
        range: DateTimeRange(
            start: DateTime(2026, 8, 28, 22), end: DateTime(2026, 8, 29, 6)),
      );
      expect(find.text('28/08 – 29/08'), findsOneWidget);
    });

    testWidgets('a runtime interval overrides the configured period',
        (tester) async {
      await pumpTimeline(tester, interval: const Duration(hours: 1));
      // The whole picked hour, plus the proportional live pad (1h / 20 = 3m).
      expect(find.text('13:22 – 14:25'), findsOneWidget);
      // The strip covers the interval, so it is still today.
      expect(find.text('29/08'), findsOneWidget);
    });

    testWidgets('a picked interval opens showing the whole span',
        (tester) async {
      // "Last 8 hours" answered with the same three-hour window as before
      // looked like a dead control; the pick is the ask. The live pad is
      // 8h / 20 = 24m, capped at ten minutes.
      await pumpTimeline(tester, interval: const Duration(hours: 8));
      expect(find.text('06:22 – 14:32'), findsOneWidget);
    });

    testWidgets('picking an interval reports the span', (tester) async {
      Duration? picked;
      await pumpTimeline(tester, onIntervalChanged: (d) => picked = d);
      await openPeriodMenu(tester);
      await tester
          .tap(find.byKey(const ValueKey('stop-timeline-interval-480')));
      await tester.pumpAndSettle();
      expect(picked, const Duration(hours: 8));
    });

    testWidgets('the interval in force is the ticked one', (tester) async {
      await pumpTimeline(tester, config: StopTimelineSpec(periodHours: 24));
      await openPeriodMenu(tester);
      CheckedPopupMenuItem<Object> item(int minutes) =>
          tester.widget<CheckedPopupMenuItem<Object>>(
              find.byKey(ValueKey('stop-timeline-interval-$minutes')));
      expect(item(24 * 60).checked, isTrue);
      expect(item(12 * 60).checked, isFalse);
    });

    testWidgets('an absolute range ticks no interval', (tester) async {
      await pumpTimeline(
        tester,
        range: DateTimeRange(
            start: DateTime(2026, 8, 28, 2), end: DateTime(2026, 8, 28, 14)),
      );
      await openPeriodMenu(tester);
      // Twelve hours, the configured period, but it is not what is showing.
      expect(
          tester
              .widget<CheckedPopupMenuItem<Object>>(
                  find.byKey(const ValueKey('stop-timeline-interval-720')))
              .checked,
          isFalse);
    });

    testWidgets('only a picked range offers the way back to live',
        (tester) async {
      await pumpTimeline(tester);
      await openPeriodMenu(tester);
      expect(find.text('Back to live'), findsNothing);
      await tester.tapAt(const Offset(10, 10)); // dismiss
      await tester.pumpAndSettle();

      var cleared = false;
      DateTimeRange? reported;
      await pumpTimeline(
        tester,
        range: DateTimeRange(
            start: DateTime(2026, 8, 28, 2), end: DateTime(2026, 8, 28, 14)),
        onRangeChanged: (r) {
          cleared = true;
          reported = r;
        },
      );
      await openPeriodMenu(tester);
      await tester.tap(find.text('Back to live'));
      await tester.pumpAndSettle();
      expect(cleared, isTrue);
      expect(reported, isNull);
    });

    testWidgets('a new period starts the view over at the top of it',
        (tester) async {
      await pumpTimeline(tester);
      expect(find.text('11:22 – 14:32'), findsOneWidget);

      // Same widget, new range: the old window is outside the new bounds and
      // must not be dragged to an edge by the clamp.
      await pumpTimeline(
        tester,
        range: DateTimeRange(
            start: DateTime(2026, 8, 27, 6), end: DateTime(2026, 8, 27, 18)),
      );
      expect(find.text('27/08 06:00 – 18:00'), findsOneWidget);
      expect(find.text('11:22 – 14:32'), findsNothing);
    });
  });

  group('an alarm standing longer than the window', () {
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

    testWidgets('the detail row says which day it started', (tester) async {
      await pumpTimeline(tester, intervals: sinceYesterday);

      // The bar fills the whole visible window; tap it anywhere right of the
      // label column, on the collapsed Line 3 group lane.
      final label =
          tester.getRect(find.byKey(const ValueKey('stop-timeline-row-g:Line 3')));
      await tester.tapAt(Offset(label.right + 120, label.center.dy));
      await tester.pumpAndSettle();

      // Started 28/08 12:22 — "Since 12:22:10" alone would read as today.
      expect(find.textContaining('Since 28/08 12:22:00'), findsOneWidget);
      expect(find.textContaining('still standing'), findsOneWidget);
      expect(find.textContaining('26h 00m'), findsOneWidget,
          reason: 'hour precision holds until two days; beyond that '
              '_durShort switches to days');
    });

    testWidgets('the lane statistic clamps to the window', (tester) async {
      await pumpTimeline(tester, intervals: sinceYesterday);
      // Opening window is the last 3h (+pad): in-window standing time is 3h,
      // not the alarm\'s 26h lifetime.
      expect(find.textContaining('now · 3h 00m · 1×'), findsOneWidget);
    });
  });
}

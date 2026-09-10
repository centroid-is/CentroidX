import 'package:flutter/gestures.dart' show PointerDeviceKind;
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

/// Four alarms under Multivac whose activations run into one another, so a
/// collapsed group draws them as a single stretch — the case an operator taps
/// and gets no answer from.
final crowdedAlarms = [
  ...alarms,
  alarm('Vacuum low', group: ['Line 3', 'Multivac']),
  alarm('Line stopped from panel', group: ['Line 3']),
  alarm('Afak jam', group: ['Line 3', 'Afak SL-15-3']),
];

StopIntervalSource get overlappingUnderMultivac => StopIntervalSource(
      closed: [
        StopActivation(
          alarmUid: 'seal-temperature-out-of-band',
          interval: AlarmInterval(
              start: ago(50), end: ago(20), level: AlarmLevel.error),
        ),
        StopActivation(
          alarmUid: 'film-reel-empty',
          interval: AlarmInterval(
              start: ago(45), end: ago(25), level: AlarmLevel.error),
        ),
        StopActivation(
          alarmUid: 'vacuum-low',
          interval: AlarmInterval(
              start: ago(42), end: ago(32), level: AlarmLevel.error),
        ),
        StopActivation(
          alarmUid: 'multivac-stopped',
          interval: AlarmInterval(
              start: ago(40), end: ago(35), level: AlarmLevel.error),
        ),
      ],
      open: const [],
    );

/// Six alarms in one stretch, so the bubble has to leave two of them out.
StopIntervalSource get sixUnderMultivac => StopIntervalSource(
      closed: [
        for (final (uid, from, to) in [
          ('seal-temperature-out-of-band', 50, 20),
          ('film-reel-empty', 48, 25),
          ('vacuum-low', 46, 32),
          ('multivac-stopped', 44, 35),
          ('line-stopped-from-panel', 42, 36),
          ('afak-jam', 40, 22),
        ])
          StopActivation(
            alarmUid: uid,
            interval:
                AlarmInterval(start: ago(from), end: ago(to), level: AlarmLevel.error),
          ),
      ],
      open: const [],
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

/// The axis tick labels, which are the visible proof of where the window sits
/// and how wide it is.
List<String> axisTicks(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data)
    .whereType<String>()
    .where((d) => RegExp(r'^\d\d:\d\d$').hasMatch(d))
    .toList();

/// A point on the empty ground below the last lane row, right of the label
/// column — where an operator lands when they miss the rows.
Offset belowTheRows(WidgetTester tester) {
  final view = tester.getRect(find.byType(StopTimelineView));
  return Offset(view.left + 500, view.bottom - 70);
}

const activationCallout = ValueKey('stop-timeline-activation-callout');
const alarmCallout = ValueKey('stop-timeline-alarm-callout');

/// Taps a lane's bars [dx] pixels right of the label column, on the row keyed
/// [rowKey] — the way an operator picks an activation.
Future<void> tapLane(WidgetTester tester, String rowKey, double dx) async {
  final label =
      tester.getRect(find.byKey(ValueKey('stop-timeline-row-$rowKey')));
  await tester.tapAt(Offset(label.right + dx, label.center.dy));
  await tester.pumpAndSettle();
}

/// Where the middle of an interval lands, in pixels right of the label
/// column, in the window the view opens on: the last three hours, plus the
/// live pad for the configured twelve-hour period (12h/20, clamped to ten
/// minutes).
double xOfInterval(WidgetTester tester, DateTime start, DateTime end) {
  final laneWidth = tester.getRect(find.byType(StopTimelineView)).width - 210;
  final windowStart = now.subtract(const Duration(hours: 3));
  final windowEnd = now.add(const Duration(minutes: 10));
  final span = windowEnd.difference(windowStart).inMicroseconds;
  final mid = start.add(end.difference(start) ~/ 2);
  return mid.difference(windowStart).inMicroseconds / span * laneWidth;
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

    testWidgets('at strip height the overview brush is dropped',
        (tester) async {
      await pumpTimeline(tester, size: const Size(620, 150));
      // the brush is the only thing carrying the period's day label
      expect(find.text('29/08'), findsNothing);
      // the lanes themselves survive
      expect(find.text('Line 3'), findsOneWidget);
    });

    testWidgets('nothing is called out until something is tapped',
        (tester) async {
      await pumpTimeline(tester);
      expect(find.byKey(activationCallout), findsNothing);
      expect(find.byKey(alarmCallout), findsNothing);
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
      // callouts belong to the lanes, not to the table
      expect(find.byKey(activationCallout), findsNothing);
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

    testWidgets('every column says what it is, the notch included',
        (tester) async {
      await pumpTimeline(tester);
      await openTable(tester);
      // The bar and the hairline beside it are two different quantities, and
      // the % column is a third; unlabelled, the notch is unguessable.
      expect(find.text('ALARM'), findsOneWidget);
      expect(find.text('IN GROUP'), findsOneWidget);
      expect(find.text('STOPS'), findsOneWidget);
      expect(find.text('LOST'), findsOneWidget);
      expect(find.text('SHARE'), findsOneWidget);
      expect(find.text('RUNNING TOTAL'), findsOneWidget);
    });

    testWidgets('the heading follows what the rows are grouped by',
        (tester) async {
      await pumpTimeline(tester);
      await openTable(tester);
      await tester
          .tap(find.byKey(const ValueKey('stop-timeline-pareto-severity')));
      await tester.pumpAndSettle();
      expect(find.text('SEVERITY'), findsOneWidget);
      // Severities have no group to sit in, so that column is gone with it.
      expect(find.text('IN GROUP'), findsNothing);
    });

    testWidgets('the table names the window it is ranking', (tester) async {
      await pumpTimeline(tester);
      await openTable(tester);
      // Without lanes or an axis, this is the only thing on screen that says
      // the ranking is windowed — and so the only thing that explains the
      // strip along the bottom.
      final label = tester
          .widget<Text>(
              find.byKey(const ValueKey('stop-timeline-pareto-window')))
          .data;
      expect(label, startsWith('ranked over '));
      expect(label, contains('–'));
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

    testWidgets('the callout says which day it started', (tester) async {
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
      // Twice over now — once on the stretch, once on the alarm the group
      // bubble names underneath it — so the assertion has to say which.
      expect(find.textContaining('still standing · 26h 00m'), findsOneWidget,
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

  group('the activation callout', () {
    // 'film-reel-empty' stood 90..70 minutes ago; the opening window is the
    // last three hours, so it lands well inside the lane.
    Future<void> openMultivac(WidgetTester tester) async {
      await tester
          .tap(find.byKey(const ValueKey('stop-timeline-row-g:Line 3')));
      await tester.pumpAndSettle();
      await tester.tap(
          find.byKey(const ValueKey('stop-timeline-row-g:Line 3/Multivac')));
      await tester.pumpAndSettle();
    }

    testWidgets('tapping a bar names the alarm, where it is and when it ran',
        (tester) async {
      await pumpTimeline(tester);
      await openMultivac(tester);
      await tapLane(tester, 'a:film-reel-empty',
          xOfInterval(tester, ago(90), ago(70)));

      expect(find.byKey(activationCallout), findsOneWidget);
      expect(find.text('Film reel empty'), findsNWidgets(2),
          reason: 'the lane label and the callout both name it');
      expect(find.text('Line 3 › Multivac'), findsOneWidget);
      expect(find.textContaining('12:52:00 – 13:12:00'), findsOneWidget);
      expect(find.textContaining('20m'), findsWidgets);
    });

    testWidgets('tapping the same bar again closes it', (tester) async {
      await pumpTimeline(tester);
      await openMultivac(tester);
      final x = xOfInterval(tester, ago(90), ago(70));
      await tapLane(tester, 'a:film-reel-empty', x);
      expect(find.byKey(activationCallout), findsOneWidget);
      await tapLane(tester, 'a:film-reel-empty', x);
      expect(find.byKey(activationCallout), findsNothing);
    });

    testWidgets('tapping empty lane space closes it', (tester) async {
      await pumpTimeline(tester);
      await openMultivac(tester);
      await tapLane(tester, 'a:film-reel-empty',
          xOfInterval(tester, ago(90), ago(70)));
      expect(find.byKey(activationCallout), findsOneWidget);
      // 2 minutes ago on the same lane: nothing stood there.
      await tapLane(
          tester, 'a:film-reel-empty', xOfInterval(tester, ago(2), ago(2)));
      expect(find.byKey(activationCallout), findsNothing);
    });

    testWidgets('a still-standing activation is called out as such',
        (tester) async {
      await pumpTimeline(tester);
      await openMultivac(tester);
      await tapLane(tester, 'a:seal-temperature-out-of-band',
          xOfInterval(tester, ago(10), now));
      expect(find.textContaining('still standing'), findsOneWidget);
      expect(find.textContaining('Since 14:12:00'), findsOneWidget);
    });

    testWidgets('a collapsed group names what stood inside it',
        (tester) async {
      await pumpTimeline(tester);
      // Line 3 collapsed: its bar is the union of everything underneath.
      await tapLane(
          tester, 'g:Line 3', xOfInterval(tester, ago(90), ago(70)));
      expect(find.byKey(activationCallout), findsOneWidget);
      // The count was never the answer to "what stopped?".
      expect(find.textContaining('inside this group'), findsNothing);
      expect(
          find.byKey(const ValueKey('stop-timeline-contributor-film-reel-empty')),
          findsOneWidget);
      expect(find.text('Film reel empty'), findsWidgets);
      expect(find.textContaining('12:52:00 · 20m'), findsOneWidget);
    });

    testWidgets('the named stops read in the order they fired',
        (tester) async {
      await pumpTimeline(tester,
          configs: crowdedAlarms, intervals: overlappingUnderMultivac);
      // Multivac collapsed inside Line 3: one stretch, four alarms in it.
      await tapLane(
          tester, 'g:Line 3', xOfInterval(tester, ago(50), ago(20)));
      final lines = tester
          .widgetList<Text>(find.descendant(
              of: find.byKey(activationCallout),
              matching: find.byType(Text)))
          .map((t) => t.data)
          .whereType<String>()
          .toList();
      // Seal fired at -50, film at -45, vacuum at -42, multivac at -40. The
      // first to fire is usually the cause of the ones after it, so the list
      // is the story of the stop, not a ranking.
      expect(lines.indexOf('Seal temperature out of band'),
          lessThan(lines.indexOf('Film reel empty')));
      expect(lines.indexOf('Film reel empty'),
          lessThan(lines.indexOf('Vacuum low')));
      expect(lines.indexOf('Vacuum low'),
          lessThan(lines.indexOf('Multivac stopped')));
    });

    testWidgets('more than fits collapses into a counted tail',
        (tester) async {
      await pumpTimeline(tester,
          configs: crowdedAlarms, intervals: sixUnderMultivac);
      await tapLane(
          tester, 'g:Line 3', xOfInterval(tester, ago(50), ago(20)));
      expect(
          find.byKey(const ValueKey('stop-timeline-contributors-more')),
          findsOneWidget);
      expect(find.text('and 2 more'), findsOneWidget);
    });

    testWidgets('a severity switched off drops its alarms from the list',
        (tester) async {
      // The bubble must be filtered exactly the way the bar it points at is —
      // one predicate, or it names alarms the bar excludes.
      await pumpTimeline(tester,
          configs: crowdedAlarms, intervals: overlappingUnderMultivac);
      await tapLane(
          tester, 'g:Line 3', xOfInterval(tester, ago(50), ago(20)));
      expect(find.text('Vacuum low'), findsWidgets);
      await tester
          .tap(find.byKey(const ValueKey('stop-timeline-level-error')));
      await tester.pumpAndSettle();
      // Every one of them was an error, so the bar and the bubble empty out
      // together rather than disagreeing.
      expect(find.byKey(activationCallout), findsNothing);
    });

    testWidgets('an alarm that is its own group jumps to the group row',
        (tester) async {
      // 'Strapper stopped' is bound to Afak SL-15-3 and has no siblings, so
      // AlarmTree folds it into the group line and it has no leaf row of its
      // own. Aiming at one would expand the tree, find nothing, and leave the
      // operator with the bubble gone and no answer.
      final bound = [
        alarm('Line 3 halted', group: ['Line 3'], bindToGroup: true),
        alarm('Strapper stopped',
            group: ['Line 3', 'Afak SL-15-3'], bindToGroup: true),
      ];
      await pumpTimeline(
        tester,
        configs: bound,
        intervals: StopIntervalSource(
          closed: [
            StopActivation(
              alarmUid: 'strapper-stopped',
              interval: AlarmInterval(
                  start: ago(50), end: ago(20), level: AlarmLevel.error),
            ),
          ],
          open: const [],
        ),
      );
      await tapLane(
          tester, 'g:Line 3', xOfInterval(tester, ago(50), ago(20)));
      await tester.tap(find
          .byKey(const ValueKey('stop-timeline-contributor-strapper-stopped')));
      await tester.pumpAndSettle();
      // It landed somewhere real: the callout is still open, on the row that
      // actually carries the alarm.
      expect(find.byKey(activationCallout), findsOneWidget);
      expect(
          find.byKey(
              const ValueKey('stop-timeline-row-a:strapper-stopped')),
          findsNothing,
          reason: 'a bound alarm with no siblings has no leaf row');
      expect(
          find.byKey(
              const ValueKey('stop-timeline-row-g:Line 3/Afak SL-15-3')),
          findsOneWidget);
    });

    testWidgets('an alarm standing under two rules is named once',
        (tester) async {
      // AlarmMan keys its active set by (uid, rule), so one alarm can stand
      // twice over. The bubble is about alarms, not about rows in a table.
      await pumpTimeline(
        tester,
        intervals: StopIntervalSource(
          closed: [
            StopActivation(
              alarmUid: 'film-reel-empty',
              interval: AlarmInterval(
                  start: ago(50), end: ago(30), level: AlarmLevel.warning),
            ),
            StopActivation(
              alarmUid: 'film-reel-empty',
              interval: AlarmInterval(
                  start: ago(40), end: ago(20), level: AlarmLevel.error),
            ),
          ],
          open: const [],
        ),
      );
      await tapLane(tester, 'g:Line 3', xOfInterval(tester, ago(50), ago(20)));
      expect(find.text('Film reel empty'), findsOneWidget);
      // 50→20 merged, not 20m + 20m summed, and the worse rule is the one
      // the mark reports.
      expect(find.textContaining('· 30m'), findsWidgets);
      expect(find.text('2×'), findsOneWidget);
    });

    testWidgets('tapping a named stop jumps to its own lane', (tester) async {
      await pumpTimeline(tester,
          configs: crowdedAlarms, intervals: overlappingUnderMultivac);
      await tapLane(
          tester, 'g:Line 3', xOfInterval(tester, ago(50), ago(20)));
      await tester.tap(find
          .byKey(const ValueKey('stop-timeline-contributor-film-reel-empty')));
      await tester.pumpAndSettle();
      // The tree opened down to it, and its own bar is the one called out.
      expect(find.byKey(const ValueKey('stop-timeline-row-a:film-reel-empty')),
          findsOneWidget);
      expect(find.byKey(activationCallout), findsOneWidget);
      expect(find.textContaining('inside this group'), findsNothing);
      // The leaf callout names the alarm itself, not the branch.
      expect(find.text('Film reel empty'), findsWidgets);
    });

    testWidgets('a switched-off alarm is not named under its group',
        (tester) async {
      await pumpTimeline(tester,
          configs: crowdedAlarms, intervals: overlappingUnderMultivac);
      // Down to the leaf, then untick it.
      await tester.tap(find.byKey(const ValueKey('stop-timeline-row-g:Line 3')));
      await tester.pumpAndSettle();
      await tester.tap(
          find.byKey(const ValueKey('stop-timeline-row-g:Line 3/Multivac')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(const ValueKey('stop-timeline-show-a:film-reel-empty')));
      await tester.pumpAndSettle();
      await tapLane(
          tester, 'g:Line 3/Multivac', xOfInterval(tester, ago(50), ago(20)));
      expect(
          find.byKey(const ValueKey('stop-timeline-contributor-film-reel-empty')),
          findsNothing);
      expect(
          find.byKey(
              const ValueKey('stop-timeline-contributor-seal-temperature-out-of-band')),
          findsOneWidget);
    });

    testWidgets('a refresh that still holds the interval keeps it open',
        (tester) async {
      await pumpTimeline(tester);
      await openMultivac(tester);
      await tapLane(tester, 'a:film-reel-empty',
          xOfInterval(tester, ago(90), ago(70)));
      expect(find.byKey(activationCallout), findsOneWidget);

      // A fresh fetch: same activations, brand new objects. The selection is
      // held as coordinates and re-resolved against the new series each
      // build, which is the only reason this survives.
      await pumpTimeline(tester, intervals: source());
      expect(find.byKey(activationCallout), findsOneWidget);
    });

    testWidgets('panning far enough takes the callout off with its bar',
        (tester) async {
      await pumpTimeline(tester);
      await openMultivac(tester);
      final label = tester
          .getRect(find.byKey(const ValueKey('stop-timeline-row-a:film-reel-empty')));
      await tester.tapAt(Offset(
          label.right + xOfInterval(tester, ago(90), ago(70)),
          label.center.dy));
      await tester.pumpAndSettle();
      expect(find.byKey(activationCallout), findsOneWidget);

      // Drag right — back in time — until the bar is off the right edge.
      final onLane = Offset(label.right + 200, label.center.dy);
      await tester.dragFrom(onLane, const Offset(900, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(activationCallout), findsNothing);

      // ...and comes back with it.
      await tester.dragFrom(onLane, const Offset(-900, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(activationCallout), findsOneWidget);
    });

  });

  group('the alarm identity callout', () {
    testWidgets('tapping a leaf shows the title the column had to cut short',
        (tester) async {
      await pumpTimeline(tester);
      await tester
          .tap(find.byKey(const ValueKey('stop-timeline-row-g:Line 3')));
      await tester.pumpAndSettle();
      await tester.tap(
          find.byKey(const ValueKey('stop-timeline-row-g:Line 3/Multivac')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(
          const ValueKey('stop-timeline-row-a:seal-temperature-out-of-band')));
      await tester.pumpAndSettle();

      expect(find.byKey(alarmCallout), findsOneWidget);
      expect(find.text('Error · Line 3 › Multivac'), findsOneWidget);
      expect(find.textContaining('In view:'), findsOneWidget);
      expect(find.textContaining('Standing now'), findsOneWidget);
    });

    testWidgets('tapping it again closes it', (tester) async {
      await pumpTimeline(tester);
      await tester
          .tap(find.byKey(const ValueKey('stop-timeline-row-g:Infrastructure')));
      await tester.pumpAndSettle();
      final leaf = find.byKey(const ValueKey('stop-timeline-row-a:link-error'));
      await tester.tap(leaf);
      await tester.pumpAndSettle();
      expect(find.byKey(alarmCallout), findsOneWidget);
      await tester.tap(leaf);
      await tester.pumpAndSettle();
      expect(find.byKey(alarmCallout), findsNothing);
    });

    testWidgets('an expandable group still expands and calls out nothing',
        (tester) async {
      await pumpTimeline(tester);
      await tester
          .tap(find.byKey(const ValueKey('stop-timeline-row-g:Line 3')));
      await tester.pumpAndSettle();
      expect(find.text('Multivac'), findsOneWidget);
      expect(find.byKey(alarmCallout), findsNothing);
    });

    testWidgets('a bound alarm says it stands for the whole group',
        (tester) async {
      await pumpTimeline(tester);
      await tester
          .tap(find.byKey(const ValueKey('stop-timeline-row-g:Line 3')));
      await tester.pumpAndSettle();
      await tester.tap(
          find.byKey(const ValueKey('stop-timeline-row-g:Line 3/Multivac')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(
          const ValueKey('stop-timeline-row-a:multivac-stopped')));
      await tester.pumpAndSettle();
      expect(find.text('Covers the whole group.'), findsOneWidget);
    });

    testWidgets('opening one callout closes the other', (tester) async {
      await pumpTimeline(tester);
      await tester
          .tap(find.byKey(const ValueKey('stop-timeline-row-g:Line 3')));
      await tester.pumpAndSettle();
      await tester.tap(
          find.byKey(const ValueKey('stop-timeline-row-g:Line 3/Multivac')));
      await tester.pumpAndSettle();

      await tapLane(tester, 'a:film-reel-empty',
          xOfInterval(tester, ago(90), ago(70)));
      expect(find.byKey(activationCallout), findsOneWidget);

      await tester.tap(find.byKey(
          const ValueKey('stop-timeline-row-a:seal-temperature-out-of-band')));
      await tester.pumpAndSettle();
      expect(find.byKey(alarmCallout), findsOneWidget);
      expect(find.byKey(activationCallout), findsNothing);
    });
  });

  group('hiding a row', () {
    testWidgets('unticking a leaf empties its lane and its group', (tester) async {
      await pumpTimeline(tester);
      await tester
          .tap(find.byKey(const ValueKey('stop-timeline-row-g:Line 3')));
      await tester.pumpAndSettle();
      await tester.tap(
          find.byKey(const ValueKey('stop-timeline-row-g:Line 3/Multivac')));
      await tester.pumpAndSettle();

      // Multivac's statistic before: three activations under it.
      expect(find.textContaining('3×'), findsWidgets);

      await tester.tap(find.byKey(
          const ValueKey('stop-timeline-show-a:film-reel-empty')));
      await tester.pumpAndSettle();

      // The row stays — it is the way back — but reports nothing.
      expect(find.text('Film reel empty'), findsOneWidget);
      expect(find.textContaining('3×'), findsNothing);
    });

    testWidgets('unticking a group takes its subtree with it', (tester) async {
      await pumpTimeline(tester);
      await tester
          .tap(find.byKey(const ValueKey('stop-timeline-row-g:Line 3')));
      await tester.pumpAndSettle();
      expect(find.text('Multivac'), findsOneWidget);

      await tester
          .tap(find.byKey(const ValueKey('stop-timeline-show-g:Line 3')));
      await tester.pumpAndSettle();

      expect(find.text('Line 3'), findsOneWidget);
      expect(find.text('Multivac'), findsNothing);
    });

    testWidgets('ticking it again brings everything back', (tester) async {
      await pumpTimeline(tester);
      final box = find.byKey(const ValueKey('stop-timeline-show-g:Line 3'));
      await tester.tap(box);
      await tester.pumpAndSettle();
      await tester.tap(box);
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(const ValueKey('stop-timeline-row-g:Line 3')));
      await tester.pumpAndSettle();
      expect(find.text('Multivac'), findsOneWidget);
    });

    testWidgets('the box does not expand the group it sits on', (tester) async {
      await pumpTimeline(tester);
      await tester
          .tap(find.byKey(const ValueKey('stop-timeline-show-g:Line 3')));
      await tester.pumpAndSettle();
      expect(find.text('Multivac'), findsNothing);
    });

    testWidgets('hiding a row closes a callout describing it', (tester) async {
      await pumpTimeline(tester);
      await tapLane(tester, 'g:Line 3', xOfInterval(tester, ago(90), ago(70)));
      expect(find.byKey(activationCallout), findsOneWidget);
      await tester
          .tap(find.byKey(const ValueKey('stop-timeline-show-g:Line 3')));
      await tester.pumpAndSettle();
      expect(find.byKey(activationCallout), findsNothing);
    });
  });

  group('the ground below the last row', () {
    // The chart reads as one surface, so an operator who lands in the gap
    // under the last alarm is still pointing at it.
    testWidgets('drags the window like a lane does', (tester) async {
      await pumpTimeline(tester);
      final before = axisTicks(tester);
      // Rightwards, into the past: the window opens docked to the live edge,
      // so a leftward drag has nowhere to go.
      await tester.dragFrom(belowTheRows(tester), const Offset(200, 0));
      await tester.pumpAndSettle();
      expect(axisTicks(tester), isNot(before));
      expect(axisTicks(tester).first.compareTo(before.first), isNegative,
          reason: 'the window moved backwards in time');
    });

    testWidgets('the wheel over it changes the span', (tester) async {
      await pumpTimeline(tester);
      final before = axisTicks(tester);
      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(belowTheRows(tester)));
      for (var i = 0; i < 5; i++) {
        await tester.sendEventToBinding(mouse.scroll(const Offset(0, 120)));
        await tester.pumpAndSettle();
      }
      // Zoomed out far enough that the ticks are hours, not half hours.
      final widened = axisTicks(tester);
      expect(widened, isNot(before));
      expect(widened.every((t) => t.endsWith(':00')), isTrue);

      for (var i = 0; i < 9; i++) {
        await tester.sendEventToBinding(mouse.scroll(const Offset(0, -120)));
        await tester.pumpAndSettle();
      }
      // And back in past where it started: quarter hours.
      expect(axisTicks(tester).any((t) => t.endsWith(':15')), isTrue);
    });

    testWidgets('a tap on it puts an open callout down', (tester) async {
      await pumpTimeline(tester);
      await tapLane(tester, 'g:Line 3', xOfInterval(tester, ago(90), ago(70)));
      expect(find.byKey(activationCallout), findsOneWidget);
      await tester.tapAt(belowTheRows(tester));
      await tester.pumpAndSettle();
      expect(find.byKey(activationCallout), findsNothing);
    });
  });

}

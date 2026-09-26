/// Shared fixture for the alarm list tests: a hand-built [AlarmActive] and an
/// [AlarmMan] that is nothing but the two streams the list reads.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tfc/providers/alarm.dart';
import 'package:tfc/theme.dart' show solarized;
import 'package:tfc/widgets/alarm.dart';
import 'package:tfc/widgets/period_menu.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/boolean_expression.dart';

/// One alarm, [uid] doubling as its title so a list row is findable by name.
///
/// [ended] set means it has deactivated — the state AlarmMan puts an alarm in
/// when it files it into the history buffer.
AlarmActive alarm(
  String uid, {
  AlarmLevel level = AlarmLevel.error,
  required DateTime at,
  DateTime? ended,
  String description = '',
  List<String> staleInputs = const [],
  DateTime? staleSince,
}) {
  final rule = AlarmRule(
    level: level,
    expression: ExpressionConfig(value: Expression(formula: 'x')),
    acknowledgeRequired: false,
  );
  return AlarmActive(
    alarm: Alarm(
      config: AlarmConfig(
        uid: uid,
        title: uid,
        description: description,
        rules: [rule],
      ),
    ),
    notification: AlarmNotification(
      uid: uid,
      active: ended == null,
      expression: 'x',
      rule: rule,
      timestamp: at,
      staleInputs: staleInputs,
      staleSince: staleSince,
    ),
    deactivated: ended,
  );
}

/// An [AlarmMan] with a fixed active set and history buffer.
///
/// `implements AlarmMan` rather than a subclass: the real one has a private
/// constructor and opens an OPC UA evaluation stream per alarm. Anything the
/// widget reaches for beyond these four falls through to [noSuchMethod] and
/// throws loudly.
class AlarmFixture implements AlarmMan {
  AlarmFixture({
    this.active = const {},
    this.past = const [],
    this.stored = const [],
  });

  final Set<AlarmActive> active;

  /// What the in-memory ring holds: the clears this station saw.
  final List<AlarmActive?> past;

  /// What `alarm_history` holds — the rows only a database read reaches.
  /// Empty in most tests, where the ring is the whole record.
  final List<AlarmActive> stored;

  /// The windows [getRecentAlarms] was asked for, newest last, so a test can
  /// assert that the period control reached the query and not just the list.
  final List<DateTimeRange> reads = [];

  @override
  Stream<Set<AlarmActive>> activeAlarms() => Stream.value(active);

  @override
  Stream<List<AlarmActive?>> history() => Stream.value(past);

  /// Overlap, the way the real one bounds it: an alarm that went off before
  /// the window and cleared inside it belongs to that window.
  @override
  Future<List<AlarmActive>> getRecentAlarms({
    int limit = 1000,
    DateTime? from,
    DateTime? to,
  }) async {
    if (from != null && to != null) {
      reads.add(DateTimeRange(start: from, end: to));
    }
    return [
      for (final row in stored)
        if ((to == null || !row.notification.timestamp.isAfter(to)) &&
            (from == null ||
                row.deactivated == null ||
                !row.deactivated!.isBefore(from)))
          row
    ];
  }

  /// The real one collapses an alarm's rules to its worst and fuzzy-matches
  /// the query; the list tests are about what happens after that.
  @override
  List<AlarmActive> filterAlarms(List<AlarmActive> alarms, String query) =>
      alarms;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The clock the list fixtures run on.
///
/// The History list is bounded by a rolling period now, so a fixture built
/// out of fixed dates needs a fixed "now" to sit inside — otherwise every
/// test in this file would start failing the day after it was written.
final alarmFixtureClock = DateTime(2026, 8, 29, 12);

/// The alarm list in a column [width] wide, the way the Alarm View page hands
/// it 2/5 of the window.
///
/// [extraOverrides] lets an arm drive the providers the list reads beside the
/// alarm source — the local gateway alarm, for one. [clock] and [pickRange]
/// drive the History period control; both default to what a golden needs.
Widget alarmList(
  AlarmFixture alarms, {
  double width = 520,
  bool dark = false,
  List<Override> extraOverrides = const [],
  DateTime? clock,
  PeriodRangePicker? pickRange,
}) {
  final (light, darkTheme) = solarized();
  return ProviderScope(
    overrides: [
      alarmManProvider.overrideWith((ref) async => alarms),
      ...extraOverrides,
    ],
    child: MaterialApp(
      theme: dark ? darkTheme : light,
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            height: 600,
            child: ListActiveAlarms(
              clock: clock ?? alarmFixtureClock,
              pickRange: pickRange ?? (_, __) async => null,
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> pumpAlarmList(
  WidgetTester tester,
  AlarmFixture alarms, {
  double width = 520,
  bool dark = false,
  List<Override> extraOverrides = const [],
  DateTime? clock,
  PeriodRangePicker? pickRange,
}) async {
  await tester.pumpWidget(alarmList(alarms,
      width: width,
      dark: dark,
      extraOverrides: extraOverrides,
      clock: clock,
      pickRange: pickRange));
  await tester.pumpAndSettle();
}

/// The detail card alone, the way the Alarm View page and the visibility
/// asset's pane both host it.
Future<void> pumpAlarmDetail(
  WidgetTester tester,
  AlarmActive alarm, {
  double width = 520,
  bool dark = false,
}) async {
  final (light, darkTheme) = solarized();
  await tester.pumpWidget(ProviderScope(
    child: MaterialApp(
      theme: dark ? darkTheme : light,
      home: Scaffold(
        body: Center(
          child: SizedBox(width: width, child: ViewActiveAlarm(alarm: alarm)),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

/// Taps the History segment of the Active/History toggle.
///
/// Scoped to the toggle: the period control carries the same history glyph
/// once an absolute range is pinned, and a bare `byIcon` would then match two.
Future<void> showHistory(WidgetTester tester) async {
  await tester.tap(find.descendant(
    of: find.byType(SegmentedButton<bool>),
    matching: find.byIcon(Icons.history),
  ));
  await tester.pumpAndSettle();
}

/// Opens the History period menu and picks the preset named [label].
Future<void> pickPeriod(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(const ValueKey('alarm-history-period-menu')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

/// Taps the quick-filter chip for [level].
Future<void> tapLevelChip(WidgetTester tester, AlarmLevel level) async {
  await tester.tap(find.byWidgetPredicate((w) =>
      w is FilterChip &&
      w.label is Text &&
      ((w.label as Text).data ?? '').startsWith(alarmLevelLabel(level))));
  await tester.pumpAndSettle();
}

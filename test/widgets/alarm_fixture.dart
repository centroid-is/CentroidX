/// Shared fixture for the alarm list tests: a hand-built [AlarmActive] and an
/// [AlarmMan] that is nothing but the two streams the list reads.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tfc/providers/alarm.dart';
import 'package:tfc/theme.dart' show solarized;
import 'package:tfc/widgets/alarm.dart';
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
/// widget reaches for beyond these three falls through to [noSuchMethod] and
/// throws loudly.
class AlarmFixture implements AlarmMan {
  AlarmFixture({this.active = const {}, this.past = const []});

  final Set<AlarmActive> active;
  final List<AlarmActive?> past;

  @override
  Stream<Set<AlarmActive>> activeAlarms() => Stream.value(active);

  @override
  Stream<List<AlarmActive?>> history() => Stream.value(past);

  /// The real one collapses an alarm's rules to its worst and fuzzy-matches
  /// the query; the list tests are about what happens after that.
  @override
  List<AlarmActive> filterAlarms(List<AlarmActive> alarms, String query) =>
      alarms;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The alarm list in a column [width] wide, the way the Alarm View page hands
/// it 2/5 of the window.
Widget alarmList(AlarmFixture alarms,
    {double width = 520, bool dark = false}) {
  final (light, darkTheme) = solarized();
  return ProviderScope(
    overrides: [alarmManProvider.overrideWith((ref) async => alarms)],
    child: MaterialApp(
      theme: dark ? darkTheme : light,
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            height: 600,
            child: const ListActiveAlarms(),
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
}) async {
  await tester.pumpWidget(alarmList(alarms, width: width, dark: dark));
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
Future<void> showHistory(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.history));
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

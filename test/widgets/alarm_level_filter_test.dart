/// The level quick-filter on the alarm list.
///
/// Search answers "which alarm", not "how bad" — narrowing a screen of alarms
/// down to the errors meant typing, and there is nothing to type. Three chips
/// do it in one tap, and the count on each says what is behind it before the
/// tap.
///
/// Nothing selected is the unfiltered list: an alarm page must show everything
/// on arrival, so the filter is opt-in and one tap gets back out of it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tfc_dart/core/alarm.dart';

import 'alarm_fixture.dart';

AlarmFixture _mixed() => AlarmFixture(
      active: {
        alarm('Motor overload',
            level: AlarmLevel.error, at: DateTime(2026, 8, 29, 8)),
        alarm('Belt drifting',
            level: AlarmLevel.warning, at: DateTime(2026, 8, 29, 7)),
        alarm('Shift started',
            level: AlarmLevel.info, at: DateTime(2026, 8, 29, 6)),
        alarm('Guard open',
            level: AlarmLevel.error, at: DateTime(2026, 8, 29, 5)),
      },
      // Inside the default history period, which the fixture clock puts at
      // 28/08 12:00 - 29/08 12:00. An ended alarm outside it is not in the
      // History list to be counted, which is the period control's whole job.
      past: [
        alarm('Line stopped',
            level: AlarmLevel.warning,
            at: DateTime(2026, 8, 28, 18),
            ended: DateTime(2026, 8, 28, 19)),
      ],
    );

/// The chip labels as rendered, in the order they are laid out.
List<String> _chipLabels(WidgetTester tester) => tester
    .widgetList<FilterChip>(find.byType(FilterChip))
    .map((c) => ((c.label as Text).data) ?? '')
    .toList();

void main() {
  group('the level quick-filter', () {
    testWidgets('offers a chip per level, worst first, with counts',
        (tester) async {
      await pumpAlarmList(tester, _mixed());

      expect(_chipLabels(tester), ['Error 2', 'Warning 1', 'Info 1'],
          reason: 'the chip an operator reaches for in a hurry is leftmost');
    });

    testWidgets('shows every level until one is picked', (tester) async {
      await pumpAlarmList(tester, _mixed());

      expect(find.text('Motor overload'), findsOneWidget);
      expect(find.text('Belt drifting'), findsOneWidget);
      expect(find.text('Shift started'), findsOneWidget);
    });

    testWidgets('one tap narrows the list to that level', (tester) async {
      await pumpAlarmList(tester, _mixed());
      await tapLevelChip(tester, AlarmLevel.error);

      expect(find.text('Motor overload'), findsOneWidget);
      expect(find.text('Guard open'), findsOneWidget);
      expect(find.text('Belt drifting'), findsNothing);
      expect(find.text('Shift started'), findsNothing);
    });

    testWidgets('the counts keep naming what is behind each chip',
        (tester) async {
      await pumpAlarmList(tester, _mixed());
      await tapLevelChip(tester, AlarmLevel.error);

      expect(_chipLabels(tester), ['Error 2', 'Warning 1', 'Info 1'],
          reason: 'a count that only reported the filtered list would collapse '
              'the other two chips to 0 and hide what is still out there');
    });

    testWidgets('levels add up rather than replacing each other',
        (tester) async {
      await pumpAlarmList(tester, _mixed());
      await tapLevelChip(tester, AlarmLevel.error);
      await tapLevelChip(tester, AlarmLevel.warning);

      expect(find.text('Motor overload'), findsOneWidget);
      expect(find.text('Belt drifting'), findsOneWidget);
      expect(find.text('Shift started'), findsNothing);
    });

    testWidgets('tapping the same chip again gives the whole list back',
        (tester) async {
      await pumpAlarmList(tester, _mixed());
      await tapLevelChip(tester, AlarmLevel.error);
      await tapLevelChip(tester, AlarmLevel.error);

      expect(find.text('Shift started'), findsOneWidget);
    });

    testWidgets('a level with nothing in it says so instead of "No alarms"',
        (tester) async {
      await pumpAlarmList(
        tester,
        AlarmFixture(active: {
          alarm('Motor overload',
              level: AlarmLevel.error, at: DateTime(2026, 8, 29, 8)),
        }),
      );
      await tapLevelChip(tester, AlarmLevel.info);

      expect(find.text('No alarms at the selected levels'), findsOneWidget,
          reason: 'a bare "No alarms" reads as a quiet plant, and the plant is '
              'not quiet — an error is standing right there');
    });

    testWidgets('the filter survives the Active/History toggle',
        (tester) async {
      await pumpAlarmList(tester, _mixed());
      await tapLevelChip(tester, AlarmLevel.error);
      await showHistory(tester);

      expect(find.text('Motor overload'), findsOneWidget);
      expect(find.text('Line stopped'), findsNothing,
          reason: 'the warning in the history buffer is filtered out too');
    });

    testWidgets('it also counts and filters the History list', (tester) async {
      await pumpAlarmList(tester, _mixed());
      await showHistory(tester);

      expect(_chipLabels(tester), ['Error 2', 'Warning 2', 'Info 1'],
          reason: 'history holds the ended warning as well as the standing '
              'alarms');
    });

    testWidgets('the chips do not overflow a narrow column', (tester) async {
      await pumpAlarmList(tester, _mixed(), width: 240);

      expect(tester.takeException(), isNull);
      expect(find.byType(FilterChip), findsNWidgets(3),
          reason: 'they wrap onto a second line rather than being dropped');
    });
  });
}

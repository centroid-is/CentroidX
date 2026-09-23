/// The History list is a period, not a buffer.
///
/// It used to show whatever [AlarmMan] happened to be holding in memory: the
/// last thousand clears, seeded once at startup from an unbounded read. So
/// "what went wrong on the night shift" was answerable only if nothing much
/// had happened since, and there was no way to ask for a different stretch —
/// the downtime view beside it had had a period control for months.
///
/// These pin the three halves of fixing that: the period bounds the database
/// read (not just the rows already in hand), it bounds the list, and an alarm
/// that straddles the edge of the window still counts.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tfc/widgets/alarm.dart';

import 'alarm_fixture.dart';

void main() {
  group('alarmHistoryEntries over a window', () {
    final window = DateTimeRange(
      start: DateTime(2026, 8, 29, 6),
      end: DateTime(2026, 8, 29, 14),
    );

    test('an alarm that began and ended before the window is out', () {
      final old = alarm('yesterday',
          at: DateTime(2026, 8, 28, 3), ended: DateTime(2026, 8, 28, 4));

      expect(alarmHistoryEntries([old], const [], window: window), isEmpty);
    });

    test('one that began before the window and cleared inside it is in', () {
      // The stop the operator is asking about does not become someone else's
      // because it started before the shift did.
      final straddling = alarm('overnight',
          at: DateTime(2026, 8, 29, 5), ended: DateTime(2026, 8, 29, 7));

      final entries =
          alarmHistoryEntries([straddling], const [], window: window);

      expect(entries, hasLength(1));
      expect(entries.single.$2, DateTime(2026, 8, 29, 7));
    });

    test('a standing alarm older than the window is still listed', () {
      // It has no deactivation time, so it overlaps every window it started
      // before — and it is the one thing on screen right now.
      final standing = alarm('running', at: DateTime(2026, 8, 20, 9));

      final entries = alarmHistoryEntries(const [], [standing],
          window: window);

      expect(entries, hasLength(1));
      expect(entries.single.$2, isNull);
    });

    test('one that has not started yet is out', () {
      final later = alarm('later', at: DateTime(2026, 8, 29, 20));

      expect(alarmHistoryEntries(const [], [later], window: window), isEmpty);
    });

    test('the same activation from the database and the ring is one row', () {
      // The database row and the in-memory copy are different objects for the
      // same event — identity dedupe never caught this, and the list showed
      // the alarm twice for as long as both were in reach.
      final stored = alarm('boiler',
          at: DateTime(2026, 8, 29, 8), ended: DateTime(2026, 8, 29, 9));
      final ringCopy = alarm('boiler',
          at: DateTime(2026, 8, 29, 8), ended: DateTime(2026, 8, 29, 9));

      final entries =
          alarmHistoryEntries([stored, ringCopy], const [], window: window);

      expect(entries, hasLength(1));
    });
  });

  group('the History period control', () {
    testWidgets('is not on the Active list', (tester) async {
      await pumpAlarmList(tester, AlarmFixture());

      expect(find.byKey(const ValueKey('alarm-history-period-menu')),
          findsNothing,
          reason: 'the Active list is whatever is wrong now; a period over '
              'it would be a control that does nothing');
    });

    testWidgets('names the stretch it is showing', (tester) async {
      await pumpAlarmList(tester, AlarmFixture());
      await showHistory(tester);

      // The fixture clock is 29/08 12:00, so the default day runs back to
      // 28/08 12:00 and the label has to spell both days out.
      expect(find.text('28/08 12:00 – 29/08 12:00'), findsOneWidget);
    });

    testWidgets('the default period asks the database for the last day',
        (tester) async {
      final alarms = AlarmFixture();
      await pumpAlarmList(tester, alarms);
      await showHistory(tester);

      expect(alarms.reads, isNotEmpty,
          reason: 'the window has to bound the query, not just the list: a '
              'newest-first read of a busy plant can spend its whole row '
              'limit on the last hour');
      expect(alarms.reads.last.start, DateTime(2026, 8, 28, 12));
      expect(alarms.reads.last.end, DateTime(2026, 8, 29, 12));
    });

    testWidgets('a wider period re-reads, and brings the older alarm back',
        (tester) async {
      final lastWeek = alarm('Freezer door',
          at: DateTime(2026, 8, 24, 2), ended: DateTime(2026, 8, 24, 3));
      final alarms = AlarmFixture(stored: [lastWeek]);

      await pumpAlarmList(tester, alarms);
      await showHistory(tester);
      expect(find.text('Freezer door'), findsNothing,
          reason: 'five days ago is outside the default day');

      await pickPeriod(tester, 'Last 7 days');

      expect(alarms.reads.last.start, DateTime(2026, 8, 22, 12));
      expect(find.text('Freezer door'), findsOneWidget);
    });

    testWidgets('an empty period says so in the period\'s terms',
        (tester) async {
      await pumpAlarmList(tester, AlarmFixture());
      await showHistory(tester);

      expect(find.text('No alarms in this period'), findsOneWidget,
          reason: '"No alarms" over a bounded history is a different, and '
              'wrong, claim');
    });

    testWidgets('a picked range pins the list, and Back to live releases it',
        (tester) async {
      final tuesday = DateTimeRange(
        start: DateTime(2026, 8, 25, 6),
        end: DateTime(2026, 8, 25, 18),
      );
      final onTuesday = alarm('Line stopped',
          at: DateTime(2026, 8, 25, 9), ended: DateTime(2026, 8, 25, 9, 30));
      final alarms = AlarmFixture(stored: [onTuesday]);

      await pumpAlarmList(tester, alarms,
          pickRange: (_, __) async => tuesday);
      await showHistory(tester);

      await tester.tap(find.byKey(const ValueKey('alarm-history-period-menu')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('alarm-history-period-live')),
          findsNothing,
          reason: 'nothing to go back from while the period is still live');
      await tester.tap(find.byKey(const ValueKey('alarm-history-pick-range')));
      await tester.pumpAndSettle();

      expect(alarms.reads.last.start, tuesday.start);
      expect(find.text('Line stopped'), findsOneWidget);
      expect(find.text('25/08 06:00 – 18:00'), findsOneWidget,
          reason: 'inside one day the end needs no date, but the day it is '
              'not today has to be said');

      await tester.tap(find.byKey(const ValueKey('alarm-history-period-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('alarm-history-period-live')));
      await tester.pumpAndSettle();

      expect(find.text('Line stopped'), findsNothing);
      expect(find.text('28/08 12:00 – 29/08 12:00'), findsOneWidget);
    });

    testWidgets('a cancelled picker changes nothing', (tester) async {
      final alarms = AlarmFixture();
      await pumpAlarmList(tester, alarms, pickRange: (_, __) async => null);
      await showHistory(tester);
      final before = alarms.reads.length;

      await tester.tap(find.byKey(const ValueKey('alarm-history-period-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('alarm-history-pick-range')));
      await tester.pumpAndSettle();

      expect(alarms.reads, hasLength(before),
          reason: 'a dismissed modal is not a fresh query');
      expect(find.text('28/08 12:00 – 29/08 12:00'), findsOneWidget);
    });
  });
}

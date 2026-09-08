/// The loader half of the stop timeline has to be *live*.
///
/// It used to read `activeAlarms().first` once per period change, so a stop
/// that began while the operator was watching never appeared, and one that
/// cleared kept growing forever. It now holds the subscription: a new
/// activation is drawn from the event itself, and a cleared one — which just
/// became a history row the widget has not fetched — triggers a refetch.
///
/// The view also stays mounted across those reloads. Swapping to a spinner on
/// every period change threw away the operator's expansion and filters, which
/// is why changing the period looked like a dead control.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rxdart/rxdart.dart';

import 'package:tfc/providers/alarm.dart';
import 'package:tfc/widgets/stop_timeline.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/boolean_expression.dart';

final now = DateTime(2026, 8, 29, 14, 22);
DateTime ago(int minutes) => now.subtract(Duration(minutes: minutes));

AlarmRule _rule() => AlarmRule(
      level: AlarmLevel.error,
      expression: ExpressionConfig(value: Expression(formula: 'a')),
      acknowledgeRequired: false,
    );

AlarmConfig config(String uid, {List<String> group = const ['Line 3']}) =>
    AlarmConfig(
      uid: uid,
      title: uid,
      description: uid,
      group: group,
      rules: [_rule()],
    );

AlarmActive activation(AlarmConfig config, {required DateTime at,
    DateTime? ended}) {
  final rule = _rule();
  return AlarmActive(
    alarm: Alarm(config: config),
    notification: AlarmNotification(
      uid: config.uid,
      active: ended == null,
      expression: 'a',
      rule: rule,
      timestamp: at,
    ),
    deactivated: ended,
  );
}

/// The three members the loader actually reaches for, over mutable data the
/// test can move mid-flight the way AlarmMan does.
class _FakeAlarmMan implements AlarmMan {
  _FakeAlarmMan({required this.configs});

  final List<AlarmConfig> configs;
  final List<AlarmActive> historyRows = [];
  final active = BehaviorSubject<Set<AlarmActive>>.seeded({});
  final ring = BehaviorSubject<List<AlarmActive?>>.seeded([]);
  int historyFetches = 0;

  @override
  AlarmManConfig get config => AlarmManConfig(alarms: configs);

  @override
  Future<List<AlarmActive>> getRecentAlarms({
    int limit = 1000,
    DateTime? from,
    DateTime? to,
  }) async {
    historyFetches++;
    return List.of(historyRows);
  }

  @override
  Stream<Set<AlarmActive>> activeAlarms() => active.stream;

  @override
  Stream<List<AlarmActive?>> history() => ring.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> pumpLoader(WidgetTester tester, _FakeAlarmMan man) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      alarmManProvider.overrideWith((ref) => Future.value(man)),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 900,
          height: 420,
          child: StopTimeline(clock: now),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  final door = config('Freezer door');
  final reel = config('Film reel empty');

  testWidgets('an activation firing mid-watch appears without touching '
      'the period', (tester) async {
    final man = _FakeAlarmMan(configs: [door, reel]);
    await pumpLoader(tester, man);
    expect(find.text('1 standing'), findsNothing);

    man.active.add({activation(door, at: ago(5))});
    await tester.pumpAndSettle();

    expect(find.text('1 standing'), findsOneWidget);
  });

  testWidgets('a clearing alarm closes from the ring, ahead of the database',
      (tester) async {
    final man = _FakeAlarmMan(configs: [door, reel]);
    final standing = activation(door, at: ago(30));
    man.active.add({standing});
    await pumpLoader(tester, man);
    expect(find.text('1 standing'), findsOneWidget);

    // AlarmMan files the instance into its ring and drops it from the set.
    // The database row is written fire-and-forget — deliberately NOT added
    // here: the ring alone must be enough to close the stop on screen.
    man.ring.add([activation(door, at: ago(30), ended: ago(1))]);
    man.active.add({});
    await tester.pumpAndSettle();

    expect(find.text('1 standing'), findsNothing);
    // The closed stop is still on the chart, from the in-memory record.
    expect(find.text('Error 1'), findsOneWidget);
  });

  testWidgets('changing the period keeps the expansion and the view alive',
      (tester) async {
    final man = _FakeAlarmMan(configs: [door, reel]);
    await pumpLoader(tester, man);

    await tester.tap(find.text('Line 3'));
    await tester.pumpAndSettle();
    expect(find.text('Freezer door'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('stop-timeline-period-menu')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('stop-timeline-interval-480')));
    await tester.pumpAndSettle();

    expect(find.text('Freezer door'), findsOneWidget,
        reason: 'a reload must not fold the operator\'s expansion back up');
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}

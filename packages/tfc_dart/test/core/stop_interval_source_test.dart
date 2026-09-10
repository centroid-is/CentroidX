import 'package:test/test.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/alarm_interval.dart';
import 'package:tfc_dart/core/boolean_expression.dart';
import 'package:tfc_dart/core/stop_interval_source.dart';

final base = DateTime(2026, 8, 29, 6);
DateTime at(int minutes) => base.add(Duration(minutes: minutes));

AlarmRule rule(AlarmLevel level) => AlarmRule(
      level: level,
      expression: ExpressionConfig(value: Expression(formula: 'A')),
      acknowledgeRequired: false,
    );

/// An activation of [uid], started at [from] and cleared at [to] (null = still
/// standing), shaped the way AlarmMan hands it over.
AlarmActive activation(
  String uid, {
  required int from,
  int? to,
  AlarmLevel level = AlarmLevel.error,
}) {
  final config = AlarmConfig(
    uid: uid,
    title: uid,
    description: '',
    rules: [rule(level)],
  );
  return AlarmActive(
    alarm: Alarm(config: config),
    notification: AlarmNotification(
      uid: uid,
      active: to == null,
      expression: null,
      rule: rule(level),
      timestamp: at(from),
    ),
    deactivated: to == null ? null : at(to),
  );
}

void main() {
  group('StopIntervalSource.fromAlarms', () {
    test('history becomes closed intervals', () {
      final source = StopIntervalSource.fromAlarms(
        history: [activation('a', from: 0, to: 10)],
        active: const [],
      );
      expect(source.closed, hasLength(1));
      expect(source.open, isEmpty);
      expect(source.closed.single.interval.end, at(10));
      expect(source.hasOpen, isFalse);
    });

    test('an active entry that already cleared is closed at its clear time',
        () {
      // An ack-required alarm stays in the active set after its condition
      // drops, carrying the clear time in `deactivated`. The machine is
      // running again — drawing it as still-growing downtime would bill the
      // line for however long the ack takes.
      final source = StopIntervalSource.fromAlarms(
        history: const [],
        active: [activation('a', from: 0, to: 15)],
      );
      expect(source.open, isEmpty);
      expect(source.closed, hasLength(1));
      expect(source.closed.single.interval.end, at(15));
      expect(source.hasOpen, isFalse);
    });

    test('one alarm standing under two rules is one lane interval', () {
      // AlarmMan keys actives by (uid, rule): a config with a warning rule
      // and an error rule both true is two open activations for one uid.
      // The lane series' sorted-disjoint invariant would reject them raw.
      final source = StopIntervalSource.fromAlarms(
        history: const [],
        active: [
          activation('a', from: 0, level: AlarmLevel.warning),
          activation('a', from: 3),
        ],
      );
      final series = source.seriesFor('a', now: at(30));
      expect(series.intervals, hasLength(1));
      expect(series.intervals.single.isOpen, isTrue);
      expect(series.intervals.single.level, AlarmLevel.error,
          reason: 'the merged interval carries the worst standing severity');
      expect(series.statsIn(at(0), at(30)).total, const Duration(minutes: 30));
    });

    test('the same activation from the ring and the database is one stop',
        () {
      // The clear record reaches the source twice: AlarmMan\'s in-memory
      // ring instance, and later the database row rebuilt as a fresh
      // instance. Identity can\'t pair them; (uid, start, level) does.
      final ringInstance = activation('a', from: 0, to: 10);
      final dbRow = activation('a', from: 0, to: 10);
      final source = StopIntervalSource.fromAlarms(
        history: [dbRow, ringInstance],
        active: const [],
      );
      expect(source.closed, hasLength(1));
    });

    test('the live set becomes open intervals', () {
      final source = StopIntervalSource.fromAlarms(
        history: const [],
        active: [activation('a', from: 5)],
      );
      expect(source.open, hasLength(1));
      expect(source.open.single.isOpen, isTrue);
      expect(source.hasOpen, isTrue);
    });

    test('the standing alarm survives the union — the whole point', () {
      // AlarmMan only writes a history row when an alarm clears, so reading
      // history alone would omit the alarm the operator is looking at.
      final source = StopIntervalSource.fromAlarms(
        history: [activation('a', from: 0, to: 10)],
        active: [activation('b', from: 30)],
      );
      expect(source.all.map((e) => e.alarmUid), ['a', 'b']);
      expect(source.all.last.isOpen, isTrue);
    });

    test('an entry in both collections is counted once', () {
      // AlarmMan moves the same instance from the active set into history, so
      // for a frame it is in both streams.
      final shared = activation('a', from: 0, to: 10);
      final source = StopIntervalSource.fromAlarms(
        history: [shared],
        active: [shared],
      );
      expect(source.all, hasLength(1));
      expect(source.closed, hasLength(1));
      expect(source.open, isEmpty);
    });

    test('a history entry with no deactivation time stays open', () {
      final source = StopIntervalSource.fromAlarms(
        history: [activation('a', from: 0)],
        active: const [],
      );
      expect(source.closed.single.isOpen, isTrue);
    });

    test('all is sorted by start regardless of which source it came from', () {
      final source = StopIntervalSource.fromAlarms(
        history: [activation('late', from: 50, to: 60)],
        active: [activation('early', from: 10)],
      );
      expect(source.all.map((e) => e.alarmUid), ['early', 'late']);
    });

    test('severity carries over from the rule that fired', () {
      final source = StopIntervalSource.fromAlarms(
        history: [activation('a', from: 0, to: 1, level: AlarmLevel.warning)],
        active: const [],
      );
      expect(source.closed.single.level, AlarmLevel.warning);
    });

    test('nothing in, empty out', () {
      final source =
          StopIntervalSource.fromAlarms(history: const [], active: const []);
      expect(source.all, isEmpty);
      expect(source.hasOpen, isFalse);
    });
  });

  group('grouping and series', () {
    final source = StopIntervalSource.fromAlarms(
      history: [
        activation('film', from: 0, to: 10),
        activation('film', from: 30, to: 40),
        activation('seal', from: 20, to: 50, level: AlarmLevel.warning),
      ],
      active: [activation('seal', from: 60)],
    );

    test('byAlarm keys on the alarm uid', () {
      expect(source.byAlarm().keys.toSet(), {'film', 'seal'});
      expect(source.byAlarm()['film'], hasLength(2));
    });

    test('each alarm’s intervals come out sorted', () {
      final seal = source.byAlarm()['seal']!;
      expect(seal.first.start, at(20));
      expect(seal.last.start, at(60));
      expect(seal.last.isOpen, isTrue);
    });

    test('seriesFor prepares a queryable series', () {
      final series = source.seriesFor('film', now: at(100));
      expect(series.statsIn(at(0), at(100)).total, const Duration(minutes: 20));
      expect(series.statsIn(at(0), at(100)).count, 2);
    });

    test('seriesFor an unknown alarm is empty, not null', () {
      final series = source.seriesFor('nope', now: at(100));
      expect(series.isEmpty, isTrue);
      expect(series.statsIn(at(0), at(100)).total, Duration.zero);
    });

    test('mergedFor unions across alarms and keeps the worst severity', () {
      // film 0-10 and seal 20-50 overlap nothing; film 30-40 sits inside seal
      final merged = source.mergedFor(['film', 'seal'], now: at(80));
      expect(merged.map((e) => e.start), [at(0), at(20), at(60)]);
      // the 20-50 stretch contains an error (film) and a warning (seal)
      expect(merged[1].level, AlarmLevel.error);
      expect(merged[1].end, at(50));
      expect(merged.last.isOpen, isTrue);
    });

    test('mergedFor ignores alarms with no activations', () {
      final merged = source.mergedFor(['film', 'nope'], now: at(80));
      expect(merged, hasLength(2));
    });

    test('a merged group series still answers window statistics', () {
      final merged = source.mergedFor(['film', 'seal'], now: at(80));
      final series = AlarmIntervalSeries(merged, now: at(80));
      // 0-10, 20-50, 60-80(open) = 10 + 30 + 20
      expect(series.statsIn(at(0), at(100)).total, const Duration(minutes: 60));
      expect(series.statsIn(at(0), at(100)).isOpen, isTrue);
    });
  });

  group('what a merged stretch was made of', () {
    final source = StopIntervalSource.fromAlarms(
      history: [
        activation('film', from: 0, to: 10),
        activation('film', from: 30, to: 40),
        activation('seal', from: 20, to: 50, level: AlarmLevel.warning),
        activation('link', from: 200, to: 210),
      ],
      active: [activation('seal', from: 60)],
    );
    // The stretch a collapsed group draws for 20-50: seal 20-50 with film
    // 30-40 inside it.
    final stretch = source.mergedFor(['film', 'seal'], now: at(80))[1];

    test('names every activation the stretch absorbed', () {
      final inside = source.activationsIn(['film', 'seal'],
          from: stretch.start, to: stretch.end!, now: at(80));
      expect(inside.map((e) => e.alarmUid), ['seal', 'film']);
      expect(inside.length, stretch.count);
    });

    test('the longest comes first, whatever order it started in', () {
      final inside = source.activationsIn(['film', 'seal'],
          from: stretch.start, to: stretch.end!, now: at(80));
      // seal stood 30 minutes, film 10 — film started later but is second on
      // length, not on start.
      expect(inside.first.interval.lengthAt(at(80)),
          const Duration(minutes: 30));
    });

    test('a contributor touching the edge is inside, not dropped', () {
      // film 0-10 starts exactly where its own stretch does.
      final first = source.mergedFor(['film', 'seal'], now: at(80)).first;
      final inside = source.activationsIn(['film', 'seal'],
          from: first.start, to: first.end!, now: at(80));
      expect(inside.map((e) => e.alarmUid), ['film']);
    });

    test('an open contributor is measured against the clock', () {
      final open = source.mergedFor(['film', 'seal'], now: at(80)).last;
      final inside = source.activationsIn(['film', 'seal'],
          from: open.start, to: at(80), now: at(80));
      expect(inside.single.alarmUid, 'seal');
      expect(inside.single.isOpen, isTrue);
      expect(
          inside.single.interval.lengthAt(at(80)), const Duration(minutes: 20));
    });

    test('alarms outside the asked-for set never appear', () {
      final inside = source.activationsIn(['film', 'seal'],
          from: at(0), to: at(300), now: at(300));
      expect(inside.map((e) => e.alarmUid), isNot(contains('link')));
    });

    test('equal-length activations come back in a fixed order', () {
      // List.sort is not stable, so ties need a total order or a test that
      // pins the list flakes.
      final tied = StopIntervalSource.fromAlarms(
        history: [
          activation('zulu', from: 0, to: 10),
          activation('alpha', from: 0, to: 10),
        ],
        active: const [],
      );
      final inside = tied.activationsIn(['zulu', 'alpha'],
          from: at(0), to: at(10), now: at(50));
      expect(inside.map((e) => e.alarmUid), ['alpha', 'zulu']);
    });

    test('a stretch with nothing in it reports nothing', () {
      // film cleared at 40 and never came back; seal is excluded because it
      // is still standing and so reaches every later window.
      final inside =
          source.activationsIn(['film'], from: at(100), to: at(150), now: at(300));
      expect(inside, isEmpty);
    });
  });
}

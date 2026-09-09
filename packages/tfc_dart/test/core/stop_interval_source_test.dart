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
}

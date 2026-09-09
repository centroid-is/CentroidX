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
///
/// Every call builds **fresh** objects. That matters from 14-06 onwards: the
/// history half is decoded out of `alarm_history` and the live half arrives
/// off the pipe, so the same activation is two different instances and an
/// identity-keyed dedupe cannot see that they are one thing.
/// [start] overrides [from] when the arm cares about the exact instant — the
/// sub-millisecond and time-zone-mode arms below, where `at(minutes)` cannot
/// express what the two halves really carry.
AlarmActive activation(
  String uid, {
  required int from,
  int? to,
  AlarmLevel level = AlarmLevel.error,
  int? ruleIndex = 0,
  DateTime? start,
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
      timestamp: start ?? at(from),
      ruleIndex: ruleIndex,
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

  group('the dedupe is keyed by value, not by identity (D-12)', () {
    test('the same activation from both sources is counted once', () {
      // 14-06 writes a row the moment an alarm goes off, so a standing alarm
      // is now in `alarm_history` (open, no deactivation time) AND in the
      // live active set — as two different objects, decoded from two
      // different places. Under the old identity dedupe every live alarm in
      // the plant would be drawn twice (P-8).
      final fromDb = activation('CN04.MOT01', from: 0);
      final fromPipe = activation('CN04.MOT01', from: 0);
      expect(identical(fromDb, fromPipe), isFalse,
          reason: 'the premise of the arm: two instances, one activation');

      final source = StopIntervalSource.fromAlarms(
        history: [fromDb],
        active: [fromPipe],
      );

      expect(source.all, hasLength(1));
      expect(source.closed, hasLength(1),
          reason: 'the history record wins, as it always did');
      expect(source.open, isEmpty);
    });

    test('two genuinely different activations of one alarm are both kept', () {
      // The dedupe must not become a swallow: the same motor tripping twice
      // in a shift is two stops, and a Pareto that counted it once would
      // under-report the thing it exists to find.
      final source = StopIntervalSource.fromAlarms(
        history: [activation('CN04.MOT01', from: 0, to: 10)],
        active: [activation('CN04.MOT01', from: 30)],
      );
      expect(source.all, hasLength(2));
      expect(source.all.map((e) => e.start), [at(0), at(30)]);
    });

    test('two rules of one alarm active at once are both kept', () {
      // Same uid, same instant, different rule. `ruleIndex` is the third
      // element of the key for exactly this case — 14-01's partial unique
      // index is on `(alarm_uid, rule_index)` for the same reason.
      final source = StopIntervalSource.fromAlarms(
        history: [activation('CN04.MOT01', from: 0, ruleIndex: 0)],
        active: [activation('CN04.MOT01', from: 0, ruleIndex: 1)],
      );
      expect(source.all, hasLength(2));
      expect(source.closed, hasLength(1));
      expect(source.open, hasLength(1));
    });

    test('null ruleIndex on both sides still dedupes on (uid, start)', () {
      // A pre-v7 row states no rule index, and neither does a fixture. Legacy
      // rows must not multiply just because they are old.
      final source = StopIntervalSource.fromAlarms(
        history: [activation('CN04.MOT01', from: 0, ruleIndex: null)],
        active: [activation('CN04.MOT01', from: 0, ruleIndex: null)],
      );
      expect(source.all, hasLength(1));
    });

    // ------------------------------------------------------- CR-03 (14-REVIEW)
    //
    // The key was `(uid, ruleIndex, DateTime)` compared with `DateTime.==`,
    // and the two halves do not carry the same `DateTime`. They never did:
    //
    //  * history — `relay_alarm_source.dart:433` hands over `row.createdAt`,
    //    which drift reads out of the TEXT column at MICROSECOND resolution,
    //    and `AlarmHistoryWriter._sqlInstant` wrote the full
    //    `toIso8601String()`, so microseconds survive the `::timestamp` round
    //    trip.
    //  * live — `relay_alarm_source.dart:252` builds
    //    `DateTime.fromMillisecondsSinceEpoch(entry.activeAtMs)`, and
    //    `activeAtMs` is `stamp.at.toUtc().millisecondsSinceEpoch`
    //    (`backend_alarms.dart:254`). Microseconds truncated, on the wire, by
    //    construction.
    //
    // An OPC UA `sourceTimestamp` is a 100 ns tick, so a plant instant with
    // microseconds in it is the ordinary case and not the exotic one. These
    // two arms are the P-8/D-12 double-count returning through a different
    // hole, and the third is what stops the repair from becoming a swallow.
    test(
        'a plant instant with microseconds still dedupes across the two halves',
        () {
      // 12:00:00.123456Z as the history row holds it, and .123000Z as the
      // wire could ever carry it. One standing alarm, two halves.
      final fromDb = DateTime.utc(2026, 8, 29, 12, 0, 0, 123, 456);
      final fromPipe = DateTime.fromMillisecondsSinceEpoch(
          fromDb.millisecondsSinceEpoch,
          isUtc: true);
      expect(fromDb, isNot(fromPipe),
          reason: 'the premise: the two halves carry different DateTimes for '
              'one activation. If these ever compare equal the arm is '
              'vacuous.');

      final source = StopIntervalSource.fromAlarms(
        history: [activation('CN04.MOT01', from: 0, start: fromDb)],
        active: [activation('CN04.MOT01', from: 0, start: fromPipe)],
      );

      expect(source.all, hasLength(1),
          reason: 'the same current stop drawn twice on the timeline and '
              'counted twice in the totals — exactly the double-count the '
              'identity set was replaced to fix (P-8, D-12), reached through '
              'the microseconds the wire cannot carry. Got: ${source.all}');
      expect(source.open, isEmpty,
          reason: 'and the history record still wins, as it always did');
    });

    test('the same instant in local mode and UTC mode is one activation', () {
      // `DateTime.==` compares the `isUtc` flag as well as the microseconds,
      // so a producer that hands over a local-mode instant misses at ANY
      // precision. Direct mode's live stamp is whatever `sourceTimestamp` the
      // open62541 value carried, which is not guaranteed to be UTC-flagged.
      final utc = DateTime.utc(2026, 8, 29, 12, 0, 0);
      final local = utc.toLocal();
      expect(local.isUtc, isFalse,
          reason: 'the premise: two DateTime objects for one instant, '
              'differing only in mode');

      final source = StopIntervalSource.fromAlarms(
        history: [activation('CN04.MOT01', from: 0, start: utc)],
        active: [activation('CN04.MOT01', from: 0, start: local)],
      );

      expect(source.all, hasLength(1),
          reason: 'one instant, one activation. Got: ${source.all}');
    });

    test('two activations one millisecond apart are still two', () {
      // The anti-vacuity half. Normalising the key must not become rounding
      // it: a dedupe that collapsed to whole seconds would pass both arms
      // above while quietly merging genuinely distinct stops, which is the
      // failure the "two genuinely different activations" arm exists for —
      // taken here to the finest resolution the wire can express.
      final first = DateTime.utc(2026, 8, 29, 12, 0, 0, 123);
      final second = DateTime.utc(2026, 8, 29, 12, 0, 0, 124);

      final source = StopIntervalSource.fromAlarms(
        history: [activation('CN04.MOT01', from: 0, to: 1, start: first)],
        active: [activation('CN04.MOT01', from: 0, start: second)],
      );

      expect(source.all, hasLength(2),
          reason: 'a millisecond is the finest thing ALARM.active can say, so '
              'two entries a millisecond apart are two activations and the '
              'key must keep them apart. Got: ${source.all}');
    });
  });

  group('filterAlarms is a shared function, not a method', () {
    // 14-09's RelayAlarmSource answers "which alarms does the operator see"
    // for a gateway-mode panel. Two implementations of that question are two
    // lists that can disagree on the same screen, so the collapse, the sort
    // and the fuzzy filter live in one top-level function with no instance
    // in sight.
    final film0 = activation('film', from: 0, level: AlarmLevel.warning);
    final film1 =
        activation('film', from: 5, level: AlarmLevel.error, ruleIndex: 1);
    final seal = activation('seal', from: 10, level: AlarmLevel.info);

    test('it collapses to the highest-priority rule per uid', () {
      final out = filterAlarms([film0, film1, seal], '');
      expect(out.map((e) => e.alarm.config.uid), ['film', 'seal']);
      expect(out.first.notification.rule.level, AlarmLevel.error);
    });

    test('it sorts by level, then by most recent timestamp', () {
      final later = activation('pump', from: 99, level: AlarmLevel.error);
      final out = filterAlarms([film1, seal, later], '');
      expect(out.map((e) => e.alarm.config.uid), ['pump', 'film', 'seal'],
          reason: 'two errors, newest first, then the info');
    });

    test('it fuzzy-filters on title and description', () {
      final out = filterAlarms([film0, film1, seal], 'seal');
      expect(out.map((e) => e.alarm.config.uid), ['seal']);
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

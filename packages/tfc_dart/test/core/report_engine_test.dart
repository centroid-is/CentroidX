import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/report.dart';
import 'package:tfc_dart/core/report_engine.dart';
import 'package:tfc_dart/core/report_result.dart';
import 'package:tfc_dart/core/report_store.dart';
import 'package:tfc_dart/core/shift.dart';

/// Against real sqlite rather than mocks: what can go wrong in the engine is
/// SQL — quoting of dotted table and column names, the boundary-row query,
/// the overlap filter on alarm_history — and only a database answers those.
class _Db extends AppDatabase {
  _Db() : super.forTest(DatabaseConfig(), NativeDatabase.memory());
}

void main() {
  late _Db db;
  late ReportEngine engine;

  final shiftStart = DateTime(2026, 9, 1, 7);
  final shiftEnd = DateTime(2026, 9, 1, 15);
  DateTime at(int minutes) => shiftStart.add(Duration(minutes: minutes));
  String iso(DateTime t) => t.toUtc().toIso8601String();

  setUp(() async {
    db = _Db();
    engine = ReportEngine(db, isPostgres: false);

    await db.customStatement(
        'CREATE TABLE "Line3.CN04.temperature" ("value" REAL, "time" TEXT)');
    // A struct table with a dotted member column, the sample_members shape.
    await db.customStatement(
        'CREATE TABLE "Line3.CN04.drive" ("time" TEXT, "stat.speed" REAL)');
    await db.customStatement(
        'CREATE TABLE "Line3.counter" ("value" INTEGER, "time" TEXT)');

    Future<void> insert(String table, String column, DateTime t, num v) =>
        db.customStatement(
            'INSERT INTO "$table" ("time", "$column") VALUES (?, ?)',
            [iso(t), v]);

    // Temperature: 20° standing from before the shift, jumps to 30° at +4h.
    await insert(
        'Line3.CN04.temperature', 'value', at(-60), 20);
    await insert('Line3.CN04.temperature', 'value', at(240), 30);
    // Drive speed via member column.
    await insert('Line3.CN04.drive', 'stat.speed', at(60), 50);
    await insert('Line3.CN04.drive', 'stat.speed', at(120), 70);
    // Counter: 1000 before the shift, resets mid-shift.
    await insert('Line3.counter', 'value', at(-10), 1000);
    await insert('Line3.counter', 'value', at(120), 1400);
    await insert('Line3.counter', 'value', at(121), 0);
    await insert('Line3.counter', 'value', at(400), 300);
  });

  tearDown(() => db.close());

  Future<void> alarmRow(
      String uid, DateTime start, DateTime? end, {String level = 'error'}) {
    return db.into(db.alarmHistory).insert(AlarmHistoryCompanion.insert(
          alarmUid: uid,
          alarmTitle: 'Alarm $uid',
          alarmDescription: uid,
          alarmLevel: level,
          active: false,
          pendingAck: false,
          createdAt: start,
          deactivatedAt: Value(end),
        ));
  }

  test('kpi metrics: boundary-aware aggregates over real tables', () async {
    final config = ReportConfig(id: 'r1', name: 'Shift report', sections: [
      KpiSectionConfig(metrics: [
        ReportMetricConfig(
            key: 'Line3.CN04.temperature',
            label: 'Temp',
            aggregate: ReportAggregate.timeWeightedMean,
            unit: '°C'),
        ReportMetricConfig(
            key: 'Line3.CN04.drive',
            member: 'stat.speed',
            label: 'Speed',
            aggregate: ReportAggregate.max),
        ReportMetricConfig(
            key: 'Line3.counter',
            label: 'Produced',
            aggregate: ReportAggregate.delta,
            decimals: 0),
      ]),
    ]);

    final result = await engine.generate(config,
        rangeStart: shiftStart, rangeEnd: shiftEnd, now: at(600));

    final kpi = result.sections.single as KpiSectionResult;
    // 20° for 4h, 30° for 4h.
    expect(kpi.metrics[0].value, closeTo(25, 1e-6));
    expect(kpi.metrics[0].formatted, '25.0 °C');
    expect(kpi.metrics[1].value, 70);
    // 1000→1400 is 400, reset to 0 restarts, then 300 more.
    expect(kpi.metrics[2].value, 700);
    expect(result.partial, isFalse);
  });

  test('additional keys fold per-key aggregates into one metric', () async {
    // A second counter, so "plant total" spans two machines.
    await db.customStatement(
        'CREATE TABLE "Line4.counter" ("value" INTEGER, "time" TEXT)');
    await db.customStatement(
        'INSERT INTO "Line4.counter" ("time", "value") VALUES (?, ?)',
        [iso(at(-5)), 50]);
    await db.customStatement(
        'INSERT INTO "Line4.counter" ("time", "value") VALUES (?, ?)',
        [iso(at(300)), 250]);

    final config = ReportConfig(id: 'r1', name: 'R', sections: [
      KpiSectionConfig(metrics: [
        ReportMetricConfig(
            key: 'Line3.counter',
            additionalKeys: ['Line4.counter'],
            label: 'Total produced',
            aggregate: ReportAggregate.delta,
            decimals: 0),
        ReportMetricConfig(
            key: 'Line3.counter',
            additionalKeys: ['not.collected'],
            label: 'Partial',
            aggregate: ReportAggregate.delta),
      ]),
    ]);
    final result = await engine.generate(config,
        rangeStart: shiftStart, rangeEnd: shiftEnd, now: at(600));
    final kpi = result.sections.single as KpiSectionResult;
    // Line3 delta is 700 (rollover-aware), Line4 adds 200.
    expect(kpi.metrics[0].value, 900);
    // A missing member of the fold still yields the rest, with a note.
    expect(kpi.metrics[1].value, 700);
    expect(kpi.metrics[1].error, contains('not.collected'));
  });

  test('a missing table is an error cell, not a failed report', () async {
    final config = ReportConfig(id: 'r1', name: 'R', sections: [
      KpiSectionConfig(metrics: [
        ReportMetricConfig(key: 'not.collected'),
        ReportMetricConfig(key: 'Line3.CN04.temperature', label: 'Temp'),
      ]),
    ]);
    final result = await engine.generate(config,
        rangeStart: shiftStart, rangeEnd: shiftEnd, now: at(600));
    final kpi = result.sections.single as KpiSectionResult;
    expect(kpi.metrics[0].value, isNull);
    expect(kpi.metrics[0].error, contains('not.collected'));
    expect(kpi.metrics[0].formatted, '—');
    expect(kpi.metrics[1].value, isNotNull);
  });

  test('a partial range integrates only up to now', () async {
    final config = ReportConfig(id: 'r1', name: 'R', sections: [
      KpiSectionConfig(metrics: [
        ReportMetricConfig(
            key: 'Line3.CN04.temperature',
            aggregate: ReportAggregate.timeWeightedMean),
      ]),
    ]);
    // Clock is mid-shift, before the 30° jump: nothing after now counts.
    final result = await engine.generate(config,
        rangeStart: shiftStart, rangeEnd: shiftEnd, now: at(120));
    expect(result.partial, isTrue);
    final kpi = result.sections.single as KpiSectionResult;
    expect(kpi.metrics[0].value, closeTo(20, 1e-6));
  });

  test('table section is rows by aggregates', () async {
    final config = ReportConfig(id: 'r1', name: 'R', sections: [
      TableSectionConfig(
        title: 'Machines',
        rows: [
          TableRowConfig(
              key: 'Line3.CN04.drive', member: 'stat.speed', label: 'CN04'),
        ],
        aggregates: [ReportAggregate.min, ReportAggregate.max],
      ),
    ]);
    final result = await engine.generate(config,
        rangeStart: shiftStart, rangeEnd: shiftEnd, now: at(600));
    final table = result.sections.single as TableSectionResult;
    expect(table.rows.single.label, 'CN04');
    expect(table.rows.single.cells.map((c) => c.value), [50, 70]);
  });

  test('chart section buckets the range', () async {
    final config = ReportConfig(id: 'r1', name: 'R', sections: [
      ChartSectionConfig(series: [
        ReportChartSeriesConfig(key: 'Line3.CN04.temperature', label: 'Temp'),
      ], maxPoints: 8),
    ]);
    final result = await engine.generate(config,
        rangeStart: shiftStart, rangeEnd: shiftEnd, now: at(600));
    final chart = result.sections.single as ChartSectionResult;
    // Only one in-range sample (the +4h jump): one non-empty bucket.
    expect(chart.series.single.points.length, 1);
    expect(chart.series.single.points.single.avg, 30);
  });

  group('alarm sections', () {
    setUp(() async {
      // Straddles the start: only 30 min of it belong to the shift.
      await alarmRow('straddler', at(-30), at(30));
      // Chatterer: three short activations inside the shift.
      for (var i = 0; i < 3; i++) {
        await alarmRow('chatty', at(60 + i * 10), at(65 + i * 10),
            level: 'warning');
      }
      // Cleared long before the shift: must not appear.
      await alarmRow('old', at(-300), at(-240));
      // Written with the '' sentinel AlarmMan uses for never-deactivated.
      await db.customStatement(
          'INSERT INTO alarm_history (alarm_uid, alarm_title, '
          'alarm_description, alarm_level, active, pending_ack, created_at, '
          "deactivated_at) VALUES ('stuck', 'Alarm stuck', 'stuck', 'error', "
          "1, 0, ?, '')",
          [at(200).toIso8601String()]);
    });

    test('summary counts overlap, not started-inside', () async {
      final config = ReportConfig(id: 'r1', name: 'R', sections: [
        AlarmSummarySectionConfig(topN: 2),
      ]);
      final result = await engine.generate(config,
          rangeStart: shiftStart, rangeEnd: shiftEnd, now: at(600));
      final summary = result.sections.single as AlarmSummarySectionResult;
      expect(summary.distinctAlarms, 3); // straddler, chatty, stuck — not old
      expect(summary.totalActivations, 5);
      expect(summary.topByCount.first.uid, 'chatty');
      expect(summary.topByCount.first.count, 3);
      // The '' row reads as still standing.
      expect(summary.openNow, 1);
      expect(summary.topByCount.length, 2);
    });

    test('downtime unions concurrent stops and honours countsAsStop',
        () async {
      // Overlapping second stop inside the straddler window — union, not sum.
      await alarmRow('parallel', at(10), at(40));
      final config = ReportConfig(id: 'r1', name: 'R', sections: [
        DowntimeSectionConfig(topN: 5),
      ]);
      final meta = {
        'chatty': const AlarmMetaLite(
            uid: 'chatty', title: 'Chatty', countsAsStop: false),
        // 'stuck' left out of the meta: defaults to counting as a stop.
      };
      final result = await engine.generate(config,
          rangeStart: shiftStart,
          rangeEnd: shiftEnd,
          now: at(600),
          alarmMeta: meta);
      final downtime = result.sections.single as DowntimeSectionResult;
      // Stops: [start..+40] (straddler ∪ parallel, clipped) and the open
      // 'stuck' from +200 to shift end.
      expect(downtime.totalDown,
          Duration(minutes: 40) + Duration(minutes: 480 - 200));
      expect(downtime.stops, 2);
      expect(downtime.openNow, isTrue);
      expect(downtime.topByDuration.map((a) => a.uid),
          isNot(contains('chatty')));
    });

    test('live active alarms fill the open interval gap', () async {
      final config = ReportConfig(id: 'r1', name: 'R', sections: [
        AlarmSummarySectionConfig(topN: 5),
      ]);
      final result = await engine.generate(
        config,
        rangeStart: shiftStart,
        rangeEnd: shiftEnd,
        now: at(600),
        activeAlarms: [
          OpenAlarm(
              uid: 'live', title: 'Live', level: 'error', start: at(100)),
          // Duplicate of a history row: must count once.
          OpenAlarm(
              uid: 'straddler',
              title: 'Alarm straddler',
              level: 'error',
              start: at(-30)),
        ],
      );
      final summary = result.sections.single as AlarmSummarySectionResult;
      expect(summary.distinctAlarms, 4);
      final live =
          summary.topByCount.singleWhere((a) => a.uid == 'live');
      expect(live.openNow, isTrue);
      final straddler =
          summary.topByCount.singleWhere((a) => a.uid == 'straddler');
      expect(straddler.count, 1);
    });
  });

  group('sql sections', () {
    test('runs a read-only query with :from/:to bound to the range',
        () async {
      final config = ReportConfig(id: 'r1', name: 'R', sections: [
        SqlSectionConfig(
          title: 'Counter rows',
          query: 'SELECT time, value FROM "Line3.counter" '
              'WHERE time > :from AND time <= :to ORDER BY time',
        ),
      ]);
      final result = await engine.generate(config,
          rangeStart: shiftStart, rangeEnd: shiftEnd, now: at(600));
      final sql = result.sections.single as SqlSectionResult;
      expect(sql.error, isNull);
      expect(sql.columns, ['time', 'value']);
      // The three in-shift counter samples; the pre-shift one is excluded.
      expect(sql.rows, hasLength(3));
      expect(sql.rows.map((r) => r[1]), ['1400', '0', '300']);
      expect(result.toText(), contains('Counter rows'));
    });

    test('rejects non-SELECT and multi-statement queries without running',
        () async {
      for (final bad in [
        'DELETE FROM "Line3.counter"',
        'SELECT 1; SELECT 2',
        '',
      ]) {
        final config = ReportConfig(id: 'r1', name: 'R', sections: [
          SqlSectionConfig(query: bad),
        ]);
        final result = await engine.generate(config,
            rangeStart: shiftStart, rangeEnd: shiftEnd, now: at(600));
        final sql = result.sections.single as SqlSectionResult;
        expect(sql.error, isNotNull, reason: bad);
        expect(sql.rows, isEmpty);
      }
      // The table is untouched by the rejected DELETE.
      final rows =
          await db.customSelect('SELECT count(*) AS c FROM "Line3.counter"')
              .getSingle();
      expect(rows.read<int>('c'), 4);
    });

    test('a failing query is an error section, not a failed report',
        () async {
      final config = ReportConfig(id: 'r1', name: 'R', sections: [
        SqlSectionConfig(query: 'SELECT * FROM "no.such.table"'),
        TextSectionConfig(text: 'still here'),
      ]);
      final result = await engine.generate(config,
          rangeStart: shiftStart, rangeEnd: shiftEnd, now: at(600));
      expect((result.sections.first as SqlSectionResult).error, isNotNull);
      expect((result.sections.last as TextSectionResult).text, 'still here');
    });

    test('rows past max_rows are dropped and flagged', () async {
      final config = ReportConfig(id: 'r1', name: 'R', sections: [
        SqlSectionConfig(
            query: 'SELECT value FROM "Line3.counter" ORDER BY time',
            maxRows: 2),
      ]);
      final result = await engine.generate(config,
          rangeStart: shiftStart, rangeEnd: shiftEnd, now: at(600));
      final sql = result.sections.single as SqlSectionResult;
      expect(sql.rows, hasLength(2));
      expect(sql.truncated, isTrue);
      expect(sql.toText(), contains('truncated'));
    });
  });

  test('text sections and report text rendering', () async {
    final config = ReportConfig(id: 'r1', name: 'Morning report', sections: [
      TextSectionConfig(title: 'Notes', text: 'Handover: all quiet.'),
    ]);
    final result = await engine.generate(config,
        rangeStart: shiftStart,
        rangeEnd: shiftEnd,
        rangeLabel: 'Day 2026-09-01',
        now: at(600));
    expect(result.toText(), contains('# Morning report — Day 2026-09-01'));
    expect(result.toText(), contains('Handover: all quiet.'));
    expect(result.toJson()['sections'], hasLength(1));
  });

  group('ReportStore', () {
    test('report and shift configs round-trip through flutter_preferences',
        () async {
      final store = ReportStore(db, isPostgres: false);
      expect((await store.loadReports()).reports, isEmpty);

      final config = ReportManConfig(reports: [
        ReportConfig(id: 'r1', name: 'Shift report', sections: [
          KpiSectionConfig(metrics: [
            ReportMetricConfig(key: 'Line3.counter'),
          ]),
          AlarmSummarySectionConfig(),
        ]),
      ]);
      await store.saveReports(config);
      // Save twice: the upsert path must update, not fail on conflict.
      config.reports.first.name = 'Renamed';
      await store.saveReports(config);

      final loaded = await store.loadReports();
      expect(loaded.reports.single.name, 'Renamed');
      expect(loaded.reports.single.sections, hasLength(2));
      expect(loaded.reports.single.sections.first, isA<KpiSectionConfig>());

      await store.saveShifts(ShiftManConfig(shifts: [
        ShiftDef(name: 'Day', startMinutes: 420, durationMinutes: 480),
      ]));
      expect((await store.loadShifts()).shifts.single.name, 'Day');
    });

    test('alarm meta comes from the alarm_man_config blob', () async {
      final store = ReportStore(db, isPostgres: false);
      await db.customStatement(
          'INSERT INTO flutter_preferences (key, value, type) VALUES '
          "('alarm_man_config', ?, 'String')",
          [
            '{"alarms": [{"uid": "a1", "title": "Door", '
                '"countsAsStop": false}, {"uid": "a2", "title": "Jam"}]}'
          ]);
      final meta = await store.loadAlarmMeta();
      expect(meta['a1']?.countsAsStop, isFalse);
      expect(meta['a2']?.countsAsStop, isTrue);
      expect(meta['a2']?.title, 'Jam');
    });
  });
}

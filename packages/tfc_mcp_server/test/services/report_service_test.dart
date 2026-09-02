import 'package:test/test.dart';
import 'package:tfc_dart/tfc_dart_core.dart';
import 'package:tfc_mcp_server/src/database/server_database.dart';
import 'package:tfc_mcp_server/src/services/report_service.dart';

import '../helpers/test_database.dart';

void main() {
  late ServerDatabase db;
  late ReportService service;

  // A fixed clock mid-shift: Tuesday 2026-09-01 10:00 local.
  final now = DateTime(2026, 9, 1, 10);
  final shiftStart = DateTime(2026, 9, 1, 7);
  DateTime at(int minutes) => shiftStart.add(Duration(minutes: minutes));

  setUp(() async {
    db = createTestDatabase();
    await db.customStatement('SELECT 1');
    service = ReportService(db, clock: () => now);
  });

  tearDown(() => db.close());

  Map<String, dynamic> reportJson(String id) => {
        'id': id,
        'name': 'Shift report',
        'range': 'shift',
        'sections': [
          {
            'type': 'kpi',
            'metrics': [
              {
                'key': 'line.temperature',
                'label': 'Temp',
                'aggregate': 'time_weighted_mean',
                'unit': '°C',
              },
            ],
          },
        ],
      };

  Future<void> seedShifts() => service.setShifts([
        {'name': 'Day', 'start_minutes': 420, 'duration_minutes': 480},
        {'name': 'Night', 'start_minutes': 900, 'duration_minutes': 960},
      ]);

  group('definition CRUD', () {
    test('create, list, get, update, delete round-trip', () async {
      expect(await service.listReports(), isEmpty);

      final created = await service.createReport(reportJson('r1'));
      expect(created['ok'], isTrue);

      final listed = await service.listReports();
      expect(listed.single['id'], 'r1');
      expect(listed.single['sections'], 1);
      expect(listed.single['range'], 'shift');

      final definition = await service.getReportDefinition('r1');
      expect(definition?['name'], 'Shift report');

      final updated = await service.updateReport(
          'r1', {...reportJson('r1'), 'name': 'Renamed'});
      expect(updated['ok'], isTrue);
      expect((await service.getReportDefinition('r1'))?['name'], 'Renamed');

      expect((await service.deleteReport('r1'))['ok'], isTrue);
      expect(await service.listReports(), isEmpty);
    });

    test('duplicate create, missing update/delete are errors', () async {
      await service.createReport(reportJson('r1'));
      final dup = await service.createReport(reportJson('r1'));
      expect(dup['error'], contains('already exists'));
      expect((await service.updateReport('nope', reportJson('nope')))['error'],
          contains('nope'));
      expect((await service.deleteReport('nope'))['error'], contains('nope'));
    });

    test('an unknown section type names the valid ones', () async {
      final result = await service.createReport({
        ...reportJson('r1'),
        'sections': [
          {'type': 'pie_of_lies'}
        ],
      });
      expect(result['error'], contains('pie_of_lies'));
      for (final valid in ReportService.validSectionTypes) {
        expect(result['error'], contains(valid));
      }
    });
  });

  group('shift calendar', () {
    test('set and get round-trip', () async {
      await seedShifts();
      final got = await service.getShifts();
      expect((got['shifts'] as List).length, 2);
      expect((got['shifts'] as List).first['name'], 'Day');
    });

    test('validation rejects nonsense', () async {
      expect(
          (await service.setShifts([
            {'name': '', 'start_minutes': 0, 'duration_minutes': 60}
          ]))['error'],
          contains('empty name'));
      expect(
          (await service.setShifts([
            {'name': 'X', 'start_minutes': 1440, 'duration_minutes': 60}
          ]))['error'],
          contains('start_minutes'));
      expect(
          (await service.setShifts([
            {'name': 'X', 'start_minutes': 0, 'duration_minutes': 0}
          ]))['error'],
          contains('duration_minutes'));
      expect(
          (await service.setShifts([
            {
              'name': 'X',
              'start_minutes': 0,
              'duration_minutes': 60,
              'weekdays': [0]
            }
          ]))['error'],
          contains('weekdays'));
    });

    test('resolveShift without a calendar explains itself', () async {
      final result = await service.resolveShift();
      expect(result['error'], contains('set_shift_calendar'));
    });

    test('resolveShift walks backwards', () async {
      await seedShifts();
      final current = await service.resolveShift();
      final shift = current['shift'] as Map<String, dynamic>;
      expect(shift['name'], 'Day');
      expect(shift['current'], isTrue);
      expect(DateTime.parse(shift['start'] as String), shiftStart);

      final previous = await service.resolveShift(offset: -1);
      expect((previous['shift'] as Map)['name'], 'Night');
      expect((previous['pattern'] as List).length, 2);
    });
  });

  group('generateReport', () {
    setUp(() async {
      await service.createReport(reportJson('r1'));
      await db.customStatement(
          'CREATE TABLE "line.temperature" ("value" REAL, "time" TEXT)');
      Future<void> insert(DateTime t, num v) => db.customStatement(
          'INSERT INTO "line.temperature" ("time", "value") VALUES (?, ?)',
          [t.toUtc().toIso8601String(), v]);
      await insert(at(-60), 20);
      await insert(at(60), 40);
    });

    test('an unknown report id is an error', () async {
      final result = await service.generateReport(reportId: 'nope');
      expect(result['error'], contains('list_reports'));
    });

    test('a shift report without a calendar points at set_shift_calendar',
        () async {
      final result = await service.generateReport(reportId: 'r1');
      expect(result['error'], contains('set_shift_calendar'));
    });

    test('generates the current shift so far', () async {
      await seedShifts();
      final result = await service.generateReport(reportId: 'r1');
      expect(result['error'], isNull);
      expect(result['text'], contains('(so far)'));
      final json = result['json'] as Map<String, dynamic>;
      expect(json['partial'], isTrue);
      expect(DateTime.parse(json['range_start'] as String), shiftStart);
      // 20° for the first hour, 40° for the two hours up to now.
      final kpi = (json['sections'] as List).single as Map<String, dynamic>;
      final metric = (kpi['metrics'] as List).single as Map<String, dynamic>;
      expect(metric['value'], closeTo((20 * 1 + 40 * 2) / 3, 1e-6));
    });

    test('offset -1 is the previous shift, complete', () async {
      await seedShifts();
      final result = await service.generateReport(reportId: 'r1', offset: -1);
      expect(result['error'], isNull);
      final json = result['json'] as Map<String, dynamic>;
      expect(json['partial'], isFalse);
      // Previous shift is last night's Night shift, 15:00 yesterday + 16h.
      expect(DateTime.parse(json['range_start'] as String),
          DateTime(2026, 8, 31, 15));
    });

    test('explicit from/to override the shift calendar entirely', () async {
      final result = await service.generateReport(
        reportId: 'r1',
        from: at(0),
        to: at(120),
      );
      expect(result['error'], isNull);
      final json = result['json'] as Map<String, dynamic>;
      expect(json['partial'], isFalse);

      final half = await service.generateReport(
          reportId: 'r1', from: at(120), to: at(0));
      expect(half['error'], contains('after'));
      final lonely =
          await service.generateReport(reportId: 'r1', from: at(0));
      expect(lonely['error'], contains('both'));
    });

    test('day-range reports use calendar days', () async {
      await service.createReport({
        ...reportJson('day1'),
        'id': 'day1',
        'range': 'day',
      });
      final result =
          await service.generateReport(reportId: 'day1', offset: -1);
      final json = result['json'] as Map<String, dynamic>;
      expect(DateTime.parse(json['range_start'] as String),
          DateTime(2026, 8, 31));
      expect(DateTime.parse(json['range_end'] as String), DateTime(2026, 9, 1));
      expect(json['range_label'], '2026-08-31');
    });
  });
}

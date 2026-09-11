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

  /// Seeds real state through the store: the service no longer writes, so a
  /// test that needs an existing calendar has to put one there itself.
  Future<void> seedShifts() =>
      ReportStore(db, isPostgres: false).saveShifts(ShiftManConfig(shifts: [
        ShiftDef(name: 'Day', startMinutes: 420, durationMinutes: 480),
        ShiftDef(name: 'Night', startMinutes: 900, durationMinutes: 960),
      ]));

  Future<void> seedReport(Map<String, dynamic> json) async {
    final store = ReportStore(db, isPostgres: false);
    final config = await store.loadReports();
    config.reports.add(ReportConfig.fromJson(json));
    await store.saveReports(config);
  }

  group('definition validation', () {
    test('the service writes nothing — validation only', () async {
      final checked = await service.validateNewReport(reportJson('r1'));
      expect(checked['report'], isNotNull);
      // The whole point: the definition did NOT land. Only a person applying
      // the proposal in the editor can do that.
      expect(await service.listReports(), isEmpty);
    });

    test('read side sees what the store holds', () async {
      await seedReport(reportJson('r1'));

      final listed = await service.listReports();
      expect(listed.single['id'], 'r1');
      expect(listed.single['sections'], 1);
      expect(listed.single['range'], 'shift');
      expect((await service.getReportDefinition('r1'))?['name'],
          'Shift report');
    });

    test('an update carries what it would replace, for the diff', () async {
      await seedReport(reportJson('r1'));
      final checked = await service
          .validateReportUpdate('r1', {...reportJson('r1'), 'name': 'Renamed'});
      expect((checked['report'] as Map)['name'], 'Renamed');
      expect((checked['before'] as Map)['name'], 'Shift report');
      // Still untouched on disk.
      expect((await service.getReportDefinition('r1'))?['name'],
          'Shift report');
    });

    test('duplicate create, missing update/delete are errors', () async {
      await seedReport(reportJson('r1'));
      final dup = await service.validateNewReport(reportJson('r1'));
      expect(dup['error'], contains('already exists'));
      expect(
          (await service.validateReportUpdate('nope', reportJson('nope')))['error'],
          contains('nope'));
      expect((await service.validateReportDelete('nope'))['error'],
          contains('nope'));
    });

    test('an unknown section type names the valid ones', () async {
      final result = await service.validateNewReport({
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

  group('production window validation', () {
    Map<String, dynamic> validWindow() => {
          'signals': [
            {
              'label': 'Line 3',
              'running': {'key': 'line.running'},
              'cleaning': {
                'key': 'line.mode',
                'member': 'stat.runMode',
                'equals': 4,
              },
            },
          ],
          'idle_minutes': 30,
          'cleaning_minutes': 10,
        };

    Map<String, dynamic> withWindow(Map<String, dynamic> window) => {
          ...reportJson('r1'),
          'window': window,
        };

    test('a window and scoped sections survive validation', () async {
      final checked = await service.validateNewReport({
        ...withWindow(validWindow()),
        'sections': [
          {'type': 'kpi', 'scope': 'running', 'metrics': <dynamic>[]},
          {'type': 'alarm_summary', 'scope': 'nominal'},
        ],
      });
      expect(checked['error'], isNull);
      final report = checked['report'] as Map<String, dynamic>;
      expect((report['window'] as Map)['idle_minutes'], 30);
      expect((report['window'] as Map)['signals'], hasLength(1));
      expect((report['sections'] as List).first['scope'], 'running');
    });

    test('idle and cleaning thresholds must be positive', () async {
      // Zero parses perfectly well and then concludes the shift the instant
      // the line pauses, so the check is here rather than in the model.
      final idle = await service
          .validateNewReport(withWindow({...validWindow(), 'idle_minutes': 0}));
      expect(idle['error'], contains('idle_minutes'));
      expect(idle['error'], contains('greater than 0'));

      final cleaning = await service.validateNewReport(
          withWindow({...validWindow(), 'cleaning_minutes': -5}));
      expect(cleaning['error'], contains('cleaning_minutes'));
    });

    test('a signal needs the key that says it is producing', () async {
      final result = await service.validateNewReport(withWindow({
        'signals': [
          {
            'running': {'key': ''}
          }
        ],
      }));
      expect(result['error'], contains('running'));
      expect(result['error'], contains('key'));
    });

    test('a rule may not set both above and equals', () async {
      final result = await service.validateNewReport(withWindow({
        'signals': [
          {
            'running': {'key': 'line.running', 'above': 0, 'equals': 4}
          }
        ],
      }));
      expect(result['error'], contains('above'));
      expect(result['error'], contains('equals'));
    });

    test('max_gap_minutes is null or a positive number', () async {
      final result = await service.validateNewReport(withWindow({
        'signals': [
          {
            'running': {'key': 'line.running'},
            'max_gap_minutes': 0,
          }
        ],
      }));
      expect(result['error'], contains('max_gap_minutes'));
    });

    test('an unknown scope names the valid ones', () async {
      final result = await service.validateNewReport({
        ...reportJson('r1'),
        'sections': [
          {'type': 'kpi', 'scope': 'whenever', 'metrics': <dynamic>[]}
        ],
      });
      expect(result['error'], contains('whenever'));
      for (final scope in ReportService.validScopes) {
        expect(result['error'], contains(scope));
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
          (await service.validateShifts([
            {'name': '', 'start_minutes': 0, 'duration_minutes': 60}
          ]))['error'],
          contains('empty name'));
      expect(
          (await service.validateShifts([
            {'name': 'X', 'start_minutes': 1440, 'duration_minutes': 60}
          ]))['error'],
          contains('start_minutes'));
      expect(
          (await service.validateShifts([
            {'name': 'X', 'start_minutes': 0, 'duration_minutes': 0}
          ]))['error'],
          contains('duration_minutes'));
      expect(
          (await service.validateShifts([
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
      await seedReport(reportJson('r1'));
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

    test('a windowed report resolves when production actually ran', () async {
      await db.customStatement(
          'CREATE TABLE "line.running" ("value" REAL, "time" TEXT)');
      await db.customStatement(
          'INSERT INTO "line.running" ("time", "value") VALUES (?, ?)',
          [at(-30).toUtc().toIso8601String(), 1]);
      await seedReport({
        ...reportJson('windowed'),
        'window': {
          'signals': [
            {
              'running': {'key': 'line.running'}
            }
          ],
        },
      });

      final result = await service.generateReport(
          reportId: 'windowed', from: at(0), to: at(120));
      expect(result['error'], isNull);
      final window = (result['json'] as Map)['window'] as Map<String, dynamic>;
      expect(window['reason'], 'shiftEnd');
      expect(DateTime.parse(window['actual_start'] as String), at(0));
      // The window leads the rendered report: what the figures cover is the
      // first thing a reader has to know.
      expect(result['text'], contains('Production'));
    });

    test('day-range reports use calendar days', () async {
      await seedReport({
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

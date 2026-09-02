import 'package:tfc_dart/tfc_dart_core.dart';

import 'sql_dialect.dart';

/// Service for listing, generating and configuring static reports.
///
/// Backed by [ReportStore] (definitions and the shift calendar in the shared
/// `flutter_preferences` table) and [ReportEngine] (aggregation over the
/// collected timeseries tables and `alarm_history`), both from tfc_dart, so
/// the same behaviour runs standalone and in-process.
///
/// Unlike the asset/alarm write tools, the report mutations here are NOT
/// proposals: a report definition describes how to *read* data, never how to
/// touch the plant, so it is applied directly (and audited) rather than
/// routed through the operator's proposal banner.
class ReportService {
  ReportService(McpDatabase db, {DateTime Function()? clock})
      : _store = ReportStore(db, isPostgres: isPostgresDb(db)),
        _engine = ReportEngine(db, isPostgres: isPostgresDb(db)),
        _clock = clock ?? DateTime.now;

  final ReportStore _store;
  final ReportEngine _engine;

  /// Injected in tests so shift resolution has a fixed "now".
  final DateTime Function() _clock;

  static const validSectionTypes = [
    KpiSectionConfig.kType,
    TableSectionConfig.kType,
    ChartSectionConfig.kType,
    AlarmSummarySectionConfig.kType,
    DowntimeSectionConfig.kType,
    SqlSectionConfig.kType,
    TextSectionConfig.kType,
  ];

  Future<List<Map<String, dynamic>>> listReports() async {
    final config = await _store.loadReports();
    return [
      for (final r in config.reports)
        {
          'id': r.id,
          'name': r.name,
          if (r.description != null) 'description': r.description,
          'range': r.range.name,
          'sections': r.sections.length,
        },
    ];
  }

  Future<Map<String, dynamic>?> getReportDefinition(String id) async {
    final config = await _store.loadReports();
    for (final r in config.reports) {
      if (r.id == id) return r.toJson();
    }
    return null;
  }

  /// Resolves the time range for [report] at [offset] periods back from now.
  ///
  /// Returns (start, end, label) or throws [StateError] with a message fit
  /// for the LLM.
  Future<(DateTime, DateTime, String)> _resolveRange(
      ReportConfig report, int offset) async {
    final now = _clock();
    switch (report.range) {
      case ReportRangeKind.shift:
        final calendar = ShiftCalendar(await _store.loadShifts());
        if (calendar.isEmpty) {
          throw StateError(
              'No shift calendar is configured. Configure one with '
              'set_shift_calendar, or pass explicit from/to times.');
        }
        final shift = calendar.byOffset(now, offset);
        if (shift == null) {
          throw StateError('No shift found $offset shifts back from now.');
        }
        return (shift.start, shift.end, shift.label);
      case ReportRangeKind.day:
        final day = DateTime(now.year, now.month, now.day + offset);
        final label = '${day.year}-${_two(day.month)}-${_two(day.day)}';
        return (day, DateTime(day.year, day.month, day.day + 1), label);
      case ReportRangeKind.week:
        final monday = DateTime(
            now.year, now.month, now.day - (now.weekday - 1) + offset * 7);
        return (
          monday,
          DateTime(monday.year, monday.month, monday.day + 7),
          'Week of ${monday.year}-${_two(monday.month)}-${_two(monday.day)}',
        );
    }
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// Generates [reportId] over the requested range.
  ///
  /// Explicit [from]/[to] win; otherwise the report's own range kind is
  /// resolved [offset] periods back from now (0 = the current period).
  Future<Map<String, dynamic>> generateReport({
    required String reportId,
    int offset = 0,
    DateTime? from,
    DateTime? to,
  }) async {
    final config = await _store.loadReports();
    ReportConfig? report;
    for (final r in config.reports) {
      if (r.id == reportId) report = r;
    }
    if (report == null) {
      return {
        'error': 'No report with id "$reportId". '
            'Use list_reports to see what exists.'
      };
    }

    final DateTime start;
    final DateTime end;
    final String label;
    if (from != null && to != null) {
      if (!to.isAfter(from)) {
        return {'error': '"to" must be after "from".'};
      }
      start = from;
      end = to;
      label = '${from.toIso8601String()} .. ${to.toIso8601String()}';
    } else if (from != null || to != null) {
      return {'error': 'Pass both from and to, or neither.'};
    } else {
      try {
        final resolved = await _resolveRange(report, offset);
        start = resolved.$1;
        end = resolved.$2;
        label = resolved.$3;
      } on StateError catch (e) {
        return {'error': e.message};
      }
    }

    final result = await _engine.generate(
      report,
      rangeStart: start,
      rangeEnd: end,
      rangeLabel: label,
      now: _clock(),
      alarmMeta: await _store.loadAlarmMeta(),
    );
    return {'text': result.toText(), 'json': result.toJson()};
  }

  /// The shift interval [offset] shifts back from now, plus the configured
  /// pattern — so a client can both name a shift and learn the calendar.
  Future<Map<String, dynamic>> resolveShift({int offset = 0}) async {
    final shiftConfig = await _store.loadShifts();
    final pattern = [for (final s in shiftConfig.shifts) s.toJson()];
    final calendar = ShiftCalendar(shiftConfig);
    if (calendar.isEmpty) {
      return {
        'error': 'No shift calendar is configured. '
            'Configure one with set_shift_calendar.',
        'pattern': pattern,
      };
    }
    final shift = calendar.byOffset(_clock(), offset);
    if (shift == null) {
      return {
        'error': 'No shift found $offset shifts back from now.',
        'pattern': pattern,
      };
    }
    return {
      'shift': {
        'name': shift.def.name,
        'label': shift.label,
        'start': shift.start.toIso8601String(),
        'end': shift.end.toIso8601String(),
        'production_date': shift.productionDate.toIso8601String(),
        'current': shift.contains(_clock()),
      },
      'pattern': pattern,
    };
  }

  /// Parses [json] as a report definition, or returns an error string that
  /// tells the caller what was wrong and what would be valid.
  ReportConfig? _parseReport(Map<String, dynamic> json, List<String> errors) {
    try {
      final report = ReportConfig.fromJson(json);
      if (report.id.isEmpty) errors.add('Report id must not be empty.');
      if (report.name.isEmpty) errors.add('Report name must not be empty.');
      return errors.isEmpty ? report : null;
    } on ArgumentError catch (e) {
      errors.add('${e.message}. '
          'Valid section types: ${validSectionTypes.join(', ')}.');
      return null;
    } catch (e) {
      errors.add('Could not parse report config: $e. '
          'Valid section types: ${validSectionTypes.join(', ')}.');
      return null;
    }
  }

  Future<Map<String, dynamic>> createReport(Map<String, dynamic> json) async {
    final errors = <String>[];
    final report = _parseReport(json, errors);
    if (report == null) return {'error': errors.join(' ')};

    final config = await _store.loadReports();
    if (config.reports.any((r) => r.id == report.id)) {
      return {
        'error': 'A report with id "${report.id}" already exists. '
            'Use update_report to change it.'
      };
    }
    config.reports.add(report);
    await _store.saveReports(config);
    return {'ok': true, 'report': report.toJson()};
  }

  Future<Map<String, dynamic>> updateReport(
      String id, Map<String, dynamic> json) async {
    final errors = <String>[];
    final report = _parseReport({...json, 'id': id}, errors);
    if (report == null) return {'error': errors.join(' ')};

    final config = await _store.loadReports();
    final index = config.reports.indexWhere((r) => r.id == id);
    if (index < 0) {
      return {'error': 'No report with id "$id" to update.'};
    }
    config.reports[index] = report;
    await _store.saveReports(config);
    return {'ok': true, 'report': report.toJson()};
  }

  Future<Map<String, dynamic>> deleteReport(String id) async {
    final config = await _store.loadReports();
    final before = config.reports.length;
    config.reports.removeWhere((r) => r.id == id);
    if (config.reports.length == before) {
      return {'error': 'No report with id "$id" to delete.'};
    }
    await _store.saveReports(config);
    return {'ok': true};
  }

  Future<Map<String, dynamic>> getShifts() async {
    final config = await _store.loadShifts();
    return {
      'shifts': [for (final s in config.shifts) s.toJson()],
    };
  }

  /// Replaces the shift calendar. Each entry needs `name`, `start_minutes`
  /// (0..1439) and `duration_minutes` (> 0); `weekdays` (1=Monday..7=Sunday)
  /// defaults to every day.
  Future<Map<String, dynamic>> setShifts(List<dynamic> shifts) async {
    final parsed = <ShiftDef>[];
    for (var i = 0; i < shifts.length; i++) {
      final entry = shifts[i];
      if (entry is! Map<String, dynamic>) {
        return {'error': 'Shift $i is not an object.'};
      }
      final ShiftDef def;
      try {
        def = ShiftDef.fromJson(entry);
      } catch (e) {
        return {'error': 'Shift $i could not be parsed: $e'};
      }
      if (def.name.isEmpty) {
        return {'error': 'Shift $i has an empty name.'};
      }
      if (def.startMinutes < 0 || def.startMinutes >= 24 * 60) {
        return {
          'error': 'Shift "${def.name}": start_minutes must be 0..1439.'
        };
      }
      if (def.durationMinutes <= 0 || def.durationMinutes > 24 * 60) {
        return {
          'error':
              'Shift "${def.name}": duration_minutes must be 1..1440.'
        };
      }
      if (def.weekdays.any((d) => d < DateTime.monday || d > DateTime.sunday)) {
        return {
          'error': 'Shift "${def.name}": weekdays must be 1 (Monday) '
              'through 7 (Sunday).'
        };
      }
      parsed.add(def);
    }
    await _store.saveShifts(ShiftManConfig(shifts: parsed));
    return {
      'ok': true,
      'shifts': [for (final s in parsed) s.toJson()],
    };
  }
}

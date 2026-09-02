import 'package:drift/drift.dart';

import 'mcp_database.dart';
import 'report.dart';
import 'report_math.dart';
import 'report_result.dart';
import 'report_store.dart';
import 'sql_dialect.dart';

/// An alarm standing right now, as plain data. `alarm_history` only gets a
/// row when an alarm *clears*, so the caller with access to the live alarm
/// set passes the open ones in here; a caller without one (the standalone
/// MCP server) simply reports on closed activations only.
class OpenAlarm {
  final String uid;
  final String title;
  final String level;
  final DateTime start;

  const OpenAlarm({
    required this.uid,
    required this.title,
    required this.level,
    required this.start,
  });
}

class _Activation {
  final String uid;
  final String title;
  final String level;
  final DateTime start;
  final DateTime? end;

  const _Activation(this.uid, this.title, this.level, this.start, this.end);
}

/// Evaluates a [ReportConfig] over one concrete time range.
///
/// Works over [McpDatabase] with raw SQL so the same engine runs inside the
/// Flutter app (AppDatabase), the in-process MCP server, and the standalone
/// MCP binary (ServerDatabase). Aggregation is computed in Dart from fetched
/// samples rather than in dialect-specific SQL: report ranges are shifts and
/// days, small enough to fetch, and the math being pure Dart is what makes it
/// unit-testable sample by sample.
class ReportEngine {
  ReportEngine(
    this._db, {
    this.isPostgres = true,
    String Function(String key)? resolveKey,
  }) : _resolveKey = resolveKey ?? ((k) => k);

  final McpDatabase _db;

  /// False only under the SQLite test harness.
  final bool isPostgres;

  /// Expands `$variable` substitutions in keys — the app passes
  /// `StateMan.resolveKey`; standalone callers use identity.
  final String Function(String key) _resolveKey;

  /// Refuse to pull more than this many samples for one metric — a report
  /// over a huge range belongs in a coarser query, not in memory.
  static const int maxSamples = 1000000;

  String _sql(String sql) => adaptSqlPlaceholders(sql, isPostgres: isPostgres);
  String get _tsCast => isPostgres ? '::timestamptz' : '';

  final Map<String, bool> _tableExistsCache = {};

  Future<bool> _tableExists(String tableName) async {
    final cached = _tableExistsCache[tableName];
    if (cached != null) return cached;
    final bool exists;
    if (isPostgres) {
      final result = await _db.customSelect(
        _sql('SELECT EXISTS (SELECT 1 FROM information_schema.tables '
            "WHERE table_schema = 'public' AND table_name = ?) AS \"exists\""),
        variables: [Variable.withString(tableName)],
      ).getSingle();
      exists = result.read<bool>('exists');
    } else {
      final result = await _db.customSelect(
        "SELECT COUNT(*) AS cnt FROM sqlite_master "
        "WHERE type = 'table' AND name = ?",
        variables: [Variable.withString(tableName)],
      ).getSingle();
      exists = result.read<int>('cnt') > 0;
    }
    _tableExistsCache[tableName] = exists;
    return exists;
  }

  static DateTime _rowTime(dynamic raw) {
    if (raw is DateTime) return raw.toLocal();
    if (raw is String) return DateTime.parse(raw).toLocal();
    throw StateError('Unexpected time type: ${raw.runtimeType}');
  }

  static double? _rowValue(dynamic raw) {
    if (raw is num) return raw.toDouble();
    if (raw is bool) return raw ? 1.0 : 0.0;
    return null;
  }

  /// Fetches the samples of one table/column over `(start, end]`, plus the
  /// value standing at `start`. Throws on SQL errors; the per-metric caller
  /// turns those into an error cell rather than failing the report.
  Future<SampleWindow> _fetchWindow(
    String table,
    String column,
    DateTime start,
    DateTime end,
  ) async {
    final qTable = quoteIdentifier(table);
    final qCol = quoteIdentifier(column);
    final startIso = start.toUtc().toIso8601String();
    final endIso = end.toUtc().toIso8601String();

    final boundaryRows = await _db.customSelect(
      _sql('SELECT $qCol AS v FROM $qTable '
          'WHERE time <= ?$_tsCast AND $qCol IS NOT NULL '
          'ORDER BY time DESC LIMIT 1'),
      variables: [Variable.withString(startIso)],
    ).get();
    final boundaryValue = boundaryRows.isEmpty
        ? null
        : _rowValue(boundaryRows.first.data['v']);

    final rows = await _db.customSelect(
      _sql('SELECT time, $qCol AS v FROM $qTable '
          'WHERE time > ?$_tsCast AND time <= ?$_tsCast '
          'AND $qCol IS NOT NULL '
          'ORDER BY time ASC LIMIT ${maxSamples + 1}'),
      variables: [
        Variable.withString(startIso),
        Variable.withString(endIso),
      ],
    ).get();
    if (rows.length > maxSamples) {
      throw StateError('more than $maxSamples samples in range');
    }

    final samples = <Sample>[];
    for (final row in rows) {
      final v = _rowValue(row.data['v']);
      if (v == null) continue;
      samples.add(Sample(_rowTime(row.data['time']), v));
    }
    return SampleWindow(
      start: start,
      end: end,
      boundaryValue: boundaryValue,
      samples: samples,
    );
  }

  /// Evaluates [config] over `[rangeStart, rangeEnd)`.
  ///
  /// When the range end lies in the future — the current shift — every
  /// duration and average is integrated only up to [now], so a half-done
  /// shift reads "so far" rather than assuming the last value holds until
  /// the shift ends.
  Future<ReportResult> generate(
    ReportConfig config, {
    required DateTime rangeStart,
    required DateTime rangeEnd,
    String? rangeLabel,
    DateTime? now,
    List<OpenAlarm> activeAlarms = const [],
    Map<String, AlarmMetaLite> alarmMeta = const {},
  }) async {
    final clock = now ?? DateTime.now();
    final partial = rangeEnd.isAfter(clock);
    final effectiveEnd = partial ? clock : rangeEnd;

    // One fetch per (table, column) no matter how many metrics read it.
    final windows = <String, Future<SampleWindow>>{};
    Future<SampleWindow> windowFor(String key, String? member) {
      final table = _resolveKey(key);
      final column = member ?? 'value';
      return windows.putIfAbsent('$table $column', () async {
        if (!await _tableExists(table)) {
          throw StateError('no collected data for "$key" '
              '(table "$table" does not exist)');
        }
        return _fetchWindow(table, column, rangeStart, effectiveEnd);
      });
    }

    Future<MetricResult> metric({
      required String label,
      required String key,
      List<String> additionalKeys = const [],
      MetricCombine combine = MetricCombine.sum,
      required String? member,
      required ReportAggregate aggregate_,
      String? unit,
      int decimals = 1,
    }) async {
      final values = <double>[];
      final problems = <String>[];
      for (final k in [key, ...additionalKeys]) {
        try {
          final v = aggregate(aggregate_, await windowFor(k, member));
          if (v != null) values.add(v);
        } on Exception catch (e) {
          problems.add('$k: $e');
        } on StateError catch (e) {
          problems.add(e.message);
        }
      }
      if (values.isEmpty) {
        return MetricResult(
          label: label,
          aggregate: aggregate_,
          unit: unit,
          decimals: decimals,
          error: problems.isEmpty ? null : problems.join('; '),
        );
      }
      final combined = switch (combine) {
        MetricCombine.sum => values.fold(0.0, (a, b) => a + b),
        MetricCombine.mean =>
          values.fold(0.0, (a, b) => a + b) / values.length,
        MetricCombine.min => values.reduce((a, b) => a < b ? a : b),
        MetricCombine.max => values.reduce((a, b) => a > b ? a : b),
      };
      return MetricResult(
        label: label,
        aggregate: aggregate_,
        unit: unit,
        decimals: decimals,
        value: combined,
        // A partial fold still shows a number, but says what it is missing.
        error: problems.isEmpty ? null : problems.join('; '),
      );
    }

    List<_Activation>? activations;
    Future<List<_Activation>> alarmActivations() async {
      return activations ??=
          await _fetchActivations(rangeStart, effectiveEnd, activeAlarms);
    }

    final sections = <ReportSectionResult>[];
    for (final section in config.sections) {
      switch (section) {
        case KpiSectionConfig s:
          sections.add(KpiSectionResult(
            title: s.title,
            metrics: [
              for (final m in s.metrics)
                await metric(
                  label: m.displayLabel,
                  key: m.key,
                  additionalKeys: m.additionalKeys,
                  combine: m.combine,
                  member: m.member,
                  aggregate_: m.aggregate,
                  unit: m.unit,
                  decimals: m.decimals,
                ),
            ],
          ));
        case TableSectionConfig s:
          sections.add(TableSectionResult(
            title: s.title,
            aggregates: s.aggregates,
            rows: [
              for (final row in s.rows)
                TableRowResult(
                  label: row.displayLabel,
                  cells: [
                    for (final agg in s.aggregates)
                      await metric(
                        label: row.displayLabel,
                        key: row.key,
                        member: row.member,
                        aggregate_: agg,
                        unit: row.unit,
                        decimals: row.decimals,
                      ),
                  ],
                ),
            ],
          ));
        case ChartSectionConfig s:
          final series = <ChartSeriesResult>[];
          for (final cs in s.series) {
            try {
              final w = await windowFor(cs.key, cs.member);
              series.add(ChartSeriesResult(
                label: cs.displayLabel,
                points: bucketize(w, s.maxPoints),
              ));
            } catch (_) {
              series.add(
                  ChartSeriesResult(label: cs.displayLabel, points: const []));
            }
          }
          sections.add(ChartSectionResult(title: s.title, series: series));
        case AlarmSummarySectionConfig s:
          sections.add(_alarmSummary(
              s, await alarmActivations(), rangeStart, effectiveEnd));
        case DowntimeSectionConfig s:
          sections.add(_downtime(s, await alarmActivations(), alarmMeta,
              rangeStart, effectiveEnd));
        case SqlSectionConfig s:
          sections.add(await _sqlSection(s, rangeStart, effectiveEnd));
        case TextSectionConfig s:
          sections.add(TextSectionResult(title: s.title, text: s.text));
      }
    }

    return ReportResult(
      reportId: config.id,
      reportName: config.name,
      rangeStart: rangeStart,
      rangeEnd: rangeEnd,
      rangeLabel: rangeLabel ?? '',
      generatedAt: clock,
      partial: partial,
      sections: sections,
    );
  }

  /// Rejects anything that is not one single SELECT (or WITH … SELECT).
  ///
  /// This is a report, so the query is read-only by contract; the check
  /// enforces the contract before the statement reaches the database. It is
  /// a guard against mistakes and section configs written by an LLM, not a
  /// sandbox — whoever can edit reports could already reach the database.
  static String? validateSqlQuery(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return 'Query is empty.';
    final head = trimmed.toLowerCase();
    if (!head.startsWith('select') && !head.startsWith('with')) {
      return 'Only a single SELECT (or WITH … SELECT) statement is allowed.';
    }
    if (trimmed.contains(';')) {
      return 'Multiple statements are not allowed — remove the ";".';
    }
    return null;
  }

  /// Runs a custom query section. `:from`/`:to` tokens become bound
  /// parameters carrying the range as ISO-8601 UTC text.
  Future<SqlSectionResult> _sqlSection(
      SqlSectionConfig config, DateTime start, DateTime end) async {
    final invalid = validateSqlQuery(config.query);
    if (invalid != null) {
      return SqlSectionResult(
          title: config.title, columns: const [], rows: const [],
          error: invalid);
    }

    // Each :from/:to occurrence becomes its own placeholder, in order.
    final variables = <Variable>[];
    final substituted = config.query.trim().replaceAllMapped(
      RegExp(r':(from|to)\b'),
      (m) {
        variables.add(Variable.withString(m[1] == 'from'
            ? start.toUtc().toIso8601String()
            : end.toUtc().toIso8601String()));
        return '?';
      },
    );

    try {
      final rows = await _db
          .customSelect(_sql(substituted), variables: variables)
          .get();
      if (rows.isEmpty) {
        return SqlSectionResult(
            title: config.title, columns: const [], rows: const []);
      }
      final columns = rows.first.data.keys.toList();
      final capped = rows.take(config.maxRows).toList();
      String cell(dynamic v) => switch (v) {
            null => '',
            DateTime d => d.toIso8601String(),
            _ => '$v',
          };
      return SqlSectionResult(
        title: config.title,
        columns: columns,
        rows: [
          for (final row in capped)
            [for (final c in columns) cell(row.data[c])],
        ],
        truncated: rows.length > config.maxRows,
      );
    } on Exception catch (e) {
      return SqlSectionResult(
          title: config.title, columns: const [], rows: const [],
          error: '$e');
    }
  }

  /// Alarm activations overlapping the range: closed ones from
  /// `alarm_history` (overlap semantics — started-before-cleared-inside
  /// belongs to the window), open ones from [activeAlarms]. An activation
  /// present in both — history gets the row the moment it clears — is
  /// counted once, as closed.
  Future<List<_Activation>> _fetchActivations(
    DateTime start,
    DateTime end,
    List<OpenAlarm> activeAlarms,
  ) async {
    final rows = await _db.customSelect(
      _sql('SELECT alarm_uid, alarm_title, alarm_level, created_at, '
          'deactivated_at FROM alarm_history '
          'WHERE created_at <= ? AND (deactivated_at IS NULL '
          "OR deactivated_at = '' OR deactivated_at >= ?)"),
      variables: [
        // Bound as local-time ISO text to match what AlarmMan writes.
        Variable.withString(end.toIso8601String()),
        Variable.withString(start.toIso8601String()),
      ],
    ).get();

    final out = <_Activation>[];
    final seen = <String>{};
    for (final row in rows) {
      final created = DateTime.parse(row.read<String>('created_at'));
      final deactivatedRaw = row.readNullable<String>('deactivated_at');
      // AlarmMan writes '' rather than NULL when an alarm has not closed.
      final deactivated = (deactivatedRaw == null || deactivatedRaw.isEmpty)
          ? null
          : DateTime.parse(deactivatedRaw);
      final uid = row.read<String>('alarm_uid');
      // Normalised to UTC: drift text timestamps may come back in either
      // zone, while the live set's clocks are local.
      seen.add('$uid ${created.toUtc().toIso8601String()}');
      out.add(_Activation(
        uid,
        row.read<String>('alarm_title'),
        row.read<String>('alarm_level'),
        created,
        deactivated,
      ));
    }
    for (final open in activeAlarms) {
      if (open.start.isAfter(end)) continue;
      if (!seen.add('${open.uid} ${open.start.toUtc().toIso8601String()}')) {
        continue;
      }
      out.add(_Activation(open.uid, open.title, open.level, open.start, null));
    }
    return out;
  }

  /// Per-alarm stats over the range, clipped to it.
  List<AlarmStat> _stats(
      List<_Activation> activations, DateTime start, DateTime end) {
    final byUid = <String, List<_Activation>>{};
    for (final a in activations) {
      (byUid[a.uid] ??= []).add(a);
    }
    final out = <AlarmStat>[];
    byUid.forEach((uid, list) {
      var count = 0;
      var totalUs = 0;
      var open = false;
      for (final a in list) {
        final lo = a.start.isAfter(start) ? a.start : start;
        final hiRaw = a.end ?? end;
        final hi = hiRaw.isBefore(end) ? hiRaw : end;
        if (!hi.isAfter(lo) && !(a.end == null && !a.start.isAfter(end))) {
          continue;
        }
        count++;
        if (hi.isAfter(lo)) totalUs += hi.difference(lo).inMicroseconds;
        if (a.end == null) open = true;
      }
      if (count == 0) return;
      out.add(AlarmStat(
        uid: uid,
        title: list.first.title,
        level: list.first.level,
        count: count,
        total: Duration(microseconds: totalUs),
        openNow: open,
      ));
    });
    return out;
  }

  AlarmSummarySectionResult _alarmSummary(
    AlarmSummarySectionConfig config,
    List<_Activation> activations,
    DateTime start,
    DateTime end,
  ) {
    final stats = _stats(activations, start, end);
    final totalActivations =
        stats.fold<int>(0, (sum, s) => sum + s.count);
    final openNow = stats.where((s) => s.openNow).length;
    final hours = end.difference(start).inSeconds / 3600;
    final byCount = [...stats]..sort((a, b) => b.count.compareTo(a.count));
    final byDuration = [...stats]..sort((a, b) => b.total.compareTo(a.total));
    return AlarmSummarySectionResult(
      title: config.title,
      totalActivations: totalActivations,
      distinctAlarms: stats.length,
      openNow: openNow,
      perHour: hours > 0 ? totalActivations / hours : 0,
      topByCount: byCount.take(config.topN).toList(),
      topByDuration: byDuration.take(config.topN).toList(),
    );
  }

  DowntimeSectionResult _downtime(
    DowntimeSectionConfig config,
    List<_Activation> activations,
    Map<String, AlarmMetaLite> alarmMeta,
    DateTime start,
    DateTime end,
  ) {
    // An alarm missing from the meta counts as a stop — same default as
    // AlarmConfig.countsAsStop, so a deleted definition's history still shows.
    final stops = activations
        .where((a) => alarmMeta[a.uid]?.countsAsStop ?? true)
        .toList();
    final stats = _stats(stops, start, end)
      ..sort((a, b) => b.total.compareTo(a.total));

    // Union of the clipped stop intervals: two machines down at once is one
    // stretch of lost time, not two.
    final clipped = <(DateTime, DateTime)>[];
    var openNow = false;
    for (final a in stops) {
      final lo = a.start.isAfter(start) ? a.start : start;
      final hiRaw = a.end ?? end;
      final hi = hiRaw.isBefore(end) ? hiRaw : end;
      if (hi.isAfter(lo)) clipped.add((lo, hi));
      if (a.end == null) openNow = true;
    }
    clipped.sort((a, b) => a.$1.compareTo(b.$1));
    var totalUs = 0;
    var mergedCount = 0;
    DateTime? curStart, curEnd;
    for (final (lo, hi) in clipped) {
      if (curEnd == null || lo.isAfter(curEnd)) {
        if (curEnd != null) {
          totalUs += curEnd.difference(curStart!).inMicroseconds;
        }
        curStart = lo;
        curEnd = hi;
        mergedCount++;
      } else if (hi.isAfter(curEnd)) {
        curEnd = hi;
      }
    }
    if (curEnd != null) {
      totalUs += curEnd.difference(curStart!).inMicroseconds;
    }

    final rangeUs = end.difference(start).inMicroseconds;
    return DowntimeSectionResult(
      title: config.title,
      totalDown: Duration(microseconds: totalUs),
      fraction: rangeUs > 0 ? totalUs / rangeUs : 0,
      stops: mergedCount,
      openNow: openNow,
      topByDuration: stats.take(config.topN).toList(),
    );
  }
}

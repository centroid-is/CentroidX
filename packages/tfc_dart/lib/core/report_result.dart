import 'report.dart';
import 'report_math.dart';

/// Formats [seconds] as `h:mm:ss` (or `d.h:mm:ss` past a day).
String formatSeconds(double seconds) {
  final total = seconds.round();
  final d = total ~/ 86400;
  final h = (total % 86400) ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final hms = '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  return d > 0 ? '${d}d $hms' : hms;
}

/// One computed metric value. [value] is null when the key had no data in the
/// range or the query failed — [error] says which.
class MetricResult {
  final String label;
  final ReportAggregate aggregate;
  final String? unit;
  final int decimals;
  final double? value;
  final String? error;

  const MetricResult({
    required this.label,
    required this.aggregate,
    this.unit,
    this.decimals = 1,
    this.value,
    this.error,
  });

  /// The value rendered for display: durations as h:mm:ss, numbers with the
  /// configured decimals and unit, missing data as an em dash.
  String get formatted {
    final v = value;
    if (v == null) return '—';
    if (aggregate.isDuration) return formatSeconds(v);
    final num = v.toStringAsFixed(decimals);
    return unit == null || unit!.isEmpty ? num : '$num $unit';
  }

  Map<String, dynamic> toJson() => {
        'label': label,
        'aggregate': aggregate.name,
        if (unit != null) 'unit': unit,
        'value': value,
        'formatted': formatted,
        if (error != null) 'error': error,
      };
}

sealed class ReportSectionResult {
  final String? title;

  const ReportSectionResult({this.title});

  String get type;

  Map<String, dynamic> toJson();

  /// Compact plain-text rendering for MCP / LLM consumption.
  String toText();
}

class KpiSectionResult extends ReportSectionResult {
  final List<MetricResult> metrics;

  const KpiSectionResult({super.title, required this.metrics});

  @override
  String get type => KpiSectionConfig.kType;

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        if (title != null) 'title': title,
        'metrics': metrics.map((m) => m.toJson()).toList(),
      };

  @override
  String toText() {
    final b = StringBuffer();
    if (title != null) b.writeln('## $title');
    for (final m in metrics) {
      b.writeln('${m.label} (${m.aggregate.label}): ${m.formatted}'
          '${m.error != null ? '  [${m.error}]' : ''}');
    }
    return b.toString().trimRight();
  }
}

class TableRowResult {
  final String label;
  final List<MetricResult> cells;

  const TableRowResult({required this.label, required this.cells});

  Map<String, dynamic> toJson() => {
        'label': label,
        'cells': cells.map((c) => c.toJson()).toList(),
      };
}

class TableSectionResult extends ReportSectionResult {
  final List<ReportAggregate> aggregates;
  final List<TableRowResult> rows;

  const TableSectionResult({
    super.title,
    required this.aggregates,
    required this.rows,
  });

  @override
  String get type => TableSectionConfig.kType;

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        if (title != null) 'title': title,
        'columns': aggregates.map((a) => a.label).toList(),
        'rows': rows.map((r) => r.toJson()).toList(),
      };

  @override
  String toText() {
    final b = StringBuffer();
    if (title != null) b.writeln('## $title');
    b.writeln(['', ...aggregates.map((a) => a.label)].join(' | '));
    for (final r in rows) {
      b.writeln([r.label, ...r.cells.map((c) => c.formatted)].join(' | '));
    }
    return b.toString().trimRight();
  }
}

class ChartSeriesResult {
  final String label;
  final List<ReportChartPoint> points;

  const ChartSeriesResult({required this.label, required this.points});

  Map<String, dynamic> toJson() => {
        'label': label,
        'points': points
            .map((p) => {
                  'time': p.time.toIso8601String(),
                  'min': p.min,
                  'avg': p.avg,
                  'max': p.max,
                })
            .toList(),
      };
}

class ChartSectionResult extends ReportSectionResult {
  final List<ChartSeriesResult> series;

  const ChartSectionResult({super.title, required this.series});

  @override
  String get type => ChartSectionConfig.kType;

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        if (title != null) 'title': title,
        'series': series.map((s) => s.toJson()).toList(),
      };

  @override
  String toText() {
    // Charts are for eyes; the text form only summarises the envelope so an
    // LLM reading the report is not flooded with buckets.
    final b = StringBuffer();
    if (title != null) b.writeln('## $title');
    for (final s in series) {
      if (s.points.isEmpty) {
        b.writeln('${s.label}: no data');
        continue;
      }
      final lo = s.points.map((p) => p.min).reduce((a, c) => a < c ? a : c);
      final hi = s.points.map((p) => p.max).reduce((a, c) => a > c ? a : c);
      b.writeln('${s.label}: ${s.points.length} buckets, min $lo, max $hi');
    }
    return b.toString().trimRight();
  }
}

/// One alarm's showing in the range, for both the alarm summary and the
/// downtime pareto.
class AlarmStat {
  final String uid;
  final String title;
  final String level;
  final int count;

  /// Standing time clipped to the range.
  final Duration total;

  /// Whether one of its activations was still open at generation time.
  final bool openNow;

  const AlarmStat({
    required this.uid,
    required this.title,
    required this.level,
    required this.count,
    required this.total,
    required this.openNow,
  });

  Map<String, dynamic> toJson() => {
        'uid': uid,
        'title': title,
        'level': level,
        'count': count,
        'total_seconds': total.inMilliseconds / 1000,
        'open_now': openNow,
      };
}

class AlarmSummarySectionResult extends ReportSectionResult {
  final int totalActivations;
  final int distinctAlarms;
  final int openNow;
  final double perHour;
  final List<AlarmStat> topByCount;
  final List<AlarmStat> topByDuration;

  const AlarmSummarySectionResult({
    super.title,
    required this.totalActivations,
    required this.distinctAlarms,
    required this.openNow,
    required this.perHour,
    required this.topByCount,
    required this.topByDuration,
  });

  @override
  String get type => AlarmSummarySectionConfig.kType;

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        if (title != null) 'title': title,
        'total_activations': totalActivations,
        'distinct_alarms': distinctAlarms,
        'open_now': openNow,
        'per_hour': perHour,
        'top_by_count': topByCount.map((a) => a.toJson()).toList(),
        'top_by_duration': topByDuration.map((a) => a.toJson()).toList(),
      };

  @override
  String toText() {
    final b = StringBuffer();
    b.writeln('## ${title ?? 'Alarms'}');
    b.writeln('$totalActivations activations of $distinctAlarms alarms '
        '(${perHour.toStringAsFixed(1)}/h), $openNow still active');
    if (topByCount.isNotEmpty) {
      b.writeln('Most frequent:');
      for (final a in topByCount) {
        b.writeln('  ${a.title} (${a.level}): x${a.count}, '
            '${formatSeconds(a.total.inMilliseconds / 1000)}'
            '${a.openNow ? ', open' : ''}');
      }
    }
    if (topByDuration.isNotEmpty) {
      b.writeln('Longest standing:');
      for (final a in topByDuration) {
        b.writeln('  ${a.title} (${a.level}): '
            '${formatSeconds(a.total.inMilliseconds / 1000)}, x${a.count}'
            '${a.openNow ? ', open' : ''}');
      }
    }
    return b.toString().trimRight();
  }
}

class DowntimeSectionResult extends ReportSectionResult {
  /// Union of all stop intervals clipped to the range — concurrent stops do
  /// not double-count.
  final Duration totalDown;

  /// Share of the range spent down, 0..1.
  final double fraction;

  final int stops;
  final bool openNow;
  final List<AlarmStat> topByDuration;

  const DowntimeSectionResult({
    super.title,
    required this.totalDown,
    required this.fraction,
    required this.stops,
    required this.openNow,
    required this.topByDuration,
  });

  @override
  String get type => DowntimeSectionConfig.kType;

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        if (title != null) 'title': title,
        'total_down_seconds': totalDown.inMilliseconds / 1000,
        'fraction': fraction,
        'stops': stops,
        'open_now': openNow,
        'top_by_duration': topByDuration.map((a) => a.toJson()).toList(),
      };

  @override
  String toText() {
    final b = StringBuffer();
    b.writeln('## ${title ?? 'Downtime'}');
    b.writeln('Down ${formatSeconds(totalDown.inMilliseconds / 1000)} '
        '(${(fraction * 100).toStringAsFixed(1)}% of range), '
        '$stops stops${openNow ? ', one still standing' : ''}');
    for (final a in topByDuration) {
      b.writeln('  ${a.title}: '
          '${formatSeconds(a.total.inMilliseconds / 1000)}, x${a.count}'
          '${a.openNow ? ', open' : ''}');
    }
    return b.toString().trimRight();
  }
}

/// A custom query's result: stringified cells, already capped.
class SqlSectionResult extends ReportSectionResult {
  final List<String> columns;
  final List<List<String>> rows;

  /// True when the query returned more rows than the section's cap.
  final bool truncated;

  final String? error;

  const SqlSectionResult({
    super.title,
    required this.columns,
    required this.rows,
    this.truncated = false,
    this.error,
  });

  @override
  String get type => SqlSectionConfig.kType;

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        if (title != null) 'title': title,
        'columns': columns,
        'rows': rows,
        if (truncated) 'truncated': true,
        if (error != null) 'error': error,
      };

  @override
  String toText() {
    final b = StringBuffer();
    if (title != null) b.writeln('## $title');
    if (error != null) {
      b.writeln('Query failed: $error');
      return b.toString().trimRight();
    }
    b.writeln(columns.join(' | '));
    for (final row in rows) {
      b.writeln(row.join(' | '));
    }
    if (truncated) b.writeln('… truncated');
    return b.toString().trimRight();
  }
}

class TextSectionResult extends ReportSectionResult {
  final String text;

  const TextSectionResult({super.title, required this.text});

  @override
  String get type => TextSectionConfig.kType;

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        if (title != null) 'title': title,
        'text': text,
      };

  @override
  String toText() {
    final b = StringBuffer();
    if (title != null) b.writeln('## $title');
    b.writeln(text);
    return b.toString().trimRight();
  }
}

/// A generated report: the definition evaluated over one concrete range.
class ReportResult {
  final String reportId;
  final String reportName;
  final DateTime rangeStart;
  final DateTime rangeEnd;

  /// Human name of the range — a shift label, a date, or a custom span.
  final String rangeLabel;

  final DateTime generatedAt;

  /// True when the range's end lies in the future — the report reads
  /// "current shift so far", and regenerating later gives more.
  final bool partial;

  final List<ReportSectionResult> sections;

  const ReportResult({
    required this.reportId,
    required this.reportName,
    required this.rangeStart,
    required this.rangeEnd,
    required this.rangeLabel,
    required this.generatedAt,
    required this.partial,
    required this.sections,
  });

  Map<String, dynamic> toJson() => {
        'report_id': reportId,
        'report_name': reportName,
        'range_start': rangeStart.toIso8601String(),
        'range_end': rangeEnd.toIso8601String(),
        'range_label': rangeLabel,
        'generated_at': generatedAt.toIso8601String(),
        'partial': partial,
        'sections': sections.map((s) => s.toJson()).toList(),
      };

  String toText() {
    final b = StringBuffer();
    b.writeln('# $reportName — $rangeLabel${partial ? ' (so far)' : ''}');
    b.writeln('Range: ${rangeStart.toIso8601String()} '
        '.. ${rangeEnd.toIso8601String()}, '
        'generated ${generatedAt.toIso8601String()}');
    for (final s in sections) {
      b.writeln();
      b.writeln(s.toText());
    }
    return b.toString().trimRight();
  }
}

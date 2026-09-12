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

/// Formats a duration the way a shift is talked about: `6h 10m`, `0h 18m`,
/// `3d 2h`. Seconds are noise at this scale.
String formatDurationCompact(Duration d) {
  final total = d.inSeconds.abs();
  final days = total ~/ 86400;
  final hours = (total % 86400) ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  if (days > 0) return '${days}d ${hours}h';
  return '${hours}h ${minutes}m';
}

/// What the plant was doing over one stretch of a report's range.
enum ProductionState {
  /// An activity signal says the line is producing.
  running,

  /// Nothing is producing, and nothing says why.
  idle,

  /// Washing — the daily ending, and the thing that is not downtime.
  cleaning,

  /// Not producing, with a stop alarm standing over it. The cause is named.
  fault,

  /// No history here at all: the collector was down. Not the same as idle,
  /// and never counted as if it were.
  noData,
}

extension ProductionStateLabel on ProductionState {
  String get label => switch (this) {
        ProductionState.running => 'Running',
        ProductionState.idle => 'Idle',
        ProductionState.cleaning => 'Washing',
        ProductionState.fault => 'Stops',
        ProductionState.noData => 'No data',
      };
}

/// Why the production window ended where it did.
enum ConclusionReason {
  /// It ran to the end of the planned range.
  shiftEnd,

  /// It stopped and stayed stopped.
  idle,

  /// It stopped and the wash followed.
  cleaning,

  /// The recording stopped; what happened after is unknown.
  noData,

  /// Nothing was produced in this range at all.
  noProduction,

  /// The range is still open and production is not over.
  ongoing,
}

/// One stretch of one state.
class StateSegment {
  final DateTime from;
  final DateTime to;
  final ProductionState state;

  const StateSegment({
    required this.from,
    required this.to,
    required this.state,
  });

  Duration get length => to.difference(from);

  Map<String, dynamic> toJson() => {
        'from': from.toIso8601String(),
        'to': to.toIso8601String(),
        'state': state.name,
      };
}

/// One activity signal's own view of the range — a lane in the state band
/// when a report watches more than one line.
class SignalLane {
  final String label;
  final List<StateSegment> segments;

  const SignalLane({required this.label, required this.segments});

  Map<String, dynamic> toJson() => {
        'label': label,
        'segments': segments.map((s) => s.toJson()).toList(),
      };
}

/// When production actually ran inside a report's planned range.
///
/// A fish plant runs while there is fish. The planned shift is an intention;
/// this is what happened — when the line first produced, when it finished,
/// and what the rest of the range was. Every section scoped to
/// [ReportScope.effective] is computed over `[effectiveStart, effectiveEnd)`,
/// so a shift that ended at 13:42 and washed until 15:00 does not report two
/// hours of zeros as production.
class ProductionWindow {
  /// The planned range, as the calendar gave it.
  final DateTime nominalStart;
  final DateTime nominalEnd;

  /// The last instant there can be data for: the range end, or now for a
  /// range still open.
  final DateTime cap;

  /// First production seen. Null when there was none.
  final DateTime? actualStart;

  /// When production finished for good. Null while it has not.
  final DateTime? concludedAt;

  final ConclusionReason reason;

  /// True when the conclusion is inferred on a range that is still open — the
  /// line has been quiet long enough to call it, but starting again would
  /// undo that, and regenerating then does.
  final bool tentative;

  /// The merged state of the plant over `[nominalStart, cap)`.
  final List<StateSegment> segments;

  /// Per-signal segments, when the report watches more than one.
  final List<SignalLane> lanes;

  final Duration running;
  final Duration idle;
  final Duration cleaning;
  final Duration fault;
  final Duration noData;

  /// Running time over the production window excluding washing — the OEE
  /// availability convention, where a wash is planned downtime. Null when
  /// there is no window to divide by.
  final double? availability;

  /// What the resolution could not do: a signal whose key has no collected
  /// data, say.
  ///
  /// A missing signal makes a busy shift look like an empty one, and the
  /// difference between "the line did not run" and "nobody recorded whether
  /// it ran" is the whole point of separating no-data from idle. So it is
  /// said out loud rather than swallowed.
  final List<String> notes;

  const ProductionWindow({
    required this.nominalStart,
    required this.nominalEnd,
    required this.cap,
    required this.actualStart,
    required this.concludedAt,
    required this.reason,
    required this.tentative,
    required this.segments,
    this.lanes = const [],
    required this.running,
    required this.idle,
    required this.cleaning,
    required this.fault,
    required this.noData,
    required this.availability,
    this.notes = const [],
  });

  DateTime get effectiveStart => actualStart ?? nominalStart;
  DateTime get effectiveEnd => concludedAt ?? cap;
  Duration get effectiveDuration =>
      effectiveEnd.isAfter(effectiveStart)
          ? effectiveEnd.difference(effectiveStart)
          : Duration.zero;
  Duration get nominalDuration => nominalEnd.difference(nominalStart);

  /// Nothing was produced in this range.
  bool get isEmpty => reason == ConclusionReason.noProduction;

  /// Whether production finished before the planned end.
  bool get endedEarly =>
      concludedAt != null && concludedAt!.isBefore(nominalEnd);

  /// The production window as a range, for scoping a section.
  TimeRange get effectiveRange => TimeRange(effectiveStart, effectiveEnd);

  /// The stretches the line was actually running.
  List<TimeRange> get runningRanges => [
        for (final s in segments)
          if (s.state == ProductionState.running) TimeRange(s.from, s.to),
      ];

  Map<String, dynamic> toJson() => {
        'nominal_start': nominalStart.toIso8601String(),
        'nominal_end': nominalEnd.toIso8601String(),
        'cap': cap.toIso8601String(),
        if (actualStart != null) 'actual_start': actualStart!.toIso8601String(),
        if (concludedAt != null) 'concluded_at': concludedAt!.toIso8601String(),
        'reason': reason.name,
        'tentative': tentative,
        'running_seconds': running.inMilliseconds / 1000,
        'idle_seconds': idle.inMilliseconds / 1000,
        'cleaning_seconds': cleaning.inMilliseconds / 1000,
        'fault_seconds': fault.inMilliseconds / 1000,
        'no_data_seconds': noData.inMilliseconds / 1000,
        if (availability != null) 'availability': availability,
        if (notes.isNotEmpty) 'notes': notes,
        'segments': segments.map((s) => s.toJson()).toList(),
        if (lanes.isNotEmpty)
          'lanes': lanes.map((l) => l.toJson()).toList(),
      };

  /// The sentence a person would say about the shift.
  String toText() {
    String hm(DateTime t) =>
        '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
    final b = StringBuffer();
    if (isEmpty) {
      b.write('No production in this range');
      if (tentative) b.write(' yet');
      b.write('.');
      for (final n in notes) {
        b.write(' $n');
      }
      return b.toString();
    }
    b.write('Production ${hm(effectiveStart)}–');
    b.write(concludedAt == null ? 'now' : hm(effectiveEnd));
    b.write(' (${formatDurationCompact(effectiveDuration)} of '
        '${formatDurationCompact(nominalDuration)} planned)');
    b.write(switch (reason) {
      ConclusionReason.shiftEnd => ', ran to the end of the range',
      ConclusionReason.idle => tentative
          ? ', possibly finished — idle since ${hm(concludedAt!)}'
          : ', finished early and stayed stopped',
      ConclusionReason.cleaning => ', finished early and washed',
      ConclusionReason.noData => ', no data recorded after ${hm(cap)}',
      ConclusionReason.ongoing => ', still running',
      ConclusionReason.noProduction => '',
    });
    b.write('. Running ${formatDurationCompact(running)}, '
        'stops ${formatDurationCompact(fault)}, '
        'idle ${formatDurationCompact(idle)}, '
        'washing ${formatDurationCompact(cleaning)}');
    if (noData > Duration.zero) {
      b.write(', no data ${formatDurationCompact(noData)}');
    }
    b.write('.');
    if (availability != null) {
      b.write(' Availability ${(availability! * 100).toStringAsFixed(1)}%.');
    }
    for (final n in notes) {
      b.write(' $n');
    }
    return b.toString();
  }
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

/// A section whose figures cover a span of time, and so carry the scope they
/// were computed over — what the reader needs to know before trusting a
/// number that says "981 boxes/h".
sealed class ScopedSectionResult extends ReportSectionResult {
  final ReportScope scope;

  const ScopedSectionResult({
    super.title,
    this.scope = ReportScope.effective,
  });
}

class KpiSectionResult extends ScopedSectionResult {
  final List<MetricResult> metrics;

  const KpiSectionResult({super.title, super.scope, required this.metrics});

  @override
  String get type => KpiSectionConfig.kType;

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        if (title != null) 'title': title,
        'scope': scope.name,
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

class TableSectionResult extends ScopedSectionResult {
  final List<ReportAggregate> aggregates;
  final List<TableRowResult> rows;

  const TableSectionResult({
    super.title,
    super.scope,
    required this.aggregates,
    required this.rows,
  });

  @override
  String get type => TableSectionConfig.kType;

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        if (title != null) 'title': title,
        'scope': scope.name,
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

class ChartSectionResult extends ScopedSectionResult {
  final List<ChartSeriesResult> series;

  const ChartSectionResult({super.title, super.scope, required this.series});

  @override
  String get type => ChartSectionConfig.kType;

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        if (title != null) 'title': title,
        'scope': scope.name,
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

class AlarmSummarySectionResult extends ScopedSectionResult {
  final int totalActivations;
  final int distinctAlarms;
  final int openNow;
  final double perHour;
  final List<AlarmStat> topByCount;
  final List<AlarmStat> topByDuration;

  /// Activations that started after production concluded. Zero when the shift
  /// ran to its end, or when no window was resolved.
  final int afterConclusion;

  const AlarmSummarySectionResult({
    super.title,
    super.scope,
    required this.totalActivations,
    required this.distinctAlarms,
    required this.openNow,
    required this.perHour,
    required this.topByCount,
    required this.topByDuration,
    this.afterConclusion = 0,
  });

  @override
  String get type => AlarmSummarySectionConfig.kType;

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        if (title != null) 'title': title,
        'scope': scope.name,
        if (afterConclusion > 0) 'after_conclusion': afterConclusion,
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

class DowntimeSectionResult extends ScopedSectionResult {
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
    super.scope,
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
        'scope': scope.name,
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
class SqlSectionResult extends ScopedSectionResult {
  final List<String> columns;
  final List<List<String>> rows;

  /// True when the query returned more rows than the section's cap.
  final bool truncated;

  final String? error;

  const SqlSectionResult({
    super.title,
    super.scope,
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

  /// When production actually ran. Null when the definition declares no
  /// activity signals — the report is then a plain range report.
  final ProductionWindow? window;

  const ReportResult({
    required this.reportId,
    required this.reportName,
    required this.rangeStart,
    required this.rangeEnd,
    required this.rangeLabel,
    required this.generatedAt,
    required this.partial,
    required this.sections,
    this.window,
  });

  Map<String, dynamic> toJson() => {
        'report_id': reportId,
        'report_name': reportName,
        'range_start': rangeStart.toIso8601String(),
        'range_end': rangeEnd.toIso8601String(),
        'range_label': rangeLabel,
        'generated_at': generatedAt.toIso8601String(),
        'partial': partial,
        if (window != null) 'window': window!.toJson(),
        'sections': sections.map((s) => s.toJson()).toList(),
      };

  String toText() {
    final b = StringBuffer();
    b.writeln('# $reportName — $rangeLabel${partial ? ' (so far)' : ''}');
    b.writeln('Range: ${rangeStart.toIso8601String()} '
        '.. ${rangeEnd.toIso8601String()}, '
        'generated ${generatedAt.toIso8601String()}');
    // The window goes first: what the numbers below cover is the first thing
    // a reader — person or model — has to know.
    if (window != null) b.writeln(window!.toText());
    for (final s in sections) {
      b.writeln();
      b.writeln(s.toText());
    }
    return b.toString().trimRight();
  }
}

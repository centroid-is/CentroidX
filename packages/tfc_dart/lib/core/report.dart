import 'package:json_annotation/json_annotation.dart';

part 'report.g.dart';

/// How one metric is condensed over the report's time range.
///
/// The set follows the OPC UA Part 13 table stakes: [timeWeightedMean] rather
/// than a plain sample mean for irregularly sampled analogs, [delta] for
/// counters (rollover- and reset-aware), and the duration-in-state pair for
/// run-time and state breakdowns.
enum ReportAggregate {
  /// Value standing at the range start (last sample at or before it).
  first,

  /// Value standing at the range end.
  last,
  min,
  max,

  /// Plain average of the samples in range.
  mean,

  /// Average weighted by how long each value stood. The right mean for
  /// change-based or irregularly sampled values.
  @JsonValue('time_weighted_mean')
  timeWeightedMean,

  /// Counter increase over the range. A drop is treated as a reset or
  /// rollover — the new value counts from zero — so it never goes negative.
  delta,

  /// Number of samples in range.
  count,

  /// Seconds the value was truthy (non-zero) in range.
  @JsonValue('duration_true')
  durationTrue,

  /// Seconds the value was falsy (zero) in range.
  @JsonValue('duration_false')
  durationFalse,
}

extension ReportAggregateLabel on ReportAggregate {
  String get label => switch (this) {
        ReportAggregate.first => 'First',
        ReportAggregate.last => 'Last',
        ReportAggregate.min => 'Min',
        ReportAggregate.max => 'Max',
        ReportAggregate.mean => 'Mean',
        ReportAggregate.timeWeightedMean => 'Avg (time-weighted)',
        ReportAggregate.delta => 'Total (Δ)',
        ReportAggregate.count => 'Samples',
        ReportAggregate.durationTrue => 'Time on',
        ReportAggregate.durationFalse => 'Time off',
      };

  /// Column-header form: the same aggregate in as few characters as a table
  /// column can spare. [label] stays the long form the editor's chips use.
  String get shortLabel => switch (this) {
        ReportAggregate.first => 'FIRST',
        ReportAggregate.last => 'LAST',
        ReportAggregate.min => 'MIN',
        ReportAggregate.max => 'MAX',
        ReportAggregate.mean => 'MEAN',
        ReportAggregate.timeWeightedMean => 'AVG',
        ReportAggregate.delta => 'TOTAL',
        ReportAggregate.count => 'SAMPLES',
        ReportAggregate.durationTrue => 'TIME ON',
        ReportAggregate.durationFalse => 'TIME OFF',
      };

  /// Whether the result is a number of seconds and should render as h:mm:ss.
  bool get isDuration =>
      this == ReportAggregate.durationTrue ||
      this == ReportAggregate.durationFalse;
}

/// How a multi-key metric folds its per-key aggregates into one number.
enum MetricCombine { sum, mean, min, max }

/// One value a report computes: a collected key (optionally one struct
/// member of it) condensed by one aggregate.
@JsonSerializable(explicitToJson: true)
class ReportMetricConfig {
  /// The collected key — which is also the timeseries table name once
  /// resolved through StateMan's `$variable` substitution.
  String key;

  /// Further keys aggregated the same way and folded in with [combine] —
  /// the "plant total is the three SpeedBatchers summed" case. [member]
  /// applies to every key, which fits identical machines sharing a struct
  /// layout.
  @JsonKey(name: 'additional_keys', defaultValue: <String>[])
  List<String> additionalKeys;

  /// How the per-key results merge when [additionalKeys] is non-empty.
  MetricCombine combine;

  /// Dotted member path into a `sample_members` table, or null for the
  /// scalar `value` column.
  String? member;

  /// Display label. Falls back to the key when empty.
  String? label;

  ReportAggregate aggregate;

  String? unit;

  /// Decimal places when rendering the number.
  int decimals;

  ReportMetricConfig({
    required this.key,
    List<String>? additionalKeys,
    this.combine = MetricCombine.sum,
    this.member,
    this.label,
    this.aggregate = ReportAggregate.timeWeightedMean,
    this.unit,
    this.decimals = 1,
  }) : additionalKeys = additionalKeys ?? [];

  String get displayLabel =>
      (label == null || label!.isEmpty) ? key : label!;

  factory ReportMetricConfig.fromJson(Map<String, dynamic> json) =>
      _$ReportMetricConfigFromJson(json);
  Map<String, dynamic> toJson() => _$ReportMetricConfigToJson(this);
}

/// One typed section of a report. The report is a flat ordered list of these
/// — a declarative section list rather than a banded canvas, deliberately:
/// it is what a form-based editor can edit and what an LLM can generate and
/// amend reliably.
sealed class ReportSectionConfig {
  String? title;

  ReportSectionConfig({this.title});

  String get type;

  Map<String, dynamic> toJson();

  static ReportSectionConfig fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    return switch (type) {
      KpiSectionConfig.kType => KpiSectionConfig.fromJson(json),
      TableSectionConfig.kType => TableSectionConfig.fromJson(json),
      ChartSectionConfig.kType => ChartSectionConfig.fromJson(json),
      AlarmSummarySectionConfig.kType =>
        AlarmSummarySectionConfig.fromJson(json),
      DowntimeSectionConfig.kType => DowntimeSectionConfig.fromJson(json),
      SqlSectionConfig.kType => SqlSectionConfig.fromJson(json),
      TextSectionConfig.kType => TextSectionConfig.fromJson(json),
      _ => throw ArgumentError('Unknown report section type: $type'),
    };
  }
}

/// Which span of the report's range a section aggregates over.
///
/// A fish plant runs while there is fish, not while the clock says shift: a
/// shift routinely starts late, ends early, and finishes in a wash. Averaging
/// a rate over the planned eight hours when the line ran for six states
/// something that did not happen, so [effective] — the production window — is
/// the default and the other two are the deliberate exceptions.
enum ReportScope {
  /// The production window: first production to conclusion. The default.
  effective,

  /// The whole planned range, conclusion ignored.
  nominal,

  /// Only the segments the line was actually running — pauses excluded.
  running,
}

extension ReportScopeLabel on ReportScope {
  /// Caption a section carries so the reader knows what the figures cover.
  String get caption => switch (this) {
        ReportScope.effective => 'over the production window',
        ReportScope.nominal => 'whole shift',
        ReportScope.running => 'while running',
      };

  String get label => switch (this) {
        ReportScope.effective => 'Production window',
        ReportScope.nominal => 'Whole shift',
        ReportScope.running => 'While running',
      };
}

/// A section whose figures cover a span of time, and so can be scoped to the
/// production window. Text is the one section that cannot.
sealed class ScopedSectionConfig extends ReportSectionConfig {
  /// Which span this section aggregates over. Ignored when the report has no
  /// [ProductionWindowConfig] — there is then only one span.
  ReportScope scope;

  ScopedSectionConfig({super.title, ReportScope? scope})
      : scope = scope ?? ReportScope.effective;
}

/// One predicate over a collected key: truthy (neither bound set), above a
/// threshold, or equal to a value.
///
/// Equality is what reads an enum column — a drive's `p_stat_RunMode` is
/// collected as an integer, so `member: p_stat_RunMode, equals: 4` is "this
/// motor is in cleaning mode".
@JsonSerializable(explicitToJson: true)
class ActivityRule {
  /// The collected key, as the timeseries table is named.
  String key;

  /// Struct member column, or null for the scalar `value` column.
  String? member;

  /// Matches when the value is strictly greater than this.
  double? above;

  /// Matches when the value equals this. Takes precedence over [above].
  @JsonKey(name: 'equals')
  double? equalsValue;

  ActivityRule({
    required this.key,
    this.member,
    this.above,
    this.equalsValue,
  });

  /// Whether [v] satisfies this rule. With neither bound set, any non-zero
  /// value matches — which is what a collected boolean means.
  bool test(double v) {
    final eq = equalsValue;
    if (eq != null) return v == eq;
    final gt = above;
    if (gt != null) return v > gt;
    return v != 0;
  }

  factory ActivityRule.fromJson(Map<String, dynamic> json) =>
      _$ActivityRuleFromJson(json);
  Map<String, dynamic> toJson() => _$ActivityRuleToJson(this);
}

/// One thing whose activity says whether the plant is producing — a line, a
/// machine. A report may watch several; the plant is producing while any of
/// them is.
@JsonSerializable(explicitToJson: true)
class ActivitySignalConfig {
  /// Display name for this signal's lane in the state band.
  String? label;

  /// When this matches, the signal is producing.
  ActivityRule running;

  /// When this matches (and [running] does not), the signal is washing.
  /// Null when nothing recorded says "washing" for this signal.
  ActivityRule? cleaning;

  /// How long a silence in an interval-sampled key means "the collector was
  /// down", rather than "the value simply did not change".
  ///
  /// Null — the default — is the honest setting for a change-based key, where
  /// hours between samples are normal and the last value genuinely still
  /// stands. Set it only for a key sampled on an interval; the conclusion
  /// algorithm then reports no-data rather than inventing idle time.
  @JsonKey(name: 'max_gap_minutes')
  int? maxGapMinutes;

  ActivitySignalConfig({
    this.label,
    required this.running,
    this.cleaning,
    this.maxGapMinutes,
  });

  Duration? get maxGap =>
      maxGapMinutes == null ? null : Duration(minutes: maxGapMinutes!);

  factory ActivitySignalConfig.fromJson(Map<String, dynamic> json) =>
      _$ActivitySignalConfigFromJson(json);
  Map<String, dynamic> toJson() => _$ActivitySignalConfigToJson(this);
}

/// How a report decides when production actually started and concluded.
///
/// Deterministic on purpose: the same range over the same recorded history
/// always yields the same window, so two people reading the same shift report
/// read the same shift.
@JsonSerializable(explicitToJson: true)
class ProductionWindowConfig {
  List<ActivitySignalConfig> signals;

  /// A non-running tail at least this long, reaching the end of the range,
  /// concludes the shift.
  @JsonKey(name: 'idle_minutes')
  int idleMinutes;

  /// Washing in that tail this long concludes the shift even when the tail is
  /// shorter than [idleMinutes] — a wash is an ending, not a pause.
  @JsonKey(name: 'cleaning_minutes')
  int cleaningMinutes;

  ProductionWindowConfig({
    List<ActivitySignalConfig>? signals,
    this.idleMinutes = 30,
    this.cleaningMinutes = 10,
  }) : signals = signals ?? [];

  Duration get idleThreshold => Duration(minutes: idleMinutes);
  Duration get cleaningThreshold => Duration(minutes: cleaningMinutes);

  factory ProductionWindowConfig.fromJson(Map<String, dynamic> json) =>
      _$ProductionWindowConfigFromJson(json);
  Map<String, dynamic> toJson() => _$ProductionWindowConfigToJson(this);
}

/// A row of headline figures.
@JsonSerializable(explicitToJson: true)
class KpiSectionConfig extends ScopedSectionConfig {
  static const kType = 'kpi';

  List<ReportMetricConfig> metrics;

  KpiSectionConfig({
    super.title,
    super.scope,
    List<ReportMetricConfig>? metrics,
  }) : metrics = metrics ?? [];

  @override
  String get type => kType;

  factory KpiSectionConfig.fromJson(Map<String, dynamic> json) =>
      _$KpiSectionConfigFromJson(json);
  @override
  Map<String, dynamic> toJson() =>
      _$KpiSectionConfigToJson(this)..['type'] = kType;
}

/// One row of an aggregate table: a key/member with its own label and unit,
/// aggregated by every column the section declares.
@JsonSerializable(explicitToJson: true)
class TableRowConfig {
  String key;
  String? member;
  String? label;
  String? unit;
  int decimals;

  TableRowConfig({
    required this.key,
    this.member,
    this.label,
    this.unit,
    this.decimals = 1,
  });

  String get displayLabel =>
      (label == null || label!.isEmpty) ? key : label!;

  factory TableRowConfig.fromJson(Map<String, dynamic> json) =>
      _$TableRowConfigFromJson(json);
  Map<String, dynamic> toJson() => _$TableRowConfigToJson(this);
}

/// A metrics-by-aggregates table: one row per key, one column per aggregate —
/// the Ignition tag-calculation shape.
@JsonSerializable(explicitToJson: true)
class TableSectionConfig extends ScopedSectionConfig {
  static const kType = 'table';

  List<TableRowConfig> rows;
  List<ReportAggregate> aggregates;

  TableSectionConfig({
    super.title,
    super.scope,
    List<TableRowConfig>? rows,
    List<ReportAggregate>? aggregates,
  })  : rows = rows ?? [],
        aggregates = aggregates ??
            [ReportAggregate.timeWeightedMean, ReportAggregate.min, ReportAggregate.max];

  @override
  String get type => kType;

  factory TableSectionConfig.fromJson(Map<String, dynamic> json) =>
      _$TableSectionConfigFromJson(json);
  @override
  Map<String, dynamic> toJson() =>
      _$TableSectionConfigToJson(this)..['type'] = kType;
}

/// One line on a report chart.
@JsonSerializable(explicitToJson: true)
class ReportChartSeriesConfig {
  String key;
  String? member;
  String? label;

  ReportChartSeriesConfig({required this.key, this.member, this.label});

  String get displayLabel =>
      (label == null || label!.isEmpty) ? key : label!;

  factory ReportChartSeriesConfig.fromJson(Map<String, dynamic> json) =>
      _$ReportChartSeriesConfigFromJson(json);
  Map<String, dynamic> toJson() => _$ReportChartSeriesConfigToJson(this);
}

/// A time-bucketed min/avg/max chart over the range.
@JsonSerializable(explicitToJson: true)
class ChartSectionConfig extends ScopedSectionConfig {
  static const kType = 'chart';

  List<ReportChartSeriesConfig> series;

  /// Buckets across the range. Keep it modest — a report chart is a shape,
  /// not a zoomable trend; the history view exists for that.
  @JsonKey(name: 'max_points')
  int maxPoints;

  ChartSectionConfig({
    super.title,
    super.scope,
    List<ReportChartSeriesConfig>? series,
    this.maxPoints = 120,
  }) : series = series ?? [];

  @override
  String get type => kType;

  factory ChartSectionConfig.fromJson(Map<String, dynamic> json) =>
      _$ChartSectionConfigFromJson(json);
  @override
  Map<String, dynamic> toJson() =>
      _$ChartSectionConfigToJson(this)..['type'] = kType;
}

/// ISA-18.2-style alarm load summary: totals, rate, and the top offenders by
/// count and by standing time.
@JsonSerializable(explicitToJson: true)
class AlarmSummarySectionConfig extends ScopedSectionConfig {
  static const kType = 'alarm_summary';

  @JsonKey(name: 'top_n')
  int topN;

  /// Alarms default to the whole shift: a stop after the line finished is not
  /// downtime, but an alarm after it finished is still an alarm somebody has
  /// to know about.
  AlarmSummarySectionConfig({
    super.title,
    ReportScope? scope,
    this.topN = 10,
  }) : super(scope: scope ?? ReportScope.nominal);

  @override
  String get type => kType;

  factory AlarmSummarySectionConfig.fromJson(Map<String, dynamic> json) =>
      _$AlarmSummarySectionConfigFromJson(json);
  @override
  Map<String, dynamic> toJson() =>
      _$AlarmSummarySectionConfigToJson(this)..['type'] = kType;
}

/// Downtime pareto over the alarms whose definitions count as stops.
@JsonSerializable(explicitToJson: true)
class DowntimeSectionConfig extends ScopedSectionConfig {
  static const kType = 'downtime';

  @JsonKey(name: 'top_n')
  int topN;

  DowntimeSectionConfig({super.title, super.scope, this.topN = 10});

  @override
  String get type => kType;

  factory DowntimeSectionConfig.fromJson(Map<String, dynamic> json) =>
      _$DowntimeSectionConfigFromJson(json);
  @override
  Map<String, dynamic> toJson() =>
      _$DowntimeSectionConfigToJson(this)..['type'] = kType;
}

/// An arbitrary read-only SQL query rendered as a table — the escape hatch
/// every SCADA reporting product grows (Ignition's SQL data source): joins
/// across key tables, `alarm_history` breakdowns the fixed sections don't
/// cover, anything a SELECT can say.
///
/// The tokens `:from` and `:to` are bound to the report range as ISO-8601
/// UTC text; against a timestamptz column write `:from::timestamptz`. Only a
/// single SELECT/WITH statement is accepted — the engine rejects anything
/// else before it reaches the database.
@JsonSerializable(explicitToJson: true)
class SqlSectionConfig extends ScopedSectionConfig {
  static const kType = 'sql';

  String query;

  /// Rows past this are dropped and the result marked truncated.
  @JsonKey(name: 'max_rows')
  int maxRows;

  SqlSectionConfig({
    super.title,
    super.scope,
    this.query = '',
    this.maxRows = 200,
  });

  @override
  String get type => kType;

  factory SqlSectionConfig.fromJson(Map<String, dynamic> json) =>
      _$SqlSectionConfigFromJson(json);
  @override
  Map<String, dynamic> toJson() =>
      _$SqlSectionConfigToJson(this)..['type'] = kType;
}

/// Free text. Also the slot where LLM-written shift commentary lands later —
/// the section type exists so a generated paragraph has somewhere to live.
@JsonSerializable(explicitToJson: true)
class TextSectionConfig extends ReportSectionConfig {
  static const kType = 'text';

  String text;

  TextSectionConfig({super.title, this.text = ''});

  @override
  String get type => kType;

  factory TextSectionConfig.fromJson(Map<String, dynamic> json) =>
      _$TextSectionConfigFromJson(json);
  @override
  Map<String, dynamic> toJson() =>
      _$TextSectionConfigToJson(this)..['type'] = kType;
}

/// What span of time a report is generated over by default. The viewer and
/// the MCP tools then move the window with an offset: 0 is the current
/// period, -1 the one before, and so on.
enum ReportRangeKind {
  /// One shift from the shift calendar.
  shift,

  /// One calendar day, midnight to midnight.
  day,

  /// One calendar week, Monday to Monday.
  week,
}

/// One report definition.
@JsonSerializable(explicitToJson: true)
class ReportConfig {
  String id;
  String name;
  String? description;

  /// The period this report is naturally about. Shift reports resolve
  /// through the shift calendar; day/week are plain calendar arithmetic.
  ReportRangeKind range;

  @JsonKey(fromJson: _sectionsFromJson, toJson: _sectionsToJson)
  List<ReportSectionConfig> sections;

  /// How this report works out when production actually ran. Null leaves the
  /// report as a plain range report: every section covers the whole range and
  /// no window is resolved — which is what every definition saved before this
  /// existed deserialises to.
  ProductionWindowConfig? window;

  ReportConfig({
    required this.id,
    required this.name,
    this.description,
    this.range = ReportRangeKind.shift,
    List<ReportSectionConfig>? sections,
    this.window,
  }) : sections = sections ?? [];

  static List<ReportSectionConfig> _sectionsFromJson(List<dynamic> json) =>
      json
          .map((e) =>
              ReportSectionConfig.fromJson(e as Map<String, dynamic>))
          .toList();

  static List<Map<String, dynamic>> _sectionsToJson(
          List<ReportSectionConfig> sections) =>
      sections.map((s) => s.toJson()).toList();

  factory ReportConfig.fromJson(Map<String, dynamic> json) =>
      _$ReportConfigFromJson(json);
  Map<String, dynamic> toJson() => _$ReportConfigToJson(this);
}

/// Every report definition in the system, stored as one JSON blob in the
/// shared preferences table — same pattern as the alarm definitions.
@JsonSerializable(explicitToJson: true)
class ReportManConfig {
  static const String configKey = 'report_config';

  List<ReportConfig> reports;

  ReportManConfig({List<ReportConfig>? reports}) : reports = reports ?? [];

  factory ReportManConfig.fromJson(Map<String, dynamic> json) =>
      _$ReportManConfigFromJson(json);
  Map<String, dynamic> toJson() => _$ReportManConfigToJson(this);
}

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

  /// Whether the result is a number of seconds and should render as h:mm:ss.
  bool get isDuration =>
      this == ReportAggregate.durationTrue ||
      this == ReportAggregate.durationFalse;
}

/// One value a report computes: a collected key (optionally one struct
/// member of it) condensed by one aggregate.
@JsonSerializable(explicitToJson: true)
class ReportMetricConfig {
  /// The collected key — which is also the timeseries table name once
  /// resolved through StateMan's `$variable` substitution.
  String key;

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
    this.member,
    this.label,
    this.aggregate = ReportAggregate.timeWeightedMean,
    this.unit,
    this.decimals = 1,
  });

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
      TextSectionConfig.kType => TextSectionConfig.fromJson(json),
      _ => throw ArgumentError('Unknown report section type: $type'),
    };
  }
}

/// A row of headline figures.
@JsonSerializable(explicitToJson: true)
class KpiSectionConfig extends ReportSectionConfig {
  static const kType = 'kpi';

  List<ReportMetricConfig> metrics;

  KpiSectionConfig({super.title, List<ReportMetricConfig>? metrics})
      : metrics = metrics ?? [];

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
class TableSectionConfig extends ReportSectionConfig {
  static const kType = 'table';

  List<TableRowConfig> rows;
  List<ReportAggregate> aggregates;

  TableSectionConfig({
    super.title,
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
class ChartSectionConfig extends ReportSectionConfig {
  static const kType = 'chart';

  List<ReportChartSeriesConfig> series;

  /// Buckets across the range. Keep it modest — a report chart is a shape,
  /// not a zoomable trend; the history view exists for that.
  @JsonKey(name: 'max_points')
  int maxPoints;

  ChartSectionConfig({
    super.title,
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
class AlarmSummarySectionConfig extends ReportSectionConfig {
  static const kType = 'alarm_summary';

  @JsonKey(name: 'top_n')
  int topN;

  AlarmSummarySectionConfig({super.title, this.topN = 10});

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
class DowntimeSectionConfig extends ReportSectionConfig {
  static const kType = 'downtime';

  @JsonKey(name: 'top_n')
  int topN;

  DowntimeSectionConfig({super.title, this.topN = 10});

  @override
  String get type => kType;

  factory DowntimeSectionConfig.fromJson(Map<String, dynamic> json) =>
      _$DowntimeSectionConfigFromJson(json);
  @override
  Map<String, dynamic> toJson() =>
      _$DowntimeSectionConfigToJson(this)..['type'] = kType;
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

  ReportConfig({
    required this.id,
    required this.name,
    this.description,
    this.range = ReportRangeKind.shift,
    List<ReportSectionConfig>? sections,
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

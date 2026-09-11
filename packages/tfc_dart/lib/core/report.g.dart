// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'report.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ReportMetricConfig _$ReportMetricConfigFromJson(Map<String, dynamic> json) =>
    ReportMetricConfig(
      key: json['key'] as String,
      additionalKeys: (json['additional_keys'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      combine: $enumDecodeNullable(_$MetricCombineEnumMap, json['combine']) ??
          MetricCombine.sum,
      member: json['member'] as String?,
      label: json['label'] as String?,
      aggregate:
          $enumDecodeNullable(_$ReportAggregateEnumMap, json['aggregate']) ??
              ReportAggregate.timeWeightedMean,
      unit: json['unit'] as String?,
      decimals: (json['decimals'] as num?)?.toInt() ?? 1,
    );

Map<String, dynamic> _$ReportMetricConfigToJson(ReportMetricConfig instance) =>
    <String, dynamic>{
      'key': instance.key,
      'additional_keys': instance.additionalKeys,
      'combine': _$MetricCombineEnumMap[instance.combine]!,
      'member': instance.member,
      'label': instance.label,
      'aggregate': _$ReportAggregateEnumMap[instance.aggregate]!,
      'unit': instance.unit,
      'decimals': instance.decimals,
    };

const _$MetricCombineEnumMap = {
  MetricCombine.sum: 'sum',
  MetricCombine.mean: 'mean',
  MetricCombine.min: 'min',
  MetricCombine.max: 'max',
};

const _$ReportAggregateEnumMap = {
  ReportAggregate.first: 'first',
  ReportAggregate.last: 'last',
  ReportAggregate.min: 'min',
  ReportAggregate.max: 'max',
  ReportAggregate.mean: 'mean',
  ReportAggregate.timeWeightedMean: 'time_weighted_mean',
  ReportAggregate.delta: 'delta',
  ReportAggregate.count: 'count',
  ReportAggregate.durationTrue: 'duration_true',
  ReportAggregate.durationFalse: 'duration_false',
};

ActivityRule _$ActivityRuleFromJson(Map<String, dynamic> json) => ActivityRule(
      key: json['key'] as String,
      member: json['member'] as String?,
      above: (json['above'] as num?)?.toDouble(),
      equalsValue: (json['equals'] as num?)?.toDouble(),
    );

Map<String, dynamic> _$ActivityRuleToJson(ActivityRule instance) =>
    <String, dynamic>{
      'key': instance.key,
      'member': instance.member,
      'above': instance.above,
      'equals': instance.equalsValue,
    };

ActivitySignalConfig _$ActivitySignalConfigFromJson(
        Map<String, dynamic> json) =>
    ActivitySignalConfig(
      label: json['label'] as String?,
      running: ActivityRule.fromJson(json['running'] as Map<String, dynamic>),
      cleaning: json['cleaning'] == null
          ? null
          : ActivityRule.fromJson(json['cleaning'] as Map<String, dynamic>),
      maxGapMinutes: (json['max_gap_minutes'] as num?)?.toInt(),
    );

Map<String, dynamic> _$ActivitySignalConfigToJson(
        ActivitySignalConfig instance) =>
    <String, dynamic>{
      'label': instance.label,
      'running': instance.running.toJson(),
      'cleaning': instance.cleaning?.toJson(),
      'max_gap_minutes': instance.maxGapMinutes,
    };

ProductionWindowConfig _$ProductionWindowConfigFromJson(
        Map<String, dynamic> json) =>
    ProductionWindowConfig(
      signals: (json['signals'] as List<dynamic>?)
          ?.map((e) => ActivitySignalConfig.fromJson(e as Map<String, dynamic>))
          .toList(),
      idleMinutes: (json['idle_minutes'] as num?)?.toInt() ?? 30,
      cleaningMinutes: (json['cleaning_minutes'] as num?)?.toInt() ?? 10,
    );

Map<String, dynamic> _$ProductionWindowConfigToJson(
        ProductionWindowConfig instance) =>
    <String, dynamic>{
      'signals': instance.signals.map((e) => e.toJson()).toList(),
      'idle_minutes': instance.idleMinutes,
      'cleaning_minutes': instance.cleaningMinutes,
    };

KpiSectionConfig _$KpiSectionConfigFromJson(Map<String, dynamic> json) =>
    KpiSectionConfig(
      title: json['title'] as String?,
      scope: $enumDecodeNullable(_$ReportScopeEnumMap, json['scope']),
      metrics: (json['metrics'] as List<dynamic>?)
          ?.map((e) => ReportMetricConfig.fromJson(e as Map<String, dynamic>))
          .toList(),
    );

Map<String, dynamic> _$KpiSectionConfigToJson(KpiSectionConfig instance) =>
    <String, dynamic>{
      'title': instance.title,
      'scope': _$ReportScopeEnumMap[instance.scope]!,
      'metrics': instance.metrics.map((e) => e.toJson()).toList(),
    };

const _$ReportScopeEnumMap = {
  ReportScope.effective: 'effective',
  ReportScope.nominal: 'nominal',
  ReportScope.running: 'running',
};

TableRowConfig _$TableRowConfigFromJson(Map<String, dynamic> json) =>
    TableRowConfig(
      key: json['key'] as String,
      member: json['member'] as String?,
      label: json['label'] as String?,
      unit: json['unit'] as String?,
      decimals: (json['decimals'] as num?)?.toInt() ?? 1,
    );

Map<String, dynamic> _$TableRowConfigToJson(TableRowConfig instance) =>
    <String, dynamic>{
      'key': instance.key,
      'member': instance.member,
      'label': instance.label,
      'unit': instance.unit,
      'decimals': instance.decimals,
    };

TableSectionConfig _$TableSectionConfigFromJson(Map<String, dynamic> json) =>
    TableSectionConfig(
      title: json['title'] as String?,
      scope: $enumDecodeNullable(_$ReportScopeEnumMap, json['scope']),
      rows: (json['rows'] as List<dynamic>?)
          ?.map((e) => TableRowConfig.fromJson(e as Map<String, dynamic>))
          .toList(),
      aggregates: (json['aggregates'] as List<dynamic>?)
          ?.map((e) => $enumDecode(_$ReportAggregateEnumMap, e))
          .toList(),
    );

Map<String, dynamic> _$TableSectionConfigToJson(TableSectionConfig instance) =>
    <String, dynamic>{
      'title': instance.title,
      'scope': _$ReportScopeEnumMap[instance.scope]!,
      'rows': instance.rows.map((e) => e.toJson()).toList(),
      'aggregates':
          instance.aggregates.map((e) => _$ReportAggregateEnumMap[e]!).toList(),
    };

ReportChartSeriesConfig _$ReportChartSeriesConfigFromJson(
        Map<String, dynamic> json) =>
    ReportChartSeriesConfig(
      key: json['key'] as String,
      member: json['member'] as String?,
      label: json['label'] as String?,
    );

Map<String, dynamic> _$ReportChartSeriesConfigToJson(
        ReportChartSeriesConfig instance) =>
    <String, dynamic>{
      'key': instance.key,
      'member': instance.member,
      'label': instance.label,
    };

ChartSectionConfig _$ChartSectionConfigFromJson(Map<String, dynamic> json) =>
    ChartSectionConfig(
      title: json['title'] as String?,
      scope: $enumDecodeNullable(_$ReportScopeEnumMap, json['scope']),
      series: (json['series'] as List<dynamic>?)
          ?.map((e) =>
              ReportChartSeriesConfig.fromJson(e as Map<String, dynamic>))
          .toList(),
      maxPoints: (json['max_points'] as num?)?.toInt() ?? 120,
    );

Map<String, dynamic> _$ChartSectionConfigToJson(ChartSectionConfig instance) =>
    <String, dynamic>{
      'title': instance.title,
      'scope': _$ReportScopeEnumMap[instance.scope]!,
      'series': instance.series.map((e) => e.toJson()).toList(),
      'max_points': instance.maxPoints,
    };

AlarmSummarySectionConfig _$AlarmSummarySectionConfigFromJson(
        Map<String, dynamic> json) =>
    AlarmSummarySectionConfig(
      title: json['title'] as String?,
      scope: $enumDecodeNullable(_$ReportScopeEnumMap, json['scope']),
      topN: (json['top_n'] as num?)?.toInt() ?? 10,
    );

Map<String, dynamic> _$AlarmSummarySectionConfigToJson(
        AlarmSummarySectionConfig instance) =>
    <String, dynamic>{
      'title': instance.title,
      'scope': _$ReportScopeEnumMap[instance.scope]!,
      'top_n': instance.topN,
    };

DowntimeSectionConfig _$DowntimeSectionConfigFromJson(
        Map<String, dynamic> json) =>
    DowntimeSectionConfig(
      title: json['title'] as String?,
      scope: $enumDecodeNullable(_$ReportScopeEnumMap, json['scope']),
      topN: (json['top_n'] as num?)?.toInt() ?? 10,
    );

Map<String, dynamic> _$DowntimeSectionConfigToJson(
        DowntimeSectionConfig instance) =>
    <String, dynamic>{
      'title': instance.title,
      'scope': _$ReportScopeEnumMap[instance.scope]!,
      'top_n': instance.topN,
    };

SqlSectionConfig _$SqlSectionConfigFromJson(Map<String, dynamic> json) =>
    SqlSectionConfig(
      title: json['title'] as String?,
      scope: $enumDecodeNullable(_$ReportScopeEnumMap, json['scope']),
      query: json['query'] as String? ?? '',
      maxRows: (json['max_rows'] as num?)?.toInt() ?? 200,
    );

Map<String, dynamic> _$SqlSectionConfigToJson(SqlSectionConfig instance) =>
    <String, dynamic>{
      'title': instance.title,
      'scope': _$ReportScopeEnumMap[instance.scope]!,
      'query': instance.query,
      'max_rows': instance.maxRows,
    };

TextSectionConfig _$TextSectionConfigFromJson(Map<String, dynamic> json) =>
    TextSectionConfig(
      title: json['title'] as String?,
      text: json['text'] as String? ?? '',
    );

Map<String, dynamic> _$TextSectionConfigToJson(TextSectionConfig instance) =>
    <String, dynamic>{
      'title': instance.title,
      'text': instance.text,
    };

ReportConfig _$ReportConfigFromJson(Map<String, dynamic> json) => ReportConfig(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      range: $enumDecodeNullable(_$ReportRangeKindEnumMap, json['range']) ??
          ReportRangeKind.shift,
      sections: ReportConfig._sectionsFromJson(json['sections'] as List),
      window: json['window'] == null
          ? null
          : ProductionWindowConfig.fromJson(
              json['window'] as Map<String, dynamic>),
    );

Map<String, dynamic> _$ReportConfigToJson(ReportConfig instance) =>
    <String, dynamic>{
      'id': instance.id,
      'name': instance.name,
      'description': instance.description,
      'range': _$ReportRangeKindEnumMap[instance.range]!,
      'sections': ReportConfig._sectionsToJson(instance.sections),
      'window': instance.window?.toJson(),
    };

const _$ReportRangeKindEnumMap = {
  ReportRangeKind.shift: 'shift',
  ReportRangeKind.day: 'day',
  ReportRangeKind.week: 'week',
};

ReportManConfig _$ReportManConfigFromJson(Map<String, dynamic> json) =>
    ReportManConfig(
      reports: (json['reports'] as List<dynamic>?)
          ?.map((e) => ReportConfig.fromJson(e as Map<String, dynamic>))
          .toList(),
    );

Map<String, dynamic> _$ReportManConfigToJson(ReportManConfig instance) =>
    <String, dynamic>{
      'reports': instance.reports.map((e) => e.toJson()).toList(),
    };

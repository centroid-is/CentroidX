// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'alarm.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

AlarmRule _$AlarmRuleFromJson(Map<String, dynamic> json) => AlarmRule(
      level: $enumDecode(_$AlarmLevelEnumMap, json['level']),
      expression:
          ExpressionConfig.fromJson(json['expression'] as Map<String, dynamic>),
      acknowledgeRequired: json['acknowledgeRequired'] as bool,
    );

Map<String, dynamic> _$AlarmRuleToJson(AlarmRule instance) => <String, dynamic>{
      'level': _$AlarmLevelEnumMap[instance.level]!,
      'expression': instance.expression,
      'acknowledgeRequired': instance.acknowledgeRequired,
    };

const _$AlarmLevelEnumMap = {
  AlarmLevel.info: 'info',
  AlarmLevel.warning: 'warning',
  AlarmLevel.error: 'error',
};

AlarmConfig _$AlarmConfigFromJson(Map<String, dynamic> json) => AlarmConfig(
      uid: json['uid'] as String,
      key: json['key'] as String?,
      title: json['title'] as String,
      description: json['description'] as String,
      rules: (json['rules'] as List<dynamic>)
          .map((e) => AlarmRule.fromJson(e as Map<String, dynamic>))
          .toList(),
      group:
          (json['group'] as List<dynamic>?)?.map((e) => e as String).toList() ??
              [],
      bindToGroup: json['bindToGroup'] as bool? ?? false,
      countsAsStop: json['countsAsStop'] as bool? ?? true,
    );

Map<String, dynamic> _$AlarmConfigToJson(AlarmConfig instance) =>
    <String, dynamic>{
      'uid': instance.uid,
      'key': instance.key,
      'title': instance.title,
      'description': instance.description,
      'rules': instance.rules,
      'group': instance.group,
      'bindToGroup': instance.bindToGroup,
      'countsAsStop': instance.countsAsStop,
    };

AlarmManConfig _$AlarmManConfigFromJson(Map<String, dynamic> json) =>
    AlarmManConfig(
      alarms: (json['alarms'] as List<dynamic>)
          .map((e) => AlarmConfig.fromJson(e as Map<String, dynamic>))
          .toList(),
    );

Map<String, dynamic> _$AlarmManConfigToJson(AlarmManConfig instance) =>
    <String, dynamic>{
      'alarms': instance.alarms,
    };

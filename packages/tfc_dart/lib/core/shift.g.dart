// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'shift.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ShiftDef _$ShiftDefFromJson(Map<String, dynamic> json) => ShiftDef(
      name: json['name'] as String,
      startMinutes: (json['start_minutes'] as num).toInt(),
      durationMinutes: (json['duration_minutes'] as num).toInt(),
      weekdays: (json['weekdays'] as List<dynamic>?)
          ?.map((e) => (e as num).toInt())
          .toList(),
    );

Map<String, dynamic> _$ShiftDefToJson(ShiftDef instance) => <String, dynamic>{
      'name': instance.name,
      'start_minutes': instance.startMinutes,
      'duration_minutes': instance.durationMinutes,
      'weekdays': instance.weekdays,
    };

ShiftManConfig _$ShiftManConfigFromJson(Map<String, dynamic> json) =>
    ShiftManConfig(
      shifts: (json['shifts'] as List<dynamic>?)
          ?.map((e) => ShiftDef.fromJson(e as Map<String, dynamic>))
          .toList(),
    );

Map<String, dynamic> _$ShiftManConfigToJson(ShiftManConfig instance) =>
    <String, dynamic>{
      'shifts': instance.shifts.map((e) => e.toJson()).toList(),
    };

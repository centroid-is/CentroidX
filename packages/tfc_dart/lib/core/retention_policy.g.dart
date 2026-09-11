// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'retention_policy.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

RetentionPolicy _$RetentionPolicyFromJson(Map<String, dynamic> json) =>
    RetentionPolicy(
      dropAfter: const DurationMinutesConverterNonNull()
          .fromJson((json['drop_after_min'] as num).toInt()),
      scheduleInterval: const DurationMinutesConverter()
          .fromJson((json['schedule_interval_min'] as num?)?.toInt()),
    );

Map<String, dynamic> _$RetentionPolicyToJson(RetentionPolicy instance) =>
    <String, dynamic>{
      'drop_after_min':
          const DurationMinutesConverterNonNull().toJson(instance.dropAfter),
      'schedule_interval_min':
          const DurationMinutesConverter().toJson(instance.scheduleInterval),
    };

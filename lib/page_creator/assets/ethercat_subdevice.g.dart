// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ethercat_subdevice.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

EcBusConfig _$EcBusConfigFromJson(Map<String, dynamic> json) => EcBusConfig(
      label: json['label'] as String? ?? '',
      diagKey: json['diagKey'] as String? ?? '',
      infoKey: json['infoKey'] as String? ?? '',
      countKey: json['countKey'] as String?,
    );

Map<String, dynamic> _$EcBusConfigToJson(EcBusConfig instance) =>
    <String, dynamic>{
      'label': instance.label,
      'diagKey': instance.diagKey,
      'infoKey': instance.infoKey,
      if (instance.countKey case final value?) 'countKey': value,
    };

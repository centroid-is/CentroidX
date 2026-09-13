// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ethercat_subdevice.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

EcSubDeviceBinding _$EcSubDeviceBindingFromJson(Map<String, dynamic> json) =>
    EcSubDeviceBinding(
      diagKey: json['diagKey'] as String? ?? '',
      infoKey: json['infoKey'] as String? ?? '',
      position: (json['position'] as num?)?.toInt() ?? 0,
      name: json['name'] as String?,
    );

Map<String, dynamic> _$EcSubDeviceBindingToJson(EcSubDeviceBinding instance) =>
    <String, dynamic>{
      'diagKey': instance.diagKey,
      'infoKey': instance.infoKey,
      'position': instance.position,
      if (instance.name case final value?) 'name': value,
    };

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

EcPlcConfig _$EcPlcConfigFromJson(Map<String, dynamic> json) => EcPlcConfig(
      label: json['label'] as String? ?? '',
      masters: (json['masters'] as List<dynamic>?)
          ?.map((e) => EcBusConfig.fromJson(e as Map<String, dynamic>))
          .toList(),
    );

Map<String, dynamic> _$EcPlcConfigToJson(EcPlcConfig instance) =>
    <String, dynamic>{
      'label': instance.label,
      'masters': instance.masters.map((e) => e.toJson()).toList(),
    };

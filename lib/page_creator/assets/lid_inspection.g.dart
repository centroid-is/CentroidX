// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'lid_inspection.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

LidInspectionConfig _$LidInspectionConfigFromJson(Map<String, dynamic> json) =>
    LidInspectionConfig(
      keyPrefix: json['key_prefix'] as String? ?? '',
      camera: json['camera'] as String? ?? '',
      recentLimit: (json['recent_limit'] as num?)?.toInt() ?? 8,
      trainingBatch: (json['training_batch'] as num?)?.toInt() ?? 20,
      alarmUids: (json['alarm_uids'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      announceInNavigation: json['announce_in_navigation'] as bool? ?? true,
    )
      ..variant = json['asset_name'] as String
      ..id = json['id'] as String?
      ..coordinates =
          Coordinates.fromJson(json['coordinates'] as Map<String, dynamic>)
      ..size = RelativeSize.fromJson(json['size'] as Map<String, dynamic>)
      ..text = json['text'] as String?
      ..textPos = $enumDecodeNullable(_$TextPosEnumMap, json['textPos'])
      ..techDocId = (json['techDocId'] as num?)?.toInt()
      ..plcAssetKey = json['plcAssetKey'] as String?
      ..showWhenInactive = json['show_when_inactive'] as bool? ?? false;

Map<String, dynamic> _$LidInspectionConfigToJson(
        LidInspectionConfig instance) =>
    <String, dynamic>{
      'asset_name': instance.variant,
      if (instance.id case final value?) 'id': value,
      'coordinates': instance.coordinates.toJson(),
      'size': instance.size.toJson(),
      'text': instance.text,
      'textPos': _$TextPosEnumMap[instance.textPos],
      'techDocId': instance.techDocId,
      'plcAssetKey': instance.plcAssetKey,
      'alarm_uids': instance.alarmUids,
      'show_when_inactive': instance.showWhenInactive,
      'announce_in_navigation': instance.announceInNavigation,
      'key_prefix': instance.keyPrefix,
      'camera': instance.camera,
      'recent_limit': instance.recentLimit,
      'training_batch': instance.trainingBatch,
    };

const _$TextPosEnumMap = {
  TextPos.above: 'above',
  TextPos.below: 'below',
  TextPos.left: 'left',
  TextPos.right: 'right',
  TextPos.inside: 'inside',
};

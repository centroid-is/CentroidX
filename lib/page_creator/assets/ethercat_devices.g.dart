// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ethercat_devices.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

EtherCatDeviceTableConfig _$EtherCatDeviceTableConfigFromJson(
        Map<String, dynamic> json) =>
    EtherCatDeviceTableConfig(
      buses: (json['buses'] as List<dynamic>?)
          ?.map((e) => EcBusConfig.fromJson(e as Map<String, dynamic>))
          .toList(),
      problemsOnly: json['problemsOnly'] as bool? ?? false,
    )
      ..variant = json['asset_name'] as String
      ..id = json['id'] as String?
      ..coordinates =
          Coordinates.fromJson(json['coordinates'] as Map<String, dynamic>)
      ..size = RelativeSize.fromJson(json['size'] as Map<String, dynamic>)
      ..text = json['text'] as String?
      ..textPos = $enumDecodeNullable(_$TextPosEnumMap, json['textPos'])
      ..techDocId = (json['techDocId'] as num?)?.toInt()
      ..plcAssetKey = json['plcAssetKey'] as String?;

Map<String, dynamic> _$EtherCatDeviceTableConfigToJson(
        EtherCatDeviceTableConfig instance) =>
    <String, dynamic>{
      'asset_name': instance.variant,
      if (instance.id case final value?) 'id': value,
      'coordinates': instance.coordinates.toJson(),
      'size': instance.size.toJson(),
      'text': instance.text,
      'textPos': _$TextPosEnumMap[instance.textPos],
      'techDocId': instance.techDocId,
      'plcAssetKey': instance.plcAssetKey,
      'buses': instance.buses.map((e) => e.toJson()).toList(),
      'problemsOnly': instance.problemsOnly,
    };

const _$TextPosEnumMap = {
  TextPos.above: 'above',
  TextPos.below: 'below',
  TextPos.left: 'left',
  TextPos.right: 'right',
  TextPos.inside: 'inside',
};

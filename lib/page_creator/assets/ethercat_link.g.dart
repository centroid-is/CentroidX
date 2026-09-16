// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ethercat_link.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

EtherCatLinkConfig _$EtherCatLinkConfigFromJson(Map<String, dynamic> json) =>
    EtherCatLinkConfig(
      key: json['key'] as String? ?? '',
      run: json['run'] == null
          ? null
          : LinkRun.fromJson(json['run'] as Map<String, dynamic>),
      thickness: (json['thickness'] as num?)?.toDouble() ?? 0.006,
    )
      ..variant = json['asset_name'] as String
      ..id = json['id'] as String?
      ..text = json['text'] as String?
      ..textPos = $enumDecodeNullable(_$TextPosEnumMap, json['textPos'])
      ..techDocId = (json['techDocId'] as num?)?.toInt()
      ..plcAssetKey = json['plcAssetKey'] as String?
      ..coordinates =
          Coordinates.fromJson(json['coordinates'] as Map<String, dynamic>)
      ..size = RelativeSize.fromJson(json['size'] as Map<String, dynamic>);

Map<String, dynamic> _$EtherCatLinkConfigToJson(EtherCatLinkConfig instance) =>
    <String, dynamic>{
      'asset_name': instance.variant,
      if (instance.id case final value?) 'id': value,
      'text': instance.text,
      'textPos': _$TextPosEnumMap[instance.textPos],
      'techDocId': instance.techDocId,
      'plcAssetKey': instance.plcAssetKey,
      'key': instance.key,
      'run': instance.run.toJson(),
      'thickness': instance.thickness,
      'coordinates': instance.coordinates.toJson(),
      'size': instance.size.toJson(),
    };

const _$TextPosEnumMap = {
  TextPos.above: 'above',
  TextPos.below: 'below',
  TextPos.left: 'left',
  TextPos.right: 'right',
  TextPos.inside: 'inside',
};

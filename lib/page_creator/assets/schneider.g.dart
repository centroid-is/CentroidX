// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'schneider.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

SchneiderATV320Config _$SchneiderATV320ConfigFromJson(
        Map<String, dynamic> json) =>
    SchneiderATV320Config(
      label: json['label'] as String?,
      labelFontSize: (json['labelFontSize'] as num?)?.toDouble(),
      hmisKey: json['hmisKey'] as String?,
      freqKey: json['freqKey'] as String?,
      configKey: json['configKey'] as String?,
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
      ..ecSubDevice = json['ecSubDevice'] == null
          ? null
          : EcSubDeviceBinding.fromJson(
              json['ecSubDevice'] as Map<String, dynamic>);

Map<String, dynamic> _$SchneiderATV320ConfigToJson(
        SchneiderATV320Config instance) =>
    <String, dynamic>{
      'asset_name': instance.variant,
      if (instance.id case final value?) 'id': value,
      'coordinates': instance.coordinates.toJson(),
      'size': instance.size.toJson(),
      'text': instance.text,
      'textPos': _$TextPosEnumMap[instance.textPos],
      'techDocId': instance.techDocId,
      'plcAssetKey': instance.plcAssetKey,
      if (instance.ecSubDevice?.toJson() case final value?)
        'ecSubDevice': value,
      'label': instance.label,
      'labelFontSize': instance.labelFontSize,
      'hmisKey': instance.hmisKey,
      'freqKey': instance.freqKey,
      'configKey': instance.configKey,
    };

const _$TextPosEnumMap = {
  TextPos.above: 'above',
  TextPos.below: 'below',
  TextPos.left: 'left',
  TextPos.right: 'right',
  TextPos.inside: 'inside',
};

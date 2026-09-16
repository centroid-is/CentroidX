// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'wagon_station_strip.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

WagonStationStripConfig _$WagonStationStripConfigFromJson(
        Map<String, dynamic> json) =>
    WagonStationStripConfig(
      stationsKey: json['stationsKey'] as String? ?? '',
      wagonStateKey: json['wagonStateKey'] as String?,
      showPositions: json['showPositions'] as bool? ?? true,
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

Map<String, dynamic> _$WagonStationStripConfigToJson(
        WagonStationStripConfig instance) =>
    <String, dynamic>{
      'asset_name': instance.variant,
      if (instance.id case final value?) 'id': value,
      'coordinates': instance.coordinates.toJson(),
      'size': instance.size.toJson(),
      'text': instance.text,
      'textPos': _$TextPosEnumMap[instance.textPos],
      'techDocId': instance.techDocId,
      'plcAssetKey': instance.plcAssetKey,
      'stationsKey': instance.stationsKey,
      if (instance.wagonStateKey case final value?) 'wagonStateKey': value,
      'showPositions': instance.showPositions,
    };

const _$TextPosEnumMap = {
  TextPos.above: 'above',
  TextPos.below: 'below',
  TextPos.left: 'left',
  TextPos.right: 'right',
  TextPos.inside: 'inside',
};

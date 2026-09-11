// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'web_view.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

WebViewAssetConfig _$WebViewAssetConfigFromJson(Map<String, dynamic> json) =>
    WebViewAssetConfig(
      url: json['url'] as String? ?? '',
      reloadSeconds: (json['reloadSeconds'] as num?)?.toInt() ?? 0,
      interactive: json['interactive'] as bool? ?? false,
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

Map<String, dynamic> _$WebViewAssetConfigToJson(WebViewAssetConfig instance) =>
    <String, dynamic>{
      'asset_name': instance.variant,
      if (instance.id case final value?) 'id': value,
      'coordinates': instance.coordinates.toJson(),
      'size': instance.size.toJson(),
      'text': instance.text,
      'textPos': _$TextPosEnumMap[instance.textPos],
      'techDocId': instance.techDocId,
      'plcAssetKey': instance.plcAssetKey,
      'url': instance.url,
      'reloadSeconds': instance.reloadSeconds,
      'interactive': instance.interactive,
    };

const _$TextPosEnumMap = {
  TextPos.above: 'above',
  TextPos.below: 'below',
  TextPos.left: 'left',
  TextPos.right: 'right',
  TextPos.inside: 'inside',
};

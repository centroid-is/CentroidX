// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'festo.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

VtugSliceConfig _$VtugSliceConfigFromJson(Map<String, dynamic> json) =>
    VtugSliceConfig(
      kind: $enumDecodeNullable(_$VtugValveKindEnumMap, json['kind']) ??
          VtugValveKind.valve52Mono,
      name: json['name'] as String? ?? '',
    );

Map<String, dynamic> _$VtugSliceConfigToJson(VtugSliceConfig instance) =>
    <String, dynamic>{
      'kind': _$VtugValveKindEnumMap[instance.kind]!,
      'name': instance.name,
    };

const _$VtugValveKindEnumMap = {
  VtugValveKind.blank: 'blank',
  VtugValveKind.valve52Mono: 'valve52Mono',
  VtugValveKind.valve52Bistable: 'valve52Bistable',
  VtugValveKind.valve53Closed: 'valve53Closed',
};

FestoVTUGConfig _$FestoVTUGConfigFromJson(Map<String, dynamic> json) =>
    FestoVTUGConfig(
      nameOrId: json['nameOrId'] as String? ?? '',
      stateKey: json['stateKey'] as String?,
      slices: (json['slices'] as List<dynamic>?)
          ?.map((e) => VtugSliceConfig.fromJson(e as Map<String, dynamic>))
          .toList(),
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

Map<String, dynamic> _$FestoVTUGConfigToJson(FestoVTUGConfig instance) =>
    <String, dynamic>{
      'asset_name': instance.variant,
      if (instance.id case final value?) 'id': value,
      'coordinates': instance.coordinates.toJson(),
      'size': instance.size.toJson(),
      'text': instance.text,
      'textPos': _$TextPosEnumMap[instance.textPos],
      'techDocId': instance.techDocId,
      'plcAssetKey': instance.plcAssetKey,
      'nameOrId': instance.nameOrId,
      'stateKey': instance.stateKey,
      'slices': instance.slices.map((e) => e.toJson()).toList(),
    };

const _$TextPosEnumMap = {
  TextPos.above: 'above',
  TextPos.below: 'below',
  TextPos.left: 'left',
  TextPos.right: 'right',
  TextPos.inside: 'inside',
};

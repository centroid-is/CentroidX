// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'section_button.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

SectionRef _$SectionRefFromJson(Map<String, dynamic> json) => SectionRef(
      key: json['key'] as String,
      label: json['label'] as String?,
      exclusiveGroup: json['exclusiveGroup'] as String?,
    );

Map<String, dynamic> _$SectionRefToJson(SectionRef instance) =>
    <String, dynamic>{
      'key': instance.key,
      'label': instance.label,
      'exclusiveGroup': instance.exclusiveGroup,
    };

SectionButtonConfig _$SectionButtonConfigFromJson(Map<String, dynamic> json) =>
    SectionButtonConfig(
      sections: (json['sections'] as List<dynamic>?)
              ?.map((e) => SectionRef.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      label: json['label'] as String?,
      showName: json['show_name'] as bool? ?? true,
      allowModeSwitch: json['allow_mode_switch'] as bool? ?? false,
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

Map<String, dynamic> _$SectionButtonConfigToJson(
        SectionButtonConfig instance) =>
    <String, dynamic>{
      'asset_name': instance.variant,
      if (instance.id case final value?) 'id': value,
      'coordinates': instance.coordinates.toJson(),
      'size': instance.size.toJson(),
      'text': instance.text,
      'textPos': _$TextPosEnumMap[instance.textPos],
      'techDocId': instance.techDocId,
      'plcAssetKey': instance.plcAssetKey,
      'sections': instance.sections.map((e) => e.toJson()).toList(),
      'show_name': instance.showName,
      'allow_mode_switch': instance.allowModeSwitch,
    };

const _$TextPosEnumMap = {
  TextPos.above: 'above',
  TextPos.below: 'below',
  TextPos.left: 'left',
  TextPos.right: 'right',
  TextPos.inside: 'inside',
};

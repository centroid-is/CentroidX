// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'recipes.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

RecipesConfig _$RecipesConfigFromJson(Map<String, dynamic> json) =>
    RecipesConfig(
      key: json['key'] as String,
      label: json['label'] as String,
      keys:
          (json['keys'] as List<dynamic>?)?.map((e) => e as String).toList() ??
              [],
      unifiedRecipe: json['unifiedRecipe'] as bool? ?? false,
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

Map<String, dynamic> _$RecipesConfigToJson(RecipesConfig instance) =>
    <String, dynamic>{
      'asset_name': instance.variant,
      if (instance.id case final value?) 'id': value,
      'coordinates': instance.coordinates.toJson(),
      'size': instance.size.toJson(),
      'text': instance.text,
      'textPos': _$TextPosEnumMap[instance.textPos],
      'techDocId': instance.techDocId,
      'plcAssetKey': instance.plcAssetKey,
      'key': instance.key,
      'keys': instance.keys,
      'label': instance.label,
      'unifiedRecipe': instance.unifiedRecipe,
    };

const _$TextPosEnumMap = {
  TextPos.above: 'above',
  TextPos.below: 'below',
  TextPos.left: 'left',
  TextPos.right: 'right',
  TextPos.inside: 'inside',
};

Recipe _$RecipeFromJson(Map<String, dynamic> json) => Recipe(
      name: json['name'] as String,
      value: const DynamicValueConverter().fromJson(json['value']),
    );

Map<String, dynamic> _$RecipeToJson(Recipe instance) => <String, dynamic>{
      'name': instance.name,
      'value': const DynamicValueConverter().toJson(instance.value),
    };

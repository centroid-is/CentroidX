// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'beckhoff.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

BeckhoffCX5010Config _$BeckhoffCX5010ConfigFromJson(
        Map<String, dynamic> json) =>
    BeckhoffCX5010Config()
      ..variant = json['asset_name'] as String
      ..id = json['id'] as String?
      ..coordinates =
          Coordinates.fromJson(json['coordinates'] as Map<String, dynamic>)
      ..size = RelativeSize.fromJson(json['size'] as Map<String, dynamic>)
      ..text = json['text'] as String?
      ..textPos = $enumDecodeNullable(_$TextPosEnumMap, json['textPos'])
      ..techDocId = (json['techDocId'] as num?)?.toInt()
      ..plcAssetKey = json['plcAssetKey'] as String?
      ..subdevices =
          const AssetListConverter().fromJson(json['subdevices'] as List)
      ..nameOrId = json['nameOrId'] as String? ?? '';

Map<String, dynamic> _$BeckhoffCX5010ConfigToJson(
        BeckhoffCX5010Config instance) =>
    <String, dynamic>{
      'asset_name': instance.variant,
      if (instance.id case final value?) 'id': value,
      'coordinates': instance.coordinates.toJson(),
      'size': instance.size.toJson(),
      'text': instance.text,
      'textPos': _$TextPosEnumMap[instance.textPos],
      'techDocId': instance.techDocId,
      'plcAssetKey': instance.plcAssetKey,
      'subdevices': const AssetListConverter().toJson(instance.subdevices),
      'nameOrId': instance.nameOrId,
    };

const _$TextPosEnumMap = {
  TextPos.above: 'above',
  TextPos.below: 'below',
  TextPos.left: 'left',
  TextPos.right: 'right',
  TextPos.inside: 'inside',
};

BeckhoffCX5340Config _$BeckhoffCX5340ConfigFromJson(
        Map<String, dynamic> json) =>
    BeckhoffCX5340Config()
      ..variant = json['asset_name'] as String
      ..id = json['id'] as String?
      ..coordinates =
          Coordinates.fromJson(json['coordinates'] as Map<String, dynamic>)
      ..size = RelativeSize.fromJson(json['size'] as Map<String, dynamic>)
      ..text = json['text'] as String?
      ..textPos = $enumDecodeNullable(_$TextPosEnumMap, json['textPos'])
      ..techDocId = (json['techDocId'] as num?)?.toInt()
      ..plcAssetKey = json['plcAssetKey'] as String?
      ..subdevices =
          const AssetListConverter().fromJson(json['subdevices'] as List)
      ..nameOrId = json['nameOrId'] as String? ?? '';

Map<String, dynamic> _$BeckhoffCX5340ConfigToJson(
        BeckhoffCX5340Config instance) =>
    <String, dynamic>{
      'asset_name': instance.variant,
      if (instance.id case final value?) 'id': value,
      'coordinates': instance.coordinates.toJson(),
      'size': instance.size.toJson(),
      'text': instance.text,
      'textPos': _$TextPosEnumMap[instance.textPos],
      'techDocId': instance.techDocId,
      'plcAssetKey': instance.plcAssetKey,
      'subdevices': const AssetListConverter().toJson(instance.subdevices),
      'nameOrId': instance.nameOrId,
    };

BeckhoffEK1100Config _$BeckhoffEK1100ConfigFromJson(
        Map<String, dynamic> json) =>
    BeckhoffEK1100Config()
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
              json['ecSubDevice'] as Map<String, dynamic>)
      ..subdevices =
          const AssetListConverter().fromJson(json['subdevices'] as List)
      ..nameOrId = json['nameOrId'] as String? ?? '';

Map<String, dynamic> _$BeckhoffEK1100ConfigToJson(
        BeckhoffEK1100Config instance) =>
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
      'subdevices': const AssetListConverter().toJson(instance.subdevices),
      'nameOrId': instance.nameOrId,
    };

BeckhoffEL1008Config _$BeckhoffEL1008ConfigFromJson(
        Map<String, dynamic> json) =>
    BeckhoffEL1008Config(
      nameOrId: json['nameOrId'] as String,
      descriptionsKey: json['descriptionsKey'] as String?,
      rawStateKey: json['rawStateKey'] as String?,
      processedStateKey: json['processedStateKey'] as String?,
      forceValuesKey: json['forceValuesKey'] as String?,
      onFiltersKey: json['onFiltersKey'] as String?,
      offFiltersKey: json['offFiltersKey'] as String?,
      channelDescriptions: (json['channel_descriptions'] as List<dynamic>?)
          ?.map((e) => e as String)
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
      ..plcAssetKey = json['plcAssetKey'] as String?
      ..ecSubDevice = json['ecSubDevice'] == null
          ? null
          : EcSubDeviceBinding.fromJson(
              json['ecSubDevice'] as Map<String, dynamic>);

Map<String, dynamic> _$BeckhoffEL1008ConfigToJson(
        BeckhoffEL1008Config instance) =>
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
      'nameOrId': instance.nameOrId,
      'descriptionsKey': instance.descriptionsKey,
      'rawStateKey': instance.rawStateKey,
      'processedStateKey': instance.processedStateKey,
      'forceValuesKey': instance.forceValuesKey,
      'onFiltersKey': instance.onFiltersKey,
      'offFiltersKey': instance.offFiltersKey,
      'channel_descriptions': instance.channelDescriptions,
    };

BeckhoffEL2008Config _$BeckhoffEL2008ConfigFromJson(
        Map<String, dynamic> json) =>
    BeckhoffEL2008Config(
      nameOrId: json['nameOrId'] as String,
      descriptionsKey: json['descriptionsKey'] as String?,
      rawStateKey: json['rawStateKey'] as String?,
      forceValuesKey: json['forceValuesKey'] as String?,
      channelDescriptions: (json['channel_descriptions'] as List<dynamic>?)
          ?.map((e) => e as String)
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
      ..plcAssetKey = json['plcAssetKey'] as String?
      ..ecSubDevice = json['ecSubDevice'] == null
          ? null
          : EcSubDeviceBinding.fromJson(
              json['ecSubDevice'] as Map<String, dynamic>);

Map<String, dynamic> _$BeckhoffEL2008ConfigToJson(
        BeckhoffEL2008Config instance) =>
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
      'nameOrId': instance.nameOrId,
      'descriptionsKey': instance.descriptionsKey,
      'rawStateKey': instance.rawStateKey,
      'forceValuesKey': instance.forceValuesKey,
      'channel_descriptions': instance.channelDescriptions,
    };

BeckhoffEL9222Config _$BeckhoffEL9222ConfigFromJson(
        Map<String, dynamic> json) =>
    BeckhoffEL9222Config(
      nameOrId: json['nameOrId'] as String,
      stateKey: json['stateKey'] as String?,
      descriptionsKey: json['descriptionsKey'] as String?,
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

Map<String, dynamic> _$BeckhoffEL9222ConfigToJson(
        BeckhoffEL9222Config instance) =>
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
      'nameOrId': instance.nameOrId,
      'stateKey': instance.stateKey,
      'descriptionsKey': instance.descriptionsKey,
    };

BeckhoffEL9187Config _$BeckhoffEL9187ConfigFromJson(
        Map<String, dynamic> json) =>
    BeckhoffEL9187Config()
      ..variant = json['asset_name'] as String
      ..id = json['id'] as String?
      ..coordinates =
          Coordinates.fromJson(json['coordinates'] as Map<String, dynamic>)
      ..size = RelativeSize.fromJson(json['size'] as Map<String, dynamic>)
      ..text = json['text'] as String?
      ..textPos = $enumDecodeNullable(_$TextPosEnumMap, json['textPos'])
      ..techDocId = (json['techDocId'] as num?)?.toInt()
      ..plcAssetKey = json['plcAssetKey'] as String?
      ..nameOrId = json['nameOrId'] as String? ?? '';

Map<String, dynamic> _$BeckhoffEL9187ConfigToJson(
        BeckhoffEL9187Config instance) =>
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
    };

BeckhoffEL9186Config _$BeckhoffEL9186ConfigFromJson(
        Map<String, dynamic> json) =>
    BeckhoffEL9186Config()
      ..variant = json['asset_name'] as String
      ..id = json['id'] as String?
      ..coordinates =
          Coordinates.fromJson(json['coordinates'] as Map<String, dynamic>)
      ..size = RelativeSize.fromJson(json['size'] as Map<String, dynamic>)
      ..text = json['text'] as String?
      ..textPos = $enumDecodeNullable(_$TextPosEnumMap, json['textPos'])
      ..techDocId = (json['techDocId'] as num?)?.toInt()
      ..plcAssetKey = json['plcAssetKey'] as String?;

Map<String, dynamic> _$BeckhoffEL9186ConfigToJson(
        BeckhoffEL9186Config instance) =>
    <String, dynamic>{
      'asset_name': instance.variant,
      if (instance.id case final value?) 'id': value,
      'coordinates': instance.coordinates.toJson(),
      'size': instance.size.toJson(),
      'text': instance.text,
      'textPos': _$TextPosEnumMap[instance.textPos],
      'techDocId': instance.techDocId,
      'plcAssetKey': instance.plcAssetKey,
    };

BeckhoffEL3054Config _$BeckhoffEL3054ConfigFromJson(
        Map<String, dynamic> json) =>
    BeckhoffEL3054Config(
      nameOrId: json['nameOrId'] as String,
      descriptionsKey: json['descriptionsKey'] as String?,
      stateKey: json['stateKey'] as String?,
      errorsKey: json['errorsKey'] as String?,
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

Map<String, dynamic> _$BeckhoffEL3054ConfigToJson(
        BeckhoffEL3054Config instance) =>
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
      'nameOrId': instance.nameOrId,
      'descriptionsKey': instance.descriptionsKey,
      'stateKey': instance.stateKey,
      'errorsKey': instance.errorsKey,
    };

BeckhoffEL2912Config _$BeckhoffEL2912ConfigFromJson(
        Map<String, dynamic> json) =>
    BeckhoffEL2912Config(
      nameOrId: json['nameOrId'] as String,
      underrangeKey: json['underrangeKey'] as String?,
      overrangeKey: json['overrangeKey'] as String?,
      descriptionKey: json['descriptionKey'] as String?,
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

Map<String, dynamic> _$BeckhoffEL2912ConfigToJson(
        BeckhoffEL2912Config instance) =>
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
      'nameOrId': instance.nameOrId,
      'underrangeKey': instance.underrangeKey,
      'overrangeKey': instance.overrangeKey,
      'descriptionKey': instance.descriptionKey,
    };

BeckhoffPS2001Config _$BeckhoffPS2001ConfigFromJson(
        Map<String, dynamic> json) =>
    BeckhoffPS2001Config(
      nameOrId: json['nameOrId'] as String,
      stateKey: json['stateKey'] as String?,
      descriptionKey: json['descriptionKey'] as String?,
      trend: json['trend'] as bool? ?? false,
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

Map<String, dynamic> _$BeckhoffPS2001ConfigToJson(
        BeckhoffPS2001Config instance) =>
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
      'nameOrId': instance.nameOrId,
      'stateKey': instance.stateKey,
      'descriptionKey': instance.descriptionKey,
      'trend': instance.trend,
    };

BeckhoffEL6070Config _$BeckhoffEL6070ConfigFromJson(
        Map<String, dynamic> json) =>
    BeckhoffEL6070Config()
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
              json['ecSubDevice'] as Map<String, dynamic>)
      ..nameOrId = json['nameOrId'] as String? ?? '';

Map<String, dynamic> _$BeckhoffEL6070ConfigToJson(
        BeckhoffEL6070Config instance) =>
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
      'nameOrId': instance.nameOrId,
    };

BeckhoffEK1110Config _$BeckhoffEK1110ConfigFromJson(
        Map<String, dynamic> json) =>
    BeckhoffEK1110Config()
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
              json['ecSubDevice'] as Map<String, dynamic>)
      ..nameOrId = json['nameOrId'] as String? ?? '';

Map<String, dynamic> _$BeckhoffEK1110ConfigToJson(
        BeckhoffEK1110Config instance) =>
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
      'nameOrId': instance.nameOrId,
    };

BeckhoffCU2508Config _$BeckhoffCU2508ConfigFromJson(
        Map<String, dynamic> json) =>
    BeckhoffCU2508Config(
      nameOrId: json['nameOrId'] as String,
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

Map<String, dynamic> _$BeckhoffCU2508ConfigToJson(
        BeckhoffCU2508Config instance) =>
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
      'nameOrId': instance.nameOrId,
    };

BeckhoffEPBoxConfig _$BeckhoffEPBoxConfigFromJson(Map<String, dynamic> json) =>
    BeckhoffEPBoxConfig(
      variantModel: $enumDecode(_$EPBoxVariantEnumMap, json['variant_model']),
      nameOrId: json['nameOrId'] as String,
      stateKey: json['stateKey'] as String?,
      descriptionsKey: json['descriptionsKey'] as String?,
      channelDescriptions: (json['channel_descriptions'] as List<dynamic>?)
          ?.map((e) => e as String)
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
      ..plcAssetKey = json['plcAssetKey'] as String?
      ..ecSubDevice = json['ecSubDevice'] == null
          ? null
          : EcSubDeviceBinding.fromJson(
              json['ecSubDevice'] as Map<String, dynamic>);

Map<String, dynamic> _$BeckhoffEPBoxConfigToJson(
        BeckhoffEPBoxConfig instance) =>
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
      'variant_model': _$EPBoxVariantEnumMap[instance.variantModel]!,
      'nameOrId': instance.nameOrId,
      'stateKey': instance.stateKey,
      'descriptionsKey': instance.descriptionsKey,
      'channel_descriptions': instance.channelDescriptions,
    };

const _$EPBoxVariantEnumMap = {
  EPBoxVariant.ep2338: 'ep2338',
  EPBoxVariant.ep1918: 'ep1918',
};

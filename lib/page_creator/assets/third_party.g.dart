// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'third_party.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ThirdPartyChildEntry _$ThirdPartyChildEntryFromJson(
        Map<String, dynamic> json) =>
    ThirdPartyChildEntry(
      id: json['id'] as String?,
      offsetX: (json['offsetX'] as num?)?.toDouble() ?? 0.5,
      offsetY: (json['offsetY'] as num?)?.toDouble() ?? 0.5,
      keepUpright: json['keepUpright'] as bool? ?? false,
      child: _childFromJson(json['child'] as Map<String, dynamic>),
    );

Map<String, dynamic> _$ThirdPartyChildEntryToJson(
        ThirdPartyChildEntry instance) =>
    <String, dynamic>{
      'id': instance.id,
      'offsetX': instance.offsetX,
      'offsetY': instance.offsetY,
      'keepUpright': instance.keepUpright,
      'child': _childToJson(instance.child),
    };

ThirdPartyEquipmentConfig _$ThirdPartyEquipmentConfigFromJson(
        Map<String, dynamic> json) =>
    ThirdPartyEquipmentConfig(
      kind: $enumDecodeNullable(_$ThirdPartyEquipmentKindEnumMap, json['kind'],
              unknownValue: ThirdPartyEquipmentKind.multivac) ??
          ThirdPartyEquipmentKind.multivac,
      runKey: json['runKey'] as String? ?? '',
      invertRunPolarity: json['invertRunPolarity'] as bool? ?? false,
      statusKey: json['statusKey'] as String? ?? '',
      runningColor: _$JsonConverterFromJson<Map<String, dynamic>, AssetColor>(
          json['runningColor'], const AssetColorConverter().fromJson),
      stoppedColor: _$JsonConverterFromJson<Map<String, dynamic>, AssetColor>(
          json['stoppedColor'], const AssetColorConverter().fromJson),
      outlineColor: _$JsonConverterFromJson<Map<String, dynamic>, AssetColor>(
          json['outlineColor'], const AssetColorConverter().fromJson),
      strokeWidth: (json['strokeWidth'] as num?)?.toDouble() ?? 2.0,
      tag: json['tag'] as String?,
      showTag: json['showTag'] as bool? ?? false,
      notes: json['notes'] as String?,
      strapMachines: (json['strapMachines'] as num?)?.toInt() ?? 3,
      robotStations: (json['robotStations'] as num?)?.toInt() ?? 2,
      mirrorX: json['mirrorX'] as bool? ?? false,
      mirrorY: json['mirrorY'] as bool? ?? false,
      childTextAngle: (json['childTextAngle'] as num?)?.toDouble() ?? 0.0,
      acceptWindowMinutes: (json['acceptWindowMinutes'] as num?)?.toInt() ?? 30,
      acceptBarsClockAligned: json['acceptBarsClockAligned'] as bool? ?? true,
      children: _childrenFromJson(json['children'] as List?),
      extraBits: (json['extraBits'] as List<dynamic>?)
              ?.map((e) => ExtraStatusBit.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    )
      ..variant = json['asset_name'] as String
      ..id = json['id'] as String?
      ..coordinates =
          Coordinates.fromJson(json['coordinates'] as Map<String, dynamic>)
      ..size = RelativeSize.fromJson(json['size'] as Map<String, dynamic>)
      ..textPos = $enumDecodeNullable(_$TextPosEnumMap, json['textPos'])
      ..techDocId = (json['techDocId'] as num?)?.toInt()
      ..plcAssetKey = json['plcAssetKey'] as String?
      ..text = json['text'] as String?;

Map<String, dynamic> _$ThirdPartyEquipmentConfigToJson(
        ThirdPartyEquipmentConfig instance) =>
    <String, dynamic>{
      'asset_name': instance.variant,
      if (instance.id case final value?) 'id': value,
      'coordinates': instance.coordinates.toJson(),
      'size': instance.size.toJson(),
      'textPos': _$TextPosEnumMap[instance.textPos],
      'techDocId': instance.techDocId,
      'plcAssetKey': instance.plcAssetKey,
      'kind': _$ThirdPartyEquipmentKindEnumMap[instance.kind]!,
      'runKey': instance.runKey,
      'invertRunPolarity': instance.invertRunPolarity,
      'statusKey': instance.statusKey,
      'runningColor': const AssetColorConverter().toJson(instance.runningColor),
      'stoppedColor': const AssetColorConverter().toJson(instance.stoppedColor),
      'outlineColor': const AssetColorConverter().toJson(instance.outlineColor),
      'strokeWidth': instance.strokeWidth,
      'tag': instance.tag,
      'showTag': instance.showTag,
      'notes': instance.notes,
      'strapMachines': instance.strapMachines,
      'mirrorX': instance.mirrorX,
      'mirrorY': instance.mirrorY,
      'robotStations': instance.robotStations,
      'children': _childrenToJson(instance.children),
      'extraBits': instance.extraBits.map((e) => e.toJson()).toList(),
      'childTextAngle': instance.childTextAngle,
      'acceptWindowMinutes': instance.acceptWindowMinutes,
      'acceptBarsClockAligned': instance.acceptBarsClockAligned,
      'text': instance.text,
    };

const _$ThirdPartyEquipmentKindEnumMap = {
  ThirdPartyEquipmentKind.multivac: 'multivac',
  ThirdPartyEquipmentKind.speedBatcher: 'speedBatcher',
  ThirdPartyEquipmentKind.boxErector: 'boxErector',
  ThirdPartyEquipmentKind.strappingLine: 'strappingLine',
  ThirdPartyEquipmentKind.fishAligner: 'fishAligner',
  ThirdPartyEquipmentKind.optimarPalletiser: 'optimarPalletiser',
  ThirdPartyEquipmentKind.palletMagazine: 'palletMagazine',
};

Value? _$JsonConverterFromJson<Json, Value>(
  Object? json,
  Value? Function(Json json) fromJson,
) =>
    json == null ? null : fromJson(json as Json);

const _$TextPosEnumMap = {
  TextPos.above: 'above',
  TextPos.below: 'below',
  TextPos.left: 'left',
  TextPos.right: 'right',
  TextPos.inside: 'inside',
};

ExtraStatusBit _$ExtraStatusBitFromJson(Map<String, dynamic> json) =>
    ExtraStatusBit(
      key: json['key'] as String,
      label: json['label'] as String,
      onRole: $enumDecodeNullable(_$HmiColorRoleEnumMap, json['onRole'],
              unknownValue: HmiColorRole.green) ??
          HmiColorRole.green,
    );

Map<String, dynamic> _$ExtraStatusBitToJson(ExtraStatusBit instance) =>
    <String, dynamic>{
      'key': instance.key,
      'label': instance.label,
      'onRole': _$HmiColorRoleEnumMap[instance.onRole]!,
    };

const _$HmiColorRoleEnumMap = {
  HmiColorRole.green: 'green',
  HmiColorRole.yellow: 'yellow',
  HmiColorRole.blue: 'blue',
  HmiColorRole.grey: 'grey',
  HmiColorRole.red: 'red',
  HmiColorRole.violet: 'violet',
  HmiColorRole.primary: 'primary',
  HmiColorRole.secondary: 'secondary',
  HmiColorRole.tertiary: 'tertiary',
  HmiColorRole.error: 'error',
  HmiColorRole.surface: 'surface',
  HmiColorRole.onSurface: 'onSurface',
};

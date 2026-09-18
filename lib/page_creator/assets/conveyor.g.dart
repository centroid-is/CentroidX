// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'conveyor.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ConveyorTurnEntry _$ConveyorTurnEntryFromJson(Map<String, dynamic> json) =>
    ConveyorTurnEntry(
      position: (json['position'] as num?)?.toDouble() ?? 0.5,
      angle: (json['angle'] as num?)?.toDouble() ?? 45,
      radius: (json['radius'] as num?)?.toDouble() ?? 1.5,
    );

Map<String, dynamic> _$ConveyorTurnEntryToJson(ConveyorTurnEntry instance) =>
    <String, dynamic>{
      'position': instance.position,
      'angle': instance.angle,
      'radius': instance.radius,
    };

ConveyorColorPaletteConfig _$ConveyorColorPaletteConfigFromJson(
        Map<String, dynamic> json) =>
    ConveyorColorPaletteConfig()
      ..variant = json['asset_name'] as String
      ..id = json['id'] as String?
      ..coordinates =
          Coordinates.fromJson(json['coordinates'] as Map<String, dynamic>)
      ..size = RelativeSize.fromJson(json['size'] as Map<String, dynamic>)
      ..text = json['text'] as String?
      ..textPos = $enumDecodeNullable(_$TextPosEnumMap, json['textPos'])
      ..techDocId = (json['techDocId'] as num?)?.toInt()
      ..plcAssetKey = json['plcAssetKey'] as String?
      ..preview = json['preview'] as bool?;

Map<String, dynamic> _$ConveyorColorPaletteConfigToJson(
        ConveyorColorPaletteConfig instance) =>
    <String, dynamic>{
      'asset_name': instance.variant,
      if (instance.id case final value?) 'id': value,
      'coordinates': instance.coordinates.toJson(),
      'size': instance.size.toJson(),
      'text': instance.text,
      'textPos': _$TextPosEnumMap[instance.textPos],
      'techDocId': instance.techDocId,
      'plcAssetKey': instance.plcAssetKey,
      'preview': instance.preview,
    };

const _$TextPosEnumMap = {
  TextPos.above: 'above',
  TextPos.below: 'below',
  TextPos.left: 'left',
  TextPos.right: 'right',
  TextPos.inside: 'inside',
};

ConveyorConfig _$ConveyorConfigFromJson(Map<String, dynamic> json) =>
    ConveyorConfig(
      key: json['key'] as String?,
      batchesKey: json['batchesKey'] as String?,
      batchArrayKey: json['batchArrayKey'] as String?,
      batchLengthKey: json['batchLengthKey'] as String?,
      frequencyKey: json['frequencyKey'] as String?,
      tripKey: json['tripKey'] as String?,
      runningKey: json['runningKey'] as String?,
      simulateBatches: json['simulateBatches'] as bool?,
      load: $enumDecodeNullable(_$ConveyorLoadEnumMap, json['load']),
      palletOrientation: $enumDecodeNullable(
          _$PalletOrientationEnumMap, json['palletOrientation']),
      bidirectional: json['bidirectional'] as bool?,
      reverseDirection: json['reverseDirection'] as bool?,
      showFrequency: json['showFrequency'] as bool?,
      showAuger: json['showAuger'] as bool?,
      augerRpmKey: json['augerRpmKey'] as String?,
      augerOpenEnd:
          $enumDecodeNullable(_$AugerOpenEndEnumMap, json['augerOpenEnd']),
      onRails: json['onRails'] as bool?,
      positionKey: json['positionKey'] as String?,
      wagonMotorKey: json['wagonMotorKey'] as String?,
      beltAlongRails: json['beltAlongRails'] as bool?,
      safetyLeftKey: json['safetyLeftKey'] as String?,
      safetyRightKey: json['safetyRightKey'] as String?,
      stationsKey: json['stationsKey'] as String?,
      wagonName: json['wagonName'] as String?,
      stationLockHelp: json['stationLockHelp'] as String?,
      invertSafetyPolarity: json['invertSafetyPolarity'] as bool? ?? false,
      wagonLength: (json['wagonLength'] as num?)?.toDouble(),
      beltThickness: (json['beltThickness'] as num?)?.toDouble(),
      gates: _gatesFromJson(json['gates'] as List?),
      turns: (json['turns'] as List<dynamic>?)
          ?.map((e) => ConveyorTurnEntry.fromJson(e as Map<String, dynamic>))
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
      ..beltWidthRelative = (json['beltWidthRelative'] as num?)?.toDouble();

Map<String, dynamic> _$ConveyorConfigToJson(ConveyorConfig instance) =>
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
      'batchesKey': instance.batchesKey,
      'batchArrayKey': instance.batchArrayKey,
      'batchLengthKey': instance.batchLengthKey,
      'frequencyKey': instance.frequencyKey,
      'tripKey': instance.tripKey,
      'runningKey': instance.runningKey,
      'simulateBatches': instance.simulateBatches,
      'load': _$ConveyorLoadEnumMap[instance.load],
      'palletOrientation':
          _$PalletOrientationEnumMap[instance.palletOrientation],
      'bidirectional': instance.bidirectional,
      'reverseDirection': instance.reverseDirection,
      'showFrequency': instance.showFrequency,
      'showAuger': instance.showAuger,
      'augerRpmKey': instance.augerRpmKey,
      'augerOpenEnd': _$AugerOpenEndEnumMap[instance.augerOpenEnd],
      'onRails': instance.onRails,
      'positionKey': instance.positionKey,
      'wagonMotorKey': instance.wagonMotorKey,
      'beltAlongRails': instance.beltAlongRails,
      'safetyLeftKey': instance.safetyLeftKey,
      'safetyRightKey': instance.safetyRightKey,
      'stationsKey': instance.stationsKey,
      'wagonName': instance.wagonName,
      'stationLockHelp': instance.stationLockHelp,
      'invertSafetyPolarity': instance.invertSafetyPolarity,
      'wagonLength': instance.wagonLength,
      'gates': _gatesToJson(instance.gates),
      'turns': instance.turns.map((e) => e.toJson()).toList(),
      'beltThickness': instance.beltThickness,
      'beltWidthRelative': instance.beltWidthRelative,
    };

const _$ConveyorLoadEnumMap = {
  ConveyorLoad.box: 'box',
  ConveyorLoad.euroPallet: 'euroPallet',
};

const _$PalletOrientationEnumMap = {
  PalletOrientation.alongBelt: 'alongBelt',
  PalletOrientation.acrossBelt: 'acrossBelt',
};

const _$AugerOpenEndEnumMap = {
  AugerOpenEnd.left: 'left',
  AugerOpenEnd.right: 'right',
};

RollerConveyorConfig _$RollerConveyorConfigFromJson(
        Map<String, dynamic> json) =>
    RollerConveyorConfig(
      key: json['key'] as String?,
      batchesKey: json['batchesKey'] as String?,
      batchArrayKey: json['batchArrayKey'] as String?,
      batchLengthKey: json['batchLengthKey'] as String?,
      frequencyKey: json['frequencyKey'] as String?,
      tripKey: json['tripKey'] as String?,
      runningKey: json['runningKey'] as String?,
      simulateBatches: json['simulateBatches'] as bool?,
      load: $enumDecodeNullable(_$ConveyorLoadEnumMap, json['load']),
      palletOrientation: $enumDecodeNullable(
          _$PalletOrientationEnumMap, json['palletOrientation']),
      bidirectional: json['bidirectional'] as bool?,
      reverseDirection: json['reverseDirection'] as bool?,
      showFrequency: json['showFrequency'] as bool?,
      showAuger: json['showAuger'] as bool?,
      augerRpmKey: json['augerRpmKey'] as String?,
      augerOpenEnd:
          $enumDecodeNullable(_$AugerOpenEndEnumMap, json['augerOpenEnd']),
      onRails: json['onRails'] as bool?,
      positionKey: json['positionKey'] as String?,
      wagonMotorKey: json['wagonMotorKey'] as String?,
      beltAlongRails: json['beltAlongRails'] as bool?,
      safetyLeftKey: json['safetyLeftKey'] as String?,
      safetyRightKey: json['safetyRightKey'] as String?,
      stationsKey: json['stationsKey'] as String?,
      wagonName: json['wagonName'] as String?,
      stationLockHelp: json['stationLockHelp'] as String?,
      invertSafetyPolarity: json['invertSafetyPolarity'] as bool? ?? false,
      wagonLength: (json['wagonLength'] as num?)?.toDouble(),
      beltThickness: (json['beltThickness'] as num?)?.toDouble(),
      gates: _gatesFromJson(json['gates'] as List?),
      turns: (json['turns'] as List<dynamic>?)
          ?.map((e) => ConveyorTurnEntry.fromJson(e as Map<String, dynamic>))
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
      ..beltWidthRelative = (json['beltWidthRelative'] as num?)?.toDouble();

Map<String, dynamic> _$RollerConveyorConfigToJson(
        RollerConveyorConfig instance) =>
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
      'batchesKey': instance.batchesKey,
      'batchArrayKey': instance.batchArrayKey,
      'batchLengthKey': instance.batchLengthKey,
      'frequencyKey': instance.frequencyKey,
      'tripKey': instance.tripKey,
      'runningKey': instance.runningKey,
      'simulateBatches': instance.simulateBatches,
      'load': _$ConveyorLoadEnumMap[instance.load],
      'palletOrientation':
          _$PalletOrientationEnumMap[instance.palletOrientation],
      'bidirectional': instance.bidirectional,
      'reverseDirection': instance.reverseDirection,
      'showFrequency': instance.showFrequency,
      'showAuger': instance.showAuger,
      'augerRpmKey': instance.augerRpmKey,
      'augerOpenEnd': _$AugerOpenEndEnumMap[instance.augerOpenEnd],
      'onRails': instance.onRails,
      'positionKey': instance.positionKey,
      'wagonMotorKey': instance.wagonMotorKey,
      'beltAlongRails': instance.beltAlongRails,
      'safetyLeftKey': instance.safetyLeftKey,
      'safetyRightKey': instance.safetyRightKey,
      'stationsKey': instance.stationsKey,
      'wagonName': instance.wagonName,
      'stationLockHelp': instance.stationLockHelp,
      'invertSafetyPolarity': instance.invertSafetyPolarity,
      'wagonLength': instance.wagonLength,
      'gates': _gatesToJson(instance.gates),
      'turns': instance.turns.map((e) => e.toJson()).toList(),
      'beltThickness': instance.beltThickness,
      'beltWidthRelative': instance.beltWidthRelative,
    };

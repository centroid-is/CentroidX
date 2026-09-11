// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ethercat_asset.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Map<String, dynamic> _$EtherCatAssetToJson(EtherCatAsset instance) =>
    <String, dynamic>{
      'assetName': instance.assetName,
      'asset_name': instance.variant,
      'displayName': instance.displayName,
      'category': instance.category,
      if (instance.id case final value?) 'id': value,
      'coordinates': instance.coordinates.toJson(),
      'size': instance.size.toJson(),
      'text': instance.text,
      'textPos': _$TextPosEnumMap[instance.textPos],
      'techDocId': instance.techDocId,
      'plcAssetKey': instance.plcAssetKey,
      if (instance.ecSubDevice?.toJson() case final value?)
        'ecSubDevice': value,
    };

const _$TextPosEnumMap = {
  TextPos.above: 'above',
  TextPos.below: 'below',
  TextPos.left: 'left',
  TextPos.right: 'right',
  TextPos.inside: 'inside',
};

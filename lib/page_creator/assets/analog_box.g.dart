// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'analog_box.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

AnalogBoxConfig _$AnalogBoxConfigFromJson(Map<String, dynamic> json) =>
    AnalogBoxConfig(
      analogKey: json['analog_key'] as String,
      analogSensorRangeMinKey: json['analog_sensor_range_min_key'] as String?,
      analogSensorRangeMaxKey: json['analog_sensor_range_max_key'] as String?,
      setpoint1Key: json['setpoint1_key'] as String?,
      setpoint1HysteresisKey: json['setpoint1_hysteresis_key'] as String?,
      setpoint2Key: json['setpoint2_key'] as String?,
      errorKey: json['error_key'] as String?,
      minValue: (json['min_value'] as num?)?.toDouble() ?? 0,
      maxValue: (json['max_value'] as num?)?.toDouble() ?? 100,
      units: json['units'] as String?,
      rangeUnits: json['range_units'] as String?,
      borderRadiusPct: (json['border_radius_pct'] as num?)?.toDouble() ?? .15,
      vertical: json['vertical'] as bool? ?? true,
      reverseFill: json['reverse_fill'] as bool? ?? false,
      bgColor: json['bg_color'] == null
          ? const Color(0xFFEFEFEF)
          : const ColorConverter()
              .fromJson(json['bg_color'] as Map<String, dynamic>),
      fillColor: json['fill_color'] == null
          ? const Color(0xFF6EC1E4)
          : const ColorConverter()
              .fromJson(json['fill_color'] as Map<String, dynamic>),
      setpoint1Color: json['sp1_color'] == null
          ? Colors.red
          : const ColorConverter()
              .fromJson(json['sp1_color'] as Map<String, dynamic>),
      setpoint2Color: json['sp2_color'] == null
          ? Colors.orange
          : const ColorConverter()
              .fromJson(json['sp2_color'] as Map<String, dynamic>),
      hysteresisColor: json['hyst_color'] == null
          ? const Color(0x44FF0000)
          : const ColorConverter()
              .fromJson(json['hyst_color'] as Map<String, dynamic>),
      showName: json['show_name'] as bool? ?? true,
      enableDialog: json['enable_dialog'] as bool? ?? true,
      graphConfig: json['graph_config'] == null
          ? null
          : GraphAssetConfig.fromJson(
              json['graph_config'] as Map<String, dynamic>),
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

Map<String, dynamic> _$AnalogBoxConfigToJson(AnalogBoxConfig instance) =>
    <String, dynamic>{
      'asset_name': instance.variant,
      if (instance.id case final value?) 'id': value,
      'coordinates': instance.coordinates.toJson(),
      'size': instance.size.toJson(),
      'text': instance.text,
      'textPos': _$TextPosEnumMap[instance.textPos],
      'techDocId': instance.techDocId,
      'plcAssetKey': instance.plcAssetKey,
      'analog_key': instance.analogKey,
      'analog_sensor_range_min_key': instance.analogSensorRangeMinKey,
      'analog_sensor_range_max_key': instance.analogSensorRangeMaxKey,
      'setpoint1_key': instance.setpoint1Key,
      'setpoint1_hysteresis_key': instance.setpoint1HysteresisKey,
      'setpoint2_key': instance.setpoint2Key,
      'error_key': instance.errorKey,
      'min_value': instance.minValue,
      'max_value': instance.maxValue,
      'units': instance.units,
      'range_units': instance.rangeUnits,
      'border_radius_pct': instance.borderRadiusPct,
      'vertical': instance.vertical,
      'reverse_fill': instance.reverseFill,
      'bg_color': const ColorConverter().toJson(instance.bgColor),
      'fill_color': const ColorConverter().toJson(instance.fillColor),
      'sp1_color': const ColorConverter().toJson(instance.setpoint1Color),
      'sp2_color': const ColorConverter().toJson(instance.setpoint2Color),
      'hyst_color': const ColorConverter().toJson(instance.hysteresisColor),
      'show_name': instance.showName,
      'enable_dialog': instance.enableDialog,
      'graph_config': instance.graphConfig?.toJson(),
    };

const _$TextPosEnumMap = {
  TextPos.above: 'above',
  TextPos.below: 'below',
  TextPos.left: 'left',
  TextPos.right: 'right',
  TextPos.inside: 'inside',
};

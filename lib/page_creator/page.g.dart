// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'page.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

AssetPage _$AssetPageFromJson(Map<String, dynamic> json) => AssetPage(
      menuItem: MenuItem.fromJson(json['menu_item'] as Map<String, dynamic>),
      assets: const AssetListConverter().fromJson(json['assets'] as List),
      mirroringDisabled: json['mirroring_disabled'] as bool,
      zoomPanDisabled: json['zoom_pan_disabled'] as bool? ?? false,
      navigationPriority: (json['navigation_priority'] as num?)?.toInt(),
      published: json['published'] as bool? ?? true,
    );

Map<String, dynamic> _$AssetPageToJson(AssetPage instance) => <String, dynamic>{
      'menu_item': instance.menuItem,
      'assets': const AssetListConverter().toJson(instance.assets),
      'mirroring_disabled': instance.mirroringDisabled,
      'zoom_pan_disabled': instance.zoomPanDisabled,
      'navigation_priority': instance.navigationPriority,
      'published': instance.published,
    };

// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'grafana_panel.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

GrafanaPanelConfig _$GrafanaPanelConfigFromJson(Map<String, dynamic> json) =>
    GrafanaPanelConfig(
      baseUrl: json['base_url'] as String? ?? '',
      dashboardUid: json['dashboard_uid'] as String? ?? '',
      dashboardSlug: json['dashboard_slug'] as String? ?? '',
      panelId: (json['panel_id'] as num?)?.toInt(),
      orgId: (json['org_id'] as num?)?.toInt() ?? 1,
      from: json['from'] as String? ?? 'now-6h',
      to: json['to'] as String? ?? 'now',
      timezone: json['timezone'] as String? ?? '',
      variables: (json['variables'] as Map<String, dynamic>?)?.map(
        (k, e) => MapEntry(k, e as String),
      ),
      extraParams: (json['extra_params'] as Map<String, dynamic>?)?.map(
        (k, e) => MapEntry(k, e as String),
      ),
      refreshSeconds: (json['refresh_seconds'] as num?)?.toInt() ?? 60,
      theme: $enumDecodeNullable(_$GrafanaPanelThemeEnumMap, json['theme']) ??
          GrafanaPanelTheme.auto,
      apiToken: json['api_token'] as String? ?? '',
    )
      ..variant = json['asset_name'] as String
      ..coordinates =
          Coordinates.fromJson(json['coordinates'] as Map<String, dynamic>)
      ..size = RelativeSize.fromJson(json['size'] as Map<String, dynamic>)
      ..text = json['text'] as String?
      ..textPos = $enumDecodeNullable(_$TextPosEnumMap, json['textPos'])
      ..techDocId = (json['techDocId'] as num?)?.toInt()
      ..plcAssetKey = json['plcAssetKey'] as String?;

Map<String, dynamic> _$GrafanaPanelConfigToJson(GrafanaPanelConfig instance) =>
    <String, dynamic>{
      'asset_name': instance.variant,
      'coordinates': instance.coordinates.toJson(),
      'size': instance.size.toJson(),
      'text': instance.text,
      'textPos': _$TextPosEnumMap[instance.textPos],
      'techDocId': instance.techDocId,
      'plcAssetKey': instance.plcAssetKey,
      'base_url': instance.baseUrl,
      'dashboard_uid': instance.dashboardUid,
      'dashboard_slug': instance.dashboardSlug,
      'panel_id': instance.panelId,
      'org_id': instance.orgId,
      'from': instance.from,
      'to': instance.to,
      'timezone': instance.timezone,
      'variables': instance.variables,
      'extra_params': instance.extraParams,
      'refresh_seconds': instance.refreshSeconds,
      'theme': _$GrafanaPanelThemeEnumMap[instance.theme]!,
      'api_token': instance.apiToken,
    };

const _$GrafanaPanelThemeEnumMap = {
  GrafanaPanelTheme.auto: 'auto',
  GrafanaPanelTheme.light: 'light',
  GrafanaPanelTheme.dark: 'dark',
};

const _$TextPosEnumMap = {
  TextPos.above: 'above',
  TextPos.below: 'below',
  TextPos.left: 'left',
  TextPos.right: 'right',
  TextPos.inside: 'inside',
};

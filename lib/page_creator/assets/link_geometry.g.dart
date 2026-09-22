// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'link_geometry.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

LinkEnd _$LinkEndFromJson(Map<String, dynamic> json) => LinkEnd(
      assetId: json['assetId'] as String?,
      port: json['port'] as String?,
      x: (json['x'] as num?)?.toDouble() ?? 0.5,
      y: (json['y'] as num?)?.toDouble() ?? 0.5,
    );

Map<String, dynamic> _$LinkEndToJson(LinkEnd instance) => <String, dynamic>{
      'assetId': instance.assetId,
      'port': instance.port,
      'x': instance.x,
      'y': instance.y,
    };

LinkWaypoint _$LinkWaypointFromJson(Map<String, dynamic> json) => LinkWaypoint(
      pinnedTo: json['pinnedTo'] as String?,
      t: (json['t'] as num?)?.toDouble(),
      n: (json['n'] as num?)?.toDouble(),
      dx: (json['dx'] as num?)?.toDouble(),
      dy: (json['dy'] as num?)?.toDouble(),
      x: (json['x'] as num?)?.toDouble(),
      y: (json['y'] as num?)?.toDouble(),
    );

Map<String, dynamic> _$LinkWaypointToJson(LinkWaypoint instance) =>
    <String, dynamic>{
      'pinnedTo': instance.pinnedTo,
      't': instance.t,
      'n': instance.n,
      'dx': instance.dx,
      'dy': instance.dy,
      if (instance.x case final value?) 'x': value,
      if (instance.y case final value?) 'y': value,
    };

LinkRun _$LinkRunFromJson(Map<String, dynamic> json) => LinkRun(
      from: json['from'] == null
          ? null
          : LinkEnd.fromJson(json['from'] as Map<String, dynamic>),
      to: json['to'] == null
          ? null
          : LinkEnd.fromJson(json['to'] as Map<String, dynamic>),
      waypoints: (json['waypoints'] as List<dynamic>?)
          ?.map((e) => LinkWaypoint.fromJson(e as Map<String, dynamic>))
          .toList(),
      radius: (json['radius'] as num?)?.toDouble() ?? 0.02,
    );

Map<String, dynamic> _$LinkRunToJson(LinkRun instance) => <String, dynamic>{
      'from': instance.from.toJson(),
      'to': instance.to.toJson(),
      'waypoints': instance.waypoints.map((e) => e.toJson()).toList(),
      'radius': instance.radius,
    };

/// The collector's *configuration* types, with no collector behind them.
///
/// A [CollectEntry] rides inside a `KeyMappingEntry`, so anything that parses
/// key mappings has to be able to parse one — including a client whose
/// history lives on the other end of a socket and which has no database, no
/// `StateMan` session and no collector at all. `collector.dart` keeps the
/// machinery and exports this file, so existing imports are unaffected.
///
/// [extractSampleMember] and [extractSampleMembers] come along because they
/// are the decode rules for `sample_members`, and a rule about how to read a
/// row belongs with the type that declares it, not with the thing that writes.
library;

import 'dart:collection';

import 'package:json_annotation/json_annotation.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;

import '../converter/duration_converter.dart';
import '../converter/dynamic_value_converter.dart';
import 'boolean_expression.dart' show ExpressionConfig;
import 'retention_policy.dart';

part 'collect_config.g.dart';

@JsonSerializable(explicitToJson: true)
class CollectEntry {
  String key;
  String? name;
  @DurationMinutesConverter()
  RetentionPolicy retention;
  @DurationMicrosecondsConverter()
  @JsonKey(name: 'sample_interval_us')
  Duration? sampleInterval; // microseconds
  @JsonKey(name: 'sample_expression')
  ExpressionConfig? sampleExpression;

  /// Dotted member paths sampled out of a structured value, e.g.
  /// `[p_stat_xOutput, p_stat_tBlockedFor]` on an FB_Sensor's
  /// `ST_Sensor_HMI` struct.
  ///
  /// Lets the collected key be the struct the HMI already binds to while the
  /// timeseries carries only the chosen members — every sample is one row in
  /// ONE table, stored as an object keyed by these paths. A chart picks a
  /// member out of the row (`GraphSeriesConfig.member`), so several series
  /// can ride the same table. Null/empty collects the whole value — the
  /// legacy behaviour. Members missing from a sample are omitted from its
  /// row; a sample where none resolve is skipped, not inserted.
  @JsonKey(name: 'sample_members')
  List<String>? sampleMembers;

  CollectEntry(
      {required this.key,
      this.name,
      this.sampleInterval,
      this.sampleExpression,
      this.sampleMembers,
      this.retention = const RetentionPolicy(
          dropAfter: Duration(days: 365), scheduleInterval: null)}) {
    name ??= key;
  }
  Map<String, dynamic> toJson() => _$CollectEntryToJson(this);
  static CollectEntry fromJson(Map<String, dynamic> json) =>
      _$CollectEntryFromJson(json);
}

/// The physical table [entry]'s samples are inserted into.
///
/// One function because there are two sides to it. The collector writes rows
/// here; `KeyMappingSeriesResolver` (`relay/key_mapping_series_resolver.dart`)
/// tells a connected client which table to read for a series. A second
/// spelling of the rule compiles, keeps every suite green, and serves a year of
/// history out of a table nothing writes — so both sides call this, and
/// `key_mapping_series_resolver_test.dart` pins that they do.
String collectTableName(CollectEntry entry) => entry.name ?? entry.key;

/// Resolves [path] (dotted member segments) inside a structured [value].
///
/// Returns `null` when any segment is missing or the current level is not a
/// struct — the caller skips that member rather than inserting garbage. Pure
/// function so the decode rules are unit-testable without a database.
DynamicValue? extractSampleMember(DynamicValue value, String path) {
  var current = value;
  for (final segment in path.split('.')) {
    if (!current.isObject || !current.contains(segment)) return null;
    current = current[segment];
  }
  return current;
}

/// Builds the one-row-per-sample object for a `sample_members` collection:
/// each resolvable path becomes a field keyed by the full dotted path.
///
/// Returns `null` when NO member resolves — that sample is skipped entirely.
DynamicValue? extractSampleMembers(DynamicValue value, List<String> members) {
  const converter = DynamicValueConverter();
  final row = LinkedHashMap<String, dynamic>();
  for (final path in members) {
    final member = extractSampleMember(value, path);
    if (member == null) continue;
    row[path] = converter.toJson(member, slim: true);
  }
  if (row.isEmpty) return null;
  return DynamicValue.fromMap(row);
}

// TODO: implement this
// @JsonSerializable()
// class CollectTable {
//   String name;
//   List<CollectEntry> entries;

//   CollectTable({
//     required this.name,
//     required this.entries,
//   });
//   Map<String, dynamic> toJson() => _$CollectTableToJson(this);
//   static CollectTable fromJson(Map<String, dynamic> json) =>
//       _$CollectTableFromJson(json);
// }

@JsonSerializable()
class CollectorConfig {
  bool collect; // if false, no collection will be done
  // List<CollectTable> tables;

  CollectorConfig({this.collect = false});

  Map<String, dynamic> toJson() => _$CollectorConfigToJson(this);
  static CollectorConfig fromJson(Map<String, dynamic> json) =>
      _$CollectorConfigFromJson(json);

  CollectorConfig copyWith({bool? collect}) => CollectorConfig(
        collect: collect ?? this.collect,
      );
}

/// Saved history views: the plain records the history-view methods exchange.
///
/// The eleven history-view methods in `packages/tfc_dart/lib/core/` are mapped
/// verbatim — same names, same semantics — but their *return types* cannot be.
/// `selectHistoryViews` and `listHistoryViewPeriods` return ORM-generated row
/// classes out of a 10,077-line generated file, and `getHistoryViewKeys` /
/// `getHistoryViewGraphs` return `Map<String, Map<String, dynamic>>` untyped
/// bags. Neither can live in a zero-dependency pure-Dart package and neither
/// can cross a socket with its field names intact. So the wire shapes are
/// declared here as plain records with the working code's field names, and the
/// database layer maps its rows onto them. Nothing in this file may import or
/// name a generated row type — that is what keeps database internals off the
/// wire, and it is asserted by grep, not by good intentions.
///
/// Every `DateTime` crosses as UTC epoch milliseconds (an `int`), the protocol
/// package's one timestamp convention, and decodes back as UTC. Construct
/// these records with UTC instants; a local-time `DateTime` still encodes to
/// the correct instant, but the decoded record will not be `==` to it.
///
/// Decoders read known keys, ignore everything else, and default every
/// optional the way the current database code does — a half-written view must
/// render, not crash the chart.
library;

/// One saved view: a name plus the keys and graphs recorded against it.
final class HistoryViewRecord {
  final int id;
  final String name;
  final DateTime createdAt;

  /// Null until the view has been edited.
  final DateTime? updatedAt;

  const HistoryViewRecord({
    required this.id,
    required this.name,
    required this.createdAt,
    this.updatedAt,
  });

  factory HistoryViewRecord.fromJson(Map<String, Object?> json) =>
      HistoryViewRecord(
        id: (json['id'] as num?)?.toInt() ?? 0,
        name: json['name'] as String? ?? '',
        createdAt: _time(json['createdAt']) ?? _epoch,
        updatedAt: _time(json['updatedAt']),
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'createdAt': createdAt.millisecondsSinceEpoch,
        if (updatedAt != null) 'updatedAt': updatedAt!.millisecondsSinceEpoch,
      };

  @override
  bool operator ==(Object other) =>
      other is HistoryViewRecord &&
      other.id == id &&
      other.name == name &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(id, name, createdAt, updatedAt);

  @override
  String toString() => 'HistoryViewRecord($id, $name)';
}

/// One key plotted in a view, with its legend label and axis placement.
final class HistoryViewKeyRecord {
  final String key;

  /// The legend label. Defaults to [key] — both here and in [fromJson] —
  /// mirroring `getHistoryViewKeys`'s `row.alias ?? row.key`: a key with no
  /// alias still needs something to render in the legend.
  final String alias;

  final bool useSecondYAxis;
  final int graphIndex;

  const HistoryViewKeyRecord({
    required this.key,
    String? alias,
    this.useSecondYAxis = false,
    this.graphIndex = 0,
  }) : alias = alias ?? key;

  factory HistoryViewKeyRecord.fromJson(Map<String, Object?> json) =>
      HistoryViewKeyRecord(
        key: json['key'] as String? ?? '',
        alias: json['alias'] as String?,
        useSecondYAxis: json['useSecondYAxis'] as bool? ?? false,
        graphIndex: (json['graphIndex'] as num?)?.toInt() ?? 0,
      );

  Map<String, Object?> toJson() => {
        'key': key,
        'alias': alias,
        'useSecondYAxis': useSecondYAxis,
        'graphIndex': graphIndex,
      };

  @override
  bool operator ==(Object other) =>
      other is HistoryViewKeyRecord &&
      other.key == key &&
      other.alias == alias &&
      other.useSecondYAxis == useSecondYAxis &&
      other.graphIndex == graphIndex;

  @override
  int get hashCode => Object.hash(key, alias, useSecondYAxis, graphIndex);

  @override
  String toString() => 'HistoryViewKeyRecord($key -> $alias, g$graphIndex)';
}

/// Graph-level configuration inside a view: title and axis units.
///
/// The three string fields default to empty rather than null, mirroring
/// `getHistoryViewGraphs`'s `?? ''` — an unlabelled axis renders blank, it
/// does not break the chart.
final class HistoryViewGraphRecord {
  final int graphIndex;
  final String name;
  final String yAxisUnit;
  final String yAxis2Unit;

  const HistoryViewGraphRecord({
    required this.graphIndex,
    this.name = '',
    this.yAxisUnit = '',
    this.yAxis2Unit = '',
  });

  factory HistoryViewGraphRecord.fromJson(Map<String, Object?> json) =>
      HistoryViewGraphRecord(
        graphIndex: (json['graphIndex'] as num?)?.toInt() ?? 0,
        name: json['name'] as String? ?? '',
        yAxisUnit: json['yAxisUnit'] as String? ?? '',
        yAxis2Unit: json['yAxis2Unit'] as String? ?? '',
      );

  Map<String, Object?> toJson() => {
        'graphIndex': graphIndex,
        'name': name,
        'yAxisUnit': yAxisUnit,
        'yAxis2Unit': yAxis2Unit,
      };

  @override
  bool operator ==(Object other) =>
      other is HistoryViewGraphRecord &&
      other.graphIndex == graphIndex &&
      other.name == name &&
      other.yAxisUnit == yAxisUnit &&
      other.yAxis2Unit == yAxis2Unit;

  @override
  int get hashCode => Object.hash(graphIndex, name, yAxisUnit, yAxis2Unit);

  @override
  String toString() => 'HistoryViewGraphRecord(g$graphIndex, $name)';
}

/// A saved time window on a view ("Vakt 1", "síðasta keyrsla").
final class HistoryViewPeriodRecord {
  final int id;
  final int viewId;
  final String name;
  final DateTime startAt;
  final DateTime endAt;
  final DateTime createdAt;

  const HistoryViewPeriodRecord({
    required this.id,
    required this.viewId,
    required this.name,
    required this.startAt,
    required this.endAt,
    required this.createdAt,
  });

  factory HistoryViewPeriodRecord.fromJson(Map<String, Object?> json) =>
      HistoryViewPeriodRecord(
        id: (json['id'] as num?)?.toInt() ?? 0,
        viewId: (json['viewId'] as num?)?.toInt() ?? 0,
        name: json['name'] as String? ?? '',
        startAt: _time(json['startAt']) ?? _epoch,
        endAt: _time(json['endAt']) ?? _epoch,
        createdAt: _time(json['createdAt']) ?? _epoch,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'viewId': viewId,
        'name': name,
        'startAt': startAt.millisecondsSinceEpoch,
        'endAt': endAt.millisecondsSinceEpoch,
        'createdAt': createdAt.millisecondsSinceEpoch,
      };

  @override
  bool operator ==(Object other) =>
      other is HistoryViewPeriodRecord &&
      other.id == id &&
      other.viewId == viewId &&
      other.name == name &&
      other.startAt == startAt &&
      other.endAt == endAt &&
      other.createdAt == createdAt;

  @override
  int get hashCode =>
      Object.hash(id, viewId, name, startAt, endAt, createdAt);

  @override
  String toString() => 'HistoryViewPeriodRecord($id, $name)';
}

/// `getHistoryViewGraphs` is keyed by graph index. JSON objects key by String
/// and graph indexes are ints, so the conversion happens here, at the
/// boundary, exactly once — never in a caller.
Map<String, Object?> historyViewGraphsToJson(
        Map<int, HistoryViewGraphRecord> graphs) =>
    _stringKeyed(graphs, (g) => g.toJson());

/// Inverse of [historyViewGraphsToJson]. An absent map decodes to empty: a
/// view with no graph configuration yet is a normal state, not an error.
Map<int, HistoryViewGraphRecord> historyViewGraphsFromJson(Object? raw) =>
    _intKeyed(
        raw,
        (v) => HistoryViewGraphRecord.fromJson(
            (v as Map).cast<String, Object?>()));

final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

DateTime? _time(Object? raw) => raw == null
    ? null
    : DateTime.fromMillisecondsSinceEpoch((raw as num).toInt(), isUtc: true);

// JSON objects key by String; graph indexes are ints. Convert at the boundary.
Map<int, V> _intKeyed<V>(Object? raw, V Function(Object?) decode) {
  if (raw == null) return const {};
  return (raw as Map).cast<String, Object?>().map(
        (k, v) => MapEntry(int.parse(k), decode(v)),
      );
}

Map<String, Object?> _stringKeyed<V>(
        Map<int, V> map, Object? Function(V) encode) =>
    map.map((k, v) => MapEntry('$k', encode(v)));

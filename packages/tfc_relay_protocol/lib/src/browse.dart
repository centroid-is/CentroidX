/// Protocol-agnostic browse tree shapes.
///
/// Mirrors the declarations the page editor already consumes through both the
/// OPC UA and UMAS browse panels (`lib/widgets/browse_panel.dart:14-57`),
/// field for field — those types are already Flutter-free, so the only thing
/// added here is the JSON discipline they lack. Keeping the field names
/// identical is what lets the existing panels bind to a remote browse source
/// without touching a widget.
///
/// **The browse surface is three calls, not one.** Listing children of a path
/// and fetching one node's detail are the obvious two. The third is path
/// resolution, and it is required rather than optional — its contract, carried
/// over verbatim from `BrowseDataSource.resolvePath` (`browse_panel.dart:67-79`)
/// because the doc comment IS the specification:
///
/// > Resolves the full chain of nodes from root to the node identified by
/// > `targetId`, for pre-selection when opening the browse panel with an
/// > already-bound value (e.g. an existing UMAS `variableName` or an OPC-UA
/// > NodeId).
/// >
/// > The returned list MUST be ordered root → … → leaf, with the last entry
/// > being the target node itself. Returns null if the target cannot be
/// > resolved (stale binding) or if the data source does not support
/// > pre-selection.
///
/// Without it, opening the browse panel on an already-bound value over the
/// pipe loses its pre-selection and the operator re-navigates the tree by
/// hand. The chain crosses the wire as a plain JSON list of [BrowseNode]; the
/// root → leaf ordering is the caller's guarantee, not something the decoder
/// can reconstruct.
///
/// Decoders read known keys and ignore everything else (forward
/// compatibility); encoders omit absent optionals and empty collections.
library;

import 'dynamic_value.dart';

/// The type of a node in the browse tree.
enum BrowseNodeType { folder, variable, method, other }

/// A protocol-agnostic node in the browse tree.
///
/// For OPC UA: [id] is the NodeId string (e.g. "ns=2;s=MyVar").
/// For UMAS: [id] is the variable path.
final class BrowseNode {
  final String id;
  final String displayName;
  final BrowseNodeType type;
  final String? dataType;
  final String? description;

  /// Free-form per-protocol annotations (server name, unit, access level).
  /// Defaults to empty and is omitted from JSON when empty: browse results
  /// fan out per keystroke and an empty map is bytes paid for on every node.
  final Map<String, String> metadata;

  const BrowseNode({
    required this.id,
    required this.displayName,
    required this.type,
    this.dataType,
    this.description,
    this.metadata = const {},
  });

  /// An unrecognised [type] name from a newer server degrades to
  /// [BrowseNodeType.other] instead of throwing — same forward-compatibility
  /// rule as `WriteResult`'s default arm. A node kind this panel has never
  /// heard of must not blank the whole tree.
  factory BrowseNode.fromJson(Map<String, Object?> json) => BrowseNode(
        id: json['id'] as String? ?? '',
        displayName: json['displayName'] as String? ?? '',
        type: _browseNodeTypeNamed(json['type'] as String?),
        dataType: json['dataType'] as String?,
        description: json['description'] as String?,
        metadata:
            (json['metadata'] as Map? ?? const {}).cast<String, String>(),
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'displayName': displayName,
        'type': type.name,
        if (dataType != null) 'dataType': dataType,
        if (description != null) 'description': description,
        if (metadata.isNotEmpty) 'metadata': metadata,
      };

  bool get isExpandable =>
      type == BrowseNodeType.folder || type == BrowseNodeType.variable;
  bool get isVariable => type == BrowseNodeType.variable;
  bool get isFolder => type == BrowseNodeType.folder;

  @override
  bool operator ==(Object other) =>
      other is BrowseNode &&
      other.id == id &&
      other.displayName == displayName &&
      other.type == type &&
      other.dataType == dataType &&
      other.description == description &&
      _metadataEqual(other.metadata, metadata);

  @override
  int get hashCode => Object.hash(id, displayName, type, dataType, description,
      _metadataHash(metadata));

  @override
  String toString() => '$displayName ($id)';
}

/// Detail information about a selected node.
final class BrowseNodeDetail {
  final String? description;

  /// The node's current value, as the pipe's one value type — quality and
  /// source timestamp included, so the detail pane can show a stale reading
  /// as stale instead of as a plausible-looking number.
  final DynamicValue? value;

  final String? dataType;

  /// Members, when the node is a structure. `null` means "not a struct";
  /// an empty list means "a struct with no members" — the pane renders those
  /// differently, so the distinction survives the wire.
  final List<BrowseNode>? structChildren;

  const BrowseNodeDetail({
    this.description,
    this.value,
    this.dataType,
    this.structChildren,
  });

  factory BrowseNodeDetail.fromJson(Map<String, Object?> json) =>
      BrowseNodeDetail(
        description: json['description'] as String?,
        value: json['value'] == null
            ? null
            : DynamicValue.fromJson(
                (json['value'] as Map).cast<String, Object?>()),
        dataType: json['dataType'] as String?,
        structChildren: json['structChildren'] == null
            ? null
            : [
                for (final child in json['structChildren'] as List)
                  BrowseNode.fromJson((child as Map).cast<String, Object?>()),
              ],
      );

  Map<String, Object?> toJson() => {
        if (description != null) 'description': description,
        if (value != null) 'value': value!.toJson(),
        if (dataType != null) 'dataType': dataType,
        if (structChildren != null)
          'structChildren': [for (final c in structChildren!) c.toJson()],
      };

  @override
  bool operator ==(Object other) =>
      other is BrowseNodeDetail &&
      other.description == description &&
      other.value == value &&
      other.dataType == dataType &&
      _childrenEqual(other.structChildren, structChildren);

  @override
  int get hashCode => Object.hash(description, value, dataType,
      structChildren == null ? null : Object.hashAll(structChildren!));
}

BrowseNodeType _browseNodeTypeNamed(String? name) {
  if (name == null) return BrowseNodeType.other;
  for (final candidate in BrowseNodeType.values) {
    if (candidate.name == name) return candidate;
  }
  return BrowseNodeType.other;
}

bool _metadataEqual(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}

int _metadataHash(Map<String, String> metadata) {
  var acc = 0;
  for (final entry in metadata.entries) {
    acc ^= Object.hash(entry.key, entry.value);
  }
  return Object.hash(acc, metadata.length);
}

bool _childrenEqual(List<BrowseNode>? a, List<BrowseNode>? b) {
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

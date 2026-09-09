import 'package:flutter/material.dart';
import '../core/opcua_sessions.dart';
import 'package:open62541/open62541.dart'
    show BrowseResultItem, NodeClass, NodeId, ClientApi, DynamicValue;
import 'package:tfc_dart/core/state_man.dart' show StateMan;

import 'browse_panel.dart';

// Re-export generic types so existing importers can still reach them.
export 'browse_panel.dart'
    show BrowseNode, BrowseNodeType, BrowseDataSource, BrowsePanel,
         BrowseNodeTile, VariableDetailStrip, showBrowseDialog;

/// Finds the [ClientApi] for [serverAlias] in [stateMan], opens the OPC UA
/// browse dialog, and returns the selected [BrowseResultItem] (or null).
///
/// Shows a [SnackBar] when no matching client is found.
Future<BrowseResultItem?> browseOpcUaNode({
  required BuildContext context,
  required StateMan stateMan,
  required String? serverAlias,
  String? initialNodeId,
}) async {
  ClientApi? client;
  for (final wrapper in opcUaSessionsOf(stateMan)) {
    if (wrapper.config.serverAlias == serverAlias) {
      client = wrapper.client;
      break;
    }
  }
  if (client == null) {
    if (!context.mounted) return null;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(
              'No client found for alias "${serverAlias ?? "(none)"}"')),
    );
    return null;
  }

  final alias = serverAlias ?? opcUaSessionsOf(stateMan).first.config.endpoint;
  final dataSource = OpcUaBrowseDataSource(client);

  final result = await showBrowseDialog(
    context: context,
    dataSource: dataSource,
    serverAlias: alias,
    initialPath: initialNodeId,
  );

  if (result == null) return null;
  return _toBrowseResultItem(result);
}

/// Adapts an OPC UA [ClientApi] to the protocol-agnostic [BrowseDataSource].
class OpcUaBrowseDataSource implements BrowseDataSource {
  final ClientApi client;

  OpcUaBrowseDataSource(this.client);

  @override
  Future<List<BrowseNode>> fetchRoots() async {
    final results = await client.browse(NodeId.objectsFolder);
    return results.map(_toBrowseNode).toList()
      ..sort((a, b) => a.displayName.compareTo(b.displayName));
  }

  @override
  Future<List<BrowseNode>> fetchChildren(BrowseNode parent) async {
    final nodeId = parseNodeId(parent.id);
    final results = await client.browse(nodeId);
    return results.map(_toBrowseNode).toList()
      ..sort((a, b) => a.displayName.compareTo(b.displayName));
  }

  /// Pre-selection support for OPC-UA. Walks the address space from
  /// `Objects` downwards, choosing at each level the child whose id is
  /// either an exact match for [targetId] or a prefix of it under the
  /// `ns=X;s=A.B.C` dotted-string convention. Falls back to a bounded
  /// BFS (depth-limited by [_kResolveMaxDepth]) when no child looks like
  /// a prefix — covers nodes that don't follow the dotted convention.
  ///
  /// Returns null on failure (unknown target, transport error, depth
  /// exceeded) — never throws so the BrowsePanel can fall back to
  /// empty-selection without surfacing a fatal error.
  @override
  Future<List<BrowseNode>?> resolvePath(String targetId) async {
    if (targetId.isEmpty) return null;
    try {
      final roots = await fetchRoots();
      // Direct hit on a root.
      for (final root in roots) {
        if (root.id == targetId) return [root];
      }
      // Prefix walk: pick at each level the child whose id is a prefix
      // of the target. This handles the dotted `ns=X;s=A.B.C` shape.
      final prefixChain = await _resolveByPrefix(roots, targetId);
      if (prefixChain != null) return prefixChain;
      // Fallback: bounded BFS from each root.
      for (final root in roots) {
        final bfsChain = await _resolveByBfs(root, targetId);
        if (bfsChain != null) return bfsChain;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static const int _kResolveMaxDepth = 8;

  Future<List<BrowseNode>?> _resolveByPrefix(
      List<BrowseNode> roots, String targetId) async {
    BrowseNode? cursor;
    for (final r in roots) {
      if (_isPrefixOf(r.id, targetId)) {
        cursor = r;
        break;
      }
    }
    if (cursor == null) return null;
    final chain = <BrowseNode>[cursor];
    for (var depth = 0; depth < _kResolveMaxDepth; depth++) {
      if (cursor!.id == targetId) return chain;
      final kids = await fetchChildren(cursor);
      BrowseNode? next;
      for (final k in kids) {
        if (k.id == targetId) {
          chain.add(k);
          return chain;
        }
        if (_isPrefixOf(k.id, targetId)) {
          next = k;
          break;
        }
      }
      if (next == null) return null;
      chain.add(next);
      cursor = next;
    }
    return null;
  }

  Future<List<BrowseNode>?> _resolveByBfs(
      BrowseNode root, String targetId) async {
    final visited = <String>{root.id};
    final queue = <List<BrowseNode>>[
      [root]
    ];
    while (queue.isNotEmpty) {
      final path = queue.removeAt(0);
      final node = path.last;
      if (node.id == targetId) return path;
      if (path.length > _kResolveMaxDepth) continue;
      final kids = await fetchChildren(node);
      for (final k in kids) {
        if (!visited.add(k.id)) continue;
        queue.add([...path, k]);
      }
    }
    return null;
  }

  /// `ns=X;s=Foo.Bar` is a prefix of `ns=X;s=Foo.Bar.Baz` under the dotted
  /// convention; bare equality is also accepted.
  static bool _isPrefixOf(String prefix, String full) {
    if (prefix == full) return true;
    return full.startsWith('$prefix.');
  }

  @override
  Future<BrowseNodeDetail> fetchDetail(BrowseNode node) async {
    final nodeId = parseNodeId(node.id);
    final val = await client.read(nodeId);
    return BrowseNodeDetail(
      value: formatDynamicValue(val),
      description: val.description != null && val.description!.value.isNotEmpty
          ? val.description!.value
          : null,
      dataType: val.typeId?.toString(),
      structChildren: _extractStructChildren(val, node, nodeId),
    );
  }

  BrowseNode _toBrowseNode(BrowseResultItem item) {
    return BrowseNode(
      id: item.nodeId.toString(),
      displayName: item.displayName,
      type: _mapNodeClass(item.nodeClass),
      metadata: {
        'nodeId': item.nodeId.toString(),
        'browseName': item.browseName,
        'nodeClass': item.nodeClass.toString(),
      },
    );
  }

  static BrowseNodeType _mapNodeClass(NodeClass nc) {
    switch (nc) {
      case NodeClass.UA_NODECLASS_OBJECT:
      case NodeClass.UA_NODECLASS_VIEW:
        return BrowseNodeType.folder;
      case NodeClass.UA_NODECLASS_VARIABLE:
        return BrowseNodeType.variable;
      case NodeClass.UA_NODECLASS_METHOD:
        return BrowseNodeType.method;
      default:
        return BrowseNodeType.other;
    }
  }

  List<BrowseNode>? _extractStructChildren(
      DynamicValue val, BrowseNode parent, NodeId nodeId) {
    if (val.isObject && nodeId.isString()) {
      final fields = val.asObject;
      return fields.keys.map((fieldName) {
        return BrowseNode(
          id: 'ns=${nodeId.namespace};s=${nodeId.string}.$fieldName',
          displayName: fieldName,
          type: BrowseNodeType.variable,
        );
      }).toList();
    }
    return null;
  }

  /// Parses a NodeId string back to a [NodeId] object.
  ///
  /// Handles formats: `ns=X;i=Y` (numeric) and `ns=X;s=Y` (string).
  @visibleForTesting
  static NodeId parseNodeId(String idStr) {
    final nsMatch = RegExp(r'^ns=(\d+);([si])=(.+)$').firstMatch(idStr);
    if (nsMatch == null) {
      throw ArgumentError('Cannot parse NodeId: "$idStr"');
    }
    final ns = int.parse(nsMatch.group(1)!);
    final type = nsMatch.group(2)!;
    final value = nsMatch.group(3)!;
    if (type == 'i') {
      return NodeId.fromNumeric(ns, int.parse(value));
    } else {
      return NodeId.fromString(ns, value);
    }
  }

  /// Formats a [DynamicValue] for display in the detail strip.
  @visibleForTesting
  static String formatDynamicValue(DynamicValue dv) {
    if (dv.isNull) return 'null';
    if (dv.isArray) {
      final list = dv.asArray;
      if (list.length <= 8) {
        return '[${list.map((e) => formatDynamicValue(e)).join(', ')}]';
      }
      return '[${list.take(6).map((e) => formatDynamicValue(e)).join(', ')}, ... (${list.length})]';
    }
    if (dv.isObject) {
      final map = dv.asObject;
      final keys = map.keys.toList();
      if (keys.length <= 4) {
        return '{${keys.map((k) => '$k: ${formatDynamicValue(map[k]!)}').join(', ')}}';
      }
      return '{${keys.take(3).map((k) => '$k: ${formatDynamicValue(map[k]!)}').join(', ')}, ... (${keys.length} fields)}';
    }
    final s = dv.value?.toString() ?? 'null';
    return s.length > 120 ? '${s.substring(0, 117)}...' : s;
  }
}

/// Converts a protocol-agnostic [BrowseNode] back to a [BrowseResultItem]
/// for backward compatibility with callers expecting OPC UA types.
BrowseResultItem _toBrowseResultItem(BrowseNode node) {
  final nodeId = OpcUaBrowseDataSource.parseNodeId(node.id);
  return BrowseResultItem(
    referenceTypeId: NodeId.fromNumeric(0, 0),
    isForward: true,
    nodeId: nodeId,
    browseName: node.metadata['browseName'] ?? node.displayName,
    displayName: node.displayName,
    nodeClass: _reverseMapNodeClass(node.type),
  );
}

NodeClass _reverseMapNodeClass(BrowseNodeType type) {
  switch (type) {
    case BrowseNodeType.folder:
      return NodeClass.UA_NODECLASS_OBJECT;
    case BrowseNodeType.variable:
      return NodeClass.UA_NODECLASS_VARIABLE;
    case BrowseNodeType.method:
      return NodeClass.UA_NODECLASS_METHOD;
    case BrowseNodeType.other:
      return NodeClass.UA_NODECLASS_UNSPECIFIED;
  }
}

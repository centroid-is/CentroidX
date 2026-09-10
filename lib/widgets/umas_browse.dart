import 'package:flutter/material.dart';
import 'package:tfc_dart/core/umas_client.dart';
import 'package:tfc_dart/core/umas_error_messages.dart';
import 'package:tfc_dart/core/umas_fb_browse_types.dart';
import 'package:tfc_dart/core/umas_types.dart';
import 'package:tfc_dart/core/state_man_types.dart';
import 'package:tfc_dart/core/modbus_device_client.dart';

import 'browse_panel.dart';

/// Adapts a [UmasClient] to the protocol-agnostic [BrowseDataSource].
///
/// Fetches the complete variable tree on first [fetchRoots] call, caches it,
/// and serves subsequent [fetchChildren]/[fetchDetail] calls from the cache.
class UmasBrowseDataSource implements BrowseDataSource {
  final UmasClient _client;
  List<UmasVariableTreeNode>? _tree; // Cached after initial browse
  Map<String, UmasVariableTreeNode>? _pathIndex; // O(1) lookup by path

  UmasBrowseDataSource(this._client);

  @override
  Future<List<BrowseNode>> fetchRoots() async {
    _tree ??= await _client.browse();
    _buildPathIndex(_tree!);
    return _tree!.map(_toBrowseNode).toList();
  }

  void _buildPathIndex(List<UmasVariableTreeNode> roots) {
    _pathIndex = {};
    void index(List<UmasVariableTreeNode> nodes) {
      for (final node in nodes) {
        _pathIndex![node.path] = node;
        index(node.children);
      }
    }
    index(roots);
  }

  @override
  Future<List<BrowseNode>> fetchChildren(BrowseNode parent) async {
    final node = _findTreeNode(parent.id);
    if (node == null) return [];
    return node.children.map(_toBrowseNode).toList();
  }

  @override
  Future<BrowseNodeDetail> fetchDetail(BrowseNode node) async {
    final dataTypeIdStr = node.metadata['dataTypeId'];
    final blockNoStr = node.metadata['blockNo'];
    // Shared lookup for both branches: live FB instances carry the
    // production tree node, including any struct/FB members under
    // `children`. The scalar branch uses this to opt OUT when the node
    // has descendants (FB instance shape), so it doesn't capture
    // browse-tree FB nodes that happen to also carry blockNo +
    // dataTypeId on themselves.
    final tree = _pathIndex?[node.id];
    final hasChildren = tree != null && tree.children.isNotEmpty;
    // Branch 1: scalar leaf — single-ref read, no structChildren. This
    // path is unchanged from v1.0 semantics: folders/arrays return 0x94
    // when hit directly, so reading is only meaningful for scalar
    // leaves carrying blockNo + dataTypeId. FB instances are excluded
    // here via `!hasChildren` — they also carry blockNo + dataTypeId
    // on themselves (the FB lives at a memory address) but have
    // children, so they belong in Branch 2.
    final isScalar = node.type == BrowseNodeType.variable &&
        blockNoStr != null &&
        dataTypeIdStr != null &&
        !hasChildren;
    if (isScalar) {
      String? value;
      try {
        if (_client.blockCrcs == null || _client.blockCrcs!.isEmpty) {
          await _client.readPlcStatus();
        }
        final blockNo = int.parse(blockNoStr);
        final offset = int.parse(node.metadata['offset'] ?? '0');
        final byteSize = int.tryParse(node.metadata['byteSize'] ?? '') ?? 2;
        final dataTypeName = node.metadata['dataTypeName'] ?? '';
        final variable = UmasVariable(
          name: node.displayName,
          blockNo: blockNo,
          offset: offset,
          dataTypeId: int.parse(dataTypeIdStr),
        );
        final dtRef = UmasDataTypeRef(
          id: int.parse(dataTypeIdStr),
          name: dataTypeName,
          byteSize: byteSize,
        );
        final typed = await _client.readVariables([(variable, dtRef)]);
        if (typed.isNotEmpty) {
          value = '${typed.first.value}';
        }
      } catch (e) {
        value = 'read error: $e';
      }
      return BrowseNodeDetail(
        dataType: node.dataType,
        description: node.metadata['path'],
        value: value,
      );
    }

    // Branch 2: FB / struct folder with at least one readable
    // descendant leaf — fan out a single batched read across all
    // readable members and synthesise child BrowseNodes (260519-hgc
    // inspection layer). VAR_IN_OUT members surface as `[not readable:
    // ...]` placeholders without issuing a read for them.
    if (tree != null) {
      final readable = <UmasVariableTreeNode>[];
      final unreadable = <UmasVariableTreeNode>[];
      _collectFbLeaves(tree, readable, unreadable);
      if (readable.isNotEmpty || unreadable.isNotEmpty) {
        return _synthesizeFbChildren(tree, readable, unreadable);
      }
    }

    // Branch 3: default — pure folder / unknown node. No read attempt;
    // no structChildren. Returns just the path as description.
    return BrowseNodeDetail(
      dataType: node.dataType,
      description: node.metadata['path'],
    );
  }

  // Depth-first walk that splits leaves into readable vs unreadable.
  // A leaf is `variable != null && dataType != null`. Sub-folders are
  // recursed into (nested structs inside an FB instance are flattened
  // into the same children list). Encounter order is preserved so the
  // synthesised display order matches the source tree.
  void _collectFbLeaves(
    UmasVariableTreeNode root,
    List<UmasVariableTreeNode> readable,
    List<UmasVariableTreeNode> unreadable,
  ) {
    for (final child in root.children) {
      if (child.variable != null && child.dataType != null) {
        if (child.readable) {
          readable.add(child);
        } else {
          unreadable.add(child);
        }
      } else if (child.children.isNotEmpty) {
        _collectFbLeaves(child, readable, unreadable);
      }
    }
  }

  // Issues the single batched readVariables call and assembles the
  // BrowseNodeDetail. Catches transport errors and surfaces them via
  // `detail.value = 'read error: $e'` with `structChildren = null`,
  // matching the scalar branch's error-style.
  Future<BrowseNodeDetail> _synthesizeFbChildren(
    UmasVariableTreeNode tree,
    List<UmasVariableTreeNode> readable,
    List<UmasVariableTreeNode> unreadable,
  ) async {
    List<TypedVariableValue> values;
    try {
      if (_client.blockCrcs == null || _client.blockCrcs!.isEmpty) {
        await _client.readPlcStatus();
      }
      final pairs = <(UmasVariable, UmasDataTypeRef)>[
        for (final leaf in readable) (leaf.variable!, leaf.dataType!),
      ];
      values = pairs.isEmpty
          ? const <TypedVariableValue>[]
          : await _client.readVariables(pairs);
    } catch (e) {
      return BrowseNodeDetail(
        value: 'read error: $e',
        dataType: tree.dataType?.name,
        description: tree.path,
      );
    }

    final children = <BrowseNode>[];
    for (var i = 0; i < readable.length; i++) {
      final leaf = readable[i];
      final typed = values[i];
      children.add(_fbMemberNode(leaf, value: '${typed.value}'));
    }
    for (final leaf in unreadable) {
      final reason = leaf.unreadableReason ?? 'unknown reason';
      children.add(_fbMemberNode(
        leaf,
        value: '[not readable: $reason]',
        readable: false,
        unreadableReason: leaf.unreadableReason,
      ));
    }

    final summary = _formatFbSummary(readable, unreadable, values);
    return BrowseNodeDetail(
      value: summary,
      dataType: tree.dataType?.name,
      description: tree.path,
      structChildren: children,
    );
  }

  // Builds a BrowseNode for one FB member entry. The synthesised node
  // carries the same blockNo / offset / dataType metadata that
  // `_toBrowseNode` writes for tree leaves (so downstream consumers
  // like BrowseNodeTile keep rendering FB direction badges), plus the
  // rendered `value` under metadata['value'].
  BrowseNode _fbMemberNode(
    UmasVariableTreeNode leaf, {
    required String value,
    bool readable = true,
    String? unreadableReason,
  }) {
    final metadata = <String, String>{
      'path': leaf.path,
      'value': value,
      if (leaf.variable != null) ...{
        'blockNo': leaf.variable!.blockNo.toString(),
        'offset': leaf.variable!.offset.toString(),
        'dataTypeId': leaf.variable!.dataTypeId.toString(),
      },
      if (leaf.dataType != null) ...{
        'dataTypeName': leaf.dataType!.name,
        'byteSize': leaf.dataType!.byteSize.toString(),
      },
    };
    if (leaf.direction != null) {
      metadata.addAll(UmasFbMember.toMetadata(
        direction: leaf.direction!,
        readable: readable,
        unreadableReason: unreadableReason ?? leaf.unreadableReason,
      ));
    }
    return BrowseNode(
      id: leaf.path,
      displayName: leaf.name,
      type: BrowseNodeType.variable,
      dataType: leaf.dataType?.name,
      metadata: metadata,
    );
  }

  // Brace-wrapped value preview for the FB-instance detail strip.
  // Mirrors the OPC-UA `formatDynamicValue` shape: up to 6 entries
  // inline, then `, ... (N fields)` once the total exceeds 6. Unreadable
  // members surface as `name: [n/r]` so the preview's element count
  // honestly matches the total field count.
  String _formatFbSummary(
    List<UmasVariableTreeNode> readable,
    List<UmasVariableTreeNode> unreadable,
    List<TypedVariableValue> values,
  ) {
    final entries = <String>[];
    for (var i = 0; i < readable.length; i++) {
      entries.add('${readable[i].name}: ${values[i].value}');
    }
    for (final u in unreadable) {
      entries.add('${u.name}: [n/r]');
    }
    final total = entries.length;
    if (total <= 6) return '{${entries.join(', ')}}';
    return '{${entries.take(6).join(', ')}, ... ($total fields)}';
  }

  BrowseNode _toBrowseNode(UmasVariableTreeNode treeNode) {
    final metadata = <String, String>{
      'path': treeNode.path,
      if (treeNode.variable != null) ...{
        'blockNo': treeNode.variable!.blockNo.toString(),
        'offset': treeNode.variable!.offset.toString(),
        'dataTypeId': treeNode.variable!.dataTypeId.toString(),
      },
      if (treeNode.dataType != null) ...{
        'dataTypeName': treeNode.dataType!.name,
        'byteSize': treeNode.dataType!.byteSize.toString(),
      },
    };
    // CRIT-2 wiring: surface FB-member affordance state to the UI layer
    // (browse_panel BrowseNodeTile reads these via UmasFbMember.*FromMetadata).
    if (treeNode.direction != null) {
      metadata.addAll(UmasFbMember.toMetadata(
        direction: treeNode.direction!,
        readable: treeNode.readable,
        unreadableReason: treeNode.unreadableReason,
      ));
    }
    return BrowseNode(
      id: treeNode.path,
      displayName: treeNode.name,
      type: treeNode.isFolder
          ? BrowseNodeType.folder
          : BrowseNodeType.variable,
      dataType: treeNode.dataType?.name,
      metadata: metadata,
    );
  }

  UmasVariableTreeNode? _findTreeNode(String path) {
    return _pathIndex?[path];
  }

  /// Pre-selection support: rebuild the chain of ancestors from the
  /// dotted UMAS path. Returns null when the path is unknown to the
  /// cached tree (stale binding) — the panel surfaces that as a hint.
  ///
  /// Tree paths look like `App.GVL.temperature`. The chain is the
  /// successive prefixes: `App`, `App.GVL`, `App.GVL.temperature`.
  @override
  Future<List<BrowseNode>?> resolvePath(String targetId) async {
    if (targetId.isEmpty) return null;
    // Ensure roots (and the path index) are loaded so a freshly-opened
    // dialog can resolve without an explicit prior fetchRoots.
    _tree ??= await _client.browse();
    if (_pathIndex == null) _buildPathIndex(_tree!);

    final leaf = _pathIndex?[targetId];
    if (leaf == null) return null;

    final segments = targetId.split('.');
    final chain = <BrowseNode>[];
    final builder = StringBuffer();
    for (var i = 0; i < segments.length; i++) {
      if (i > 0) builder.write('.');
      builder.write(segments[i]);
      final node = _pathIndex?[builder.toString()];
      if (node == null) return null;
      chain.add(_toBrowseNode(node));
    }
    return chain;
  }
}

/// Maps UMAS exceptions to user-friendly error info.
///
/// TD-018 (v1.1.x): delegates to the shared `mapUmasError` in
/// `tfc_dart/core/umas_error_messages.dart` so the CLI and the Flutter
/// dialog produce identical error guidance.
BrowseErrorInfo? _umasErrorMapper(Object error) {
  final info = mapUmasError(error);
  if (info == null) return null;
  return (summary: info.summary, detail: info.detail);
}

/// Convenience function to open UMAS browse dialog for a Modbus server.
///
/// Finds the [ModbusDeviceClientAdapter] matching [serverAlias] and reuses
/// its shared [UmasClient] (via [ModbusDeviceClientAdapter.umasClient]) so
/// the dialog's fetchDetail reads serialize against the adapter's poll
/// loop instead of opening a duplicate UMAS session on the same TCP
/// socket. See debug session `umas-fb-freeze-loop` (2026-05-19).
Future<BrowseNode?> browseUmasNode({
  required BuildContext context,
  required StateMan stateMan,
  required String? serverAlias,
  String? initialPath,
}) async {
  // Find the ModbusDeviceClientAdapter for this server alias.
  // StateMan exposes `deviceClients: List<DeviceClient>`.
  // There is NO `modbusDeviceClients` field. Filter with whereType.
  ModbusDeviceClientAdapter? adapter;
  for (final dc
      in stateMan.deviceClients.whereType<ModbusDeviceClientAdapter>()) {
    if (dc.serverAlias == serverAlias) {
      adapter = dc;
      break;
    }
  }
  if (adapter == null) {
    if (!context.mounted) return null;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('No Modbus client found for "$serverAlias"')),
    );
    return null;
  }

  // wrapper.client is nullable (ModbusClientTcp?).
  // It is null when the Modbus connection is not established.
  final tcpClient = adapter.wrapper.client;
  if (tcpClient == null) {
    if (!context.mounted) return null;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content:
              Text('Modbus not connected. Connect first, then browse.')),
    );
    return null;
  }

  // BUG (umas-fb-freeze-loop, 2026-05-19): the dialog used to construct
  // its OWN `UmasClient(sendFn: tcpClient.send)` here, which shared the
  // TCP socket with the adapter's poll-loop client but kept a SEPARATE
  // UMAS session (pairing key, hardware id, symbol cache). The M580
  // only supports one paired UMAS session per TCP connection — the
  // dialog's `pair()` invalidated the poll-loop's session, the next
  // poll tripped `_handleSessionError`, both clients raced to re-pair,
  // and the symbol-cache rebuild storm (1077 entries × N round-trips
  // on the main isolate) froze the UI.
  //
  // Fix: borrow the adapter's already-paired client via the public
  // `umasClient` accessor. fetchDetail batched reads now serialize
  // against the poll loop through the client's own `_initLock` /
  // `_withSession`, and the symbol cache is built ONCE per project.
  final umasClient = adapter.umasClient;
  if (umasClient == null) {
    if (!context.mounted) return null;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('UMAS client not ready. Try again in a moment.')),
    );
    return null;
  }
  final dataSource = UmasBrowseDataSource(umasClient);

  return showBrowseDialog(
    context: context,
    dataSource: dataSource,
    serverAlias: serverAlias ?? '',
    errorMapper: _umasErrorMapper,
    initialPath: initialPath,
  );
}

import 'dart:async';
import '../core/opcua_sessions.dart';

import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_mcp_server/tfc_mcp_server.dart'
    show BrowseSource, BrowsedNode, BrowsedNodeType, NodeBrowser;

import '../widgets/browse_panel.dart'
    show BrowseDataSource, BrowseNode, BrowseNodeType;
import '../widgets/opcua_browse.dart' show OpcUaBrowseDataSource;

/// [NodeBrowser] backed by the app's existing browse data sources.
///
/// The key-repository browse panel already knows how to walk both an OPC UA
/// address space behind one `BrowseDataSource`
/// abstraction. This adapts that to the MCP layer rather than growing a
/// second browse implementation that would drift from the one operators see.
/// Only `opcUaSessionsOf(StateMan)` (OPC UA) are enumerated today. UMAS devices live
/// in `StateMan.deviceClients` and would need `UmasBrowseDataSource` wiring in
/// here; the NodeBrowser interface is already protocol-agnostic so that can be
/// added without touching the server package or the tools.
class StateManNodeBrowser implements NodeBrowser {
  StateManNodeBrowser(this._stateMan);

  final StateMan _stateMan;

  /// Cached per alias: the panel's OPC UA source is stateless, but a stateful
  /// caches its tree after the first walk and re-walking is expensive.
  final Map<String, BrowseDataSource> _sources = {};

  /// A browse against a wedged server can sit outstanding indefinitely --
  /// exactly what a wedged PLC looks like from the outside. Fail with
  /// something the operator can act on instead of hanging the tool call.
  static const _timeout = Duration(seconds: 20);

  @override
  List<BrowseSource> get sources => [
        for (final w in opcUaSessionsOf(_stateMan))
          if (w.config.serverAlias != null)
            BrowseSource(
              alias: w.config.serverAlias!,
              protocol: 'opcua',
              endpoint: w.config.endpoint,
            ),
      ];

  BrowseDataSource _sourceFor(String alias) {
    final cached = _sources[alias];
    if (cached != null) return cached;
    for (final w in opcUaSessionsOf(_stateMan)) {
      if (w.config.serverAlias == alias) {
        final src = OpcUaBrowseDataSource(w.client);
        _sources[alias] = src;
        return src;
      }
    }
    final known = sources.map((s) => s.alias).join(', ');
    throw ArgumentError('Unknown server "$alias". Browsable: '
        '${known.isEmpty ? "(none)" : known}');
  }

  @override
  Future<List<BrowsedNode>> browse(String alias, {String? nodeId}) async {
    final source = _sourceFor(alias);
    final List<BrowseNode> children;
    if (nodeId == null || nodeId.isEmpty) {
      children = await source.fetchRoots().timeout(_timeout);
    } else {
      // fetchChildren only reads `id` off the parent, so a stub carrying the
      // id is sufficient -- the caller has an id, not a whole node.
      final parent = BrowseNode(
        id: nodeId,
        displayName: nodeId,
        type: BrowseNodeType.folder,
      );
      children = await source.fetchChildren(parent).timeout(_timeout);
    }
    return children.map(_toBrowsed).toList();
  }

  static BrowsedNode _toBrowsed(BrowseNode n) => BrowsedNode(
        id: n.id,
        name: n.displayName,
        type: switch (n.type) {
          BrowseNodeType.folder => BrowsedNodeType.folder,
          BrowseNodeType.variable => BrowsedNodeType.variable,
          BrowseNodeType.method => BrowsedNodeType.method,
          BrowseNodeType.other => BrowsedNodeType.other,
        },
        dataType: n.dataType,
        description: n.description,
      );
}

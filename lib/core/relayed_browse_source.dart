/// The plant's address space, browsed over the relay.
///
/// ## What this closes
///
/// `browseOpcUaNode` resolves its client from `opcUaSessionsOf(stateMan)`,
/// and a gateway panel holds **no OPC UA session at all** — the sessions are
/// the backend's. So the Browse button in the key repository and in the page
/// editor's key picker answered *"No client found for alias …"* on every
/// relayed panel, and the UMAS half was worse than that: it dialled its own
/// TCP socket **from the panel**, which on a relayed deployment is the wrong
/// network entirely.
///
/// The gateway has served `browse.fetchRoots`, `.fetchChildren`,
/// `.fetchDetail` and `.resolvePath` since Phase 17, graded by
/// `_PolicyBrowse` — including the id-decides rule that stops a caller
/// labelling a hidden variable a folder to read its value. Nothing in the app
/// used them. This is the four-line adapter that does.
///
/// ## Why two `BrowseNode` classes, and why this does not collapse them
///
/// `lib/widgets/browse_panel.dart` declares the UI's node type and
/// `tfc_relay_protocol` declares the wire's. They are field-identical today,
/// and the temptation is to make the panel import the protocol's. It should
/// not: the panel is the one part of this that also serves UMAS and OPC UA
/// sources that have never been near the relay, and giving a widget layer a
/// protocol dependency to save a dozen lines of mapping is how a UI change
/// starts needing a wire version bump. The mapping is written once, here, in
/// both directions.
library;

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

import '../widgets/browse_panel.dart';

/// The wire's node as the panel's.
BrowseNode browseNodeFromWire(relay.BrowseNode node) => BrowseNode(
      id: node.id,
      displayName: node.displayName,
      type: _typeFromWire(node.type),
      dataType: node.dataType,
      description: node.description,
      metadata: node.metadata,
    );

/// The panel's node as the wire's.
///
/// `fetchChildren` and `fetchDetail` take a node the panel is holding, so the
/// mapping has to go both ways. The **id** is what the far end decides by —
/// `_PolicyBrowse._visible` looks the key up by id and never trusts `type`,
/// which is a rendering hint a caller fills in — so a node that crosses here
/// with a wrong `type` cannot be used to read something hidden.
relay.BrowseNode browseNodeToWire(BrowseNode node) => relay.BrowseNode(
      id: node.id,
      displayName: node.displayName,
      type: _typeToWire(node.type),
      dataType: node.dataType,
      description: node.description,
      metadata: node.metadata,
    );

BrowseNodeType _typeFromWire(relay.BrowseNodeType type) => switch (type) {
      relay.BrowseNodeType.folder => BrowseNodeType.folder,
      relay.BrowseNodeType.variable => BrowseNodeType.variable,
      relay.BrowseNodeType.method => BrowseNodeType.method,
      relay.BrowseNodeType.other => BrowseNodeType.other,
    };

relay.BrowseNodeType _typeToWire(BrowseNodeType type) => switch (type) {
      BrowseNodeType.folder => relay.BrowseNodeType.folder,
      BrowseNodeType.variable => relay.BrowseNodeType.variable,
      BrowseNodeType.method => relay.BrowseNodeType.method,
      BrowseNodeType.other => relay.BrowseNodeType.other,
    };

/// Adapts the relay's [relay.BrowseApi] to the panel's [BrowseDataSource].
///
/// Four members, one for one. Everything that decides what a caller may see
/// is at the far end and stays there: this object cannot widen an answer,
/// because it never asks a second question of its own.
final class RelayedBrowseDataSource implements BrowseDataSource {
  RelayedBrowseDataSource(this._api);

  final relay.BrowseApi _api;

  @override
  Future<List<BrowseNode>> fetchRoots() async =>
      [for (final node in await _api.fetchRoots()) browseNodeFromWire(node)];

  @override
  Future<List<BrowseNode>> fetchChildren(BrowseNode parent) async => [
        for (final node in await _api.fetchChildren(browseNodeToWire(parent)))
          browseNodeFromWire(node),
      ];

  @override
  Future<BrowseNodeDetail> fetchDetail(BrowseNode node) async {
    final detail = await _api.fetchDetail(browseNodeToWire(node));
    return BrowseNodeDetail(
      description: detail.description,
      // The panel renders a string; the wire carries the pipe's one value
      // type, quality and source timestamp included. `toString()` is what
      // the OPC UA source does with its own value for the same strip, so the
      // two transports show the same shape of thing.
      value: detail.value?.toString(),
      dataType: detail.dataType,
      structChildren: detail.structChildren == null
          ? null
          : [
              for (final child in detail.structChildren!)
                browseNodeFromWire(child),
            ],
    );
  }

  /// Null when the target cannot be resolved — a stale binding — which is
  /// what the panel's contract asks for and what it renders as "no
  /// pre-selection". A one-element chain would pre-select a node the binding
  /// does not name, and a selection that looks deliberate is one an engineer
  /// binds without checking.
  @override
  Future<List<BrowseNode>?> resolvePath(String targetId) async {
    final chain = await _api.resolvePath(targetId);
    if (chain == null) return null;
    return [for (final node in chain) browseNodeFromWire(node)];
  }
}

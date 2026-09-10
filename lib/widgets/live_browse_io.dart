import 'package:flutter/material.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue, NodeId;
import 'package:tfc_dart/core/state_man_types.dart' show StateMan;

import 'package:collection/collection.dart';

import '../core/opcua_sessions.dart' as browse;
import 'browse_panel.dart' show BrowseNode;
import 'opcua_browse.dart' as browse_dialog;
import 'umas_browse.dart' as umas;

/// Opens the browse dialog and returns the node the user picked, or null if
/// they dismissed it.
Future<NodeId?> browseOpcUaNode({
  required BuildContext context,
  required StateMan stateMan,
  required String? serverAlias,
  String? initialNodeId,
}) async {
  final result = await browse_dialog.browseOpcUaNode(
    context: context,
    stateMan: stateMan,
    serverAlias: serverAlias,
    initialNodeId: initialNodeId,
  );
  return result?.nodeId;
}

/// Reads the node and reports how many elements it holds.
///
/// Throws if this process has no OPC UA session, or if the node is not an
/// array — the field turns both into the message it shows the user.
Future<int> probeOpcUaArrayLength(
  StateMan stateMan, {
  required String? serverAlias,
  required int namespace,
  required String identifier,
}) async {
  final sessions = browse.opcUaSessionsOf(stateMan);
  final wrapper = sessions
          .where((w) => w.config.serverAlias == serverAlias)
          .firstOrNull ??
      sessions.firstOrNull;
  if (wrapper == null) throw Exception('No OPC UA client available');

  final nodeId = int.tryParse(identifier) != null
      ? NodeId.fromNumeric(namespace, int.parse(identifier))
      : NodeId.fromString(namespace, identifier);
  final DynamicValue value =
      await wrapper.client.read(nodeId).timeout(const Duration(seconds: 5));
  if (!value.isArray) throw Exception('Node is not an array');
  return value.asArray.length;
}

/// Opens the UMAS symbol browser and returns the node the user picked.
Future<BrowseNode?> browseUmasNode({
  required BuildContext context,
  required StateMan stateMan,
  required String? serverAlias,
  String? initialPath,
}) =>
    umas.browseUmasNode(
      context: context,
      stateMan: stateMan,
      serverAlias: serverAlias,
      initialPath: initialPath,
    );

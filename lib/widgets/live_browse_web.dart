import 'package:flutter/material.dart';
import 'package:open62541/open62541_types.dart' show NodeId;
import 'package:tfc_dart/core/state_man_types.dart' show StateMan;

/// Always null — the same answer the real dialog gives when the user closes it
/// without choosing a node, so the caller leaves the fields as they were.
///
/// Browsing means holding an OPC UA session open against the server, which a
/// browser tab does not have. The namespace and identifier fields stay
/// editable by hand, which is how a key mapping is written anyway once the
/// node id is known.
Future<NodeId?> browseOpcUaNode({
  required BuildContext context,
  required StateMan stateMan,
  required String? serverAlias,
  String? initialNodeId,
}) async =>
    null;

/// Always throws: probing an array's length means reading the node off a live
/// OPC UA session, and a browser holds none. The field renders the message.
Future<int> probeOpcUaArrayLength(
  StateMan stateMan, {
  required String? serverAlias,
  required int namespace,
  required String identifier,
}) async =>
    throw Exception('No OPC UA client available in the browser');

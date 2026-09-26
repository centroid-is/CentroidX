import 'package:open62541/open62541.dart' show AttributeId, NodeId;
import 'package:tfc_dart/core/state_man_types.dart';

import '../opcua_sessions.dart';
import 'field_descriptions_types.dart';

/// Browses the node behind [configKey] and reads DisplayName and Description
/// off each of its children.
///
/// Returns an empty map — never throws — when there is no session for the
/// key's server alias, which is the normal state in gateway mode. That case
/// used to be a bare `firstWhere` with no `orElse`, i.e. a `StateError` thrown
/// out of `initState` on every Schneider pane opened on a gateway station.
Future<Map<String, FieldDescription>> fetchFieldDescriptions(
  StateMan stateMan,
  String configKey,
) async {
  final key = stateMan.resolveKey(configKey);
  final nodeIdResult = stateMan.keyMappings.lookupNodeId(key);
  if (nodeIdResult == null) return const {};
  final (nodeId, _) = nodeIdResult;

  final alias = stateMan.keyMappings.lookupServerAlias(key);
  final sessions = opcUaSessionsOf(stateMan);
  final wrapper = sessions
      .where((w) => w.config.serverAlias == alias)
      .firstOrNull;
  if (wrapper == null) return const {};

  await wrapper.client.awaitConnect();
  final children = await wrapper.client.browse(nodeId);

  // Batch read descriptions for all children
  final readParams = <NodeId, List<AttributeId>>{};
  for (final child in children) {
    readParams[child.nodeId] = [
      AttributeId.UA_ATTRIBUTEID_DESCRIPTION,
      AttributeId.UA_ATTRIBUTEID_DISPLAYNAME,
    ];
  }
  final results = await wrapper.client.readAttribute(readParams);

  final meta = <String, FieldDescription>{};
  for (final child in children) {
    final val = results[child.nodeId];
    meta[child.browseName] = (
      displayName: val?.displayName?.value,
      description: val?.description?.value,
    );
  }
  return meta;
}

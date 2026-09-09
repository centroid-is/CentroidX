import 'dart:async';

import 'package:test/test.dart';
import 'package:open62541/open62541.dart'
    show AttributeId, ClientApi, DynamicValue, NodeId;
import 'package:tfc_dart/core/state_man.dart';

class ReadAttrClientApi implements ClientApi {
  /// Every readAttribute call the wrapper issued.
  final List<Map<NodeId, List<AttributeId>>> calls = [];

  @override
  Future<void> awaitConnect() async {}

  @override
  Future<Map<NodeId, DynamicValue>> readAttribute(
      Map<NodeId, List<AttributeId>> nodes) async {
    calls.add(nodes);
    return {
      for (final id in nodes.keys) id: DynamicValue(value: id.toString()),
    };
  }

  @override
  Future<void> delete() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  test('readMany returns a value for every OPC UA key on one server',
      () async {
    final fake = ReadAttrClientApi();
    final sm = await OpcUaStateMan.create(
      config: StateManConfig(opcua: []),
      keyMappings: KeyMappings(nodes: {
        'a': KeyMappingEntry(
            opcuaNode: OpcUANodeConfig(namespace: 4, identifier: 'A')),
        'b': KeyMappingEntry(
            opcuaNode: OpcUANodeConfig(namespace: 4, identifier: 'B')),
        'c': KeyMappingEntry(
            opcuaNode: OpcUANodeConfig(namespace: 4, identifier: 'C')),
      }),
    );
    sm.clients.add(ClientWrapper(fake, OpcUAConfig()));

    final result = await sm.readMany(['a', 'b', 'c']);

    expect(fake.calls.single.keys.length, 3,
        reason: 'all three nodes must go into one readAttribute batch, '
            'got ${fake.calls.single.keys.toList()}');
    expect(result.keys.toSet(), {'a', 'b', 'c'},
        reason: 'readMany dropped keys: got ${result.keys.toList()}');

    await sm.close().timeout(const Duration(seconds: 5), onTimeout: () {});
  });
}

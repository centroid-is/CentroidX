/// End-to-end reproduction of the reconnect-refresh abort, shaped the way an
/// operator hits it: a page holding several keys, one PLC node dies, the
/// connection goes quiet and comes back, and the keys that never died must
/// still get their values refreshed.
@TestOn('vm')
library;

import 'dart:async';

import 'package:open62541/open62541.dart'
    show ClientApi, ClientState, DynamicValue, MonitoringMode, NodeId;
import 'package:test/test.dart';
import 'package:tfc_dart/core/state_man.dart';

/// A fake OPC-UA client that hands out one controllable stream per node.
class NodeScriptedClientApi implements ClientApi {
  final monitors = <String, StreamController<DynamicValue>>{};

  @override
  Stream<ClientState> get stateStream => const Stream.empty();

  @override
  Future<void> awaitConnect() async {}

  @override
  Future<void> connect(String url) async {}

  @override
  Future<int> subscriptionCreate({
    Duration requestedPublishingInterval = const Duration(milliseconds: 100),
    int requestedLifetimeCount = 10000,
    int requestedMaxKeepAliveCount = 10,
    int maxNotificationsPerPublish = 0,
    bool publishingEnabled = true,
    int priority = 0,
  }) async =>
      1;

  @override
  Stream<DynamicValue> monitor(
    NodeId nodeId,
    int subscriptionId, {
    MonitoringMode monitoringMode = MonitoringMode.UA_MONITORINGMODE_REPORTING,
    Duration samplingInterval = const Duration(milliseconds: 100),
    bool discardOldest = true,
    int queueSize = 1,
    bool deliverBadStatus = false,
  }) {
    final id = nodeId.toString();
    final c = StreamController<DynamicValue>();
    monitors[id] = c;
    c.onListen = () => scheduleMicrotask(() {
          if (!c.isClosed) c.add(DynamicValue(value: 'first:$id'));
        });
    return c.stream;
  }

  @override
  Stream<Map<NodeId, DynamicValue>> monitoredItems(
    dynamic nodes,
    int subscriptionId, {
    MonitoringMode monitoringMode = MonitoringMode.UA_MONITORINGMODE_REPORTING,
    Duration samplingInterval = const Duration(milliseconds: 100),
    bool discardOldest = true,
    int queueSize = 1,
    bool deliverBadStatus = false,
  }) =>
      const Stream.empty();

  @override
  Future<void> delete() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  test(
      'after a node dies and the connection recovers, the surviving keys are '
      'still refreshed', () async {
    final fake = NodeScriptedClientApi();
    final sm = await OpcUaStateMan.create(
      config: StateManConfig(opcua: []),
      keyMappings: KeyMappings(nodes: {
        for (final k in ['dead', 'alive1', 'alive2'])
          k: KeyMappingEntry(
              opcuaNode: OpcUANodeConfig(namespace: 4, identifier: k)
                ..serverAlias = 'plc'),
      }),
    );
    addTearDown(
        () => sm.close().timeout(const Duration(seconds: 5), onTimeout: () {}));
    final wrapper = ClientWrapper(fake, OpcUAConfig()..serverAlias = 'plc');
    sm.clients.add(wrapper);

    // A page mounts three readouts. 'dead' is subscribed first, so it lands
    // first in the wrapper's stream set — the ordering an operator has no
    // control over.
    final received = <String, List<Object?>>{};
    for (final key in ['dead', 'alive1', 'alive2']) {
      received[key] = [];
      final stream = await sm.subscribe(key);
      final sub = stream.listen((v) => received[key]!.add(v.value));
      addTearDown(sub.cancel);
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(received['alive1'], hasLength(1), reason: 'sanity: first values');

    // One node stops reporting and the server tears its monitored item down
    // — a task stopped on the PLC, a symbol removed by a download.
    await fake.monitors['ns=4;s=dead']!.close();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final before = {
      for (final k in ['alive1', 'alive2']) k: received[k]!.length
    };

    // The connection goes quiet and then comes back. This is the whole point
    // of resendOnRecovery: every live readout gets its last value pushed
    // again so the page is not showing pre-outage data with no way to tell.
    wrapper.simulateInactivity();
    wrapper.simulateHeartbeatTick();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(received['alive1']!.length, greaterThan(before['alive1']!),
        reason: 'alive1 was never refreshed after the reconnect. The dead '
            'key is still in ClientWrapper.streams (its dispose callback ran '
            '`w.streams.remove(_subscriptions[key])` AFTER removing the key, '
            'i.e. remove(null)), so _handleRecovery reaches it first, '
            'resendLastValue() throws StateError on its closed subject, and '
            'the loop aborts before every remaining key.');
    expect(received['alive2']!.length, greaterThan(before['alive2']!),
        reason: 'alive2 was never refreshed after the reconnect either.');
  });
}

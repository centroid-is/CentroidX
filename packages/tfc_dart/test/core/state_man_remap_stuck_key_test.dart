import 'dart:async';

import 'package:test/test.dart';
import 'package:open62541/open62541.dart'
    show AttributeId, ClientApi, DynamicValue, MonitoringMode, NodeId;
import 'package:tfc_dart/core/state_man.dart';

/// 'BAD' never emits (a node the PLC accepts but never reports).
/// 'GOOD' emits once every 200 ms.
class TwoNodeClientApi implements ClientApi {
  final List<String> monitored = [];

  @override
  Future<void> awaitConnect() async {}

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
    final name = nodeId.toString();
    monitored.add(name);
    if (name.contains('BAD')) {
      return StreamController<DynamicValue>().stream; // never emits
    }
    return Stream<DynamicValue>.periodic(
        const Duration(milliseconds: 200), (i) => DynamicValue(value: i));
  }

  @override
  Stream<Map<NodeId, DynamicValue>> monitoredItems(
    Map<NodeId, List<AttributeId>> nodes,
    int subscriptionId, {
    MonitoringMode monitoringMode = MonitoringMode.UA_MONITORINGMODE_REPORTING,
    Duration samplingInterval = const Duration(milliseconds: 100),
    bool discardOldest = true,
    int queueSize = 1,
    bool deliverBadStatus = false,
  }) =>
      const Stream<Map<NodeId, DynamicValue>>.empty();

  @override
  Future<void> delete() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

KeyMappingEntry entryFor(String id) => KeyMappingEntry(
    opcuaNode: OpcUANodeConfig(namespace: 4, identifier: id));

void main() {
  test('re-pointing a key that is stuck in subscribe-retry makes it live '
      'and keeps it live', () async {
    final fake = TwoNodeClientApi();
    final sm = await OpcUaStateMan.create(
      config: StateManConfig(opcua: []),
      keyMappings: KeyMappings(nodes: {'k': entryFor('BAD')}),
    );
    sm.clients.add(ClientWrapper(fake, OpcUAConfig()));

    // Never completes for a silent node — the retry loop runs underneath.
    unawaited(sm.subscribe('k').then((s) => s.listen((_) {}, onError: (_) {}),
        onError: (_) {}));

    // Let the first 5s first-value timeout elapse and a retry start.
    await Future<void>.delayed(const Duration(seconds: 7));

    // Operator fixes the mapping: point 'k' at a node that does report.
    final res = sm.updateKeyMappings(KeyMappings(nodes: {'k': entryFor('GOOD')}));
    expect(res.resubscribed, contains('k'),
        reason: 'sanity: the changed key was re-pointed in place');

    final seen = <DynamicValue>[];
    final stream = await sm.subscribe('k');
    final sub = stream.listen(seen.add, onError: (_) {});

    await Future<void>.delayed(const Duration(seconds: 2));
    expect(seen, isNotEmpty, reason: 'the re-pointed key never delivered');

    // The old loop's next retry lands around t=21s. If it is still alive it
    // steals the raw subscription back to the dead node.
    final beforeSteal = seen.length;
    await Future<void>.delayed(const Duration(seconds: 18));
    expect(seen.length, greaterThan(beforeSteal),
        reason: 'the re-pointed key went silent again — the retry loop for '
            'the OLD node id is still running and stole the subscription. '
            'monitor() calls: ${fake.monitored}');

    await sub.cancel();
    await sm.close().timeout(const Duration(seconds: 5), onTimeout: () {});
  }, timeout: const Timeout(Duration(seconds: 90)));
}

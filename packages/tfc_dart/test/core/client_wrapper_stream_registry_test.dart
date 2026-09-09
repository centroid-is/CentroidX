import 'dart:async';

import 'package:test/test.dart';
import 'package:open62541/open62541.dart'
    show AttributeId, ClientApi, DynamicValue, MonitoringMode, NodeId;
import 'package:tfc_dart/core/state_man.dart';

/// A ClientApi whose monitored items are driven by the test.
class DrivableClientApi implements ClientApi {
  final Map<String, StreamController<DynamicValue>> controllers = {};

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
    final c = controllers.putIfAbsent(
        name, () => StreamController<DynamicValue>.broadcast());
    // Deliver a first value so _monitor() returns instead of retrying.
    scheduleMicrotask(() {
      if (!c.isClosed) c.add(DynamicValue(value: 1));
    });
    return c.stream;
  }

  /// Heartbeat: never ticks on its own; the test drives recovery directly.
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

Future<OpcUaStateMan> makeStateMan(
    DrivableClientApi fake, Map<String, KeyMappingEntry> nodes) async {
  final sm = await OpcUaStateMan.create(
    config: StateManConfig(opcua: []),
    keyMappings: KeyMappings(nodes: nodes),
  );
  sm.clients.add(ClientWrapper(fake, OpcUAConfig()..serverAlias = 'plc'));
  return sm;
}

KeyMappingEntry entryFor(String id) => KeyMappingEntry(
      opcuaNode: OpcUANodeConfig(namespace: 4, identifier: id)
        ..serverAlias = 'plc',
    );

void main() {
  test('disposed AutoDisposingStream is removed from ClientWrapper.streams',
      () async {
    final fake = DrivableClientApi();
    final sm = await makeStateMan(fake, {'a': entryFor('A')});
    final wrapper = sm.clients.single;

    final stream = await sm.subscribe('a');
    final sub = stream.listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(wrapper.streams.length, 1, reason: 'monitor registered the stream');

    // The OPC-UA monitored item ends (server closed it / channel torn down).
    await fake.controllers.values.first.close();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // onDone closed the subject and retired the _subscriptions entry.
    expect(wrapper.streams.where((s) => s.isSpent), isEmpty,
        reason: 'a spent stream must not stay in the wrapper set');

    await sub.cancel();
    await sm.close().timeout(const Duration(seconds: 5), onTimeout: () {});
  });

  test('recovery resends every live stream even after one was disposed',
      () async {
    final fake = DrivableClientApi();
    final sm = await makeStateMan(fake, {
      'dead': entryFor('DEAD'),
      'live': entryFor('LIVE'),
    });
    final wrapper = sm.clients.single;

    // 'dead' is registered first, so it is iterated first in _handleRecovery.
    final deadStream = await sm.subscribe('dead');
    final deadSub = deadStream.listen((_) {});
    final liveStream = await sm.subscribe('live');
    final seen = <DynamicValue>[];
    final liveSub = liveStream.listen(seen.add);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(seen.length, 1, reason: 'live got its first value');

    // The 'dead' key's monitored item ends -> its subject closes.
    await fake.controllers[NodeId.fromString(4, 'DEAD').toString()]!.close();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Server goes inactive, then the heartbeat recovers.
    wrapper.simulateInactivity();
    wrapper.simulateHeartbeatTick();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(seen.length, 2,
        reason: 'the live key must be resent on recovery; a spent sibling '
            'in wrapper.streams must not abort the loop');

    await deadSub.cancel();
    await liveSub.cancel();
    await sm.close().timeout(const Duration(seconds: 5), onTimeout: () {});
  });

  test('key-mapping removal does not strand a spent stream in the wrapper',
      () async {
    final fake = DrivableClientApi();
    final sm = await makeStateMan(fake, {
      'gone': entryFor('GONE'),
      'live': entryFor('LIVE'),
    });
    final wrapper = sm.clients.single;

    final goneStream = await sm.subscribe('gone');
    final goneSub = goneStream.listen((_) {}, onError: (_) {});
    final liveStream = await sm.subscribe('live');
    final seen = <DynamicValue>[];
    final liveSub = liveStream.listen(seen.add, onError: (_) {});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(seen.length, 1);

    // Operator deletes the 'gone' key mapping and saves.
    sm.updateKeyMappings(KeyMappings(nodes: {'live': entryFor('LIVE')}));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(wrapper.streams.where((s) => s.isSpent), isEmpty,
        reason: 'removed key left a closed subject in wrapper.streams');

    wrapper.simulateInactivity();
    wrapper.simulateHeartbeatTick();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(seen.length, 2, reason: 'live key must still be resent');

    await goneSub.cancel();
    await liveSub.cancel();
    await sm.close().timeout(const Duration(seconds: 5), onTimeout: () {});
  });

  test('re-pointing a key onto another protocol does not strand its stream',
      () async {
    final fake = DrivableClientApi();
    final sm = await makeStateMan(fake, {
      'moved': entryFor('MOVED'),
      'live': entryFor('LIVE'),
    });
    final wrapper = sm.clients.single;

    final movedStream = await sm.subscribe('moved');
    final movedSub = movedStream.listen((_) {}, onError: (_) {});
    final liveStream = await sm.subscribe('live');
    final seen = <DynamicValue>[];
    final liveSub = liveStream.listen(seen.add, onError: (_) {});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(seen.length, 1);

    // Operator re-points 'moved' from OPC UA at a Modbus register. The old
    // OPC UA stream cannot carry the new routing, so updateKeyMappings
    // completes it -- and must also drop it from the wrapper's resend set.
    sm.updateKeyMappings(KeyMappings(nodes: {
      'moved': KeyMappingEntry(
          modbusNode: ModbusNodeConfig(
              registerType: ModbusRegisterType.holdingRegister, address: 40)),
      'live': entryFor('LIVE'),
    }));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(wrapper.streams.where((s) => s.isSpent), isEmpty,
        reason: 'protocol switch left a closed subject in wrapper.streams');

    wrapper.simulateInactivity();
    wrapper.simulateHeartbeatTick();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(seen.length, 2, reason: 'live key must still be resent');

    await movedSub.cancel();
    await liveSub.cancel();
    await sm.close().timeout(const Duration(seconds: 5), onTimeout: () {});
  });
}

// Every OPC UA client gets a clock watching it, not only the ones some page
// happens to read a key from.
//
// Heartbeats used to start in exactly one place: the lazy path that creates a
// subscription the first time a KEY is monitored on a server. A client that no
// page reads from therefore never got a subscription, never got a heartbeat,
// and had nothing watching it at all. Measured on the station that froze on
// 2026-09-10: seven clients, and exactly ONE "Starting heartbeat" line in the
// whole run -- seventeen minutes in, and only after the second engine rebuild.
//
// That matters because the failure mode a heartbeat exists to catch emits
// nothing. TCP stays established, the secure channel stays formally open, and
// no state event is ever raised again (see docs/opcua-frozen-session-repro.md
// and the note above EffectiveDeviceStatus.opcuaUnhealthy). Only a clock can
// notice it, so a client without one reads "connected" forever.
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';

import 'package:open62541/open62541.dart'
    show
        AttributeId,
        ClientApi,
        ClientState,
        DynamicValue,
        MonitoringMode,
        NodeId,
        SecureChannelState,
        SessionState;
import 'package:test/test.dart';
import 'package:tfc_dart/core/state_man.dart';

/// A client that answers `subscriptionCreate` and feeds the heartbeat's
/// monitored item on demand.
class ScriptedClientApi implements ClientApi {
  ScriptedClientApi({this.subscriptionFailure, this.subscriptionHangs = false});

  /// When set, every `subscriptionCreate` throws this.
  final Object? subscriptionFailure;

  /// When true, `subscriptionCreate` never completes.
  final bool subscriptionHangs;

  int subscriptionCreateCalls = 0;
  final List<int> monitoredItemsSubs = [];
  final StreamController<Map<NodeId, DynamicValue>> heartbeat =
      StreamController<Map<NodeId, DynamicValue>>.broadcast();

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
  }) async {
    subscriptionCreateCalls++;
    if (subscriptionHangs) return Completer<int>().future;
    if (subscriptionFailure != null) throw subscriptionFailure!;
    return 7;
  }

  @override
  Stream<DynamicValue> monitor(
    NodeId nodeId,
    int subscriptionId, {
    MonitoringMode monitoringMode = MonitoringMode.UA_MONITORINGMODE_REPORTING,
    Duration samplingInterval = const Duration(milliseconds: 100),
    bool discardOldest = true,
    int queueSize = 1,
  }) =>
      StreamController<DynamicValue>().stream;

  @override
  Stream<Map<NodeId, DynamicValue>> monitoredItems(
    Map<NodeId, List<AttributeId>> nodes,
    int subscriptionId, {
    MonitoringMode monitoringMode = MonitoringMode.UA_MONITORINGMODE_REPORTING,
    Duration samplingInterval = const Duration(milliseconds: 100),
    bool discardOldest = true,
    int queueSize = 1,
  }) {
    monitoredItemsSubs.add(subscriptionId);
    return heartbeat.stream;
  }

  @override
  Future<void> delete() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Puts [wrapper] into the state a freshly activated session leaves it in.
void markConnected(ClientWrapper wrapper) {
  wrapper.updateConnectionStatus(ClientState(
    channelState: SecureChannelState.UA_SECURECHANNELSTATE_OPEN,
    sessionState: SessionState.UA_SESSIONSTATE_ACTIVATED,
    recoveryStatus: 0,
  ));
}

void main() {
  group('ensureHeartbeat', () {
    test('gives a clock to a client that no key routes to', () async {
      // The exact shape of six of the seven clients on the frozen station.
      final api = ScriptedClientApi();
      final wrapper = ClientWrapper(api, OpcUAConfig());
      addTearDown(wrapper.dispose);

      expect(wrapper.hasHeartbeat, isFalse);
      expect(wrapper.subscriptionId, isNull);

      await wrapper.ensureHeartbeat();

      expect(wrapper.hasHeartbeat, isTrue);
      expect(wrapper.subscriptionId, 7);
      expect(api.monitoredItemsSubs, [7]);
      expect(wrapper.heartbeatUnavailable, isNull);
      expect(wrapper.heartbeatSettled, isTrue);
    });

    test('reuses a subscription the key path already made', () async {
      final api = ScriptedClientApi();
      final wrapper = ClientWrapper(api, OpcUAConfig());
      addTearDown(wrapper.dispose);
      wrapper.subscriptionId = 42;

      await wrapper.ensureHeartbeat();

      expect(api.subscriptionCreateCalls, 0);
      expect(api.monitoredItemsSubs, [42]);
      expect(wrapper.hasHeartbeat, isTrue);
    });

    test('is idempotent -- a second call does not start a second heartbeat',
        () async {
      final api = ScriptedClientApi();
      final wrapper = ClientWrapper(api, OpcUAConfig());
      addTearDown(wrapper.dispose);

      await wrapper.ensureHeartbeat();
      await wrapper.ensureHeartbeat();
      await wrapper.ensureHeartbeat();

      expect(api.subscriptionCreateCalls, 1);
      expect(api.monitoredItemsSubs, [7]);
    });

    test('two concurrent callers create one subscription between them',
        () async {
      final api = ScriptedClientApi();
      final wrapper = ClientWrapper(api, OpcUAConfig());
      addTearDown(wrapper.dispose);

      await Future.wait([wrapper.ensureHeartbeat(), wrapper.ensureHeartbeat()]);

      expect(api.subscriptionCreateCalls, 1);
      expect(wrapper.hasHeartbeat, isTrue);
    });

    test('a client that cannot get a clock says so, loudly and in its status',
        () async {
      // The requirement: a client that cannot be watched must not be silently
      // left unwatched.
      final api = ScriptedClientApi(subscriptionFailure: StateError('refused'));
      final wrapper = ClientWrapper(api, OpcUAConfig());
      addTearDown(wrapper.dispose);
      markConnected(wrapper);
      expect(wrapper.effectiveStatus, EffectiveDeviceStatus.connecting,
          reason: 'inside the start grace, before we know anything');

      await wrapper.ensureHeartbeat();

      expect(wrapper.hasHeartbeat, isFalse);
      expect(wrapper.heartbeatUnavailable, contains('refused'));
      expect(wrapper.lastError, contains('refused'));
      // Not "connected", and not merely "connecting until the grace expires":
      // we know no clock is coming, so the grace has nothing to wait for.
      expect(wrapper.effectiveStatus, EffectiveDeviceStatus.opcuaUnhealthy);
      expect(wrapper.heartbeatSettled, isTrue,
          reason: 'the question has been answered, even though the answer is '
              'no -- startup must not block on it forever');
    });

    test('a failed attempt is retried, and success clears the finding',
        () async {
      final api = ScriptedClientApi(subscriptionFailure: StateError('refused'));
      final wrapper = ClientWrapper(api, OpcUAConfig());
      addTearDown(wrapper.dispose);
      markConnected(wrapper);

      await wrapper.ensureHeartbeat();
      expect(wrapper.heartbeatUnavailable, isNotNull);
      expect(wrapper.effectiveStatus, EffectiveDeviceStatus.opcuaUnhealthy);

      // The server comes good on the next attempt.
      final healthy = ScriptedClientApi();
      final recovered = ClientWrapper(healthy, OpcUAConfig());
      addTearDown(recovered.dispose);
      markConnected(recovered);
      await recovered.ensureHeartbeat();

      expect(recovered.heartbeatUnavailable, isNull);
      expect(recovered.hasHeartbeat, isTrue);
    });

    test('a subscription that never answers does not wedge the caller',
        () async {
      // subscriptionCreate is bounded at 10s inside ensureHeartbeat; without
      // that a server which accepts the channel and never replies would hold
      // the wrapper's SingleWorker forever, and with it every key on it.
      final api = ScriptedClientApi(subscriptionHangs: true);
      final wrapper = ClientWrapper(api, OpcUAConfig());
      addTearDown(wrapper.dispose);
      markConnected(wrapper);

      await wrapper.ensureHeartbeat().timeout(const Duration(seconds: 30));

      expect(wrapper.hasHeartbeat, isFalse);
      expect(wrapper.heartbeatUnavailable, isNotNull,
          reason: 'the timeout is a stated reason, not silence');
    }, timeout: const Timeout(Duration(seconds: 45)));

    test('a client that lost its session gets its clock back', () async {
      // The session-loss path stops the heartbeat and rebuilds it from the
      // keys routed to this server. A server with NO keys has none to rebuild
      // from, so without ensureHeartbeat running after that branch it would
      // come back from a session loss permanently unwatched -- the same hole
      // as never having had a heartbeat, reached by a different road.
      final api = ScriptedClientApi();
      final wrapper = ClientWrapper(api, OpcUAConfig());
      addTearDown(wrapper.dispose);
      markConnected(wrapper);
      await wrapper.ensureHeartbeat();
      expect(wrapper.hasHeartbeat, isTrue);

      // What the session-loss branch does to a wrapper.
      wrapper.subscriptionId = null;
      wrapper.stopHeartbeat();
      expect(wrapper.hasHeartbeat, isFalse);

      await wrapper.ensureHeartbeat();
      expect(wrapper.hasHeartbeat, isTrue);
      expect(api.subscriptionCreateCalls, 2);
    });

    test('a heartbeat tick keeps the client out of unhealthy', () async {
      final api = ScriptedClientApi();
      final wrapper = ClientWrapper(api, OpcUAConfig());
      addTearDown(wrapper.dispose);
      markConnected(wrapper);
      await wrapper.ensureHeartbeat();

      api.heartbeat.add({NodeId.fromNumeric(0, 2258): DynamicValue(value: 1)});
      await Future<void>.delayed(Duration.zero);

      expect(wrapper.effectiveStatus, EffectiveDeviceStatus.connected);

      // The 15 s staleness threshold is deliberately unchanged: it is chosen
      // against the publishing interval, which is clamped well below it, so
      // 15 s of silence means the operator has been looking at frozen values
      // for 15 s.
      wrapper.debugSetLastHeartbeatTick(
          DateTime.now().subtract(ClientWrapper.heartbeatStaleAfter * 2));
      expect(wrapper.effectiveStatus, EffectiveDeviceStatus.opcuaUnhealthy);
    });
  });

  group('StateMan.connectionsSettled', () {
    test('completes once every client has a clock or a stated reason',
        () async {
      final stateMan = await StateMan.create(
        config: StateManConfig(opcua: []),
        keyMappings: KeyMappings(nodes: {}),
      );
      addTearDown(stateMan.close);

      final healthy = ClientWrapper(ScriptedClientApi(), OpcUAConfig());
      final refused = ClientWrapper(
          ScriptedClientApi(subscriptionFailure: StateError('refused')),
          OpcUAConfig());
      stateMan.clients.addAll([healthy, refused]);

      var settled = false;
      unawaited(stateMan.connectionsSettled().then((_) => settled = true));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(settled, isFalse, reason: 'neither client has answered yet');

      await healthy.ensureHeartbeat();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(settled, isFalse, reason: 'one client is still unanswered');

      await refused.ensureHeartbeat();
      await stateMan.connectionsSettled().timeout(const Duration(seconds: 5));
      expect(healthy.hasHeartbeat, isTrue);
      expect(refused.heartbeatUnavailable, isNotNull);
    });

    test('completes immediately when there are no OPC UA clients', () async {
      final stateMan = await StateMan.create(
        config: StateManConfig(opcua: []),
        keyMappings: KeyMappings(nodes: {}),
      );
      addTearDown(stateMan.close);
      await stateMan.connectionsSettled().timeout(const Duration(seconds: 2));
    });

    test('gives up rather than holding a rebuild back forever', () async {
      // A server that never answers must delay an engine rebuild, but not
      // indefinitely -- an operator who has just reconnected would otherwise
      // be left looking at a renderer that is never rebuilt.
      final stateMan = await StateMan.create(
        config: StateManConfig(opcua: []),
        keyMappings: KeyMappings(nodes: {}),
      );
      addTearDown(stateMan.close);
      stateMan.clients.add(
          ClientWrapper(ScriptedClientApi(subscriptionHangs: true), OpcUAConfig()));

      await stateMan
          .connectionsSettled(cap: const Duration(seconds: 2))
          .timeout(const Duration(seconds: 10));
    });

    test('every caller gets the same future', () async {
      final stateMan = await StateMan.create(
        config: StateManConfig(opcua: []),
        keyMappings: KeyMappings(nodes: {}),
      );
      addTearDown(stateMan.close);
      expect(identical(stateMan.connectionsSettled(),
          stateMan.connectionsSettled()), isTrue);
    });
  });
}

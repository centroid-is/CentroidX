// A heartbeat that cannot be created, on a client whose data plane is fine.
//
// The shape of the incident these tests are written from: one of four OPC UA
// clients showed a red "No data" chip while its values were demonstrably
// current — fresher, in fact, than a sibling client the same page was calling
// Connected. On-demand reads against it worked throughout. The session was
// open, its existing subscriptions were delivering sub-second data, and the
// only thing actually broken was that the client could not create the *extra*
// subscription it watches itself with.
//
// Two defects met there:
//
//  1. The client asked the same server for the same subscription every 30 s
//     forever — or, on the worker-busy path, silently stopped asking at all,
//     because the retry timer was cancelled by a call that then returned
//     without arming a new one. Neither is a recovery strategy.
//  2. `heartbeatUnavailable != null` was collapsed into the same status as a
//     frozen session, and that status is rendered "No data". Two people spent
//     half an hour chasing absent data that was never absent.
//
// So these tests pin the failure, not the fix: a client whose heartbeat
// subscription keeps failing must keep a retry armed and back it off, and
// must never report a state that claims data is absent when it is arriving.
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

/// A client whose `subscriptionCreate` fails until [failure] is cleared.
///
/// Deliberately only fails the *create*: `monitoredItems` still works, which
/// is the whole point — the data plane of the real client was healthy.
class FlakyClientApi implements ClientApi {
  FlakyClientApi({this.failure = 'BadTooManySubscriptions'});

  /// Thrown by every `subscriptionCreate` while non-null.
  Object? failure;

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
    final f = failure;
    if (f != null) throw StateError('$f');
    return 11;
  }

  @override
  Stream<DynamicValue> monitor(
    NodeId nodeId,
    int subscriptionId, {
    MonitoringMode monitoringMode = MonitoringMode.UA_MONITORINGMODE_REPORTING,
    Duration samplingInterval = const Duration(milliseconds: 100),
    bool discardOldest = true,
    int queueSize = 1,
    bool deliverBadStatus = false,
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
    // Ignored here, and that is the point: this fake exists to count retries,
    // and it never delivers a sample of either quality. The parameter is
    // carried so the override keeps matching `ClientApi` — the upstream pin
    // added it for PIPE-11's bad-status samples.
    bool deliverBadStatus = false,
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

/// Fail the heartbeat subscription [times] times in a row.
Future<void> failHeartbeat(ClientWrapper wrapper, int times) async {
  for (var i = 0; i < times; i++) {
    await wrapper.ensureHeartbeat();
  }
}

void main() {
  group('a healthy data plane with no heartbeat', () {
    test('is reported as unmonitored, never as "no data"', () async {
      // The incident, in one test. The chip renders opcuaUnhealthy as
      // "No data"; claiming that about a client delivering sub-second values
      // is not a cosmetic mistake, it is the status lying about the plant.
      final api = FlakyClientApi();
      final wrapper = ClientWrapper(api, OpcUAConfig());
      addTearDown(wrapper.dispose);
      markConnected(wrapper);
      // Values are arriving on the subscriptions that already exist.
      wrapper.debugSetLastDataTick(DateTime.now());

      await wrapper.ensureHeartbeat();

      expect(wrapper.hasHeartbeat, isFalse);
      expect(wrapper.heartbeatUnavailable, contains('BadTooManySubscriptions'));
      expect(wrapper.dataPlaneLive, isTrue);
      expect(wrapper.effectiveStatus, EffectiveDeviceStatus.opcuaUnmonitored,
          reason: 'nobody is watching this client -- but its data is fine, '
              'and opcuaUnhealthy is rendered "No data"');
      expect(wrapper.effectiveStatus,
          isNot(EffectiveDeviceStatus.opcuaUnhealthy));
      expect(wrapper.effectiveStatus, isNot(EffectiveDeviceStatus.connected),
          reason: 'an unwatched client is still not a healthy one');
    });

    test('says why, in a sentence an operator can reach', () async {
      // heartbeatUnavailable held the real reason and kept it in the log.
      final api = FlakyClientApi(failure: 'BadTooManyMonitoredItems');
      final wrapper = ClientWrapper(api, OpcUAConfig());
      addTearDown(wrapper.dispose);
      markConnected(wrapper);
      wrapper.debugSetLastDataTick(DateTime.now());

      await wrapper.ensureHeartbeat();

      final detail = wrapper.healthDetail;
      expect(detail, isNotNull);
      expect(detail, contains('BadTooManyMonitoredItems'),
          reason: "the server's own refusal, not a paraphrase of it");
      expect(detail, contains('still arriving'),
          reason: 'and it must not imply the values have stopped');
    });

    test('a stale heartbeat is still "no data" -- that claim is true there',
        () async {
      // The distinction only helps if the other half survives: a heartbeat
      // that started and then went silent DOES mean frozen values.
      final api = FlakyClientApi(failure: null);
      final wrapper = ClientWrapper(api, OpcUAConfig());
      addTearDown(wrapper.dispose);
      markConnected(wrapper);
      await wrapper.ensureHeartbeat();
      expect(wrapper.hasHeartbeat, isTrue);

      wrapper.debugSetLastHeartbeatTick(
          DateTime.now().subtract(ClientWrapper.heartbeatStaleAfter * 2));

      expect(wrapper.effectiveStatus, EffectiveDeviceStatus.opcuaUnhealthy);
      expect(wrapper.healthDetail, contains('frozen'));
    });
  });

  group('the retry chain', () {
    test('survives losing the worker to the key path', () async {
      // The permanent-stuck path. ensureHeartbeat cancels the pending retry
      // before it does anything else; if it then bails out because another
      // caller owns the subscription-creation worker, the chain is over.
      // Nothing else calls ensureHeartbeat on a session that stays activated,
      // so the client sits unmonitored until the process restarts.
      final api = FlakyClientApi();
      final wrapper = ClientWrapper(api, OpcUAConfig());
      addTearDown(wrapper.dispose);
      markConnected(wrapper);

      await wrapper.ensureHeartbeat();
      expect(wrapper.heartbeatUnavailable, isNotNull);
      expect(wrapper.heartbeatRetryArmed, isTrue);

      // The key path takes the worker; the retry lands on top of it.
      expect(await wrapper.worker.doTheWork(), isTrue);
      final pending = wrapper.ensureHeartbeat();
      await Future<void>.delayed(Duration.zero);
      // The key path finishes. Every waiter is told "not you" -- and in the
      // real failure the key path had not started a heartbeat either,
      // because it found a subscription already there.
      wrapper.worker.complete();
      await pending;

      expect(wrapper.hasHeartbeat, isFalse);
      expect(wrapper.heartbeatUnavailable, isNotNull);
      expect(wrapper.heartbeatRetryArmed, isTrue,
          reason: 'losing the worker is a reason to ask again later, not a '
              'reason to stop asking');
    });

    test('survives a disconnect instead of ending on one', () async {
      // A retry that fires while the client is disconnected used to return
      // and arm nothing, leaving recovery entirely to a SESSIONSTATE_ACTIVATED
      // event -- which a frozen session never emits.
      final api = FlakyClientApi();
      final wrapper = ClientWrapper(api, OpcUAConfig());
      addTearDown(wrapper.dispose);
      markConnected(wrapper);
      await wrapper.ensureHeartbeat();
      expect(wrapper.heartbeatRetryArmed, isTrue);

      wrapper.updateConnectionStatus(ClientState(
        channelState: SecureChannelState.UA_SECURECHANNELSTATE_CLOSED,
        sessionState: SessionState.UA_SESSIONSTATE_CLOSED,
        recoveryStatus: 0,
      ));
      expect(wrapper.connectionStatus, ConnectionStatus.disconnected);

      wrapper.debugHeartbeatRetryTick();

      expect(wrapper.heartbeatRetryArmed, isTrue,
          reason: 'still disconnected, so ask again later -- but keep asking');
    });

    test('backs off instead of hammering, and caps the backoff', () {
      // Not politeness. subscriptionCreate runs under a .timeout(10s) and a
      // Dart timeout does not cancel the request, so a server that answers
      // late still creates the subscription and the binding has no
      // DeleteSubscriptions to hand the id back with. A flat 30 s retry can
      // strand 120 subscriptions an hour on the very server that is refusing
      // to make them.
      expect(ClientWrapper.heartbeatRetryDelayFor(0),
          ClientWrapper.heartbeatRetryDelay);
      expect(ClientWrapper.heartbeatRetryDelayFor(1),
          ClientWrapper.heartbeatRetryDelay);
      expect(ClientWrapper.heartbeatRetryDelayFor(2),
          ClientWrapper.heartbeatRetryDelay * 2);
      expect(ClientWrapper.heartbeatRetryDelayFor(3),
          ClientWrapper.heartbeatRetryDelay * 4);
      for (final n in [8, 20, 200, 100000]) {
        expect(ClientWrapper.heartbeatRetryDelayFor(n),
            ClientWrapper.heartbeatRetryMaxDelay,
            reason: 'bounded for any number of failures, including absurd '
                'ones -- an endpoint down for a week must not overflow it');
      }
    });

    test('a heartbeat that finally starts clears the ladder', () async {
      final api = FlakyClientApi();
      final wrapper = ClientWrapper(api, OpcUAConfig());
      addTearDown(wrapper.dispose);
      markConnected(wrapper);

      await failHeartbeat(wrapper, 2);
      expect(wrapper.heartbeatFailures, 2);

      api.failure = null;
      await wrapper.ensureHeartbeat();

      expect(wrapper.hasHeartbeat, isTrue);
      expect(wrapper.heartbeatUnavailable, isNull);
      expect(wrapper.heartbeatFailures, 0);
      expect(wrapper.heartbeatRetryArmed, isFalse);
      expect(wrapper.effectiveStatus, isNot(EffectiveDeviceStatus.opcuaUnmonitored));
    });

    test('dispose ends the chain for good', () async {
      final api = FlakyClientApi();
      final wrapper = ClientWrapper(api, OpcUAConfig());
      markConnected(wrapper);
      await wrapper.ensureHeartbeat();
      expect(wrapper.heartbeatRetryArmed, isTrue);

      wrapper.dispose();

      expect(wrapper.heartbeatRetryArmed, isFalse);
      // The chain re-arms itself, so the flag is what stops it, not the
      // cancel: a re-arm after dispose would leak a timer into every test
      // that builds a StateMan.
      wrapper.debugHeartbeatRetryTick();
      expect(wrapper.heartbeatRetryArmed, isFalse);
    });
  });

  group('data-plane clock', () {
    test('is fed by data items, not by the heartbeat', () async {
      // If the heartbeat fed it, "the data plane is alive" would be true
      // exactly when the heartbeat works -- and the whole point of the clock
      // is to describe the data plane when the heartbeat does not work.
      final api = FlakyClientApi(failure: null);
      final wrapper = ClientWrapper(api, OpcUAConfig());
      addTearDown(wrapper.dispose);
      markConnected(wrapper);
      await wrapper.ensureHeartbeat();

      api.heartbeat.add({NodeId.fromNumeric(0, 2258): DynamicValue(value: 1)});
      await Future<void>.delayed(Duration.zero);

      expect(wrapper.dataPlaneLive, isFalse,
          reason: 'a heartbeat tick is not a data value');

      wrapper.recordDataTick();
      expect(wrapper.dataPlaneLive, isTrue);
    });

    test('"Data age" counts the newest value of any kind', () async {
      // The field is labelled "Data age" on the connection-info card, so it
      // has to mean data. Reading only the heartbeat clock reported a server
      // with a busy data plane and no heartbeat as having ancient data.
      final api = FlakyClientApi();
      final wrapper = ClientWrapper(api, OpcUAConfig());
      addTearDown(wrapper.dispose);
      markConnected(wrapper);
      await wrapper.ensureHeartbeat();

      expect(wrapper.heartbeatAgeSec, -1, reason: 'never ticked');
      wrapper.recordDataTick();

      expect(wrapper.lastDataAgeSec, lessThan(1));
      expect(wrapper.heartbeatAgeSec, -1);
    });
  });
}

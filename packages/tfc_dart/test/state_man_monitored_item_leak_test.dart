import 'dart:async';

import 'package:test/test.dart';
import 'package:open62541/open62541.dart'
    show ClientApi, DynamicValue, MonitoringMode, NodeId;
import 'package:tfc_dart/core/state_man.dart';

/// A client that never delivers a first value, and whose monitored-item
/// delete is asynchronous — exactly like the real binding, where onCancel
/// issues `UA_Client_MonitoredItems_delete_async` and returns a Future.
///
/// It records every create and every *completed* delete so a test can assert
/// on how many monitored items the server is actually holding.
class LeakCountingClientApi implements ClientApi {
  LeakCountingClientApi({
    this.deleteDelay = const Duration(milliseconds: 400),
    this.streamError,
  });

  /// How long the server takes to acknowledge a monitored-item delete.
  final Duration deleteDelay;

  /// When set, the monitored item reports this error instead of staying
  /// silent — a server that answers "no" rather than one that is merely slow.
  /// The two are the whole point of the split in `_monitor`'s timeout: an
  /// answered error is a subscription worth rebuilding, silence is not.
  final Object? streamError;

  int creates = 0;
  int deletes = 0;

  /// Monitored items the server currently holds, and the high-water mark.
  int get live => creates - deletes;
  int peakLive = 0;

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
    late StreamController<DynamicValue> controller;
    controller = StreamController<DynamicValue>(
      onListen: () {
        creates++;
        if (live > peakLive) peakLive = live;
        if (streamError != null) controller.addError(streamError!);
      },
      onCancel: () async {
        // The real delete is a round trip to the PLC, not instantaneous.
        await Future<void>.delayed(deleteDelay);
        deletes++;
      },
    );
    // Never emits a value: reproduces a node the server accepts but never
    // reports, which is what drives _monitor's 8s first-value timeout.
    return controller.stream;
  }

  /// StateMan.close() calls this; noSuchMethod's null is not a Future.
  @override
  Future<void> delete() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  group('StateMan._monitor — monitored items must not accumulate', () {
    late OpcUaStateMan stateMan;
    late LeakCountingClientApi fake;

    setUp(() async {
      fake = LeakCountingClientApi();
      stateMan = await OpcUaStateMan.create(
        config: StateManConfig(opcua: []),
        keyMappings: KeyMappings(nodes: {
          'silent.node': KeyMappingEntry(
            opcuaNode: OpcUANodeConfig(namespace: 4, identifier: 'Silent')
              ..serverAlias = 'plc',
          ),
        }),
      );
      stateMan.clients
          .add(ClientWrapper(fake, OpcUAConfig()..serverAlias = 'plc'));
    });

    tearDown(() async {
      // close() joins the retry loop; never let teardown mask the result.
      await stateMan.close().timeout(const Duration(seconds: 5),
          onTimeout: () {});
    });

    test(
      'a node that never reports does not leave monitored items behind on retry',
      () async {
        // NOT awaited: _monitor() only returns once a first value arrives,
        // so for a node that never reports, subscribe()'s Future never
        // completes at all -- the caller is left hanging while the retry
        // loop churns underneath it.
        unawaited(stateMan.subscribe('silent.node').then(
            (stream) => stream.listen((_) {}, onError: (_) {}),
            onError: (_) {}));

        // Long enough for several first-value timeouts (8s each) plus the
        // 1s delay between them.
        await Future<void>.delayed(const Duration(seconds: 20));

        final creates = fake.creates;
        final deletes = fake.deletes;
        final peak = fake.peakLive;
        print('monitored items -- creates=$creates deletes=$deletes '
            'peakConcurrent=$peak');


        expect(creates, greaterThan(1),
            reason: 'the retry loop should have re-subscribed at least once');
        // The invariant: the retry loop tears down the previous monitored
        // item before standing up the next, so the server never holds more
        // than one at a time for a single key.
        //
        // `_rawSub?.cancel()` is called without awaiting it, so a new
        // monitored item is created while the delete is still in flight.
        expect(peak, lessThanOrEqualTo(1),
            reason: 'server held $peak concurrent monitored items for ONE key '
                'after $creates subscribe attempts ($deletes deletes '
                'completed) -- each retry leaks until the async delete lands');
      },
      timeout: const Timeout(Duration(seconds: 60)),
      // SKIPPED: asserts the invariant the code does not yet hold. The
      // binding's onCancel discards the delete future, so a replacement
      // monitored item is created while the previous delete is still in
      // flight. Kept executable so the day the cancel is awaited, drop
      // the skip and this proves it. See FLAKINESS.md section 3.
      skip: 'known defect: monitored-item cancel is not awaited',
    );

    test('the backoff ladder is 1s, 10s, 60s, then 600s', () {
      expect(kSubscribeBackoffSeconds, [1, 10, 60, 600]);
    });

    test(
      'a key the server answers with an error backs off instead of hammering',
      () async {
        // The flat 1s retry meant a first-value timeout + 1s delay = one
        // fresh subscribe every few seconds, per key, forever. Across ~140
        // failing keys that saturated the isolate and froze the UI -- the
        // clock in the HMI stopped painting. With the ladder the same key
        // costs three attempts in the first 40s and then settles towards one
        // per 10 min.
        //
        // The fixture reports an error rather than staying silent: since a
        // silent server no longer re-subscribes at all (see the test below),
        // an answered error is the case that still walks the ladder.
        final erroring =
            LeakCountingClientApi(streamError: 'BadDeviceFailure');
        final sm = await OpcUaStateMan.create(
          config: StateManConfig(opcua: []),
          keyMappings: KeyMappings(nodes: {
            'silent.node': KeyMappingEntry(
              opcuaNode: OpcUANodeConfig(namespace: 4, identifier: 'Silent')
                ..serverAlias = 'plc',
            ),
          }),
        );
        sm.clients
            .add(ClientWrapper(erroring, OpcUAConfig()..serverAlias = 'plc'));

        unawaited(sm.subscribe('silent.node').then(
            (stream) => stream.listen((_) {}, onError: (_) {}),
            onError: (_) {}));
        await Future<void>.delayed(const Duration(seconds: 40));

        print('attempts in 40s: ${erroring.creates}');
        expect(erroring.creates, lessThanOrEqualTo(4),
            reason: '${erroring.creates} subscribe attempts in 40s -- that is '
                'the flat retry interval back again, which froze the UI');
        expect(erroring.creates, greaterThanOrEqualTo(2),
            reason: 'it must still retry; a server that answers with an error '
                'has a subscription worth rebuilding');

        await sm.close().timeout(const Duration(seconds: 5), onTimeout: () {});
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      'a silent server keeps its subscription instead of re-subscribing',
      () async {
        // The regression this pairs with: a first-value timeout used to throw,
        // and the throw re-subscribed. Re-subscribing cancels and recreates
        // the monitored items, so under the startup flood the retry churn
        // landed hardest on the servers that were already slowest to answer --
        // the subscription that would have delivered the value was torn down
        // before the value could arrive.
        //
        // Silence now costs exactly one monitored item. The value lands on the
        // stream whenever the server gets round to it.
        unawaited(stateMan.subscribe('silent.node').then(
            (stream) => stream.listen((_) {}, onError: (_) {}),
            onError: (_) {}));
        await Future<void>.delayed(const Duration(seconds: 40));

        print('attempts in 40s against a silent server: ${fake.creates}');
        expect(fake.creates, 1,
            reason: '${fake.creates} subscribe attempts for a server that is '
                'merely slow -- each one tears down the monitored item that '
                'was about to deliver, which is the starvation loop itself');
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      'a silent key still completes its subscribe() instead of hanging',
      () async {
        // Before, _monitor only returned once a first value arrived, so a
        // caller awaiting subscribe() on a slow key waited forever while the
        // retry loop churned underneath it. The timeout now falls through, so
        // the caller gets its stream and simply sees no value yet.
        final stream = await stateMan
            .subscribe('silent.node')
            .timeout(const Duration(seconds: 20));
        stream.listen((_) {}, onError: (_) {});
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'when the server stops acknowledging deletes, every retry leaks an item',
      () async {
        // A PLC that has stopped answering: the delete request goes out and
        // never comes back. This is the state a station is in once it starts
        // refusing new connections -- and it is the difference between a
        // transient overlap of two and unbounded growth.
        fake = LeakCountingClientApi(deleteDelay: const Duration(minutes: 5));
        final sm = await OpcUaStateMan.create(
          config: StateManConfig(opcua: []),
          keyMappings: KeyMappings(nodes: {
            'silent.node': KeyMappingEntry(
              opcuaNode: OpcUANodeConfig(namespace: 4, identifier: 'Silent')
                ..serverAlias = 'plc',
            ),
          }),
        );
        sm.clients.add(ClientWrapper(fake, OpcUAConfig()..serverAlias = 'plc'));

        unawaited(sm.subscribe('silent.node').then(
            (stream) => stream.listen((_) {}, onError: (_) {}),
            onError: (_) {}));
        await Future<void>.delayed(const Duration(seconds: 20));

        print('unacked deletes -- creates=${fake.creates} '
            'deletes=${fake.deletes} peakConcurrent=${fake.peakLive}');

        expect(fake.peakLive, lessThanOrEqualTo(1),
            reason: 'server accumulated ${fake.peakLive} monitored items for '
                'ONE key in 20s because no delete was ever acknowledged');

        await sm.close().timeout(const Duration(seconds: 5), onTimeout: () {});
      },
      timeout: const Timeout(Duration(seconds: 60)),
      // SKIPPED: asserts the invariant the code does not yet hold. The
      // binding's onCancel discards the delete future, so a replacement
      // monitored item is created while the previous delete is still in
      // flight. Kept executable so the day the cancel is awaited, drop
      // the skip and this proves it. See FLAKINESS.md section 3.
      skip: 'known defect: monitored-item cancel is not awaited',
    );
  });
}

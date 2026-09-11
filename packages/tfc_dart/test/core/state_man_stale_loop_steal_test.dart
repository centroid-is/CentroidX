// Regression test for the "stale keys" bug: nothing serialized _monitorLoops
// per key, so a superseded loop waking from its backoff ladder tore down the
// raw subscription of the loop that had already succeeded — deleting the live
// monitored items on the PLC — and replaced them with its own attempt. On the
// plant (hmi-pokkun .81, 2026-08-28) whole 280-key cohorts of stale loops woke
// together (17:22:57, 17:24:29) and re-created every st101 key against a
// healthy session; the delete/create storm orphaned monitored items
// server-side ("Could not process a notification with clienthandle N" x8388
// over 21h) and froze individual keys forever while the rest kept updating.
//
// This test scripts the smaller deterministic core: loop A hangs and goes on
// its retry ladder; loop B (started by a key-mapping change) succeeds and
// values flow; then loop A wakes from backoff and — with the old code — steals
// and cancels loop B's live raw stream, freezing the key silently. A
// superseded loop must instead notice it has been replaced and die without
// touching the live stream.
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';

import 'package:open62541/open62541.dart'
    show AttributeId, ClientApi, DynamicValue, MonitoringMode, NodeId;
import 'package:test/test.dart';
import 'package:tfc_dart/core/state_man.dart';

/// Scripted fake:
///  * a node whose id contains 'HANG' never emits (PLC accepts, never reports);
///  * the FIRST monitor() of a node containing 'LIVE' returns the live
///    controller the test feeds; every LATER monitor() of it hangs — the PLC
///    under a re-subscribe storm, where the stolen key's replacement never
///    comes up again.
class StealScriptClientApi implements ClientApi {
  final live = StreamController<DynamicValue>();
  bool liveHandedOut = false;
  bool liveCancelled = false;
  final List<String> monitorCalls = [];

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
    monitorCalls.add(name);
    if (name.contains('LIVE') && !liveHandedOut) {
      liveHandedOut = true;
      live.onCancel = () {
        liveCancelled = true;
      };
      return live.stream;
    }
    return StreamController<DynamicValue>().stream; // never emits
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

KeyMappingEntry entryFor(String id) =>
    KeyMappingEntry(opcuaNode: OpcUANodeConfig(namespace: 4, identifier: id));

void main() {
  test(
      'a superseded _monitorLoop waking from backoff must not tear down the '
      'live stream of the loop that replaced it', () async {
    final fake = StealScriptClientApi();
    final sm = await OpcUaStateMan.create(
      config: StateManConfig(opcua: []),
      keyMappings: KeyMappings(nodes: {'k': entryFor('HANG')}),
    );
    sm.clients.add(ClientWrapper(fake, OpcUAConfig()));

    // Loop A: starts against the silent node, will time out after 5s and go
    // on the 1s/10s/... ladder. Its returned future is irrelevant here.
    unawaited(sm
        .subscribe('k')
        .then((s) => s.listen((_) {}, onError: (_) {}), onError: (_) {}));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // The widget's stream: the entry is registered synchronously, so this is
    // the same ReplaySubject loop B will feed.
    final seen = <Object?>[];
    final stream = await sm.subscribe('k');
    final widgetSub = stream.listen((v) => seen.add(v.value), onError: (_) {});

    // The PLC keeps reporting the LIVE node the whole time.
    final pusher = Timer.periodic(const Duration(milliseconds: 200), (t) {
      if (!fake.live.isClosed) fake.live.add(DynamicValue(value: t.tick));
    });

    // t=1s: the mapping is corrected — loop B replaces loop A and succeeds.
    await Future<void>.delayed(const Duration(seconds: 1));
    final res =
        sm.updateKeyMappings(KeyMappings(nodes: {'k': entryFor('LIVE')}));
    expect(res.resubscribed, contains('k'),
        reason: 'sanity: the changed key was re-pointed in place');

    // Values must flow once loop B is up (sanity for both old and new code).
    await Future<void>.delayed(const Duration(milliseconds: 4400));
    expect(seen, isNotEmpty,
        reason: 'sanity: loop B subscribed the live node and values arrived');

    // Loop A's first-value timeout fires ~5.1s in, its 1s backoff ends ~6.1s
    // in, and with the old code its next attempt cancels loop B's live raw
    // stream and replaces it with one that never emits. From t=7s to t=12s the
    // PLC is still reporting every 200ms — the widget must keep seeing it.
    await Future<void>.delayed(const Duration(milliseconds: 1500)); // t=7s
    final beforeWindow = seen.length;
    await Future<void>.delayed(const Duration(seconds: 5)); // t=12s
    final afterWindow = seen.length;

    expect(fake.liveCancelled, isFalse,
        reason: 'the stale loop A tore down loop B\'s live monitored item — '
            'this is the delete/create churn that orphans items on the PLC');
    expect(afterWindow - beforeWindow, greaterThan(0),
        reason: 'key froze: the PLC reported ~25 values in the window but the '
            'widget saw none — the live stream was stolen by a superseded '
            'retry loop and silently replaced with a dead one');

    pusher.cancel();
    await widgetSub.cancel();
    await sm.close();
  });
}

/// Adversarial tests for [StateMan] / [ClientWrapper] / [AutoDisposingStream]:
/// lifetime, teardown and recovery paths driven from a fake OPC-UA client.
@TestOn('vm')
library;

import 'dart:async';

import 'package:open62541/open62541.dart'
    show
        ClientApi,
        ClientState,
        DynamicValue,
        MonitoringMode,
        NodeId,
        SecureChannelState,
        SessionState;
import 'package:test/test.dart';
import 'package:tfc_dart/core/state_man.dart';

ClientState state(SecureChannelState ch, SessionState se) =>
    ClientState(channelState: ch, sessionState: se, recoveryStatus: 0);

final activated = state(SecureChannelState.UA_SECURECHANNELSTATE_OPEN,
    SessionState.UA_SESSIONSTATE_ACTIVATED);
final closed = state(SecureChannelState.UA_SECURECHANNELSTATE_CLOSED,
    SessionState.UA_SESSIONSTATE_CLOSED);

/// A fake OPC-UA client whose state stream and monitored-item streams are
/// driven by the test.
class ScriptedClientApi implements ClientApi {
  final stateController = StreamController<ClientState>.broadcast();

  /// Controllers handed out by [monitor], newest last.
  final monitors = <StreamController<DynamicValue>>[];

  /// When set, [subscriptionCreate] waits on this instead of returning.
  Completer<int>? subscriptionGate;

  int subscriptionCreateCalls = 0;
  int monitorCalls = 0;
  bool deleted = false;

  @override
  Stream<ClientState> get stateStream => stateController.stream;

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
  }) {
    subscriptionCreateCalls++;
    final gate = subscriptionGate;
    if (gate != null) return gate.future;
    return Future.value(1);
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
  }) {
    monitorCalls++;
    final c = StreamController<DynamicValue>();
    monitors.add(c);
    // Deliver a first value as soon as someone listens, so _monitorLoop
    // completes instead of spinning on its 5s first-value timeout.
    c.onListen = () {
      scheduleMicrotask(() {
        if (!c.isClosed) c.add(DynamicValue(value: 1));
      });
    };
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
  Future<void> delete() async {
    deleted = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Future<StateMan> stateManWith(ScriptedClientApi fake,
    {Map<String, KeyMappingEntry>? nodes}) async {
  final sm = await OpcUaStateMan.create(
    config: StateManConfig(opcua: []),
    keyMappings: KeyMappings(
        nodes: nodes ??
            {
              'a': KeyMappingEntry(
                  opcuaNode: OpcUANodeConfig(namespace: 4, identifier: 'A')
                    ..serverAlias = 'plc'),
            }),
  );
  sm.clients.add(ClientWrapper(fake, OpcUAConfig()..serverAlias = 'plc'));
  return sm;
}

void main() {
  group('StateMan.close()', () {
    test('a client state event after dispose() must not throw', () {
      // StateMan._() installs `wrapper.client.stateStream.listen((value) {
      // wrapper.updateConnectionStatus(value); ... })` (state_man.dart:1210)
      // and NOTHING ever cancels that subscription — not close(), not
      // dispose(). close() calls wrapper.dispose(), which closes
      // _connectionController. The next state event the binding delivers
      // therefore runs this:
      final wrapper = ClientWrapper(ScriptedClientApi(), OpcUAConfig());
      wrapper.dispose();

      expect(() => wrapper.updateConnectionStatus(activated), returnsNormally,
          reason: 'updateConnectionStatus adds to a StreamController that '
              'dispose() closed. StateMan.close() disposes every wrapper '
              'while leaving its stateStream listener alive, so a state event '
              'racing shutdown throws "Cannot add new events after calling '
              'close" from inside the listener — an uncaught async error on '
              'the shutdown path (reload of key mappings, server-config save, '
              'app exit).');
    });
  });

  group('SingleWorker — subscription creation', () {
    test('a waiter whose owner never finishes must not wait forever',
        () async {
      // _monitorLoop does `await wrapper.worker.doTheWork()` with no timeout.
      // The owner only calls complete() in the `finally` of the
      // subscriptionCreate try — which never runs if the isolate/PLC never
      // answers CreateSubscription (the TCP-accepts-then-hangs case). Every
      // other key on that server is then parked on a bare await: no retry
      // ladder, no further log lines, no recovery.
      final worker = SingleWorker();
      expect(await worker.doTheWork(), isTrue, reason: 'sanity: owner');

      var waiterFinished = false;
      unawaited(worker.doTheWork().then((_) => waiterFinished = true));
      await Future<void>.delayed(const Duration(seconds: 8));

      expect(waiterFinished, isTrue,
          reason: 'The second caller never completes. In production that is '
              'every key on the server behind one hung CreateSubscription.');
    });

    test(
        'a subscriptionCreate that never returns starves the other keys on '
        'that server', () async {
      final fake = ScriptedClientApi()..subscriptionGate = Completer<int>();
      final sm = await stateManWith(fake, nodes: {
        'a': KeyMappingEntry(
            opcuaNode: OpcUANodeConfig(namespace: 4, identifier: 'A')
              ..serverAlias = 'plc'),
        'b': KeyMappingEntry(
            opcuaNode: OpcUANodeConfig(namespace: 4, identifier: 'B')
              ..serverAlias = 'plc'),
      });
      addTearDown(() {
        fake.subscriptionGate?.complete(1);
        return sm.close()
            .timeout(const Duration(seconds: 5), onTimeout: () {});
      });

      // Key 'a' wins the worker and hangs inside subscriptionCreate.
      unawaited(
          sm.subscribe('a').then((s) => s.listen((_) {}), onError: (_) {}));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Key 'b' now awaits worker.doTheWork().
      unawaited(
          sm.subscribe('b').then((s) => s.listen((_) {}), onError: (_) {}));

      await Future<void>.delayed(const Duration(seconds: 14));

      expect(fake.subscriptionCreateCalls, greaterThanOrEqualTo(2),
          reason: 'One CreateSubscription that never answers wedges the whole '
              'server permanently: `await client.subscriptionCreate(...)` '
              '(state_man.dart:2218) has no timeout, so its `finally` never '
              'runs, SingleWorker is never completed, and no key on that '
              'server — not even the one that owns the worker — ever gets to '
              'try again. Exactly the TCP-accepts-then-hangs failure mode.');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('AutoDisposingStream idle timer', () {
    test('a spent entry must not dispose the entry that replaced it',
        () async {
      // StateMan._subscriptions is keyed by key, and _onDispose removes BY
      // KEY, not by identity. AutoDisposingStream.onDone closes the subject
      // and calls _onDispose, but never cancels _idleTimer — and
      // _handleCancel starts that timer when the last listener goes away,
      // which happens as the closing subject completes its listeners.
      final registry = <String, AutoDisposingStream<int>>{};
      AutoDisposingStream<int> make() => AutoDisposingStream<int>(
            'a',
            registry.remove,
            idleTimeout: const Duration(milliseconds: 100),
          );

      final first = make();
      registry['a'] = first;
      final raw = StreamController<int>();
      first.subscribe(raw.stream, null);
      final listener = first.stream.listen((_) {});

      // The PLC drops the monitored item.
      await raw.close();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await listener.cancel();

      // A widget re-subscribes; StateMan._monitor builds a fresh entry.
      final second = make();
      registry['a'] = second;

      // The DEAD entry's idle timer now fires.
      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(registry['a'], same(second),
          reason: 'The spent entry\'s idle timer removed the live entry that '
              'replaced it. The next subscriber for this key therefore builds '
              'yet another entry and asks the PLC for four more monitored '
              'items, while the one it displaced keeps streaming — the '
              'monitored-item accumulation the wrapper already instruments, '
              'reproduced once per reconnect per key.');
    });
  });

  group('updateKeyMappings', () {
    test('editing the same key twice must not accumulate monitor loops',
        () async {
      final fake = ScriptedClientApi();
      final sm = await stateManWith(fake);
      addTearDown(() => sm.close().timeout(const Duration(seconds: 5),
          onTimeout: () {}));

      final stream = await sm.subscribe('a');
      final sub = stream.listen((_) {}, onError: (_) {});
      addTearDown(sub.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final afterFirst = fake.monitorCalls;

      // Two saves that each change the key's node — the operator retargeting
      // a key in the key-mapping editor.
      for (var i = 0; i < 2; i++) {
        sm.updateKeyMappings(KeyMappings(nodes: {
          'a': KeyMappingEntry(
              opcuaNode: OpcUANodeConfig(namespace: 4, identifier: 'A$i')
                ..serverAlias = 'plc'),
        }));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      expect(fake.monitorCalls - afterFirst, 2,
          reason: 'One re-point per save. More than that means overlapping '
              '_monitorLoop futures are each creating monitored items for '
              'the same key.');
    });
  });
}

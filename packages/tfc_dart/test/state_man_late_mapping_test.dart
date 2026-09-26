import 'dart:async';

import 'package:test/test.dart';
import 'package:open62541/open62541.dart'
    show ClientApi, DynamicValue, MonitoringMode, NodeId;
import 'package:tfc_dart/core/state_man.dart';

/// A key that is subscribed to *before* its mapping exists must come alive
/// when the mapping lands — without restarting the app.
///
/// The incident this file pins (2026-08-21/22): an operator accepted three
/// AI-proposed OPC UA key mappings in the key repository. The mappings were
/// written to preferences correctly, `server_alias` and all, the preferences
/// listener in `lib/providers/state_man.dart` picked the save up and applied
/// it live — and the three tags still read null until the app was restarted.
/// The log said, once per key and never again:
///
///   Failed to connect to client for key: "SPB01.Multivac.Run":
///   No OPC-UA client found for key "SPB01.Multivac.Run" (server alias: null)
///
/// That message reads like a dropped `server_alias`, and it is not. The alias
/// survives every hop of the accept (see the round-trip test at the bottom).
/// `null` is what [KeyMappings.lookupServerAlias] returns for a key that has
/// no entry *at all* — i.e. the subscribe happened while the mapping was
/// still only a proposal. What made that permanent rather than transient is
/// [StateMan._monitor]: the one failure path in it that gives up for good.
/// It registers the subscription entry, fails to resolve a client, hands the
/// caller a `Stream.error` and returns — leaving a cached entry that can
/// never deliver, so every later subscribe for that key gets the same dead
/// stream back. Every other failure in _monitor (no subscription id, no first
/// value, BadNodeIdUnknown) retries forever on the 1s/10s/60s/600s ladder,
/// precisely because "a node can come back".
///
/// Blast radius: alarms bind their condition keys through
/// `Evaluator.state()` → `stateMan.subscribe`, once, at construction. An
/// alarm written before its `.Fault` mapping existed therefore never fired,
/// no matter how correct the mapping it was later given.
class RecordingClientApi implements ClientApi {
  final List<NodeId> monitored = [];
  final Map<NodeId, StreamController<DynamicValue>> _controllers = {};

  void emit(NodeId node, DynamicValue value) => _controllers[node]!.add(value);

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
    monitored.add(nodeId);
    late StreamController<DynamicValue> controller;
    controller = StreamController<DynamicValue>(
      onListen: () => controller.add(DynamicValue(value: 0)),
    );
    _controllers[nodeId] = controller;
    return controller.stream;
  }

  @override
  Future<void> delete() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// The key and node the operator actually accepted, kept verbatim so the test
/// reads like the incident.
const _key = 'SPB01.Multivac.Run';
final _node = NodeId.fromString(4, 'SPB01.multivac.hmi.p_stat_Run');

KeyMappings _accepted() => KeyMappings(nodes: {
      _key: KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(
            namespace: 4, identifier: 'SPB01.multivac.hmi.p_stat_Run')
          ..serverAlias = 'st101',
      ),
    });

/// Polls until [test] holds or the budget runs out. The repair rides the
/// subscribe backoff ladder, whose first rung is 1s, so a fixed delay would
/// either be flaky or far longer than it needs to be.
Future<void> _waitFor(bool Function() test,
    {Duration budget = const Duration(seconds: 6)}) async {
  final deadline = DateTime.now().add(budget);
  while (!test() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late RecordingClientApi fake;
  late OpcUaStateMan stateMan;

  setUp(() async {
    fake = RecordingClientApi();
    // No mapping for [_key] yet — it is still only a proposal on screen.
    stateMan = await OpcUaStateMan.create(
      config: StateManConfig(opcua: []),
      keyMappings: KeyMappings(nodes: {}),
      deviceClients: const [],
    );
    stateMan.clients
        .add(ClientWrapper(fake, OpcUAConfig()..serverAlias = 'st101'));
  });

  tearDown(() async {
    await stateMan
        .close()
        .timeout(const Duration(seconds: 5), onTimeout: () {});
  });

  test('a stream taken before the mapping existed starts flowing when the '
      'operator accepts it', () async {
    final values = <DynamicValue>[];
    final errors = <Object>[];
    // An alarm evaluator or a page widget binds the key while it is still
    // unmapped. It keeps whatever stream it was handed — nothing in the app
    // subscribes a second time on its own.
    final stream = await stateMan.subscribe(_key);
    final sub = stream.listen(values.add, onError: errors.add);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // The operator presses Accept: preferences are written with the alias and
    // the provider's listener applies the save live.
    final result = stateMan.updateKeyMappings(_accepted());
    expect(result.added, {_key});
    expect(result.requiresReload, isFalse,
        reason: 'an OPC UA-only mapping is applied in place');

    await _waitFor(() => values.isNotEmpty);
    expect(fake.monitored, contains(_node),
        reason: 'the accepted mapping must be monitored without a restart');
    expect(values, isNotEmpty,
        reason: 'the stream the caller is holding must come alive; leaving it '
            'dead is what kept 28 fault mappings unreadable for days');

    // And it stays live, rather than delivering one seed value and stopping.
    final before = values.length;
    fake.emit(_node, DynamicValue(value: 1));
    await _waitFor(() => values.length > before);
    expect(values.last.value, 1);

    await sub.cancel();
  });

  test('a failed subscribe is not cached as the answer for every later one',
      () async {
    // First subscribe fails: no mapping, so no client to route to.
    final dead = await stateMan.subscribe(_key);
    final firstValues = <DynamicValue>[];
    final firstSub = dead.listen(firstValues.add, onError: (_) {});
    await Future<void>.delayed(const Duration(milliseconds: 50));

    stateMan.updateKeyMappings(_accepted());
    await _waitFor(() => fake.monitored.contains(_node));

    // A widget rebuilt after the accept asks again. It must not be handed the
    // entry the failed attempt left behind.
    final values = <DynamicValue>[];
    final stream = await stateMan.subscribe(_key);
    final sub = stream.listen(values.add, onError: (_) {});
    await _waitFor(() => values.isNotEmpty);
    expect(values, isNotEmpty,
        reason: 'a subscribe after the mapping landed must deliver values');

    await sub.cancel();
    await firstSub.cancel();
  });

  test('the accepted server_alias survives the whole mapping round trip', () {
    // Guards the half of the report that was *not* broken: the alias is
    // carried inside `opcua_node`, not at the top level of the entry, and it
    // survives toJson/fromJson. An audit that looks at the top level reports
    // a false negative.
    final accepted = _accepted();
    final roundTripped = KeyMappings.fromJson(accepted.toJson());
    expect(roundTripped.lookupServerAlias(_key), 'st101');
    expect(
        (accepted.toJson()['nodes'] as Map)[_key]['opcua_node']['server_alias'],
        'st101');
  });
}

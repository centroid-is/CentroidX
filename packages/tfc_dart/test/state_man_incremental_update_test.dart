import 'dart:async';

import 'package:jbtm/src/m2400.dart' show M2400RecordType;
import 'package:modbus_client_tcp/modbus_client_tcp.dart';
import 'package:test/test.dart';
import 'package:open62541/open62541.dart'
    show ClientApi, DynamicValue, MonitoringMode, NodeId;
import 'package:tfc_dart/core/config/config_diff.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/key_mapping_codec.dart';
import 'package:tfc_dart/core/modbus_client_wrapper.dart';
import 'package:tfc_dart/core/modbus_device_client.dart';
import 'package:tfc_dart/core/state_man.dart';

/// A fake OPC UA client that records which NodeIds were monitored and lets
/// the test push values into the currently-live monitor stream per node.
///
/// Every monitor() emits one seed value right away so StateMan._monitor's
/// first-value gate opens without waiting for its 5s timeout.
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

KeyMappingEntry opcuaEntry(String identifier,
        {String alias = 'plc', int? bitMask}) =>
    KeyMappingEntry(
      opcuaNode: OpcUANodeConfig(namespace: 4, identifier: identifier)
        ..serverAlias = alias,
      bitMask: bitMask,
    );

KeyMappingEntry modbusEntry(int address, {String? variableName}) =>
    KeyMappingEntry(
      modbusNode: ModbusNodeConfig(
        serverAlias: 'mb',
        registerType: ModbusRegisterType.holdingRegister,
        address: address,
      ),
      variableName: variableName,
    );

KeyMappingEntry m2400Entry({int? statusFilter}) => KeyMappingEntry(
      m2400Node: M2400NodeConfig(
        recordType: M2400RecordType.recBatch,
        serverAlias: 'scale1',
        statusFilter: statusFilter,
      ),
    );

Future<StateMan> buildStateMan(Map<String, KeyMappingEntry> nodes,
    {List<DeviceClient> deviceClients = const []}) {
  return StateMan.create(
    config: StateManConfig(opcua: []),
    keyMappings: KeyMappings(nodes: nodes),
    deviceClients: deviceClients,
  );
}

void main() {
  group('updateKeyMappings — diff classification', () {
    test('OPC UA-only edits, adds and removals apply live (no reload)',
        () async {
      final stateMan = await buildStateMan({
        'a': opcuaEntry('A'),
        'b': opcuaEntry('B'),
        'gone': opcuaEntry('Gone'),
      });
      try {
        final result = stateMan.updateKeyMappings(KeyMappings(nodes: {
          'a': opcuaEntry('A'), // untouched
          'b': opcuaEntry('B2'), // edited node
          'new': opcuaEntry('New'), // added
          // 'gone' removed
        }));
        expect(result.requiresReload, isFalse);
        expect(result.added, {'new'});
        expect(result.removed, {'gone'});
        expect(result.changed, {'b'});
        // Nothing was live-subscribed, so nothing to re-point.
        expect(result.resubscribed, isEmpty);
        expect(stateMan.keyMappings.nodes.keys, containsAll(['a', 'b', 'new']));
      } finally {
        await stateMan.close();
      }
    });

    test('unchanged mappings produce an empty diff', () async {
      final stateMan = await buildStateMan({'a': opcuaEntry('A')});
      try {
        final result =
            stateMan.updateKeyMappings(KeyMappings(nodes: {'a': opcuaEntry('A')}));
        expect(result.added, isEmpty);
        expect(result.removed, isEmpty);
        expect(result.changed, isEmpty);
        expect(result.requiresReload, isFalse);
      } finally {
        await stateMan.close();
      }
    });

    test('bitMask edit on an OPC UA key applies live', () async {
      final stateMan = await buildStateMan({'a': opcuaEntry('A')});
      try {
        final result = stateMan.updateKeyMappings(
            KeyMappings(nodes: {'a': opcuaEntry('A', bitMask: 0x4)}));
        expect(result.changed, {'a'});
        expect(result.requiresReload, isFalse);
      } finally {
        await stateMan.close();
      }
    });

    test('classic Modbus add/change/remove each require a reload', () async {
      final stateMan = await buildStateMan({
        'reg.change': modbusEntry(10),
        'reg.remove': modbusEntry(11),
      });
      try {
        final result = stateMan.updateKeyMappings(KeyMappings(nodes: {
          'reg.change': modbusEntry(20),
          'reg.add': modbusEntry(30),
        }));
        expect(result.requiresReload, isTrue);
        expect(
            result.reloadReasons,
            containsAll([
              contains('reg.change'),
              contains('reg.add'),
              contains('reg.remove'),
            ]));
      } finally {
        await stateMan.close();
      }
    });

    test('bitMask edit on a Modbus key requires a reload (spec is frozen)',
        () async {
      final stateMan = await buildStateMan({'reg': modbusEntry(10)});
      try {
        final result = stateMan.updateKeyMappings(KeyMappings(
            nodes: {'reg': modbusEntry(10)..bitMask = 0x1}));
        expect(result.requiresReload, isTrue);
        expect(result.reloadReasons.single, contains('reg'));
      } finally {
        await stateMan.close();
      }
    });

    test('M2400 change and removal require a reload, add does not', () async {
      final stateMan = await buildStateMan({
        'scale.change': m2400Entry(),
        'scale.remove': m2400Entry(),
      });
      try {
        final result = stateMan.updateKeyMappings(KeyMappings(nodes: {
          'scale.change': m2400Entry(statusFilter: 3),
          'scale.add': m2400Entry(),
        }));
        expect(result.requiresReload, isTrue);
        expect(result.reloadReasons, hasLength(2));
        expect(result.reloadReasons,
            containsAll([contains('scale.change'), contains('scale.remove')]));
        expect(result.added, {'scale.add'});
      } finally {
        await stateMan.close();
      }
    });

    test('UMAS-by-name add and removal apply live, rename requires reload',
        () async {
      final addRemove = await buildStateMan(
          {'umas.remove': modbusEntry(0, variableName: 'M_A.x')});
      try {
        final result = addRemove.updateKeyMappings(KeyMappings(nodes: {
          'umas.add': modbusEntry(0, variableName: 'M_B.y'),
        }));
        // Removal is handled by the adapter's unsubscribeUmas hook; adds
        // materialize on first subscribe. Neither needs a rebuild.
        expect(result.requiresReload, isFalse);
      } finally {
        await addRemove.close();
      }

      final rename = await buildStateMan(
          {'umas.key': modbusEntry(0, variableName: 'M_A.x')});
      try {
        final result = rename.updateKeyMappings(KeyMappings(nodes: {
          'umas.key': modbusEntry(0, variableName: 'M_A.renamed'),
        }));
        expect(result.requiresReload, isTrue);
        expect(result.reloadReasons.single, contains('umas.key'));
      } finally {
        await rename.close();
      }
    });
  });

  group('updateKeyMappings — live OPC UA streams', () {
    late RecordingClientApi fake;
    late StateMan stateMan;

    setUp(() async {
      fake = RecordingClientApi();
      stateMan = await buildStateMan({'motor.speed': opcuaEntry('Old')});
      stateMan.clients
          .add(ClientWrapper(fake, OpcUAConfig()..serverAlias = 'plc'));
    });

    tearDown(() async {
      await stateMan
          .close()
          .timeout(const Duration(seconds: 5), onTimeout: () {});
    });

    test('a changed key with a live monitor is re-pointed on the SAME stream',
        () async {
      final values = <DynamicValue>[];
      final stream = await stateMan.subscribe('motor.speed');
      final sub = stream.listen(values.add);
      await Future.delayed(const Duration(milliseconds: 10));
      expect(values, isNotEmpty, reason: 'seed value from the old node');
      expect(fake.monitored.last, NodeId.fromString(4, 'Old'));

      final result = stateMan
          .updateKeyMappings(KeyMappings(nodes: {'motor.speed': opcuaEntry('New')}));
      expect(result.requiresReload, isFalse);
      expect(result.resubscribed, {'motor.speed'});

      // The re-point is async (_monitor resub) — wait for the new
      // monitored item to appear.
      for (var i = 0; i < 100 && !fake.monitored.contains(NodeId.fromString(4, 'New')); i++) {
        await Future.delayed(const Duration(milliseconds: 10));
      }
      expect(fake.monitored.last, NodeId.fromString(4, 'New'),
          reason: 'the monitor must move to the new node');

      final before = values.length;
      fake.emit(NodeId.fromString(4, 'New'), DynamicValue(value: 99));
      await Future.delayed(const Duration(milliseconds: 10));
      expect(values.length, greaterThan(before),
          reason: 'the ORIGINAL stream keeps flowing after the re-point');
      expect(values.last.value, 99);

      await sub.cancel();
    });

    test('a removed key with a live monitor completes its stream', () async {
      var done = false;
      final stream = await stateMan.subscribe('motor.speed');
      final sub = stream.listen((_) {}, onDone: () => done = true);
      await Future.delayed(const Duration(milliseconds: 10));

      final result = stateMan.updateKeyMappings(KeyMappings(nodes: {}));
      expect(result.requiresReload, isFalse);
      expect(result.removed, {'motor.speed'});
      await Future.delayed(Duration.zero);
      expect(done, isTrue,
          reason: 'widgets must see a clean onDone for a deleted key');

      await sub.cancel();
    });
  });

  group('updateVariableNames poll-group refresh', () {
    test('a runtime-added UMAS key lands in its configured poll group',
        () async {
      final wrapper = ModbusClientWrapper('127.0.0.1', 0, 1,
          clientFactory: (h, p, u) =>
              ModbusClientTcp(h, serverPort: p, unitId: u));
      final adapter = ModbusDeviceClientAdapter(
        wrapper,
        specs: const {},
        variableNames: const {'k1': 'A.b'},
        umasEnabled: true,
        serverAlias: 'mb',
        umasPollGroupByKey: const {'k1': 'default'},
        pollGroups: [
          ModbusPollGroupConfig(name: 'fast', intervalMs: 100),
          ModbusPollGroupConfig(name: 'default', intervalMs: 1000),
        ],
      );
      try {
        adapter.updateVariableNames(
          {'k1': 'A.b', 'k2': 'C.d'},
          umasPollGroupByKey: {'k1': 'default', 'k2': 'fast'},
        );
        adapter.addUmasKey('k2');
        expect(adapter.debugUmasKeysByGroup['fast'], contains('k2'),
            reason: 'the refreshed poll-group mapping must be honored even '
                'for a group that had no members at construction');
      } finally {
        adapter.dispose();
      }
    });
  });

  group('updateKeyMappings — the store\'s diff and the recompute agree', () {
    // SC-3's signature half. The `ConfigStore` has already computed exactly
    // this diff to decide which rows to write; handing it over saves
    // re-deriving the same three sets by encoding every entry on both sides
    // to JSON — 430 encodes of objects that did not move, per save, on this
    // plant. What must be true is that it is the SAME answer, so each case
    // below runs both paths over identical inputs and compares them.
    //
    // The diff is built the way the store builds it: through the codec, over
    // `ConfigItem`s. A hand-assembled payload is structurally a different
    // payload — every model class emits its unset optionals as explicit nulls
    // — and the consequence is every key diffing as changed.
    ConfigDiff diffOf(
            Map<String, KeyMappingEntry> before, Map<String, KeyMappingEntry> after) =>
        diffConfigItems(
          stored: keyMappingItems(KeyMappings(nodes: before)),
          wanted: keyMappingItems(KeyMappings(nodes: after)),
        );

    /// Runs both paths over the same edit and asserts they cannot be told
    /// apart. Two `StateMan`s, because the apply mutates the one it runs on.
    Future<void> expectEquivalent(
      Map<String, KeyMappingEntry> before,
      Map<String, KeyMappingEntry> after, {
      List<DeviceClient> Function()? deviceClients,
    }) async {
      final next = KeyMappings(nodes: after);
      final recomputing =
          await buildStateMan(before, deviceClients: deviceClients?.call() ?? const []);
      final given =
          await buildStateMan(before, deviceClients: deviceClients?.call() ?? const []);
      try {
        final a = recomputing.updateKeyMappings(next);
        final b = given.updateKeyMappings(next, diff: diffOf(before, after));

        expect(b.added, a.added);
        expect(b.removed, a.removed);
        expect(b.changed, a.changed);
        expect(b.resubscribed, a.resubscribed);
        expect(b.reloadReasons, a.reloadReasons);
        expect(b.requiresReload, a.requiresReload);
        expect(given.keyMappings.nodes.keys, recomputing.keyMappings.nodes.keys);
      } finally {
        await recomputing.close();
        await given.close();
      }
    }

    test('an add, an edit and a removal in one save', () async {
      await expectEquivalent(
        {'a': opcuaEntry('A'), 'b': opcuaEntry('B'), 'gone': opcuaEntry('Gone')},
        {'a': opcuaEntry('A'), 'b': opcuaEntry('B2'), 'new': opcuaEntry('New')},
      );
    });

    test('a save that changes nothing', () async {
      await expectEquivalent(
        {'a': opcuaEntry('A')},
        {'a': opcuaEntry('A')},
      );
    });

    test('a classic-Modbus edit still asks for a reload', () async {
      // The requiresReload classification is what a station feels: it is the
      // difference between re-pointing a subscription and dropping every
      // connection on the panel. It must not depend on where the sets came
      // from.
      await expectEquivalent(
        {'m': modbusEntry(10), 'keep': opcuaEntry('K')},
        {'m': modbusEntry(11), 'keep': opcuaEntry('K')},
      );
      await expectEquivalent(
        {'m': modbusEntry(10)},
        {},
      );
      await expectEquivalent(
        {},
        {'m': modbusEntry(10)},
      );
    });

    test('an M2400 change and a protocol switch', () async {
      await expectEquivalent(
        {'w': m2400Entry(statusFilter: 1)},
        {'w': m2400Entry(statusFilter: 2)},
      );
      await expectEquivalent(
        {'p': opcuaEntry('P')},
        {'p': modbusEntry(7, variableName: 'Speed')},
      );
    });

    test('a bitMask edit, which no key name reveals', () async {
      // The two paths could agree on every case where the key set moves and
      // still disagree here: the store's diff is structural over the payload,
      // and `bit_mask` is a field of it.
      await expectEquivalent(
        {'a': opcuaEntry('A')},
        {'a': opcuaEntry('A', bitMask: 3)},
      );
    });

    test('a diff carrying items of another kind is ignored, not applied',
        () async {
      // From Phase 3 the store holds pages and assets in the same snapshot and
      // emits one diff over all of them. A page id that happened to match a
      // mapping key would otherwise tear down that key's subscription.
      final stateMan = await buildStateMan({'a': opcuaEntry('A')});
      try {
        final result = stateMan.updateKeyMappings(
          KeyMappings(nodes: {'a': opcuaEntry('A')}),
          diff: ConfigDiff(
            added: const [],
            changed: const [],
            removed: [
              ConfigItem.of(
                  kind: ConfigKind.page, id: 'a', value: const {'title': 'A'}),
            ],
          ),
        );

        expect(result.removed, isEmpty);
        expect(result.requiresReload, isFalse);
        expect(stateMan.keyMappings.nodes.keys, ['a']);
      } finally {
        await stateMan.close();
      }
    });
  });
}

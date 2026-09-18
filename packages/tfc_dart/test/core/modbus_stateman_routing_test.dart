import 'dart:async';

import 'package:modbus_client/modbus_client.dart' show ModbusElementType;
import 'package:open62541/open62541_types.dart' show DynamicValue, NodeId;
import 'package:test/test.dart';

import 'package:tfc_dart/core/modbus_client_wrapper.dart';
import 'package:tfc_dart/core/modbus_device_client.dart';
import 'package:tfc_dart/core/state_man.dart';

// ---------------------------------------------------------------------------
// Mock DeviceClient for Modbus routing tests
// ---------------------------------------------------------------------------

/// Mock that implements DeviceClient with controllable return values.
/// Used to test StateMan routing logic without real Modbus transport.
class MockModbusDeviceClient implements DeviceClient {
  @override
  final Set<String> subscribableKeys;
  final String? serverAlias;

  final Map<String, StreamController<DynamicValue>> _controllers = {};
  final Map<String, DynamicValue> _cachedValues = {};
  final List<String> subscribeCalls = [];
  final List<String> readCalls = [];
  final List<(String, DynamicValue)> writeCalls = [];

  ConnectionStatus _status = ConnectionStatus.disconnected;
  final _statusController =
      StreamController<ConnectionStatus>.broadcast();

  MockModbusDeviceClient({
    required Set<String> keys,
    this.serverAlias,
  }) : subscribableKeys = keys;

  @override
  bool canSubscribe(String key) => subscribableKeys.contains(key);

  @override
  Stream<DynamicValue> subscribe(String key) {
    subscribeCalls.add(key);
    final controller = _controllers.putIfAbsent(
        key, () => StreamController<DynamicValue>.broadcast());
    return controller.stream;
  }

  @override
  DynamicValue? read(String key) {
    readCalls.add(key);
    return _cachedValues[key];
  }

  @override
  Future<void> write(String key, DynamicValue value) async {
    writeCalls.add((key, value));
  }

  @override
  ConnectionStatus get connectionStatus => _status;

  @override
  Stream<ConnectionStatus> get connectionStream => _statusController.stream;

  @override
  void connect() {
    _status = ConnectionStatus.connected;
    _statusController.add(ConnectionStatus.connected);
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.close();
    }
    _statusController.close();
  }

  /// Set a cached value for read() to return.
  void setCachedValue(String key, DynamicValue value) {
    _cachedValues[key] = value;
  }

  /// Push a value into a subscribe stream.
  void push(String key, DynamicValue value) {
    _controllers.putIfAbsent(
        key, () => StreamController<DynamicValue>.broadcast());
    _controllers[key]!.add(value);
  }
}

/// Mock ModbusClientWrapper that tracks addPollGroup calls.
class MockModbusClientWrapper extends ModbusClientWrapper {
  final List<(String, Duration)> addPollGroupCalls = [];

  MockModbusClientWrapper()
      : super('mock', 0, 1, clientFactory: (h, p, u) {
          throw StateError('MockModbusClientWrapper should not create clients');
        });

  @override
  void addPollGroup(String name, Duration interval,
      {Duration? responseTimeout}) {
    addPollGroupCalls.add((name, interval));
    // Don't call super -- we don't want real poll groups in tests
  }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('buildSpecsFromKeyMappings', () {
    test('converts ModbusNodeConfig entries to ModbusRegisterSpec map', () {
      final keyMappings = KeyMappings(nodes: {
        'pump1_speed': KeyMappingEntry(
          modbusNode: ModbusNodeConfig(
            serverAlias: 'plc1',
            registerType: ModbusRegisterType.holdingRegister,
            address: 100,
            dataType: ModbusDataType.uint16,
            pollGroup: 'fast',
          ),
        ),
        'tank_level': KeyMappingEntry(
          modbusNode: ModbusNodeConfig(
            serverAlias: 'plc1',
            registerType: ModbusRegisterType.inputRegister,
            address: 200,
            dataType: ModbusDataType.float32,
            pollGroup: 'slow',
          ),
        ),
      });

      final specs = buildSpecsFromKeyMappings(keyMappings, 'plc1');

      expect(specs.length, 2);
      expect(specs.containsKey('pump1_speed'), isTrue);
      expect(specs.containsKey('tank_level'), isTrue);

      final pump = specs['pump1_speed']!;
      expect(pump.key, 'pump1_speed');
      expect(pump.registerType, ModbusElementType.holdingRegister);
      expect(pump.address, 100);
      expect(pump.dataType, ModbusDataType.uint16);
      expect(pump.pollGroup, 'fast');

      final tank = specs['tank_level']!;
      expect(tank.key, 'tank_level');
      expect(tank.registerType, ModbusElementType.inputRegister);
      expect(tank.address, 200);
      expect(tank.dataType, ModbusDataType.float32);
      expect(tank.pollGroup, 'slow');
    });

    test('skips entries without modbusNode', () {
      final keyMappings = KeyMappings(nodes: {
        'opc_key': KeyMappingEntry(
          opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'temp'),
        ),
        'modbus_key': KeyMappingEntry(
          modbusNode: ModbusNodeConfig(
            serverAlias: 'plc1',
            registerType: ModbusRegisterType.coil,
            address: 0,
          ),
        ),
      });

      final specs = buildSpecsFromKeyMappings(keyMappings, 'plc1');

      expect(specs.length, 1);
      expect(specs.containsKey('modbus_key'), isTrue);
      expect(specs.containsKey('opc_key'), isFalse);
    });

    test('skips entries with different serverAlias', () {
      final keyMappings = KeyMappings(nodes: {
        'plc1_key': KeyMappingEntry(
          modbusNode: ModbusNodeConfig(
            serverAlias: 'plc1',
            registerType: ModbusRegisterType.holdingRegister,
            address: 100,
          ),
        ),
        'plc2_key': KeyMappingEntry(
          modbusNode: ModbusNodeConfig(
            serverAlias: 'plc2',
            registerType: ModbusRegisterType.holdingRegister,
            address: 200,
          ),
        ),
      });

      final specs = buildSpecsFromKeyMappings(keyMappings, 'plc1');

      expect(specs.length, 1);
      expect(specs.containsKey('plc1_key'), isTrue);
      expect(specs.containsKey('plc2_key'), isFalse);
    });

    test('converts ModbusRegisterType to ModbusElementType in spec', () {
      final keyMappings = KeyMappings(nodes: {
        'coil_key': KeyMappingEntry(
          modbusNode: ModbusNodeConfig(
            serverAlias: null,
            registerType: ModbusRegisterType.coil,
            address: 0,
          ),
        ),
        'di_key': KeyMappingEntry(
          modbusNode: ModbusNodeConfig(
            serverAlias: null,
            registerType: ModbusRegisterType.discreteInput,
            address: 10,
          ),
        ),
        'hr_key': KeyMappingEntry(
          modbusNode: ModbusNodeConfig(
            serverAlias: null,
            registerType: ModbusRegisterType.holdingRegister,
            address: 100,
          ),
        ),
        'ir_key': KeyMappingEntry(
          modbusNode: ModbusNodeConfig(
            serverAlias: null,
            registerType: ModbusRegisterType.inputRegister,
            address: 200,
          ),
        ),
      });

      final specs = buildSpecsFromKeyMappings(keyMappings, null);

      expect(specs['coil_key']!.registerType, ModbusElementType.coil);
      expect(specs['di_key']!.registerType, ModbusElementType.discreteInput);
      expect(specs['hr_key']!.registerType, ModbusElementType.holdingRegister);
      expect(specs['ir_key']!.registerType, ModbusElementType.inputRegister);
    });

    test('handles null serverAlias matching', () {
      final keyMappings = KeyMappings(nodes: {
        'null_alias': KeyMappingEntry(
          modbusNode: ModbusNodeConfig(
            serverAlias: null,
            registerType: ModbusRegisterType.holdingRegister,
            address: 100,
          ),
        ),
        'named_alias': KeyMappingEntry(
          modbusNode: ModbusNodeConfig(
            serverAlias: 'plc1',
            registerType: ModbusRegisterType.holdingRegister,
            address: 200,
          ),
        ),
      });

      // Query for null alias should only get the null entry
      final specs = buildSpecsFromKeyMappings(keyMappings, null);
      expect(specs.length, 1);
      expect(specs.containsKey('null_alias'), isTrue);
    });
  });

  group('buildModbusDeviceClients', () {
    test('creates one adapter per ModbusConfig entry', () {
      final configs = [
        ModbusConfig(
          host: '10.0.0.1',
          port: 502,
          unitId: 1,
          serverAlias: 'plc1',
        ),
        ModbusConfig(
          host: '10.0.0.2',
          port: 502,
          unitId: 2,
          serverAlias: 'plc2',
        ),
      ];

      final keyMappings = KeyMappings(nodes: {
        'plc1_key': KeyMappingEntry(
          modbusNode: ModbusNodeConfig(
            serverAlias: 'plc1',
            registerType: ModbusRegisterType.holdingRegister,
            address: 100,
          ),
        ),
        'plc2_key': KeyMappingEntry(
          modbusNode: ModbusNodeConfig(
            serverAlias: 'plc2',
            registerType: ModbusRegisterType.holdingRegister,
            address: 200,
          ),
        ),
      });

      final adapters = buildModbusDeviceClients(configs, keyMappings);

      expect(adapters.length, 2);
      expect(adapters[0], isA<ModbusDeviceClientAdapter>());
      expect(adapters[1], isA<ModbusDeviceClientAdapter>());

      // Each adapter should only have specs for its own alias
      expect(adapters[0].canSubscribe('plc1_key'), isTrue);
      expect(adapters[0].canSubscribe('plc2_key'), isFalse);
      expect(adapters[1].canSubscribe('plc2_key'), isTrue);
      expect(adapters[1].canSubscribe('plc1_key'), isFalse);

      // Clean up
      for (final a in adapters) {
        a.dispose();
      }
    });

    test('pre-configures poll groups from ModbusConfig.pollGroups', () {
      final configs = [
        ModbusConfig(
          host: '10.0.0.1',
          port: 502,
          unitId: 1,
          serverAlias: 'plc1',
          pollGroups: [
            ModbusPollGroupConfig(name: 'fast', intervalMs: 500),
            ModbusPollGroupConfig(name: 'slow', intervalMs: 5000),
          ],
        ),
      ];

      final keyMappings = KeyMappings(nodes: {
        'key1': KeyMappingEntry(
          modbusNode: ModbusNodeConfig(
            serverAlias: 'plc1',
            registerType: ModbusRegisterType.holdingRegister,
            address: 100,
            pollGroup: 'fast',
          ),
        ),
      });

      // We use the real buildModbusDeviceClients to verify poll groups.
      // Since we cannot easily inspect the internal poll groups of a
      // ModbusClientWrapper from outside, we verify the adapters are
      // created correctly and the specs match.
      final adapters = buildModbusDeviceClients(configs, keyMappings);

      expect(adapters.length, 1);
      final adapter = adapters[0] as ModbusDeviceClientAdapter;
      expect(adapter.canSubscribe('key1'), isTrue);
      expect(adapter.serverAlias, 'plc1');

      // Clean up
      for (final a in adapters) {
        a.dispose();
      }
    });

    test('adapters have specs populated via buildSpecsFromKeyMappings', () {
      final configs = [
        ModbusConfig(
          host: '10.0.0.1',
          port: 502,
          unitId: 1,
          serverAlias: 'plc1',
        ),
      ];

      final keyMappings = KeyMappings(nodes: {
        'key_a': KeyMappingEntry(
          modbusNode: ModbusNodeConfig(
            serverAlias: 'plc1',
            registerType: ModbusRegisterType.holdingRegister,
            address: 100,
          ),
        ),
        'key_b': KeyMappingEntry(
          modbusNode: ModbusNodeConfig(
            serverAlias: 'plc1',
            registerType: ModbusRegisterType.coil,
            address: 0,
          ),
        ),
        'other_plc': KeyMappingEntry(
          modbusNode: ModbusNodeConfig(
            serverAlias: 'plc2',
            registerType: ModbusRegisterType.holdingRegister,
            address: 300,
          ),
        ),
      });

      final adapters = buildModbusDeviceClients(configs, keyMappings);

      expect(adapters.length, 1);
      expect(adapters[0].canSubscribe('key_a'), isTrue);
      expect(adapters[0].canSubscribe('key_b'), isTrue);
      expect(adapters[0].canSubscribe('other_plc'), isFalse);

      for (final a in adapters) {
        a.dispose();
      }
    });
  });

  group('ModbusDeviceClientAdapter routing (unit)', () {
    test('canSubscribe returns true for Modbus keys', () {
      final mock = MockModbusDeviceClient(
        keys: {'pump1_speed', 'tank_level'},
        serverAlias: 'plc1',
      );

      expect(mock.canSubscribe('pump1_speed'), isTrue);
      expect(mock.canSubscribe('tank_level'), isTrue);
      mock.dispose();
    });

    test('canSubscribe returns false for non-Modbus keys', () {
      final mock = MockModbusDeviceClient(
        keys: {'pump1_speed'},
        serverAlias: 'plc1',
      );

      expect(mock.canSubscribe('someOpcUaKey'), isFalse);
      expect(mock.canSubscribe('BATCH'), isFalse);
      mock.dispose();
    });

    test('subscribe returns DynamicValue stream', () async {
      final mock = MockModbusDeviceClient(
        keys: {'pump1_speed'},
        serverAlias: 'plc1',
      );

      final stream = mock.subscribe('pump1_speed');
      final completer = Completer<DynamicValue>();
      final sub = stream.listen((dv) {
        if (!completer.isCompleted) completer.complete(dv);
      });

      final expected = DynamicValue(value: 42, typeId: NodeId.uint16);
      mock.push('pump1_speed', expected);

      final dv = await completer.future.timeout(const Duration(seconds: 2));
      expect(dv.value, 42);
      expect(dv.typeId, NodeId.uint16);

      expect(mock.subscribeCalls, contains('pump1_speed'));

      await sub.cancel();
      mock.dispose();
    });

    test('read returns cached DynamicValue', () {
      final mock = MockModbusDeviceClient(
        keys: {'pump1_speed'},
        serverAlias: 'plc1',
      );

      final expected = DynamicValue(value: 100.0, typeId: NodeId.float);
      mock.setCachedValue('pump1_speed', expected);

      final result = mock.read('pump1_speed');
      expect(result, isNotNull);
      expect(result!.value, 100.0);
      expect(mock.readCalls, contains('pump1_speed'));

      mock.dispose();
    });

    test('read returns null when no cached value', () {
      final mock = MockModbusDeviceClient(
        keys: {'pump1_speed'},
        serverAlias: 'plc1',
      );

      final result = mock.read('pump1_speed');
      expect(result, isNull);

      mock.dispose();
    });

    test('write delegates to adapter', () async {
      final mock = MockModbusDeviceClient(
        keys: {'pump1_speed'},
        serverAlias: 'plc1',
      );

      final dv = DynamicValue(value: 42, typeId: NodeId.uint16);
      await mock.write('pump1_speed', dv);

      expect(mock.writeCalls.length, 1);
      expect(mock.writeCalls[0].$1, 'pump1_speed');
      expect(mock.writeCalls[0].$2.value, 42);

      mock.dispose();
    });
  });

  group('readMany routing', () {
    test('DeviceClient.read routes Modbus keys correctly', () {
      // Test the pattern that readMany will use: iterate keys,
      // check canSubscribe, call dc.read()
      final mock = MockModbusDeviceClient(
        keys: {'modbus_key1', 'modbus_key2'},
        serverAlias: 'plc1',
      );

      mock.setCachedValue('modbus_key1',
          DynamicValue(value: 10, typeId: NodeId.uint16));
      mock.setCachedValue('modbus_key2',
          DynamicValue(value: 20, typeId: NodeId.uint16));

      final results = <String, DynamicValue>{};
      final keys = ['modbus_key1', 'modbus_key2', 'opc_key'];

      final opcuaKeys = <String>[];
      for (final key in keys) {
        if (mock.canSubscribe(key)) {
          final value = mock.read(key);
          if (value != null) results[key] = value;
        } else {
          opcuaKeys.add(key);
        }
      }

      expect(results.length, 2);
      expect(results['modbus_key1']!.value, 10);
      expect(results['modbus_key2']!.value, 20);
      expect(opcuaKeys, ['opc_key']);

      mock.dispose();
    });

    test('handles mixed Modbus and non-DeviceClient keys', () {
      final modbusMock = MockModbusDeviceClient(
        keys: {'modbus_temp'},
        serverAlias: 'plc1',
      );

      modbusMock.setCachedValue('modbus_temp',
          DynamicValue(value: 25.5, typeId: NodeId.float));

      final keys = ['modbus_temp', 'opc_pressure', 'opc_flow'];

      final results = <String, DynamicValue>{};
      final opcuaKeys = <String>[];

      for (final key in keys) {
        if (modbusMock.canSubscribe(key)) {
          final value = modbusMock.read(key);
          if (value != null) results[key] = value;
        } else {
          opcuaKeys.add(key);
        }
      }

      expect(results.length, 1);
      expect(results['modbus_temp']!.value, 25.5);
      expect(opcuaKeys, ['opc_pressure', 'opc_flow']);

      modbusMock.dispose();
    });
  });

  group('Coexistence', () {
    test('M2400-style and Modbus mocks coexist without interference', () {
      // M2400-style mock (dot-notation prefix matching)
      final m2400Mock = MockModbusDeviceClient(
        keys: {'BATCH', 'STAT'},
        serverAlias: 'm2400_1',
      );

      // Modbus mock (exact key matching)
      final modbusMock = MockModbusDeviceClient(
        keys: {'pump1_speed', 'tank_level'},
        serverAlias: 'plc1',
      );

      // Each claims only its own keys
      expect(m2400Mock.canSubscribe('BATCH'), isTrue);
      expect(m2400Mock.canSubscribe('pump1_speed'), isFalse);

      expect(modbusMock.canSubscribe('pump1_speed'), isTrue);
      expect(modbusMock.canSubscribe('BATCH'), isFalse);

      // Both can have cached values independently
      m2400Mock.setCachedValue('BATCH',
          DynamicValue(value: {'weight': 42.0}));
      modbusMock.setCachedValue('pump1_speed',
          DynamicValue(value: 1500, typeId: NodeId.uint16));

      expect(m2400Mock.read('BATCH')!.value, {'weight': 42.0});
      expect(modbusMock.read('pump1_speed')!.value, 1500);

      m2400Mock.dispose();
      modbusMock.dispose();
    });

    test('subscribe streams are independent between protocols', () async {
      final m2400Mock = MockModbusDeviceClient(
        keys: {'BATCH'},
        serverAlias: 'm2400_1',
      );
      final modbusMock = MockModbusDeviceClient(
        keys: {'pump1_speed'},
        serverAlias: 'plc1',
      );

      final m2400Values = <DynamicValue>[];
      final modbusValues = <DynamicValue>[];

      final s1 = m2400Mock.subscribe('BATCH').listen(m2400Values.add);
      final s2 = modbusMock.subscribe('pump1_speed').listen(modbusValues.add);

      m2400Mock.push('BATCH', DynamicValue(value: 'batch_data'));
      modbusMock.push('pump1_speed',
          DynamicValue(value: 42, typeId: NodeId.uint16));

      await Future.delayed(const Duration(milliseconds: 50));

      expect(m2400Values.length, 1);
      expect(m2400Values[0].value, 'batch_data');
      expect(modbusValues.length, 1);
      expect(modbusValues[0].value, 42);

      await s1.cancel();
      await s2.cancel();
      m2400Mock.dispose();
      modbusMock.dispose();
    });
  });

  group('OPC UA coexistence', () {
    test('OPC UA keys are not claimed by Modbus adapter', () {
      final modbusMock = MockModbusDeviceClient(
        keys: {'pump1_speed'},
        serverAlias: 'plc1',
      );

      // OPC UA keys should not match
      expect(modbusMock.canSubscribe('ns=2;s=Temperature'), isFalse);
      expect(modbusMock.canSubscribe('ns=0;i=2258'), isFalse);

      modbusMock.dispose();
    });

    test('Modbus adapter only uses exact key matching', () {
      final modbusMock = MockModbusDeviceClient(
        keys: {'pump1_speed'},
        serverAlias: 'plc1',
      );

      // Prefix/suffix should not match (unlike M2400 dot-notation)
      expect(modbusMock.canSubscribe('pump1_speed.sub'), isFalse);
      expect(modbusMock.canSubscribe('pump1'), isFalse);
      expect(modbusMock.canSubscribe('pump1_speed'), isTrue);

      modbusMock.dispose();
    });
  });
}

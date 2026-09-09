import 'package:test/test.dart';
import 'package:tfc_dart/core/modbus_device_client.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;

OpcUAConfig _opcua(String alias, {bool enabled = true}) => OpcUAConfig()
  ..endpoint = 'opc.tcp://$alias:4840'
  ..serverAlias = alias
  ..enabled = enabled;

KeyMappings _opcuaKey(String key, String? alias) => KeyMappings(nodes: {
      key: KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(namespace: 2, identifier: '1001')
          ..serverAlias = alias,
      ),
    });

void main() {
  group('enabled flag serialization', () {
    test('OpcUAConfig defaults to enabled and round-trips', () {
      final config = _opcua('plc1');
      expect(config.enabled, isTrue);
      expect(config.toJson()['enabled'], isTrue);

      config.enabled = false;
      final restored = OpcUAConfig.fromJson(config.toJson());
      expect(restored.enabled, isFalse);
    });

    test('OpcUAConfig without an "enabled" field decodes as enabled', () {
      // Every config saved before this feature existed.
      final restored = OpcUAConfig.fromJson({
        'endpoint': 'opc.tcp://legacy:4840',
        'server_alias': 'legacy',
      });
      expect(restored.enabled, isTrue);
    });

    test('M2400Config defaults to enabled and round-trips', () {
      final config = M2400Config(host: '10.0.0.1', enabled: false);
      expect(M2400Config(host: '10.0.0.1').enabled, isTrue);
      expect(M2400Config.fromJson(config.toJson()).enabled, isFalse);
      expect(
        M2400Config.fromJson({'host': '10.0.0.1', 'port': 52211}).enabled,
        isTrue,
      );
    });

    test('ModbusConfig defaults to enabled and round-trips', () {
      final config = ModbusConfig(host: '10.0.0.1', enabled: false);
      expect(ModbusConfig(host: '10.0.0.1').enabled, isTrue);
      expect(ModbusConfig.fromJson(config.toJson()).enabled, isFalse);
      expect(
        ModbusConfig.fromJson({'host': '10.0.0.1', 'port': 502}).enabled,
        isTrue,
      );
    });

    test('StateManConfig.copy() preserves the disabled flag', () {
      final config = StateManConfig(
        opcua: [_opcua('plc1', enabled: false)],
        jbtm: [M2400Config(host: 'h', enabled: false)..serverAlias = 'w1'],
        modbus: [ModbusConfig(host: 'h', enabled: false, serverAlias: 'm1')],
      );
      final copy = config.copy();
      expect(copy.opcua.single.enabled, isFalse);
      expect(copy.jbtm.single.enabled, isFalse);
      expect(copy.modbus.single.enabled, isFalse);
    });
  });

  group('StateManConfig.disabledServerAliases', () {
    test('collects disabled aliases across all three protocols', () {
      final config = StateManConfig(
        opcua: [_opcua('plc1', enabled: false), _opcua('plc2')],
        jbtm: [M2400Config(host: 'h', enabled: false)..serverAlias = 'w1'],
        modbus: [ModbusConfig(host: 'h', serverAlias: 'm1', enabled: false)],
      );

      expect(config.disabledServerAliases, {'plc1', 'w1', 'm1'});
      expect(config.isServerEnabled('plc1'), isFalse);
      expect(config.isServerEnabled('plc2'), isTrue);
      expect(config.isServerEnabled('w1'), isFalse);
      expect(config.isServerEnabled('m1'), isFalse);
    });

    test('an unknown alias counts as enabled', () {
      final config = StateManConfig(opcua: [_opcua('plc1', enabled: false)]);
      // Nothing serves 'ghost', but nothing disabled it either — keep the
      // existing "no client found" error rather than claiming it is off.
      expect(config.isServerEnabled('ghost'), isTrue);
    });

    test('null and empty alias are the same unnamed server', () {
      final config = StateManConfig(opcua: [OpcUAConfig()..enabled = false]);
      expect(config.disabledServerAliases, {null});
      expect(config.isServerEnabled(null), isFalse);
      expect(config.isServerEnabled(''), isFalse);
    });

    test('an alias still served by an enabled entry is not disabled', () {
      final config = StateManConfig(
        opcua: [_opcua('plc1', enabled: false)],
        modbus: [ModbusConfig(host: 'h', serverAlias: 'plc1')],
      );
      expect(config.disabledServerAliases, isEmpty);
      expect(config.isServerEnabled('plc1'), isTrue);
    });

    test('enabledOpcua/Jbtm/Modbus filter out disabled entries', () {
      final config = StateManConfig(
        opcua: [_opcua('plc1', enabled: false), _opcua('plc2')],
        jbtm: [
          M2400Config(host: 'a', enabled: false)..serverAlias = 'w1',
          M2400Config(host: 'b')..serverAlias = 'w2',
        ],
        modbus: [
          ModbusConfig(host: 'a', serverAlias: 'm1', enabled: false),
          ModbusConfig(host: 'b', serverAlias: 'm2'),
        ],
      );

      expect(config.enabledOpcua.map((c) => c.serverAlias), ['plc2']);
      expect(config.enabledJbtm.map((c) => c.serverAlias), ['w2']);
      expect(config.enabledModbus.map((c) => c.serverAlias), ['m2']);
      expect(config.allServers, hasLength(6));
    });
  });

  group('device clients skip disabled servers', () {
    test('createM2400DeviceClients builds nothing for a disabled weigher', () {
      final clients = createM2400DeviceClients([
        M2400Config(host: '10.104.29.71', enabled: false)..serverAlias = 'w1',
        M2400Config(host: '10.104.29.72')..serverAlias = 'w2',
      ]);

      expect(clients, hasLength(1));
      expect((clients.single as M2400DeviceClientAdapter).serverAlias, 'w2');

      for (final c in clients) {
        c.dispose();
      }
    });

    test('buildModbusDeviceClients builds nothing for a disabled PLC', () {
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

      final clients = buildModbusDeviceClients([
        ModbusConfig(host: '10.0.0.1', serverAlias: 'plc1', enabled: false),
        ModbusConfig(host: '10.0.0.2', serverAlias: 'plc2'),
      ], keyMappings);

      expect(clients, hasLength(1));
      expect(clients.single.canSubscribe('plc2_key'), isTrue);
      expect(clients.single.canSubscribe('plc1_key'), isFalse);

      for (final c in clients) {
        c.dispose();
      }
    });
  });

  group('StateMan with a disabled server', () {
    test('creates no OPC UA client for it', () async {
      final stateMan = await StateMan.create(
        config: StateManConfig(opcua: [_opcua('plc1', enabled: false)]),
        keyMappings: _opcuaKey('pump.speed', 'plc1'),
      );

      expect(stateMan.clients, isEmpty);
      await stateMan.close();
    });

    test('read() throws ServerDisabledException naming the key and server',
        () async {
      final stateMan = await StateMan.create(
        config: StateManConfig(opcua: [_opcua('plc1', enabled: false)]),
        keyMappings: _opcuaKey('pump.speed', 'plc1'),
      );

      await expectLater(
        stateMan.read('pump.speed'),
        throwsA(isA<ServerDisabledException>()
            .having((e) => e.serverAlias, 'serverAlias', 'plc1')
            .having((e) => e.message, 'message', contains('pump.speed'))),
      );

      await stateMan.close();
    });

    test('write() throws ServerDisabledException', () async {
      final stateMan = await StateMan.create(
        config: StateManConfig(opcua: [_opcua('plc1', enabled: false)]),
        keyMappings: _opcuaKey('pump.speed', 'plc1'),
      );

      await expectLater(
        stateMan.write('pump.speed', DynamicValue(value: 42)),
        throwsA(isA<ServerDisabledException>()),
      );

      await stateMan.close();
    });

    test('subscribe() throws instead of entering the 1 s retry loop', () async {
      final stateMan = await StateMan.create(
        config: StateManConfig(opcua: [_opcua('plc1', enabled: false)]),
        keyMappings: _opcuaKey('pump.speed', 'plc1'),
      );

      await expectLater(
        stateMan.subscribe('pump.speed'),
        throwsA(isA<ServerDisabledException>()),
      );

      await stateMan.close();
    });

    test('readMany() skips disabled keys and keeps the rest', () async {
      final stateMan = await StateMan.create(
        config: StateManConfig(opcua: [_opcua('plc1', enabled: false)]),
        keyMappings: _opcuaKey('pump.speed', 'plc1'),
      );

      // Only key in the mapping is disabled, so nothing comes back — and
      // crucially no exception and no client lookup.
      expect(await stateMan.readMany(['pump.speed']), isEmpty);

      await stateMan.close();
    });

    test('isKeyDisabled reports per key, not per server', () async {
      final stateMan = await StateMan.create(
        config: StateManConfig(
          opcua: [_opcua('plc1', enabled: false), _opcua('plc2')],
        ),
        keyMappings: KeyMappings(nodes: {
          'off.key': KeyMappingEntry(
            opcuaNode: OpcUANodeConfig(namespace: 2, identifier: '1')
              ..serverAlias = 'plc1',
          ),
          'on.key': KeyMappingEntry(
            opcuaNode: OpcUANodeConfig(namespace: 2, identifier: '2')
              ..serverAlias = 'plc2',
          ),
        }),
      );

      expect(stateMan.isKeyDisabled('off.key'), isTrue);
      expect(stateMan.isKeyDisabled('on.key'), isFalse);

      await stateMan.close();
    });

    test('keys on an enabled server still get the old no-client error',
        () async {
      // Regression guard: disabling one server must not turn every
      // unreachable server into a "disabled" report.
      final stateMan = await StateMan.create(
        config: StateManConfig(opcua: [_opcua('plc1', enabled: false)]),
        keyMappings: _opcuaKey('other.key', 'plc2'),
      );

      await expectLater(
        stateMan.read('other.key'),
        throwsA(isA<StateManException>()
            .having((e) => e, 'not a disable error',
                isNot(isA<ServerDisabledException>()))),
      );

      await stateMan.close();
    });
  });
}

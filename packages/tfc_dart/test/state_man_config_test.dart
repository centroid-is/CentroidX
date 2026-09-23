
import 'package:jbtm/jbtm.dart' show M2400RecordType, M2400Field;
import 'package:test/test.dart';
import 'package:tfc_dart/core/modbus_client_wrapper.dart' show ModbusDataType;
import 'package:tfc_dart/core/state_man.dart';

void main() {
  group('M2400Config', () {
    test('serializes to JSON with keys: host, port, server_alias', () {
      final config = M2400Config(host: '192.168.1.100', port: 52211);
      config.serverAlias = 'scale1';
      final json = config.toJson();
      expect(json, containsPair('host', '192.168.1.100'));
      expect(json, containsPair('port', 52211));
      expect(json, containsPair('server_alias', 'scale1'));
    });

    test('round-trips: fromJson(toJson()) produces equivalent object', () {
      final config = M2400Config(host: '10.0.0.1', port: 52212);
      config.serverAlias = 'scale2';
      final json = config.toJson();
      final restored = M2400Config.fromJson(json);
      expect(restored.host, '10.0.0.1');
      expect(restored.port, 52212);
      expect(restored.serverAlias, 'scale2');
    });

    test('defaults: host empty string, port 52211', () {
      final config = M2400Config();
      expect(config.host, '');
      expect(config.port, 52211);
    });
  });

  group('M2400NodeConfig', () {
    test('serializes with keys: record_type, field, server_alias', () {
      final node = M2400NodeConfig(
        recordType: M2400RecordType.recBatch,
        field: M2400Field.weight,
        serverAlias: 'scale1',
      );
      final json = node.toJson();
      expect(json, containsPair('record_type', 'recBatch'));
      expect(json, containsPair('field', 'weight'));
      expect(json, containsPair('server_alias', 'scale1'));
    });

    test('with field=null serializes correctly (field null in JSON)', () {
      final node = M2400NodeConfig(
        recordType: M2400RecordType.recStat,
        serverAlias: 'scale1',
      );
      final json = node.toJson();
      expect(json['record_type'], 'recStat');
      expect(json['field'], isNull);
    });

    test('round-trips with field set', () {
      final node = M2400NodeConfig(
        recordType: M2400RecordType.recBatch,
        field: M2400Field.weight,
        serverAlias: 'scale1',
      );
      final restored = M2400NodeConfig.fromJson(node.toJson());
      expect(restored.recordType, M2400RecordType.recBatch);
      expect(restored.field, M2400Field.weight);
      expect(restored.serverAlias, 'scale1');
    });

    test('round-trips without field set', () {
      final node = M2400NodeConfig(
        recordType: M2400RecordType.recStat,
        serverAlias: 'scale2',
      );
      final restored = M2400NodeConfig.fromJson(node.toJson());
      expect(restored.recordType, M2400RecordType.recStat);
      expect(restored.field, isNull);
      expect(restored.serverAlias, 'scale2');
    });

    test('record_type serializes as string enum name', () {
      final node = M2400NodeConfig(
        recordType: M2400RecordType.recBatch,
      );
      final json = node.toJson();
      expect(json['record_type'], 'recBatch');
    });

    test('record_type deserializes from string enum name', () {
      final json = {'record_type': 'recBatch', 'field': null, 'server_alias': null};
      final node = M2400NodeConfig.fromJson(json);
      expect(node.recordType, M2400RecordType.recBatch);
    });

    test('field serializes as string enum name', () {
      final node = M2400NodeConfig(
        recordType: M2400RecordType.recBatch,
        field: M2400Field.weight,
      );
      final json = node.toJson();
      expect(json['field'], 'weight');
    });

    test('field deserializes from string enum name', () {
      final json = {'record_type': 'recBatch', 'field': 'weight', 'server_alias': null};
      final node = M2400NodeConfig.fromJson(json);
      expect(node.field, M2400Field.weight);
    });
  });

  group('StateManConfig with jbtm', () {
    test('serializes alongside opcua list', () {
      final config = StateManConfig(
        opcua: [OpcUAConfig()],
        jbtm: [M2400Config(host: '10.0.0.1', port: 52211)],
      );
      final json = config.toJson();
      expect(json, contains('opcua'));
      expect(json, contains('jbtm'));
      expect((json['jbtm'] as List).length, 1);
    });

    test('empty jbtm list serializes correctly', () {
      final config = StateManConfig(opcua: [OpcUAConfig()], jbtm: []);
      final json = config.toJson();
      expect(json['jbtm'], isA<List>());
      expect((json['jbtm'] as List), isEmpty);
    });

    test('backwards compatible: JSON without jbtm key defaults to empty list', () {
      final json = {
        'opcua': [
          {'endpoint': 'opc.tcp://localhost:4840'}
        ]
      };
      final config = StateManConfig.fromJson(json);
      expect(config.jbtm, isEmpty);
      expect(config.opcua, isNotEmpty);
    });

    test('round-trips with both opcua and jbtm', () {
      final original = StateManConfig(
        opcua: [OpcUAConfig()],
        jbtm: [
          M2400Config(host: '10.0.0.1', port: 52211)..serverAlias = 'scale1',
          M2400Config(host: '10.0.0.2', port: 52212)..serverAlias = 'scale2',
        ],
      );
      final restored = StateManConfig.fromJson(original.toJson());
      expect(restored.jbtm.length, 2);
      expect(restored.jbtm[0].host, '10.0.0.1');
      expect(restored.jbtm[0].serverAlias, 'scale1');
      expect(restored.jbtm[1].host, '10.0.0.2');
      expect(restored.jbtm[1].serverAlias, 'scale2');
    });
  });

  group('KeyMappingEntry with m2400Node', () {
    test('serializes/deserializes correctly', () {
      final entry = KeyMappingEntry(
        m2400Node: M2400NodeConfig(
          recordType: M2400RecordType.recBatch,
          field: M2400Field.weight,
          serverAlias: 'scale1',
        ),
      );
      final json = entry.toJson();
      expect(json, contains('m2400_node'));
      expect(json['m2400_node'], isNotNull);

      final restored = KeyMappingEntry.fromJson(json);
      expect(restored.m2400Node, isNotNull);
      expect(restored.m2400Node!.recordType, M2400RecordType.recBatch);
      expect(restored.m2400Node!.field, M2400Field.weight);
      expect(restored.m2400Node!.serverAlias, 'scale1');
    });

    test('server returns m2400Node.serverAlias when opcuaNode is null', () {
      final entry = KeyMappingEntry(
        m2400Node: M2400NodeConfig(
          recordType: M2400RecordType.recBatch,
          serverAlias: 'scale1',
        ),
      );
      expect(entry.server, 'scale1');
    });

    test('server returns opcuaNode.serverAlias when both exist', () {
      final entry = KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'test')
          ..serverAlias = 'opcServer',
        m2400Node: M2400NodeConfig(
          recordType: M2400RecordType.recBatch,
          serverAlias: 'scale1',
        ),
      );
      // opcuaNode takes precedence
      expect(entry.server, 'opcServer');
    });
  });

  group('KeyMappings with M2400 entries', () {
    test('lookupServerAlias returns correct alias for M2400 keys', () {
      final mappings = KeyMappings(nodes: {
        'myBatch': KeyMappingEntry(
          m2400Node: M2400NodeConfig(
            recordType: M2400RecordType.recBatch,
            serverAlias: 'scale1',
          ),
        ),
      });
      expect(mappings.lookupServerAlias('myBatch'), 'scale1');
    });

    test('filterByServer filters M2400 entries correctly', () {
      final mappings = KeyMappings(nodes: {
        'batch1': KeyMappingEntry(
          m2400Node: M2400NodeConfig(
            recordType: M2400RecordType.recBatch,
            serverAlias: 'scale1',
          ),
        ),
        'batch2': KeyMappingEntry(
          m2400Node: M2400NodeConfig(
            recordType: M2400RecordType.recBatch,
            serverAlias: 'scale2',
          ),
        ),
        'opcKey': KeyMappingEntry(
          opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'test')
            ..serverAlias = 'opcServer',
        ),
      });
      final scale1Only = mappings.filterByServer('scale1');
      expect(scale1Only.nodes.length, 1);
      expect(scale1Only.nodes.containsKey('batch1'), isTrue);

      final scale2Only = mappings.filterByServer('scale2');
      expect(scale2Only.nodes.length, 1);
      expect(scale2Only.nodes.containsKey('batch2'), isTrue);

      final opcOnly = mappings.filterByServer('opcServer');
      expect(opcOnly.nodes.length, 1);
      expect(opcOnly.nodes.containsKey('opcKey'), isTrue);
    });
  });

  group('OPC UA regression', () {
    test('existing OPC UA config JSON round-trips without regression', () {
      final opcConfig = OpcUAConfig()
        ..endpoint = 'opc.tcp://10.0.0.1:4840'
        ..username = 'admin'
        ..password = 'secret'
        ..serverAlias = 'myOpc';

      final json = opcConfig.toJson();
      final restored = OpcUAConfig.fromJson(json);
      expect(restored.endpoint, 'opc.tcp://10.0.0.1:4840');
      expect(restored.username, 'admin');
      expect(restored.password, 'secret');
      expect(restored.serverAlias, 'myOpc');
    });

    test('StateManConfig with only opcua (no jbtm) round-trips', () {
      final config = StateManConfig(opcua: [OpcUAConfig()]);
      final json = config.toJson();
      final restored = StateManConfig.fromJson(json);
      expect(restored.opcua.length, 1);
      expect(restored.jbtm, isEmpty);
    });

    test('KeyMappingEntry with only opcuaNode still works', () {
      final entry = KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'test')
          ..serverAlias = 'myOpc',
      );
      final json = entry.toJson();
      final restored = KeyMappingEntry.fromJson(json);
      expect(restored.opcuaNode, isNotNull);
      expect(restored.m2400Node, isNull);
      expect(restored.server, 'myOpc');
    });

    test('KeyMappings lookupServerAlias still works for OPC UA keys', () {
      final mappings = KeyMappings(nodes: {
        'opcKey': KeyMappingEntry(
          opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'test')
            ..serverAlias = 'myOpc',
        ),
      });
      expect(mappings.lookupServerAlias('opcKey'), 'myOpc');
    });
  });

  // ==========================================================================
  // Modbus config serialization tests (Phase 8, Plan 01)
  // ==========================================================================

  group('ModbusRegisterType', () {
    test('all 4 values serialize as camelCase strings', () {
      expect(ModbusRegisterType.coil.name, 'coil');
      expect(ModbusRegisterType.discreteInput.name, 'discreteInput');
      expect(ModbusRegisterType.holdingRegister.name, 'holdingRegister');
      expect(ModbusRegisterType.inputRegister.name, 'inputRegister');
    });

    test('all 4 values deserialize from camelCase strings via JSON round-trip', () {
      // Use a ModbusNodeConfig to test enum serialization through JSON
      for (final rt in ModbusRegisterType.values) {
        final node = ModbusNodeConfig(registerType: rt, address: 0);
        final json = node.toJson();
        final restored = ModbusNodeConfig.fromJson(json);
        expect(restored.registerType, rt,
            reason: 'Failed round-trip for ${rt.name}');
      }
    });
  });

  group('ModbusPollGroupConfig', () {
    test('round-trips with name and intervalMs', () {
      final pg = ModbusPollGroupConfig(name: 'fast', intervalMs: 250);
      final json = pg.toJson();
      final restored = ModbusPollGroupConfig.fromJson(json);
      expect(restored.name, 'fast');
      expect(restored.intervalMs, 250);
    });

    test('default intervalMs is 1000', () {
      final pg = ModbusPollGroupConfig(name: 'default');
      expect(pg.intervalMs, 1000);
    });
  });

  group('ModbusConfig', () {
    test('serializes to JSON with keys: host, port, unit_id, server_alias, poll_groups', () {
      final config = ModbusConfig(
        host: '192.168.1.50',
        port: 502,
        unitId: 3,
        serverAlias: 'plc1',
        pollGroups: [ModbusPollGroupConfig(name: 'fast', intervalMs: 250)],
      );
      final json = config.toJson();
      expect(json, containsPair('host', '192.168.1.50'));
      expect(json, containsPair('port', 502));
      expect(json, containsPair('unit_id', 3));
      expect(json, containsPair('server_alias', 'plc1'));
      expect(json['poll_groups'], isA<List>());
      expect((json['poll_groups'] as List).length, 1);
    });

    test('round-trips with all fields populated', () {
      final config = ModbusConfig(
        host: '10.50.10.10',
        port: 5020,
        unitId: 5,
        serverAlias: 'plc2',
        pollGroups: [
          ModbusPollGroupConfig(name: 'fast', intervalMs: 100),
          ModbusPollGroupConfig(name: 'slow', intervalMs: 5000),
        ],
      );
      final json = config.toJson();
      final restored = ModbusConfig.fromJson(json);
      expect(restored.host, '10.50.10.10');
      expect(restored.port, 5020);
      expect(restored.unitId, 5);
      expect(restored.serverAlias, 'plc2');
      expect(restored.pollGroups.length, 2);
      expect(restored.pollGroups[0].name, 'fast');
      expect(restored.pollGroups[0].intervalMs, 100);
      expect(restored.pollGroups[1].name, 'slow');
      expect(restored.pollGroups[1].intervalMs, 5000);
    });

    test('defaults: host empty, port 502, unitId 1', () {
      final config = ModbusConfig();
      expect(config.host, '');
      expect(config.port, 502);
      expect(config.unitId, 1);
      expect(config.pollGroups, isEmpty);
    });
  });

  group('ModbusNodeConfig', () {
    test('serializes with keys: server_alias, register_type, address, data_type, poll_group', () {
      final node = ModbusNodeConfig(
        serverAlias: 'plc1',
        registerType: ModbusRegisterType.holdingRegister,
        address: 100,
        dataType: ModbusDataType.float32,
        pollGroup: 'fast',
      );
      final json = node.toJson();
      expect(json, containsPair('server_alias', 'plc1'));
      expect(json, containsPair('register_type', 'holdingRegister'));
      expect(json, containsPair('address', 100));
      expect(json, containsPair('data_type', 'float32'));
      expect(json, containsPair('poll_group', 'fast'));
    });

    test('round-trips with all register types', () {
      for (final rt in ModbusRegisterType.values) {
        final node = ModbusNodeConfig(
          registerType: rt,
          address: 42,
          serverAlias: 'plc1',
        );
        final restored = ModbusNodeConfig.fromJson(node.toJson());
        expect(restored.registerType, rt,
            reason: 'Failed round-trip for register type ${rt.name}');
      }
    });

    test('round-trips with all data types', () {
      for (final dt in ModbusDataType.values) {
        final node = ModbusNodeConfig(
          registerType: ModbusRegisterType.holdingRegister,
          address: 0,
          dataType: dt,
        );
        final restored = ModbusNodeConfig.fromJson(node.toJson());
        expect(restored.dataType, dt,
            reason: 'Failed round-trip for data type ${dt.name}');
      }
    });

    test('defaults: dataType uint16, pollGroup default', () {
      final node = ModbusNodeConfig(
        registerType: ModbusRegisterType.holdingRegister,
        address: 0,
      );
      expect(node.dataType, ModbusDataType.uint16);
      expect(node.pollGroup, 'default');
    });
  });

  group('StateManConfig with modbus', () {
    test('JSON without modbus key defaults to empty list (backward compat)', () {
      final json = {
        'opcua': [
          {'endpoint': 'opc.tcp://localhost:4840'}
        ]
      };
      final config = StateManConfig.fromJson(json);
      expect(config.modbus, isEmpty);
      expect(config.opcua, isNotEmpty);
    });

    test('round-trips with opcua + jbtm + modbus all populated', () {
      final original = StateManConfig(
        opcua: [OpcUAConfig()],
        jbtm: [M2400Config(host: '10.0.0.1', port: 52211)..serverAlias = 'scale1'],
        modbus: [
          ModbusConfig(
            host: '10.50.10.10',
            port: 502,
            unitId: 1,
            serverAlias: 'plc1',
            pollGroups: [ModbusPollGroupConfig(name: 'fast', intervalMs: 250)],
          ),
        ],
      );
      final restored = StateManConfig.fromJson(original.toJson());
      expect(restored.opcua.length, 1);
      expect(restored.jbtm.length, 1);
      expect(restored.modbus.length, 1);
      expect(restored.modbus[0].host, '10.50.10.10');
      expect(restored.modbus[0].port, 502);
      expect(restored.modbus[0].unitId, 1);
      expect(restored.modbus[0].serverAlias, 'plc1');
      expect(restored.modbus[0].pollGroups.length, 1);
      expect(restored.modbus[0].pollGroups[0].name, 'fast');
      expect(restored.modbus[0].pollGroups[0].intervalMs, 250);
    });
  });

  group('KeyMappingEntry with modbusNode', () {
    test('serializes/deserializes correctly with modbus_node key', () {
      final entry = KeyMappingEntry(
        modbusNode: ModbusNodeConfig(
          serverAlias: 'plc1',
          registerType: ModbusRegisterType.holdingRegister,
          address: 100,
          dataType: ModbusDataType.float32,
          pollGroup: 'fast',
        ),
      );
      final json = entry.toJson();
      expect(json, contains('modbus_node'));
      expect(json['modbus_node'], isNotNull);

      final restored = KeyMappingEntry.fromJson(json);
      expect(restored.modbusNode, isNotNull);
      expect(restored.modbusNode!.serverAlias, 'plc1');
      expect(restored.modbusNode!.registerType, ModbusRegisterType.holdingRegister);
      expect(restored.modbusNode!.address, 100);
      expect(restored.modbusNode!.dataType, ModbusDataType.float32);
      expect(restored.modbusNode!.pollGroup, 'fast');
    });

    test('server returns modbusNode.serverAlias when opcua and m2400 are null', () {
      final entry = KeyMappingEntry(
        modbusNode: ModbusNodeConfig(
          serverAlias: 'plc1',
          registerType: ModbusRegisterType.coil,
          address: 0,
        ),
      );
      expect(entry.server, 'plc1');
    });

    test('server returns opcuaNode.serverAlias when both opcua and modbus exist (opcua precedence)', () {
      final entry = KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'test')
          ..serverAlias = 'opcServer',
        modbusNode: ModbusNodeConfig(
          serverAlias: 'plc1',
          registerType: ModbusRegisterType.holdingRegister,
          address: 0,
        ),
      );
      expect(entry.server, 'opcServer');
    });
  });

  group('KeyMappings with Modbus entries', () {
    test('lookupServerAlias returns correct alias for Modbus keys', () {
      final mappings = KeyMappings(nodes: {
        'modbusTemp': KeyMappingEntry(
          modbusNode: ModbusNodeConfig(
            serverAlias: 'plc1',
            registerType: ModbusRegisterType.inputRegister,
            address: 200,
          ),
        ),
      });
      expect(mappings.lookupServerAlias('modbusTemp'), 'plc1');
    });
  });

  group('OPC UA + M2400 regression (post-Modbus additions)', () {
    test('existing OPC UA config JSON round-trips unchanged', () {
      final opcConfig = OpcUAConfig()
        ..endpoint = 'opc.tcp://10.0.0.1:4840'
        ..username = 'admin'
        ..password = 'secret'
        ..serverAlias = 'myOpc';

      final json = opcConfig.toJson();
      final restored = OpcUAConfig.fromJson(json);
      expect(restored.endpoint, 'opc.tcp://10.0.0.1:4840');
      expect(restored.username, 'admin');
      expect(restored.password, 'secret');
      expect(restored.serverAlias, 'myOpc');
    });

    test('existing M2400 config JSON round-trips unchanged', () {
      final config = M2400Config(host: '10.0.0.1', port: 52211);
      config.serverAlias = 'scale1';
      final json = config.toJson();
      final restored = M2400Config.fromJson(json);
      expect(restored.host, '10.0.0.1');
      expect(restored.port, 52211);
      expect(restored.serverAlias, 'scale1');
    });

    test('KeyMappingEntry with only opcuaNode still works (modbusNode is null)', () {
      final entry = KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'test')
          ..serverAlias = 'myOpc',
      );
      final json = entry.toJson();
      final restored = KeyMappingEntry.fromJson(json);
      expect(restored.opcuaNode, isNotNull);
      expect(restored.m2400Node, isNull);
      expect(restored.modbusNode, isNull);
      expect(restored.server, 'myOpc');
    });
  });
}

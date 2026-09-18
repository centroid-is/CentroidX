import 'dart:convert';

import 'package:open62541/open62541_types.dart' show DynamicValue, NodeId;
import 'package:tfc_dart/core/state_man.dart'
    show
        KeyMappingEntry,
        KeyMappings,
        ModbusNodeConfig,
        ModbusRegisterType,
        OpcUaStateMan,
        StateMan;
import 'package:tfc_dart/core/modbus_client_wrapper.dart' show ModbusDataType;
import 'package:test/test.dart';

void main() {
  group('OpcUaStateMan.applyBitMask helper', () {
    test('returns value unchanged when bitMask is null', () {
      final dv = DynamicValue(value: 0x1234, typeId: NodeId.uint16);
      final result = OpcUaStateMan.applyBitMask(dv, null, null);
      expect(result.value, equals(0x1234));
      expect(result.typeId, equals(NodeId.uint16));
    });

    test('mask=0x00FF shift=0 raw=0x1234 returns 0x34', () {
      final dv = DynamicValue(value: 0x1234, typeId: NodeId.uint16);
      final result = OpcUaStateMan.applyBitMask(dv, 0x00FF, 0);
      expect(result.value, equals(0x34));
      expect(result.typeId, equals(NodeId.uint16));
    });

    test('mask=0xFF00 shift=8 raw=0x1234 returns 0x12', () {
      final dv = DynamicValue(value: 0x1234, typeId: NodeId.uint16);
      final result = OpcUaStateMan.applyBitMask(dv, 0xFF00, 8);
      expect(result.value, equals(0x12));
      expect(result.typeId, equals(NodeId.uint16));
    });

    test('single-bit mask=0x0008 shift=3 raw=0x000F returns bool true', () {
      final dv = DynamicValue(value: 0x000F, typeId: NodeId.uint16);
      final result = OpcUaStateMan.applyBitMask(dv, 0x0008, 3);
      expect(result.value, isA<bool>());
      expect(result.value, isTrue);
      expect(result.typeId, equals(NodeId.boolean));
    });

    test('single-bit mask=0x0008 shift=3 raw=0x0004 returns bool false', () {
      // 0x0004 = 0b0100, bit 3 is 0
      final dv = DynamicValue(value: 0x0004, typeId: NodeId.uint16);
      final result = OpcUaStateMan.applyBitMask(dv, 0x0008, 3);
      expect(result.value, isA<bool>());
      expect(result.value, isFalse);
      expect(result.typeId, equals(NodeId.boolean));
    });

    test('returns value unchanged when value is not num', () {
      final dv = DynamicValue(value: 'hello', typeId: NodeId.uastring);
      final result = OpcUaStateMan.applyBitMask(dv, 0xFF, 0);
      expect(result.value, equals('hello'));
      expect(result.typeId, equals(NodeId.uastring));
    });

    test('handles null bitShift (defaults to 0)', () {
      final dv = DynamicValue(value: 0x1234, typeId: NodeId.uint16);
      final result = OpcUaStateMan.applyBitMask(dv, 0x00FF, null);
      expect(result.value, equals(0x34));
    });
  });

  group('KeyMappingEntry bitMask/bitShift JSON', () {
    test('round-trips bitMask=0xFF and bitShift=0 through JSON', () {
      final entry = KeyMappingEntry(
        modbusNode: ModbusNodeConfig(
          serverAlias: 'plc_1',
          registerType: ModbusRegisterType.holdingRegister,
          address: 100,
          dataType: ModbusDataType.uint16,
        ),
      )
        ..bitMask = 0xFF
        ..bitShift = 0;

      final json = entry.toJson();
      expect(json['bit_mask'], equals(0xFF));
      expect(json['bit_shift'], equals(0));

      final restored = KeyMappingEntry.fromJson(json);
      expect(restored.bitMask, equals(0xFF));
      expect(restored.bitShift, equals(0));
    });

    test('deserializes with null values when bitMask/bitShift absent (backward compat)', () {
      final json = {
        'modbus_node': {
          'server_alias': 'plc_1',
          'register_type': 'holdingRegister',
          'address': 100,
          'data_type': 'uint16',
        },
      };
      final entry = KeyMappingEntry.fromJson(json);
      expect(entry.bitMask, isNull);
      expect(entry.bitShift, isNull);
    });
  });
}

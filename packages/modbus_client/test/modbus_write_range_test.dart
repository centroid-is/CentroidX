/// A write the register cannot hold is refused, never narrowed.
///
/// Every integer register used to hand its raw value straight to a
/// `ByteData.setXxx`, and every one of those masks silently. Measured on a
/// `ModbusUint16Register` before this file existed — the PDU's value word,
/// as the device would have read it:
///
///   * 70000 → 4464
///   * 65536 → 0
///   * 5.9   → 5
///   * -5    → 65531
///
/// The device acknowledges every one of those, so the layer above reports the
/// write applied. On a plant that is a machine doing something nobody asked
/// for, confirmed by the layer that is supposed to catch it. So each case here
/// asserts on the VALUE: the number that must not reach the wire, and the
/// number that does when the value is legitimate.
library modbus_write_range_test;

import 'dart:typed_data';

import 'package:modbus_client/modbus_client.dart';
import 'package:test/test.dart';

/// The value word of a single-register write PDU, as the device reads it.
int fc06Value(ModbusWriteRequest request) =>
    ByteData.sublistView(request.protocolDataUnit).getUint16(3);

/// The register bytes of a multiple-register write PDU.
ByteData fc16Bytes(ModbusWriteRequest request) =>
    ByteData.sublistView(request.protocolDataUnit, 6);

Matcher refused = throwsA(isA<ModbusException>()
    .having((e) => e.context, 'context',
        ModbusNumRegister.writeRefusalContext)
    .having((e) => e.msg, 'msg', contains('nothing was sent')));

void main() {
  group('a 16-bit unsigned register', () {
    final reg = ModbusUint16Register(
        name: 'r', address: 0, type: ModbusElementType.holdingRegister);

    test('70000 is refused, not sent as 4464', () {
      expect(() => reg.getWriteRequest(70000), refused);
    });

    test('65536 is refused, not sent as 0', () {
      expect(() => reg.getWriteRequest(65536), refused);
    });

    test('-5 is refused, not sent as 65531', () {
      expect(() => reg.getWriteRequest(-5), refused);
    });

    test('5.9 is refused, not sent as 5', () {
      expect(() => reg.getWriteRequest(5.9), refused);
    });

    test('a bool or a String is refused as a type, not coerced', () {
      expect(() => reg.getWriteRequest(true), refused);
      expect(() => reg.getWriteRequest('5'), refused);
    });

    test('the bounds themselves, and a whole-number double, go through '
        'unchanged', () {
      expect(fc06Value(reg.getWriteRequest(65535)), 65535);
      expect(fc06Value(reg.getWriteRequest(0)), 0);
      expect(fc06Value(reg.getWriteRequest(5.0)), 5,
          reason: 'a slider at 5.0 is a legitimate write of 5');
    });

    test('rawValue skips the engineering conversion, not the range check', () {
      expect(() => reg.getWriteRequest(70000, rawValue: true), refused);
      expect(fc06Value(reg.getWriteRequest(7, rawValue: true)), 7);
    });
  });

  group('a 16-bit signed register', () {
    final reg = ModbusInt16Register(
        name: 'r', address: 0, type: ModbusElementType.holdingRegister);

    test('40000 is refused, not sent as -25536', () {
      expect(() => reg.getWriteRequest(40000), refused);
      expect(() => reg.getWriteRequest(-40000), refused);
    });

    test('the negative bound is carried as its two\'s complement', () {
      expect(fc06Value(reg.getWriteRequest(-32768)), 0x8000);
      expect(fc06Value(reg.getWriteRequest(-1)), 0xFFFF);
    });
  });

  group('a multi-register integer is checked before its bytes exist', () {
    test('5000000000 into an Int32 is refused, not sent as 705032704', () {
      final reg = ModbusInt32Register(
          name: 'r', address: 0, type: ModbusElementType.holdingRegister);
      expect(() => reg.getWriteRequest(5000000000), refused);
      expect(fc16Bytes(reg.getWriteRequest(2147483647)).getInt32(0),
          2147483647);
    });

    test('-1 into a Uint32 is refused, not sent as 4294967295', () {
      final reg = ModbusUint32Register(
          name: 'r', address: 0, type: ModbusElementType.holdingRegister);
      expect(() => reg.getWriteRequest(-1), refused);
      expect(fc16Bytes(reg.getWriteRequest(4294967295)).getUint32(0),
          4294967295);
    });

    test('a magnitude a double cannot carry back is refused rather than '
        'saturated', () {
      // `1e30.toInt()` is int64-max on the VM, not a throw; without the
      // round-trip check a LINT register would take 9223372036854775807.
      final reg = ModbusInt64Register(
          name: 'r', address: 0, type: ModbusElementType.holdingRegister);
      expect(() => reg.getWriteRequest(1e30), refused);
    });
  });

  group('the engineering conversion', () {
    test('a value that is a whole number of counts after scaling is accepted, '
        'and IEEE-754 noise is not mistaken for a fraction', () {
      final reg = ModbusUint16Register(
          name: 'r',
          address: 0,
          type: ModbusElementType.holdingRegister,
          multiplier: 0.1);
      // 5.9 / 0.1 is 58.99999999999999 in floating point; the count is 59.
      expect(fc06Value(reg.getWriteRequest(5.9)), 59);
    });

    test('a value that is a fraction of a count is refused, not truncated', () {
      final reg = ModbusUint16Register(
          name: 'r',
          address: 0,
          type: ModbusElementType.holdingRegister,
          multiplier: 0.5);
      // 5.9 / 0.5 = 11.8 counts: the old `~/` sent 11, which reads back 5.5.
      expect(() => reg.getWriteRequest(5.9), refused);
    });
  });

  group('a floating-point register', () {
    test('a 32-bit float refuses a magnitude that would reach the wire as '
        'infinity, and carries an ordinary value', () {
      final reg = ModbusFloatRegister(
          name: 'r', address: 0, type: ModbusElementType.holdingRegister);
      expect(() => reg.getWriteRequest(1e39), refused);
      expect(fc16Bytes(reg.getWriteRequest(1.5)).getFloat32(0), 1.5);
      expect(fc16Bytes(reg.getWriteRequest(7)).getFloat32(0), 7.0,
          reason: 'an int typed into a float setpoint is the same number');
    });

    test('a 64-bit double carries anything finite', () {
      final reg = ModbusDoubleRegister(
          name: 'r', address: 0, type: ModbusElementType.holdingRegister);
      expect(fc16Bytes(reg.getWriteRequest(1e39)).getFloat64(0), 1e39);
    });
  });

  group('a coil', () {
    final coil = ModbusCoil(name: 'c', address: 0);

    test('takes a bool, or exactly 0 and 1', () {
      expect(fc06Value(coil.getWriteRequest(true)), 0xFF00);
      expect(fc06Value(coil.getWriteRequest(false)), 0x0000);
      expect(fc06Value(coil.getWriteRequest(1)), 0xFF00);
      expect(fc06Value(coil.getWriteRequest(0)), 0x0000);
    });

    test('refuses anything that does not name one of its two states, '
        'instead of energising on it', () {
      // Every one of these used to be "not zero, therefore on".
      expect(() => coil.getWriteRequest(2), refused);
      expect(() => coil.getWriteRequest(5.5), refused);
      expect(() => coil.getWriteRequest('off'), refused);
      expect(() => coil.getWriteRequest(null), refused);
    });
  });
}

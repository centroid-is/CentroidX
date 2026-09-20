/// **What a register can hold**, judged per type and never by example.
///
/// The Modbus write path had no guard in front of the wire. `shapeOpcUaWrite`
/// decides what the OPC UA path sends and refuses what does not fit; nothing
/// did the same for a register, so the value went from the composer to
/// `modbus_client`'s `ByteData.setUint16` untouched, and `setUint16` masks.
/// Measured on a uint16 register before this file existed: 70000 reached the
/// wire as 4464, 65536 as 0, 5.9 as 5, −5 as 65531 — the device acknowledged
/// each one and the operator was told `applied`. The box erectors on the
/// customer's plant are behind exactly this path.
///
/// Two claims, per type:
///
///  1. **Every value a register can carry goes through as the same number**,
///     and as the Dart type the wrapper's own doc names for the register.
///  2. **A value a register cannot carry is REFUSED**, under the same two
///     reason codes the OPC UA path uses, so an operator reads one explanation
///     whichever protocol the tag is behind. Never clamped, never rounded,
///     never sign-flipped.
///
/// No server, no socket, no adapter: `shapeModbusWrite` is a pure decision
/// over the mapping entry's declared type, and that is what lets a table this
/// wide run on every platform in the matrix.
library;

import 'package:tfc_dart/core/modbus_client_wrapper.dart' show ModbusDataType;
import 'package:tfc_dart/core/state_man_types.dart' show ModbusRegisterType;
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:test/test.dart';

ModbusWrite shape(Object? value,
        {ModbusDataType dataType = ModbusDataType.uint16,
        ModbusRegisterType registerType = ModbusRegisterType.holdingRegister,
        int? bitMask,
        int? bitShift,
        bool bySymbol = false}) =>
    shapeModbusWrite(value,
        registerType: registerType,
        dataType: dataType,
        bitMask: bitMask,
        bitShift: bitShift,
        bySymbol: bySymbol);

/// What reached the adapter — the assertion is on the VALUE.
Object sent(ModbusWrite shaped) => switch (shaped) {
      ModbusWriteReady(value: final value) => value,
      ModbusWriteRefused(reason: final reason) =>
        fail('refused (${reason.kind}): ${reason.message}'),
    };

Matcher refusedAs(String code) => isA<ModbusWriteRefused>()
    .having((r) => r.reason.kind, 'reason.kind', code)
    .having((r) => r.reason.message, 'reason.message',
        contains('nothing was sent'));

final Matcher outOfRange = refusedAs(writeValueOutOfRangeCode);
final Matcher typeMismatch = refusedAs(writeTypeMismatchCode);

void main() {
  group('the measured uint16 cases: refused, not narrowed', () {
    test('70000 is refused, not sent as 4464', () {
      expect(shape(70000), outOfRange);
    });

    test('65536 is refused, not sent as 0', () {
      expect(shape(65536), outOfRange);
    });

    test('-5 is refused, not sent as 65531', () {
      expect(shape(-5), outOfRange);
    });

    test('5.9 is refused, not sent as 5', () {
      expect(shape(5.9), outOfRange);
    });

    test('and the values that fit go through as the same number', () {
      expect(sent(shape(65535)), 65535);
      expect(sent(shape(0)), 0);
      expect(sent(shape(5.0)), 5,
          reason: 'a slider at 5.0 is a legitimate write of 5, handed over as '
              'an int because that is what the register holds and what the '
              'poll delivers back');
      expect(sent(shape(5.0)), isA<int>());
    });
  });

  group('every integer width has its own bounds', () {
    test('int16', () {
      expect(sent(shape(-32768, dataType: ModbusDataType.int16)), -32768);
      expect(sent(shape(32767, dataType: ModbusDataType.int16)), 32767);
      expect(shape(40000, dataType: ModbusDataType.int16), outOfRange,
          reason: 'setInt16 would have sent -25536');
      expect(shape(-40000, dataType: ModbusDataType.int16), outOfRange);
    });

    test('int32', () {
      expect(sent(shape(2147483647, dataType: ModbusDataType.int32)),
          2147483647);
      expect(shape(5000000000, dataType: ModbusDataType.int32), outOfRange,
          reason: 'setInt32 would have sent 705032704 — the OPC UA file\'s '
              'own measured number, and the same defect');
    });

    test('uint32', () {
      expect(sent(shape(4294967295, dataType: ModbusDataType.uint32)),
          4294967295);
      expect(shape(-1, dataType: ModbusDataType.uint32), outOfRange,
          reason: 'setUint32 would have sent 4294967295');
    });

    test('int64 takes the whole Dart int, uint64 stops at 2^63-1', () {
      expect(
          sent(shape(-9223372036854775808, dataType: ModbusDataType.int64)),
          -9223372036854775808);
      expect(sent(shape(9223372036854775807, dataType: ModbusDataType.uint64)),
          9223372036854775807);
      expect(shape(-1, dataType: ModbusDataType.uint64), outOfRange);
    });

    test('a magnitude a double cannot carry back is refused rather than '
        'saturated', () {
      // `1e30.toInt()` is int64-max on the VM. Without the round trip a LINT
      // register would take 9223372036854775807 and report it applied.
      expect(shape(1e30, dataType: ModbusDataType.int64), outOfRange);
    });

    test('`bit` on a holding register is the uint16 element the wrapper builds '
        'for it, and a bool into it is a mismatch that names the fix', () {
      expect(sent(shape(1, dataType: ModbusDataType.bit)), 1);
      expect(shape(70000, dataType: ModbusDataType.bit), outOfRange);
      expect(shape(true, dataType: ModbusDataType.bit), typeMismatch);
      expect(
          (shape(true, dataType: ModbusDataType.bit) as ModbusWriteRefused)
              .reason
              .message,
          contains('bit_mask'));
    });
  });

  group('a type the register cannot take at all', () {
    test('a String, a bool or a DateTime into a numeric register', () {
      expect(shape('5'), typeMismatch,
          reason: 'the element would have thrown a NoSuchMethodError from '
              'inside its arithmetic, which reaches the operator as "unknown"');
      expect(shape(true), typeMismatch);
      expect(shape(DateTime.utc(2026)), typeMismatch);
    });

    test('a null, a List and a Map are refused before anything is built', () {
      expect(shape(null), typeMismatch);
      expect(shape(<int>[1, 2]), typeMismatch);
      expect(shape(<String, int>{'a': 1}), typeMismatch);
    });
  });

  group('a floating-point register', () {
    test('float32 carries a number, takes an int as the same number, and '
        'refuses a magnitude that would reach the wire as infinity', () {
      expect(sent(shape(1.5, dataType: ModbusDataType.float32)), 1.5);
      expect(sent(shape(7, dataType: ModbusDataType.float32)), 7.0);
      expect(sent(shape(7, dataType: ModbusDataType.float32)), isA<double>());
      expect(shape(1e39, dataType: ModbusDataType.float32), outOfRange);
      expect(shape('1.5', dataType: ModbusDataType.float32), typeMismatch);
    });

    test('float64 carries anything finite', () {
      expect(sent(shape(1e39, dataType: ModbusDataType.float64)), 1e39);
    });
  });

  group('a coil', () {
    test('takes a bool, or exactly 0 and 1, and hands the adapter a bool', () {
      expect(sent(shape(true, registerType: ModbusRegisterType.coil)), true);
      expect(sent(shape(false, registerType: ModbusRegisterType.coil)), false);
      expect(sent(shape(1, registerType: ModbusRegisterType.coil)), true);
      expect(sent(shape(0, registerType: ModbusRegisterType.coil)), false);
      expect(sent(shape(1.0, registerType: ModbusRegisterType.coil)), true);
    });

    test('refuses anything that does not name one of its two states', () {
      // Every one of these used to energise the coil: the element read "not
      // zero, therefore on".
      expect(shape(2, registerType: ModbusRegisterType.coil), typeMismatch);
      expect(shape(5.5, registerType: ModbusRegisterType.coil), typeMismatch);
      expect(shape('off', registerType: ModbusRegisterType.coil), typeMismatch);
    });
  });

  group('a read-only register type', () {
    test('is refused under the gateway\'s one spelling of not-writable', () {
      for (final type in [
        ModbusRegisterType.discreteInput,
        ModbusRegisterType.inputRegister,
      ]) {
        final shaped = shape(1, registerType: type);
        expect(shaped, isA<ModbusWriteRefused>());
        expect((shaped as ModbusWriteRefused).reason, same(notWritableReason),
            reason: 'the wrapper throws an ArgumentError for these, which the '
                'link grades `unknown` — for a write that was never sent');
      }
    });
  });

  group('a bit-masked field', () {
    test('a single-bit mask is a boolean field: bool or 0/1 in, bool out', () {
      expect(sent(shape(true, bitMask: 0x0004)), true);
      expect(sent(shape(0, bitMask: 0x0004)), false);
      expect(sent(shape(1, bitMask: 0x0004)), true);
      expect(shape(2, bitMask: 0x0004), typeMismatch,
          reason: 'the adapter read `value == true || value == 1` and treated '
              'a 2 as false — a bit cleared by a value that was not a state');
    });

    test('a multi-bit field takes what fits and refuses what the RMW would '
        'have dropped', () {
      // A four-bit field at bits 4..7: values 0..15.
      expect(sent(shape(15, bitMask: 0x00F0, bitShift: 4)), 15);
      expect(sent(shape(0, bitMask: 0x00F0, bitShift: 4)), 0);
      expect(shape(16, bitMask: 0x00F0, bitShift: 4), outOfRange,
          reason: '(16 << 4) & 0xF0 is 0: the adapter would have written 0 '
              'into the field and reported 16 applied');
      expect(shape(20, bitMask: 0x00F0, bitShift: 4), outOfRange,
          reason: 'and 20 would have landed as 4');
      expect(shape(-1, bitMask: 0x00F0, bitShift: 4), outOfRange);
      expect(shape(2.5, bitMask: 0x00F0, bitShift: 4), outOfRange);
      expect(shape(true, bitMask: 0x00F0, bitShift: 4), typeMismatch);
      expect(shape('3', bitMask: 0x00F0, bitShift: 4), typeMismatch);
    });

    test('a non-contiguous mask refuses a value whose bits fall in its gaps',
        () {
      // Bits 0 and 2: 0b101. A 3 (0b011) has bit 1 set, which the mask drops.
      expect(sent(shape(5, bitMask: 0x0005)), 5);
      expect(shape(3, bitMask: 0x0005), outOfRange);
    });

    test('an empty mask can carry nothing and says so', () {
      expect(shape(1, bitMask: 0), outOfRange);
    });
  });

  group('a UMAS-by-symbol key', () {
    test('passes a scalar through untouched — the PLC\'s declared type is the '
        'encoder\'s to enforce — and refuses what no encoder has a case for',
        () {
      expect(sent(shape(70000, bySymbol: true)), 70000,
          reason: 'this layer cannot see the symbol\'s width; the encoder '
              '(umas_types.dart:991, TD-006) refuses 70000 into an INT by name '
              'and the link grades that refusal as out_of_range');
      expect(sent(shape(5.9, bySymbol: true)), 5.9);
      expect(sent(shape(true, bySymbol: true)), true);
      expect(sent(shape('run', bySymbol: true)), 'run');
      expect(shape(null, bySymbol: true), typeMismatch);
      expect(shape(DateTime.utc(2026), bySymbol: true), typeMismatch);
      expect(shape(<int>[1], bySymbol: true), typeMismatch);
    });
  });
}

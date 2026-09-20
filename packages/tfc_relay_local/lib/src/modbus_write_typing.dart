/// **What a register can hold**, decided before anything is sent.
///
/// `opcua_write_typing.dart` states the doctrine for the OPC UA path and this
/// file makes the register map obey it: a value the tag cannot represent is
/// **refused**, never clamped and never truncated. Clamping actuates with a
/// value nobody chose; truncating actuates with a different one and calls it
/// applied. That is the OPC UA file's failure mode 3, and until this file
/// existed the Modbus path had nothing in front of it.
///
/// ## What the path did without a guard
///
/// `ModbusUpstreamLink.performWrite` handed the raw value to the adapter
/// (`modbus_device_client.dart:1258-1296`), which handed it to the wrapper
/// (`modbus_client_wrapper.dart:638-650`), which handed it to
/// `modbus_client`'s element, whose `_getRawValue` did `(value - offset) ~/
/// multiplier` and then a `ByteData.setUint16` — which masks silently.
/// Measured on a uint16 register: 70000 went to the wire as 4464, 65536 as 0,
/// 5.9 as 5 and −5 as 65531. The device acknowledged every one, and the write
/// was reported `WriteApplied`. This is live on the customer's plant: the box
/// erectors BER02/BER03 are Saia-over-Modbus.
///
/// `modbus_client` now refuses those at the element (`modbus_element_num.dart`,
/// `writeRefusalContext`), which is the backstop for every caller of that
/// package. This file is the **named** refusal one layer up: an element throw
/// reaches `classifyWriteError` as text, and text this gateway cannot read as
/// a refusal is graded `unknown` — the honest answer for a lost answer and the
/// wrong one for a write that never left this process. Deciding it here, from
/// the mapping entry, makes it a `rejected` with evidence and with the **same
/// two reason codes the OPC UA path uses** ([writeValueOutOfRangeCode],
/// [writeTypeMismatchCode]), so an operator reads one explanation whichever
/// protocol the tag is behind.
///
/// ## Where the type comes from
///
/// The register map. `ModbusNodeConfig.dataType` and `.registerType` are the
/// declared width and kind, and `KeyMappingEntry.bitMask`/`bitShift` narrow a
/// register to a field. The link records them in `claim`, which is the one
/// place it sees the entry, and shapes every write against them. Nothing is
/// read from the device: a register has no type attribute to ask for.
///
/// A UMAS-by-symbol key is the exception — its type is the PLC's declared
/// one, resolved by the adapter's symbol cache, and this layer cannot see it.
/// For those keys only the shape is checked here; the width is the encoder's
/// (`umas_types.dart:991`, TD-006), which already refuses by name, and the
/// link's `classifyWriteError` turns that refusal into the same two codes.
///
/// ## The bit-masked field
///
/// A masked key is a read-modify-write of a whole register
/// (`modbus_device_client.dart:1266-1290`). Its multi-bit arm does
/// `(value << shift) & mask`, which drops every bit that does not fit the
/// field — a 20 written into a four-bit field lands as 4. Its single-bit arm
/// reads `value == true || value == 1` and treats anything else as false, so
/// a 2 clears a bit. Both are the same silent narrowing in a smaller frame,
/// and both are refused here before the read half of the RMW runs.
library;

import 'package:tfc_dart/core/modbus_client_wrapper.dart' show ModbusDataType;
import 'package:tfc_dart/core/state_man_types.dart' show ModbusRegisterType;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' show WriteReason;

import 'opcua_write_typing.dart'
    show
        integralValueOf,
        maxFiniteFloat32,
        writeTypeMismatchCode,
        writeValueOutOfRangeCode;
import 'write_translation.dart' show notWritableReason;

/// The result of shaping one relay value for one Modbus/UMAS key.
sealed class ModbusWrite {
  const ModbusWrite();
}

/// The register can hold [value], and this is what the adapter is handed.
///
/// A `bool` for a coil or a single-bit field, an `int` for an integer register
/// or a multi-bit field, a `double` for a float register — the Dart type the
/// wrapper's own doc names for each (`modbus_client_wrapper.dart:628-632`), so
/// the optimistic echo it pushes after the ack carries the same type the poll
/// delivers.
final class ModbusWriteReady extends ModbusWrite {
  const ModbusWriteReady(this.value);

  final Object value;
}

/// The register **cannot** hold the value, and nothing was sent.
///
/// A refusal decided before the crossing, so "rejected" is a claim with
/// evidence. The reason is a whole [WriteReason] rather than a code and a
/// sentence because one of the refusals is the gateway's single spelling of
/// "read-only" ([notWritableReason]), and re-spelling that here would give an
/// operator two refusals for one fact.
final class ModbusWriteRefused extends ModbusWrite {
  const ModbusWriteRefused(this.reason);

  final WriteReason reason;
}

/// The inclusive range each integer data type can hold.
///
/// `uint64`'s upper bound is `2^63-1` for the reason `opcua_write_typing.dart`
/// gives for `UInt64`: a Dart `int` is 64-bit signed and cannot express more,
/// so a bound written as `2^64-1` would be a check that never fires. `bit` on
/// a register is a uint16 — that is the element the wrapper builds for it
/// (`modbus_client_wrapper.dart:1149-1151`).
const Map<ModbusDataType, (int, int)> _integerRanges = <ModbusDataType, (int, int)>{
  ModbusDataType.int16: (-32768, 32767),
  ModbusDataType.uint16: (0, 65535),
  ModbusDataType.bit: (0, 65535),
  ModbusDataType.int32: (-2147483648, 2147483647),
  ModbusDataType.uint32: (0, 4294967295),
  ModbusDataType.int64: (-9223372036854775808, 9223372036854775807),
  ModbusDataType.uint64: (0, 9223372036854775807),
};

/// Shapes [value] — a raw Dart scalar — for the register the mapping names.
///
/// [registerType] and [dataType] are the entry's `modbus_node`; [bitMask] and
/// [bitShift] its field narrowing, both null for a whole-register key.
/// [bySymbol] is true for a UMAS-by-name key, whose width this layer cannot
/// know — see the library doc for what is and is not checked for one.
ModbusWrite shapeModbusWrite(
  Object? value, {
  required ModbusRegisterType registerType,
  required ModbusDataType dataType,
  int? bitMask,
  int? bitShift,
  bool bySymbol = false,
}) {
  if (value == null) {
    return const ModbusWriteRefused(WriteReason(writeTypeMismatchCode,
        message: 'a null is not a value to write to a register; nothing was '
            'sent'));
  }
  if (value is List || value is Map) {
    // A register is a scalar. The adapter would take `value is num ? … : 0`
    // on the masked path and throw a NoSuchMethodError on the plain one;
    // neither is a refusal an operator can read.
    return ModbusWriteRefused(WriteReason(writeTypeMismatchCode,
        message: 'a ${value.runtimeType} is not a scalar; a register holds '
            'one number or one bit, and nothing was sent'));
  }

  if (bySymbol) {
    // The PLC's declared type decides the width, in the encoder. What can be
    // decided here is only that the payload is a kind the encoder has any
    // case for at all (`umas_types.dart:1003-1150`: bool, int, double, String).
    if (value is bool || value is num || value is String) {
      return ModbusWriteReady(value);
    }
    return ModbusWriteRefused(WriteReason(writeTypeMismatchCode,
        message: 'a ${value.runtimeType} has no UMAS encoding; nothing was '
            'sent'));
  }

  switch (registerType) {
    case ModbusRegisterType.discreteInput:
    case ModbusRegisterType.inputRegister:
      // The wrapper throws an ArgumentError for these
      // (`modbus_client_wrapper.dart:690-697`), which reaches the link as text
      // and is graded `unknown` — for a write that was never sent. Refused
      // here under the gateway's one spelling of read-only instead.
      return const ModbusWriteRefused(notWritableReason);

    case ModbusRegisterType.coil:
      final bit = _asBit(value);
      if (bit == null) return _mismatch(value, 'a coil');
      return ModbusWriteReady(bit);

    case ModbusRegisterType.holdingRegister:
      if (bitMask != null) {
        return _shapeField(value, mask: bitMask, shift: bitShift ?? 0);
      }
      return _shapeRegister(value, dataType);
  }
}

/// A whole holding register, by its declared data type.
ModbusWrite _shapeRegister(Object value, ModbusDataType dataType) {
  switch (dataType) {
    case ModbusDataType.float32:
    case ModbusDataType.float64:
      if (value is! num) {
        return _mismatch(value, 'a ${dataType.name} register');
      }
      final asDouble = value.toDouble();
      if (dataType == ModbusDataType.float32 &&
          asDouble.isFinite &&
          asDouble.abs() > maxFiniteFloat32) {
        // `setFloat32` turns this into infinity on the wire — the OPC UA
        // file's Float refusal, for the same register width.
        return ModbusWriteRefused(WriteReason(writeValueOutOfRangeCode,
            message: '$value does not fit a float32 register, whose largest '
                'finite magnitude is $maxFiniteFloat32; nothing was sent'));
      }
      return ModbusWriteReady(asDouble);

    case ModbusDataType.bit:
    case ModbusDataType.int16:
    case ModbusDataType.uint16:
    case ModbusDataType.int32:
    case ModbusDataType.uint32:
    case ModbusDataType.int64:
    case ModbusDataType.uint64:
      if (value is bool) {
        // `data_type: bit` on a holding register is still a uint16 element
        // and the wrapper's encoder has no case for a bool; the mapping that
        // means "one bit of this register" is a `bit_mask`.
        return ModbusWriteRefused(WriteReason(writeTypeMismatchCode,
            message: 'a bool cannot be written to a whole ${dataType.name} '
                'register; a single bit of a register is addressed with a '
                'bit_mask, and nothing was sent'));
      }
      if (value is double) {
        // Not a type mismatch — a whole-number double IS writable to an
        // integer register. A fractional one is refused rather than rounded:
        // `~/` is what turned 5.9 into 5, and nothing downstream would ever
        // mention it.
        final whole = integralValueOf(value);
        if (whole == null) {
          return ModbusWriteRefused(WriteReason(writeValueOutOfRangeCode,
              message: '$value cannot be written to a ${dataType.name} '
                  'register as the same number; nothing was sent, because '
                  'rounding or saturating a setpoint is a change no readback '
                  'can show as one'));
        }
        return _rangedInteger(whole, dataType);
      }
      final asInt = integralValueOf(value);
      if (asInt == null) {
        return _mismatch(value, 'a ${dataType.name} register');
      }
      return _rangedInteger(asInt, dataType);
  }
}

/// One integer, range-checked against [dataType].
ModbusWrite _rangedInteger(int value, ModbusDataType dataType) {
  final range = _integerRanges[dataType]!;
  if (value < range.$1 || value > range.$2) {
    return ModbusWriteRefused(WriteReason(writeValueOutOfRangeCode,
        message: '$value does not fit ${dataType.name} '
            '(${range.$1}..${range.$2}); nothing was sent, so the register '
            'still holds what it held'));
  }
  return ModbusWriteReady(value);
}

/// A bit-masked field of a holding register.
///
/// Mirrors the adapter's own split (`modbus_device_client.dart:1272-1273`):
/// a mask with exactly one bit set is a boolean field, anything else is a
/// small integer written with `(value << shift) & mask`.
ModbusWrite _shapeField(Object value, {required int mask, required int shift}) {
  if (mask == 0) {
    // `(x << shift) & 0` is zero, so the RMW would write the register back
    // unchanged and report the value applied.
    return const ModbusWriteRefused(WriteReason(writeValueOutOfRangeCode,
        message: 'an empty bit_mask addresses no bits of the register, so no '
            'value can be written through it; nothing was sent'));
  }
  final single = (mask & (mask - 1)) == 0;
  if (single) {
    final bit = _asBit(value);
    if (bit == null) return _mismatch(value, 'a single-bit field');
    return ModbusWriteReady(bit);
  }
  if (value is bool) return _mismatch(value, 'a multi-bit field');
  final asInt = integralValueOf(value);
  if (asInt == null) {
    return value is double
        ? ModbusWriteRefused(WriteReason(writeValueOutOfRangeCode,
            message: '$value is not a whole number and a bit field cannot '
                'carry a fraction; nothing was sent'))
        : _mismatch(value, 'a multi-bit field');
  }
  // `mask >> shift` bounds the field before the shift below can overflow a
  // 64-bit int; the second test is what catches a non-contiguous mask.
  if (asInt < 0 ||
      asInt > (mask >> shift) ||
      ((asInt << shift) & mask) != (asInt << shift)) {
    return ModbusWriteRefused(WriteReason(writeValueOutOfRangeCode,
        message: '$asInt does not fit the field selected by bit_mask '
            '0x${mask.toRadixString(16)} (shift $shift), whose largest value '
            'is ${mask >> shift}; nothing was sent, because the '
            'read-modify-write would have dropped the bits that do not fit'));
  }
  return ModbusWriteReady(asInt);
}

/// [value] as a bool, or null when it does not name one of the two states.
///
/// A `bool`, or exactly `0`/`1` (an `int`, or a double that is one of them):
/// the two spellings a control surface sends for a bit. The adapter's masked
/// arm accepted `value == true || value == 1` and read everything else as
/// false, and `modbus_client`'s coil encoder read everything non-zero as on;
/// a `2` therefore cleared a bit on one path and set a coil on the other.
bool? _asBit(Object value) {
  if (value is bool) return value;
  final asInt = integralValueOf(value);
  if (asInt == 0) return false;
  if (asInt == 1) return true;
  return null;
}

ModbusWrite _mismatch(Object value, String target) =>
    ModbusWriteRefused(WriteReason(writeTypeMismatchCode,
        message: 'a ${value.runtimeType} cannot be written to $target; '
            'nothing was sent'));

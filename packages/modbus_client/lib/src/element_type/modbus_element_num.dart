part of '../modbus_element.dart';

/// A numeric register where [type] can be [ModbusElementType.inputRegister] or
/// [ModbusElementType.inputRegister]. The returned device value
/// (i.e. raw value) can be of type Int16, Uint16, Int32 or Uint32.
///
/// This raw value might be converted into an engineering value by this formula:
///    engineering value = raw value * [multiplier] + [offset]
///
/// The string representation of the engineering value can have a unit of
/// measure [uom] and rounded decimal places [viewDecimalPlaces].
abstract class ModbusNumRegister<T extends num> extends ModbusElement<T> {
  final double multiplier;
  final double offset;
  final String uom;
  final int viewDecimalPlaces;

  /// The inclusive bounds of the raw counts an integer register can carry;
  /// both null for a floating-point register.
  ///
  /// Written out per class rather than derived from [byteCount] and a sign
  /// bit, so the number a refusal names is the number the wire can hold and
  /// not an expression somebody has to evaluate at three in the morning.
  /// `ModbusUint64Register`'s upper bound is `2^63-1` rather than `2^64-1`
  /// because a Dart `int` is 64-bit **signed** and cannot express anything
  /// above it — a bound written as `2^64-1` would be a check that never fires
  /// pretending to be one that does. Two getters and not a record because this
  /// package still declares a 2.17 SDK floor.
  int? get rawMinimum;
  int? get rawMaximum;

  /// The largest finite IEEE-754 **single**, so a 32-bit float register can
  /// refuse a magnitude that would reach the wire as infinity.
  static const double maxFiniteFloat32 = 3.4028234663852886e38;

  /// The [ModbusException.context] every refusal below carries, so a caller
  /// that wants to tell "nothing was sent" from "the device answered" can do
  /// it by name rather than by parsing the sentence.
  static const String writeRefusalContext = 'ModbusNumRegister.getWriteRequest';

  ModbusNumRegister(
      {required super.name,
      super.description,
      super.onUpdate,
      required super.type,
      required super.address,
      required super.byteCount,
      this.uom = "",
      this.multiplier = 1,
      this.offset = 0,
      this.viewDecimalPlaces = 2,
      super.endianness = ModbusEndianness.ABCD});

  /// Builds the write request, **refusing** a value the register cannot hold.
  ///
  /// This used to hand `_getRawValue(value)` straight to `ByteData.setUint16`
  /// (and `setInt32`, `setUint64`, …), every one of which masks silently.
  /// Measured on a `ModbusUint16Register`: 70000 went to the wire as 4464,
  /// 65536 as 0, 5.9 as 5 and -5 as 65531 — and the device acknowledged each
  /// one, so the caller was told the write applied. On a plant that is a
  /// machine doing something nobody asked for, confirmed by the layer that is
  /// supposed to catch it.
  ///
  /// So the raw value is checked before a byte of it exists, and a value that
  /// does not fit throws a [ModbusException] with [writeRefusalContext]. It is
  /// never clamped and never rounded: clamping actuates with a value nobody
  /// chose, and rounding a setpoint is a change no readback can show as one.
  /// [rawValue] skips the engineering conversion, not the range check — a raw
  /// 70000 into a 16-bit register is the same truncation by another door.
  @override
  ModbusWriteRequest getWriteRequest(dynamic value,
      {bool rawValue = false,
      int? unitId,
      Duration? responseTimeout,
      ModbusEndianness? endianness}) {
    final checked = _checkedRawValue(value, rawValue: rawValue);
    if (byteCount == 2) {
      // Already converted and checked, so the base class must write it as it
      // is: `rawValue: true` is what stops it converting a second time.
      return super.getWriteRequest(checked,
          rawValue: true,
          unitId: unitId,
          responseTimeout: responseTimeout,
          endianness: endianness ?? this.endianness);
    } else {
      return getMultipleWriteRequest(_toBytes(checked),
          unitId: unitId,
          responseTimeout: responseTimeout,
          endianness: endianness ?? this.endianness);
    }
  }

  /// [value] as the raw count the wire will carry, or a [ModbusException]
  /// naming the value, the register and the bound it broke.
  num _checkedRawValue(dynamic value, {required bool rawValue}) {
    if (value is! num) {
      throw ModbusException(
          context: writeRefusalContext,
          msg: "$name: a ${value.runtimeType} cannot be written to a "
              "${runtimeType.toString().replaceFirst('Modbus', '')}; nothing "
              "was sent");
    }
    final minimum = rawMinimum;
    final maximum = rawMaximum;
    if (minimum == null || maximum == null) {
      final raw = rawValue ? value.toDouble() : _getRawValue(value).toDouble();
      if (byteCount == 4 && raw.isFinite && raw.abs() > maxFiniteFloat32) {
        // `setFloat32` turns a finite double past single precision into
        // infinity, and a device that reads infinity from a setpoint register
        // is a device with a setpoint nobody chose.
        throw ModbusException(
            context: writeRefusalContext,
            msg: "$name: $value does not fit a 32-bit float register, whose "
                "largest finite magnitude is $maxFiniteFloat32; nothing was "
                "sent");
      }
      return raw;
    }
    // Real division, not `~/`: the truncating operator is what turned 5.9
    // into 5, and a whole-number check needs the fraction it threw away.
    final num raw = rawValue ? value : (value - offset) / multiplier;
    final counts = _wholeNumber(raw);
    if (counts == null) {
      throw ModbusException(
          context: writeRefusalContext,
          msg: "$name: $value is not a whole number of raw counts"
              "${multiplier == 1 && offset == 0 ? '' : ' (multiplier $multiplier, offset $offset)'}"
              " and would be truncated on the wire; nothing was sent");
    }
    if (counts < minimum || counts > maximum) {
      throw ModbusException(
          context: writeRefusalContext,
          msg: "$name: $value does not fit $minimum..$maximum; nothing was "
              "sent, so the register still holds what it held");
    }
    return counts;
  }

  /// [raw] as an `int` that means the same number, or null.
  ///
  /// A `double` within a relative 1e-9 of an integer is accepted, because the
  /// engineering conversion is floating-point arithmetic: `5.9 / 0.1` is
  /// `58.99999999999999`, and refusing that would refuse a legitimate write
  /// for an artefact of IEEE-754. Anything further off is a fraction the
  /// wire would drop, and is refused. The round trip through `toInt()` is
  /// the magnitude check: `toInt()` saturates on the VM rather than throwing,
  /// so `1e30.toInt()` is `9223372036854775807`, and only `toDouble()` coming
  /// back equal proves the number survived.
  static int? _wholeNumber(num raw) {
    if (raw is int) return raw;
    final asDouble = raw.toDouble();
    if (!asDouble.isFinite) return null;
    final rounded = asDouble.roundToDouble();
    final tolerance = 1e-9 * (asDouble.abs() < 1 ? 1 : asDouble.abs());
    if ((asDouble - rounded).abs() > tolerance) return null;
    final asInt = rounded.toInt();
    return asInt.toDouble() == rounded ? asInt : null;
  }

  @override
  num _getRawValue(dynamic value) => (value - offset) ~/ multiplier;

  @override
  T? setValueFromBytes(Uint8List rawValues) {
    return value = (_fromBytes(rawValues) * multiplier) + offset as T;
  }

  @override
  String get _valueStr => _value == null
      ? "<none>"
      : "${_value!.toStringAsFixed(viewDecimalPlaces).replaceFirst(RegExp(r'\.?0*$'), '')}$uom";

  T _fromBytes(Uint8List bytes);

  Uint8List _toBytes(dynamic value);
}

/// A signed 16 bit register
class ModbusInt16Register extends ModbusNumRegister {
  ModbusInt16Register(
      {required super.name,
      required super.address,
      required super.type,
      super.description,
      super.onUpdate,
      super.uom,
      super.multiplier,
      super.offset,
      super.viewDecimalPlaces,
      super.endianness})
      : super(byteCount: 2);

  @override
  int? get rawMinimum => -32768;

  @override
  int? get rawMaximum => 32767;

  @override
  int _fromBytes(Uint8List bytes) => ByteData.view(bytes.buffer, 0, byteCount)
      .getInt16(0, endianness.swapByte ? Endian.little : Endian.big);

  @override
  Uint8List _toBytes(dynamic value) =>
      Uint8List(byteCount)..buffer.asByteData().setInt16(0, value);
}

/// An unsigned 16 bit register
class ModbusUint16Register extends ModbusNumRegister {
  ModbusUint16Register(
      {required super.name,
      required super.address,
      required super.type,
      super.description,
      super.onUpdate,
      super.uom,
      super.multiplier,
      super.offset,
      super.viewDecimalPlaces,
      super.endianness})
      : super(byteCount: 2);

  @override
  int? get rawMinimum => 0;

  @override
  int? get rawMaximum => 65535;

  @override
  int _fromBytes(Uint8List bytes) => bytes.buffer
      .asByteData()
      .getUint16(0, endianness.swapByte ? Endian.little : Endian.big);

  @override
  Uint8List _toBytes(dynamic value) =>
      Uint8List(byteCount)..buffer.asByteData().setUint16(0, value);
}

/// A signed 32 bit register
class ModbusInt32Register extends ModbusNumRegister {
  ModbusInt32Register(
      {required super.name,
      required super.address,
      required super.type,
      super.description,
      super.onUpdate,
      super.uom,
      super.multiplier,
      super.offset,
      super.viewDecimalPlaces,
      super.endianness})
      : super(byteCount: 4);

  @override
  int? get rawMinimum => -2147483648;

  @override
  int? get rawMaximum => 2147483647;

  @override
  int _fromBytes(Uint8List bytes) => bytes.buffer.asByteData().getInt32(0);

  @override
  Uint8List _toBytes(dynamic value) =>
      Uint8List(byteCount)..buffer.asByteData().setInt32(0, value);
}

/// An unsigned 32 bit register
class ModbusUint32Register extends ModbusNumRegister {
  ModbusUint32Register(
      {required super.name,
      required super.address,
      required super.type,
      super.uom,
      super.description,
      super.onUpdate,
      super.multiplier,
      super.offset,
      super.viewDecimalPlaces,
      super.endianness})
      : super(byteCount: 4);

  @override
  int? get rawMinimum => 0;

  @override
  int? get rawMaximum => 4294967295;

  @override
  int _fromBytes(Uint8List bytes) => bytes.buffer.asByteData().getUint32(0);

  @override
  Uint8List _toBytes(dynamic value) =>
      Uint8List(byteCount)..buffer.asByteData().setUint32(0, value);
}


/// The 64-bit bounds, **computed rather than written as literals**.
///
/// dart2js refuses an integer literal it cannot represent exactly, and
/// ±2^63 are two of them — written out, they stopped the web bundle
/// compiling at all (this package is in the web app's import closure through
/// the asset library even though a browser never dials Modbus TCP). On the
/// VM these are exactly the int64 bounds; on the web they are the nearest
/// doubles, which is moot because no web build ever writes a register.
final int _int64Max = int.parse('9223372036854775807');
final int _int64Min = int.parse('-9223372036854775808');

/// A signed 64 bit register
class ModbusInt64Register extends ModbusNumRegister {
  ModbusInt64Register(
      {required super.name,
      required super.address,
      required super.type,
      super.description,
      super.onUpdate,
      super.uom,
      super.multiplier,
      super.offset,
      super.viewDecimalPlaces,
      super.endianness})
      : super(byteCount: 8);

  @override
  int? get rawMinimum => _int64Min;

  @override
  int? get rawMaximum => _int64Max;

  @override
  int _fromBytes(Uint8List bytes) => bytes.buffer.asByteData().getInt64(0);

  @override
  Uint8List _toBytes(dynamic value) =>
      Uint8List(byteCount)..buffer.asByteData().setInt64(0, value);
}

/// An unsigned 64 bit register
class ModbusUint64Register extends ModbusNumRegister {
  ModbusUint64Register(
      {required super.name,
      required super.address,
      required super.type,
      super.uom,
      super.description,
      super.onUpdate,
      super.multiplier,
      super.offset,
      super.viewDecimalPlaces,
      super.endianness})
      : super(byteCount: 8);

  @override
  int? get rawMinimum => 0;

  @override
  int? get rawMaximum => _int64Max;

  @override
  int _fromBytes(Uint8List bytes) => bytes.buffer.asByteData().getUint64(0);

  @override
  Uint8List _toBytes(dynamic value) =>
      Uint8List(byteCount)..buffer.asByteData().setUint64(0, value);
}

/// A 32 bit Float register
class ModbusFloatRegister extends ModbusNumRegister<double> {
  ModbusFloatRegister(
      {required super.name,
      required super.address,
      required super.type,
      super.uom,
      super.description,
      super.onUpdate,
      super.multiplier,
      super.offset,
      super.viewDecimalPlaces,
      super.endianness})
      : super(byteCount: 4);

  @override
  int? get rawMinimum => null;

  @override
  int? get rawMaximum => null;

  @override
  double _getRawValue(dynamic value) => (value - offset) / multiplier;

  @override
  double _fromBytes(Uint8List bytes) => bytes.buffer.asByteData().getFloat32(0);

  @override
  Uint8List _toBytes(dynamic value) =>
      Uint8List(byteCount)..buffer.asByteData().setFloat32(0, value);
}

/// A 64 bit Double register
class ModbusDoubleRegister extends ModbusNumRegister<double> {
  ModbusDoubleRegister(
      {required super.name,
      required super.address,
      required super.type,
      super.uom,
      super.description,
      super.onUpdate,
      super.multiplier,
      super.offset,
      super.viewDecimalPlaces,
      super.endianness})
      : super(byteCount: 8);

  @override
  int? get rawMinimum => null;

  @override
  int? get rawMaximum => null;

  @override
  double _getRawValue(dynamic value) => (value - offset) / multiplier;

  @override
  double _fromBytes(Uint8List bytes) => bytes.buffer.asByteData().getFloat64(0);

  @override
  Uint8List _toBytes(dynamic value) =>
      Uint8List(byteCount)..buffer.asByteData().setFloat64(0, value);
}

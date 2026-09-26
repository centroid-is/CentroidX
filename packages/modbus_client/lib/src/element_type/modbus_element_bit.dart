part of '../modbus_element.dart';

/// A Modbus bit value element. This is the base class of [ModbusDiscreteInput]
/// and [ModbusCoil] elements.
class ModbusBitElement extends ModbusElement<bool> {
  ModbusBitElement(
      {required super.name,
      super.description,
      required super.address,
      required super.type,
      super.onUpdate})
      : super(byteCount: 1);

  @override
  set value(dynamic newValue) =>
      newValue is num ? super.value = newValue != 0 : super.value = newValue;
  @override
  bool? setValueFromBytes(Uint8List rawValues) =>
      super.value = (rawValues.first & 0x01) != 0;

  @override

  /// NOTE: [rawValue] is ignored for bit elements!
  ModbusWriteRequest getWriteRequest(dynamic value,
      {bool rawValue = false,
      int? unitId,
      Duration? responseTimeout,
      ModbusEndianness? endianness}) {
    return super.getWriteRequest(value,
        rawValue: false,
        unitId: unitId,
        responseTimeout: responseTimeout,
        endianness: endianness);
  }

  /// The FC05 encoding of [value]: `0xFF00` for on, `0x0000` for off.
  ///
  /// A `bool`, or the integers `0` and `1` — the two spellings a control
  /// surface actually sends. Everything else is refused: this used to read
  /// "anything that is not `0` is on", so a `2`, a `5.5` or the string `"off"`
  /// all energised the coil, the device acknowledged, and the caller was told
  /// the write applied. A coil is an actuator; a value that does not name one
  /// of its two states is not something to guess at.
  @override
  int _getRawValue(dynamic value) {
    if (value is bool) return value ? 0xFF00 : 0x0000;
    if (value == 0) return 0x0000;
    if (value == 1) return 0xFF00;
    throw ModbusException(
        context: ModbusNumRegister.writeRefusalContext,
        msg: "$name: $value (${value.runtimeType}) is neither a bool nor 0/1 "
            "and cannot be written to a coil; nothing was sent");
  }
}

/// A Modbus [ModbusElementType.discreteInput] value element.
class ModbusDiscreteInput extends ModbusBitElement {
  ModbusDiscreteInput(
      {required super.name,
      super.description,
      required super.address,
      super.onUpdate})
      : super(type: ModbusElementType.discreteInput);
}

/// A Modbus [ModbusElementType.coil] value element.
class ModbusCoil extends ModbusBitElement {
  ModbusCoil(
      {required super.name,
      super.description,
      required super.address,
      super.onUpdate})
      : super(type: ModbusElementType.coil);
}

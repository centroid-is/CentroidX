/// **What type does a write carry into the plant?**
///
/// The OPC UA write service takes a `Variant`, and a Variant without a type is
/// not a value — it is a hole. The binding says so twice: `valueToVariant`
/// (`common.dart:112`) throws `Unable to determine type for …` when the
/// `DynamicValue` carries no `typeId`, and the serializer beneath it
/// (`opcua_serializer.dart:331-335`) auto-deduces only `bool` and `String`,
/// throwing for `int` and `double` alike.
///
/// So the type is not a nicety this layer adds on the way past. It is the
/// difference between a write and no write, and a gateway that gets it wrong
/// fails in one of three ways, in increasing order of how badly:
///
///  1. **Nothing is sent and the operator is told `unknown`.** Correct for a
///     write whose fate nobody knows, wrong here: the reason is entirely
///     inside this process. An operator who correctly does not retry an
///     `unknown` has had a Start command silently dropped.
///  2. **The server refuses with `Bad_TypeMismatch`.** Safe, and a named
///     refusal — but the write still did not happen, and the tag was fine.
///  3. **The server accepts a narrowed number.** Measured: 5000000000 written
///     to a DINT tag as an Int32 variant becomes 705032704, and the server
///     answers Good. The operator is told it worked. This is the one that
///     cannot be allowed to survive anywhere in this file.
///
/// ## Why the tag's own DataType and not the Dart runtime type
///
/// A Dart runtime type does not carry enough information to pick a UA type,
/// and the gap is not academic on this plant:
///
///  * a Dart `double` is `Float` for a TwinCAT **REAL** and `Double` for an
///    **LREAL**, and REAL is what a setpoint is. Guessing `Double` produces
///    `Bad_TypeMismatch` on every setpoint on the plant — the same defect,
///    wearing failure mode 2 instead of 1;
///  * a Dart `int` is any of eight UA types. The width is the tag's property
///    and no property of the number carries it, which is exactly why the
///    binding refuses to guess (`opcua_serializer.dart:334`) rather than
///    picking one.
///
/// The tag knows. Its DataType attribute is one read, and the answer cannot
/// change while the address space stands — so the caller caches it per key per
/// **epoch**, the same discipline and the same reason as the decode probe.
///
/// Nothing here is `null`-tolerant on the way in: the relay's `DynamicValue`
/// can carry a null payload for a bad-quality reading, and a null is not a
/// number to write.
library;

import 'package:open62541/open62541.dart' as ua;

/// The result of shaping one relay value for one OPC UA tag.
sealed class TypedWrite {
  const TypedWrite();
}

/// The value can be represented in the tag's type, and this is the Variant.
final class TypedWriteReady extends TypedWrite {
  const TypedWriteReady(this.value);

  final ua.DynamicValue value;
}

/// The value **cannot** be represented in the tag's type, and nothing was sent.
///
/// A refusal, not an ambiguity: this is decided before the crossing, so
/// "rejected" is a claim with evidence rather than the unsafe default. The
/// alternative is failure mode 3 above.
final class TypedWriteRefused extends TypedWrite {
  const TypedWriteRefused(this.code, this.message);

  /// The machine-readable half, for `WriteReason.code`.
  final String code;

  /// The sentence an engineer reads at three in the morning. It names the tag's
  /// type and the value, because "these two do not fit" is the whole diagnosis.
  final String message;
}

/// The `WriteReason` code for a value the tag's type cannot hold.
const String writeValueOutOfRangeCode = 'value_out_of_range';

/// The `WriteReason` code for a value whose Dart type the tag cannot take at
/// all — a String into a numeric tag, a number into a Boolean.
const String writeTypeMismatchCode = 'value_type_mismatch';

/// The inclusive range each integer UA type can hold.
///
/// `UInt64`'s upper bound is `2^63-1` rather than `2^64-1` because a Dart `int`
/// is 64-bit **signed** and cannot express anything above it — a bound written
/// as `2^64-1` would be a check that never fires pretending to be one that
/// does.
const Map<ua.Namespace0Id, (int, int)> _integerRanges =
    <ua.Namespace0Id, (int, int)>{
  ua.Namespace0Id.sbyte: (-128, 127),
  ua.Namespace0Id.byte: (0, 255),
  ua.Namespace0Id.int16: (-32768, 32767),
  ua.Namespace0Id.uint16: (0, 65535),
  ua.Namespace0Id.int32: (-2147483648, 2147483647),
  ua.Namespace0Id.uint32: (0, 4294967295),
  ua.Namespace0Id.int64: (-9223372036854775808, 9223372036854775807),
  ua.Namespace0Id.uint64: (0, 9223372036854775807),
};

/// The largest finite IEEE-754 **single**, so a `Float` tag can refuse a
/// magnitude that would reach the wire as infinity.
const double _maxFinite32 = 3.4028234663852886e38;

/// The type this layer assumes for an `int` when the tag's own type could not
/// be learned. See [shapeOpcUaWrite]'s `targetType: null` contract.
final ua.NodeId fallbackIntegerType = ua.NodeId.int32;

/// Shapes [value] — a raw Dart scalar — into the Variant the tag wants.
///
/// [targetType] is the node's DataType attribute. **Null means it could not be
/// learned**, which happens two ways and gets the same answer both times:
///
///  * the read failed or timed out — the session is in trouble and this is not
///    the layer that fixes it;
///  * the tag's type is not one this table knows: a registered struct, an enum
///    alias, or a vendor alias of a simple type (TwinCAT exposes STRING at
///    `ns=3;i=3013`, which `variantToValue` already has a fallback for).
///
/// In both cases the shape falls back to the Dart runtime type — `bool` →
/// Boolean, `String` → String, `double` → Double, `int` → Int32 — which is
/// what the tag most often is and, where it is not, produces the server's own
/// named `Bad_TypeMismatch`. The **range check still applies** to the fallback
/// integer: a fallback may be wrong about the width, and being wrong is
/// survivable, but narrowing a number and calling it applied is not.
TypedWrite shapeOpcUaWrite(Object? value, {ua.NodeId? targetType}) {
  if (value == null) {
    return const TypedWriteRefused(writeTypeMismatchCode,
        'a null has no OPC UA type and is not a value to write');
  }
  if (value is List || value is Map) {
    // Whole-array and struct writes do not come through here: an array key
    // goes down the read-modify-write path, which keeps the element types the
    // server itself sent. Anything else arriving here is a shape this seam
    // has no schema for, and guessing one is how a struct gets written as a
    // byte soup.
    return TypedWriteRefused(
        writeTypeMismatchCode,
        'a ${value.runtimeType} is not a scalar; composite writes need the '
        "server's own schema and this seam does not have one");
  }

  final id = _namespace0(targetType);
  if (id == null) {
    return _shapeByRuntimeType(value, declared: targetType);
  }

  switch (id) {
    case ua.Namespace0Id.boolean:
      if (value is! bool) {
        return _mismatch(value, 'Boolean');
      }
      return TypedWriteReady(
          ua.DynamicValue(value: value, typeId: ua.NodeId.boolean));

    case ua.Namespace0Id.string:
      if (value is! String) {
        return _mismatch(value, 'String');
      }
      return TypedWriteReady(
          ua.DynamicValue(value: value, typeId: ua.NodeId.uastring));

    case ua.Namespace0Id.datetime:
      // No plant key writes one today. It is here because it is the last of
      // the thirteen types `create_type.dart`'s `_payloadTypes` can encode,
      // and a table that stopped one short of the binding's own set would have
      // a hole nobody could see from inside it.
      if (value is! DateTime) {
        return _mismatch(value, 'DateTime');
      }
      return TypedWriteReady(
          ua.DynamicValue(value: value, typeId: ua.NodeId.datetime));

    case ua.Namespace0Id.float:
    case ua.Namespace0Id.double:
      final asDouble = _asDouble(value);
      if (asDouble == null) {
        return _mismatch(value, id == ua.Namespace0Id.float ? 'Float' : 'Double');
      }
      if (id == ua.Namespace0Id.float && asDouble.abs() > _maxFinite32) {
        // A finite number that reaches the wire as infinity is failure mode 3
        // in the library doc, and a REAL tag is where it would happen.
        return TypedWriteRefused(
            writeValueOutOfRangeCode,
            '$asDouble does not fit a Float (REAL) tag, whose largest finite '
            'magnitude is $_maxFinite32; nothing was sent');
      }
      return TypedWriteReady(ua.DynamicValue(
          value: asDouble,
          typeId: id == ua.Namespace0Id.float
              ? ua.NodeId.float
              : ua.NodeId.double));

    case ua.Namespace0Id.sbyte:
    case ua.Namespace0Id.byte:
    case ua.Namespace0Id.int16:
    case ua.Namespace0Id.uint16:
    case ua.Namespace0Id.int32:
    case ua.Namespace0Id.uint32:
    case ua.Namespace0Id.int64:
    case ua.Namespace0Id.uint64:
      if (value is double) {
        // Not a type mismatch — a double IS writable to an integer tag when it
        // is a whole number this machine can carry both ways. When it is not,
        // rounding or saturating it would move the setpoint by an amount
        // nothing downstream would ever mention.
        final whole = _asInt(value);
        if (whole == null) {
          return TypedWriteRefused(
              writeValueOutOfRangeCode,
              '$value cannot be written to a ${id.name} tag as the same '
              'number; nothing was sent, because rounding or saturating a '
              'setpoint is a change no readback can show as one');
        }
        return _rangedInteger(whole, id, _integerTypeId(id));
      }
      final asInt = _asInt(value);
      if (asInt == null) {
        return _mismatch(value, id.name);
      }
      return _rangedInteger(asInt, id, _integerTypeId(id));

    default:
      // Two kinds of type land here and both want the same answer.
      //
      // **The abstract ones** — `BaseDataType` (open62541's own default for a
      // node whose DataType attribute was never set), `Number`, `Integer`,
      // `UInteger`, `Enumeration` — are named entries in `Namespace0Id` but
      // are not something a Variant can be. Encoding one means handing it to
      // `nodeIdToPayloadType(...)!`, which throws a bare null-check from
      // inside the FFI layer.
      // **The concrete ones this binding cannot serialise** — Guid,
      // ByteString, LocalizedText, NodeId and the rest: `create_type.dart`'s
      // `_payloadTypes` has thirteen entries and every one of them is handled
      // above. Inventing an encoding for a fourteenth would be a guess with
      // no test behind it.
      return _shapeByRuntimeType(value, declared: targetType);
  }
}

/// The fallback: the Dart runtime type, and the range check kept.
TypedWrite _shapeByRuntimeType(Object? value, {required ua.NodeId? declared}) {
  if (value is bool) {
    return TypedWriteReady(
        ua.DynamicValue(value: value, typeId: ua.NodeId.boolean));
  }
  if (value is String) {
    return TypedWriteReady(
        ua.DynamicValue(value: value, typeId: ua.NodeId.uastring));
  }
  if (value is double) {
    return TypedWriteReady(
        ua.DynamicValue(value: value, typeId: ua.NodeId.double));
  }
  if (value is DateTime) {
    return TypedWriteReady(
        ua.DynamicValue(value: value, typeId: ua.NodeId.datetime));
  }
  if (value is int) {
    // Int32 is the assumption, and it is checked rather than trusted: this
    // branch runs precisely when nothing is known about the width, which is
    // when a silent narrowing is most likely and least detectable.
    return _rangedInteger(value, ua.Namespace0Id.int32, fallbackIntegerType,
        assumed: true);
  }
  return TypedWriteRefused(
      writeTypeMismatchCode,
      'a ${value.runtimeType} has no OPC UA encoding here'
      "${declared == null ? '' : ' for a $declared tag'}");
}

/// One integer, range-checked against [id] and typed as [typeId].
TypedWrite _rangedInteger(int value, ua.Namespace0Id id, ua.NodeId typeId,
    {bool assumed = false}) {
  final range = _integerRanges[id]!;
  if (value < range.$1 || value > range.$2) {
    return TypedWriteRefused(
        writeValueOutOfRangeCode,
        '$value does not fit ${assumed ? 'the assumed ' : ''}${id.name} '
        '(${range.$1}..${range.$2}); nothing was sent, so the tag still holds '
        'what it held');
  }
  return TypedWriteReady(ua.DynamicValue(value: value, typeId: typeId));
}

ua.NodeId _integerTypeId(ua.Namespace0Id id) => switch (id) {
      ua.Namespace0Id.sbyte => ua.NodeId.sbyte,
      ua.Namespace0Id.byte => ua.NodeId.byte,
      ua.Namespace0Id.int16 => ua.NodeId.int16,
      ua.Namespace0Id.uint16 => ua.NodeId.uint16,
      ua.Namespace0Id.int32 => ua.NodeId.int32,
      ua.Namespace0Id.uint32 => ua.NodeId.uint32,
      ua.Namespace0Id.int64 => ua.NodeId.int64,
      ua.Namespace0Id.uint64 => ua.NodeId.uint64,
      _ => throw ArgumentError.value(id, 'id', 'not an integer type'),
    };

/// [type] as a namespace-0 well-known id, or null when it is neither.
///
/// A DataType in any other namespace is a custom type by construction, and a
/// numeric id namespace 0 does not define is one this binding has no name for.
ua.Namespace0Id? _namespace0(ua.NodeId? type) {
  if (type == null || type.namespace != 0 || !type.isNumeric()) return null;
  try {
    return ua.Namespace0Id.fromInt(type.numeric);
  } catch (_) {
    // `fromInt` is a `firstWhere` with no orElse — it throws for anything the
    // enum does not list, which is most of namespace 0.
    return null;
  }
}

/// A Dart value as a double, or null when it is not a number.
///
/// An `int` is accepted: an operator typing `5` into a REAL setpoint field
/// produces a Dart `int`, and refusing that would be this defect with better
/// manners.
double? _asDouble(Object value) {
  if (value is double) return value;
  if (value is int) return value.toDouble();
  return null;
}

/// A Dart value as an int that means the same number, or null.
///
/// A `double` that is exactly integral is accepted — a slider at 5.0 for a
/// DINT tag is a legitimate write. One that is not is **refused rather than
/// rounded**: silently turning a 5.5 setpoint into a 5 or a 6 is the same
/// class of failure as narrowing, and neither is visible downstream.
///
/// The round trip is the check that matters and it is not decoration.
/// `double.toInt()` **saturates** on the VM rather than throwing: `1e30.toInt()`
/// is `9223372036854775807`, so a `1e30` written to a LINT tag would otherwise
/// arrive as int64-max and be reported applied. Requiring `i.toDouble() ==
/// value` catches that and every other magnitude a double cannot carry back.
int? _asInt(Object value) {
  if (value is int) return value;
  if (value is double) {
    if (!value.isFinite || value != value.roundToDouble()) return null;
    final asInt = value.toInt();
    return asInt.toDouble() == value ? asInt : null;
  }
  return null;
}

TypedWrite _mismatch(Object value, String uaType) => TypedWriteRefused(
    writeTypeMismatchCode,
    'a ${value.runtimeType} cannot be written to a $uaType tag; nothing was '
    'sent');

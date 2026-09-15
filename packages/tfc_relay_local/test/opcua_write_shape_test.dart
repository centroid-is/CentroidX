/// The write path's typing table, judged per type rather than by example.
///
/// `opcua_write_typing_test.dart` is the same subject against a real server and
/// is where the claim "this actually reaches a PLC" lives. This file is the
/// exhaustive half: every namespace-0 scalar type the plant declares, every
/// Dart value that can arrive for it, and — the part a server-backed suite is
/// too slow to cover — every boundary of every integer width, from both sides.
///
/// No server, no socket, no `@TestOn`. The function under test is pure.
library;

import 'package:open62541/open62541.dart' as ua;
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:test/test.dart';

/// The shaped Variant, or a failure naming the refusal instead.
ua.DynamicValue ready(Object? value, {ua.NodeId? targetType}) {
  final shaped = shapeOpcUaWrite(value, targetType: targetType);
  if (shaped is TypedWriteRefused) {
    fail('expected $value to shape for $targetType, but it was refused: '
        '${shaped.code} — ${shaped.message}');
  }
  return (shaped as TypedWriteReady).value;
}

TypedWriteRefused refused(Object? value, {ua.NodeId? targetType}) {
  final shaped = shapeOpcUaWrite(value, targetType: targetType);
  if (shaped is! TypedWriteRefused) {
    fail('expected $value to be refused for $targetType, but it shaped as '
        '${(shaped as TypedWriteReady).value.typeId}');
  }
  return shaped;
}

void main() {
  group('the tag decides the type, and the value survives it', () {
    test('BOOL', () {
      final v = ready(true, targetType: ua.NodeId.boolean);
      expect(v.typeId, ua.NodeId.boolean);
      expect(v.value, isTrue);
    });

    test('STRING keeps its Icelandic', () {
      // CLAUDE.md's wire hazards: þ/ð/æ are what this plant's strings contain,
      // and a table that only ever moved ASCII would not have been tested.
      final v = ready('þristur', targetType: ua.NodeId.uastring);
      expect(v.typeId, ua.NodeId.uastring);
      expect(v.value, 'þristur');
    });

    test('REAL takes a double and stays a Float', () {
      // The row that decides the whole design. A Dart double is Float for a
      // TwinCAT REAL and Double for an LREAL; there is nothing in the number
      // that says which, and REAL is what a setpoint is.
      final v = ready(1.5, targetType: ua.NodeId.float);
      expect(v.typeId, ua.NodeId.float,
          reason: 'a REAL setpoint written as a Double is Bad_TypeMismatch on '
              'every setpoint on the plant');
      expect(v.value, 1.5);
    });

    test('REAL takes an int, because an operator types 5 not 5.0', () {
      final v = ready(5, targetType: ua.NodeId.float);
      expect(v.typeId, ua.NodeId.float);
      expect(v.value, 5.0);
      expect(v.value, isA<double>(),
          reason: 'an int left as an int under a Float typeId is a four-byte '
              'integer bit pattern read as a float');
    });

    test('LREAL takes a double and stays a Double', () {
      final v = ready(12.25, targetType: ua.NodeId.double);
      expect(v.typeId, ua.NodeId.double);
      expect(v.value, 12.25);
    });

    // Every integer width, at both ends of its range, plus one past each end.
    // The old code typed all of these Int32: correct for exactly one row, a
    // named refusal for six, and a silent truncation for the seventh.
    final widths = <({String label, ua.NodeId typeId, int min, int max})>[
      (label: 'SByte', typeId: ua.NodeId.sbyte, min: -128, max: 127),
      (label: 'Byte', typeId: ua.NodeId.byte, min: 0, max: 255),
      (label: 'Int16', typeId: ua.NodeId.int16, min: -32768, max: 32767),
      (label: 'UInt16', typeId: ua.NodeId.uint16, min: 0, max: 65535),
      (
        label: 'Int32',
        typeId: ua.NodeId.int32,
        min: -2147483648,
        max: 2147483647
      ),
      (label: 'UInt32', typeId: ua.NodeId.uint32, min: 0, max: 4294967295),
      (
        label: 'Int64',
        typeId: ua.NodeId.int64,
        min: -9223372036854775808,
        max: 9223372036854775807
      ),
      (
        label: 'UInt64',
        typeId: ua.NodeId.uint64,
        min: 0,
        // A Dart int is 64-bit SIGNED, so this is the largest value that can
        // reach this seam at all. Writing 2^64-1 here would be a bound that
        // never fires pretending to be one that does.
        max: 9223372036854775807
      ),
    ];

    for (final w in widths) {
      test('${w.label} carries its own range and keeps its own type', () {
        for (final edge in <int>[w.min, w.max, 0]) {
          if (edge < w.min) continue;
          final v = ready(edge, targetType: w.typeId);
          expect(v.typeId, w.typeId,
              reason: '${w.label} must stay ${w.label}, not become Int32');
          expect(v.value, edge);
        }
      });

      test('${w.label} refuses what it cannot hold', () {
        // `Int64` and `UInt64`'s upper edges are the top of a Dart int, so
        // "one past" does not exist for them from this side; the lower edge
        // still does for UInt64.
        for (final beyond in <int?>[
          w.min == -9223372036854775808 ? null : w.min - 1,
          w.max == 9223372036854775807 ? null : w.max + 1,
        ]) {
          if (beyond == null) continue;
          final r = refused(beyond, targetType: w.typeId);
          expect(r.code, writeValueOutOfRangeCode);
          expect(r.message, contains('$beyond'),
              reason: 'the number and the range go in the sentence — "these '
                  'two do not fit" is the whole diagnosis');
        }
      });
    }

    test('the measured truncation is now a refusal', () {
      // The bench's shape, exactly: 5000000000 to a DINT tag was reported
      // APPLIED with the server holding 705032704.
      final r = refused(5000000000, targetType: ua.NodeId.int32);
      expect(r.code, writeValueOutOfRangeCode);
      expect(r.message, contains('nothing was sent'));
    });
  });

  group('a whole double is a legitimate integer write; a fraction is not', () {
    test('5.0 into a DINT is 5', () {
      final v = ready(5.0, targetType: ua.NodeId.int32);
      expect(v.typeId, ua.NodeId.int32);
      expect(v.value, 5);
      expect(v.value, isA<int>());
    });

    test('5.5 into a DINT is refused, not rounded', () {
      final r = refused(5.5, targetType: ua.NodeId.int32);
      expect(r.code, writeValueOutOfRangeCode);
    });

    test('1e30 into a LINT is refused, not saturated', () {
      // `double.toInt()` SATURATES on the VM — `1e30.toInt()` is int64-max —
      // so without the round-trip check this would be an applied write of a
      // number nobody asked for, on the one integer width wide enough to
      // accept it.
      final r = refused(1e30, targetType: ua.NodeId.int64);
      expect(r.code, writeValueOutOfRangeCode);
    });

    test('infinity and NaN are refused for an integer tag', () {
      expect(refused(double.infinity, targetType: ua.NodeId.int32).code,
          writeValueOutOfRangeCode);
      expect(refused(double.nan, targetType: ua.NodeId.int32).code,
          writeValueOutOfRangeCode);
    });
  });

  group('a Float tag refuses a magnitude that would arrive as infinity', () {
    test('1e39 does not fit a REAL', () {
      final r = refused(1e39, targetType: ua.NodeId.float);
      expect(r.code, writeValueOutOfRangeCode);
    });

    test('the largest finite single still fits', () {
      expect(ready(3.4028234663852886e38, targetType: ua.NodeId.float).value,
          3.4028234663852886e38);
    });

    test('an LREAL takes it, because a Double can hold it', () {
      expect(ready(1e39, targetType: ua.NodeId.double).value, 1e39);
    });
  });

  group('a value the tag cannot take at all is a type mismatch', () {
    test('a String into a numeric tag', () {
      expect(refused('go', targetType: ua.NodeId.int32).code,
          writeTypeMismatchCode);
      expect(refused('go', targetType: ua.NodeId.float).code,
          writeTypeMismatchCode);
    });

    test('a number into a BOOL tag', () {
      // Deliberately strict. "1 means true" is a convention this gateway does
      // not get to invent on an operator's behalf, and a Start command is the
      // wrong place to start inventing.
      expect(refused(1, targetType: ua.NodeId.boolean).code,
          writeTypeMismatchCode);
    });

    test('a bool into a numeric tag', () {
      expect(refused(true, targetType: ua.NodeId.int32).code,
          writeTypeMismatchCode);
    });

    test('a bool into a STRING tag', () {
      expect(refused(true, targetType: ua.NodeId.uastring).code,
          writeTypeMismatchCode);
    });

    test('a null is not a value to write', () {
      expect(refused(null, targetType: ua.NodeId.int32).code,
          writeTypeMismatchCode);
      expect(refused(null).code, writeTypeMismatchCode,
          reason: 'and it is refused with no target type either — the relay '
              "DynamicValue carries a null payload for a bad reading, and a "
              'bad reading is not a command');
    });

    test('a list or a map has no scalar encoding here', () {
      expect(refused(<int>[1, 2], targetType: ua.NodeId.int32).code,
          writeTypeMismatchCode);
      expect(refused(<String, int>{'a': 1}).code, writeTypeMismatchCode);
    });
  });

  group('when the tag type could not be learned, the runtime type decides', () {
    // Two ways to get here and they get the same answer: the DataType read
    // failed, or the tag's type is not one this table knows (a registered
    // struct, an enum alias, TwinCAT's STRING at ns=3;i=3013).
    final unknown = ua.NodeId.fromNumeric(3, 3013);

    for (final target in <ua.NodeId?>[null, unknown]) {
      final label = target == null ? 'no type' : 'an unrecognised type';

      test('$label: a bool is still a Boolean', () {
        expect(ready(true, targetType: target).typeId, ua.NodeId.boolean);
      });

      test('$label: a String is still a String', () {
        expect(ready('x', targetType: target).typeId, ua.NodeId.uastring);
      });

      test('$label: a double falls back to Double', () {
        expect(ready(1.5, targetType: target).typeId, ua.NodeId.double);
      });

      test('$label: an int falls back to Int32', () {
        final v = ready(7, targetType: target);
        expect(v.typeId, fallbackIntegerType);
        expect(v.value, 7);
      });

      test('$label: and the fallback int is STILL range-checked', () {
        // The whole point of the fallback being a documented assumption rather
        // than a shrug. Being wrong about the width is survivable — the server
        // answers Bad_TypeMismatch, which is a named refusal. Narrowing a
        // number and calling it applied is not, and this is the branch where
        // nothing is known and it would be least detectable.
        final r = refused(5000000000, targetType: target);
        expect(r.code, writeValueOutOfRangeCode);
        expect(r.message, contains('assumed'),
            reason: 'the sentence must say the width was assumed, or an '
                'engineer reads it as the tag having declared Int32');
      });
    }

    // The ABSTRACT namespace-0 types, which are what a real server reports for
    // a node whose DataType attribute was never set — `BaseDataType` is
    // open62541's own default, and `Number`/`Integer`/`Enumeration` are legal
    // on a live address space. They are named types, so a table that switched
    // on the enum without thinking about them would try to encode one, and the
    // binding's `nodeIdToPayloadType(...)!` would throw a bare null-check from
    // inside the FFI layer. Each falls back like an unknown type.
    for (final abstractType in <ua.Namespace0Id>[
      ua.Namespace0Id.basedataType,
      ua.Namespace0Id.number,
      ua.Namespace0Id.integer,
      ua.Namespace0Id.uinteger,
      ua.Namespace0Id.enumeration,
    ]) {
      test('${abstractType.name} is abstract, so the runtime type decides', () {
        final tag = ua.NodeId.fromNumeric(0, abstractType.value);
        expect(ready(1.5, targetType: tag).typeId, ua.NodeId.double);
        expect(ready(7, targetType: tag).typeId, fallbackIntegerType);
        expect(refused(5000000000, targetType: tag).code,
            writeValueOutOfRangeCode);
      });
    }

    test('a namespace-0 type this table does not shape takes the same road',
        () {
      // Guid is a real namespace-0 scalar the binding's `_payloadTypes` cannot
      // encode at all. Shaping a value for it must not invent one.
      final guidTag = ua.NodeId.fromNumeric(0, ua.Namespace0Id.guid.value);
      expect(ready('x', targetType: guidTag).typeId, ua.NodeId.uastring);
    });
  });

  group('the table covers exactly what the binding can encode', () {
    // `create_type.dart`'s `_payloadTypes` is the binding's own list of the
    // scalars it can serialise, and it is private. A table that stopped one
    // type short of it would have a hole nobody could see from inside it.
    test('DateTime, the thirteenth', () {
      final at = DateTime.utc(2026, 9, 9, 12);
      final v = ready(at, targetType: ua.NodeId.datetime);
      expect(v.typeId, ua.NodeId.datetime);
      expect(v.value, at);
    });

    test('a DateTime with no target type still types itself', () {
      expect(ready(DateTime.utc(2026)).typeId, ua.NodeId.datetime);
    });

    test('a number is not a DateTime', () {
      expect(refused(0, targetType: ua.NodeId.datetime).code,
          writeTypeMismatchCode);
    });
  });
}

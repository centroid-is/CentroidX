/// The pure-Dart DynamicValue — the type every later component passes around.
///
/// Each group states the operational consequence of the property it pins, not
/// the mechanics: these are the guarantees widgets, the value store and the
/// wire all lean on. No clock, no I/O, no FFI anywhere in this file.
library;

import 'dart:convert';

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

void main() {
  /// Same helper as messages_test.dart:6-11 — every shape must survive
  /// encode → jsonEncode → jsonDecode → decode with an unknown field planted
  /// in it, or a newer server rolls out and every older client falls over.
  Map<String, Object?> viaJson(Map<String, Object?> json,
          {Map<String, Object?> extra = const {'futureField': 123}}) =>
      jsonDecode(jsonEncode({...json, ...extra})) as Map<String, Object?>;

  Map<String, Object?> full(DynamicValue v) => v.toJson() as Map<String, Object?>;

  DynamicValue roundTrip(DynamicValue v) => DynamicValue.fromJson(viaJson(full(v)));

  group('coercions never return null and never throw', () {
    test('a double answers every scalar question', () {
      final v = DynamicValue(value: 3.5);
      expect(v.asDouble, 3.5);
      expect(v.asInt, 3, reason: 'truncation, not a throw, on a gauge reading');
      expect(v.asString, '3.5');
      expect(v.asBool, isTrue, reason: 'non-zero is on, as operators read it');
    });

    test('a null value coerces to zeroes, never null and never a throw', () {
      final v = DynamicValue(value: null);
      expect(v.asDouble, 0.0);
      expect(v.asInt, 0);
      expect(v.asString, '');
      expect(v.asBool, isFalse,
          reason: '44 asDouble and 43 asInt call sites index the result '
              'directly; a null here is a crashed mimic page');
    });

    test('booleans parse from the strings and numbers a PLC actually sends',
        () {
      expect(DynamicValue(value: 'true').asBool, isTrue);
      expect(DynamicValue(value: '  TRUE ').asBool, isTrue,
          reason: 'whitespace and case from a text tag must not flip a state');
      expect(DynamicValue(value: '1').asBool, isTrue);
      expect(DynamicValue(value: 1).asBool, isTrue);
      expect(DynamicValue(value: 0).asBool, isFalse);
      expect(DynamicValue(value: 'no').asBool, isFalse);
      expect(DynamicValue(value: true).asBool, isTrue);
    });

    test('numeric strings coerce rather than reading as zero', () {
      expect(DynamicValue(value: '42').asInt, 42);
      expect(DynamicValue(value: '42.5').asDouble, 42.5);
      expect(DynamicValue(value: '42.5').asInt, 42);
      expect(DynamicValue(value: 'not a number').asDouble, 0.0,
          reason: 'garbage degrades to zero, it does not throw mid-build');
    });

    test('a collection still answers the scalar getters without throwing', () {
      final v = DynamicValue(value: const {'a': 1});
      expect(v.asDouble, 0.0);
      expect(v.asInt, 0);
      expect(v.asBool, isFalse);
      expect(v.asString, isNotEmpty);
    });
  });

  group('type tests each recognise exactly their own shape', () {
    test('every shape reports itself and nothing else', () {
      expect(DynamicValue(value: null).isNull, isTrue);
      expect(DynamicValue(value: true).isBoolean, isTrue);
      expect(DynamicValue(value: 7).isInteger, isTrue);
      expect(DynamicValue(value: 7.5).isDouble, isTrue);
      expect(DynamicValue(value: 'x').isString, isTrue);
      expect(DynamicValue(value: const [1, 2]).isArray, isTrue);
      expect(DynamicValue(value: const {'a': 1}).isObject, isTrue);
    });

    test('an integer is not a double and an array is not an object', () {
      final i = DynamicValue(value: 7);
      expect(i.isDouble, isFalse,
          reason: 'the JSON type tag is derived from this, so a widened int '
              'would change the wire shape');
      expect(DynamicValue(value: 7.5).isInteger, isFalse);
      expect(DynamicValue(value: const [1]).isObject, isFalse);
      expect(DynamicValue(value: const {'a': 1}).isArray, isFalse);
      expect(DynamicValue(value: null).isString, isFalse);
    });
  });

  group('membership and indexing (the sensor.dart guard idiom)', () {
    final obj = DynamicValue(value: const {
      'run': true,
      'speed': 12.5,
      'nested': {'deep': 1},
    });

    test('contains answers for a missing member instead of throwing', () {
      expect(obj.contains('run'), isTrue);
      expect(obj.contains('missing'), isFalse,
          reason: 'an older PLC library revision missing a member must '
              'degrade, not crash the mimic');
    });

    test('operator[] throws on a missing member', () {
      expect(obj['run'].asBool, isTrue);
      expect(() => obj['missing'], throwsStateError,
          reason: 'sensor.dart:125-132 guards every read precisely because '
              'this throws — silently returning null would hide bad configs');
    });

    test('arrays index by int and object members by String', () {
      final arr = DynamicValue(value: const [10, 20, 30]);
      expect(arr[1].asInt, 20);
      expect(arr.length, 3);
      expect(() => arr[9], throwsStateError);
      expect(arr.contains(9), isFalse);
      expect(obj['nested']['deep'].asInt, 1,
          reason: 'nested members index without unwrapping by hand');
    });

    test('entries iterate object children in insertion order', () {
      expect(obj.entries.map((e) => e.key).toList(), ['run', 'speed', 'nested'],
          reason: 'diagnostic tables render fields in the order the server '
              'declared them');
    });

    test('asObject and asArray throw on the wrong shape', () {
      expect(() => DynamicValue(value: 1).asObject, throwsStateError);
      expect(() => DynamicValue(value: 1).asArray, throwsStateError);
      expect(obj.asObject.keys, contains('speed'));
      expect(DynamicValue(value: const [1]).asArray, hasLength(1));
    });
  });

  group('value equality is what makes zero-rebuild possible (CLI-06)', () {
    test('two values built from equal nested maps are == and share a hashCode',
        () {
      final a = DynamicValue(value: {
        'a': 1,
        'b': {
          'c': [1, 2, 3],
        },
      });
      final b = DynamicValue(value: {
        'a': 1,
        'b': {
          'c': [1, 2, 3],
        },
      });
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode,
          reason: 'the store skips the notification on ==; an identity-based '
              'comparison would rebuild all 1500 keys every batch');
    });

    test('changing one nested leaf makes them unequal', () {
      final a = DynamicValue(value: {
        'b': {'c': 1},
      });
      final b = DynamicValue(value: {
        'b': {'c': 2},
      });
      expect(a, isNot(equals(b)),
          reason: 'a deep change the store missed is a stale screen');
    });

    test('quality and sourceTime participate in equality', () {
      final t = DateTime.utc(2026, 8, 13, 12);
      expect(DynamicValue(value: 1, quality: Quality.badStale),
          isNot(equals(DynamicValue(value: 1))),
          reason: 'a value going stale must notify even when the number is '
              'unchanged — that is the whole freshness promise');
      expect(DynamicValue(value: 1, sourceTime: t),
          isNot(equals(DynamicValue(value: 1))));
      expect(DynamicValue(value: 1, sourceTime: t),
          equals(DynamicValue(value: 1, sourceTime: t)));
    });

    test('copyWith returns a new instance and leaves the original untouched',
        () {
      final original = DynamicValue(value: 1, displayName: const LocalizedText('Speed'));
      final changed = original.copyWith(value: 2);
      expect(original.asInt, 1, reason: 'immutability is the store contract');
      expect(changed.asInt, 2);
      expect(changed.displayName?.value, 'Speed',
          reason: 'metadata survives the six ..value= call sites being ported '
              'to copyWith');
    });

    test('copyWith can clear an optional field', () {
      final original = DynamicValue(
        value: 1,
        displayName: const LocalizedText('Speed'),
        description: const LocalizedText('belt speed'),
      );
      final cleared = original.copyWith(displayName: null, description: null);
      expect(cleared.displayName, isNull);
      expect(cleared.description, isNull);
      expect(original.displayName, isNotNull);
    });

    test('DynamicValue.from is a deep copy that is == to its source', () {
      final source = DynamicValue(value: {
        'b': {'c': 1},
      });
      final copy = DynamicValue.from(source);
      expect(copy, equals(source));
      expect(identical(copy['b'], source['b']), isFalse,
          reason: 'a shared child would let a mutation of one tree leak into '
              'the other during encode-once fan-out');
    });
  });

  group('quality composition — a parent never looks healthier than its child',
      () {
    test('an object inherits the worst quality among its children', () {
      final v = DynamicValue(value: {
        'ok': DynamicValue(value: 1),
        'broken': DynamicValue(value: 2, quality: Quality.badCommFault),
      });
      expect(v.quality, Quality.badCommFault,
          reason: 'a green header over a dead member is exactly the lie the '
              'pipe exists to prevent');
    });

    test('an array inherits the worst quality among its elements', () {
      final v = DynamicValue(value: [
        DynamicValue(value: 1),
        DynamicValue(value: 2, quality: Quality.errorConfig),
      ]);
      expect(v.quality, Quality.errorConfig);
    });

    test('a good-band quality of its own survives healthy children', () {
      final v = DynamicValue(
        value: {'ok': DynamicValue(value: 1)},
        quality: Quality.goodWritePending,
      );
      expect(v.quality, Quality.goodWritePending,
          reason: 'the write-pending badge must not be laundered back to '
              'plain good by composition');
    });

    test("a child's within-band quality is visible on its parent", () {
      // WR-10. A widget bound to a struct rather than to the leaf showed no
      // pending badge while a write to one of its members was in flight —
      // the case CONTEXT D-04 exists to make visible.
      final v = DynamicValue(value: {
        'ok': DynamicValue(value: 1),
        'writing':
            DynamicValue(value: 2, quality: Quality.goodWritePending),
      });
      expect(v.quality, Quality.goodWritePending);
    });

    test('a worse band still beats a within-band child', () {
      final v = DynamicValue(value: {
        'writing':
            DynamicValue(value: 1, quality: Quality.goodWritePending),
        'dead': DynamicValue(value: 2, quality: Quality.badCommFault),
      });
      expect(v.quality, Quality.badCommFault,
          reason: 'the pending badge must not shadow a dead member');
    });

    test("a parent's own non-good quality is not replaced by a child's", () {
      final v = DynamicValue(
        value: {'writing': DynamicValue(value: 1, quality: Quality.goodWritePending)},
        quality: Quality.uncertainLastKnown,
      );
      expect(v.quality, Quality.uncertainLastKnown,
          reason: 'within-band promotion only lifts a plain-good parent; it '
              'never lowers one that already says something');
    });

    test('a non-finite leaf becomes null with badNonFinite quality', () {
      final v = DynamicValue(value: double.infinity);
      expect(v.value, isNull);
      expect(v.quality, Quality.badNonFinite,
          reason: 'jsonEncode throws on Infinity — one open-circuit 4-20 mA '
              'input would otherwise fail the batch for every client');

      final nested = DynamicValue(value: {'rate': double.nan});
      expect(nested['rate'].value, isNull);
      expect(nested.quality, Quality.badNonFinite);
    });
  });

  group('toString renders what diagnostic pages print', () {
    test('a value with enumFields renders name(value)', () {
      final v = DynamicValue(
        value: 2,
        enumFields: const {
          1: EnumField(value: 1, name: 'Stopped'),
          2: EnumField(value: 2, name: 'Running'),
        },
      );
      expect(v.toString(), 'Running(2)');
    });

    test('a null value renders null', () {
      expect(DynamicValue(value: null).toString(), 'null');
      expect(
          DynamicValue(
            value: null,
            enumFields: const {1: EnumField(value: 1, name: 'Stopped')},
          ).toString(),
          'null');
    });
  });

  group('companion types carry their own equality', () {
    test('LocalizedText and EnumField compare by content', () {
      expect(const LocalizedText('Hraði', locale: 'is'),
          equals(const LocalizedText('Hraði', locale: 'is')));
      expect(const LocalizedText('Hraði', locale: 'is'),
          isNot(equals(const LocalizedText('Hraði'))));
      expect(const EnumField(value: 1, name: 'Stopped'),
          equals(const EnumField(value: 1, name: 'Stopped')));
    });
  });

  group('JSON round-trips tolerantly', () {
    test('every shape survives encode → jsonEncode → jsonDecode → decode', () {
      final shapes = <DynamicValue>[
        DynamicValue(value: null),
        DynamicValue(value: true),
        DynamicValue(value: 42),
        DynamicValue(value: 42.5),
        DynamicValue(value: 'x'),
        DynamicValue(value: const [1, 'two', false]),
        DynamicValue(value: {
          'run': true,
          'nested': {'deep': 1.5},
        }),
      ];
      for (final shape in shapes) {
        expect(roundTrip(shape), equals(shape),
            reason: 'a shape that does not round-trip is a value the client '
                'and the server disagree about');
      }
    });

    test('metadata, quality and source time round-trip with the value', () {
      final v = DynamicValue(
        value: 2,
        quality: Quality.uncertainLastKnown,
        sourceTime: DateTime.utc(2026, 8, 13, 12, 30, 15, 250),
        typeId: ValueType.integer,
        sourceTypeId: 'ns=2;s=X',
        displayName: const LocalizedText('Staða', locale: 'is'),
        description: const LocalizedText('state of the line'),
        enumFields: const {
          1: EnumField(value: 1, name: 'Stopped'),
          2: EnumField(value: 2, name: 'Running'),
        },
      );
      final decoded = roundTrip(v);
      expect(decoded, equals(v));
      expect(decoded.typeId, ValueType.integer,
          reason: 'typeId crosses as the ValueType name');
      expect(decoded.sourceTypeId, 'ns=2;s=X',
          reason: 'the opaque source id is round-tripped, never parsed — the '
              'wire shape the existing converter uses does not change');
      expect(decoded.quality, Quality.uncertainLastKnown);
      expect(decoded.sourceTime, v.sourceTime);
    });

    test('an unknown field is ignored, not an error', () {
      final decoded = DynamicValue.fromJson(viaJson(
          full(DynamicValue(value: 1)),
          extra: const {'futureField': 123, 'anotherOne': 'x'}));
      expect(decoded.asInt, 1,
          reason: 'a newer server must be able to add a field without '
              'breaking every deployed panel');
    });

    test('toJson omits absent optionals and empty collections', () {
      expect(full(DynamicValue(value: 1)).keys.toSet(), {'type', 'value'},
          reason: 'metadata is cached at subscribe time; repeating it on '
              'every push is bytes on a slow plant link');
      expect(full(DynamicValue(value: 1, enumFields: const {})).keys.toSet(),
          {'type', 'value'});
    });

    test('the type tag is one of the eight the converter already emits', () {
      String tagOf(Object? v) => full(DynamicValue(value: v))['type'] as String;
      expect(tagOf(null), 'null');
      expect(tagOf(true), 'boolean');
      expect(tagOf(1), 'integer');
      expect(tagOf(1.5), 'double');
      expect(tagOf('x'), 'string');
      expect(tagOf(const [1]), 'array');
      expect(tagOf(const {'a': 1}), 'object');
      expect(tagOf(DateTime.utc(2026)), 'unknown');
    });

    test('slim mode returns the bare value with no metadata', () {
      final v = DynamicValue(value: 12.5, displayName: const LocalizedText('Speed'));
      expect(v.toJson(slim: true), 12.5,
          reason: 'slim values are what UpdateParams pushes; metadata rides '
              'once in SubscribeResult.meta');
      expect(
          DynamicValue(value: const {'a': 1}).toJson(slim: true), {'a': 1});
    });

    test('numbers decode through num — JSON 1.0 for an integer does not crash',
        () {
      final decoded = DynamicValue.fromJson(
          jsonDecode('{"type":"integer","value":1.0}') as Map<String, Object?>);
      expect(decoded.asInt, 1);
      expect(decoded.isInteger, isTrue);
    });

    group('a leaf the peer sent wrong degrades alone', () {
      // WR-04. A _TypeError out of a decoder on the notification path (`u`
      // updates) has no JSON-RPC error response to land in: it surfaces as an
      // unhandled error and takes down the value pipeline for a frame that
      // had one bad field in it.

      test('a declared type the value does not match', () {
        for (final json in <Map<String, Object?>>[
          {'type': 'integer', 'value': 'five'},
          {'type': 'boolean', 'value': 1},
          {'type': 'double', 'value': true},
          {'type': 'object', 'value': 'not an object'},
          {'type': 'array', 'value': 7},
        ]) {
          final decoded = DynamicValue.fromJson(json);
          expect(decoded.value, isNull, reason: '$json');
          expect(decoded.quality, Quality.errorTypeMismatch,
              reason: 'a leaf that could not be decoded must be visibly '
                  'undecodable, not silently null — $json');
        }
      });

      test('a mismatch inside a struct costs that member alone', () {
        final decoded = DynamicValue.fromJson({
          'type': 'object',
          'value': {
            'ok': {'type': 'integer', 'value': 7},
            'broken': {'type': 'integer', 'value': 'five'},
          },
        });
        expect(decoded['ok'].asInt, 7,
            reason: 'the healthy member of the batch survives');
        expect(decoded['broken'].value, isNull);
        expect(decoded.quality, Quality.errorTypeMismatch,
            reason: 'and the parent says so, worst-wins');
      });

      test('an absent value is an absent reading, not a mismatch', () {
        for (final type in ['integer', 'double', 'boolean', 'object',
          'array']) {
          final decoded =
              DynamicValue.fromJson({'type': type, 'value': null});
          expect(decoded.quality, Quality.good, reason: type);
        }
      });

      test('a number under a string tag is a representation difference', () {
        final decoded =
            DynamicValue.fromJson({'type': 'string', 'value': 42});
        expect(decoded.value, '42');
        expect(decoded.quality, Quality.good);
      });

      test('malformed metadata costs the label, not the value', () {
        final decoded = DynamicValue.fromJson({
          'type': 'integer',
          'value': 7,
          'typeId': 99,
          'sourceTypeId': const [],
          'displayName': 'not an object',
          'description': 7,
          'enumFields': {'not a code': {}, '3': 'not an object'},
        });
        expect(decoded.asInt, 7);
        expect(decoded.typeId, isNull);
        expect(decoded.sourceTypeId, isNull);
        expect(decoded.displayName, isNull);
        expect(decoded.enumFields, isEmpty);
      });

      test('a wrong-typed type tag falls through to unknown', () {
        expect(DynamicValue.fromJson({'type': 7, 'value': 'x'}).value, 'x');
      });
    });
  });

  group('poison values are defused at the boundary', () {
    test('1e999 arriving as Infinity decodes to null with badNonFinite', () {
      final json = jsonDecode('{"type":"double","value":1e999}')
          as Map<String, Object?>;
      expect(json['value'], double.infinity,
          reason: 'jsonDecode really does hand us Infinity — this is the '
              'poison the re-sanitize on decode exists for');
      final decoded = DynamicValue.fromJson(json);
      expect(decoded.value, isNull);
      expect(decoded.quality, Quality.badNonFinite);
      expect(() => jsonEncode(decoded.toJson()), returnsNormally,
          reason: 're-encoding a decoded poison value must not detonate the '
              'batch for every other client');
    });

    test('jsonEncode of a NaN-sourced value does not throw', () {
      expect(() => jsonEncode(DynamicValue.of(double.nan).toJson()),
          returnsNormally);
      expect(
          () => jsonEncode(
              DynamicValue(value: {'rate': double.nan}).toJson()),
          returnsNormally);
    });

    test("'Þorskflök í raspi' survives the full round-trip unchanged", () {
      const name = 'Þorskflök í raspi';
      final v = DynamicValue(
        value: name,
        displayName: const LocalizedText(name, locale: 'is'),
      );
      final decoded = roundTrip(v);
      expect(decoded.asString, name);
      expect(decoded.displayName?.value, name);
    });
  });

  group('hostile nesting is refused, not survived by luck', () {
    Map<String, Object?> nest(int depth) {
      Map<String, Object?> node = {'type': 'integer', 'value': 1};
      for (var i = 0; i < depth; i++) {
        node = {
          'type': 'object',
          'value': {'child': node},
        };
      }
      return node;
    }

    test('nesting within the limit decodes', () {
      final decoded = DynamicValue.fromJson(nest(10));
      expect(decoded.isObject, isTrue);
    });

    test('nesting past maxDepth throws a FormatException naming the limit',
        () {
      expect(DynamicValue.maxDepth, 64);
      expect(
          () => DynamicValue.fromJson(nest(DynamicValue.maxDepth + 5)),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', contains('64'))),
          reason: 'the recursive decoder is new code receiving untrusted '
              'bytes; a stack overflow would take the whole gateway down');
    });

    test('the public constructor honours the same bound', () {
      // WR-11. The decoder bounded its recursion and the constructor did
      // not — and the constructor is what the OPC UA / Modbus / M2400
      // converters call on the gateway, with structures the upstream
      // controls.
      Object? deep = 1;
      for (var i = 0; i < DynamicValue.maxDepth + 5; i++) {
        deep = {'child': deep};
      }
      expect(() => DynamicValue(value: deep), throwsArgumentError,
          reason: 'ArgumentError rather than FormatException: the caller here '
              'is local code, so this is programmer error');
    });

    test('a self-referential structure from a converter is refused', () {
      final cycle = <String, Object?>{};
      cycle['self'] = cycle;
      expect(() => DynamicValue(value: cycle), throwsArgumentError);
    });

    test('a structure just inside the bound still constructs', () {
      Object? deep = 1;
      for (var i = 0; i < DynamicValue.maxDepth - 2; i++) {
        deep = [deep];
      }
      expect(() => DynamicValue(value: deep), returnsNormally);
    });
  });
}

/// A `DynamicValue` object must decode from any `Map<String, dynamic>`, not
/// only from the one shape `jsonDecode` happens to produce on the VM.
///
/// The `object` branch of `DynamicValueConverter.fromJson` cast to the
/// **concrete** `LinkedHashMap<String, dynamic>`. On the VM that is invisible:
/// `jsonDecode` builds its maps with a `{}` literal, which is a
/// `LinkedHashMap`, so every station panel decodes recipes happily. On
/// dart2js it is fatal: `jsonDecode` returns a lazy `_JsonMap` wrapping the
/// browser's `JSON.parse` result, which implements `Map<String, dynamic>` and
/// is **not** a `LinkedHashMap`. The browser client therefore showed
///
///   Error loading recipes: TypeError: Instance of 'minified:aeZ':
///   type 'minified:aeZ' is not a subtype of type 'minified:a4H<String, dynamic>'
///
/// on every recipe, while the same data opened fine on the panel beside it.
///
/// A test that decodes ordinary `jsonDecode` output cannot catch this: on the
/// VM that output satisfies the bad cast. So these hand the converter maps
/// that are honest `Map<String, dynamic>`s but not `LinkedHashMap`s — which is
/// exactly what the web gives it — and the bad cast fails on the VM too.
library;

import 'dart:collection';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:tfc_dart/converter/dynamic_value_converter.dart';

/// A `Map<String, dynamic>` that is not a `LinkedHashMap`, standing in for
/// dart2js's `_JsonMap`.
Map<String, dynamic> notALinkedHashMap(Map<String, dynamic> from) =>
    UnmodifiableMapView<String, dynamic>(from);

void main() {
  const converter = DynamicValueConverter();

  group('an object whose maps are not LinkedHashMaps', () {
    test('decodes its members', () {
      final json = notALinkedHashMap({
        'type': 'object',
        'value': notALinkedHashMap({
          'spaceBetweenBatches':
              notALinkedHashMap({'type': 'integer', 'value': 7}),
          'name': notALinkedHashMap({'type': 'string', 'value': 'Flök'}),
        }),
      });

      final value = converter.fromJson(json);

      expect(value.isObject, isTrue);
      expect(value['spaceBetweenBatches'].asInt, 7);
      expect(value['name'].asString, 'Flök');
    });

    test('decodes an object nested inside an object', () {
      final json = notALinkedHashMap({
        'type': 'object',
        'value': notALinkedHashMap({
          'inner': notALinkedHashMap({
            'type': 'object',
            'value': notALinkedHashMap({
              'leaf': notALinkedHashMap({'type': 'boolean', 'value': true}),
            }),
          }),
        }),
      });

      final value = converter.fromJson(json);

      expect(value['inner']['leaf'].asBool, isTrue);
    });

    test('decodes an object inside an array', () {
      final json = notALinkedHashMap({
        'type': 'array',
        'value': [
          notALinkedHashMap({
            'type': 'object',
            'value': notALinkedHashMap({
              'leaf': notALinkedHashMap({'type': 'integer', 'value': 1}),
            }),
          }),
        ],
      });

      final value = converter.fromJson(json);

      expect(value[0]['leaf'].asInt, 1);
    });
  });

  test('the shape jsonDecode gives on the VM still decodes', () {
    // The case that always worked, kept so the fix cannot trade one platform
    // for the other.
    final json = jsonDecode(
      '{"type":"object","value":{"n":{"type":"integer","value":3}}}',
    ) as Map<String, dynamic>;

    expect(converter.fromJson(json)['n'].asInt, 3);
  });

  test('a non-map is still refused by name', () {
    // The guard at the top of fromJson, which reports a FormatException rather
    // than letting a cast fail somewhere deeper with a minified type name.
    expect(() => converter.fromJson(<dynamic>['not', 'a', 'map']),
        throwsA(isA<FormatException>()));
  });
}

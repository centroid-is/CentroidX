/// The OPC-UA → relay-protocol value converter, in its new home.
///
/// These are the PURE arms of what used to live beside the OPC UA link in
/// `tfc_relay_local`: the quality table, the source-time preservation, the
/// Bad-drops-the-payload rule and the struct/array normalisation. They need no
/// server — they construct a binding sample by hand and assert what the
/// converter makes of it — which is exactly why they belong in the fast lane
/// beside the moved code (relay_local keeps its real-server arms, which now
/// exercise the same functions through the re-export).
@TestOn('vm')
library;

import 'package:open62541/open62541.dart';
import 'package:tfc_dart/core/opcua_value_translation.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;
import 'package:test/test.dart';

/// A binding sample with an explicit status code and (optionally) a source
/// stamp. `statusCode`/`sourceTimestamp` are mutable fields on the resolved
/// build (the `monitor-quality-sourcetime` override).
DynamicValue sample(
  Object? value, {
  int? statusCode,
  DateTime? sourceTimestamp,
}) =>
    DynamicValue(value: value)
      ..statusCode = statusCode
      ..sourceTimestamp = sourceTimestamp;

void main() {
  group('qualityForOpcUaStatus: the table an operator reads', () {
    test('absent and Good both mean good', () {
      expect(qualityForOpcUaStatus(null), relay.Quality.good);
      expect(qualityForOpcUaStatus(opcUaStatusCodeGood), relay.Quality.good);
      expect(qualityForOpcUaStatus(0), relay.Quality.good);
    });

    test('the tag-is-gone codes are errorConfig (waiting will not fix it)', () {
      expect(qualityForOpcUaStatus(opcUaBadNodeIdUnknown),
          relay.Quality.errorConfig);
      expect(qualityForOpcUaStatus(opcUaBadNodeIdInvalid),
          relay.Quality.errorConfig);
      expect(qualityForOpcUaStatus(opcUaBadAttributeIdInvalid),
          relay.Quality.errorConfig);
    });

    test('a type mismatch has its own quality', () {
      expect(qualityForOpcUaStatus(opcUaBadTypeMismatch),
          relay.Quality.errorTypeMismatch);
    });

    test('an unruled Bad is the TRANSIENT one, not errorConfig', () {
      expect(qualityForOpcUaStatus(opcUaBadCommunicationError),
          relay.Quality.badCommFault);
      expect(qualityForOpcUaStatus(opcUaBadInternalError),
          relay.Quality.badCommFault);
      expect(qualityForOpcUaStatus(opcUaBadSessionIdInvalid),
          relay.Quality.badCommFault);
    });

    test('any Uncertain is last-known', () {
      expect(qualityForOpcUaStatus(opcUaUncertainLastUsableValue),
          relay.Quality.uncertainLastKnown);
    });
  });

  group('qualityForOpcUaErrorText: the same table, read out of prose', () {
    test('the config codes by name', () {
      expect(qualityForOpcUaErrorText('… BadNodeIdUnknown …'),
          relay.Quality.errorConfig);
      expect(qualityForOpcUaErrorText('… BadNodeIdInvalid …'),
          relay.Quality.errorConfig);
      expect(qualityForOpcUaErrorText('… BadAttributeIdInvalid …'),
          relay.Quality.errorConfig);
    });

    test('type mismatch by name', () {
      expect(qualityForOpcUaErrorText('… BadTypeMismatch …'),
          relay.Quality.errorTypeMismatch);
    });

    test('anything else is transient, never errorConfig', () {
      expect(qualityForOpcUaErrorText('some sentence nobody taught this'),
          relay.Quality.badCommFault);
    });

    test(
        'the binding\'s own decode failures are errorTypeMismatch — '
        'waiting will not teach it Guid', () {
      // The exact texts the pinned binding throws when a variant's declared
      // DataType has no payload mapping (`common.dart:170`) and when an
      // ExtensionObject's binary encoding is unknown to it
      // (`opcua_serializer.dart:322`). The 200-server bench measured what the
      // old mapping did with these: badCommFault, a transient label on a
      // permanent condition — and on the subscribe path, nothing at all.
      expect(
          qualityForOpcUaErrorText('Unsupported nodeId type: '
              'NodeId(namespace: 0, identifier: 14)'),
          relay.Quality.errorTypeMismatch);
      expect(
          qualityForOpcUaErrorText('Unsupported binary encoding id: '
              'NodeId(namespace: 0, identifier: 886) for AttributeId '
              'UA_ATTRIBUTEID_DATATYPEDEFINITION'),
          relay.Quality.errorTypeMismatch);
    });
  });

  group('translateOpcUaSample: the one crossing point', () {
    test('a good sample carries the server\'s source time, not arrival', () {
      final source = DateTime.utc(2026, 1, 2, 3, 4, 5);
      final arrival = DateTime.utc(2026, 1, 2, 3, 4, 9);
      var fell = 0;
      final out = translateOpcUaSample(
        sample(7, statusCode: 0, sourceTimestamp: source),
        arrivedAt: arrival,
        onSourceTimeFallback: () => fell++,
      );
      expect(out.value, 7);
      expect(out.quality, relay.Quality.good);
      expect(out.sourceTime, source);
      expect(fell, 0, reason: 'the server stamped it; no fallback');
    });

    test('no source stamp falls back to arrival and CALLS the counter, but '
        'does NOT degrade quality', () {
      final arrival = DateTime.utc(2026, 1, 2, 3, 4, 9);
      var fell = 0;
      final out = translateOpcUaSample(
        sample(7, statusCode: 0),
        arrivedAt: arrival,
        onSourceTimeFallback: () => fell++,
      );
      expect(out.sourceTime, arrival);
      expect(out.quality, relay.Quality.good, reason: 'a missing stamp is not '
          'a bad reading');
      expect(fell, 1);
    });

    test('a Bad sample drops its payload (null under a bad badge)', () {
      final out = translateOpcUaSample(
        sample(999, statusCode: opcUaBadNodeIdUnknown),
        arrivedAt: DateTime.utc(2026),
        onSourceTimeFallback: () {},
      );
      expect(out.value, isNull,
          reason: 'a number nobody measured must not be published');
      expect(out.quality, relay.Quality.errorConfig);
    });

    test('an unruled Bad also drops the payload, transient quality', () {
      final out = translateOpcUaSample(
        sample(42, statusCode: opcUaBadCommunicationError),
        arrivedAt: DateTime.utc(2026),
        onSourceTimeFallback: () {},
      );
      expect(out.value, isNull);
      expect(out.quality, relay.Quality.badCommFault);
    });
  });

  group('the payload normaliser handles nested binding values', () {
    test('a plain scalar passes through', () {
      final out = translateOpcUaSample(
        sample(3.5, statusCode: 0),
        arrivedAt: DateTime.utc(2026),
        onSourceTimeFallback: () {},
      );
      expect(out.value, 3.5);
    });

    test('a list of binding values is unwrapped element-wise', () {
      final out = translateOpcUaSample(
        sample(<Object?>[DynamicValue(value: 1), DynamicValue(value: 2)],
            statusCode: 0),
        arrivedAt: DateTime.utc(2026),
        onSourceTimeFallback: () {},
      );
      // The protocol ctor re-normalises each element into its own
      // relay.DynamicValue; the binding wrapping is gone underneath it.
      final list = out.value as List;
      expect(list.map((e) => (e as relay.DynamicValue).value), <Object?>[1, 2]);
    });

    test('a struct (map of binding values) is unwrapped by key', () {
      final out = translateOpcUaSample(
        sample(<Object?, Object?>{'a': DynamicValue(value: 10), 'b': 20},
            statusCode: 0),
        arrivedAt: DateTime.utc(2026),
        onSourceTimeFallback: () {},
      );
      final map = out.value as Map;
      expect((map['a'] as relay.DynamicValue).value, 10);
      expect((map['b'] as relay.DynamicValue).value, 20);
    });
  });
}

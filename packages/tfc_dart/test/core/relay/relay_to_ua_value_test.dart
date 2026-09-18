/// `relayToUaValue`: the pipe's value, converted for `Expression`'s boolean
/// math.
///
/// The crossing exists because `Expression` is typed on `package:open62541`'s
/// `DynamicValue` and stays that way (DI-7): every collector sample condition
/// and every conditional icon on every page depends on it, and genericising it
/// in a TDD phase is a change nobody can bound. So the backend converts.
///
/// **The arms below are about what must NOT be lost or invented in that
/// crossing.** A converter that returns `DynamicValue(value: raw)` and nothing
/// else compiles, passes a naive smoke test, and quietly drops the plant's
/// instant — which is the one thing `resolveAlarmStamp` exists to consume. And
/// a converter that helpfully substitutes `0` for a null payload under a bad
/// quality manufactures the exact false activation D-3 exists to prevent.
///
/// Import prefixes are the house rule (`opcua_value_translation.dart`'s
/// IMPORT-PREFIX HAZARD, R-6): `package:open62541` bare, the protocol
/// `as relay`.
library;

import 'package:open62541/open62541.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/relay/relay_to_ua_value.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

void main() {
  group('relayToUaValue', () {
    test('a primitive keeps its value, its name and the plant instant', () {
      final at = DateTime.utc(2026, 9, 6, 12, 0, 0);

      final out = relayToUaValue(
        relay.DynamicValue(value: 42.5, sourceTime: at),
        name: 'tank.temp',
      );

      expect(out.value, 42.5);
      expect(out.name, 'tank.temp');
      expect(out.asDouble, 42.5);
      // The git build (`monitor-quality-sourcetime`, pinned at 0251aa09) has
      // both fields. Dropping the instant here would make every converted
      // value a `backend_receipt` stamp downstream, and the reason would be
      // invisible: nothing throws when a nullable field stays null.
      expect(out.sourceTimestamp, at,
          reason: 'the plant instant must survive the crossing');
      expect(out.statusCode, 0,
          reason: 'a good-band relay quality is UA Good (0)');
    });

    test('a struct converts member by member into a real ua object graph', () {
      final at = DateTime.utc(2026, 9, 6, 12, 0, 0);

      final out = relayToUaValue(
        relay.DynamicValue(
          value: {'temp': 4.0, 'running': true},
          sourceTime: at,
        ),
        name: 'tank',
      );

      // Not a Map hiding inside one DynamicValue: `Expression` indexes members,
      // and a bare Map answers `DynamicType.unknown` to every accessor.
      expect(out.isObject, isTrue);
      expect(out['temp'].asDouble, 4.0);
      expect(out['temp'].name, 'temp');
      expect(out['running'].asBool, isTrue);
      expect(out.sourceTimestamp, at);
    });

    test('an array converts element by element', () {
      final out = relayToUaValue(
        relay.DynamicValue(value: [1, 2, 3]),
        name: 'counts',
      );

      expect(out.isArray, isTrue);
      expect(out[0].asInt, 1);
      expect(out[1].asInt, 2);
      expect(out[2].asInt, 3);
    });

    test('a bad-quality null payload stays null -- no invented zero', () {
      final out = relayToUaValue(
        relay.DynamicValue(value: null, quality: relay.Quality.badCommFault),
        name: 'tank.temp',
      );

      // The whole of D-3 rests on this: `Expression._evaluate` reads a null
      // through `asDouble == 0.0`, so a converter that substituted a zero would
      // make `tank.temp < 5` true on a dead link and no gate downstream could
      // tell. The conversion carries the absence; the WATCHER refuses to
      // evaluate it.
      expect(out.value, isNull);
      expect(out.isNull, isTrue);
      expect(out.statusCode, isNotNull,
          reason: 'a bad relay quality must not read as UA Good');
      expect(out.statusCode! & 0x80000000, isNot(0),
          reason: 'the Bad band bit must be set');
    });
  });
}

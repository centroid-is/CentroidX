/// The comparison the gateway's idempotency window is judged by (05-RESEARCH
/// §A.2, WRT-02).
///
/// `value_handlers.write` has to answer one question about a repeated cmd id:
/// is this the *same* operator action arriving twice, or a different write
/// wearing a re-used id? Getting it wrong in one direction costs a refusal on
/// a path where a refusal is honest ("definitively no effect"). Getting it
/// wrong in the other direction reports one write's outcome for a genuinely
/// different write — the operator reads "applied" about a setpoint nobody
/// applied. These cases pin the direction the helper errs in.
library;

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

void main() {
  group('jsonEquals', () {
    test('an identical reference is the same request', () {
      final payload = <String, Object?>{
        'key': 'ST101.CN04.SPEED',
        'value': {
          'setpoint': 1450,
          'ramp': [1, 2, 3],
        },
      };
      expect(jsonEquals(payload, payload), isTrue,
          reason: 'a params map compared against itself must never look like '
              'a second, different write of the same cmd id');
    });

    test('two params maps built in a different order are the same request', () {
      // The named case the plan's sabotage arm targets: `jsonEncode(a) ==
      // jsonEncode(b)` makes key order significant, and JSON object order is
      // not semantically meaningful. A client that rebuilds its params map
      // from a different iteration order (a re-send after reconnect walks a
      // different map) would otherwise be told its own replay is a new write.
      final first = <String, Object?>{'key': 'ST201.PUMP.CMD', 'value': 1};
      final second = <String, Object?>{'value': 1, 'key': 'ST201.PUMP.CMD'};
      expect(jsonEquals(first, second), isTrue,
          reason: 'an operator re-sending the same command must reach the '
              'logged outcome, not a refusal manufactured by map iteration '
              'order');
    });

    test('a rebuilt copy of a nested payload is the same request', () {
      // The named case Dart's default `a == b` fails: Map and List equality
      // is identity, so a payload decoded twice off the wire would look like
      // two different writes.
      final original = <String, Object?>{
        'a': [
          1,
          {'b': 2},
        ],
      };
      final rebuilt = <String, Object?>{
        'a': [
          1,
          {'b': 2},
        ],
      };
      expect(jsonEquals(original, rebuilt), isTrue,
          reason: 'the same command decoded twice off the wire is one '
              'operator action and must resolve to one outcome');
    });

    test('a reordered list is a different request', () {
      // Object order is not meaningful; *array* order is. A ramp profile
      // written back-to-front is a different write.
      final ascending = <String, Object?>{
        'a': [
          1,
          {'b': 2},
        ],
      };
      final descending = <String, Object?>{
        'a': [
          {'b': 2},
          1,
        ],
      };
      expect(jsonEquals(ascending, descending), isFalse,
          reason: 'a ramp profile in the opposite order is a different '
              'machine movement and must not inherit the first one\'s outcome');
    });

    test('a DINT 1 and a REAL 1.0 are different writes', () {
      // Dart's `==` is true across int/double; PLC tags are not. Writing 1 to
      // a DINT and 1.0 to a REAL are two different writes, and the second
      // must not be answered with the first one's outcome.
      expect(jsonEquals(1, 1.0), isFalse,
          reason: 'a REAL write must not be reported with a DINT write\'s '
              'outcome — refusing a legitimate replay is degrading, '
              'answering the wrong write is unsafe');
      expect(jsonEquals(<String, Object?>{'value': 1}, {'value': 1.0}), isFalse,
          reason: 'the same strictness has to hold once the number is nested '
              'inside the params map the gateway actually fingerprints');
      expect(jsonEquals(1, 1), isTrue,
          reason: 'strictness about the type must not break the ordinary '
              'case of one integer setpoint sent twice');
      expect(jsonEquals(1.5, 1.5), isTrue,
          reason: 'the same for an analogue setpoint sent twice');
    });

    test('an absent key and a key holding null are different requests', () {
      expect(jsonEquals(<String, Object?>{'a': 1}, {'a': 1, 'b': null}),
          isFalse,
          reason: 'omitting a field and explicitly clearing it are different '
              'instructions to the PLC');
      expect(jsonEquals(<String, Object?>{'a': 1, 'b': null}, {'a': 1}),
          isFalse,
          reason: 'and the asymmetry must not depend on which side arrived '
              'first');
    });

    test('same length, different keys is a different request', () {
      // Length-then-lookup implementations that trust length alone read a
      // missing key as null and call two different maps equal.
      expect(jsonEquals(<String, Object?>{'a': 1}, {'b': 1}), isFalse,
          reason: 'writing 1 to a different tag is a different write');
      expect(jsonEquals(<String, Object?>{'a': null}, {'b': null}), isFalse,
          reason: 'and a null value must not let a missing key pass as '
              'present');
    });

    test('shapes that JSON keeps apart stay apart', () {
      expect(jsonEquals(<Object?>[], <String, Object?>{}), isFalse,
          reason: 'an empty list and an empty object are different payloads');
      expect(jsonEquals(null, 0), isFalse,
          reason: 'no value and a zero setpoint are different writes');
      expect(jsonEquals('', null), isFalse,
          reason: 'an empty string and no value are different writes');
      expect(jsonEquals(true, 1), isFalse,
          reason: 'a coil command and an integer 1 are different writes');
      expect(jsonEquals(1, '1'), isFalse,
          reason: 'a numeric setpoint and its string spelling are different '
              'writes');
      expect(jsonEquals(<Object?>[1], <Object?>[1, 2]), isFalse,
          reason: 'a longer ramp is a different movement');
    });

    test('unequal leaves inside an otherwise equal payload are caught', () {
      expect(
          jsonEquals(
            <String, Object?>{
              'key': 'ST301.KN02.SPEED',
              'value': {'setpoint': 1450},
            },
            <String, Object?>{
              'key': 'ST301.KN02.SPEED',
              'value': {'setpoint': 1451},
            },
          ),
          isFalse,
          reason: 'a setpoint one unit apart is the write most likely to be '
              'mistaken for a replay, and the one that must not be');
    });

    test('a legally deep payload compares without stack death', () {
      // Ingress is bounded at depth 64 by `sanitize`, so 60 is legal input
      // and must cost nothing. Anything deeper never reaches this helper.
      Object? nest(int depth) {
        Object? node = 'leaf';
        for (var i = 0; i < depth; i++) {
          node = <String, Object?>{'n': node};
        }
        return node;
      }

      expect(jsonEquals(nest(60), nest(60)), isTrue,
          reason: 'a deeply structured PLC struct written twice is still one '
              'operator action');
      final deviant = nest(59);
      expect(jsonEquals(nest(60), <String, Object?>{'n': deviant}), isTrue,
          reason: 'the walk must reach the bottom rather than stopping early');
      expect(jsonEquals(nest(60), nest(59)), isFalse,
          reason: 'a differently shaped struct at depth is a different write');
    });

    test('an unrecognised shape is not equal, ever', () {
      // The err-toward-not-equal rule (05-RESEARCH §A.2). Nothing that is not
      // decoded JSON should reach here, but if something does, the answer
      // that costs a refusal is the safe one.
      final blob = Object();
      expect(jsonEquals(blob, Object()), isFalse,
          reason: 'an unexpected payload type must produce a refusal, not a '
              'claimed match against another write');
      expect(jsonEquals(blob, blob), isTrue,
          reason: 'the identity of one and the same object is still the same '
              'request');
      expect(jsonEquals(<String, Object?>{'a': 1}, <Object?>[1]), isFalse,
          reason: 'a map and a list are different payloads');
      expect(jsonEquals(Duration.zero, 0), isFalse,
          reason: 'a non-JSON leaf must never match a JSON one');
    });

    test('int-keyed maps compare by key, like sanitize preserves them', () {
      // `sanitize` deliberately preserves non-String map keys because the
      // OPC UA and M2400 converters produce them; the fingerprint has to
      // survive the same shape rather than throwing on it.
      expect(jsonEquals(<Object?, Object?>{1: 'a'}, <Object?, Object?>{1: 'a'}),
          isTrue,
          reason: 'a converter-shaped payload written twice is one action');
      expect(jsonEquals(<Object?, Object?>{1: 'a'}, <Object?, Object?>{'1': 'a'}),
          isFalse,
          reason: 'an integer key and its string spelling are different '
              'structures');
    });
  });
}

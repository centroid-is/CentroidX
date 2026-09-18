/// The wire shape of **acknowledge**: one name, and one identity.
///
/// Phase 14 plan 12, from Jón's Q-1 ruling of 2026-09-06 — *"The acknowledge
/// is not used anywhere yet. So let's relay it."* Nothing depends on the old
/// behaviour, so the ack is built rather than disabled.
///
/// Two properties this file exists for, and neither is served by the ordinary
/// round-trip arm alone:
///
///  * **The name is a literal.** `alarm_keys.dart` makes the argument for
///    `ALARM.active` and it holds verbatim here: a wire name is matched by a
///    gateway out in the plant, so a second spelling compiles, keeps every
///    suite green, and quietly answers `-32601` for every deployment.
///  * **The identity is D-4's and only D-4's.** `toJson`'s key set is asserted
///    as an *equality*. A second identity scheme sneaking onto this frame —
///    a `historyId` beside the pair, say — is the failure this file is here to
///    catch, because two identities for one row can disagree and the disagreeing
///    ack acknowledges the wrong alarm.
library;

import 'dart:convert';

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// Encode → `jsonEncode` → `jsonDecode` → decode, with an unknown field bolted
/// on, exactly as `messages_test.dart` does it.
Map<String, Object?> viaJson(Map<String, Object?> json,
        {Map<String, Object?> extra = const {}}) =>
    jsonDecode(jsonEncode({...json, ...extra})) as Map<String, Object?>;

void main() {
  test('the wire name is a literal, not whatever the constant happens to say',
      () {
    // Spelled against a bare string on purpose. A test written as
    // `expect(Methods.ackAlarm, Methods.ackAlarm)` agrees with a rename and
    // asserts nothing about the name a gateway in the plant is matching.
    expect(Methods.ackAlarm, 'ackAlarm');
  });

  test('AckAlarmParams round-trips both fields', () {
    final params = AckAlarmParams(alarmUid: 'u', ruleIndex: 2);
    final decoded = AckAlarmParams.fromJson(viaJson(params.toJson()));

    expect(decoded.alarmUid, 'u');
    expect(decoded.ruleIndex, 2);
  });

  test('the frame carries D-4\'s identity and nothing else', () {
    final json = AckAlarmParams(alarmUid: 'u', ruleIndex: 0).toJson();

    // An equality, not a `contains`. `(alarm_uid, rule_index)` is already the
    // key of the partial unique index on `alarm_history`, so a third field
    // here would be a second way to name the same row — and the two can
    // disagree.
    expect(json.keys.toSet(), {'alarmUid', 'ruleIndex'});
  });

  test('a missing alarmUid is refused by name', () {
    // Not a null that reaches the gateway and acknowledges whatever row sorts
    // first.
    expect(() => AckAlarmParams.fromJson(const {'ruleIndex': 1}),
        throwsFormatException);
  });

  test('an empty alarmUid is refused', () {
    // `HoldTickParams`' empty-key precedent verbatim: a frame that reads as
    // valid and identifies nothing.
    expect(
        () => AckAlarmParams.fromJson(const {'alarmUid': '', 'ruleIndex': 1}),
        throwsFormatException);
    expect(() => AckAlarmParams(alarmUid: '', ruleIndex: 1),
        throwsA(isA<ArgumentError>()));
  });

  test('a non-integer ruleIndex is refused, including 1e999\'s Infinity', () {
    expect(
        () =>
            AckAlarmParams.fromJson(const {'alarmUid': 'u', 'ruleIndex': 'two'}),
        throwsFormatException,
        reason: 'a string index cannot name a rule');
    expect(
        () => AckAlarmParams.fromJson(const {'alarmUid': 'u', 'ruleIndex': 1.5}),
        throwsFormatException,
        reason: 'a rule index is a position in a list, not a fraction of one');
    expect(
        () => AckAlarmParams.fromJson(
            jsonDecode('{"alarmUid":"u","ruleIndex":1e999}')
                as Map<String, Object?>),
        throwsFormatException,
        reason: '`1e999` decodes to Infinity without complaint, and '
            '`Infinity.toInt()` throws an UnsupportedError nothing at this '
            'boundary catches — the poison WriteParams.fromJson defuses');
    expect(() => AckAlarmParams.fromJson(const {'alarmUid': 'u'}),
        throwsFormatException,
        reason: 'an absent index is not a zero');
  });

  test('a negative ruleIndex is refused', () {
    expect(
        () => AckAlarmParams.fromJson(const {'alarmUid': 'u', 'ruleIndex': -1}),
        throwsFormatException,
        reason: 'refusing here is cheaper than a gateway asking an engine '
            'about rule minus one');
    expect(() => AckAlarmParams(alarmUid: 'u', ruleIndex: -1),
        throwsA(isA<ArgumentError>()));
  });

  test('an unknown extra field is ignored, not refused', () {
    // Forward compatibility runs the other way too: a newer client may add a
    // field and an older gateway must keep working. Pinned because "ignore" is
    // a decision and the opposite one is also defensible.
    final decoded = AckAlarmParams.fromJson(viaJson(
        AckAlarmParams(alarmUid: 'u', ruleIndex: 3).toJson(),
        extra: const {'futureField': 123}));

    expect(decoded.alarmUid, 'u');
    expect(decoded.ruleIndex, 3);
  });
}

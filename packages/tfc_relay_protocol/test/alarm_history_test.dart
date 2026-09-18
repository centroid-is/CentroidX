/// The wire shape of **alarm history**: the request window, and the row.
///
/// ## What this file is defending
///
/// `RelayAlarmSource.getRecentAlarms` used to read the panel's own database.
/// On a gateway station `preferencesProvider` now builds `Preferences` with
/// `db: null` (`lib/providers/preferences.dart:60`), so that method's
/// `if (preferences.database == null) return []` was the **only** branch that
/// ever ran: an empty history page on a plant that has had alarms all week,
/// with no error, no line on stderr and nothing on screen to say the answer
/// was not an answer.
///
/// So the two properties every arm below serves are:
///
///  * **An answer nobody can read is refused, never decoded as empty.**
///    [AlarmActiveEntry.decodeList] is deliberately tolerant — a banner must
///    not go blank on a frame it did not expect, and the previous active set
///    stands. History has no previous set to stand: a tolerant decode here
///    reproduces the exact silence this whole change exists to remove, so
///    [AlarmHistoryEntry.decodeList] throws.
///  * **A window that can only answer empty is refused at the door.** A
///    `limit` of zero, and a `from` after its `to`, both come back as an empty
///    list that is indistinguishable from a quiet plant.
///
/// ## Absence is spelled by absence
///
/// `userSummaryToJson`'s convention, and it is the one the lead named: epoch
/// milliseconds UTC under `…Ms` keys, **omitted** when null rather than sent
/// as an explicit null. 17-06 measured what a present-null costs on this wire
/// (every create/update/delete answering `-32602`). Three fields on a history
/// row are legitimately absent and they mean three different things —
/// `deactivatedAtMs` absent is *still standing*, `ruleIndex` absent is a
/// pre-v7 row that names no rule, `tsSource` absent is a row written before
/// anybody recorded provenance — and none of them may be confused with a zero.
library;

import 'dart:convert';

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// Encode → `jsonEncode` → `jsonDecode` → decode, `ack_alarm_params_test.dart`'s
/// helper verbatim: a shape that survives a real JSON round trip, plus an
/// unknown field a newer peer might add.
Map<String, Object?> viaJson(Map<String, Object?> json,
        {Map<String, Object?> extra = const {}}) =>
    jsonDecode(jsonEncode({...json, ...extra})) as Map<String, Object?>;

AlarmHistoryEntry _entry({
  String uid = 'CN04.MOT01',
  int? ruleIndex = 1,
  String? tsSource = AlarmActiveEntry.tsSourcePlant,
  DateTime? deactivatedAt,
  bool active = true,
}) =>
    AlarmHistoryEntry(
      uid: uid,
      ruleIndex: ruleIndex,
      level: 'error',
      title: 'Motor overload',
      description: 'the drive tripped',
      group: const ['Line 3', 'Multivac'],
      expression: 'a{10.0} > 5',
      acknowledgeRequired: true,
      active: active,
      pendingAck: false,
      createdAt: DateTime.utc(2026, 9, 8, 19, 18, 3),
      deactivatedAt: deactivatedAt,
      tsSource: tsSource,
    );

void main() {
  group('the method name', () {
    test('is a literal, not whatever the constant happens to say', () {
      // `alarm_keys.dart`'s argument, which holds for every name a gateway out
      // in the plant matches: a second spelling compiles, keeps every suite
      // green, and answers `-32601` for every deployment.
      expect(Methods.alarmHistory, 'alarmHistory');
    });
  });

  group('AlarmHistoryParams — the window', () {
    test('round-trips the limit and both bounds as epoch ms UTC', () {
      final params = AlarmHistoryParams(
        limit: 250,
        from: DateTime.utc(2026, 9, 1),
        to: DateTime.utc(2026, 9, 8),
      );
      final json = params.toJson();

      expect(json['fromMs'], DateTime.utc(2026, 9, 1).millisecondsSinceEpoch);
      expect(json['toMs'], DateTime.utc(2026, 9, 8).millisecondsSinceEpoch);

      final back = AlarmHistoryParams.fromJson(viaJson(json));
      expect(back.limit, 250);
      expect(back.from, DateTime.utc(2026, 9, 1));
      expect(back.to, DateTime.utc(2026, 9, 8));
      expect(back.from!.isUtc, isTrue,
          reason: 'a local-time round trip is what makes two panels in two '
              'time zones disagree about when the line stopped');
    });

    test('a local-time bound is normalised to UTC on the way out', () {
      final local = DateTime.utc(2026, 9, 1).toLocal();
      final json = AlarmHistoryParams(limit: 10, from: local).toJson();
      expect(json['fromMs'], DateTime.utc(2026, 9, 1).millisecondsSinceEpoch);
    });

    test('an unbounded window omits both keys rather than sending nulls', () {
      final json = AlarmHistoryParams(limit: 10).toJson();

      // An equality, `ack_alarm_params_test.dart`-style: a present null is
      // what 17-06 measured answering `-32602` for every call.
      expect(json.keys.toSet(), {'limit'});

      final back = AlarmHistoryParams.fromJson(viaJson(json));
      expect(back.from, isNull);
      expect(back.to, isNull);
    });

    test('a limit of zero is refused rather than answered empty', () {
      // The whole point of this file. Zero rows and a plant that has never
      // had an alarm look identical on screen, and one of them is a bug.
      expect(() => AlarmHistoryParams(limit: 0), throwsArgumentError);
      expect(() => AlarmHistoryParams.fromJson(const {'limit': 0}),
          throwsFormatException);
    });

    test('a negative limit is refused', () {
      expect(() => AlarmHistoryParams(limit: -1), throwsArgumentError);
      expect(() => AlarmHistoryParams.fromJson(const {'limit': -1}),
          throwsFormatException);
    });

    test('a limit above the cap is refused by name, never quietly clamped', () {
      // Clamping would answer 5000 rows to a caller that asked for 50 000 and
      // say nothing — a short list presented as the whole history, which is
      // the truncation failure `result_too_large.dart` refuses for charts.
      expect(() => AlarmHistoryParams(limit: AlarmHistoryParams.maxLimit + 1),
          throwsArgumentError);
      expect(
          () => AlarmHistoryParams.fromJson(
              {'limit': AlarmHistoryParams.maxLimit + 1}),
          throwsFormatException);
    });

    test('the cap clears what the app actually asks for', () {
      // `stop_timeline.dart:129` asks for 2000 and `AlarmSource` defaults to
      // 1000. A cap under either would refuse the panel's own reads.
      expect(AlarmHistoryParams.maxLimit, greaterThanOrEqualTo(2000));
    });

    test('a window that ends before it starts is refused', () {
      // It matches no row, so it comes back empty — and an empty answer to an
      // impossible question is the same silence by a longer route.
      expect(
          () => AlarmHistoryParams(
                limit: 10,
                from: DateTime.utc(2026, 9, 8),
                to: DateTime.utc(2026, 9, 1),
              ),
          throwsArgumentError);
      expect(
          () => AlarmHistoryParams.fromJson({
                'limit': 10,
                'fromMs': DateTime.utc(2026, 9, 8).millisecondsSinceEpoch,
                'toMs': DateTime.utc(2026, 9, 1).millisecondsSinceEpoch,
              }),
          throwsFormatException);
    });

    test('a missing limit is refused, never defaulted', () {
      expect(() => AlarmHistoryParams.fromJson(const {}),
          throwsFormatException);
    });

    test('a non-finite or fractional limit is refused', () {
      // `1e999` decodes to Infinity without complaint and `Infinity.toInt()`
      // throws an `UnsupportedError` nothing at this boundary catches —
      // `AckAlarmParams.fromJson`'s measured arm, here for the same reason.
      expect(() => AlarmHistoryParams.fromJson(jsonDecode('{"limit": 1e999}')
              as Map<String, Object?>),
          throwsFormatException);
      expect(() => AlarmHistoryParams.fromJson(const {'limit': 1.5}),
          throwsFormatException);
      expect(() => AlarmHistoryParams.fromJson(const {'limit': 'lots'}),
          throwsFormatException);
    });

    test('a non-finite or fractional bound is refused', () {
      expect(
          () => AlarmHistoryParams.fromJson(
              jsonDecode('{"limit": 10, "fromMs": 1e999}')
                  as Map<String, Object?>),
          throwsFormatException);
      expect(
          () => AlarmHistoryParams.fromJson(const {'limit': 10, 'toMs': 1.5}),
          throwsFormatException);
      expect(
          () =>
              AlarmHistoryParams.fromJson(const {'limit': 10, 'fromMs': 'when'}),
          throwsFormatException);
    });

    test('an unknown extra field is ignored, not refused', () {
      // Forward compatibility runs both ways: a newer panel adding a field
      // must not make an older gateway refuse to answer at all.
      final back = AlarmHistoryParams.fromJson(
          viaJson(AlarmHistoryParams(limit: 5).toJson(),
              extra: const {'sortBy': 'severity'}));
      expect(back.limit, 5);
    });
  });

  group('AlarmHistoryEntry — the row', () {
    test('every field round-trips', () {
      final entry = _entry(
          active: false,
          deactivatedAt: DateTime.utc(2026, 9, 8, 19, 22, 3));
      final back = AlarmHistoryEntry.fromJson(viaJson(entry.toJson()));

      expect(back.uid, 'CN04.MOT01');
      expect(back.ruleIndex, 1);
      expect(back.level, 'error');
      expect(back.title, 'Motor overload');
      expect(back.description, 'the drive tripped');
      expect(back.group, ['Line 3', 'Multivac']);
      expect(back.expression, 'a{10.0} > 5');
      expect(back.acknowledgeRequired, isTrue);
      expect(back.active, isFalse);
      expect(back.pendingAck, isFalse);
      expect(back.createdAt, DateTime.utc(2026, 9, 8, 19, 18, 3));
      expect(back.deactivatedAt, DateTime.utc(2026, 9, 8, 19, 22, 3));
      expect(back.tsSource, AlarmActiveEntry.tsSourcePlant);
      expect(back.createdAt.isUtc, isTrue);
      expect(back.deactivatedAt!.isUtc, isTrue);
      expect(back, entry);
    });

    test('the configuration is copied onto the row, not left to a join', () {
      // `alarm_active_entry.dart`'s argument, and it binds here with more
      // force: a gateway panel's `alarm_man_config` is a device-local mirror
      // and the backend's is the one the engine evaluated. A history row
      // joined against the panel's copy is a row the panel silently DROPS when
      // the two disagree — `AlarmMan.getRecentAlarms` returns null for an
      // unknown uid and `whereType` throws it away, so a renamed alarm empties
      // the page with no error.
      final json = _entry().toJson();
      expect(json.keys,
          containsAll(<String>['level', 'title', 'description', 'group']));
    });

    test('a still-standing row omits deactivatedAtMs rather than sending null',
        () {
      final json = _entry(deactivatedAt: null).toJson();
      expect(json.containsKey('deactivatedAtMs'), isFalse);
      expect(AlarmHistoryEntry.fromJson(viaJson(json)).deactivatedAt, isNull,
          reason: 'no deactivation time is what makes a row overlap every '
              'window it started before; a zero would date it to 1970');
    });

    test('a pre-v7 row omits ruleIndex rather than claiming rule 0', () {
      // Matching a row that names no rule to rule 0 is a guess dressed as a
      // fact, and the rule it would pick up is the one an acknowledge is sent
      // under.
      final json = _entry(ruleIndex: null).toJson();
      expect(json.containsKey('ruleIndex'), isFalse);
      expect(AlarmHistoryEntry.fromJson(viaJson(json)).ruleIndex, isNull);
    });

    test('a pre-v7 row omits tsSource rather than claiming a provenance', () {
      // Null and `backend_receipt` are different facts: one says nobody
      // recorded anything, the other says the backend positively guessed.
      final json = _entry(tsSource: null).toJson();
      expect(json.containsKey('tsSource'), isFalse);
      expect(AlarmHistoryEntry.fromJson(viaJson(json)).tsSource, isNull);
    });

    test('a tsSource nobody can interpret is refused by name', () {
      // `AlarmActiveEntry.fromJson`'s rule, for its reason: defaulting an
      // unknown to `plant` would relabel a backend guess as the plant's word
      // in the one field a stop analysis exists to be audited on.
      expect(
          () => AlarmHistoryEntry.fromJson(
              viaJson(_entry().toJson(), extra: {'tsSource': 'ntp'})),
          throwsFormatException);
      expect(
          () => AlarmHistoryEntry(
                uid: 'u',
                level: 'error',
                title: 't',
                description: 'd',
                createdAt: DateTime.utc(2026),
                tsSource: 'ntp',
              ),
          throwsArgumentError);
    });

    test('a negative ruleIndex is refused', () {
      expect(
          () => AlarmHistoryEntry(
                uid: 'u',
                ruleIndex: -1,
                level: 'error',
                title: 't',
                description: 'd',
                createdAt: DateTime.utc(2026),
              ),
          throwsArgumentError);
      expect(
          () => AlarmHistoryEntry.fromJson(
              viaJson(_entry().toJson(), extra: const {'ruleIndex': -1})),
          throwsFormatException);
    });

    test('a row with no uid is refused rather than decoded as an empty name',
        () {
      expect(
          () => AlarmHistoryEntry.fromJson(
              viaJson(_entry().toJson(), extra: const {'uid': ''})),
          throwsFormatException);
    });

    test('a row with no createdAtMs is refused, never dated to 1970', () {
      final json = viaJson(_entry().toJson())..remove('createdAtMs');
      expect(() => AlarmHistoryEntry.fromJson(json), throwsFormatException);
    });
  });

  group('the answer', () {
    test('a list of rows round-trips through encodeList/decodeList', () {
      final entries = [
        _entry(),
        _entry(uid: 'CN05.MOT01', ruleIndex: null, tsSource: null),
      ];
      final encoded = jsonDecode(jsonEncode(
          AlarmHistoryEntry.encodeList(entries)));
      expect(AlarmHistoryEntry.decodeList(encoded), entries);
    });

    test('an empty history round-trips as an empty list', () {
      // The one case that must stay representable: a plant that genuinely has
      // no history says so, and that answer is legible.
      final encoded =
          jsonDecode(jsonEncode(AlarmHistoryEntry.encodeList(const [])));
      expect(AlarmHistoryEntry.decodeList(encoded), isEmpty);
    });

    test('an answer that is not the expected shape is REFUSED, not emptied',
        () {
      // The heart of this file. `AlarmActiveEntry.decodeList` is tolerant on
      // purpose — the previous active set stands, and a banner must not go
      // blank. History has no previous set to stand on, so a tolerant decode
      // here would put an empty page on screen and call it the plant's
      // history. That is the bug this whole change exists to remove, so every
      // unreadable answer throws and the caller has something to show.
      expect(() => AlarmHistoryEntry.decodeList(null), throwsFormatException);
      expect(() => AlarmHistoryEntry.decodeList('history'),
          throwsFormatException);
      expect(() => AlarmHistoryEntry.decodeList(const <Object?>[]),
          throwsFormatException,
          reason: 'a bare list is an older or different answer, not this one');
      expect(() => AlarmHistoryEntry.decodeList(const <String, Object?>{}),
          throwsFormatException,
          reason: 'a map with no "entries" key states nothing about history');
      expect(
          () => AlarmHistoryEntry.decodeList(
              const <String, Object?>{'entries': 'lots'}),
          throwsFormatException);
    });

    test('one unreadable row refuses the whole answer', () {
      // Not "skip it and return the rest". A partial history presented as a
      // whole one is a stop analysis missing the interval nobody knows is
      // missing.
      final good = _entry().toJson();
      final bad = {...good, 'tsSource': 'ntp'};
      expect(
          () => AlarmHistoryEntry.decodeList(
              jsonDecode(jsonEncode({'entries': [good, bad]}))),
          throwsFormatException);
    });
  });
}

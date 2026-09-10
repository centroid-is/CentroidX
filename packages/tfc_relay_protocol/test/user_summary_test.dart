// UserSummary — the roster row `AccessAdminApi.listUsers` answers.
//
// The type exists because 17-08's F-1 found the users screen drawing
// 1970-01-01 in the created column for every account on a gateway station:
// `listUsers` answered `AuthenticatedUser`, a *session identity* with nowhere
// to put a date, and the panel filled the hole with epoch zero. These arms pin
// down the two properties that keep that from coming back — the timestamps
// cross, and their absence is spelled by absence rather than by a zero — plus
// the safety property the type was given in the first place: there is nowhere
// on it to put a credential.

import 'package:tfc_access/tfc_access.dart';
import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

void main() {
  group('UserSummary crosses the wire', () {
    test('every field round-trips, timestamps as epoch ms UTC', () {
      const summary = UserSummary(
        username: 'ST101-panel',
        roleName: 'Panel Operator',
        displayName: 'ST101',
        stationAccount: true,
      );
      final withTimes = UserSummary(
        username: summary.username,
        roleName: summary.roleName,
        displayName: summary.displayName,
        stationAccount: summary.stationAccount,
        createdAt: DateTime.utc(2026, 4, 1, 7, 30),
        lastLoginAt: DateTime.utc(2026, 9, 8, 6, 15),
      );

      final json = userSummaryToJson(withTimes);
      expect(json['createdAtMs'],
          DateTime.utc(2026, 4, 1, 7, 30).millisecondsSinceEpoch,
          reason: 'one integer, the spelling auditRecordToJson already uses — '
              'no timezone for two ends to disagree about');

      final back = userSummaryFromJson(json);
      expect(back.username, 'ST101-panel');
      expect(back.roleName, 'Panel Operator');
      expect(back.displayName, 'ST101');
      expect(back.stationAccount, isTrue);
      expect(back.createdAt, withTimes.createdAt);
      expect(back.lastLoginAt, withTimes.lastLoginAt);
      expect(back.createdAt!.isUtc, isTrue,
          reason: 'a decoded instant is UTC, so a panel in Iceland and one in '
              'a UTC+2 test both render the same wall time');
    });

    test('a local-time instant is normalised to UTC on the way out', () {
      final local = DateTime.utc(2026, 4, 1, 7, 30).toLocal();
      final json = userSummaryToJson(UserSummary(
          username: 'jon', roleName: 'Engineering', createdAt: local));
      expect(json['createdAtMs'],
          DateTime.utc(2026, 4, 1, 7, 30).millisecondsSinceEpoch);
    });

    test('absence is spelled by absence, never by a present null or a zero',
        () {
      final json = userSummaryToJson(
          const UserSummary(username: 'jon', roleName: 'Engineering'));
      expect(json.containsKey('createdAtMs'), isFalse,
          reason: '17-06 recorded what a present-null field costs — every '
              'create/update/delete answering -32602');
      expect(json.containsKey('lastLoginAtMs'), isFalse);
      expect(json.containsKey('displayName'), isFalse);

      final back = userSummaryFromJson(json);
      expect(back.createdAt, isNull,
          reason: 'a missing key means the server did not say, which is not '
              'the same claim as epoch zero');
      expect(back.lastLoginAt, isNull);
      expect(back.stationAccount, isFalse);
    });

    test('a null createdAt is what an older backend looks like, and decodes '
        'rather than throwing', () {
      // Exactly the payload a backend that predates the DTO sends: the four
      // fields it had, and no timestamps. The roster must still render.
      final back = userSummaryFromJson(const <String, Object?>{
        'username': 'ST101-panel',
        'roleName': 'Panel Operator',
        'stationAccount': true,
      });
      expect(back.username, 'ST101-panel');
      expect(back.createdAt, isNull);
    });

    test('there is nowhere on the wire form to put a credential', () {
      final json = userSummaryToJson(UserSummary(
          username: 'jon',
          roleName: 'Engineering',
          createdAt: DateTime.utc(2026, 1, 1),
          lastLoginAt: DateTime.utc(2026, 1, 2)));
      expect(
          json.keys.toSet(),
          {
            'username',
            'roleName',
            'stationAccount',
            'hasPassword',
            'createdAtMs',
            'lastLoginAtMs',
          },
          reason: 'the reason listUsers does not answer app_user\'s drift row: '
              'a hash cannot reach this wire by somebody forgetting to strip '
              'it, because there is no key for one');
    });

    test('hasPassword crosses, and an older backend reads as protected', () {
      final open = userSummaryToJson(const UserSummary(
          username: 'line', roleName: 'Operator', hasPassword: false));
      expect(open['hasPassword'], isFalse);
      expect(userSummaryFromJson(open).hasPassword, isFalse,
          reason: 'the users screen cannot mark an open account it is not '
              'told about');

      // What a backend that predates the field sends: no key at all.
      final older = userSummaryFromJson(const <String, Object?>{
        'username': 'line',
        'roleName': 'Operator',
      });
      expect(older.hasPassword, isTrue,
          reason: 'assume protected for an unknown — under-claiming is the '
              'safe direction, telling somebody an account is open when it is '
              'not is the unsafe one');
    });

    test('hasPassword says whether there is a credential, never what it is',
        () {
      final json = userSummaryToJson(const UserSummary(
          username: 'jon', roleName: 'Engineering', hasPassword: true));
      expect(json['hasPassword'], isTrue);
      expect(json.values.whereType<String>(), everyElement(isNot(contains(r'$'))),
          reason: 'nothing hash-shaped is on this wire');
    });

    test('toString names the account and its dates and nothing else', () {
      final text = UserSummary(
              username: 'jon',
              roleName: 'Engineering',
              createdAt: DateTime.utc(2026, 1, 1))
          .toString();
      expect(text, contains('jon'));
      expect(text, contains('Engineering'));
      expect(text, contains('2026-01-01'));
    });
  });
}

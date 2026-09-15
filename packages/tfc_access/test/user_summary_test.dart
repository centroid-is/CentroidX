/// The roster row, and the two defaults that have to lean the safe way.
///
/// `UserSummary` is declared here rather than in the protocol package because
/// it is access vocabulary, not wire vocabulary: `AccessAdminStore.listUsers`
/// answers it in direct mode, where there is no wire at all. Its JSON codecs
/// stay in `tfc_relay_protocol`, which is where encoding belongs.
///
/// These arms are about what an *absent* value means. Both fields have a
/// default, both defaults are reachable from a backend older than the field,
/// and in both cases one direction under-claims and the other over-claims.
library;

import 'package:tfc_access/tfc_access.dart';
import 'package:test/test.dart';

void main() {
  group('UserSummary defaults', () {
    test('hasPassword defaults to true — the under-claiming direction', () {
      const user = UserSummary(username: 'jon', roleName: 'Engineering');

      expect(user.hasPassword, isTrue,
          reason: 'a backend older than this field sends nothing, and before '
              'passwordless accounts existed every account had one. Assuming '
              '"protected" is the safe way to be wrong: the roster omits a '
              'marker it should have drawn. Flipping the default tells '
              'somebody an account is open when it is not, which is the one '
              'wrong answer this screen must never give.');
    });

    test('stationAccount defaults to false — every account is a person '
        'until somebody says otherwise', () {
      const user = UserSummary(username: 'jon', roleName: 'Engineering');

      expect(user.stationAccount, isFalse,
          reason: 'a station account never has its session expire. Defaulting '
              'to true would silently hand a never-expiring session to an '
              'account nobody marked as a panel, including one carried over '
              'from a schema that had no such column.');
    });

    test('both timestamps default to null, and they mean different things',
        () {
      const user = UserSummary(username: 'jon', roleName: 'Engineering');

      expect(user.lastLoginAt, isNull,
          reason: 'null lastLoginAt is a fact about the account: it has never '
              'signed in, and the screen says "never".');
      expect(user.createdAt, isNull,
          reason: 'null createdAt is a fact about the wire: this server did '
              'not say. Every app_user row has one, so the screen says '
              '"unknown" rather than inventing a date — the epoch-zero it '
              'used to draw was exactly that invention.');
    });

    test('carries no credential field, and there is nowhere to put one', () {
      // Not a style assertion. `listUsers` answers this type rather than
      // `app_user`'s drift row precisely so that a hash cannot reach a caller
      // by somebody forgetting to strip it. `hasPassword` is one bit that says
      // there is nothing to steal, not what the thing to steal is.
      const user = UserSummary(username: 'jon', roleName: 'Engineering');

      expect(user.toString(), isNot(contains('hash')));
      expect(user.toString(), isNot(contains('salt')));
    });
  });
}

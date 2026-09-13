import 'package:tfc_access/tfc_access.dart';
import 'package:test/test.dart';

void main() {
  group('the reserved username', () {
    test('is the name the audit trail already writes for a logged-out panel',
        () {
      // lib/core/access_admin_store.dart and lib/providers/access.dart write
      // `who: 'anonymous'` for a session with no user. The account is named
      // the same so a trail row and the account it names agree.
      expect(kAnonymousUsername, 'anonymous');
    });

    test('matches case-insensitively and ignoring surrounding whitespace', () {
      expect(isAnonymousUsername('anonymous'), isTrue);
      expect(isAnonymousUsername('Anonymous'), isTrue);
      expect(isAnonymousUsername('  ANONYMOUS '), isTrue);
    });

    test('does not match a name that merely contains it', () {
      expect(isAnonymousUsername('anonymous2'), isFalse);
      expect(isAnonymousUsername('not anonymous'), isFalse);
      expect(isAnonymousUsername('operator'), isFalse);
    });
  });

  group('the password sentinel', () {
    test('cannot be decoded, so no build can verify a login against it', () {
      expect(
        PasswordHash.tryDecode(
          kAnonymousPasswordSentinel,
          saltB64: kAnonymousSaltSentinel,
        ),
        isNull,
      );
    });
  });

  group('the errors', () {
    test('AnonymousAccountError is an Error and says what was refused', () {
      final error = AnonymousAccountError('delete');
      expect(error, isA<Error>());
      expect(error.toString(), contains('delete'));
      expect(error.toString(), contains(kAnonymousUsername));
    });

    test('ReservedUsernameException is an Exception naming the refused name',
        () {
      const e = ReservedUsernameException('Anonymous');
      expect(e, isA<Exception>());
      expect(e.toString(), contains('Anonymous'));
    });
  });

  group('AnonymousAccount composition', () {
    const operator = AccessRole(
      name: 'Operator',
      groups: {AccessGroup.operate},
      allowedPages: {'/'},
    );
    const viewer = AccessRole(
      name: 'Viewer',
      groups: {AccessGroup.setpoints},
      allowedPages: {'/trends'},
    );
    const open = AccessRole(name: 'Open', groups: {});

    test('one role is exactly that role', () {
      final a = AnonymousAccount(roles: const [operator]);
      expect(a.groups, {AccessGroup.operate});
      expect(a.allowedPages, {'/'});
      expect(a.roleNames, ['Operator']);
    });

    test('several roles union their groups and pages, primary first', () {
      final a = AnonymousAccount(roles: const [operator, viewer]);
      expect(a.groups, {AccessGroup.operate, AccessGroup.setpoints});
      expect(a.allowedPages, {'/', '/trends'});
      expect(a.roleNames, ['Operator', 'Viewer']);
    });

    test('a role with no whitelist makes every page visible', () {
      final a = AnonymousAccount(roles: const [operator, open]);
      expect(a.allowedPages, isNull);
    });

    test('a personal whitelist replaces the roles\' whitelist', () {
      final narrower =
          AnonymousAccount(roles: const [operator, open], pagesOverride: {});
      expect(narrower.allowedPages, isEmpty);
      final wider = AnonymousAccount(
        roles: const [operator],
        pagesOverride: {'/', '/packing'},
      );
      expect(wider.allowedPages, {'/', '/packing'});
    });

    test('an AccessSession built from it answers with its roles', () {
      final a = AnonymousAccount(roles: const [operator, viewer]);
      final s = AccessSession.anonymous(
        a.groups,
        allowedPages: a.allowedPages,
        roleNames: a.roleNames,
      );
      expect(s.isElevated, isFalse);
      expect(s.roleName, 'Operator');
      expect(s.roleNames, ['Operator', 'Viewer']);
      expect(s.roleLabel, 'Operator + Viewer');
      expect(s.can(AccessGroup.setpoints), isTrue);
      expect(s.pageVisible('/trends'), isTrue);
      expect(s.pageVisible('/packing'), isFalse);
    });
  });
}

import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';

void main() {
  group('encodeAllowedPagesColumn', () {
    test('a null set is a null column, not a sentinel string', () {
      expect(encodeAllowedPagesColumn(null), isNull);
    });

    test('an empty set encodes as an empty array, which is not null', () {
      // The whole point of the feature: "block all" must be storable and must
      // not read back as "no whitelist".
      expect(encodeAllowedPagesColumn(<String>{}), '[]');
    });

    test('paths are sorted, so a save that changes nothing looks unchanged',
        () {
      expect(
        encodeAllowedPagesColumn({'/packing', '/', '/fillet'}),
        encodeAllowedPagesColumn({'/fillet', '/packing', '/'}),
      );
      expect(encodeAllowedPagesColumn({'/packing', '/', '/fillet'}),
          '["/","/fillet","/packing"]');
    });
  });

  group('decodeAllowedPagesColumn fails closed', () {
    test('only a null column answers null', () {
      expect(decodeAllowedPagesColumn(null), isNull);
    });

    test('an empty array answers the empty set — block all, not unrestricted',
        () {
      expect(decodeAllowedPagesColumn('[]'), isEmpty);
      expect(decodeAllowedPagesColumn('[]'), isNotNull);
    });

    test('garbage denies rather than allowing', () {
      // The deliberate opposite of decodeGroups being forgiving: an unreadable
      // page column that failed open would show the pages it exists to hide.
      for (final bad in ['not json', '{"a":1}', '42', '"/a"', '']) {
        expect(decodeAllowedPagesColumn(bad), isEmpty, reason: bad);
        expect(decodeAllowedPagesColumn(bad), isNotNull, reason: bad);
      }
    });

    test('non-string entries are dropped, which narrows', () {
      expect(decodeAllowedPagesColumn('["/a",7,null,"/b"]'), {'/a', '/b'});
    });

    test('round-trips', () {
      final pages = {'/', '/fillet', '/packing'};
      expect(decodeAllowedPagesColumn(encodeAllowedPagesColumn(pages)), pages);
      expect(decodeAllowedPagesColumn(encodeAllowedPagesColumn(<String>{})),
          isEmpty);
      expect(decodeAllowedPagesColumn(encodeAllowedPagesColumn(null)), isNull);
    });
  });

  group('effectiveAllowedPages — the user replaces the role', () {
    // The truth table from the design note §1c, all six rows.
    test('neither level has an opinion: unrestricted', () {
      expect(effectiveAllowedPages(user: null, role: null), isNull);
    });

    test('user null inherits the role, including an empty role whitelist', () {
      expect(effectiveAllowedPages(user: null, role: {'/a'}), {'/a'});
      expect(effectiveAllowedPages(user: null, role: <String>{}), isEmpty);
    });

    test('a personal whitelist applies with no role whitelist', () {
      expect(effectiveAllowedPages(user: {'/b'}, role: null), {'/b'});
    });

    test('a personal whitelist REPLACES the role, never merges with it', () {
      // Union would make the role level unable to bind; intersection could not
      // express granting one account one extra page.
      expect(effectiveAllowedPages(user: {'/b'}, role: {'/a'}), {'/b'});
    });

    test('an empty personal whitelist denies everything the role allows', () {
      expect(effectiveAllowedPages(user: <String>{}, role: {'/a'}), isEmpty);
    });
  });

  group('AccessRole carries a whitelist', () {
    test('defaults to null — every page, as before the column existed', () {
      const role = AccessRole(name: 'R', groups: {AccessGroup.operate});
      expect(role.allowedPages, isNull);
      expect(role.encodeAllowedPages(), isNull);
    });

    test('fromDb decodes the column, and a null column stays null', () {
      final open = AccessRole.fromDb(
          name: 'R', groupsJson: '["operate"]', seeded: false);
      expect(open.allowedPages, isNull);

      final limited = AccessRole.fromDb(
        name: 'R',
        groupsJson: '["operate"]',
        seeded: false,
        allowedPagesJson: '["/a","/b"]',
      );
      expect(limited.allowedPages, {'/a', '/b'});

      final blocked = AccessRole.fromDb(
        name: 'R',
        groupsJson: '["operate"]',
        seeded: false,
        allowedPagesJson: '[]',
      );
      expect(blocked.allowedPages, isEmpty);
    });

    test('null and the empty set are different roles', () {
      const open = AccessRole(name: 'R', groups: {AccessGroup.operate});
      const blocked = AccessRole(
          name: 'R', groups: {AccessGroup.operate}, allowedPages: {});
      expect(open, isNot(blocked));
      expect(open.hashCode, isNot(blocked.hashCode));
    });

    test('equality tracks the page set', () {
      const a = AccessRole(
          name: 'R', groups: {AccessGroup.operate}, allowedPages: {'/a'});
      const b = AccessRole(
          name: 'R', groups: {AccessGroup.operate}, allowedPages: {'/a'});
      const c = AccessRole(
          name: 'R', groups: {AccessGroup.operate}, allowedPages: {'/b'});
      expect(a, b);
      expect(a, isNot(c));
    });

    test('the seeded roles carry no whitelist', () {
      // Seeding one would be inventing plant knowledge the code does not have.
      for (final role in kSeedRoles) {
        expect(role.allowedPages, isNull, reason: role.name);
      }
    });
  });

  group('AccessSession.pageVisible', () {
    AccessSession sessionWith(Set<String>? pages) => AccessSession(
          groups: const {AccessGroup.operate},
          allowedPages: pages,
        );

    test('no whitelist admits every page', () {
      expect(sessionWith(null).pageVisible('/anything'), isTrue);
    });

    test('an empty whitelist admits nothing', () {
      expect(sessionWith(<String>{}).pageVisible('/'), isFalse);
    });

    test('admits exactly what is listed', () {
      final s = sessionWith({'/fillet'});
      expect(s.pageVisible('/fillet'), isTrue);
      expect(s.pageVisible('/packing'), isFalse);
    });

    test('matches exactly — no prefix matching, no normalisation', () {
      final s = sessionWith({'/fillet'});
      expect(s.pageVisible('/fillet/sub'), isFalse);
      expect(s.pageVisible('/fillet/'), isFalse);
      expect(s.pageVisible('fillet'), isFalse);
    });

    test('anonymous carries the Operator row whitelist', () {
      final s = AccessSession.anonymous(
        const {AccessGroup.operate},
        operatorAllowedPages: const {'/'},
      );
      expect(s.pageVisible('/'), isTrue);
      expect(s.pageVisible('/packing'), isFalse);
    });

    test('anonymous without the argument is unrestricted, as before', () {
      final s = AccessSession.anonymous(const {AccessGroup.operate});
      expect(s.allowedPages, isNull);
      expect(s.pageVisible('/anything'), isTrue);
    });
  });

  group('AccessSession does not persist its whitelist', () {
    test('toJson carries no page list', () {
      final s = AccessSession(
        user: const AuthenticatedUser(
          username: 'jon',
          roleName: 'Engineering',
          displayName: 'Jon',
        ),
        groups: const {AccessGroup.operate},
        allowedPages: const {'/fillet'},
        expiresAt: DateTime.utc(2026, 1, 1),
      );
      final json = s.toJson();
      expect(json.keys, isNot(contains('allowedPages')));
      expect(json.values.join(), isNot(contains('/fillet')));
    });

    test('a hand-written payload cannot carry one', () {
      // The preferences file is a plain file on a panel anybody can walk up to.
      final parsed = AccessSession.parse(
        '{"username":"jon","roleName":"Operator","displayName":"Jon",'
        '"expiresAt":"2099-01-01T00:00:00.000Z",'
        '"allowedPages":["/everything"]}',
      );
      expect(parsed, isNotNull);
      // PersistedSession has no such field to carry it into a live session.
      expect(parsed!.roleName, 'Operator');
    });
  });

  group('audit rows for the two new writes', () {
    test('role.pages records null as a value, not as a missing one', () {
      final row = AuditRecord.rolePages(
        who: 'jon',
        station: 'ST01',
        roleName: 'Engineering',
        actionId: 'a1',
        subject: 'Operator',
        oldPages: null,
        newPages: '["/"]',
        allowed: true,
      );
      expect(row.itemKey, 'role.pages');
      expect(row.member, 'Operator');
      expect(row.oldValue, isNull);
      expect(row.newValue, '["/"]');
      expect(row.groupRequired, AccessGroup.users.name);
      expect(row.allowed, isTrue);
    });

    test('user.pages carries the account in member, not in the itemKey', () {
      final row = AuditRecord.userPages(
        who: 'jon',
        station: 'ST01',
        roleName: 'Engineering',
        actionId: 'a2',
        subject: 'trainee',
        oldPages: '["/"]',
        newPages: null,
        allowed: false,
        reason: 'denied',
      );
      expect(row.itemKey, 'user.pages');
      expect(row.member, 'trainee');
      expect(row.allowed, isFalse);
      expect(row.reason, 'denied');
    });
  });
}

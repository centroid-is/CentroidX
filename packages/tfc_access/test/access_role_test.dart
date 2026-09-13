import 'dart:convert';

import 'package:tfc_access/tfc_access.dart';
import 'package:test/test.dart';

AccessRole _seed(String name) => kSeedRoles.firstWhere((r) => r.name == name,
    orElse: () => fail('no seed role named "$name"'));

void main() {
  group('kSeedRoles', () {
    test('has exactly four roles', () {
      expect(kSeedRoles, hasLength(4));
    });

    test('is named Operator, Shift Leader, Maintenance, Engineering', () {
      expect(kSeedRoles.map((r) => r.name),
          ['Operator', 'Shift Leader', 'Maintenance', 'Engineering']);
    });

    test('Operator can only operate', () {
      // Anonymous resolves to this role, so its group set is what an entirely
      // unauthenticated panel on the floor may do.
      expect(_seed('Operator').groups, {AccessGroup.operate});
    });

    test('Shift Leader adds setpoints', () {
      expect(_seed('Shift Leader').groups,
          {AccessGroup.operate, AccessGroup.setpoints});
    });

    test('Maintenance has operate, setpoints, device and force', () {
      // setpoints is present on purpose (decided 2026-08-28): somebody who has
      // just swapped a motor needs to set it running properly, and sending them
      // to find a shift leader to type a number is how workarounds get
      // invented. Do not "fix" this by removing it.
      expect(_seed('Maintenance').groups, {
        AccessGroup.operate,
        AccessGroup.setpoints,
        AccessGroup.device,
        AccessGroup.force,
      });
    });

    test('Engineering has all seven groups', () {
      expect(_seed('Engineering').groups, AccessGroup.values.toSet());
    });

    test('every seed role is marked seeded', () {
      expect(kSeedRoles.every((r) => r.seeded), isTrue);
    });
  });

  group('AccessRole', () {
    test('can() reports membership', () {
      final role = _seed('Shift Leader');
      expect(role.can(AccessGroup.setpoints), isTrue);
      expect(role.can(AccessGroup.force), isFalse);
    });

    test('encodeGroups produces a JSON array of enum names', () {
      final role = _seed('Shift Leader');
      expect(jsonDecode(role.encodeGroups()), ['operate', 'setpoints']);
    });

    test('encodeGroups emits groups in enum order regardless of insert order',
        () {
      // Stable output keeps the stored TEXT column diffable and stops a
      // no-op role save from looking like a change.
      const role = AccessRole(
        name: 'Scrambled',
        groups: {AccessGroup.users, AccessGroup.operate, AccessGroup.device},
      );
      expect(jsonDecode(role.encodeGroups()), ['operate', 'device', 'users']);
    });

    test('decodeGroups round-trips encodeGroups', () {
      for (final role in kSeedRoles) {
        expect(AccessRole.decodeGroups(role.encodeGroups()), role.groups,
            reason: 'round trip failed for ${role.name}');
      }
    });

    test('decodeGroups drops names this build does not know', () {
      // A newer station writing an eighth group must not brick an older one:
      // the unknown name is ignored, not thrown on.
      expect(AccessRole.decodeGroups('["operate","not_a_group"]'),
          {AccessGroup.operate});
    });

    test('decodeGroups yields an empty set for empty and null input', () {
      expect(AccessRole.decodeGroups(''), isEmpty);
      expect(AccessRole.decodeGroups('null'), isEmpty);
    });

    test('decodeGroups yields an empty set for malformed JSON', () {
      // Same reasoning as the unknown-name case, one step further: a corrupt
      // column costs the role its groups, never the app its startup.
      expect(AccessRole.decodeGroups('{not json'), isEmpty);
      expect(AccessRole.decodeGroups('{"groups":["operate"]}'), isEmpty);
    });

    test('decodeGroups ignores non-string array entries', () {
      expect(
          AccessRole.decodeGroups('["operate",7,null]'), {AccessGroup.operate});
    });

    test('fromDb rebuilds a role from its stored columns', () {
      final role = AccessRole.fromDb(
        name: 'Shift Leader',
        groupsJson: '["operate","setpoints"]',
        seeded: true,
      );
      expect(role, _seed('Shift Leader'));
    });

    test('value equality covers name, groups and seeded', () {
      const a = AccessRole(name: 'X', groups: {AccessGroup.operate});
      const b = AccessRole(name: 'X', groups: {AccessGroup.operate});
      const differentGroups =
          AccessRole(name: 'X', groups: {AccessGroup.setpoints});
      const differentSeeded =
          AccessRole(name: 'X', groups: {AccessGroup.operate}, seeded: true);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(differentGroups));
      expect(a, isNot(differentSeeded));
    });

    test('groups compare by contents, not by set identity', () {
      final a = AccessRole(
          name: 'X', groups: {AccessGroup.operate, AccessGroup.users});
      final b = AccessRole(
          name: 'X', groups: {AccessGroup.users, AccessGroup.operate});
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });

  // AuthenticatedUser lives here rather than in its own suite because it is the
  // other half of the same vocabulary: a user is a name plus exactly one role
  // name, and the role name is the only link between the two types.
  group('AuthenticatedUser', () {
    test('displayName falls back to the username', () {
      const user = AuthenticatedUser(username: 'jon', roleName: 'Engineering');
      expect(user.displayName, 'jon');
    });

    test('displayName is used when supplied', () {
      const user = AuthenticatedUser(
        username: 'jon',
        roleName: 'Engineering',
        displayName: 'Jón Bjarni',
      );
      expect(user.displayName, 'Jón Bjarni');
    });

    test('an empty displayName falls back to the username', () {
      const user = AuthenticatedUser(
        username: 'jon',
        roleName: 'Engineering',
        displayName: '',
      );
      expect(user.displayName, 'jon');
    });

    test('has value equality', () {
      const a = AuthenticatedUser(username: 'jon', roleName: 'Engineering');
      const b = AuthenticatedUser(username: 'jon', roleName: 'Engineering');
      const c = AuthenticatedUser(username: 'jon', roleName: 'Operator');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });
}

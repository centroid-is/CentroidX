// The composition rules for an account that holds more than one role.
//
// Everything here is pure: no database, no session, no widget. The rules
// themselves are three lines of code each, and what makes them worth a suite of
// their own is that each is the *rejected* reading of something in
// `allowed_pages.dart` — the union that file rules out for the user-versus-role
// composition is exactly the union this one requires for role-versus-role, and
// a reader who conflates the two will "fix" one of them.

import 'package:tfc_access/tfc_access.dart';
import 'package:test/test.dart';

/// A role granting [groups] and admitting [pages].
AccessRole role(
  String name, {
  Set<AccessGroup> groups = const {},
  Set<String>? pages,
}) =>
    AccessRole(name: name, groups: groups, allowedPages: pages);

void main() {
  group('the additional_roles column', () {
    test('an empty list stores as NULL, not as an empty array', () {
      // The upgrade rule: every v8 account lands on NULL and must keep
      // meaning "holds only its primary role". If the empty list wrote '[]'
      // then saving an account with no extras would rewrite a column that had
      // never been touched.
      expect(encodeAdditionalRoles(const []), isNull);
    });

    test('round-trips the names in the order they were given', () {
      final stored = encodeAdditionalRoles(['Maintenance', 'Shift Leader']);
      expect(decodeAdditionalRoles(stored), ['Maintenance', 'Shift Leader']);
    });

    test('is not sorted — the order is what the screen was told', () {
      // Deliberately the opposite of `encodeAllowedPagesColumn`, which sorts
      // for a stable audit diff. Here the first entry is the primary role and
      // sorting would silently reassign it.
      expect(encodeAdditionalRoles(['Zulu', 'Alpha']), '["Zulu","Alpha"]');
    });

    test('a NULL column reads as no extra roles', () {
      expect(decodeAdditionalRoles(null), isEmpty);
    });

    test('anything unreadable reads as no extra roles, which narrows', () {
      // The opposite ruling to `decodeAllowedPagesColumn`, and it needs no
      // fail-closed special case: losing an extra role already takes
      // capability away. The account keeps its primary role, which is the
      // column with the foreign key on it.
      for (final mangled in ['', 'not json', '{"a":1}', '17', '[]']) {
        expect(decodeAdditionalRoles(mangled), isEmpty, reason: mangled);
      }
    });

    test('drops entries that are not non-blank strings', () {
      expect(decodeAdditionalRoles('["Maintenance",7,null,"  ","Cleaner"]'),
          ['Maintenance', 'Cleaner']);
    });

    test('trims, because a role name is a primary key', () {
      expect(decodeAdditionalRoles('["  Maintenance  "]'), ['Maintenance']);
    });
  });

  group('normaliseRoleNames', () {
    test('puts the primary first and keeps the rest in order', () {
      expect(
        normaliseRoleNames(primary: 'Operator', additional: ['B', 'A']),
        ['Operator', 'B', 'A'],
      );
    });

    test('never lists the primary twice, wherever it appears', () {
      expect(
        normaliseRoleNames(
            primary: 'Operator', additional: ['Maintenance', 'Operator']),
        ['Operator', 'Maintenance'],
      );
    });

    test('removes duplicates and blanks', () {
      expect(
        normaliseRoleNames(
            primary: 'Operator', additional: ['A', '', '  ', 'A']),
        ['Operator', 'A'],
      );
    });

    test('a primary alone is a one-element list', () {
      expect(normaliseRoleNames(primary: 'Operator'), ['Operator']);
    });

    test('the result is unmodifiable', () {
      final names = normaliseRoleNames(primary: 'Operator');
      expect(() => names.add('Engineering'), throwsUnsupportedError);
    });
  });

  group('unionRoleGroups', () {
    test('holding two roles grants what either grants', () {
      final groups = unionRoleGroups([
        role('Shift Leader',
            groups: {AccessGroup.operate, AccessGroup.setpoints}),
        role('Maintenance', groups: {AccessGroup.device, AccessGroup.force}),
      ]);
      expect(
          groups,
          {
            AccessGroup.operate,
            AccessGroup.setpoints,
            AccessGroup.device,
            AccessGroup.force,
          });
    });

    test('is a union and not an intersection', () {
      // The whole reason a second role is worth having. An intersection would
      // make "also give them Maintenance" take capabilities away, which is
      // what nobody means by it.
      final groups = unionRoleGroups([
        role('A', groups: {AccessGroup.operate}),
        role('B', groups: {AccessGroup.configure}),
      ]);
      expect(groups, contains(AccessGroup.operate));
      expect(groups, contains(AccessGroup.configure));
    });

    test('no roles grant nothing', () {
      expect(unionRoleGroups(const []), isEmpty);
    });
  });

  group('unionRoleAllowedPages', () {
    test('two whitelists union', () {
      expect(
        unionRoleAllowedPages([
          role('A', pages: {'/a'}),
          role('B', pages: {'/b'}),
        ]),
        {'/a', '/b'},
      );
    });

    test('a role with no whitelist wins the union outright', () {
      // Null is "sees every page", so a set containing one sees every page.
      // The alternative lets a narrow role bind a role that was never
      // restricted, which makes adding a role *remove* pages.
      expect(
        unionRoleAllowedPages([
          role('A', pages: {'/a'}),
          role('Unrestricted'),
        ]),
        isNull,
      );
    });

    test('order does not matter to that', () {
      expect(
        unionRoleAllowedPages([
          role('Unrestricted'),
          role('A', pages: {'/a'}),
        ]),
        isNull,
      );
    });

    test('an empty whitelist is a real claim and unions as nothing', () {
      // Block-all stays expressible: two roles that each name no page admit
      // no page, rather than collapsing to "unrestricted".
      expect(
        unionRoleAllowedPages([
          role('A', pages: const {}),
          role('B', pages: const {}),
        ]),
        isEmpty,
      );
    });

    test('no roles admit every page', () {
      expect(unionRoleAllowedPages(const []), isNull);
    });

    test('the personal override still replaces the whole role level', () {
      // `effectiveAllowedPages` is untouched by any of this: one account has
      // one personal opinion, however many roles it is overriding.
      final roleLevel = unionRoleAllowedPages([
        role('A', pages: {'/a'}),
        role('B', pages: {'/b'}),
      ]);
      expect(
        effectiveAllowedPages(user: {'/only'}, role: roleLevel),
        {'/only'},
      );
      expect(effectiveAllowedPages(user: null, role: roleLevel), {'/a', '/b'});
    });
  });

  group('roleLabelFor', () {
    test('one role reads exactly as it always did', () {
      // The compatibility claim behind every unchanged golden and trail row on
      // a station that never adds a second role.
      expect(roleLabelFor(['Engineering']), 'Engineering');
    });

    test('several join with a plus, in the list order', () {
      expect(roleLabelFor(['Maintenance', 'Engineering']),
          'Maintenance + Engineering');
    });

    test('no roles read as nothing rather than as a stray separator', () {
      expect(roleLabelFor(const []), '');
    });
  });
}

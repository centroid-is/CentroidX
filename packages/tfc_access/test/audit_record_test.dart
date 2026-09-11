import 'dart:io';

import 'package:clock/clock.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:test/test.dart';

/// A password-shaped string. If this ever appears in an audit row, the trail
/// has become the thing it was meant to protect against.
const _password = 'hunter2-correct-horse-battery-staple';

/// The encoded group set of a role that can operate, as `AppRole.groups` holds
/// it. Built through [AccessRole.encodeGroups] rather than hand-written, so the
/// admin rows carry the one encoding this codebase uses.
final String _maintenanceGroups = const AccessRole(
  name: 'Maintenance',
  groups: {AccessGroup.operate},
).encodeGroups();

/// The same role after somebody ticked `force` — the edit the admin surface
/// exists to make legible as `["operate"] -> ["operate","force"]`.
final String _maintenanceGroupsWithForce = const AccessRole(
  name: 'Maintenance',
  groups: {AccessGroup.operate, AccessGroup.force},
).encodeGroups();

/// The eight admin factory names, in itemKey order.
const _adminFactoryNames = <String>[
  'roleCreate',
  'roleUpdate',
  'roleDelete',
  'roleRename',
  'userCreate',
  'userDelete',
  'userRole',
  'userPassword',
];

/// One row from each of the eight admin constructors, in itemKey order.
///
/// Built as a list rather than asserted one constructor at a time so that a
/// ninth admin constructor added without a row here is visible as a length
/// mismatch, not as a silently unasserted vocabulary entry.
List<AuditRecord> _adminRows({required bool allowed}) => [
      AuditRecord.roleCreate(
        who: 'jon',
        station: 'st101',
        roleName: 'Engineering',
        actionId: 'a' * 32,
        subject: 'Maintenance',
        groups: _maintenanceGroups,
        allowed: allowed,
      ),
      AuditRecord.roleUpdate(
        who: 'jon',
        station: 'st101',
        roleName: 'Engineering',
        actionId: 'a' * 32,
        subject: 'Maintenance',
        oldGroups: _maintenanceGroups,
        newGroups: _maintenanceGroupsWithForce,
        allowed: allowed,
      ),
      AuditRecord.roleDelete(
        who: 'jon',
        station: 'st101',
        roleName: 'Engineering',
        actionId: 'a' * 32,
        subject: 'Maintenance',
        groups: _maintenanceGroups,
        allowed: allowed,
      ),
      AuditRecord.roleRename(
        who: 'jon',
        station: 'st101',
        roleName: 'Engineering',
        actionId: 'a' * 32,
        oldName: 'Maintenance',
        newName: 'Servicing',
        allowed: allowed,
      ),
      AuditRecord.userCreate(
        who: 'jon',
        station: 'st101',
        roleName: 'Engineering',
        actionId: 'a' * 32,
        subject: 'gudrun',
        grantedRole: 'Maintenance',
        allowed: allowed,
      ),
      AuditRecord.userDelete(
        who: 'jon',
        station: 'st101',
        roleName: 'Engineering',
        actionId: 'a' * 32,
        subject: 'gudrun',
        heldRole: 'Maintenance',
        allowed: allowed,
      ),
      AuditRecord.userRole(
        who: 'jon',
        station: 'st101',
        roleName: 'Engineering',
        actionId: 'a' * 32,
        subject: 'gudrun',
        oldRole: 'Operator',
        newRole: 'Maintenance',
        allowed: allowed,
      ),
      AuditRecord.userPassword(
        who: 'jon',
        station: 'st101',
        roleName: 'Engineering',
        actionId: 'a' * 32,
        subject: 'gudrun',
        allowed: allowed,
      ),
    ];

/// Walk up to the `tfc_access` package root, so the source-reading test below
/// works whether `dart test` was invoked from the package or from the repo
/// root. A source assertion that silently passes because it could not find the
/// file is worse than no assertion.
Directory _packageRoot() {
  var dir = Directory.current.absolute;
  while (true) {
    final pubspec = File('${dir.path}/pubspec.yaml');
    if (pubspec.existsSync() &&
        pubspec.readAsStringSync().contains('name: tfc_access')) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      fail('could not locate the tfc_access package root from '
          '${Directory.current.path}');
    }
    dir = parent;
  }
}

/// The parameter list of `factory AuditRecord.[name]` — everything after the
/// opening parenthesis, up to the `}) =>` that closes it.
///
/// The parameters only, and deliberately not the factory's own name or its
/// body. `userPassword` has `password` in its name and `user.password` in its
/// body, and both are correct; the thing worth forbidding is a credential
/// arriving as an argument.
String _factorySignature(String source, String name) {
  final declaration = 'factory AuditRecord.$name(';
  final start = source.indexOf(declaration);
  expect(start, isNot(-1), reason: 'AuditRecord.$name should exist');
  final end = source.indexOf('}) =>', start);
  expect(end, isNot(-1), reason: 'AuditRecord.$name should be a factory');
  return source.substring(start + declaration.length, end);
}

void main() {
  group('newActionId', () {
    test('is 32 lowercase hex characters', () {
      expect(newActionId(), matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('two successive calls differ', () {
      expect(newActionId(), isNot(newActionId()));
    });

    test('a hundred calls produce a hundred distinct ids', () {
      // 128 bits from Random.secure(). Collisions here would mean one action's
      // rows could be confused with another's, which is the whole point of
      // having a correlation id.
      final ids = {for (var i = 0; i < 100; i++) newActionId()};
      expect(ids, hasLength(100));
    });
  });

  group('AuditRecord', () {
    test('carries one field per AuditEntry column', () {
      final at = DateTime.utc(2026, 8, 28, 9, 30);
      final record = AuditRecord(
        at: at,
        who: 'jon',
        station: 'svn-nes-ot-cl02',
        roleName: 'Engineering',
        surface: 'tag',
        itemKey: 'CN04.MOT01.p_cfg',
        member: 'Freq',
        oldValue: '50',
        newValue: '35',
        groupRequired: 'device',
        allowed: true,
        origin: 'operator',
        actionId: 'a' * 32,
        reason: 'commissioning',
      );

      expect(record.at, at);
      expect(record.who, 'jon');
      expect(record.station, 'svn-nes-ot-cl02');
      expect(record.roleName, 'Engineering');
      expect(record.surface, 'tag');
      expect(record.itemKey, 'CN04.MOT01.p_cfg');
      expect(record.member, 'Freq');
      expect(record.oldValue, '50');
      expect(record.newValue, '35');
      expect(record.groupRequired, 'device');
      expect(record.allowed, isTrue);
      expect(record.origin, 'operator');
      expect(record.actionId, 'a' * 32);
      expect(record.reason, 'commissioning');
    });

    test('origin defaults to operator', () {
      // Hand-made by default on purpose: an unmarked future machine caller
      // lands in the trail loudly rather than escaping it silently.
      final record = AuditRecord(
        at: DateTime.utc(2026),
        who: 'jon',
        station: 'st101',
        roleName: 'Engineering',
        surface: 'pref',
        itemKey: 'some.pref',
        groupRequired: 'configure',
        allowed: true,
        actionId: newActionId(),
      );
      expect(record.origin, 'operator');
    });

    test('nullable columns default to null', () {
      final record = AuditRecord(
        at: DateTime.utc(2026),
        who: 'jon',
        station: 'st101',
        roleName: 'Engineering',
        surface: 'route',
        itemKey: '/server-config',
        groupRequired: 'administer',
        allowed: false,
        actionId: newActionId(),
      );
      expect(record.member, isNull);
      expect(record.oldValue, isNull);
      expect(record.newValue, isNull);
      expect(record.reason, isNull);
    });

    test('has value equality', () {
      final at = DateTime.utc(2026);
      final a = AuditRecord(
        at: at,
        who: 'jon',
        station: 'st101',
        roleName: 'Engineering',
        surface: 'tag',
        itemKey: 'k',
        groupRequired: 'device',
        allowed: true,
        actionId: 'b' * 32,
      );
      final b = AuditRecord(
        at: at,
        who: 'jon',
        station: 'st101',
        roleName: 'Engineering',
        surface: 'tag',
        itemKey: 'k',
        groupRequired: 'device',
        allowed: true,
        actionId: 'b' * 32,
      );
      final c = AuditRecord(
        at: at,
        who: 'jon',
        station: 'st101',
        roleName: 'Engineering',
        surface: 'tag',
        itemKey: 'k',
        groupRequired: 'device',
        allowed: false,
        actionId: 'b' * 32,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('AuditRecord.login', () {
    AuditRecord build() => AuditRecord.login(
          who: 'jon',
          station: 'st101',
          roleName: 'Engineering',
          actionId: 'c' * 32,
        );

    test('fixes the auth vocabulary', () {
      final record = build();
      expect(record.surface, 'auth');
      expect(record.itemKey, 'login');
      expect(record.allowed, isTrue);
    });

    test('records the resolved role in newValue', () {
      final record = build();
      expect(record.roleName, 'Engineering');
      expect(record.newValue, 'Engineering');
    });

    test('groupRequired is empty — an auth event is not gated on a group', () {
      expect(build().groupRequired, isEmpty);
    });

    test('at defaults to the current clock', () {
      final fixed = DateTime.utc(2026, 8, 28, 12);
      final record = withClock(
        Clock.fixed(fixed),
        () => AuditRecord.login(
          who: 'jon',
          station: 'st101',
          roleName: 'Engineering',
          actionId: 'c' * 32,
        ),
      );
      expect(record.at, fixed);
    });
  });

  group('AuditRecord.loginFailed', () {
    AuditRecord build({String who = 'jon'}) => AuditRecord.loginFailed(
          who: who,
          station: 'st101',
          actionId: 'd' * 32,
        );

    test('fixes the auth vocabulary and records the denial', () {
      final record = build();
      expect(record.surface, 'auth');
      expect(record.itemKey, 'login.failed');
      expect(record.allowed, isFalse);
    });

    test('who is the attempted username', () {
      expect(build(who: 'not-a-user').who, 'not-a-user');
    });

    test('who is truncated to 64 characters', () {
      // The username field on a login form accepts a paste. A megabyte of it
      // must not become an audit row.
      final record = build(who: 'x' * 5000);
      expect(record.who, hasLength(64));
      expect(record.who, 'x' * 64);
    });

    test('a who of exactly 64 characters is left alone', () {
      expect(build(who: 'y' * 64).who, 'y' * 64);
    });

    test('the role is anonymous — nobody was signed in', () {
      expect(build().roleName, kOperatorRoleName);
    });

    test('groupRequired is empty', () {
      expect(build().groupRequired, isEmpty);
    });
  });

  group('AuditRecord.logout', () {
    AuditRecord build() => AuditRecord.logout(
          who: 'jon',
          station: 'st101',
          roleName: 'Engineering',
          actionId: 'e' * 32,
        );

    test('fixes the auth vocabulary', () {
      final record = build();
      expect(record.surface, 'auth');
      expect(record.itemKey, 'logout');
      expect(record.allowed, isTrue);
    });

    test('oldValue is the role being left', () {
      expect(build().oldValue, 'Engineering');
    });

    test('groupRequired is empty', () {
      expect(build().groupRequired, isEmpty);
    });
  });

  group('AuditRecord.sessionTimeout', () {
    AuditRecord build({String? reason}) => AuditRecord.sessionTimeout(
          who: 'jon',
          station: 'st101',
          roleName: 'Engineering',
          actionId: 'f' * 32,
          reason: reason,
        );

    test('fixes the auth vocabulary', () {
      final record = build();
      expect(record.surface, 'auth');
      expect(record.itemKey, 'session.timeout');
      expect(record.allowed, isTrue);
    });

    test('accepts a reason', () {
      expect(build(reason: '15 minutes idle').reason, '15 minutes idle');
    });

    test('oldValue is the role being left', () {
      expect(build().oldValue, 'Engineering');
    });

    test('groupRequired is empty', () {
      expect(build().groupRequired, isEmpty);
    });
  });

  group('AuditRecord.sessionResume', () {
    AuditRecord build({String roleName = kOperatorRoleName}) =>
        AuditRecord.sessionResume(
          who: 'freezer',
          station: 'st101',
          roleName: roleName,
          actionId: 'e' * 32,
        );

    test('fixes the auth vocabulary', () {
      final record = build();
      expect(record.surface, 'auth');
      expect(record.itemKey, 'session.resume');
      expect(record.allowed, isTrue);
    });

    test('newValue is the role resumed into', () {
      expect(build().newValue, kOperatorRoleName);
      expect(build(roleName: 'Shift Leader').newValue, 'Shift Leader');
    });

    test('groupRequired is empty', () {
      expect(build().groupRequired, isEmpty);
    });

    test('is not a login', () {
      // The distinction the trail is for: a `login` row means a credential was
      // accepted at that instant. A resume means a panel came back to an
      // identity it already held, with nobody at it. Collapsing the two would
      // make "was a person here?" unanswerable a month later.
      expect(build().itemKey, isNot('login'));
      expect(
        AuditRecord.login(
          who: 'freezer',
          station: 'st101',
          roleName: kOperatorRoleName,
          actionId: 'e' * 32,
        ).itemKey,
        isNot(build().itemKey),
      );
    });
  });

  group('no auth record can carry a password', () {
    // The structural half of this assertion is the constructor signatures: none
    // of the five auth factories takes a password, so a call passing one would
    // not compile and this file would not run at all. The tests below cover the
    // other half — that a password handed to the *login flow* has no field on
    // the record it could land in, and that toString() does not leak the value
    // columns for an auth row even if something later puts one there.

    test('a failed login built from a bad password mentions it nowhere', () {
      final record = AuditRecord.loginFailed(
        who: 'jon',
        station: 'st101',
        actionId: newActionId(),
      );
      expect(record.toString(), isNot(contains(_password)));
      expect(record.oldValue, isNull);
      expect(record.newValue, isNull);
      expect(record.member, isNull);
      expect(record.reason, isNull);
    });

    test('toString withholds the value columns for surface auth', () {
      final record = AuditRecord(
        at: DateTime.utc(2026),
        who: 'jon',
        station: 'st101',
        roleName: 'Engineering',
        surface: 'auth',
        itemKey: 'login',
        oldValue: _password,
        newValue: _password,
        groupRequired: '',
        allowed: true,
        actionId: newActionId(),
      );
      expect(record.toString(), isNot(contains(_password)));
      expect(record.toString(), contains('auth'));
      expect(record.toString(), contains('login'));
    });

    test('toString still shows the value columns for a tag write', () {
      // Withholding is scoped to auth rows. A tag write's old and new values
      // are the point of the trail.
      final record = AuditRecord(
        at: DateTime.utc(2026),
        who: 'jon',
        station: 'st101',
        roleName: 'Engineering',
        surface: 'tag',
        itemKey: 'CN04.MOT01.p_cfg',
        member: 'Freq',
        oldValue: '50',
        newValue: '35',
        groupRequired: 'device',
        allowed: true,
        actionId: newActionId(),
      );
      expect(record.toString(), contains('50'));
      expect(record.toString(), contains('35'));
    });
  });

  group('AuditRecord.roleCreate', () {
    AuditRecord build({bool allowed = true}) => AuditRecord.roleCreate(
          who: 'jon',
          station: 'st101',
          roleName: 'Engineering',
          actionId: 'a' * 32,
          subject: 'Maintenance',
          groups: _maintenanceGroups,
          allowed: allowed,
        );

    test('fixes the admin vocabulary', () {
      final record = build();
      expect(record.surface, 'admin');
      expect(record.itemKey, 'role.create');
    });

    test('the role created is the member, not part of the itemKey', () {
      // The itemKey vocabulary is a closed set of eight strings that Phase 5
      // filters on. Folding the subject into it (`role.create.Maintenance`)
      // would make it unbounded, and an unbounded itemKey is an unfilterable
      // one.
      final record = build();
      expect(record.member, 'Maintenance');
      expect(record.itemKey, isNot(contains('Maintenance')));
    });

    test('newValue is the encoded group set of the new role', () {
      expect(build().newValue, _maintenanceGroups);
      expect(build().oldValue, isNull);
    });
  });

  group('AuditRecord.roleUpdate', () {
    AuditRecord build({bool allowed = true}) => AuditRecord.roleUpdate(
          who: 'jon',
          station: 'st101',
          roleName: 'Engineering',
          actionId: 'b' * 32,
          subject: 'Maintenance',
          oldGroups: _maintenanceGroups,
          newGroups: _maintenanceGroupsWithForce,
        allowed: allowed,
        );

    test('fixes the admin vocabulary', () {
      final record = build();
      expect(record.surface, 'admin');
      expect(record.itemKey, 'role.update');
    });

    test('carries both encoded group sets, so the row reads old -> new', () {
      // AccessRole.encodeGroups emits AccessGroup.values order, so
      // ["operate"] -> ["operate","force"] is legible in Phase 5's generic
      // write row with no viewer change.
      final record = build();
      expect(record.oldValue, _maintenanceGroups);
      expect(record.newValue, _maintenanceGroupsWithForce);
    });

    test('the role edited is the member', () {
      expect(build().member, 'Maintenance');
    });
  });

  group('AuditRecord.roleDelete', () {
    AuditRecord build({bool allowed = true}) => AuditRecord.roleDelete(
          who: 'jon',
          station: 'st101',
          roleName: 'Engineering',
          actionId: 'c' * 32,
          subject: 'Maintenance',
          groups: _maintenanceGroups,
          allowed: allowed,
        );

    test('fixes the admin vocabulary', () {
      final record = build();
      expect(record.surface, 'admin');
      expect(record.itemKey, 'role.delete');
    });

    test('oldValue is what the deleted role granted', () {
      final record = build();
      expect(record.oldValue, _maintenanceGroups);
      expect(record.newValue, isNull);
      expect(record.member, 'Maintenance');
    });
  });

  group('AuditRecord.roleRename', () {
    AuditRecord build({bool allowed = true}) => AuditRecord.roleRename(
          who: 'jon',
          station: 'st101',
          roleName: 'Engineering',
          actionId: 'd' * 32,
          oldName: 'Maintenance',
          newName: 'Servicing',
          allowed: allowed,
        );

    test('fixes the admin vocabulary', () {
      final record = build();
      expect(record.surface, 'admin');
      expect(record.itemKey, 'role.rename');
    });

    test('carries both names, and the member is the role as it was named', () {
      final record = build();
      expect(record.oldValue, 'Maintenance');
      expect(record.newValue, 'Servicing');
      expect(record.member, 'Maintenance');
    });
  });

  group('AuditRecord.userCreate', () {
    AuditRecord build({bool allowed = true}) => AuditRecord.userCreate(
          who: 'jon',
          station: 'st101',
          roleName: 'Engineering',
          actionId: 'e' * 32,
          subject: 'gudrun',
          grantedRole: 'Maintenance',
          allowed: allowed,
        );

    test('fixes the admin vocabulary', () {
      final record = build();
      expect(record.surface, 'admin');
      expect(record.itemKey, 'user.create');
    });

    test('newValue is the role granted, and the account is the member', () {
      final record = build();
      expect(record.newValue, 'Maintenance');
      expect(record.member, 'gudrun');
    });

    test('nothing about the password reaches the row', () {
      // The structural half is the signature: userCreate takes no password, so
      // a call passing one would not compile and this file would not run.
      final record = build();
      expect(record.oldValue, isNull);
      expect(record.toString(), isNot(contains(_password)));
    });
  });

  group('AuditRecord.userDelete', () {
    AuditRecord build({bool allowed = true}) => AuditRecord.userDelete(
          who: 'jon',
          station: 'st101',
          roleName: 'Engineering',
          actionId: 'f' * 32,
          subject: 'gudrun',
          heldRole: 'Maintenance',
          allowed: allowed,
        );

    test('fixes the admin vocabulary', () {
      final record = build();
      expect(record.surface, 'admin');
      expect(record.itemKey, 'user.delete');
    });

    test('oldValue is the role the deleted account held', () {
      final record = build();
      expect(record.oldValue, 'Maintenance');
      expect(record.newValue, isNull);
      expect(record.member, 'gudrun');
    });
  });

  group('AuditRecord.userRole', () {
    AuditRecord build({bool allowed = true}) => AuditRecord.userRole(
          who: 'jon',
          station: 'st101',
          roleName: 'Engineering',
          actionId: '1' * 32,
          subject: 'gudrun',
          oldRole: 'Operator',
          newRole: 'Maintenance',
          allowed: allowed,
        );

    test('fixes the admin vocabulary', () {
      final record = build();
      expect(record.surface, 'admin');
      expect(record.itemKey, 'user.role');
    });

    test('reads as a transition on the account named in member', () {
      // itemKey `user.role` plus member `gudrun` is what makes Phase 5's
      // generic row read correctly with no viewer change.
      final record = build();
      expect(record.member, 'gudrun');
      expect(record.oldValue, 'Operator');
      expect(record.newValue, 'Maintenance');
    });
  });

  group('AuditRecord.userPassword', () {
    AuditRecord build({bool allowed = true}) => AuditRecord.userPassword(
          who: 'jon',
          station: 'st101',
          roleName: 'Engineering',
          actionId: '2' * 32,
          subject: 'gudrun',
          allowed: allowed,
        );

    test('fixes the admin vocabulary', () {
      final record = build();
      expect(record.surface, 'admin');
      expect(record.itemKey, 'user.password');
    });

    test('records that the password was set, on the account in member', () {
      expect(build().member, 'gudrun');
    });

    test('oldValue and newValue are both null and not parameterisable', () {
      // toString withholds the value columns only when isAuthEvent — that is,
      // surface == 'auth'. An admin row's values are NOT withheld, which is
      // correct for a group set and is exactly why this constructor leaves
      // both fields null by construction rather than by discipline.
      final record = build();
      expect(record.oldValue, isNull,
          reason: "toString's withholding is keyed on surface == 'auth', so an "
              'admin row prints its values into log files that outlive the '
              'database');
      expect(record.newValue, isNull,
          reason: "toString's withholding is keyed on surface == 'auth', so an "
              'admin row prints its values into log files that outlive the '
              'database');
    });
  });

  group('the admin surface as a whole', () {
    test('the vocabulary is exactly these eight itemKeys', () {
      expect(
        _adminRows(allowed: true).map((r) => r.itemKey).toList(),
        [
          'role.create',
          'role.update',
          'role.delete',
          'role.rename',
          'user.create',
          'user.delete',
          'user.role',
          'user.password',
        ],
      );
    });

    test('every admin row requires the users group', () {
      for (final record in _adminRows(allowed: true)) {
        expect(record.groupRequired, AccessGroup.users.name,
            reason: 'this is what puts admin rows behind Phase 5\'s existing '
                'users chip, with no change to its viewer. An empty '
                'groupRequired would fall outside every group filter');
      }
    });

    test('every admin row carries the admin surface', () {
      for (final record in _adminRows(allowed: true)) {
        expect(record.surface, 'admin');
      }
    });

    test('each constructor can record a refusal as well as a grant', () {
      // allowed is a parameter on all eight, not a hardcoded true. An admin
      // action refused by the users gate is a row worth having, and if the
      // constructors could not build one the store would hand-build denial
      // rows — the vocabulary drifting on day one.
      final denied = _adminRows(allowed: false);
      expect(denied, hasLength(8));
      for (final record in denied) {
        expect(record.allowed, isFalse);
      }
      for (final record in _adminRows(allowed: true)) {
        expect(record.allowed, isTrue);
      }
    });

    test('isAuthEvent is false for every admin row', () {
      for (final record in _adminRows(allowed: true)) {
        expect(record.isAuthEvent, isFalse);
      }
    });

    test('at defaults to the current clock', () {
      final fixed = DateTime.utc(2026, 8, 30, 9);
      final record = withClock(
        Clock.fixed(fixed),
        () => AuditRecord.userPassword(
          who: 'jon',
          station: 'st101',
          roleName: 'Engineering',
          actionId: '3' * 32,
          subject: 'gudrun',
          allowed: true,
        ),
      );
      expect(record.at, fixed);
    });

    test('no admin constructor takes a password, a hash or a salt', () {
      // The structural half is the eight signatures: every call site above
      // compiles, and none of them passes a credential. This is the other
      // half — a source read of the eight parameter lists, so that adding a
      // "just the hash, for debugging" parameter fails here rather than
      // shipping.
      final source = File('${_packageRoot().path}/lib/src/audit.dart')
          .readAsStringSync();
      for (final name in _adminFactoryNames) {
        final signature = _factorySignature(source, name);
        for (final forbidden in ['password', 'hash', 'salt']) {
          expect(signature.toLowerCase(), isNot(contains(forbidden)),
              reason: 'AuditRecord.$name must record that an account changed, '
                  'never the credential. A trail that leaks credentials is '
                  'worse than no trail');
        }
      }
    });

    test('the admin surface is read from AccessSurface, not restated here', () {
      // This arm used to assert the opposite — that AccessSurface had three
      // values and `byWireName('admin')` was null — on the reasoning that
      // nothing ever gates on an admin row. Plan 17-01 gave the policy
      // `groupForAdmin`, so something does now; and these rows have recorded
      // `groupRequired: users` since Phase 6, which was always a grading with
      // nowhere to be declared.
      //
      // What replaces it is the stronger claim: the surface the row is
      // recorded under and the surface the policy is asked about are the same
      // string, because one is read from the other.
      expect(AccessSurface.byWireName('admin'), AccessSurface.accessAdmin);
      expect(AccessSurface.accessAdmin.wireName, 'admin',
          reason: "stored data — a year of Phase 6 rows carry it; renaming "
              'this rewrites what they mean');

      final record = AuditRecord.roleCreate(
        who: 'jon',
        station: 'st101',
        roleName: 'Engineer',
        subject: 'Shift Leader',
        groups: '["operate"]',
        allowed: true,
        actionId: newActionId(),
      );
      expect(record.surface, AccessSurface.accessAdmin.wireName);
      expect(const AccessPolicy().groupForWireSurface(record.surface, 'x'),
          AccessGroup.users,
          reason: 'the policy answers for the surface the row carries');
    });

    test("'auth' is still not a write surface", () {
      // The precedent 'admin' used to follow, and the half of it that stands:
      // signing in is an event, not a write somebody could be authorized for,
      // so no policy member answers for it and it stays a private literal.
      //
      // This is the anti-vacuity half of the arm above: without it, "the enum
      // grew" would read as "the enum grows for anything that appears in the
      // surface column", which is not the rule.
      expect(AccessSurface.byWireName('auth'), isNull);
      final login = AuditRecord.login(
        who: 'jon',
        station: 'st101',
        roleName: 'Engineer',
        actionId: newActionId(),
      );
      expect(login.surface, 'auth');
      expect(AccessSurface.values.map((s) => s.wireName), isNot(contains('auth')));
    });
  });

  group('NullAuditSink', () {
    test('records nothing and completes', () async {
      final sink = NullAuditSink();
      await sink.record(
        AuditRecord.login(
          who: 'jon',
          station: 'st101',
          roleName: 'Engineering',
          actionId: newActionId(),
        ),
      );
    });

    test('is an AuditSink', () {
      expect(NullAuditSink(), isA<AuditSink>());
    });
  });
}

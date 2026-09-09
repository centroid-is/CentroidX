// AccessRepository — roles, the Operator guard, anonymous group resolution and
// the first-user window.
//
// SQLite only, against a real in-memory `AppDatabase`. The two rules this file
// exists to pin down are the ones that are easy to write down and easy to get
// wrong:
//
//  * the `Operator` row cannot be deleted or renamed, enforced in code rather
//    than documented in a comment somewhere;
//  * a user can be created only while `app_user` is empty, and the check that
//    makes that true lives *inside* the transaction.
//
// `PRAGMA foreign_keys = ON` is issued per database opened here rather than in
// `AppDatabase` itself. The pragma is per-connection and off by default in
// SQLite, so without it the referential test below would pass vacuously.
// Turning it on globally would change the behaviour of every other tfc_dart
// test that writes rows, so it is enabled in this file only.

import 'dart:convert';
import 'dart:io';

// `isNull` / `isNotNull` are matchers here, not drift's SQL expressions of the
// same names.
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_repository.dart';
import 'package:tfc_dart/core/database_drift.dart' show AppDatabase;

/// Opens an in-memory database with the schema created and foreign keys on.
///
/// The `SELECT 1` is what forces drift to run the migration: opening the
/// database is lazy, so without it the first assertion would race the schema.
Future<AppDatabase> _openDb() async {
  final db = AppDatabase.inMemoryForTest();
  await db.customSelect('SELECT 1').getSingle();
  await db.customStatement('PRAGMA foreign_keys = ON');
  return db;
}

/// Opens an in-memory database exactly as [_openDb] does, but **without** the
/// foreign-key pragma.
///
/// This is what every connection in this build looks like outside these tests.
/// The pragma is per-connection and SQLite defaults it off, and it is issued in
/// exactly five files — this one, `access_schema_test.dart` (twice),
/// `access_template_table_test.dart` and `local_auth_provider_test.dart`, all
/// of them tests. Nothing under any `lib/` turns it on.
///
/// So a rule that only holds when foreign keys are on is not a rule this build
/// has. The tests that use this opener are the ones that prove the rule is
/// enforced by [AccessRepository] itself.
Future<AppDatabase> _openDbForeignKeysOff() async {
  final db = AppDatabase.inMemoryForTest();
  await db.customSelect('SELECT 1').getSingle();
  return db;
}

/// The usernames holding [roleName], read with raw SQL, sorted.
Future<List<String>> _rawHoldersOf(AppDatabase db, String roleName) async {
  final rows = await db.customSelect(
    'SELECT username FROM app_user WHERE role_name = ?',
    variables: [Variable<String>(roleName)],
  ).get();
  return rows.map((r) => r.read<String>('username')).toList()..sort();
}

/// The `role_name` column of [username], read with raw SQL, or null.
Future<String?> _rawRoleOf(AppDatabase db, String username) async {
  final rows = await db.customSelect(
    'SELECT role_name FROM app_user WHERE username = ?',
    variables: [Variable<String>(username)],
  ).get();
  if (rows.isEmpty) return null;
  return rows.first.read<String>('role_name');
}

/// The groups of the role named [name], read with raw SQL.
///
/// Deliberately not through [AccessRepository]: a test that asserts on the
/// repository's own read of the row it just wrote can pass while the row is
/// wrong.
Future<Set<AccessGroup>?> _rawGroups(AppDatabase db, String name) async {
  final rows = await db.customSelect(
    'SELECT groups FROM app_role WHERE name = ?',
    variables: [Variable<String>(name)],
  ).get();
  if (rows.isEmpty) return null;
  return AccessRole.decodeGroups(rows.first.read<String>('groups'));
}

Future<Set<String>> _rawRoleNames(AppDatabase db) async {
  final rows = await db.customSelect('SELECT name FROM app_role').get();
  return rows.map((r) => r.read<String>('name')).toSet();
}

Future<int> _rawUserCount(AppDatabase db) async {
  final rows =
      await db.customSelect('SELECT COUNT(*) AS c FROM app_user').get();
  return rows.first.read<int>('c');
}

/// Inserts a user row directly, without going through the first-user window.
///
/// The referential tests need a user that holds a role; they are about
/// `deleteRole` and `renameRole`, not about how the row got there.
Future<void> _rawInsertUser(
  AppDatabase db, {
  required String username,
  required String roleName,
}) =>
    db.customStatement(
      'INSERT INTO app_user '
      '(username, role_name, password_hash, salt, created_at) '
      "VALUES ('$username', '$roleName', 'hash', 'salt', "
      "'2026-08-28T00:00:00Z')",
    );

/// Inserts an `audit_entry` row naming [who], with raw SQL.
///
/// `audit_entry.who` is a denormalised TEXT column with no foreign key
/// (`database_drift.dart:142`), which is what makes the trail survive a deleted
/// account by construction. The test below asserts that property rather than
/// trusting it.
Future<void> _rawInsertAudit(AppDatabase db, {required String who}) =>
    db.customStatement(
      'INSERT INTO audit_entry '
      '(at, who, station, role_name, surface, item_key, group_required, '
      'allowed, action_id) '
      "VALUES ('2026-08-29T00:00:00Z', '$who', 'ST101', 'Engineering', "
      "'admin', 'role.update', 'users', 1, 'a1')",
    );

Future<int> _rawAuditCountFor(AppDatabase db, String who) async {
  final rows = await db.customSelect(
    'SELECT COUNT(*) AS c FROM audit_entry WHERE who = ?',
    variables: [Variable<String>(who)],
  ).get();
  return rows.first.read<int>('c');
}

void main() {
  late AppDatabase db;
  late AccessRepository repo;

  setUp(() async {
    // 10 iterations, not 200000. A real derivation measures ~660 ms in the test
    // VM and the first-user group below performs a dozen of them; without this
    // hook the file becomes unrunnable rather than merely slow.
    Pbkdf2Kdf.iterationsForTest = 10;
    db = await _openDb();
    repo = AccessRepository(db);
  });

  tearDown(() async {
    Pbkdf2Kdf.iterationsForTest = null;
    await db.close();
  });

  group('roles', () {
    test('a fresh database returns the four seed roles, all seeded', () async {
      final roles = await repo.roles();

      expect(roles.map((r) => r.name).toSet(), {
        'Operator',
        'Shift Leader',
        'Maintenance',
        'Engineering',
      });
      expect(roles.every((r) => r.seeded), isTrue,
          reason: 'every row written by the v6 seed carries seeded = true');
    });

    test('role("Maintenance") holds operate, setpoints, device and force',
        () async {
      final role = await repo.role('Maintenance');

      expect(role, isNotNull);
      expect(role!.groups, {
        AccessGroup.operate,
        AccessGroup.setpoints,
        AccessGroup.device,
        AccessGroup.force,
      });
    });

    test('role() on an unknown name returns null', () async {
      expect(await repo.role('Nonexistent'), isNull);
    });
  });

  group('anonymous group resolution', () {
    test('a fresh database resolves anonymous to {operate}', () async {
      expect(await repo.anonymousGroups(), {AccessGroup.operate});
    });

    test('editing the Operator row changes what a logged-out panel may do',
        () async {
      // The deliberate footgun, asserted so it cannot be "fixed" by accident:
      // ticking setpoints on Operator grants it to every panel on the floor
      // with nobody signed in.
      await repo.upsertRole(const AccessRole(
        name: kOperatorRoleName,
        groups: {AccessGroup.operate, AccessGroup.setpoints},
      ));

      expect(await repo.anonymousGroups(),
          {AccessGroup.operate, AccessGroup.setpoints});
    });

    test('an empty Operator row means anonymous can do nothing', () async {
      // Allowed on purpose. Refusing an empty Operator would be a policy
      // decision, and this layer has no standing to make one — a site that
      // wants a panel that does nothing until somebody signs in is entitled
      // to have it.
      await repo
          .upsertRole(const AccessRole(name: kOperatorRoleName, groups: {}));

      expect(await repo.anonymousGroups(), isEmpty);
    });

    test('a missing Operator row falls back to the seeded {operate}', () async {
      // Simulates the row being deleted out from under the app in psql. A
      // logged-out panel that cannot jog because somebody ran a DELETE is a
      // stopped line; the seeded set is the conservative floor.
      await db.customStatement("DELETE FROM app_role WHERE name = 'Operator'");
      expect(await _rawGroups(db, kOperatorRoleName), isNull,
          reason: 'the row really is gone, so the fallback is what answers');

      expect(await repo.anonymousGroups(), {AccessGroup.operate});
    });

    test('a failing query falls back to the seeded {operate}', () async {
      // The other half of the same guarantee: the database being unreachable
      // must not cost a logged-out panel its ability to jog either.
      await db.close();

      expect(await repo.anonymousGroups(), {AccessGroup.operate});

      // Re-open so tearDown's close() has something valid to close.
      db = await _openDb();
    });
  });

  group('the Operator guard', () {
    test('deleteRole("Operator") throws and leaves the row present', () async {
      await expectLater(
        () => repo.deleteRole(kOperatorRoleName),
        throwsA(isA<ProtectedRoleError>()),
      );

      expect(await _rawRoleNames(db), contains(kOperatorRoleName));
    });

    test('deleteRole("operator") throws — the guard is case-insensitive',
        () async {
      await expectLater(
        () => repo.deleteRole('operator'),
        throwsA(isA<ProtectedRoleError>()),
      );

      expect(await _rawRoleNames(db), contains(kOperatorRoleName));
    });

    test('deleteRole(" Operator ") throws — and whitespace-tolerant', () async {
      await expectLater(
        () => repo.deleteRole(' Operator '),
        throwsA(isA<ProtectedRoleError>()),
      );

      expect(await _rawRoleNames(db), contains(kOperatorRoleName));
    });

    test('renameRole away from Operator throws and leaves the name alone',
        () async {
      await expectLater(
        () => repo.renameRole(kOperatorRoleName, 'Ops'),
        throwsA(isA<ProtectedRoleError>()),
      );

      final names = await _rawRoleNames(db);
      expect(names, contains(kOperatorRoleName));
      expect(names, isNot(contains('Ops')));
    });

    test('renameRole onto the Operator name throws too', () async {
      // The mirror image of the guard above: renaming another role *to*
      // Operator while Operator exists is a primary-key collision, and while
      // Operator is missing it would silently reassign the anonymous identity.
      await expectLater(
        () => repo.renameRole('Shift Leader', 'Operator'),
        throwsA(isA<ProtectedRoleError>()),
      );

      expect(await _rawRoleNames(db), contains('Shift Leader'));
    });

    test('Engineering is an ordinary row and deletes', () async {
      await repo.deleteRole('Engineering');

      expect(await _rawRoleNames(db), isNot(contains('Engineering')));
    });

    test('renaming an ordinary role succeeds and the old name is gone',
        () async {
      await repo.renameRole('Shift Leader', 'Team Lead');

      final names = await _rawRoleNames(db);
      expect(names, contains('Team Lead'));
      expect(names, isNot(contains('Shift Leader')));
      expect((await repo.role('Team Lead'))!.groups,
          {AccessGroup.operate, AccessGroup.setpoints});
    });

    test('renaming a role a user holds carries the user with it', () async {
      await _rawInsertUser(db, username: 'jon', roleName: 'Engineering');

      await repo.renameRole('Engineering', 'Controls');

      final rows = await db
          .customSelect("SELECT role_name FROM app_user WHERE username = 'jon'")
          .get();
      expect(rows.first.read<String>('role_name'), 'Controls',
          reason: 'a rename must not orphan the users pointing at the role');
    });

    test('renaming a role that does not exist names the missing role',
        () async {
      await expectLater(
        () => repo.renameRole('Ghost', 'Spectre'),
        throwsA(isA<MissingRoleError>()
            .having((e) => e.toString(), 'message', contains('Ghost'))),
      );
    });

    test('renaming onto a name that already exists is refused', () async {
      await expectLater(
        () => repo.renameRole('Shift Leader', 'Maintenance'),
        throwsA(isA<ArgumentError>()),
      );

      final names = await _rawRoleNames(db);
      expect(names, contains('Shift Leader'));
      expect(await _rawGroups(db, 'Maintenance'), {
        AccessGroup.operate,
        AccessGroup.setpoints,
        AccessGroup.device,
        AccessGroup.force,
      });
    });
  });

  group('upsertRole', () {
    test('a new name inserts', () async {
      await repo.upsertRole(const AccessRole(
        name: 'Line Lead',
        groups: {AccessGroup.operate, AccessGroup.setpoints},
      ));

      expect(await _rawGroups(db, 'Line Lead'),
          {AccessGroup.operate, AccessGroup.setpoints});
    });

    test('an existing name updates the groups in place and keeps seeded',
        () async {
      await repo.upsertRole(const AccessRole(
        name: 'Shift Leader',
        groups: {AccessGroup.operate},
        // Passed as false on purpose: an edit must not clear the flag that
        // says where the row came from.
        seeded: false,
      ));

      final role = await repo.role('Shift Leader');
      expect(role!.groups, {AccessGroup.operate});
      expect(role.seeded, isTrue);
      expect(await _rawRoleNames(db), hasLength(4),
          reason: 'an update, not a second row');
    });

    test('a role created through upsertRole is not marked seeded', () async {
      await repo.upsertRole(const AccessRole(name: 'Line Lead', groups: {}));

      expect((await repo.role('Line Lead'))!.seeded, isFalse);
    });

    test('a blank role name is refused', () async {
      // A row whose primary key is whitespace is unselectable from any screen
      // that trims its input, and there is no legitimate way to reach it.
      await expectLater(
        () => repo.upsertRole(const AccessRole(name: '  ', groups: {})),
        throwsA(isA<ArgumentError>()),
      );

      expect(await _rawRoleNames(db), hasLength(4));
    });

    test('renaming to a blank name is refused', () async {
      await expectLater(
        () => repo.renameRole('Shift Leader', '   '),
        throwsA(isA<ArgumentError>()),
      );

      expect(await _rawRoleNames(db), contains('Shift Leader'));
    });
  });

  group('deleting a role accounts still hold', () {
    // This group used to assert `SqliteException(787): FOREIGN KEY constraint
    // failed`. It passed only because this file turns the pragma on; on the
    // SQLite demo backend — where nothing turns it on — the delete succeeded
    // and left the holder pointing at a role that was no longer there. The
    // refusal now lives in [AccessRepository.deleteRole], and these tests
    // assert that refusal rather than the database engine's message.

    test('is refused in application code, with the holders named', () async {
      await _rawInsertUser(db, username: 'eng', roleName: 'Engineering');
      await _rawInsertUser(db, username: 'jon', roleName: 'Maintenance');
      await _rawInsertUser(db, username: 'ada', roleName: 'Maintenance');

      await expectLater(
        () => repo.deleteRole('Maintenance'),
        throwsA(isA<RoleInUseException>()
            .having((e) => e.roleName, 'roleName', 'Maintenance')
            // Sorted, so the dialog reads the same twice running.
            .having((e) => e.holders, 'holders', ['ada', 'jon'])),
      );

      expect(await _rawRoleNames(db), contains('Maintenance'));
      expect(await _rawUserCount(db), 3,
          reason: 'the user must not be orphaned by a refused delete');
    });

    test('is refused with foreign keys off — every production connection',
        () async {
      // The whole point of the trap: with the pragma off the database refuses
      // nothing, so the refusal has to be ours.
      await db.close();
      db = await _openDbForeignKeysOff();
      repo = AccessRepository(db);
      await _rawInsertUser(db, username: 'eng', roleName: 'Engineering');
      await _rawInsertUser(db, username: 'jon', roleName: 'Maintenance');

      await expectLater(
        () => repo.deleteRole('Maintenance'),
        throwsA(isA<RoleInUseException>()
            .having((e) => e.holders, 'holders', ['jon'])),
      );

      expect(await _rawRoleNames(db), contains('Maintenance'),
          reason: 'the role row survives the refusal');
      expect(await _rawRoleOf(db, 'jon'), 'Maintenance',
          reason: 'and so does the user row, still pointing at it');
    });

    test('names the holders in its message, so a dialog can quote it',
        () async {
      await _rawInsertUser(db, username: 'eng', roleName: 'Engineering');
      await _rawInsertUser(db, username: 'jon', roleName: 'Maintenance');

      await expectLater(
        () => repo.deleteRole('Maintenance'),
        throwsA(isA<RoleInUseException>().having(
          (e) => e.toString(),
          'message',
          allOf(contains('Maintenance'), contains('jon')),
        )),
      );
    });

    test('a role nobody holds still deletes', () async {
      await _rawInsertUser(db, username: 'eng', roleName: 'Engineering');

      await repo.deleteRole('Maintenance');

      expect(await _rawRoleNames(db), isNot(contains('Maintenance')));
    });
  });

  group('the last users-holder invariant', () {
    // Of the four seeded roles only Engineering grants `users`, so one account
    // holding Engineering is the whole of the plant's ability to manage roles
    // and accounts. Every trip route below starts from exactly that fixture.
    const engineeringWithoutUsers = AccessRole(
      name: 'Engineering',
      groups: {
        AccessGroup.operate,
        AccessGroup.setpoints,
        AccessGroup.device,
        AccessGroup.force,
        AccessGroup.configure,
        AccessGroup.administer,
      },
    );

    setUp(() => _rawInsertUser(db, username: 'jon', roleName: 'Engineering'));

    test('route (c): unticking users from the only role granting it is refused',
        () async {
      await expectLater(
        () => repo.upsertRole(engineeringWithoutUsers),
        throwsA(isA<LastUsersHolderException>()
            .having((e) => e.roleName, 'roleName', 'Engineering')
            .having((e) => e.holders, 'holders', ['jon'])),
      );

      expect(await _rawGroups(db, 'Engineering'), contains(AccessGroup.users),
          reason: 'the transaction rolled back — the stored set is unchanged');
    });

    test('route (d): deleting the only users-granting role is refused',
        () async {
      await expectLater(
        () => repo.deleteRole('Engineering'),
        throwsA(allOf(
          isA<LastUsersHolderException>()
              .having((e) => e.holders, 'holders', ['jon']),
          isNot(isA<RoleInUseException>()),
        )),
        reason: 'both rules trip here, and the lockout refusal is the one the '
            'operator must be told about: moving the holders off a role is a '
            'fix they can perform, and being locked out of the roles screen is '
            'not — it has no recovery inside the application at all',
      );

      expect(await _rawRoleNames(db), contains('Engineering'));
      expect(await _rawRoleOf(db, 'jon'), 'Engineering');
    });

    test(
        'the refusal points at the deployment doc rather than offering an '
        'override', () async {
      await expectLater(
        () => repo.deleteRole('Engineering'),
        throwsA(isA<LastUsersHolderException>().having(
          (e) => e.toString(),
          'message',
          allOf(contains('jon'), contains('access-control-deployment.md')),
        )),
      );
    });

    test('renaming the only users-granting role still succeeds', () async {
      // The guard refuses lockouts, not role administration. A rename carries
      // its holders with it, so the invariant is untouched; a guard here would
      // be a guard that refuses something safe.
      await repo.renameRole('Engineering', 'Controls');

      expect(await _rawRoleNames(db), contains('Controls'));
      expect(await _rawRoleOf(db, 'jon'), 'Controls');
      expect(await _rawHoldersOf(db, 'Controls'), ['jon']);
    });

    test('unticking users is allowed while another role still grants it',
        () async {
      await repo.upsertRole(const AccessRole(
        name: 'Controls',
        groups: {AccessGroup.operate, AccessGroup.users},
      ));
      await _rawInsertUser(db, username: 'ada', roleName: 'Controls');

      await repo.upsertRole(engineeringWithoutUsers);

      expect(await _rawGroups(db, 'Engineering'),
          isNot(contains(AccessGroup.users)));
    });

    test(
        'a user whose role names no role contributes nothing, and throws '
        'nothing', () async {
      // Reachable with foreign keys off, which is every production connection.
      await db.close();
      db = await _openDbForeignKeysOff();
      repo = AccessRepository(db);
      await _rawInsertUser(db, username: 'jon', roleName: 'Engineering');
      await _rawInsertUser(db, username: 'ghost', roleName: 'Nonexistent');

      await expectLater(
        () => repo.upsertRole(engineeringWithoutUsers),
        throwsA(isA<LastUsersHolderException>()
            .having((e) => e.holders, 'holders', ['jon'])),
      );
    });

    test('with no accounts at all the guard does not fire', () async {
      // A fresh station before anyone has commissioned it holds `users`
      // nowhere, so there is nothing for a change to take away. The recovery
      // from that state is the first-user window, not this guard, and a guard
      // that fired here would make a station unconfigurable out of the box.
      await db.customStatement('DELETE FROM app_user');

      await repo.deleteRole('Engineering');

      expect(await _rawRoleNames(db), isNot(contains('Engineering')));
    });
  });

  group('first user window', () {
    test('isUserTableEmpty is true on a fresh database', () async {
      expect(await repo.isUserTableEmpty, isTrue);
      expect(await repo.userCount(), 0);
    });

    test('isUserTableEmpty is false once a user exists', () async {
      await repo.createFirstUser(username: 'jon', password: 'hunter2');

      expect(await repo.isUserTableEmpty, isFalse);
      expect(await repo.userCount(), 1);
    });

    test('createFirstUser on an empty table inserts exactly one row', () async {
      await repo.createFirstUser(username: 'jon', password: 'hunter2');

      expect(await _rawUserCount(db), 1);
      expect((await repo.user('jon'))!.username, 'jon');
    });

    test('the first account is forced to Engineering', () async {
      // There is no role parameter to pass, which is the point: the first
      // account cannot ask to be something narrower or something else.
      await repo.createFirstUser(username: 'jon', password: 'hunter2');

      expect((await repo.user('jon'))!.roleName, 'Engineering');
    });

    test('the stored row holds a hash and a salt, not the password', () async {
      await repo.createFirstUser(username: 'jon', password: 'hunter2');

      final row = (await repo.user('jon'))!;
      expect(row.passwordHash, isNot(contains('hunter2')));
      expect(row.salt, isNotEmpty);
      expect(row.passwordHash, startsWith('argon2id\$'));
      expect(row.createdAt, isNotNull);
    });

    test('the stored hash verifies against the password it was made from',
        () async {
      await repo.createFirstUser(username: 'jon', password: 'hunter2');

      final row = (await repo.user('jon'))!;
      final decoded = decodeStoredHash(row.passwordHash, saltB64: row.salt)!;

      expect(
        await PasswordHasher.verify(password: 'hunter2', stored: decoded),
        isTrue,
      );
      expect(
        await PasswordHasher.verify(password: 'wrong', stored: decoded),
        isFalse,
      );
    });

    test('a second createFirstUser throws and inserts nothing', () async {
      await repo.createFirstUser(username: 'jon', password: 'hunter2');

      await expectLater(
        () => repo.createFirstUser(username: 'eve', password: 'letmein'),
        throwsA(isA<FirstUserWindowClosedError>()),
      );

      expect(await _rawUserCount(db), 1);
      expect(await repo.user('eve'), isNull);
    });

    test('two concurrent createFirstUser calls leave exactly one row',
        () async {
      // Both futures are created before either is awaited — that is what makes
      // this a race rather than two sequential calls. If the emptiness check
      // sat outside the transaction, both would see an empty table and both
      // would insert.
      final a = repo.createFirstUser(username: 'jon', password: 'hunter2');
      final b = repo.createFirstUser(username: 'eve', password: 'letmein');

      final outcomes = await Future.wait<Object?>([
        a.then<Object?>((_) => null, onError: (Object e) => e),
        b.then<Object?>((_) => null, onError: (Object e) => e),
      ]);

      expect(outcomes.whereType<FirstUserWindowClosedError>(), hasLength(1),
          reason: 'exactly one of the two must be refused');
      expect(outcomes.where((o) => o == null), hasLength(1),
          reason: 'exactly one of the two must succeed');
      expect(await _rawUserCount(db), 1);
    });

    test('an empty username throws ArgumentError and inserts nothing',
        () async {
      await expectLater(
        () => repo.createFirstUser(username: '  ', password: 'hunter2'),
        throwsA(isA<ArgumentError>()),
      );

      expect(await _rawUserCount(db), 0);
    });

    test('an empty password throws ArgumentError and inserts nothing',
        () async {
      await expectLater(
        () => repo.createFirstUser(username: 'jon', password: ''),
        throwsA(isA<ArgumentError>()),
      );

      expect(await _rawUserCount(db), 0);
    });

    test('the empty-password error does not quote the password', () async {
      // `ArgumentError.value(password, ...)` would put the credential in the
      // message and from there into whatever logs it.
      try {
        await repo.createFirstUser(username: 'jon', password: '');
        fail('expected an ArgumentError');
      } on ArgumentError catch (e) {
        expect(e.toString(), isNot(contains('hunter2')));
        expect(e.invalidValue, isNull);
      }
    });

    test('a missing Engineering role is named, not reported as a foreign key',
        () async {
      await repo.deleteRole('Engineering');

      await expectLater(
        () => repo.createFirstUser(username: 'jon', password: 'hunter2'),
        throwsA(isA<MissingRoleError>()
            .having((e) => e.toString(), 'message', contains('Engineering'))),
      );

      expect(await _rawUserCount(db), 0);
    });

    test('usernames are case-sensitive, matching the primary key', () async {
      await repo.createFirstUser(username: 'jon', password: 'hunter2');

      expect(await repo.user('jon'), isNotNull);
      expect(await repo.user('JON'), isNull,
          reason: 'a decision, not an accident: the PK is case-sensitive TEXT');
    });

    test('touchLastLogin writes the timestamp', () async {
      await repo.createFirstUser(username: 'jon', password: 'hunter2');
      expect((await repo.user('jon'))!.lastLoginAt, isNull);

      final at = DateTime.utc(2026, 8, 28, 9, 30);
      await repo.touchLastLogin('jon', at);

      expect((await repo.user('jon'))!.lastLoginAt!.toUtc(), at);
    });

    test('no password, hash or salt reaches flutter_preferences', () async {
      await repo.createFirstUser(username: 'jon', password: 'hunter2');
      final row = (await repo.user('jon'))!;

      final prefs = await db
          .customSelect('SELECT key, value FROM flutter_preferences')
          .get();
      for (final pref in prefs) {
        final value = pref.read<String?>('value') ?? '';
        for (final secret in ['hunter2', row.passwordHash, row.salt]) {
          expect(value, isNot(contains(secret)),
              reason: 'flutter_preferences is synced between stations and read '
                  'by the backend config watcher; credentials live in app_user '
                  'and nowhere else (key "${pref.read<String>('key')}")');
        }
      }
    });
  });

  group('stored hash encoding', () {
    test('round-trips through encodeStoredHash / decodeStoredHash', () async {
      final hash = await PasswordHasher.hash('hunter2');

      final decoded =
          decodeStoredHash(encodeStoredHash(hash), saltB64: hash.saltB64);

      expect(decoded, hash);
      expect(decoded!.memoryKib, 10, reason: 'the test hook value travels');
    });

    test('the encoded form carries the parameters it was made with', () async {
      final hash = await PasswordHasher.hash('hunter2');
      final stored = encodeStoredHash(hash);
      final params = Argon2idKdf.params;

      expect(
        stored,
        'argon2id\$v=19\$m=${params.memoryKib},t=${params.iterations},'
        'p=${params.parallelism}\$${hash.hashB64}',
        reason: 'composed from the constants rather than from literals, so the '
            'assertion cannot drift away from them',
      );

      // Raising the ambient cost must not change how an existing row reads.
      // That is the whole reason the parameters are stored rather than assumed.
      Pbkdf2Kdf.iterationsForTest = 99;
      final reread = decodeStoredHash(stored, saltB64: hash.saltB64)!;
      expect(reread.memoryKib, params.memoryKib);
      expect(reread.iterations, params.iterations);
      expect(reread.parallelism, params.parallelism);
      Pbkdf2Kdf.iterationsForTest = 10;
    });

    test('a legacy bare-base64 value decodes at the default count', () {
      final legacy = base64Encode(List<int>.filled(32, 7));

      final decoded = decodeStoredHash(legacy, saltB64: 'c2FsdA==');

      expect(decoded, isNotNull);
      expect(decoded!.hashB64, legacy);
      expect(decoded.iterations, Pbkdf2Kdf.iterations);
    });

    test('a mangled value decodes to null rather than throwing', () {
      expect(decodeStoredHash(r'scrypt$1$abc', saltB64: 'c2FsdA=='), isNull);
      expect(
        decodeStoredHash(r'pbkdf2-sha256$notanumber$abc', saltB64: 'c2FsdA=='),
        isNull,
      );
    });
  });

  group('listUsers', () {
    test('is empty on a fresh database', () async {
      expect(await repo.listUsers(), isEmpty);
    });

    test('returns every row, ordered by username', () async {
      await _rawInsertUser(db, username: 'jon', roleName: 'Engineering');
      await _rawInsertUser(db, username: 'ada', roleName: 'Maintenance');
      await _rawInsertUser(db, username: 'zoe', roleName: 'Operator');

      final users = await repo.listUsers();

      expect(users.map((u) => u.username), ['ada', 'jon', 'zoe']);
      expect(users.map((u) => u.roleName),
          ['Maintenance', 'Engineering', 'Operator']);
    });
  });

  group('createUser', () {
    test('creates an account in the role it was given', () async {
      await repo.createUser(
          username: 'ada', password: 'hunter2', roleName: 'Maintenance');

      final row = (await repo.user('ada'))!;
      expect(row.roleName, 'Maintenance',
          reason: 'unlike createFirstUser, the role is a parameter here');
      expect(row.createdAt, isNotNull);
      expect(row.lastLoginAt, isNull);
    });

    test('stores a hash and a salt, never the password', () async {
      await repo.createUser(
          username: 'ada', password: 'hunter2', roleName: 'Maintenance');

      final row = (await repo.user('ada'))!;
      expect(row.passwordHash, isNot(contains('hunter2')));
      expect(row.passwordHash, startsWith('argon2id\$'));
      final decoded = decodeStoredHash(row.passwordHash, saltB64: row.salt)!;
      expect(
        await PasswordHasher.verify(password: 'hunter2', stored: decoded),
        isTrue,
      );
    });

    test('works after the first-user window has closed', () async {
      // createUser is not createFirstUser: it neither opens nor closes that
      // window, and it is reachable only from a `users`-gated screen.
      await repo.createFirstUser(username: 'jon', password: 'hunter2');

      await repo.createUser(
          username: 'ada', password: 'letmein', roleName: 'Shift Leader');

      expect(await _rawUserCount(db), 2);
    });

    test('is not refused when nobody holds users yet', () async {
      // Creating an account cannot take a holder away, so createUser
      // deliberately does not call the lockout guard. On an empty table there
      // is no holder at all, which is where a misplaced guard would show up.
      await repo.createUser(
          username: 'zoe', password: 'hunter2', roleName: 'Operator');

      expect(await _rawUserCount(db), 1);
    });

    test('a duplicate username is refused, and names it', () async {
      await _rawInsertUser(db, username: 'ada', roleName: 'Maintenance');

      await expectLater(
        () => repo.createUser(
            username: 'ada', password: 'hunter2', roleName: 'Engineering'),
        throwsA(isA<UserExistsException>()
            .having((e) => e.username, 'username', 'ada')),
      );

      expect(await _rawRoleOf(db, 'ada'), 'Maintenance',
          reason: 'the transaction rolled back — the existing row is intact');
    });

    test('an unknown role is named, and nothing is inserted', () async {
      // The hash was derived before the transaction opened, so this is also
      // the case that throws one away — which costs nothing, and is why
      // deriving it early is safe.
      await expectLater(
        () => repo.createUser(
            username: 'ada', password: 'hunter2', roleName: 'Ghost'),
        throwsA(isA<MissingRoleError>()
            .having((e) => e.toString(), 'message', contains('Ghost'))),
      );

      expect(await _rawUserCount(db), 0);
    });

    test('a blank username is refused and quotes the username', () async {
      await expectLater(
        () => repo.createUser(
            username: '  ', password: 'hunter2', roleName: 'Engineering'),
        throwsA(isA<ArgumentError>()
            .having((e) => e.invalidValue, 'invalidValue', '  ')),
      );

      expect(await _rawUserCount(db), 0);
    });

    test('an empty password creates an account that signs in on its username '
        'alone, marked so nothing derives against it', () async {
      await repo.createUser(
          username: 'line', password: '', roleName: 'Engineering');

      final row = (await repo.user('line'))!;
      expect(row.passwordHash, kNoPasswordMarker);
      expect(isPasswordless(row.passwordHash), isTrue);
      expect(row.salt, isEmpty, reason: 'there is nothing to salt');
      expect(decodeStoredHash(row.passwordHash, saltB64: row.salt), isNull,
          reason: 'the marker is not an algorithm, so a caller that forgets to '
              'ask isPasswordless first fails the login rather than letting '
              'somebody in');
    });

    test('usernames are trimmed but not case-folded', () async {
      await repo.createUser(
          username: ' ada ', password: 'hunter2', roleName: 'Maintenance');
      await repo.createUser(
          username: 'ADA', password: 'hunter2', roleName: 'Maintenance');

      expect(await repo.user('ada'), isNotNull);
      expect(await repo.user('ADA'), isNotNull);
      expect(await _rawUserCount(db), 2,
          reason: 'the primary key is case-sensitive TEXT, by decision');
    });
  });

  group('deleteUser', () {
    test('removes the row', () async {
      await _rawInsertUser(db, username: 'eng', roleName: 'Engineering');
      await _rawInsertUser(db, username: 'ada', roleName: 'Maintenance');

      await repo.deleteUser('ada');

      expect(await repo.user('ada'), isNull);
      expect(await _rawUserCount(db), 1);
    });

    test('route (a): deleting the last users-holding account is refused',
        () async {
      await _rawInsertUser(db, username: 'jon', roleName: 'Engineering');
      await _rawInsertUser(db, username: 'ada', roleName: 'Maintenance');

      await expectLater(
        () => repo.deleteUser('jon'),
        throwsA(isA<LastUsersHolderException>()
            .having((e) => e.roleName, 'roleName', 'Engineering')
            .having((e) => e.holders, 'holders', ['jon'])),
      );

      expect(await _rawUserCount(db), 2,
          reason: 'the transaction rolled back — the row survives');
      expect(await _rawRoleOf(db, 'jon'), 'Engineering');
    });

    test('deleting one of two users-holders is allowed', () async {
      await _rawInsertUser(db, username: 'jon', roleName: 'Engineering');
      await _rawInsertUser(db, username: 'ada', roleName: 'Engineering');

      await repo.deleteUser('jon');

      expect(await _rawHoldersOf(db, 'Engineering'), ['ada']);
    });

    test('an unknown username is refused rather than succeeding quietly',
        () async {
      await expectLater(
        () => repo.deleteUser('ghost'),
        throwsA(isA<UserNotFoundException>()
            .having((e) => e.username, 'username', 'ghost')),
      );
    });

    test('leaves the deleted account audit rows in place', () async {
      await _rawInsertUser(db, username: 'eng', roleName: 'Engineering');
      await _rawInsertUser(db, username: 'ada', roleName: 'Maintenance');
      await _rawInsertAudit(db, who: 'ada');
      await _rawInsertAudit(db, who: 'ada');

      await repo.deleteUser('ada');

      expect(await _rawAuditCountFor(db, 'ada'), 2,
          reason: 'audit_entry.who is a denormalised TEXT column with no '
              'foreign key, so the trail survives a deleted account by '
              'construction. No cascade may ever be added.');
    });
  });

  group('setRole', () {
    test('moves the account onto the role', () async {
      await _rawInsertUser(db, username: 'eng', roleName: 'Engineering');
      await _rawInsertUser(db, username: 'ada', roleName: 'Operator');

      await repo.setRole('ada', 'Maintenance');

      expect(await _rawRoleOf(db, 'ada'), 'Maintenance');
    });

    test('route (b): moving the last users-holding account off it is refused',
        () async {
      await _rawInsertUser(db, username: 'jon', roleName: 'Engineering');

      await expectLater(
        () => repo.setRole('jon', 'Maintenance'),
        throwsA(isA<LastUsersHolderException>()
            .having((e) => e.roleName, 'roleName', 'Engineering')
            .having((e) => e.holders, 'holders', ['jon'])),
      );

      expect(await _rawRoleOf(db, 'jon'), 'Engineering',
          reason: 'the transaction rolled back — role_name is unchanged');
    });

    test('moving the last holder onto another users-granting role is allowed',
        () async {
      await _rawInsertUser(db, username: 'jon', roleName: 'Engineering');
      await repo.upsertRole(const AccessRole(
        name: 'Controls',
        groups: {AccessGroup.operate, AccessGroup.users},
      ));

      await repo.setRole('jon', 'Controls');

      expect(await _rawRoleOf(db, 'jon'), 'Controls');
    });

    test('an unknown username is refused', () async {
      await expectLater(
        () => repo.setRole('ghost', 'Maintenance'),
        throwsA(isA<UserNotFoundException>()
            .having((e) => e.username, 'username', 'ghost')),
      );
    });

    test('an unknown role is named', () async {
      await _rawInsertUser(db, username: 'ada', roleName: 'Maintenance');

      await expectLater(
        () => repo.setRole('ada', 'Ghost'),
        throwsA(isA<MissingRoleError>()
            .having((e) => e.toString(), 'message', contains('Ghost'))),
      );

      expect(await _rawRoleOf(db, 'ada'), 'Maintenance');
    });
  });

  group('rehashPassword', () {
    test('writes both columns and reports the one row it updated', () async {
      await repo.createFirstUser(username: 'jon', password: 'hunter2');
      final before = (await repo.user('jon'))!;
      final fresh = await PasswordHasher.hash('hunter2');

      final updated = await repo.rehashPassword('jon', fresh);

      expect(updated, 1);
      final after = (await repo.user('jon'))!;
      expect(after.passwordHash, encodeStoredHash(fresh));
      expect(after.salt, fresh.saltB64,
          reason: 'the salt belongs to the hash it was derived with; leaving '
              'the old one behind strands the row');
      expect(after.salt, isNot(before.salt));
      expect(after.roleName, before.roleName,
          reason: 'it rewrites the stored form of a password, and nothing '
              'else about the account');
      expect(after.lastLoginAt, before.lastLoginAt);

      final decoded = decodeStoredHash(after.passwordHash, saltB64: after.salt)!;
      expect(
        await PasswordHasher.verify(password: 'hunter2', stored: decoded),
        isTrue,
        reason: 'the same password the user has always used must still work, '
            'or the migration has locked them out',
      );
    });

    test('a username that no longer exists returns 0 and throws nothing',
        () async {
      // On the login path the row was read moments ago, so a zero row count
      // means the account was deleted in between. That is a legitimate
      // outcome, not an error — unlike setPassword, whose caller has no such
      // guarantee and which therefore throws.
      final fresh = await PasswordHasher.hash('hunter2');

      expect(await repo.rehashPassword('ghost', fresh), 0);
    });

    test('it neither derives nor opens a transaction', () {
      // The mirror image of the derive-before-transaction test below, and the
      // pair reads as one statement: those three writers keep the ordering by
      // convention, this one has nothing to order. It takes an already-derived
      // hash and issues a single UPDATE, which is also what lets the login
      // path decide *whether* to pay for a derivation before paying for one.
      //
      // Line endings normalised, and the end-of-method marker chosen, for the
      // reasons spelled out in that test — the same CI round trip paid for
      // both.
      final source = File('lib/core/access/access_repository.dart')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');

      final start = source.indexOf('Future<int> rehashPassword(');
      expect(start, greaterThan(-1), reason: 'rehashPassword must exist');
      final end = source.indexOf('\n  }\n', start);
      expect(end, greaterThan(-1),
          reason: 'could not find the end of rehashPassword — the marker is a '
              'literal newline-two-spaces-brace');
      final body = source.substring(start, end);

      expect(body, isNot(contains('PasswordHasher.hash')),
          reason: 'deriving here would move the cost into the repository and '
              'take the decision away from the caller that knows whether a '
              'rewrite is due at all');
      expect(body, isNot(contains('db.transaction')),
          reason: 'a single UPDATE is atomic on its own; a transaction would '
              'add a round trip to every migrating login for nothing');
    });
  });

  group('setPassword', () {
    test('writes a hash and salt that verify against the new password',
        () async {
      await repo.createFirstUser(username: 'jon', password: 'hunter2');
      final before = (await repo.user('jon'))!;

      await repo.setPassword('jon', 'letmein');

      final after = (await repo.user('jon'))!;
      expect(after.passwordHash, isNot(before.passwordHash));
      expect(after.salt, isNot(before.salt),
          reason: 'a reset writes a fresh salt as well as a fresh hash');
      expect(after.passwordHash, isNot(contains('letmein')));

      final decoded = decodeStoredHash(after.passwordHash, saltB64: after.salt)!;
      expect(
        await PasswordHasher.verify(password: 'letmein', stored: decoded),
        isTrue,
      );
      expect(
        await PasswordHasher.verify(password: 'hunter2', stored: decoded),
        isFalse,
      );
    });

    test('does not touch last_login_at, and does not sign anybody out',
        () async {
      await repo.createFirstUser(username: 'jon', password: 'hunter2');
      final at = DateTime.utc(2026, 8, 29, 6);
      await repo.touchLastLogin('jon', at);

      await repo.setPassword('jon', 'letmein');

      expect((await repo.user('jon'))!.lastLoginAt!.toUtc(), at);
      expect((await repo.user('jon'))!.roleName, 'Engineering');
    });

    test('an unknown username is refused', () async {
      await expectLater(
        () => repo.setPassword('ghost', 'letmein'),
        throwsA(isA<UserNotFoundException>()
            .having((e) => e.username, 'username', 'ghost')),
      );
    });

    test('an empty password removes the password rather than being refused, '
        'and a real one puts it back', () async {
      await repo.createFirstUser(username: 'jon', password: 'hunter2');
      final before = (await repo.user('jon'))!.passwordHash;
      expect(isPasswordless(before), isFalse);

      await repo.setPassword('jon', '');
      final opened = (await repo.user('jon'))!;
      expect(opened.passwordHash, kNoPasswordMarker);
      expect(opened.salt, isEmpty);

      await repo.setPassword('jon', 'hunter3');
      final closed = (await repo.user('jon'))!;
      expect(isPasswordless(closed.passwordHash), isFalse,
          reason: 'it is a round trip, not a one-way door');
      expect(closed.salt, isNotEmpty);
      expect(closed.passwordHash, isNot(before),
          reason: 'a new salt, so a new hash');
    });

    test('the hash is derived before the transaction opens', () async {
      // Structural, because the ordering is not observable from outside: the
      // cost of getting it wrong is a write transaction held open across a
      // one-second key derivation on the shared Postgres server, not a wrong
      // answer. createFirstUser states the reasoning; these two methods copy
      // it, and this test is what keeps them copying it.
      // Line endings normalised because this test parses the source rather
      // than merely searching it: the end-of-method marker below is a literal
      // '\n  }\n', which on a Windows checkout is '\r\n  }\r\n'. Without this
      // the indexOf returns -1 and the substring throws a RangeError instead
      // of failing with anything that names the real problem. Cost one CI
      // round trip on windows-latest.
      final source = File('lib/core/access/access_repository.dart')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');

      for (final method in ['createUser', 'setPassword']) {
        final start = source.indexOf('Future<void> $method(');
        expect(start, greaterThan(-1), reason: '$method must exist');
        final end = source.indexOf('\n  }\n', start);
        expect(end, greaterThan(-1),
            reason: 'could not find the end of $method — the end-of-method '
                'marker is a literal newline-two-spaces-brace, so a reindent '
                'or a stray line ending breaks this parse, not the ordering '
                'it is checking');
        final body = source.substring(start, end);

        final hashAt = body.indexOf('PasswordHasher.hash');
        final transactionAt = body.indexOf('db.transaction');
        expect(hashAt, greaterThan(-1), reason: '$method must hash');
        expect(transactionAt, greaterThan(-1),
            reason: '$method must write inside a transaction');
        expect(hashAt, lessThan(transactionAt),
            reason: '$method must derive the hash before opening the '
                'transaction, as createFirstUser does');
      }
    });
  });
}

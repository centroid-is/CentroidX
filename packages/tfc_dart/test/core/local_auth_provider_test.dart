// LocalAuthProvider — the one AuthProvider this milestone ships.
//
// The contract being pinned down here is the null-vs-throw one from
// `AuthProvider`: **null means the credentials were not recognised, a throw
// means infrastructure failed.** Plan 01-07 writes an audit row with
// `allowed: false` for the null and must not record a database outage as
// somebody's failed login attempt — a trail that reports twenty failed logins
// during a five-minute network blip is a trail nobody trusts afterwards.
// Collapsing the two here would be untraceable later, so both halves have their
// own test.
//
// `PRAGMA foreign_keys = ON` is per-connection and enabled per database opened
// in this file, for the same reason as in `access_repository_test.dart`.

import 'dart:convert';
import 'dart:io';

// `isNull` / `isNotNull` are matchers here, not drift's SQL expressions of the
// same names.
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:logger/logger.dart';
import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_repository.dart';
import 'package:tfc_dart/core/access/local_auth_provider.dart';
import 'package:tfc_dart/core/database_drift.dart'
    show AppDatabase, AppUserCompanion, AppUserData;

Future<AppDatabase> _openDb() async {
  final db = AppDatabase.inMemoryForTest();
  await db.customSelect('SELECT 1').getSingle();
  await db.customStatement('PRAGMA foreign_keys = ON');
  return db;
}

/// Collects log lines so the warning paths can be asserted on.
class _CapturingOutput extends LogOutput {
  final List<String> lines = [];

  @override
  void output(OutputEvent event) => lines.addAll(event.lines);
}

/// Passes everything through, so the assertions do not depend on the ambient
/// log level.
class _AlwaysFilter extends LogFilter {
  @override
  bool shouldLog(LogEvent event) => true;
}

/// Emits `level|message`, so a test can assert on the level without parsing
/// whatever decoration the default printer applies.
class _LevelTaggedPrinter extends LogPrinter {
  @override
  List<String> log(LogEvent event) => ['${event.level.name}|${event.message}'];
}

/// A repository whose reads fail — a stand-in for the shared Postgres server
/// being unreachable.
class _OutageRepository extends AccessRepository {
  _OutageRepository(super.db);

  @override
  Future<AppUserData?> user(String username) =>
      Future<AppUserData?>.error(StateError('connection closed'));
}

/// A repository that counts its reads, for the "does not touch the database"
/// assertions.
class _CountingRepository extends AccessRepository {
  _CountingRepository(super.db);

  int userReads = 0;

  @override
  Future<AppUserData?> user(String username) {
    userReads++;
    return super.user(username);
  }
}

/// Rewrites [username]'s row as a `pbkdf2-sha256` one, the way every row in
/// every deployed database was written before Argon2id landed.
///
/// Local to this file on purpose, and assembled from the primitives that are
/// still public because verification needs them forever. There is deliberately
/// no library function for this: [PasswordHasher.hash] only makes Argon2id
/// now, and a helper in `tfc_access` that wrote the retired algorithm would be
/// a live write path for the very thing this migration exists to remove — which
/// is how a retired algorithm comes back.
Future<void> _plantLegacyPbkdf2Row(
  AppDatabase db, {
  required String username,
  required String password,
}) async {
  final salt = List<int>.generate(16, (i) => i + 1);
  final key = await Pbkdf2Kdf.deriveKey(
    passphrase: password,
    salt: salt,
    iterations: Pbkdf2Kdf.iterations,
  );
  final legacy = PasswordHash(
    hashB64: base64Encode(await key.extractBytes()),
    saltB64: base64Encode(salt),
    iterations: Pbkdf2Kdf.iterations,
  );

  await (db.update(db.appUser)..where((t) => t.username.equals(username)))
      .write(AppUserCompanion(
    passwordHash: Value(encodeStoredHash(legacy)),
    salt: Value(legacy.saltB64),
  ));
}

/// A repository that counts the write-backs `rehashPassword` performs, and
/// otherwise delegates.
///
/// Counting is the only honest way to assert idempotence: two Argon2id hashes
/// of the same password differ by their salt, so comparing stored values across
/// two logins cannot tell "rewritten again" from "rewritten once".
class _RehashCountingRepository extends AccessRepository {
  _RehashCountingRepository(super.db);

  int rehashes = 0;

  @override
  Future<int> rehashPassword(String username, PasswordHash hash) {
    rehashes++;
    return super.rehashPassword(username, hash);
  }
}

/// A repository whose `rehashPassword` always fails — a read-only replica, a
/// permissions change, a connection dropped between the read and the write.
///
/// The user in front of the panel typed the right password. The write-back is a
/// convenience nobody asked for, and it must not be able to refuse them.
class _RehashFailingRepository extends AccessRepository {
  _RehashFailingRepository(super.db);

  @override
  Future<int> rehashPassword(String username, PasswordHash hash) =>
      Future<int>.error(StateError('read-only replica'));
}

void main() {
  late AppDatabase db;
  late AccessRepository repo;
  late LocalAuthProvider provider;
  late _CapturingOutput logOutput;

  setUp(() async {
    // 10 iterations, not 200000: every test below performs at least one real
    // derivation, several perform two.
    Pbkdf2Kdf.iterationsForTest = 10;
    LocalAuthProvider.dummyDerivations = 0;
    db = await _openDb();
    repo = AccessRepository(db);
    logOutput = _CapturingOutput();
    provider = LocalAuthProvider(
      repo,
      logger: Logger(
        filter: _AlwaysFilter(),
        printer: _LevelTaggedPrinter(),
        output: logOutput,
      ),
    );
    await repo.createFirstUser(username: 'jon', password: 'hunter2');
  });

  tearDown(() async {
    Pbkdf2Kdf.iterationsForTest = null;
    LocalAuthProvider.dummyDerivations = 0;
    await db.close();
  });

  group('credentials', () {
    test('the right password returns the user and their role', () async {
      final user = await provider.authenticate('jon', 'hunter2');

      expect(user, isNotNull);
      expect(user!.username, 'jon');
      expect(user.roleName, 'Engineering');
    });

    test('a wrong password returns null', () async {
      expect(await provider.authenticate('jon', 'wrong'), isNull);
    });

    test('an unknown username returns null', () async {
      expect(await provider.authenticate('nobody', 'hunter2'), isNull);
    });

    test('the username is trimmed before lookup', () async {
      expect(await provider.authenticate('  jon  ', 'hunter2'), isNotNull);
    });

    test('an empty username returns null without touching the database',
        () async {
      final counting = _CountingRepository(db);
      final p = LocalAuthProvider(counting);

      expect(await p.authenticate('   ', 'hunter2'), isNull);
      expect(counting.userReads, 0);
    });

    test('an empty password against an account that has one returns null',
        () async {
      // It used to short-circuit before the database was touched. It cannot
      // any more: a blank password is how a passwordless account signs in, so
      // the row has to be read before the answer is known. What must not
      // change is the answer for an account that *does* have a password.
      expect(await provider.authenticate('jon', ''), isNull);
    });
  });

  group('an account with no password', () {
    setUp(() async {
      await repo.upsertRole(const AccessRole(
          name: 'Line', groups: {AccessGroup.operate}));
      await repo.createUser(
          username: 'line', password: '', roleName: 'Line');
    });

    test('signs in on its username alone', () async {
      final user = await provider.authenticate('line', '');

      expect(user, isNotNull,
          reason: 'this is the whole feature: a blank password box and a name');
      expect(user!.username, 'line');
      expect(user.roleName, 'Line');
    });

    test('signs in whatever was typed in the password box', () async {
      // Stated as a test rather than left to be discovered: there is no
      // credential, so there is no wrong guess at one. Anybody at the panel
      // holds this account's role, which is what the users screen marks and
      // what the create dialog warns about.
      expect(await provider.authenticate('line', 'anything at all'), isNotNull);
    });

    test('the sign-in is recorded like any other', () async {
      await provider.authenticate('line', '');

      expect((await repo.user('line'))!.lastLoginAt, isNotNull,
          reason: 'an open account is the one you most want a last-login for');
    });

    test('nothing is derived for it, and nothing is rehashed', () async {
      LocalAuthProvider.dummyDerivations = 0;
      final before = (await repo.user('line'))!.passwordHash;

      await provider.authenticate('line', '');

      expect(LocalAuthProvider.dummyDerivations, 0,
          reason: 'the account exists, so the absent-user dummy must not run');
      expect((await repo.user('line'))!.passwordHash, before,
          reason: 'there is no plaintext in hand and no hash to carry '
              'forward, so the rehash path must not be reached');
    });

    test('giving it a password closes it again', () async {
      await repo.setPassword('line', 'hunter2');

      expect(await provider.authenticate('line', ''), isNull);
      expect(await provider.authenticate('line', 'wrong'), isNull);
      expect(await provider.authenticate('line', 'hunter2'), isNotNull);
    });
  });

  group('username enumeration resistance', () {
    test('an absent user still costs a derivation', () async {
      await provider.authenticate('nobody', 'hunter2');

      expect(LocalAuthProvider.dummyDerivations, 1,
          reason: 'the missing-user path must do the same work as the '
              'wrong-password path, or the difference enumerates usernames');
    });

    test('a present user costs no dummy derivation', () async {
      await provider.authenticate('jon', 'wrong');

      expect(LocalAuthProvider.dummyDerivations, 0);
    });

    test('the empty-input short circuit costs no derivation', () async {
      // Nothing to hide here: an empty username is not a username somebody
      // might or might not have.
      await provider.authenticate('', 'hunter2');

      expect(LocalAuthProvider.dummyDerivations, 0);
    });
  });

  group('lastLoginAt', () {
    test('a successful authenticate records the login', () async {
      expect((await repo.user('jon'))!.lastLoginAt, isNull);

      await provider.authenticate('jon', 'hunter2');

      expect((await repo.user('jon'))!.lastLoginAt, isNotNull);
    });

    test('a failed authenticate does not', () async {
      await provider.authenticate('jon', 'wrong');

      expect((await repo.user('jon'))!.lastLoginAt, isNull);
    });
  });

  group('a dangling role', () {
    /// Deletes the `Engineering` row out from under the user, the way `psql`
    /// would. Foreign keys are turned off for the one statement: the point is
    /// to reproduce damage the app cannot itself cause, not to test the
    /// constraint.
    Future<void> deleteEngineeringBehindTheApp() async {
      await db.customStatement('PRAGMA foreign_keys = OFF');
      await db
          .customStatement("DELETE FROM app_role WHERE name = 'Engineering'");
      await db.customStatement('PRAGMA foreign_keys = ON');
    }

    test('returns null rather than an undefined group set', () async {
      await deleteEngineeringBehindTheApp();

      expect(await provider.authenticate('jon', 'hunter2'), isNull);
    });

    test('logs a warning naming the user and the missing role', () async {
      await deleteEngineeringBehindTheApp();

      await provider.authenticate('jon', 'hunter2');

      final warnings =
          logOutput.lines.where((l) => l.startsWith('warning|')).join('\n');
      expect(warnings, isNotEmpty,
          reason: 'a dangling role is an operational fault, not a quiet null');
      expect(warnings, contains('jon'));
      expect(warnings, contains('Engineering'));
    });

    test('does not record a login for a role that is gone', () async {
      await deleteEngineeringBehindTheApp();

      await provider.authenticate('jon', 'hunter2');

      expect((await repo.user('jon'))!.lastLoginAt, isNull);
    });
  });

  group('the null-vs-throw contract', () {
    test('a database outage rethrows rather than returning null', () async {
      final p = LocalAuthProvider(_OutageRepository(db));

      await expectLater(
        () => p.authenticate('jon', 'hunter2'),
        throwsA(isA<StateError>()),
        reason: 'null means bad credentials; an outage must not be audited as '
            'a failed login attempt',
      );
    });
  });


  group('migration to argon2id', () {
    /// A provider over [r] logging into the shared capture, so the warning
    /// assertions here work the same way the ones above do.
    LocalAuthProvider providerFor(AccessRepository r) => LocalAuthProvider(
          r,
          logger: Logger(
            filter: _AlwaysFilter(),
            printer: _LevelTaggedPrinter(),
            output: logOutput,
          ),
        );

    Future<void> deleteEngineeringBehindTheApp() async {
      await db.customStatement('PRAGMA foreign_keys = OFF');
      await db
          .customStatement("DELETE FROM app_role WHERE name = 'Engineering'");
      await db.customStatement('PRAGMA foreign_keys = ON');
    }

    test('a pbkdf2-sha256 row signs in and comes out argon2id', () async {
      await _plantLegacyPbkdf2Row(db, username: 'jon', password: 'hunter2');
      final before = (await repo.user('jon'))!;
      expect(before.passwordHash, startsWith('pbkdf2-sha256\$'),
          reason: 'the fixture must really be a legacy row, or the rewrite '
              'assertion below passes vacuously');

      final user = await provider.authenticate('jon', 'hunter2');

      expect(user, isNotNull,
          reason: 'the migration must not change who can sign in');
      expect(user!.username, 'jon');
      expect(user.roleName, 'Engineering');

      final after = (await repo.user('jon'))!;
      expect(after.passwordHash, startsWith('argon2id\$'),
          reason: 'asserted by the tag rather than by "the hash changed", '
              'which a re-salted pbkdf2 row would also satisfy');
      expect(after.salt, isNot(before.salt),
          reason: 'the salt belongs to the hash it was derived with');
    });

    test('the rewrite is invisible to whoever signed in', () async {
      await _plantLegacyPbkdf2Row(db, username: 'jon', password: 'hunter2');

      final first = await provider.authenticate('jon', 'hunter2');
      final second = await provider.authenticate('jon', 'hunter2');

      expect(first, isNotNull);
      expect(second, isNotNull,
          reason: 'the rewritten row must verify against the password its '
              'owner has always used — this is the lockout the migration '
              'exists to avoid');
      expect(second!.username, first!.username);
      expect(second.roleName, first.roleName);
    });

    test('a second login rewrites nothing', () async {
      await _plantLegacyPbkdf2Row(db, username: 'jon', password: 'hunter2');
      final counting = _RehashCountingRepository(db);
      final p = providerFor(counting);

      expect(await p.authenticate('jon', 'hunter2'), isNotNull);
      expect(counting.rehashes, 1);

      expect(await p.authenticate('jon', 'hunter2'), isNotNull);
      expect(counting.rehashes, 1,
          reason: 'the row is argon2id at the current parameters now, so '
              'needsRehash is false and there is nothing to do');
    });

    test('a user already on an argon2id row is never rewritten', () async {
      // `jon` was created by the setUp, through createFirstUser, which has
      // written Argon2id from the start since plan 07-14.
      final counting = _RehashCountingRepository(db);

      expect(await providerFor(counting).authenticate('jon', 'hunter2'),
          isNotNull);

      expect(counting.rehashes, 0);
    });

    test('a wrong password rewrites nothing', () async {
      await _plantLegacyPbkdf2Row(db, username: 'jon', password: 'hunter2');
      final before = (await repo.user('jon'))!;
      final counting = _RehashCountingRepository(db);

      expect(await providerFor(counting).authenticate('jon', 'wrong'), isNull);

      expect(counting.rehashes, 0,
          reason: 'there is no verified password in hand on this path; a '
              'rewrite here would be a rewrite from an unverified string');
      final after = (await repo.user('jon'))!;
      expect(after.passwordHash, before.passwordHash);
      expect(after.salt, before.salt);
    });

    test('a write-back that throws does not fail the login', () async {
      // The central guarantee of this plan. A migration that locks out the
      // people it exists to migrate is worse than no migration.
      await _plantLegacyPbkdf2Row(db, username: 'jon', password: 'hunter2');
      final p = providerFor(_RehashFailingRepository(db));

      final user = await p.authenticate('jon', 'hunter2');

      expect(user, isNotNull,
          reason: 'the credentials were already judged and the answer was '
              'yes; a housekeeping write nobody asked for must not be able to '
              'refuse a correct password');
      expect(user!.username, 'jon');
      expect(user.roleName, 'Engineering');

      final warnings =
          logOutput.lines.where((l) => l.startsWith('warning|')).join('\n');
      expect(warnings, isNotEmpty,
          reason: 'a rewrite that cannot be written is an operational fault, '
              'not a silent one');
      expect(warnings, contains('jon'));
      expect(warnings, contains('upgrad'));

      final after = (await repo.user('jon'))!;
      expect(after.passwordHash, startsWith('pbkdf2-sha256\$'),
          reason: 'the row is untouched, so the next login tries again');
    });

    test('a login refused for a missing role does not rewrite the row',
        () async {
      await _plantLegacyPbkdf2Row(db, username: 'jon', password: 'hunter2');
      final before = (await repo.user('jon'))!;
      await deleteEngineeringBehindTheApp();
      final counting = _RehashCountingRepository(db);

      expect(
          await providerFor(counting).authenticate('jon', 'hunter2'), isNull);

      expect(counting.rehashes, 0,
          reason: 'the refusal returns before the write-back; a session that '
              'is not going to exist must not quietly rewrite a row');
      final after = (await repo.user('jon'))!;
      expect(after.passwordHash, before.passwordHash);
      expect(after.salt, before.salt);
    });

    test('the password reaches no log line on any of the four paths', () async {
      // A distinctive value: a short or common password could satisfy this
      // assertion by simply not appearing anywhere, which proves nothing.
      const password = 'correct-horse-battery-staple-7Q';

      // The success-and-rewrite path.
      await _plantLegacyPbkdf2Row(db, username: 'jon', password: password);
      expect(await providerFor(repo).authenticate('jon', password), isNotNull);

      // The wrong-password path.
      expect(
          await providerFor(repo).authenticate('jon', '$password-no'), isNull);

      // The write-back-failure path — re-planted, because the row above is
      // argon2id now and would have nothing to rewrite.
      await _plantLegacyPbkdf2Row(db, username: 'jon', password: password);
      expect(
        await providerFor(_RehashFailingRepository(db))
            .authenticate('jon', password),
        isNotNull,
      );

      // The missing-role path.
      await deleteEngineeringBehindTheApp();
      expect(await providerFor(repo).authenticate('jon', password), isNull);

      expect(logOutput.lines, isNotEmpty,
          reason: 'two of those paths warn, so an empty capture would mean '
              'this test asserts nothing');
      expect(logOutput.lines.join('\n'), isNot(contains(password)));
    });
  });

  group('the password never reaches a log or a message', () {
    test('no log line produced by any path contains the password', () async {
      await provider.authenticate('jon', 'hunter2');
      await provider.authenticate('jon', 'hunter2-wrong');
      await provider.authenticate('nobody', 'hunter2-wrong');

      expect(logOutput.lines.join('\n'), isNot(contains('hunter2')));
    });

    test('the source file interpolates no password into any string', () {
      // A source-level assertion rather than a behavioural one, because the
      // behavioural version can only cover the paths a test happens to walk.
      // If a future edit adds `logger.d('checking $password')` on some branch
      // nothing here exercises, this still fails.
      final source =
          File('lib/core/access/local_auth_provider.dart').readAsStringSync();
      expect(source, isNotEmpty,
          reason: 'the file must actually be found, or this passes vacuously');

      for (final forbidden in [
        r'$password',
        r'${password',
        r'$_password',
        // The change-password path's own parameter names. Same rule, same
        // reason: this file logs on three branches of `changePassword`, and a
        // credential interpolated into any of them outlives the change.
        r'$currentPassword',
        r'${currentPassword',
        r'$newPassword',
        r'${newPassword',
      ]) {
        expect(source, isNot(contains(forbidden)),
            reason: 'a password in a log line or an exception message outlives '
                'the login it came from');
      }
    });
  });

  // -------------------------------------------------------------------------
  // Self-service password change
  //
  // The contract is `PasswordChangeResult`'s three values plus the throw, and
  // the same discipline as `authenticate` above: a judged request is a value, a
  // failure of the machinery is a throw. The extra assertion this path carries
  // that the login path does not is what it must *not* do — see the
  // `touchLastLogin` test.
  // -------------------------------------------------------------------------
  group('changePassword', () {
    /// Verifies [password] against whatever is stored for [username] right now.
    ///
    /// Reads the row back rather than calling `authenticate`, so the assertion
    /// does not depend on the method under test's neighbour.
    Future<bool> storedPasswordIs(String username, String password) async {
      final row = await repo.user(username);
      if (row == null) return false;
      final stored = decodeStoredHash(row.passwordHash, saltB64: row.salt);
      if (stored == null) return false;
      return PasswordHasher.verify(password: password, stored: stored);
    }

    test('the right current password replaces it with the new one', () async {
      final result = await provider.changePassword(
        username: 'jon',
        currentPassword: 'hunter2',
        newPassword: 'letmein',
      );

      expect(result, PasswordChangeResult.ok);
      expect(await storedPasswordIs('jon', 'letmein'), isTrue);
      expect(await storedPasswordIs('jon', 'hunter2'), isFalse,
          reason: 'the old password must stop working at once — the dialog '
              'promises exactly that');
    });

    test('a wrong current password changes nothing', () async {
      final before = (await repo.user('jon'))!;

      final result = await provider.changePassword(
        username: 'jon',
        currentPassword: 'wrong',
        newPassword: 'letmein',
      );

      expect(result, PasswordChangeResult.wrongCurrentPassword);

      final after = (await repo.user('jon'))!;
      expect(after.passwordHash, before.passwordHash,
          reason: 'a refused change must not rewrite the row');
      expect(after.salt, before.salt);
      expect(await storedPasswordIs('jon', 'hunter2'), isTrue);
    });

    test('an empty current password is refused without a derivation', () async {
      final counting = _CountingRepository(db);
      final p = LocalAuthProvider(counting);

      expect(
        await p.changePassword(
          username: 'jon',
          currentPassword: '',
          newPassword: 'letmein',
        ),
        PasswordChangeResult.wrongCurrentPassword,
      );
      expect(counting.userReads, 0,
          reason: 'an empty current password cannot be right, so there is '
              'nothing to look up');
    });

    test('an empty new password throws, carrying no credential', () async {
      try {
        await provider.changePassword(
          username: 'jon',
          currentPassword: 'hunter2',
          newPassword: '',
        );
        fail('an empty new password must be refused');
      } on ArgumentError catch (e) {
        // The rule `AccessRepository.setPassword` set: the message must not be
        // able to carry the credential into whatever logs the error.
        expect(e.toString(), isNot(contains('hunter2')));
        expect(e.invalidValue, isNull);
      }

      expect(await storedPasswordIs('jon', 'hunter2'), isTrue);
    });

    test('a deleted account is accountMissing, not a wrong password', () async {
      // An administrator can delete an account while its owner has a session
      // open. Telling that person their password is wrong would cost them the
      // next ten minutes.
      expect(
        await provider.changePassword(
          username: 'ghost',
          currentPassword: 'hunter2',
          newPassword: 'letmein',
        ),
        PasswordChangeResult.accountMissing,
      );
    });

    test('an undecodable hash is refused, and says so in the log', () async {
      // A row edited by hand in `psql`. Not a credential failure in spirit, but
      // it is one in effect, and the alternative — a FormatException off a
      // dialog — takes the screen down over a row the person at the panel did
      // not write. The log line is the only place the real cause survives.
      //
      // The stored form has to be one `tryDecode` actually rejects. A bare
      // string with no `$` is read as a *legacy* bare-base64 pbkdf2 hash and
      // decodes fine; it fails later, in `verify`, and reaches the same
      // refusal by a different route — covered by the test below.
      await (db.update(db.appUser)..where((t) => t.username.equals('jon')))
          .write(const AppUserCompanion(
              passwordHash: Value(r'pbkdf2-sha256$notanumber$aGk=')));

      expect(
        await provider.changePassword(
          username: 'jon',
          currentPassword: 'hunter2',
          newPassword: 'letmein',
        ),
        PasswordChangeResult.wrongCurrentPassword,
      );
      expect(
        logOutput.lines.where((l) => l.startsWith('warning|')).join('\n'),
        contains('edited outside'),
      );
    });

    test('a hash that decodes but cannot verify is refused too', () async {
      // The other route to the same answer: `tryDecode` accepts this as a
      // legacy bare hash, and `PasswordHasher.verify` returns false rather than
      // throwing on the base64 that is not base64. Refused, not thrown, and
      // deliberately without the log line — nothing here knows the row is
      // damaged rather than simply not matching.
      await (db.update(db.appUser)..where((t) => t.username.equals('jon')))
          .write(const AppUserCompanion(passwordHash: Value('not-a-hash')));

      expect(
        await provider.changePassword(
          username: 'jon',
          currentPassword: 'hunter2',
          newPassword: 'letmein',
        ),
        PasswordChangeResult.wrongCurrentPassword,
      );
    });

    test('an outage throws rather than reporting a wrong password', () async {
      // The rule this whole file exists to pin: infrastructure is a throw. A
      // database blip recorded as somebody failing to change their password is
      // a trail nobody trusts.
      final p = LocalAuthProvider(_OutageRepository(db));

      expect(
        () => p.changePassword(
          username: 'jon',
          currentPassword: 'hunter2',
          newPassword: 'letmein',
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('does not touch last_login_at — a change is not a login', () async {
      // The reason this method does not simply call `authenticate`. Moving the
      // last-login timestamp on a password change makes it unable to answer
      // "when was this account last actually used?", which is the question an
      // administrator asks before deleting a stale account.
      await repo.touchLastLogin('jon', DateTime.utc(2026, 1, 1));
      final before = (await repo.user('jon'))!.lastLoginAt;

      await provider.changePassword(
        username: 'jon',
        currentPassword: 'hunter2',
        newPassword: 'letmein',
      );

      expect((await repo.user('jon'))!.lastLoginAt, before);
    });

    test('a legacy pbkdf2 row verifies and lands as argon2id', () async {
      // The migration, by a second route. `authenticate` carries people forward
      // on their next login; this carries them forward on their next password
      // change, and for free — the row is being rewritten anyway, so there is
      // no `needsRehash` decision to make.
      await _plantLegacyPbkdf2Row(db, username: 'jon', password: 'hunter2');
      expect((await repo.user('jon'))!.passwordHash, startsWith('pbkdf2'));

      final result = await provider.changePassword(
        username: 'jon',
        currentPassword: 'hunter2',
        newPassword: 'letmein',
      );

      expect(result, PasswordChangeResult.ok);
      expect((await repo.user('jon'))!.passwordHash, startsWith('argon2id'));
      expect(await storedPasswordIs('jon', 'letmein'), isTrue);
    });

    test('burns no dummy derivation — there is no name to enumerate', () async {
      // `authenticate` pays for one on an unknown username so that "no such
      // user" and "wrong password" cost the same. There is nothing to defend
      // here: the username comes from the live session, not from a field
      // anybody can type a guess into.
      await provider.changePassword(
        username: 'ghost',
        currentPassword: 'hunter2',
        newPassword: 'letmein',
      );

      expect(LocalAuthProvider.dummyDerivations, 0);
    });

    test('a new password identical to the old one is allowed', () async {
      // Not a policy decision dressed as a bug fix: refusing it would be a rule
      // nobody wrote down, on a screen whose stated position is that there is
      // no password policy. The row genuinely changes — fresh salt.
      final before = (await repo.user('jon'))!;

      expect(
        await provider.changePassword(
          username: 'jon',
          currentPassword: 'hunter2',
          newPassword: 'hunter2',
        ),
        PasswordChangeResult.ok,
      );

      final after = (await repo.user('jon'))!;
      expect(after.salt, isNot(before.salt));
      expect(await storedPasswordIs('jon', 'hunter2'), isTrue);
    });

    test('is reachable through the capability interface', () async {
      // How the provider layer finds it: `auth is PasswordSelfService`. When
      // OIDC lands behind the same `AuthProvider` seam it will not implement
      // this, and the affordance disappears with no call site edited.
      expect(provider, isA<PasswordSelfService>());
      expect(provider, isA<AuthProvider>());
    });
  });
}

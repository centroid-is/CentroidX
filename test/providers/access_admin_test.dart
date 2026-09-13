// The seam between the admin screen and everything beneath it: the three
// providers that reach `AccessAdminStore`, and the one session method that
// makes the `Operator` warning true of the running app rather than only of the
// `app_role` table.
//
// `ProviderContainer` with overrides over a real in-memory Drift database
// rather than widget tests — this is provider and controller logic and does not
// need a tree.
//
// **Why `refreshGroupsFromRoles` is tested here and not in
// `access_session_test.dart`.** The method exists for the admin feature: the
// roles section's `Operator` banner promises that ticking a group there changes
// what a logged-out panel may do now, and 06-08's users section calls it after
// `setUserRole` and `deleteUser` so an admin cannot demote or delete their own
// account and keep `users`. If the admin surface is ever removed, this
// behaviour and these tests should die with it, which is an argument for
// keeping them beside each other rather than filed under the session.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/core/access_admin_store.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/access_admin.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_repository.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import '../helpers/test_helpers.dart' show useInMemoryDeviceLocalPreferences;

// ---------------------------------------------------------------------------
// Doubles
// ---------------------------------------------------------------------------

/// A stand-in for `LocalAuthProvider` honouring the same null-versus-throw
/// contract: null for an unrecognised credential, a throw for infrastructure.
///
/// It reads the roles out of the map it is handed rather than out of the
/// database, so a test can sign somebody in without paying for PBKDF2 twice.
/// Every test that cares about the `app_user` row creates it for real.
class _FakeAuthProvider implements AuthProvider {
  _FakeAuthProvider(this.users);

  final Map<String, ({String password, String roleName})> users;

  @override
  Future<AuthenticatedUser?> authenticate(
      String username, String password) async {
    final cred = users[username];
    if (cred == null || cred.password != password) return null;
    return AuthenticatedUser(username: username, roleName: cred.roleName);
  }
}

/// A sink that keeps every row, so "this call writes no audit row" is an
/// assertion about a list rather than about a silence.
class _RecordingSink implements AuditSink {
  final List<AuditRecord> rows = [];

  @override
  Future<void> record(AuditRecord entry) async => rows.add(entry);
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

const String _kStation = 'test-panel';

/// Everything a test needs to drive the providers and the controller.
class _Harness {
  _Harness({
    required this.container,
    required this.db,
    required this.repository,
    required this.sink,
  });

  final ProviderContainer container;
  final AppDatabase db;
  final AccessRepository repository;
  final _RecordingSink sink;

  AccessSessionController get notifier =>
      container.read(accessSessionProvider.notifier);

  AccessSession? get session =>
      container.read(accessSessionProvider).valueOrNull;

  Future<AccessSession> settle() =>
      container.read(accessSessionProvider.future);

  Future<String?> storedPayload() =>
      container.read(localPreferencesProvider).getString(kAccessSessionPrefKey);
}

Future<_Harness> _harness({
  bool withDatabase = true,
  Map<String, ({String password, String roleName})>? users,
}) async {
  final db = AppDatabase.inMemoryForTest();
  addTearDown(() => db.close());
  // Force the migration, so the four seeded roles exist before anything asks
  // for them.
  await db.customSelect('SELECT 1').getSingle();

  final repository = AccessRepository(db);
  final auth = _FakeAuthProvider(users ??
      {
        'jon': (password: 'correct horse', roleName: 'Engineering'),
        'sigga': (password: 'hunter2', roleName: 'Shift Leader'),
      });
  final sink = _RecordingSink();

  final container = ProviderContainer(overrides: [
    accessRepositoryProvider
        .overrideWith((ref) async => withDatabase ? repository : null),
    authProviderProvider
        .overrideWith((ref) async => withDatabase ? auth : null),
    auditSinkProvider.overrideWith((ref) async => sink),
    stationNameProvider.overrideWithValue(_kStation),
  ]);
  addTearDown(container.dispose);

  return _Harness(
    container: container,
    db: db,
    repository: repository,
    sink: sink,
  );
}

/// The `Operator` role with [groups] instead of whatever it holds today.
AccessRole _operatorWith(Set<AccessGroup> groups) => AccessRole(
      name: kOperatorRoleName,
      groups: groups,
      seeded: true,
    );

void main() {
  setUp(() {
    useInMemoryDeviceLocalPreferences();
    // The device-local store the session persists into. In memory, and fresh
    // per test, so one test's stored payload cannot restore into the next.
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    DatabaseConfig.clearPrefsCache();
    // PBKDF2 at production iterations is the better part of a second per
    // account, and several tests here create real rows.
    Pbkdf2Kdf.iterationsForTest = 10;
  });

  tearDown(() => Pbkdf2Kdf.iterationsForTest = null);

  // -------------------------------------------------------------------------
  // The store provider
  // -------------------------------------------------------------------------

  group('accessAdminStoreProvider', () {
    test('is null when the station has no database', () async {
      final h = await _harness(withDatabase: false);
      expect(
        await h.container.read(accessAdminStoreProvider.future),
        isNull,
        reason: 'a station commissioned without Postgres has no roles and no '
            'accounts to administer, and that is a normal state rather than an '
            'error — the same null-is-normal shape accessRepositoryProvider '
            'already has',
      );
    });

    test('is a store when there is one', () async {
      final h = await _harness();
      expect(await h.container.read(accessAdminStoreProvider.future),
          isA<AccessAdminStore>());
    });

    test('is one instance for the life of the container', () async {
      final h = await _harness();
      final first = await h.container.read(accessAdminStoreProvider.future);
      final second = await h.container.read(accessAdminStoreProvider.future);
      expect(identical(first, second), isTrue);
    });

    test('survives a sign-in and a sign-out', () async {
      final h = await _harness();
      await h.settle();
      final before = await h.container.read(accessAdminStoreProvider.future);

      final result = await h.notifier.signIn('jon', 'correct horse');
      expect(result, AccessSignInResult.ok);
      final afterSignIn =
          await h.container.read(accessAdminStoreProvider.future);
      expect(
        identical(before, afterSignIn),
        isTrue,
        reason: 'T-04-30: the session must reach this store as a callback. A '
            'ref.watch of the session here would rebuild the provider — and '
            'with it the database handle it holds — on every sign-in, '
            'sign-out and inactivity timeout',
      );

      await h.notifier.signOut();
      final afterSignOut =
          await h.container.read(accessAdminStoreProvider.future);
      expect(identical(before, afterSignOut), isTrue,
          reason: 'T-04-30, the other edge of the same rule');
    });

    test('hands the store the session in force at call time, not at build time',
        () async {
      final h = await _harness();
      await h.settle();
      final store = await h.container.read(accessAdminStoreProvider.future);

      // Built while anonymous: the gate refuses.
      await expectLater(
        store!.createRole(const AccessRole(name: 'Cleaning', groups: {})),
        throwsA(isA<AccessDenied>()),
      );

      // The same store instance, after a sign-in that grants `users`.
      await h.notifier.signIn('jon', 'correct horse');
      await store.createRole(const AccessRole(name: 'Cleaning', groups: {}));
      expect(
        (await h.repository.role('Cleaning')), isNotNull,
        reason: 'the callback resolves the session per call, so the store the '
            'sign-in did not rebuild is nevertheless the one that now permits '
            'the write',
      );
    });
  });

  // -------------------------------------------------------------------------
  // The two list providers
  // -------------------------------------------------------------------------

  group('accessAdminRolesProvider', () {
    test('is the seeded roles', () async {
      final h = await _harness();
      final roles = await h.container.read(accessAdminRolesProvider.future);
      expect(roles.map((r) => r.name), containsAll(kSeedRoles.map((r) => r.name)));
    });

    test('is empty rather than a throw when the station has no database',
        () async {
      final h = await _harness(withDatabase: false);
      expect(
        await h.container.read(accessAdminRolesProvider.future),
        isEmpty,
        reason: 'the page renders the terminal state; a missing database is '
            'not an exception for this list to raise',
      );
    });

    test('re-reads after an invalidation, which is the only refresh there is',
        () async {
      final h = await _harness();
      await h.settle();
      expect(await h.container.read(accessAdminRolesProvider.future),
          isNot(contains(predicate<AccessRole>((r) => r.name == 'Cleaning'))));

      await h.repository.upsertRole(const AccessRole(
        name: 'Cleaning',
        groups: {AccessGroup.operate},
      ));
      h.container.invalidate(accessAdminRolesProvider);

      expect(
        (await h.container.read(accessAdminRolesProvider.future))
            .map((r) => r.name),
        contains('Cleaning'),
      );
    });
  });

  group('accessAdminUsersProvider', () {
    test('lists the accounts', () async {
      final h = await _harness();
      await h.repository.createUser(
        username: 'jon',
        password: 'correct horse',
        roleName: 'Engineering',
      );
      expect(
        (await h.container.read(accessAdminUsersProvider.future))
            .map((u) => u.username),
        ['jon'],
      );
    });

    test('is empty rather than a throw when the station has no database',
        () async {
      final h = await _harness(withDatabase: false);
      expect(await h.container.read(accessAdminUsersProvider.future), isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // refreshGroupsFromRoles — the anonymous arm
  // -------------------------------------------------------------------------

  group('refreshGroupsFromRoles, anonymous', () {
    test('an Operator widening reaches a logged-out panel without a sign-out',
        () async {
      final h = await _harness();
      final before = await h.settle();
      expect(before.can(AccessGroup.setpoints), isFalse);

      await h.repository.upsertRole(_operatorWith(
        {AccessGroup.operate, AccessGroup.setpoints},
      ));
      await h.notifier.refreshGroupsFromRoles();

      expect(
        h.session!.can(AccessGroup.setpoints),
        isTrue,
        reason: 'T-06-30: the roles section warns that ticking a group on '
            'Operator grants it to every logged-out panel on the floor. '
            'Without this the warning is a promise the app does not keep until '
            'something else happens to rebuild the session',
      );
      expect(h.session!.isElevated, isFalse);
    });

    test('writes no audit row', () async {
      final h = await _harness();
      await h.settle();
      h.sink.rows.clear();

      await h.repository.upsertRole(_operatorWith(
        {AccessGroup.operate, AccessGroup.setpoints},
      ));
      await h.notifier.refreshGroupsFromRoles();

      expect(
        h.sink.rows,
        isEmpty,
        reason: 'T-06-33: re-resolving groups is not an authentication event. '
            'The four auth itemKeys are login, login_failed, logout and '
            'session_timeout, and this is none of them — the role write itself '
            'is already audited by AccessAdminStore as role.update',
      );
    });

    test('is survivable and terminal when the station has no database',
        () async {
      final h = await _harness(withDatabase: false);
      await h.settle();
      await h.notifier.refreshGroupsFromRoles();
      expect(h.session!.isElevated, isFalse);
      expect(h.session!.can(AccessGroup.operate), isTrue,
          reason: 'the seeded Operator floor: a logged-out panel that cannot '
              'jog a conveyor because Postgres blinked is a stopped line');
    });
  });

  // -------------------------------------------------------------------------
  // refreshGroupsFromRoles — the elevated arm
  // -------------------------------------------------------------------------

  group('refreshGroupsFromRoles, elevated', () {
    /// Signs `jon` in against a real `app_user` row in [roleName].
    Future<_Harness> elevated({String roleName = 'Engineering'}) async {
      final h = await _harness();
      await h.settle();
      await h.repository.createUser(
        username: 'jon',
        password: 'correct horse',
        roleName: roleName,
      );
      expect(await h.notifier.signIn('jon', 'correct horse'),
          AccessSignInResult.ok);
      return h;
    }

    /// A second account holding `users`, so the lockout guard permits a
    /// self-demotion or a self-delete. That the guard permits it at all is
    /// CONTEXT's invariant, not an oversight: the rule is "at least one account
    /// holds a role granting users", not "you may not edit yourself".
    Future<void> secondUsersHolder(_Harness h) => h.repository.createUser(
          username: 'admin',
          password: 'a second holder',
          roleName: 'Engineering',
        );

    test('a widening of the signed-in role is picked up', () async {
      final h = await _harness();
      await h.settle();
      await h.repository.createUser(
        username: 'sigga',
        password: 'hunter2',
        roleName: 'Shift Leader',
      );
      await h.notifier.signIn('sigga', 'hunter2');
      expect(h.session!.can(AccessGroup.force), isFalse);

      await h.repository.upsertRole(const AccessRole(
        name: 'Shift Leader',
        groups: {AccessGroup.operate, AccessGroup.setpoints, AccessGroup.force},
        seeded: true,
      ));
      await h.notifier.refreshGroupsFromRoles();

      expect(h.session!.can(AccessGroup.force), isTrue);
      expect(h.session!.isElevated, isTrue);
    });

    test('leaves expiresAt untouched', () async {
      final h = await elevated();
      final before = h.session!.expiresAt;
      expect(before, isNotNull);

      await h.repository.upsertRole(_operatorWith(
        {AccessGroup.operate, AccessGroup.setpoints},
      ));
      await h.notifier.refreshGroupsFromRoles();

      expect(
        h.session!.expiresAt,
        before,
        reason: 'T-06-32: an admin re-saving a role in another tab is not the '
            'signed-in operator touching the panel. Extending the countdown '
            'here would be an inactivity timeout that does not time out',
      );
    });

    test('a deleted role drops the session to anonymous', () async {
      final h = await _harness(users: {
        'birna': (password: 'a password', roleName: 'Cleaning'),
      });
      await h.settle();
      await h.repository.upsertRole(const AccessRole(
        name: 'Cleaning',
        groups: {AccessGroup.operate, AccessGroup.device},
      ));
      await h.repository.createUser(
        username: 'birna',
        password: 'a password',
        roleName: 'Cleaning',
      );
      await h.notifier.signIn('birna', 'a password');
      expect(h.session!.can(AccessGroup.device), isTrue);

      // The account goes first, so deleting the role is not blocked by
      // RoleInUseException — the role is what this test takes away.
      await h.repository.deleteUser('birna');
      await h.repository.deleteRole('Cleaning');
      await h.notifier.refreshGroupsFromRoles();

      expect(
        h.session!.isElevated,
        isFalse,
        reason: 'T-06-31: a session whose role no longer resolves has no group '
            'set to stand on, and leaving it holding the old one is the '
            'privilege-retention hole this method exists to close',
      );
      expect(h.session!.can(AccessGroup.device), isFalse);
    });

    test('a self-demotion is read off the app_user row, not the cached role '
        'name', () async {
      final h = await elevated();
      expect(h.session!.can(AccessGroup.users), isTrue);

      await secondUsersHolder(h);
      await h.repository.setRole('jon', 'Shift Leader');
      await h.notifier.refreshGroupsFromRoles();

      expect(
        h.session!.can(AccessGroup.users),
        isFalse,
        reason: 'T-06-37: resolving the session\'s own cached roleName would '
            'answer Engineering — the value the demotion just wrote over — so '
            'the method would silently fail in the one case it exists for. '
            'The app_user row is re-read first, and that row\'s role is what '
            'is resolved',
      );
      expect(h.session!.roleName, 'Shift Leader');
      expect(h.session!.isElevated, isTrue);
    });

    test('a self-delete drops to anonymous and leaves no stored session behind',
        () async {
      final h = await elevated();
      await secondUsersHolder(h);
      expect(await h.storedPayload(), isNotNull);

      await h.repository.deleteUser('jon');
      await h.notifier.refreshGroupsFromRoles();

      expect(
        h.session!.isElevated,
        isFalse,
        reason: 'T-06-37: an account that no longer exists is not an elevated '
            'session, and leaving it holding users is the hole',
      );
      expect(h.session!.user, isNull);
      expect(h.session!.can(AccessGroup.users), isFalse);
      expect(h.session!.groups, await h.repository.anonymousGroups());
      expect(
        await h.storedPayload(),
        isNull,
        reason: 'the in-memory drop alone does not survive a restart: '
            '_restoreOrAnonymous resolves the stored payload\'s role name and '
            'never consults app_user, so a payload left behind would restore '
            'the deleted account elevated on any start inside the remaining '
            'window',
      );

      // The restart, driven the way the app reaches it: a fresh controller over
      // the same device-local store.
      final restored = await _restart(h);
      expect(restored.isElevated, isFalse,
          reason: 'the restart window is what the cleared payload closes');
    });

    test('a self-demotion re-persists the new role name at the same expiry',
        () async {
      final h = await elevated();
      final expiry = h.session!.expiresAt;

      await secondUsersHolder(h);
      await h.repository.setRole('jon', 'Shift Leader');
      await h.notifier.refreshGroupsFromRoles();

      final stored = AccessSession.parse((await h.storedPayload())!);
      expect(stored, isNotNull);
      expect(
        stored!.roleName,
        'Shift Leader',
        reason: 'T-06-37, the demotion arm: the session stays elevated, so no '
            'drop route fires and nothing clears the payload. A stored copy '
            'still naming Engineering would restore the wider groups the '
            'demotion just removed, on any start inside the remaining window',
      );
      expect(stored.expiresAt, expiry,
          reason: 'this rewrites the role, not the clock');

      final restored = await _restart(h);
      expect(restored.isElevated, isTrue);
      expect(restored.roleName, 'Shift Leader');
      expect(restored.can(AccessGroup.users), isFalse);
    });

    test('a drop route detaches the countdown, so the next sign-in arms a '
        'fresh one', () async {
      final h = await _harness();
      final sub = h.container.listen<AsyncValue<AccessSession>>(
        accessSessionProvider,
        (_, __) {},
      );
      addTearDown(sub.close);
      await h.settle();

      await h.repository.createUser(
        username: 'jon',
        password: 'correct horse',
        roleName: 'Engineering',
      );
      await secondUsersHolder(h);
      await h.notifier.signIn('jon', 'correct horse');
      expect(h.notifier.timerIsRunning, isTrue);

      await h.repository.deleteUser('jon');
      await h.notifier.refreshGroupsFromRoles();
      expect(h.notifier.timerIsRunning, isFalse);

      await h.repository.createUser(
        username: 'sigga',
        password: 'hunter2',
        roleName: 'Shift Leader',
      );
      await h.notifier.signIn('sigga', 'hunter2');
      expect(
        h.notifier.timerIsRunning,
        isTrue,
        reason: '_attach early-returns at `if (_expiry != null)`, so without '
            'the _detach on the drop route the new operator would inherit the '
            'dropped session\'s leftover remainder instead of a fresh '
            'countdown, and would be signed out early on somebody else\'s '
            'clock',
      );
    });
  });
}

/// A restart: a second container over the same repository and the same
/// device-local store, resolving its session through `_restoreOrAnonymous`.
///
/// This is the honest route to the restore path — asserting only on the
/// absence of the preference key would test the clear, not the thing the clear
/// is for.
Future<AccessSession> _restart(_Harness h) async {
  final container = ProviderContainer(overrides: [
    accessRepositoryProvider.overrideWith((ref) async => h.repository),
    auditSinkProvider.overrideWith((ref) async => h.sink),
    stationNameProvider.overrideWithValue(_kStation),
  ]);
  addTearDown(container.dispose);
  return container.read(accessSessionProvider.future);
}

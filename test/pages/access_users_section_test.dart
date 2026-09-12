/// The administration page's users section (spec §1, 06-CONTEXT "Users
/// Screen").
///
/// 06-03's store already drives every user write through a `configure`-only
/// session and reads the rows back from `app_user`, so the claims here are the
/// ones only a rendered screen can make:
///
///  * the four terminal states cannot render as each other — "still loading",
///    "the store errored", "this station has no database" and "the list came
///    back empty" are four different sentences and only one of them is ever
///    true, and the empty one says the first-user window is still open rather
///    than "no users",
///  * the row shows the four columns `AppUser` actually has — username, role,
///    created, last login — and a null last login renders as a word rather
///    than as a blank cell that reads like a rendering bug,
///  * a session without `users` sees every control, may press every one of
///    them, and reaches the shared `AccessDeniedPrompt` — nothing is greyed,
///  * both lockout routes that run through this table are refused *inline*,
///    with the holders counted and named, and no override anywhere,
///  * an admin who demotes or deletes **their own** account loses what it gave
///    them immediately, with no sign-out anywhere in the test,
///  * deleting an account leaves its audit rows alone.
///
/// The store is real, over a real in-memory database, so "the account was
/// deleted" is read back from `app_user` rather than from a mock's call log.
/// The recording subclass exists for the two claims a table cannot answer:
/// which methods the section reached for, and what happens when a write throws
/// something the tables would never produce.
///
/// **Two sessions, on purpose.** The store's gate reads the `session` variable
/// below; `accessSessionProvider` is the real controller and stays anonymous
/// unless a test signs in. On a station those are the same session. Splitting
/// them here is what lets most tests exercise a permitted write without
/// standing up an elevated session — and the two self-privilege tests, which
/// *do* need the real controller, sign in and then make their claim without a
/// sign-out.
library;

import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/core/access_admin_store.dart';
import 'package:tfc/pages/access_users_section.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/access_admin.dart';
import 'package:tfc/providers/access_policy.dart';
import 'package:tfc/widgets/access_admin_notice.dart';
import 'package:tfc/widgets/access_denied_prompt.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_repository.dart';
import 'package:tfc_dart/core/access/local_auth_provider.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';

// ---------------------------------------------------------------------------
// Doubles
// ---------------------------------------------------------------------------

/// A stand-in for `LocalAuthProvider` honouring the same null-versus-throw
/// contract. Only the tests that sign somebody in reach it.
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

class _RecordingSink implements AuditSink {
  final List<AuditRecord> rows = [];

  @override
  Future<void> record(AuditRecord entry) async => rows.add(entry);
}

/// The real store, over the real tables, with a call log.
///
/// Subclassed rather than faked, for the reason
/// `access_templates_section_test.dart` gives: what *happened* is read back
/// from the tables, and only "which methods did the section reach for" needs a
/// log.
class _RecordingStore extends AccessAdminStore {
  _RecordingStore({
    required super.repository,
    required super.session,
    required super.audit,
    required super.station,
    super.onDenied,
  });

  final List<String> calls = [];

  /// What the next `deleteUser` throws instead of deleting, once.
  ///
  /// The only way to stage a refusal the tables cannot produce — see the
  /// multi-holder count test, which explains why routes (a) and (b) can never
  /// name more than one holder on their own.
  Object? deleteThrowsOnce;

  /// What the next `setUserRole` throws instead of moving, once.
  Object? setRoleThrowsOnce;

  /// What the next `createUser` throws instead of inserting, once.
  ///
  /// The never-render-the-exception test stages a message carrying something
  /// that looks like a credential, which nothing real would produce — 06-02
  /// made the repository's `ArgumentError` deliberately bare for that reason.
  /// Defence in depth is the claim, so the threat has to be simulated.
  Object? createThrowsOnce;

  /// What the next `setUserPassword` throws instead of writing, once.
  Object? setPasswordThrowsOnce;

  /// Held open, a credential-bearing write never comes back — the only
  /// deterministic way to observe the busy state, which at test iteration
  /// counts is otherwise a microtask wide.
  Completer<void>? holdWrites;

  Future<void> _hold() async {
    final hold = holdWrites;
    if (hold != null) await hold.future;
  }

  @override
  Future<void> createUser({
    required String username,
    required String password,
    required String roleName,
    List<String> additionalRoles = const <String>[],
    String origin = 'operator',
    String? reason,
  }) async {
    calls.add('createUser:$username:${[roleName, ...additionalRoles].join('+')}');
    await _hold();
    final boom = createThrowsOnce;
    if (boom != null) {
      createThrowsOnce = null;
      throw boom;
    }
    return super.createUser(
        username: username,
        password: password,
        roleName: roleName,
        additionalRoles: additionalRoles,
        origin: origin,
        reason: reason);
  }

  @override
  Future<void> setUserPassword(String username, String password,
      {String origin = 'operator', String? reason}) async {
    calls.add('setUserPassword:$username');
    await _hold();
    final boom = setPasswordThrowsOnce;
    if (boom != null) {
      setPasswordThrowsOnce = null;
      throw boom;
    }
    return super.setUserPassword(username, password,
        origin: origin, reason: reason);
  }

  @override
  Future<List<AccessRole>> roles() {
    calls.add('roles');
    return super.roles();
  }

  @override
  Future<List<AppUserData>> listUsers() {
    calls.add('listUsers');
    return super.listUsers();
  }

  @override
  Future<void> deleteUser(String username,
      {String origin = 'operator', String? reason}) async {
    calls.add('deleteUser:$username');
    final boom = deleteThrowsOnce;
    if (boom != null) {
      deleteThrowsOnce = null;
      throw boom;
    }
    return super.deleteUser(username, origin: origin, reason: reason);
  }

  @override
  Future<void> setUserStationAccount(String username, bool value,
      {String origin = 'operator', String? reason}) async {
    calls.add('setUserStationAccount:$username:$value');
    return super.setUserStationAccount(username, value,
        origin: origin, reason: reason);
  }

  @override
  Future<void> setUserInactivityTimeout(String username, int? minutes,
      {String origin = 'operator', String? reason}) async {
    calls.add('setUserInactivityTimeout:$username:$minutes');
    return super.setUserInactivityTimeout(username, minutes,
        origin: origin, reason: reason);
  }

  @override
  Future<void> setUserRoles(String username, List<String> roleNames,
      {String origin = 'operator', String? reason}) async {
    calls.add('setUserRole:$username:${roleNames.join('+')}');
    final boom = setRoleThrowsOnce;
    if (boom != null) {
      setRoleThrowsOnce = null;
      throw boom;
    }
    return super.setUserRoles(username, roleNames,
        origin: origin, reason: reason);
  }
}

/// The `users` gate the composed page puts over this section, in miniature.
///
/// Only the part that matters to the two self-privilege claims: when the
/// session in force loses `users`, the subtree is swapped out and the section
/// is disposed. `AccessGate` itself brings a locked page, its own scaffold and
/// a sign-in opener, none of which those claims need — and standing all of that
/// up would make the test about the gate rather than about what runs after the
/// await.
class _UsersGate extends ConsumerWidget {
  const _UsersGate({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(accessSessionProvider).valueOrNull;
    if (session == null || !session.can(AccessGroup.users)) {
      return const Text('locked');
    }
    return child;
  }
}

// ---------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------

/// The engineer the `users` gate exists for: they may edit a page and must not
/// be able to re-scope who may write what. Spec §1 separates `users` from
/// `configure` for exactly this person.
AccessSession _configureOnly() => const AccessSession(
      user: AuthenticatedUser(username: 'engineer', roleName: 'Engineering'),
      groups: {
        AccessGroup.operate,
        AccessGroup.setpoints,
        AccessGroup.device,
        AccessGroup.configure,
      },
    );

AccessSession _withUsers() => const AccessSession(
      user: AuthenticatedUser(username: 'admin', roleName: 'Engineering'),
      groups: {AccessGroup.operate, AccessGroup.configure, AccessGroup.users},
    );

const String _kStation = 'SVN-NES-OT-CL02';

void main() {
  late AppDatabase db;
  late AccessRepository repository;
  late _RecordingSink sink;
  late AccessSession session;
  late _FakeAuthProvider auth;
  _RecordingStore? store;
  ProviderContainer? container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    DatabaseConfig.clearPrefsCache();
    // A production-strength derivation is the better part of a second per
    // account, and nearly every test here creates real rows. The one test that
    // needs a derivation to actually take time raises this for itself rather
    // than clearing it.
    Pbkdf2Kdf.iterationsForTest = 10;

    db = AppDatabase.inMemoryForTest();
    // Force the migration, so the four seeded roles exist before anything asks
    // for them.
    await db.customSelect('SELECT 1').getSingle();
    repository = AccessRepository(db);
    sink = _RecordingSink();
    session = _withUsers();
    auth = _FakeAuthProvider({
      'admin': (password: 'correct horse', roleName: 'Engineering'),
      'keeper': (password: 'correct horse', roleName: 'Engineering'),
    });
    store = null;
    container = null;
  });

  tearDown(() async {
    Pbkdf2Kdf.iterationsForTest = null;
    await db.close();
  });

  /// The same wiring the real providers do. `accessRepositoryProvider` is
  /// shared by the store and by `AccessSessionController`, which is what makes
  /// `refreshGroupsFromRoles` observe the row the section just wrote.
  List<Override> overrides({
    bool noDatabase = false,
    Object? storeError,
    bool storeNeverResolves = false,
    Future<List<AccessRole>>? roles,
  }) =>
      [
        accessRepositoryProvider.overrideWith((ref) async => repository),
        authProviderProvider.overrideWith((ref) async => auth),
        auditSinkProvider.overrideWith((ref) async => sink),
        stationNameProvider.overrideWithValue(_kStation),
        accessAdminStoreProvider.overrideWith((ref) async {
          if (storeNeverResolves) {
            return Completer<AccessAdminStore?>().future;
          }
          if (storeError != null) throw storeError;
          if (noDatabase) return null;
          return store = _RecordingStore(
            repository: repository,
            session: () => session,
            audit: sink,
            station: _kStation,
            // Exactly what the real provider does, so a refusal here reaches
            // the shared prompt as it does on a station.
            onDenied: (denial) => reportAccessDenial(ref, denial),
          );
        }),
        // Overridden only where a test needs a roster the seeded database
        // cannot produce — see the role picker.
        if (roles != null) accessAdminRolesProvider.overrideWith((ref) => roles),
      ];

  /// The section on its own, under a real [AccessDeniedPrompt] — the prompt a
  /// refusal has to reach, rather than a listener of the test's own.
  ///
  /// An explicit container rather than a plain `ProviderScope`, so a test can
  /// read the real `accessSessionProvider` and assert what the caller may do
  /// after a write. [gated] additionally puts the section behind the `users`
  /// gate the composed page puts it behind, which is what makes a self-demotion
  /// or a self-delete unmount the widget mid-await.
  Widget host(List<Override> o, {bool gated = false}) {
    final c = ProviderContainer(overrides: o);
    container = c;
    addTearDown(c.dispose);
    return UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        // No splash, for an environment reason rather than a design one: the
        // Material 3 ink sparkle loads `shaders/ink_sparkle.frag`, and on this
        // SDK the bundled asset carries Vulkan stages only — so a tap whose
        // ripple actually animates throws "does not contain appropriate
        // runtime stage data for current backend (SkSL)" and fails the test
        // for something no screen here is about. Nothing in this file asserts
        // a ripple; the goldens live in `access_admin_golden_test.dart`.
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Scaffold(
          body: AccessDeniedPrompt(
            child: SingleChildScrollView(
              child: gated
                  ? const _UsersGate(child: AccessUsersSection())
                  : const AccessUsersSection(),
            ),
          ),
        ),
      ),
    );
  }

  /// Pumps the section on a panel-sized surface.
  ///
  /// The default 800×600 test window cannot fit a four-column row with three
  /// trailing controls plus an open dialog, and a tap on a control laid out
  /// below the fold fails rather than scrolling to it. A station is 1920×1080
  /// and the composed page scrolls; the point of the larger surface is that
  /// these tests are about what the screen says, not about where it wraps.
  /// (06-07 learned this the hard way and its harness says so too.)
  Future<void> pumpSection(
    WidgetTester tester,
    List<Override> o, {
    bool gated = false,
  }) async {
    tester.view.physicalSize = const Size(1400, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(host(o, gated: gated));
    await tester.pumpAndSettle();
  }

  /// The session the real controller currently publishes.
  ///
  /// Through `.future` rather than `.valueOrNull`, because the first read of a
  /// provider nothing has listened to yet lands on `AsyncLoading` — and
  /// `pumpSection` deliberately does not listen to the session unless the test
  /// asked for the gate.
  Future<AccessSession> sessionInForce() =>
      container!.read(accessSessionProvider.future);

  // -------------------------------------------------------------------------
  // The per-account inactivity timeout
  //
  // It used to be one device-local number for the whole panel, with a switch
  // that made every session on that panel immortal. It is an account's own
  // property now, edited here beside the account it governs.
  // -------------------------------------------------------------------------
  group('the inactivity timeout', () {
    Future<void> seedBob({int? minutes, bool stationAccount = false}) async {
      await repository.createUser(
          username: 'bob', password: 'pw', roleName: 'Shift Leader');
      if (minutes != null) {
        await repository.setInactivityTimeout('bob', minutes);
      }
      if (stationAccount) await repository.setStationAccount('bob', true);
    }

    Future<int?> storedMinutes() async => (await repository.listUsers())
        .singleWhere((u) => u.username == 'bob')
        .inactivityTimeoutMinutes;

    testWidgets('the dialog opens seeded with what the account gets, and saves '
        'a new value', (tester) async {
      await seedBob();
      await pumpSection(tester, overrides());

      await tester.tap(find.byKey(kAccessUserTimeoutKey('bob')));
      await tester.pumpAndSettle();

      final field =
          tester.widget<TextField>(find.byKey(kAccessUserTimeoutFieldKey));
      expect(field.controller!.text,
          kDefaultInactivityTimeout.inMinutes.toString(),
          reason: 'an account with no value of its own still gets a window, '
              'and the field opens on the one it is actually getting');

      await tester.enterText(find.byKey(kAccessUserTimeoutFieldKey), '45');
      await tester.tap(find.byKey(kAccessUserTimeoutSaveKey));
      await tester.pumpAndSettle();

      expect(await storedMinutes(), 45);
      expect(store!.calls, contains('setUserInactivityTimeout:bob:45'));
    });

    testWidgets('"Use default" clears the account\'s own value',
        (tester) async {
      await seedBob(minutes: 45);
      await pumpSection(tester, overrides());

      await tester.tap(find.byKey(kAccessUserTimeoutKey('bob')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAccessUserTimeoutDefaultKey));
      await tester.pumpAndSettle();

      expect(await storedMinutes(), isNull,
          reason: 'null is the account following the default, which is a '
              'different state from any number it could be given');
    });

    testWidgets('an account already on the default is not offered "Use '
        'default"', (tester) async {
      await seedBob();
      await pumpSection(tester, overrides());

      await tester.tap(find.byKey(kAccessUserTimeoutKey('bob')));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessUserTimeoutDefaultKey), findsNothing,
          reason: 'it would be a button that does nothing');
    });

    testWidgets('out-of-range input refuses, says the range, and writes '
        'nothing', (tester) async {
      await seedBob();
      await pumpSection(tester, overrides());

      await tester.tap(find.byKey(kAccessUserTimeoutKey('bob')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(kAccessUserTimeoutFieldKey), '0');
      await tester.tap(find.byKey(kAccessUserTimeoutSaveKey));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessUserTimeoutRangeKey), findsOneWidget);
      expect(find.byKey(kAccessUserTimeoutFieldKey), findsOneWidget,
          reason: 'the dialog stays open so the number can be corrected');
      expect(await storedMinutes(), isNull);
      expect(store!.calls, isNot(contains(startsWith('setUserInactivityTimeout'))));
    });

    testWidgets('the row tags an account that has a window of its own',
        (tester) async {
      await seedBob(minutes: 45);
      await pumpSection(tester, overrides());

      expect(find.byKey(kAccessUserTimeoutTagKey('bob')), findsOneWidget);
      expect(find.text(kAccessUserTimeoutTag(45)), findsOneWidget);
    });

    testWidgets('an account on the default carries no tag', (tester) async {
      await seedBob();
      await pumpSection(tester, overrides());

      expect(find.byKey(kAccessUserTimeoutTagKey('bob')), findsNothing);
    });

    testWidgets('a station account has no timeout to set', (tester) async {
      // Disabled because the setting does not apply — its sessions never
      // expire — and not for lack of a permission, which this screen never
      // greys anything for. The tooltip is what says which.
      await seedBob(minutes: 45, stationAccount: true);
      await pumpSection(tester, overrides());

      final button =
          tester.widget<IconButton>(find.byKey(kAccessUserTimeoutKey('bob')));
      expect(button.onPressed, isNull);
      expect(button.tooltip, kAccessUserTimeoutStationTooltip);
      expect(find.byKey(kAccessUserTimeoutTagKey('bob')), findsNothing,
          reason: 'a stored number governs nothing while the flag is set, so '
              'showing it beside the role would only mislead');
    });
  });

  /// Signs [username] in on the **real** controller, so the session in force is
  /// elevated and the `users` gate above the section is open.
  Future<void> signIn(WidgetTester tester, String username) async {
    final result = await container!
        .read(accessSessionProvider.notifier)
        .signIn(username, 'correct horse');
    expect(result, AccessSignInResult.ok);
    await tester.pumpAndSettle();
  }

  /// Cleanup, never part of a claim: an elevated session arms the inactivity
  /// monitor, and a timer still pending when the test body ends fails a widget
  /// test on its way out. Every call sits *after* the assertions it follows.
  Future<void> signOut(WidgetTester tester) async {
    await container!.read(accessSessionProvider.notifier).signOut();
    await tester.pumpAndSettle();
  }

  Future<void> makeUser(String username, String roleName) =>
      repository.createUser(
        username: username,
        password: 'correct horse',
        roleName: roleName,
      );

  Future<AppUserData?> userNamed(String username) => repository.user(username);

  /// The text a keyed cell renders.
  String cell(WidgetTester tester, Key key) =>
      tester.widget<Text>(find.byKey(key)).data!;

  /// Opens the change-role dialog for [username].
  Future<void> openRolePicker(WidgetTester tester, String username) async {
    await tester.tap(find.byKey(kAccessUserChangeRoleKey(username)));
    await tester.pumpAndSettle();
  }

  /// Opens the create dialog.
  Future<void> openCreate(WidgetTester tester) async {
    await tester.tap(find.byKey(kAccessUsersCreateKey));
    await tester.pumpAndSettle();
  }

  /// Opens the set-password dialog for [username].
  Future<void> openSetPassword(WidgetTester tester, String username) async {
    await tester.tap(find.byKey(kAccessUserSetPasswordKey(username)));
    await tester.pumpAndSettle();
  }

  /// Fills the create dialog's three fields.
  Future<void> fillCreate(
    WidgetTester tester, {
    required String username,
    required String password,
    String? confirm,
  }) async {
    await tester.enterText(find.byKey(kAccessUserUsernameFieldKey), username);
    await tester.enterText(find.byKey(kAccessUserPasswordFieldKey), password);
    await tester.enterText(
        find.byKey(kAccessUserConfirmFieldKey), confirm ?? password);
    await tester.pump();
  }

  /// Whether [needle] appears in the text of anything rendered, obscured field
  /// contents included.
  ///
  /// `find.textContaining` matches an `EditableText` by its controller's text
  /// as well as a `Text` by its data, which is exactly the reach this claim
  /// needs: a password must not turn up in a rendered sentence *or* be quietly
  /// pushed back into a field.
  bool treeMentions(WidgetTester tester, String needle) =>
      find.textContaining(needle).evaluate().isNotEmpty;

  /// The real verifier, so "the password was changed" is answered by signing in
  /// rather than by reading a column.
  AuthProvider realAuth() => LocalAuthProvider(repository);

  /// One hand-made audit row naming [who], written straight into the table.
  ///
  /// Raw drift rather than the store's sink, because the claim is about the
  /// *table* surviving a delete: `audit_entry.who` is a denormalised TEXT
  /// column with no foreign key, and the row has to be in the database for its
  /// survival to mean anything.
  Future<void> auditRowFor(String who, String itemKey) =>
      db.into(db.auditEntry).insert(AuditEntryCompanion.insert(
            at: DateTime.now().toUtc(),
            who: who,
            station: _kStation,
            roleName: 'Shift Leader',
            surface: 'tag',
            itemKey: itemKey,
            groupRequired: 'setpoints',
            allowed: true,
            actionId: 'action-$who-$itemKey',
            newValue: const Value('12.5'),
          ));

  Future<List<AuditEntryData>> auditRowsFor(String who) =>
      (db.select(db.auditEntry)..where((t) => t.who.equals(who))).get();

  // -------------------------------------------------------------------------
  // The four terminal states
  // -------------------------------------------------------------------------

  group('the four terminal states', () {
    testWidgets('still loading renders nothing — not a spinner that flashes',
        (tester) async {
      await pumpSection(tester, overrides(storeNeverResolves: true));

      expect(find.byKey(kAccessUsersSectionKey), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: 'this is one section on a page; the page owns the spinner, '
              'and a spinner that appears for a frame on every station is the '
              'flash AccessLockBadge refuses to draw');
      expect(find.byKey(kAccessUsersUnavailableKey), findsNothing);
      expect(find.byKey(kAccessUsersNoDatabaseKey), findsNothing);
      expect(find.byKey(kAccessUsersEmptyKey), findsNothing);
    });

    testWidgets('the store errored says the roster is untrustworthy',
        (tester) async {
      await pumpSection(
          tester, overrides(storeError: StateError('no connection')));

      expect(find.byKey(kAccessUsersUnavailableKey), findsOneWidget);
      expect(find.text(kAccessUsersUnavailableNote), findsOneWidget);
      expect(find.byKey(kAccessUsersNoDatabaseKey), findsNothing);
      expect(find.byKey(kAccessUsersEmptyKey), findsNothing);
    });

    testWidgets('no database says why, rather than showing an empty roster',
        (tester) async {
      await pumpSection(tester, overrides(noDatabase: true));

      expect(find.byKey(kAccessUsersNoDatabaseKey), findsOneWidget);
      expect(find.text(kAccessUsersNoDatabaseNote), findsOneWidget);
      expect(find.byKey(kAccessUsersEmptyKey), findsNothing,
          reason: '"there are no accounts" is a different claim from "this '
              'station cannot tell you", and only one of them is true here');
    });

    testWidgets('an empty roster says the first-user window is still open',
        (tester) async {
      // The real loader produces this one: the migration seeds roles and not
      // users, so a freshly migrated station has an empty app_user.
      await pumpSection(tester, overrides());

      expect(find.byKey(kAccessUsersEmptyKey), findsOneWidget);
      expect(find.text(kAccessUsersEmptyNote), findsOneWidget);
      expect(
        kAccessUsersEmptyNote,
        contains('first-user window'),
        reason: 'on a commissioned station an empty app_user means the '
            'first-account screen is claimable by whoever reaches it first, '
            'which is a different and much more urgent fact than "no users"',
      );
      expect(find.byKey(kAccessUsersNoDatabaseKey), findsNothing);
      expect(find.byKey(kAccessUsersUnavailableKey), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  // The four columns — all four of them real columns on AppUser
  // -------------------------------------------------------------------------

  group('the four columns', () {
    testWidgets('username, role, created and last login, and nothing else',
        (tester) async {
      await makeUser('bjorn', 'Shift Leader');
      final at = DateTime.utc(2026, 3, 4, 5, 6);
      await repository.touchLastLogin('bjorn', at);

      await pumpSection(tester, overrides());

      expect(find.byKey(kAccessUsersHeaderKey), findsOneWidget);
      expect(find.text(kAccessUsersColumnUsername), findsOneWidget);
      expect(find.text(kAccessUsersColumnRole), findsOneWidget);
      expect(find.text(kAccessUsersColumnCreated), findsOneWidget);
      expect(find.text(kAccessUsersColumnLastLogin), findsOneWidget);

      expect(cell(tester, kAccessUserNameKey('bjorn')), 'bjorn');
      expect(cell(tester, kAccessUserRoleKey('bjorn')), 'Shift Leader');
      final row = (await userNamed('bjorn'))!;
      expect(cell(tester, kAccessUserCreatedKey('bjorn')),
          kAccessUserWhen(row.createdAt));
      expect(cell(tester, kAccessUserLastLoginKey('bjorn')),
          kAccessUserWhen(row.lastLoginAt));
      expect(row.lastLoginAt, isNotNull);
    });

    testWidgets('a null lastLoginAt renders as a word, not as an empty cell',
        (tester) async {
      // A freshly created account has never logged in, which is exactly the
      // state worth seeing: a blank cell reads as a rendering bug.
      await makeUser('nyr', 'Shift Leader');
      expect((await userNamed('nyr'))!.lastLoginAt, isNull);

      await pumpSection(tester, overrides());

      expect(cell(tester, kAccessUserLastLoginKey('nyr')), kAccessUserNever);
      expect(cell(tester, kAccessUserLastLoginKey('nyr')), isNotEmpty);
      expect(find.text(kAccessUserNever), findsOneWidget);
    });

    testWidgets('every account gets a row, in the roster order', (tester) async {
      await makeUser('anna', 'Shift Leader');
      await makeUser('bjorn', 'Maintenance');
      await makeUser('cato', 'Engineering');

      await pumpSection(tester, overrides());

      for (final name in ['anna', 'bjorn', 'cato']) {
        expect(find.byKey(kAccessUserRowKey(name)), findsOneWidget);
      }
      expect(cell(tester, kAccessUserRoleKey('cato')), 'Engineering');
    });
  });

  // -------------------------------------------------------------------------
  // Station account
  // -------------------------------------------------------------------------

  group('station account', () {
    testWidgets('the toggle flips the flag through the store and the row '
        'follows', (tester) async {
      await makeUser('freezer', 'Shift Leader');
      await pumpSection(tester, overrides());

      await tester.tap(find.byKey(kAccessUserStationAccountKey('freezer')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(kAccessUserStationAccountConfirmMake));
      await tester.pumpAndSettle();

      expect(store!.calls, contains('setUserStationAccount:freezer:true'));
      // The roster refreshed from the repository, so the row now renders the
      // on-state affordance — the one whose tooltip offers the way back.
      expect(
          tester
              .widget<IconButton>(
                  find.byKey(kAccessUserStationAccountKey('freezer')))
              .tooltip,
          kAccessUserStationAccountOnTooltip);
    });

    testWidgets('cancelling the confirmation writes nothing', (tester) async {
      await makeUser('freezer', 'Shift Leader');
      await pumpSection(tester, overrides());

      await tester.tap(find.byKey(kAccessUserStationAccountKey('freezer')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(
          store!.calls.where((c) => c.startsWith('setUserStationAccount')),
          isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // Change role
  // -------------------------------------------------------------------------

  group('change role', () {
    testWidgets('the picker offers exactly the roles the store returned',
        (tester) async {
      await makeUser('bjorn', 'Shift Leader');
      await pumpSection(
        tester,
        overrides(roles: Future.value(const [
          AccessRole(name: 'Shift Leader', groups: {AccessGroup.operate}),
          AccessRole(name: 'Cleaner', groups: {}),
        ])),
      );

      await openRolePicker(tester, 'bjorn');

      expect(find.byKey(kAccessUserRoleChoiceKey('Shift Leader')),
          findsOneWidget);
      expect(find.byKey(kAccessUserRoleChoiceKey('Cleaner')), findsOneWidget);
      expect(
        find.byKey(kAccessUserRoleChoiceKey('Maintenance')),
        findsNothing,
        reason: 'the picker is built from accessAdminRolesProvider, so it '
            'cannot offer a role that is not there — an account pointing at a '
            'missing role is an orphan the repository would refuse anyway',
      );
      expect(find.byKey(kAccessUserRoleChoiceKey('Engineering')), findsNothing);
    });

    testWidgets('a users session moves an account and the row follows',
        (tester) async {
      await makeUser('bjorn', 'Shift Leader');
      await pumpSection(tester, overrides());

      // A move is now two taps, because the picker is a multi-select: untick
      // what is held, tick what is wanted.
      await openRolePicker(tester, 'bjorn');
      await tester.tap(find.byKey(kAccessUserRoleChoiceKey('Shift Leader')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAccessUserRoleChoiceKey('Maintenance')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAccessUserRoleConfirmKey));
      await tester.pumpAndSettle();

      expect((await userNamed('bjorn'))!.roleName, 'Maintenance');
      expect((await userNamed('bjorn'))!.additionalRoles, isNull,
          reason: 'one role is stored as NULL, not as an empty array — a '
              'single-role account is byte-identical to what v8 wrote');
      expect(cell(tester, kAccessUserRoleKey('bjorn')), 'Maintenance',
          reason: 'the roster is invalidated after every successful write');
      expect(store!.calls.where((c) => c.startsWith('setUserRole')).length, 1);
    });

    testWidgets('a second role is added beside the first, and both are shown',
        (tester) async {
      await makeUser('bjorn', 'Shift Leader');
      await pumpSection(tester, overrides());

      await openRolePicker(tester, 'bjorn');
      await tester.tap(find.byKey(kAccessUserRoleChoiceKey('Maintenance')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAccessUserRoleConfirmKey));
      await tester.pumpAndSettle();

      final row = (await userNamed('bjorn'))!;
      expect(row.roleName, 'Shift Leader',
          reason: 'the role already held stays primary — ticking a second one '
              'must not move role_name onto it');
      expect(decodeAdditionalRoles(row.additionalRoles), ['Maintenance']);
      expect(cell(tester, kAccessUserRoleKey('bjorn')),
          'Shift Leader + Maintenance',
          reason: 'the roster shows every role, so adding one does not read '
              'as a demotion');
    });

    testWidgets('what the account may do is the union of its roles',
        (tester) async {
      // Shift Leader has no `device`; Maintenance does. Holding both must
      // grant it — a second role widens and never narrows.
      await makeUser('bjorn', 'Shift Leader');
      await pumpSection(tester, overrides());

      await openRolePicker(tester, 'bjorn');
      await tester.tap(find.byKey(kAccessUserRoleChoiceKey('Maintenance')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAccessUserRoleConfirmKey));
      await tester.pumpAndSettle();

      final who = await realAuth().authenticate('bjorn', 'correct horse');
      expect(who, isNotNull);
      expect(who!.roleNames, ['Shift Leader', 'Maintenance']);
    });

    testWidgets('unticking everything offers no way to save', (tester) async {
      await makeUser('bjorn', 'Shift Leader');
      await pumpSection(tester, overrides());

      await openRolePicker(tester, 'bjorn');
      await tester.tap(find.byKey(kAccessUserRoleChoiceKey('Shift Leader')));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessUserRoleNoneKey), findsOneWidget,
          reason: 'the disabled confirm is never unexplained');
      await tester.tap(find.byKey(kAccessUserRoleConfirmKey));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessUserRoleConfirmKey), findsOneWidget,
          reason: 'the dialog stays open — an account with no role could not '
              'sign in and the repository refuses it');
      expect(store!.calls.where((c) => c.startsWith('setUserRole')), isEmpty);
    });

    testWidgets('choosing the role already held writes nothing',
        (tester) async {
      await makeUser('bjorn', 'Shift Leader');
      await pumpSection(tester, overrides());

      await openRolePicker(tester, 'bjorn');
      await tester.tap(find.byKey(kAccessUserRoleConfirmKey));
      await tester.pumpAndSettle();

      expect(store!.calls.where((c) => c.startsWith('setUserRole')), isEmpty,
          reason: 'a no-op move would still leave an audit row claiming a '
              'change that did not happen');
    });
  });

  // -------------------------------------------------------------------------
  // Delete, and the trail that outlives the account
  // -------------------------------------------------------------------------

  group('delete', () {
    testWidgets('the confirmation states that the audit history survives',
        (tester) async {
      await makeUser('admin', 'Engineering');
      await makeUser('bjorn', 'Shift Leader');
      await pumpSection(tester, overrides());

      await tester.tap(find.byKey(kAccessUserDeleteKey('bjorn')));
      await tester.pumpAndSettle();

      expect(find.text(kAccessUserDeleteMessage('bjorn')), findsOneWidget);
      expect(
        kAccessUserDeleteMessage('bjorn'),
        contains('audit'),
        reason: '06-CONTEXT: the trail survives by construction, and the '
            "obvious assumption is the opposite — so the dialog says so",
      );
      expect(await userNamed('bjorn'), isNotNull,
          reason: 'nothing is deleted until the confirmation is answered');
    });

    testWidgets('the account goes and its audit rows stay', (tester) async {
      await makeUser('admin', 'Engineering');
      await makeUser('bjorn', 'Shift Leader');
      await auditRowFor('bjorn', 'CN01.MOT01.Freq');
      await auditRowFor('bjorn', 'CN02.MOT01.Freq');
      expect(await auditRowsFor('bjorn'), hasLength(2));

      await pumpSection(tester, overrides());
      await tester.tap(find.byKey(kAccessUserDeleteKey('bjorn')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(kAccessUserDeleteConfirmLabel));
      await tester.pumpAndSettle();

      expect(await userNamed('bjorn'), isNull);
      expect(find.byKey(kAccessUserRowKey('bjorn')), findsNothing);
      expect(
        await auditRowsFor('bjorn'),
        hasLength(2),
        reason: 'audit_entry.who is a denormalised TEXT column with no foreign '
            'key precisely so the trail outlives the account. No cascade may '
            'ever be added, and this is the test that would fail if one were',
      );
    });

    testWidgets('cancelling the confirmation deletes nothing', (tester) async {
      await makeUser('admin', 'Engineering');
      await makeUser('bjorn', 'Shift Leader');
      await pumpSection(tester, overrides());

      await tester.tap(find.byKey(kAccessUserDeleteKey('bjorn')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(await userNamed('bjorn'), isNotNull);
      expect(store!.calls.where((c) => c.startsWith('deleteUser')), isEmpty);
    });

    testWidgets(
        'a configure-only session is refused, reaches the shared prompt, and '
        'the roster is unchanged', (tester) async {
      await makeUser('admin', 'Engineering');
      await makeUser('bjorn', 'Shift Leader');
      session = _configureOnly();
      await pumpSection(tester, overrides());

      final button = tester.widget<IconButton>(
          find.byKey(kAccessUserDeleteKey('bjorn')));
      expect(button.onPressed, isNotNull,
          reason: 'nothing on this section is greyed for lack of a permission '
              '— it is pressed, and then explained');

      await tester.tap(find.byKey(kAccessUserDeleteKey('bjorn')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(kAccessUserDeleteConfirmLabel));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessDeniedBodyKey), findsOneWidget);
      expect(find.text(kAccessDeniedGroupNote(AccessGroup.users)),
          findsOneWidget,
          reason: 'spec §1: somebody who may edit a page must not be able to '
              're-scope who may write what');
      expect(await userNamed('bjorn'), isNotNull);
      expect(find.byKey(kAccessUserRowKey('bjorn')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // The lockout invariant, surfaced rather than re-implemented
  // -------------------------------------------------------------------------

  group('the lockout refusal', () {
    testWidgets(
        'trip route (a): deleting the last users holder is refused inline, '
        'names the holder and states the count, with no snackbar',
        (tester) async {
      await makeUser('admin', 'Engineering');
      await makeUser('bjorn', 'Shift Leader');
      await pumpSection(tester, overrides());

      await tester.tap(find.byKey(kAccessUserDeleteKey('admin')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(kAccessUserDeleteConfirmLabel));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessAdminRefusalKey), findsOneWidget);
      expect(
        find.text(kAccessAdminLastUsersHolderNote('Engineering', 1)),
        findsOneWidget,
        reason: "06-CONTEXT asks for 'the count and names of the holders'; the "
            'exception goes straight to the shared widget so this section '
            'composes no sentence of its own',
      );
      expect(find.byKey(kAccessAdminNoticeNameKey('admin')), findsOneWidget);
      expect(find.text(kAccessAdminBreakGlassNote), findsOneWidget,
          reason: 'there is no override, and there is a documented way back');
      expect(find.byType(SnackBar), findsNothing,
          reason: 'a refusal naming accounts must not be in something that '
              'disappears while it is being read');
      expect(find.byKey(kAccessDeniedBodyKey), findsNothing,
          reason: 'this is not an AccessDenied: the account that hits it '
              'already holds users, so no sign-in resolves it');
      expect(await userNamed('admin'), isNotNull);
    });

    testWidgets(
        'trip route (b): moving the last users holder to a role without users '
        'is refused inline', (tester) async {
      await makeUser('admin', 'Engineering');
      await pumpSection(tester, overrides());

      await openRolePicker(tester, 'admin');
      await tester.tap(find.byKey(kAccessUserRoleChoiceKey('Engineering')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAccessUserRoleChoiceKey('Maintenance')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAccessUserRoleConfirmKey));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessAdminRefusalKey), findsOneWidget);
      expect(find.text(kAccessAdminLastUsersHolderNote('Engineering', 1)),
          findsOneWidget);
      expect(find.byKey(kAccessAdminNoticeNameKey('admin')), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect((await userNamed('admin'))!.roleName, 'Engineering',
          reason: 'the repository refused inside the transaction; the screen '
              'only reports it');
    });

    testWidgets('the refusal states whatever count the exception carried',
        (tester) async {
      // Routes (a) and (b) can never name more than one holder: the guard
      // refuses only when nobody would hold `users` afterwards, and that
      // cannot be true while a second holder is still there. So a count above
      // one is staged rather than provoked — and the point of staging it is to
      // prove this section renders the exception's own count and names rather
      // than a sentence of its own that happens to read "1 account".
      await makeUser('admin', 'Engineering');
      await pumpSection(tester, overrides());
      store!.deleteThrowsOnce = const LastUsersHolderException(
        'Engineering',
        ['admin', 'keeper', 'sigga'],
      );

      await tester.tap(find.byKey(kAccessUserDeleteKey('admin')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(kAccessUserDeleteConfirmLabel));
      await tester.pumpAndSettle();

      expect(find.text(kAccessAdminLastUsersHolderNote('Engineering', 3)),
          findsOneWidget);
      for (final holder in ['admin', 'keeper', 'sigga']) {
        expect(find.byKey(kAccessAdminNoticeNameKey(holder)), findsOneWidget);
      }
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('there is no override anywhere on the refusal', (tester) async {
      await makeUser('admin', 'Engineering');
      await pumpSection(tester, overrides());

      await tester.tap(find.byKey(kAccessUserDeleteKey('admin')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(kAccessUserDeleteConfirmLabel));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
            of: find.byKey(kAccessAdminRefusalKey),
            matching: find.byType(TextField)),
        findsNothing,
        reason: '06-CONTEXT rejects a typed-confirmation lockout override by '
            'name: "no destructive override is offered"',
      );
      expect(
        find.descendant(
            of: find.byKey(kAccessAdminRefusalKey),
            matching: find.byType(ButtonStyleButton)),
        findsNothing,
      );
    });
  });

  // -------------------------------------------------------------------------
  // T-06-77: the admin who changes their own account
  // -------------------------------------------------------------------------

  group('the caller changing their own account', () {
    testWidgets(
        'a self-demotion drops users on the spot, with no sign-out before the '
        'claim', (tester) async {
      // Permitted, because a second Engineering account still holds `users` —
      // which is exactly the window T-06-77 lives in.
      await makeUser('admin', 'Engineering');
      await makeUser('keeper', 'Engineering');

      await pumpSection(tester, overrides(), gated: true);
      await signIn(tester, 'admin');
      expect((await sessionInForce()).can(AccessGroup.users), isTrue);
      expect(find.byKey(kAccessUsersSectionKey), findsOneWidget);

      await openRolePicker(tester, 'admin');
      await tester.tap(find.byKey(kAccessUserRoleChoiceKey('Engineering')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAccessUserRoleChoiceKey('Maintenance')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAccessUserRoleConfirmKey));
      await tester.pumpAndSettle();

      expect((await userNamed('admin'))!.roleName, 'Maintenance');
      expect(
        (await sessionInForce()).can(AccessGroup.users),
        isFalse,
        reason: 'T-06-77: without refreshGroupsFromRoles the caller keeps the '
            'groups the account they just demoted was giving them, until they '
            'sign out — privilege retention in the phase whose job is '
            'administering privileges',
      );
      expect((await sessionInForce()).isElevated, isTrue,
          reason: 'a demotion is not a sign-out; the account still exists');
      expect(find.text('locked'), findsOneWidget,
          reason: 'the gate closed on the caller, which is the point');
      expect(tester.takeException(), isNull,
          reason: 'the refresh goes last and everything after the await is '
              'guarded, so the unmount is a non-event');

      // Cleanup only, after every assertion above: an elevated session arms
      // the inactivity monitor and a pending timer fails a widget test.
      await signOut(tester);
    });

    testWidgets(
        'a self-delete drops the session to anonymous, with no sign-out '
        'anywhere in the test', (tester) async {
      // A second holder is present, so the invariant permits the delete.
      await makeUser('admin', 'Engineering');
      await makeUser('keeper', 'Engineering');

      await pumpSection(tester, overrides(), gated: true);
      await signIn(tester, 'admin');
      expect((await sessionInForce()).isElevated, isTrue);

      await tester.tap(find.byKey(kAccessUserDeleteKey('admin')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(kAccessUserDeleteConfirmLabel));
      await tester.pumpAndSettle();

      expect(await userNamed('admin'), isNull);
      expect((await sessionInForce()).isElevated, isFalse,
          reason: 'the account behind the session is gone');
      expect((await sessionInForce()).user, isNull);
      expect((await sessionInForce()).can(AccessGroup.users), isFalse);
      expect(find.text('locked'), findsOneWidget);
      expect(
        tester.takeException(),
        isNull,
        reason: 'the roster is invalidated and the dialog closed before the '
            'await, and nothing touches ref or context after it — otherwise '
            'this runs on a disposed element',
      );
    });
  });

  // -------------------------------------------------------------------------
  // The create dialog — one of the two screens where a password is in hand
  // -------------------------------------------------------------------------

  group('the create dialog', () {
    testWidgets('there is no create control without a database',
        (tester) async {
      await pumpSection(tester, overrides(noDatabase: true));

      expect(find.byKey(kAccessUsersCreateKey), findsNothing,
          reason: 'there is no table to create into — and that is not a '
              'permission decision, so nothing is greyed either');
    });

    testWidgets('a blank username is refused with its own sentence',
        (tester) async {
      await makeUser('admin', 'Engineering');
      await pumpSection(tester, overrides());
      await openCreate(tester);
      await fillCreate(tester, username: '   ', password: 'correct horse');

      await tester.tap(find.byKey(kAccessUserCreateConfirmKey));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessUserBlankUsernameKey), findsOneWidget);
      expect(find.text(kAccessUserBlankUsernameNote), findsOneWidget);
      expect(store!.calls.where((c) => c.startsWith('createUser')), isEmpty);
      expect(find.byKey(kAccessUserCreateConfirmKey), findsOneWidget,
          reason: 'the dialog stays open so the operator can fix one field '
              'rather than retype three');
    });

    testWidgets('a blank password is refused with its own sentence',
        (tester) async {
      await makeUser('admin', 'Engineering');
      await pumpSection(tester, overrides());
      await openCreate(tester);
      await fillCreate(tester, username: 'newbie', password: '');

      await tester.tap(find.byKey(kAccessUserCreateConfirmKey));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessUserBlankPasswordKey), findsOneWidget);
      expect(find.text(kAccessUserBlankPasswordNote), findsOneWidget);
      expect(store!.calls.where((c) => c.startsWith('createUser')), isEmpty);
    });

    testWidgets('passwords that do not match are refused with their own '
        'sentence', (tester) async {
      await makeUser('admin', 'Engineering');
      await pumpSection(tester, overrides());
      await openCreate(tester);
      await fillCreate(
          tester,
          username: 'newbie',
          password: 'correct horse',
          confirm: 'correct hose');

      await tester.tap(find.byKey(kAccessUserCreateConfirmKey));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessUserMismatchKey), findsOneWidget);
      expect(find.text(kAccessUserMismatchNote), findsOneWidget);
      expect(store!.calls.where((c) => c.startsWith('createUser')), isEmpty);
    });

    testWidgets('the three checks run in first_user.dart\'s order',
        (tester) async {
      await makeUser('admin', 'Engineering');
      await pumpSection(tester, overrides());
      await openCreate(tester);
      // Every branch is wrong at once. Three checks in a fixed order means
      // three sentences the operator can act on, one at a time; a single
      // "invalid input" is a support call.
      await fillCreate(tester, username: '', password: '', confirm: 'x');

      await tester.tap(find.byKey(kAccessUserCreateConfirmKey));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessUserBlankUsernameKey), findsOneWidget);
      expect(find.byKey(kAccessUserBlankPasswordKey), findsNothing);
      expect(find.byKey(kAccessUserMismatchKey), findsNothing);
    });

    testWidgets('a duplicate username is refused inside the dialog, before '
        'the store is asked', (tester) async {
      await makeUser('admin', 'Engineering');
      await makeUser('bjorn', 'Shift Leader');
      await pumpSection(tester, overrides());
      await openCreate(tester);
      await fillCreate(tester, username: 'bjorn', password: 'correct horse');

      await tester.tap(find.byKey(kAccessUserCreateConfirmKey));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessUserDuplicateKey), findsOneWidget);
      expect(find.text(kAccessUserDuplicateNote('bjorn')), findsOneWidget);
      expect(
        store!.calls.where((c) => c.startsWith('createUser')),
        isEmpty,
        reason: 'an exception surfaced as a snackbar after the dialog closed '
            'would make the operator retype everything',
      );
    });

    testWidgets('the duplicate check compares exactly — a capitalisation is a '
        'different account', (tester) async {
      await makeUser('admin', 'Engineering');
      await makeUser('bjorn', 'Shift Leader');
      await pumpSection(tester, overrides());
      await openCreate(tester);
      await fillCreate(tester, username: 'Bjorn', password: 'correct horse');

      await tester.tap(find.byKey(kAccessUserCreateConfirmKey));
      await tester.pumpAndSettle();

      expect(
        find.byKey(kAccessUserDuplicateKey),
        findsNothing,
        reason: 'app_user.username is a case-sensitive primary key and '
            'AccessRepository.user documents why. A dialog that refused '
            '"Bjorn" because "bjorn" exists would refuse a name the database '
            'would have accepted',
      );
      expect(await userNamed('Bjorn'), isNotNull);
      expect(await userNamed('bjorn'), isNotNull);
    });

    testWidgets('UserExistsException re-renders the dialog rather than '
        'closing it', (tester) async {
      await makeUser('admin', 'Engineering');
      await pumpSection(tester, overrides());
      await openCreate(tester);
      await fillCreate(tester, username: 'newbie', password: 'correct horse');
      // The race the pre-check cannot win: another station inserted the name
      // between the loaded roster and this transaction.
      store!.createThrowsOnce = const UserExistsException('newbie');

      await tester.tap(find.byKey(kAccessUserCreateConfirmKey));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessUserCreateConfirmKey), findsOneWidget,
          reason: 'the dialog stays open, holding what was typed');
      expect(find.byKey(kAccessUserDuplicateKey), findsOneWidget);
      expect(find.text(kAccessUserDuplicateNote('newbie')), findsOneWidget);
      expect(
          tester
              .widget<TextField>(find.byKey(kAccessUserUsernameFieldKey))
              .controller!
              .text,
          'newbie');
    });

    testWidgets('an account is created in the role that was picked, and its '
        'password works', (tester) async {
      await makeUser('admin', 'Engineering');
      await pumpSection(tester, overrides());
      await openCreate(tester);
      await fillCreate(tester, username: 'newbie', password: 'correct horse');
      // The dialog opens with the narrowest role ticked; untick it so that
      // what this test asserts is the picked role and not a union with the
      // default.
      await tester.tap(find.byKey(kAccessUserRoleChoiceKey('Operator')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAccessUserRoleChoiceKey('Maintenance')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(kAccessUserCreateConfirmKey));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessUserCreateConfirmKey), findsNothing,
          reason: 'the dialog closes on success');
      expect(find.byKey(kAccessUserRowKey('newbie')), findsOneWidget);
      expect((await userNamed('newbie'))!.roleName, 'Maintenance');
      expect(cell(tester, kAccessUserLastLoginKey('newbie')), kAccessUserNever);

      final who = await realAuth().authenticate('newbie', 'correct horse');
      expect(who?.roleName, 'Maintenance',
          reason: 'the credential reached the repository and nowhere else');
    });

    testWidgets('an account can be created holding two roles at once',
        (tester) async {
      await makeUser('admin', 'Engineering');
      await pumpSection(tester, overrides());
      await openCreate(tester);
      await fillCreate(tester, username: 'newbie', password: 'correct horse');
      // Operator is ticked by default; add Maintenance beside it.
      await tester.tap(find.byKey(kAccessUserRoleChoiceKey('Maintenance')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(kAccessUserCreateConfirmKey));
      await tester.pumpAndSettle();

      final row = (await userNamed('newbie'))!;
      expect(row.roleName, 'Operator');
      expect(decodeAdditionalRoles(row.additionalRoles), ['Maintenance']);
      expect(cell(tester, kAccessUserRoleKey('newbie')),
          'Operator + Maintenance');

      final who = await realAuth().authenticate('newbie', 'correct horse');
      expect(who?.roleNames, ['Operator', 'Maintenance']);
    });

    testWidgets('a failure never renders the exception', (tester) async {
      const staged = 'sekrit-9x-never-typed';
      await makeUser('admin', 'Engineering');
      await pumpSection(tester, overrides());
      await openCreate(tester);
      await fillCreate(tester, username: 'newbie', password: 'correct horse');
      // An ArgumentError raised on a bad credential can carry the credential
      // in its message. `staged` was never typed into this dialog, so finding
      // it anywhere in the tree can only mean the exception was rendered.
      store!.createThrowsOnce = ArgumentError('rejected credential: $staged');

      await tester.tap(find.byKey(kAccessUserCreateConfirmKey));
      await tester.pumpAndSettle();

      expect(
        treeMentions(tester, staged),
        isFalse,
        reason: 'T-06-70: first_user.dart refuses to render the exception on '
            'exactly this screen — rendering it would put a credential into a '
            'screenshot of a commissioning session',
      );
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byKey(kAccessUserFailedKey), findsOneWidget);
      expect(find.text(kAccessUserCreateFailedNote), findsOneWidget);
      expect(await userNamed('newbie'), isNull);
    });

    testWidgets('the confirming action is disabled while the write is in '
        'flight, and enabled again if it fails', (tester) async {
      await makeUser('admin', 'Engineering');
      await pumpSection(tester, overrides());
      await openCreate(tester);
      await fillCreate(tester, username: 'newbie', password: 'correct horse');
      final hold = Completer<void>();
      store!.holdWrites = hold;
      store!.createThrowsOnce = StateError('the database went away');

      await tester.tap(find.byKey(kAccessUserCreateConfirmKey));
      await tester.pump();

      expect(
        tester
            .widget<FilledButton>(find.byKey(kAccessUserCreateConfirmKey))
            .onPressed,
        isNull,
        reason: 'T-06-75: the write is a key derivation rather than a round '
            'trip, and this is about a second tap racing the first — not '
            'about a permission, which is the rule that says never grey a '
            'control',
      );
      expect(
          tester
              .widget<TextField>(find.byKey(kAccessUserUsernameFieldKey))
              .enabled,
          isFalse);

      hold.complete();
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<FilledButton>(find.byKey(kAccessUserCreateConfirmKey))
            .onPressed,
        isNotNull,
        reason: 'the dialog is usable again after a failure',
      );
    });

    testWidgets(
        'a second tap cannot race the first while a real derivation is in '
        'flight', (tester) async {
      await makeUser('admin', 'Engineering');
      await pumpSection(tester, overrides());
      await openCreate(tester);
      await fillCreate(tester, username: 'newbie', password: 'correct horse');
      // The busy state exercised against something that actually takes time.
      // 32768 KiB — 32 MiB of Argon2id memory at t=1, p=1 under the cost dial.
      // Named through the store rather than the Pbkdf2Kdf forwarder, because
      // this is the one site in the file dialling Argon2id cost up rather than
      // clamping everything cheap.
      //
      // A literal chosen for this test, deliberately independent of the
      // parameters measured for production: clearing the hook instead would
      // put an unbounded, rig-measured cost inside a testWidgets timeout.
      // Both bounds are self-enforcing — too cheap and the single-createUser
      // assertion below fails, too expensive and this times out.
      KdfTestCost.iterationsForTest = 32768;

      await tester.tap(find.byKey(kAccessUserCreateConfirmKey));
      await tester.tap(find.byKey(kAccessUserCreateConfirmKey),
          warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(store!.calls.where((c) => c.startsWith('createUser')).length, 1,
          reason: 'two writes would be one account and one '
              'UserExistsException surfaced for no reason');
      expect(await userNamed('newbie'), isNotNull);
    });

    testWidgets('every controller is disposed', (tester) async {
      await makeUser('admin', 'Engineering');
      await pumpSection(tester, overrides());
      await openCreate(tester);

      final controllers = [
        for (final key in [
          kAccessUserUsernameFieldKey,
          kAccessUserPasswordFieldKey,
          kAccessUserConfirmFieldKey,
        ])
          tester.widget<TextField>(find.byKey(key)).controller!,
      ];
      expect(controllers, hasLength(3));

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      for (final controller in controllers) {
        expect(
          () => controller.addListener(() {}),
          throwsA(isA<AssertionError>()),
          reason: 'a disposed ChangeNotifier asserts on addListener — the '
              'controller holding a password must not outlive its dialog',
        );
      }
      expect(tester.takeException(), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // The set-password dialog — the other screen where a password is in hand
  // -------------------------------------------------------------------------

  group('the set-password dialog', () {
    testWidgets('two fields, and neither of them is a username or a current '
        'password', (tester) async {
      await makeUser('bjorn', 'Shift Leader');
      await pumpSection(tester, overrides());
      await openSetPassword(tester, 'bjorn');

      expect(find.byKey(kAccessUserPasswordFieldKey), findsOneWidget);
      expect(find.byKey(kAccessUserConfirmFieldKey), findsOneWidget);
      expect(find.byType(TextField), findsNWidgets(2));
      expect(
        find.byKey(kAccessUserUsernameFieldKey),
        findsNothing,
        reason: 'there is no verify-current flow and self-service is out of '
            'scope: an admin types the new password directly',
      );
      expect(find.text(kAccessUserSetPasswordTitle('bjorn')), findsOneWidget);
    });

    testWidgets('a blank password is refused with its own sentence',
        (tester) async {
      await makeUser('bjorn', 'Shift Leader');
      await pumpSection(tester, overrides());
      await openSetPassword(tester, 'bjorn');

      await tester.tap(find.byKey(kAccessUserPasswordConfirmKey));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessUserBlankPasswordKey), findsOneWidget);
      expect(find.text(kAccessUserBlankPasswordNote), findsOneWidget);
      expect(store!.calls.where((c) => c.startsWith('setUserPassword')),
          isEmpty);
    });

    testWidgets('a mismatch is refused with its own sentence', (tester) async {
      await makeUser('bjorn', 'Shift Leader');
      await pumpSection(tester, overrides());
      await openSetPassword(tester, 'bjorn');
      await tester.enterText(
          find.byKey(kAccessUserPasswordFieldKey), 'new leyniord');
      await tester.enterText(
          find.byKey(kAccessUserConfirmFieldKey), 'new leynior');
      await tester.pump();

      await tester.tap(find.byKey(kAccessUserPasswordConfirmKey));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessUserMismatchKey), findsOneWidget);
      expect(find.text(kAccessUserMismatchNote), findsOneWidget);
      expect(store!.calls.where((c) => c.startsWith('setUserPassword')),
          isEmpty);
    });

    testWidgets('the new password works and the old one stops working',
        (tester) async {
      await makeUser('bjorn', 'Shift Leader');
      await pumpSection(tester, overrides());
      await openSetPassword(tester, 'bjorn');
      await tester.enterText(
          find.byKey(kAccessUserPasswordFieldKey), 'new leyniord');
      await tester.enterText(
          find.byKey(kAccessUserConfirmFieldKey), 'new leyniord');
      await tester.pump();

      await tester.tap(find.byKey(kAccessUserPasswordConfirmKey));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessUserPasswordConfirmKey), findsNothing);
      final auth = realAuth();
      expect((await auth.authenticate('bjorn', 'new leyniord'))?.roleName,
          'Shift Leader');
      expect(await auth.authenticate('bjorn', 'correct horse'), isNull);
    });

    testWidgets('a failure never renders the exception', (tester) async {
      const staged = 'sekrit-7y-never-typed';
      await makeUser('bjorn', 'Shift Leader');
      await pumpSection(tester, overrides());
      await openSetPassword(tester, 'bjorn');
      await tester.enterText(
          find.byKey(kAccessUserPasswordFieldKey), 'new leyniord');
      await tester.enterText(
          find.byKey(kAccessUserConfirmFieldKey), 'new leyniord');
      await tester.pump();
      store!.setPasswordThrowsOnce =
          ArgumentError('rejected credential: $staged');

      await tester.tap(find.byKey(kAccessUserPasswordConfirmKey));
      await tester.pumpAndSettle();

      expect(treeMentions(tester, staged), isFalse, reason: 'T-06-70');
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byKey(kAccessUserFailedKey), findsOneWidget);
      expect(find.text(kAccessUserSetPasswordFailedNote), findsOneWidget);
    });

    testWidgets('the confirming action is disabled while the hash is in '
        'flight', (tester) async {
      await makeUser('bjorn', 'Shift Leader');
      await pumpSection(tester, overrides());
      await openSetPassword(tester, 'bjorn');
      await tester.enterText(
          find.byKey(kAccessUserPasswordFieldKey), 'new leyniord');
      await tester.enterText(
          find.byKey(kAccessUserConfirmFieldKey), 'new leyniord');
      await tester.pump();
      final hold = Completer<void>();
      store!.holdWrites = hold;

      await tester.tap(find.byKey(kAccessUserPasswordConfirmKey));
      await tester.pump();

      expect(
          tester
              .widget<FilledButton>(find.byKey(kAccessUserPasswordConfirmKey))
              .onPressed,
          isNull);
      expect(
          tester
              .widget<TextField>(find.byKey(kAccessUserPasswordFieldKey))
              .enabled,
          isFalse);

      hold.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(kAccessUserPasswordConfirmKey), findsNothing);
    });

    testWidgets('every controller is disposed', (tester) async {
      await makeUser('bjorn', 'Shift Leader');
      await pumpSection(tester, overrides());
      await openSetPassword(tester, 'bjorn');

      final controllers = [
        for (final key in [
          kAccessUserPasswordFieldKey,
          kAccessUserConfirmFieldKey,
        ])
          tester.widget<TextField>(find.byKey(key)).controller!,
      ];
      expect(controllers, hasLength(2));

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      for (final controller in controllers) {
        expect(() => controller.addListener(() {}),
            throwsA(isA<AssertionError>()));
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('neither dialog puts the password into an audit row',
        (tester) async {
      const secret = 'ny-leyniord-7q';
      await makeUser('admin', 'Engineering');
      await pumpSection(tester, overrides());

      await openCreate(tester);
      await fillCreate(tester, username: 'newbie', password: secret);
      await tester.tap(find.byKey(kAccessUserCreateConfirmKey));
      await tester.pumpAndSettle();

      await openSetPassword(tester, 'newbie');
      await tester.enterText(find.byKey(kAccessUserPasswordFieldKey), secret);
      await tester.enterText(find.byKey(kAccessUserConfirmFieldKey), secret);
      await tester.pump();
      await tester.tap(find.byKey(kAccessUserPasswordConfirmKey));
      await tester.pumpAndSettle();

      expect(sink.rows.map((r) => r.itemKey),
          containsAll(['user.create', 'user.password']));
      for (final row in sink.rows) {
        expect(
          row.toString(),
          isNot(contains(secret)),
          reason: 'T-06-70/T-06-71: AuditRecord.userCreate and '
              'AuditRecord.userPassword have no parameter that could carry a '
              'credential, and an admin row is not an auth row — toString '
              'withholds the value columns only for the auth surface, so these '
              'do reach log files',
        );
        expect(row.oldValue, isNot(secret));
        expect(row.newValue, isNot(secret));
      }
    });
  });
}

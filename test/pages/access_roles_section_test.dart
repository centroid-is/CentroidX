/// The administration page's roles section (spec §1, 06-CONTEXT "Roles
/// Screen").
///
/// 06-03's store already drives every write through a `configure`-only session
/// and reads the rows back from the tables, so the claims here are the ones
/// only a rendered screen can make:
///
///  * the four terminal states cannot render as each other — "still loading",
///    "the store errored", "this station has no database" and "the list came
///    back empty" are four different sentences and only one of them is ever
///    true,
///  * the `Operator` row carries neither a Rename nor a Delete affordance, and
///    the predicate deciding that is `isProtectedRoleName` rather than a string
///    comparison, so a row stored as `operator` is protected too,
///  * a session without `users` sees every control, may press every one of
///    them, and reaches the shared `AccessDeniedPrompt` — nothing is greyed,
///  * a duplicate name is refused inside the dialog, before the store is asked,
///    because a typo is not an authorization event.
///
/// The store is real, over a real in-memory database, so "the role was created"
/// is read back from `app_role` rather than from a mock's call log. The
/// recording subclass exists for the one claim a table cannot answer: which
/// methods the section reached for.
///
/// **Two sessions, on purpose.** The store's gate reads the `session` variable
/// below; `accessSessionProvider` is the real controller and stays anonymous
/// unless a test signs in. On a station those are the same session. Splitting
/// them here is what lets one test assert that a logged-out panel gains a group
/// the moment `Operator` is saved **with no sign-in and no sign-out anywhere in
/// the test** — the store has to permit the write for the write to happen at
/// all, and signing in to arrange that would destroy the claim being made.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/core/access_admin_store.dart';
import 'package:tfc/pages/access_roles_section.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/access_admin.dart';
import 'package:tfc/providers/access_policy.dart';
import 'package:tfc/widgets/access_admin_notice.dart';
import 'package:tfc/widgets/access_denied_prompt.dart';
import 'package:tfc/widgets/panes/standard_dialog.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_repository.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import '../helpers/test_helpers.dart' show useInMemoryDeviceLocalPreferences;

// ---------------------------------------------------------------------------
// Doubles
// ---------------------------------------------------------------------------

/// A stand-in for `LocalAuthProvider` honouring the same null-versus-throw
/// contract. Only the two tests that sign somebody in reach it.
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
/// log. A hand-written fake would have let the one-roster-read test pass while
/// the section quietly asked the database something per row.
class _RecordingStore extends AccessAdminStore {
  _RecordingStore({
    required super.repository,
    required super.session,
    required super.audit,
    required super.station,
    super.onDenied,
  });

  final List<String> calls = [];

  /// Held open, the roster read the delete dialog makes never comes back — the
  /// only way to observe the "not yet asked" state, which is otherwise one
  /// microtask wide.
  Completer<void>? holdReads;

  /// Makes the roster read fail, so the delete dialog can answer neither of
  /// its two questions. Only `listUsers` and never `roles`: a failing `roles`
  /// is the section's own unavailable state and would leave no row to press.
  Object? listUsersThrows;

  /// What the next `deleteRole` throws instead of deleting, once.
  ///
  /// The losing race cannot be staged any other way. The dialog's pre-check
  /// and the repository's in-transaction guard are two different moments, and
  /// a test cannot get between them from outside. Cleared after it fires, so a
  /// second attempt behaves normally.
  Object? deleteThrowsOnce;

  @override
  Future<List<AccessRole>> roles() {
    calls.add('roles');
    return super.roles();
  }

  @override
  Future<List<AppUserData>> listUsers() async {
    calls.add('listUsers');
    final hold = holdReads;
    if (hold != null) await hold.future;
    final boom = listUsersThrows;
    if (boom != null) throw boom;
    return super.listUsers();
  }

  @override
  Future<void> createRole(AccessRole role,
      {String origin = 'operator', String? reason}) {
    calls.add('createRole:${role.name}');
    return super.createRole(role, origin: origin, reason: reason);
  }

  @override
  Future<void> updateRole(AccessRole role,
      {String origin = 'operator', String? reason}) {
    calls.add('updateRole:${role.name}:${role.encodeGroups()}');
    return super.updateRole(role, origin: origin, reason: reason);
  }

  @override
  Future<void> deleteRole(String name,
      {String origin = 'operator', String? reason}) async {
    calls.add('deleteRole:$name');
    final boom = deleteThrowsOnce;
    if (boom != null) {
      deleteThrowsOnce = null;
      throw boom;
    }
    return super.deleteRole(name, origin: origin, reason: reason);
  }

  @override
  Future<void> renameRole(String from, String to,
      {String origin = 'operator', String? reason}) {
    calls.add('renameRole:$from:$to');
    return super.renameRole(from, to, origin: origin, reason: reason);
  }
}

/// The `users` gate the composed page puts over this section, in miniature.
///
/// Only the part that matters to one claim here: when the session in force
/// loses `users`, the subtree is swapped out and the section is disposed.
/// `AccessGate` itself brings a locked page, its own scaffold and a sign-in
/// opener, none of which this claim needs — and standing all of that up would
/// make the test about the gate rather than about what runs after the await.
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

/// A panel with nobody signed in. It may open the delete dialog and press
/// Delete; the store is what refuses, and the shared prompt is what explains.
AccessSession _anonymous() =>
    AccessSession.anonymous(const {AccessGroup.operate});

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
    useInMemoryDeviceLocalPreferences();
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    DatabaseConfig.clearPrefsCache();
    // PBKDF2 at production iterations is the better part of a second per
    // account, and several tests here create real rows.
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
      'keeper': (password: 'correct horse', roleName: 'Access Admin'),
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
        inactivityTimeoutProvider
            .overrideWith((ref) async => const Duration(minutes: 15)),
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
        // Overridden only where a test needs a list the seeded database cannot
        // produce — see the empty-list terminal state.
        if (roles != null) accessAdminRolesProvider.overrideWith((ref) => roles),
      ];

  /// The section on its own, under a real [AccessDeniedPrompt] — the prompt a
  /// refusal has to reach, rather than a listener of the test's own.
  ///
  /// An explicit container rather than a plain `ProviderScope`, so a test can
  /// read the real `accessSessionProvider` and assert what a logged-out panel
  /// may do after a save. [gated] additionally puts the section behind the
  /// `users` gate the composed page puts it behind, which is what makes a save
  /// that narrows the caller's own role unmount the widget mid-await.
  Widget host(List<Override> o, {bool gated = false}) {
    final c = ProviderContainer(overrides: o);
    container = c;
    addTearDown(c.dispose);
    return UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        home: Scaffold(
          body: AccessDeniedPrompt(
            child: SingleChildScrollView(
              child: gated
                  ? const _UsersGate(child: AccessRolesSection())
                  : const AccessRolesSection(),
            ),
          ),
        ),
      ),
    );
  }

  /// Pumps the section on a panel-sized surface.
  ///
  /// The default 800×600 test window cannot fit an open editor — seven
  /// checkboxes with subtitles, plus the banner and the action row — and a tap
  /// on a control laid out below the fold fails rather than scrolling to it.
  /// A station is 1920×1080 and the composed page scrolls; the point of the
  /// larger surface is that these tests are about what the screen says, not
  /// about where it wraps.
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

  /// Signs [username] in on the **real** controller, so the session in force is
  /// elevated and the `users` gate above the section is open.
  Future<void> signIn(WidgetTester tester, String username) async {
    // Let `build()` resolve first. It is async, and a `state` written by
    // `signIn` while it is still in flight is overwritten when it completes —
    // so a test that signs in on a freshly-read notifier can silently end up
    // anonymous. In the app this cannot happen: `BaseScaffold` listens to the
    // session from the first frame, long before any sign-in surface opens.
    await container!.read(accessSessionProvider.future);
    final result = await container!
        .read(accessSessionProvider.notifier)
        .signIn(username, 'correct horse');
    expect(result, AccessSignInResult.ok);
    await tester.pumpAndSettle();
  }

  /// Cleanup, not part of any claim: an elevated session arms the inactivity
  /// monitor, and a timer still pending when the test body ends fails the test
  /// on its way out.
  Future<void> signOut(WidgetTester tester) async {
    await container!.read(accessSessionProvider.notifier).signOut();
    await tester.pumpAndSettle();
  }

  Future<AccessRole?> roleNamed(String name) => repository.role(name);

  Future<void> makeUser(String username, String roleName) =>
      repository.createUser(
        username: username,
        password: 'correct horse',
        roleName: roleName,
      );

  /// Opens the editor for [name] by tapping its row.
  Future<void> openEditor(WidgetTester tester, String name) async {
    await tester.tap(find.byKey(kAccessRoleTileKey(name)));
    await tester.pumpAndSettle();
  }

  // -------------------------------------------------------------------------
  // The four terminal states
  // -------------------------------------------------------------------------

  group('the four terminal states', () {
    testWidgets('still loading renders nothing — not a spinner that flashes',
        (tester) async {
      await pumpSection(tester, overrides(storeNeverResolves: true));

      expect(find.byKey(kAccessRolesSectionKey), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: 'this is one section on a page; the page owns the spinner, '
              'and a spinner that appears for a frame on every station is the '
              'flash AccessLockBadge refuses to draw');
      expect(find.byKey(kAccessRolesUnavailableKey), findsNothing);
      expect(find.byKey(kAccessRolesNoDatabaseKey), findsNothing);
      expect(find.byKey(kAccessRolesEmptyKey), findsNothing);
    });

    testWidgets('the store errored says the list is untrustworthy',
        (tester) async {
      await pumpSection(
          tester, overrides(storeError: StateError('no connection')));

      expect(find.byKey(kAccessRolesUnavailableKey), findsOneWidget);
      expect(find.text(kAccessRolesUnavailableNote), findsOneWidget);
      expect(find.byKey(kAccessRolesNoDatabaseKey), findsNothing);
      expect(find.byKey(kAccessRolesEmptyKey), findsNothing);
    });

    testWidgets('no database says why, rather than showing an empty list',
        (tester) async {
      await pumpSection(tester, overrides(noDatabase: true));

      expect(find.byKey(kAccessRolesNoDatabaseKey), findsOneWidget);
      expect(find.text(kAccessRolesNoDatabaseNote), findsOneWidget);
      expect(find.byKey(kAccessRolesEmptyKey), findsNothing,
          reason: '"there are no roles" is a different claim from "this '
              'station cannot tell you", and only one of them is true here');
      expect(find.byKey(kAccessRolesCreateKey), findsNothing,
          reason: 'there is no table to create into — and that is not a '
              'permission decision, so nothing is greyed either');
    });

    testWidgets('an empty list says a seeded database cannot be empty',
        (tester) async {
      // The one state the real loader cannot produce: the v6 migration seeds
      // four roles and `Operator` cannot be deleted. Overridden here precisely
      // because the copy's claim is that reaching it means something is wrong.
      await pumpSection(
          tester, overrides(roles: Future.value(const <AccessRole>[])));

      expect(find.byKey(kAccessRolesEmptyKey), findsOneWidget);
      expect(find.text(kAccessRolesEmptyNote), findsOneWidget);
      expect(find.byKey(kAccessRolesNoDatabaseKey), findsNothing);
      expect(find.byKey(kAccessRolesUnavailableKey), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  // The list
  // -------------------------------------------------------------------------

  group('the list', () {
    testWidgets('names every seeded role and what it grants, by label',
        (tester) async {
      await pumpSection(tester, overrides());

      expect(find.text(kAccessRolesHeadline), findsOneWidget);
      for (final role in kSeedRoles) {
        expect(find.text(role.name), findsOneWidget);
      }
      expect(
        find.text(kAccessRoleSummary({AccessGroup.operate}, 0)),
        findsOneWidget,
        reason: 'the Operator row: one group, nobody holds it',
      );
      expect(
        find.textContaining(AccessGroup.force.label),
        findsAtLeastNWidgets(1),
        reason: 'the summary reads by label, not by enum name — "force" tells '
            'a commissioning engineer nothing',
      );
    });

    testWidgets('the holder counts come from one roster read, not one query '
        'per row', (tester) async {
      await makeUser('admin', 'Engineering');
      await makeUser('sigga', 'Shift Leader');
      await makeUser('gunna', 'Shift Leader');

      await pumpSection(tester, overrides());

      expect(store!.calls.where((c) => c == 'listUsers').length, 1,
          reason: 'four roles on a seeded station, one roster read — a count '
              'per row would be one round trip per role per rebuild');
      expect(
        find.text(kAccessRoleSummary(
            {AccessGroup.operate, AccessGroup.setpoints}, 2)),
        findsOneWidget,
        reason: 'Shift Leader is held by two accounts',
      );
    });
  });

  // -------------------------------------------------------------------------
  // Operator: protected in the UI as well as in the repository
  // -------------------------------------------------------------------------

  group('Operator', () {
    testWidgets('the Operator row offers no Rename and no Delete at all',
        (tester) async {
      await pumpSection(tester, overrides());

      expect(find.byKey(kAccessRoleRenameKey(kOperatorRoleName)), findsNothing,
          reason: 'absent, not disabled: an unauthenticated panel resolves to '
              'this row and no session can change that, so a control that is '
              'present and always refuses would teach a second press');
      expect(find.byKey(kAccessRoleDeleteKey(kOperatorRoleName)), findsNothing);

      // By count rather than by looking for a disabled one: the other three
      // seeded roles have both controls, so the totals pin that exactly one
      // row is missing them.
      expect(find.byType(IconButton),
          findsNWidgets((kSeedRoles.length - 1) * 2));
    });

    testWidgets("a row stored as ' operator ' is protected too — the UI uses "
        'isProtectedRoleName, not a string comparison', (tester) async {
      // Inserted through drift rather than through the repository, because
      // `upsertRole` trims: the whitespace variant is only reachable as stored
      // data written by something older or by hand. The predicate is
      // whitespace-tolerant and case-insensitive precisely for this row.
      await db.into(db.appRole).insert(
            AppRoleCompanion.insert(name: ' operator ', groups: '["operate"]'),
          );

      await pumpSection(tester, overrides());

      expect(find.byKey(kAccessRoleTileKey(' operator ')), findsOneWidget);
      expect(find.byKey(kAccessRoleRenameKey(' operator ')), findsNothing);
      expect(find.byKey(kAccessRoleDeleteKey(' operator ')), findsNothing);
      expect(find.byType(IconButton),
          findsNWidgets((kSeedRoles.length - 1) * 2),
          reason: 'the extra row added no controls: five rows, three of them '
              'renameable and deletable');
    });
  });

  // -------------------------------------------------------------------------
  // Create and rename
  // -------------------------------------------------------------------------

  group('create', () {
    testWidgets('a users session creates a role and the list shows it',
        (tester) async {
      await pumpSection(tester, overrides());

      await tester.tap(find.byKey(kAccessRolesCreateKey));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(kAccessRoleNameFieldKey), 'Line Supervisor');
      await tester.tap(find.byKey(kAccessRoleNameConfirmKey));
      await tester.pumpAndSettle();

      expect(find.text('Line Supervisor'), findsOneWidget);
      final created = await roleNamed('Line Supervisor');
      expect(created, isNotNull);
      expect(created!.groups, isEmpty,
          reason: 'a new role grants nothing until a box is ticked');
    });

    testWidgets('a duplicate name is refused inside the dialog, without the '
        'store being called', (tester) async {
      await pumpSection(tester, overrides());
      store!.calls.clear();

      await tester.tap(find.byKey(kAccessRolesCreateKey));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(kAccessRoleNameFieldKey), 'Maintenance');
      await tester.tap(find.byKey(kAccessRoleNameConfirmKey));
      await tester.pumpAndSettle();

      expect(find.text(kAccessRoleDuplicateNameNote), findsOneWidget);
      expect(find.byKey(kAccessRoleNameFieldKey), findsOneWidget,
          reason: 'the dialog stays open with the text in it — a typo must not '
              'cost the whole entry');
      expect(store!.calls.where((c) => c.startsWith('createRole')), isEmpty,
          reason: 'a typo is not an authorization event, and putting a '
              'sign-in prompt in front of one teaches the operator to ignore '
              'the prompt');
    });

    testWidgets('a blank name is refused inside the dialog', (tester) async {
      await pumpSection(tester, overrides());
      store!.calls.clear();

      await tester.tap(find.byKey(kAccessRolesCreateKey));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(kAccessRoleNameFieldKey), '   ');
      await tester.tap(find.byKey(kAccessRoleNameConfirmKey));
      await tester.pumpAndSettle();

      expect(find.text(kAccessRoleInvalidNameNote), findsOneWidget);
      expect(store!.calls.where((c) => c.startsWith('createRole')), isEmpty);
    });

    testWidgets('a name that is a capitalisation of Operator is refused '
        'inside the dialog', (tester) async {
      await pumpSection(tester, overrides());
      store!.calls.clear();

      await tester.tap(find.byKey(kAccessRolesCreateKey));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(kAccessRoleNameFieldKey), 'operator');
      await tester.tap(find.byKey(kAccessRoleNameConfirmKey));
      await tester.pumpAndSettle();

      expect(find.text(kAccessRoleProtectedNameNote), findsOneWidget,
          reason: 'a second row the UI would render with no controls, and '
              'which nothing could then delete, is worse than a refusal here');
      expect(store!.calls.where((c) => c.startsWith('createRole')), isEmpty);
    });

    testWidgets('a configure-only session is refused, reaches the shared '
        'prompt, and the list is unchanged', (tester) async {
      session = _configureOnly();
      await pumpSection(tester, overrides());

      final create =
          tester.widget<OutlinedButton>(find.byKey(kAccessRolesCreateKey));
      expect(create.onPressed, isNotNull,
          reason: 'nothing on this section is greyed for lack of a permission '
              '— it is pressed, and then explained');

      await tester.tap(find.byKey(kAccessRolesCreateKey));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(kAccessRoleNameFieldKey), 'Cleaner');
      await tester.tap(find.byKey(kAccessRoleNameConfirmKey));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessDeniedBodyKey), findsOneWidget);
      expect(find.text(kAccessDeniedGroupNote(AccessGroup.users)),
          findsOneWidget,
          reason: 'spec §1: somebody who may edit a page must not be able to '
              're-scope who may write what');
      expect(await roleNamed('Cleaner'), isNull);
      expect(tester.takeException(), isNull);
    });
  });

  group('rename', () {
    testWidgets('a users session renames a role and its holders come with it',
        (tester) async {
      await makeUser('sigga', 'Shift Leader');
      await pumpSection(tester, overrides());

      await tester.tap(find.byKey(kAccessRoleRenameKey('Shift Leader')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(kAccessRoleNameFieldKey), 'Line Lead');
      await tester.tap(find.byKey(kAccessRoleNameConfirmKey));
      await tester.pumpAndSettle();

      expect(find.text('Line Lead'), findsOneWidget);
      expect(find.text('Shift Leader'), findsNothing);
      expect((await repository.user('sigga'))!.roleName, 'Line Lead');
    });

    testWidgets('the rename dialog refuses a name already taken, without the '
        'store being called', (tester) async {
      await pumpSection(tester, overrides());
      store!.calls.clear();

      await tester.tap(find.byKey(kAccessRoleRenameKey('Shift Leader')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(kAccessRoleNameFieldKey), 'Maintenance');
      await tester.tap(find.byKey(kAccessRoleNameConfirmKey));
      await tester.pumpAndSettle();

      expect(find.text(kAccessRoleDuplicateNameNote), findsOneWidget);
      expect(store!.calls.where((c) => c.startsWith('renameRole')), isEmpty);
    });
  });


  // -------------------------------------------------------------------------
  // The seven checkboxes
  // -------------------------------------------------------------------------

  group('the seven checkboxes', () {
    testWidgets('are generated from AccessGroup.values, in that order, with '
        'the label as title and the description as subtitle', (tester) async {
      await pumpSection(tester, overrides());
      await openEditor(tester, 'Maintenance');

      final tiles = tester
          .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
          .toList();

      expect(tiles.length, AccessGroup.values.length,
          reason: 'seven, and generated — a hand-written list of seven is how '
              'an eighth group silently fails to appear');
      expect(
        [for (final tile in tiles) (tile.title! as Text).data],
        [for (final group in AccessGroup.values) group.label],
        reason: 'the enum is declared in increasing privilege and '
            'tfc_access/test/access_group_test.dart pins that order precisely '
            'so consumers can rely on it',
      );
      expect(
        [for (final tile in tiles) (tile.subtitle! as Text).data],
        [for (final group in AccessGroup.values) group.description],
        reason: 'AccessGroupInfo.description, verbatim — one wording shared '
            'with the MCP tools, sourced from the enum\'s own doc comments',
      );
    });

    testWidgets('start ticked exactly where the role grants, and Cancel '
        'discards without writing', (tester) async {
      await pumpSection(tester, overrides());
      await openEditor(tester, 'Shift Leader');
      store!.calls.clear();

      CheckboxListTile boxFor(AccessGroup group) => tester
          .widget<CheckboxListTile>(
              find.byKey(kAccessRoleGroupKey('Shift Leader', group)));

      expect(boxFor(AccessGroup.operate).value, isTrue);
      expect(boxFor(AccessGroup.setpoints).value, isTrue);
      expect(boxFor(AccessGroup.force).value, isFalse);

      await tester.tap(
          find.byKey(kAccessRoleGroupKey('Shift Leader', AccessGroup.force)));
      await tester.pumpAndSettle();
      expect(boxFor(AccessGroup.force).value, isTrue,
          reason: 'the tick is local — the editor holds a draft and does not '
              'write on every box');
      expect(store!.calls.where((c) => c.startsWith('updateRole')), isEmpty);

      await tester.tap(find.byKey(kAccessRoleCancelKey('Shift Leader')));
      await tester.pumpAndSettle();
      expect((await roleNamed('Shift Leader'))!.groups,
          {AccessGroup.operate, AccessGroup.setpoints});
      expect(store!.calls.where((c) => c.startsWith('updateRole')), isEmpty);
    });

    testWidgets('one Save writes one role.update however many boxes moved',
        (tester) async {
      await pumpSection(tester, overrides());
      await openEditor(tester, 'Shift Leader');
      store!.calls.clear();

      for (final group in [AccessGroup.device, AccessGroup.force]) {
        await tester
            .tap(find.byKey(kAccessRoleGroupKey('Shift Leader', group)));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(kAccessRoleSaveKey('Shift Leader')));
      await tester.pumpAndSettle();

      expect(store!.calls.where((c) => c.startsWith('updateRole')).length, 1,
          reason: 'two boxes, one write, one audit row');
      expect((await roleNamed('Shift Leader'))!.groups, {
        AccessGroup.operate,
        AccessGroup.setpoints,
        AccessGroup.device,
        AccessGroup.force,
      });
    });
  });

  // -------------------------------------------------------------------------
  // Warning one of two: the persistent inline banner
  // -------------------------------------------------------------------------

  group('the Operator banner', () {
    testWidgets('is rendered the whole time the protected row is open',
        (tester) async {
      await pumpSection(tester, overrides());

      expect(find.byKey(kAccessOperatorWarningKey), findsNothing,
          reason: 'nothing is open yet');

      await openEditor(tester, kOperatorRoleName);
      expect(find.byKey(kAccessOperatorWarningKey), findsOneWidget);
      expect(find.text(kAccessOperatorBannerNote), findsOneWidget,
          reason: 'access_repository.dart:90-96 asks for the warning "at the '
              'point of edit, not in a help page"');

      // Still up after a tick, and after another. A banner that vanished the
      // moment the operator started editing would be a banner about nothing.
      await tester.tap(find.byKey(
          kAccessRoleGroupKey(kOperatorRoleName, AccessGroup.setpoints)));
      await tester.pumpAndSettle();
      expect(find.byKey(kAccessOperatorWarningKey), findsOneWidget);
      await tester.tap(find.byKey(
          kAccessRoleGroupKey(kOperatorRoleName, AccessGroup.device)));
      await tester.pumpAndSettle();
      expect(find.byKey(kAccessOperatorWarningKey), findsOneWidget);
    });

    testWidgets('is not rendered for any other role', (tester) async {
      await pumpSection(tester, overrides());

      for (final name in ['Shift Leader', 'Maintenance', 'Engineering']) {
        await openEditor(tester, name);
        expect(find.byKey(kAccessOperatorWarningKey), findsNothing,
            reason: '$name is an ordinary role; a warning shown everywhere is '
                'a warning nobody reads');
        await openEditor(tester, name);
      }
    });

    testWidgets('the Operator row is marked as the anonymous identity',
        (tester) async {
      await pumpSection(tester, overrides());

      expect(find.byKey(kAccessRoleAnonymousTagKey), findsOneWidget);
      expect(find.text(kAccessRoleAnonymousTag), findsOneWidget,
          reason: 'the row is legible as the anonymous identity rather than '
              'merely as the row with no controls');
    });
  });

  // -------------------------------------------------------------------------
  // Warning two of two: the confirmation on save
  // -------------------------------------------------------------------------

  group('the Operator save confirmation', () {
    testWidgets('names the groups being added by label, and cancelling it '
        'writes nothing', (tester) async {
      await pumpSection(tester, overrides());
      await openEditor(tester, kOperatorRoleName);
      store!.calls.clear();

      for (final group in [AccessGroup.setpoints, AccessGroup.force]) {
        await tester
            .tap(find.byKey(kAccessRoleGroupKey(kOperatorRoleName, group)));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(kAccessRoleSaveKey(kOperatorRoleName)));
      await tester.pumpAndSettle();

      expect(find.text(kAccessOperatorConfirmTitle), findsOneWidget);
      expect(
        find.text(kAccessOperatorConfirmMessage(
            const [AccessGroup.setpoints, AccessGroup.force])),
        findsOneWidget,
      );
      expect(
          find.descendant(
              of: find.byType(StandardDialog),
              matching: find.textContaining(AccessGroup.force.label)),
          findsOneWidget,
          reason: 'by label. AccessGroup.force.name is "force", which is '
              'exactly the word 06-01 exists to stop the screen using');
      expect(find.byKey(kAccessOperatorWarningKey), findsOneWidget,
          reason: 'both halves at once — the banner does not go away because '
              'the dialog arrived');

      await tester.tap(find.descendant(
          of: find.byType(StandardDialog), matching: find.text('Cancel')));
      await tester.pumpAndSettle();

      expect(store!.calls.where((c) => c.startsWith('updateRole')), isEmpty);
      expect(
          (await roleNamed(kOperatorRoleName))!.groups, {AccessGroup.operate});
      expect(
        tester
            .widget<CheckboxListTile>(find.byKey(
                kAccessRoleGroupKey(kOperatorRoleName, AccessGroup.force)))
            .value,
        isTrue,
        reason: 'the draft is left as the operator left it, so a second Save '
            'does not need the boxes ticked again',
      );
    });

    testWidgets('a save that only removes groups shows the banner and no '
        'confirmation', (tester) async {
      await repository.upsertRole(const AccessRole(
        name: kOperatorRoleName,
        groups: {AccessGroup.operate, AccessGroup.setpoints},
        seeded: true,
      ));
      await pumpSection(tester, overrides());
      await openEditor(tester, kOperatorRoleName);

      expect(find.byKey(kAccessOperatorWarningKey), findsOneWidget);

      await tester.tap(find.byKey(
          kAccessRoleGroupKey(kOperatorRoleName, AccessGroup.setpoints)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAccessRoleSaveKey(kOperatorRoleName)));
      await tester.pumpAndSettle();

      expect(find.text(kAccessOperatorConfirmTitle), findsNothing,
          reason: 'narrowing is the safe direction, and a confirm on every '
              'save is a confirm nobody reads');
      expect(
          (await roleNamed(kOperatorRoleName))!.groups, {AccessGroup.operate});
    });

    testWidgets('an ordinary role shows neither warning on save',
        (tester) async {
      await pumpSection(tester, overrides());
      await openEditor(tester, 'Maintenance');

      await tester.tap(find
          .byKey(kAccessRoleGroupKey('Maintenance', AccessGroup.configure)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAccessRoleSaveKey('Maintenance')));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessOperatorWarningKey), findsNothing);
      expect(find.text(kAccessOperatorConfirmTitle), findsNothing);
      expect((await roleNamed('Maintenance'))!.groups,
          contains(AccessGroup.configure));
    });
  });

  // -------------------------------------------------------------------------
  // The change the banner warns about, actually taking effect
  // -------------------------------------------------------------------------

  group('the group change takes effect', () {
    testWidgets('an anonymous session gains setpoints the moment Operator is '
        'saved with it — no sign-in and no sign-out', (tester) async {
      await pumpSection(tester, overrides());

      expect((await sessionInForce()).isElevated, isFalse);
      expect((await sessionInForce()).can(AccessGroup.setpoints), isFalse);

      await openEditor(tester, kOperatorRoleName);
      await tester.tap(find.byKey(
          kAccessRoleGroupKey(kOperatorRoleName, AccessGroup.setpoints)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAccessRoleSaveKey(kOperatorRoleName)));
      await tester.pumpAndSettle();
      await tester.tap(find.text(kAccessOperatorConfirmLabel));
      await tester.pumpAndSettle();

      expect(
        (await sessionInForce()).can(AccessGroup.setpoints),
        isTrue,
        reason: 'T-06-65: the banner promises that ticking a group here '
            'changes what a logged-out panel may do. Without '
            'refreshGroupsFromRoles it is a promise the app does not keep '
            'until something else happens to rebuild the session',
      );
      expect((await sessionInForce()).isElevated, isFalse,
          reason: 'still logged out — that is the whole point');
    });

    testWidgets('a rename re-resolves the session in force too, so the write '
        'path does not refresh only after an Operator edit', (tester) async {
      await makeUser('admin', 'Engineering');
      await pumpSection(tester, overrides());
      await signIn(tester, 'admin');
      expect((await sessionInForce()).user!.roleName, 'Engineering');

      await tester.tap(find.byKey(kAccessRoleRenameKey('Engineering')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(kAccessRoleNameFieldKey), 'Controls Engineering');
      await tester.tap(find.byKey(kAccessRoleNameConfirmKey));
      await tester.pumpAndSettle();

      expect(
        (await sessionInForce()).user!.roleName,
        'Controls Engineering',
        reason: 'the refresh runs after all four role writes, not only after '
            'an Operator update — the session was carrying a role name that '
            'no longer exists',
      );

      await signOut(tester);
    });
  });

  // -------------------------------------------------------------------------
  // The lockout invariant, surfaced rather than re-implemented
  // -------------------------------------------------------------------------

  group('the lockout refusal', () {
    testWidgets('unticking users from the only granting role is refused '
        'inline, names the holders, and shows no snackbar', (tester) async {
      await makeUser('admin', 'Engineering');
      await pumpSection(tester, overrides());
      await openEditor(tester, 'Engineering');

      await tester.tap(
          find.byKey(kAccessRoleGroupKey('Engineering', AccessGroup.users)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAccessRoleSaveKey('Engineering')));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessAdminRefusalKey), findsOneWidget);
      expect(find.byKey(kAccessAdminNoticeNameKey('admin')), findsOneWidget,
          reason: 'naming the remaining holder is what makes the fix obvious');
      expect(find.text(kAccessAdminBreakGlassNote), findsOneWidget,
          reason: 'there is no override, and there is a documented way back');
      expect(find.byType(SnackBar), findsNothing,
          reason: 'a refusal naming accounts must not be in something that '
              'disappears while it is being read');
      expect(find.byKey(kAccessDeniedBodyKey), findsNothing,
          reason: 'this is not an AccessDenied: the account that hits it '
              'already holds users, so no sign-in resolves it');

      expect((await roleNamed('Engineering'))!.groups,
          contains(AccessGroup.users));
      expect(
        tester
            .widget<CheckboxListTile>(find
                .byKey(kAccessRoleGroupKey('Engineering', AccessGroup.users)))
            .value,
        isFalse,
        reason: 'the boxes are left as the operator left them, so they can '
            'see what they tried',
      );
    });

    testWidgets('there is no override anywhere on the refused editor',
        (tester) async {
      await makeUser('admin', 'Engineering');
      await pumpSection(tester, overrides());
      await openEditor(tester, 'Engineering');
      await tester.tap(
          find.byKey(kAccessRoleGroupKey('Engineering', AccessGroup.users)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAccessRoleSaveKey('Engineering')));
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

    testWidgets(
        'narrowing the caller\'s own role while a second granting role is '
        'still held unmounts the section mid-save and throws nothing',
        (tester) async {
      // Route (c) is *permitted* here: a second role grants `users` and
      // somebody holds it, so the repository does not refuse — the refresh
      // simply drops the caller below the gate this section sits behind.
      await repository.upsertRole(
          const AccessRole(name: 'Access Admin', groups: {AccessGroup.users}));
      await makeUser('admin', 'Engineering');
      await makeUser('keeper', 'Access Admin');

      await pumpSection(tester, overrides(), gated: true);
      await signIn(tester, 'admin');
      expect(find.byKey(kAccessRolesSectionKey), findsOneWidget);

      await openEditor(tester, 'Engineering');
      await tester.tap(
          find.byKey(kAccessRoleGroupKey('Engineering', AccessGroup.users)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAccessRoleSaveKey('Engineering')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull,
          reason: 'the refresh goes last and everything after the await is '
              'guarded, so the unmount is a non-event — an invalidate or a '
              'setState sequenced after it would run on a disposed element');
      expect(find.text('locked'), findsOneWidget,
          reason: 'the caller narrowed their own role and the gate closed, '
              'which is exactly what the call is for');
      expect((await roleNamed('Engineering'))!.groups,
          isNot(contains(AccessGroup.users)));

      await signOut(tester);
    });
  });


  // -------------------------------------------------------------------------
  // The delete dialog: two blocks, one state value, and no way past either
  // -------------------------------------------------------------------------

  group('the delete dialog', () {
    /// Opens the dialog for [name] without settling, so a test can observe the
    /// state before the two reads come back.
    Future<void> openDelete(WidgetTester tester, String name) async {
      await tester.tap(find.byKey(kAccessRoleDeleteKey(name)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
    }

    testWidgets('not yet asked: it says the question is in flight and offers '
        'no Delete', (tester) async {
      await pumpSection(tester, overrides());
      store!.holdReads = Completer<void>();

      await openDelete(tester, 'Maintenance');

      expect(find.byKey(kAccessRoleDeleteCheckingKey), findsOneWidget);
      expect(find.text(kAccessRoleDeleteCheckingNote), findsOneWidget);
      expect(find.byKey(kAccessRoleDeleteConfirmKey), findsNothing,
          reason: 'a half-answered dialog must not render as unblocked');
      expect(find.byKey(kAccessRoleDeleteFreeKey), findsNothing);

      store!.holdReads!.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(kAccessRoleDeleteFreeKey), findsOneWidget);
    });

    testWidgets('unreadable: "cannot tell" renders its own message and offers '
        'no Delete — it does not render as "nobody holds it"', (tester) async {
      await pumpSection(tester, overrides());
      store!.listUsersThrows = StateError('the roster could not be read');

      await openDelete(tester, 'Maintenance');
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessRoleDeleteUnknownKey), findsOneWidget);
      expect(find.text(kAccessRoleDeleteUnknownNote), findsOneWidget);
      expect(find.byKey(kAccessRoleDeleteFreeKey), findsNothing,
          reason: '"could not ask" and "nobody holds it" are different claims '
              'and only one of them is safe to delete on');
      expect(find.byKey(kAccessRoleDeleteConfirmKey), findsNothing);
      expect(find.text('Close'), findsOneWidget,
          reason: 'blocked relabels Cancel to Close, because there is nothing '
              'to cancel');
    });

    testWidgets('nothing in the way: it says the delete costs nothing, offers '
        'Delete, and the role goes', (tester) async {
      await pumpSection(tester, overrides());

      await openDelete(tester, 'Maintenance');
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessRoleDeleteFreeKey), findsOneWidget);
      expect(find.text(kAccessRoleDeleteFreeNote('Maintenance')),
          findsOneWidget);
      expect(find.byKey(kAccessRoleDeleteConfirmKey), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget,
          reason: 'nothing is blocked, so the negative action is a Cancel');

      await tester.tap(find.byKey(kAccessRoleDeleteConfirmKey));
      await tester.pumpAndSettle();

      expect(await roleNamed('Maintenance'), isNull);
      expect(find.text('Maintenance'), findsNothing);
    });

    testWidgets('blocked because accounts hold it: the count and every holder '
        'name, and no confirming action', (tester) async {
      // A second role grants `users` and somebody holds it, so the lockout
      // check stands aside and this is unambiguously the holders block.
      await makeUser('admin', 'Engineering');
      for (final name in ['gunna', 'jon', 'sigga']) {
        await makeUser(name, 'Maintenance');
      }
      await pumpSection(tester, overrides());

      await openDelete(tester, 'Maintenance');
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessAdminRefusalKey), findsOneWidget);
      expect(
        find.text(kAccessAdminRoleInUseNote('Maintenance', 3)),
        findsOneWidget,
        reason: '06-CONTEXT: "showing the count and names of the holders". '
            'The count is in the sentence — a sentence naming three people '
            'without saying "3" makes the reader count them',
      );
      expect(find.textContaining('3'), findsAtLeastNWidgets(1));
      for (final name in ['gunna', 'jon', 'sigga']) {
        expect(find.byKey(kAccessAdminNoticeNameKey(name)), findsOneWidget,
            reason: 'every holder is named, not just counted');
      }
      expect(find.byKey(kAccessRoleDeleteConfirmKey), findsNothing,
          reason: 'absent, not greyed: no sign-in resolves this, and a '
              'control that is present and always refuses teaches the '
              'operator to press it twice');
      expect(find.text(kAccessAdminBreakGlassNote), findsNothing,
          reason: 'this is not a lockout; pointing a commissioning engineer '
              'at DELETE FROM app_user for it would be advice that breaks '
              'things');
    });

    testWidgets('blocked because it would leave nobody managing access: the '
        'count, the holders and the break-glass sentence', (tester) async {
      await makeUser('admin', 'Engineering');
      await makeUser('sigga', 'Engineering');
      await pumpSection(tester, overrides());

      await openDelete(tester, 'Engineering');
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessAdminRefusalKey), findsOneWidget);
      expect(
        find.text(kAccessAdminLastUsersHolderNote('Engineering', 2)),
        findsOneWidget,
        reason: 'the same count-and-names shape as the holders block — 06-02 '
            'runs the lockout check first because moving holders off a role '
            'is a fix the operator can perform and a plant with nobody able '
            'to manage roles has no fix inside the application at all',
      );
      for (final name in ['admin', 'sigga']) {
        expect(find.byKey(kAccessAdminNoticeNameKey(name)), findsOneWidget);
      }
      expect(find.text(kAccessAdminBreakGlassNote), findsOneWidget,
          reason: 'there is no override, and there is a documented way back');
      expect(find.byKey(kAccessRoleDeleteConfirmKey), findsNothing);
    });

    testWidgets('both blocked states offer zero confirming actions and zero '
        'text fields', (tester) async {
      await makeUser('admin', 'Engineering');
      for (final name in ['gunna', 'jon']) {
        await makeUser(name, 'Maintenance');
      }
      await pumpSection(tester, overrides());

      for (final name in ['Maintenance', 'Engineering']) {
        await openDelete(tester, name);
        await tester.pumpAndSettle();

        expect(find.byKey(kAccessRoleDeleteConfirmKey), findsNothing,
            reason: '$name: the instruction takes the action\'s place');
        expect(
          find.descendant(
              of: find.byType(StandardDialogFrame),
              matching: find.byType(TextField)),
          findsNothing,
          reason: '06-CONTEXT rejects a typed-confirmation override by name — '
              '"no destructive override is offered" — and there is no '
              'reassign-then-delete either; both are in its deferred list',
        );
        expect(find.text('Close'), findsOneWidget);

        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
      }
    });

    testWidgets('the losing race on holders re-renders the same dialog with '
        'the newer list rather than raising an error', (tester) async {
      await makeUser('admin', 'Engineering');
      await pumpSection(tester, overrides());

      await openDelete(tester, 'Maintenance');
      await tester.pumpAndSettle();
      expect(find.byKey(kAccessRoleDeleteFreeKey), findsOneWidget,
          reason: 'the pre-check saw nobody holding it');

      // Another station moved two accounts onto the role between the question
      // and the statement.
      store!.deleteThrowsOnce =
          const RoleInUseException('Maintenance', ['gunna', 'sigga']);
      await tester.tap(find.byKey(kAccessRoleDeleteConfirmKey));
      await tester.pumpAndSettle();

      expect(find.byType(StandardDialogFrame), findsOneWidget,
          reason: 'the same dialog telling the operator a truer thing, not an '
              'error about a failed operation');
      expect(find.text(kAccessAdminRoleInUseNote('Maintenance', 2)),
          findsOneWidget);
      expect(find.byKey(kAccessAdminNoticeNameKey('gunna')), findsOneWidget);
      expect(find.byKey(kAccessAdminNoticeNameKey('sigga')), findsOneWidget);
      expect(find.byKey(kAccessRoleDeleteConfirmKey), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(await roleNamed('Maintenance'), isNotNull);
    });

    testWidgets('the losing race on the lockout re-renders the same dialog '
        'with the newer refusal', (tester) async {
      await makeUser('admin', 'Engineering');
      await pumpSection(tester, overrides());

      await openDelete(tester, 'Maintenance');
      await tester.pumpAndSettle();
      expect(find.byKey(kAccessRoleDeleteFreeKey), findsOneWidget);

      // Another station unticked `users` from every other granting role
      // between the question and the statement.
      store!.deleteThrowsOnce =
          const LastUsersHolderException('Maintenance', ['admin']);
      await tester.tap(find.byKey(kAccessRoleDeleteConfirmKey));
      await tester.pumpAndSettle();

      expect(find.byType(StandardDialogFrame), findsOneWidget);
      expect(find.text(kAccessAdminLastUsersHolderNote('Maintenance', 1)),
          findsOneWidget);
      expect(find.text(kAccessAdminBreakGlassNote), findsOneWidget);
      expect(find.byKey(kAccessRoleDeleteConfirmKey), findsNothing);
      expect(await roleNamed('Maintenance'), isNotNull);
    });

    testWidgets('an AccessDenied leaves the dialog open, so the operator can '
        'sign in from the shared prompt and press Delete again', (tester) async {
      session = _anonymous();
      await pumpSection(tester, overrides());

      await openDelete(tester, 'Maintenance');
      await tester.pumpAndSettle();

      final confirm = tester
          .widget<ButtonStyleButton>(find.byKey(kAccessRoleDeleteConfirmKey));
      expect(confirm.onPressed, isNotNull,
          reason: 'a permission refusal is explained, not hidden — the '
              'control stays pressable');

      await tester.tap(find.byKey(kAccessRoleDeleteConfirmKey));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessDeniedBodyKey), findsOneWidget);
      expect(find.text(kAccessDeniedGroupNote(AccessGroup.users)),
          findsOneWidget);
      expect(find.byKey(kAccessRoleDeleteFreeKey), findsOneWidget,
          reason: 'the dialog stays open on purpose');
      expect(await roleNamed('Maintenance'), isNotNull);
    });
  });

  // -------------------------------------------------------------------------
  // A sanity check on the shared notice frame: the section renders neither
  // block until it has something to say.
  // -------------------------------------------------------------------------

  testWidgets('no warning and no refusal is rendered by a list at rest',
      (tester) async {
    await pumpSection(tester, overrides());

    expect(find.byKey(kAccessOperatorWarningKey), findsNothing);
    expect(find.byKey(kAccessAdminRefusalKey), findsNothing);

    // The editor is closed, so no checkbox is on screen either.
    expect(find.byType(CheckboxListTile), findsNothing);
    await openEditor(tester, 'Maintenance');
    expect(find.byType(CheckboxListTile), findsNWidgets(AccessGroup.values.length));
  });
}

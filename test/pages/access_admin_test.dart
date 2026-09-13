/// The administration page — the one screen that holds both halves of the
/// milestone's admin surface (06-CONTEXT "Roles Screen": *"One page, two
/// sections"*).
///
/// 06-07 and 06-08 already prove what each section says on its own. What only
/// the assembled page can be asked is:
///
///  * that the page is a `Page`/`Body` pair, so every widget test and every
///    golden pumps the body without a Beamer ancestor — `BaseScaffold` calls
///    `context.currentBeamLocation` and cannot be pumped without one,
///  * that the roles section is **above** the users section, which is the
///    commissioning order the deployment doc's new §4 sequence depends on:
///    roles first, then accounts,
///  * that the page — unlike either section — shows a progress indicator while
///    the store handle resolves, because `access_gate.dart` forbids a
///    page-level blank and `first_user.dart` states the rule: a blank page
///    reads as broken,
///  * that a window too short for two variable-height lists scrolls rather
///    than clipping, and
///  * that no note sits at the foot of the page any more.
///
/// The store is real, over a real in-memory database, for the reason
/// `access_roles_section_test.dart` gives: "the roles rendered" is then read
/// back through the same path a station uses. Nothing here writes, so there is
/// no recording subclass and no denial wiring — this page composes, and the
/// two sections own every write.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/access_admin_store.dart';
import 'package:tfc/pages/access_admin.dart';
import 'package:tfc/pages/access_session_section.dart';
import 'package:tfc/pages/access_roles_section.dart';
import 'package:tfc/pages/access_users_section.dart';
import 'package:tfc/providers/access_admin.dart';
import 'package:tfc/widgets/base_scaffold.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_repository.dart';
import 'package:tfc_dart/core/database_drift.dart';

// ---------------------------------------------------------------------------
// Doubles
// ---------------------------------------------------------------------------

class _RecordingSink implements AuditSink {
  final List<AuditRecord> rows = [];

  @override
  Future<void> record(AuditRecord entry) async => rows.add(entry);
}

// ---------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------

/// The session this page is gated for.
AccessSession _withUsers() => const AccessSession(
      user: AuthenticatedUser(username: 'admin', roleName: 'Engineering'),
      groups: {AccessGroup.operate, AccessGroup.configure, AccessGroup.users},
    );

/// The engineer the `users` gate exists for — they may edit a page and may not
/// re-scope who may write what. On a station they never reach this route, but
/// the page itself holds no gate, so it renders the same sections to them.
AccessSession _configureOnly() => const AccessSession(
      user: AuthenticatedUser(username: 'engineer', roleName: 'Engineering'),
      groups: {
        AccessGroup.operate,
        AccessGroup.setpoints,
        AccessGroup.device,
        AccessGroup.configure,
      },
    );

const String _kStation = 'SVN-NES-OT-CL02';

void main() {
  late AppDatabase db;
  late AccessRepository repository;
  late _RecordingSink sink;
  late AccessSession session;

  setUp(() async {
    // No `SharedPreferences` harness and no KDF override, unlike the two
    // section tests: nothing on this page writes, so no account is hashed, and
    // the store handle is overridden directly rather than resolved through
    // `accessRepositoryProvider` and its preference-backed config.
    db = AppDatabase.inMemoryForTest();
    // Force the migration, so the four seeded roles exist before the page asks
    // for them.
    await db.customSelect('SELECT 1').getSingle();
    repository = AccessRepository(db);
    sink = _RecordingSink();
    session = _withUsers();
  });

  tearDown(() async {
    await db.close();
  });

  /// The store the two sections reach, over the real tables.
  ///
  /// No `onDenied`: nothing on this page writes, so no refusal can be raised
  /// from it, and wiring a denial channel here would only be a second place
  /// for the sections' own tests to disagree with.
  List<Override> overrides({
    bool noDatabase = false,
    Object? storeError,
    bool storeNeverResolves = false,
  }) =>
      [
        accessAdminStoreProvider.overrideWith((ref) async {
          if (storeNeverResolves) {
            return Completer<AccessAdminStore?>().future;
          }
          if (storeError != null) throw storeError;
          if (noDatabase) return null;
          return AccessAdminStore(
            repository: repository,
            session: () => session,
            audit: sink,
            station: _kStation,
          );
        }),
      ];

  /// The body alone — never the page. [BaseScaffold] calls
  /// `context.currentBeamLocation`, so pumping [AccessAdminPage] here would
  /// fail for a routing reason that has nothing to do with any claim below.
  Widget host(List<Override> o) => ProviderScope(
        overrides: o,
        child: const MaterialApp(
          home: Scaffold(body: AccessAdminBody()),
        ),
      );

  /// Pumps the body on a panel-sized surface.
  ///
  /// The default 800x600 test window is shorter than two unscrolled sections,
  /// so on it every one of these assertions would be about where the page
  /// wraps rather than about what it says. A station is 1920x1080; the
  /// short-window claims below set their own size deliberately.
  ///
  /// [settle] is off for the one case that never settles: a spinner animates
  /// forever, so `pumpAndSettle` on the unresolved-store page times out rather
  /// than reporting anything about the page.
  Future<void> pumpBody(
    WidgetTester tester,
    List<Override> o, {
    Size size = const Size(1400, 2600),
    bool settle = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(host(o));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  // -------------------------------------------------------------------------
  // The Page/Body split
  // -------------------------------------------------------------------------

  group('the page/body split', () {
    testWidgets(
        'the page is field-less and returns a BaseScaffold whose body is the '
        'AccessAdminBody', (tester) async {
      // Built, not pumped. `BaseScaffold` needs a Beamer ancestor; the claim
      // here is about what the page hands it, which `build` answers directly.
      late BuildContext captured;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(builder: (context) {
            captured = context;
            return const SizedBox.shrink();
          }),
        ),
      );

      const page = AccessAdminPage();
      final built = page.build(captured);

      expect(built, isA<BaseScaffold>(),
          reason: 'the route target is a scaffold; everything testable lives '
              'in the body');
      final scaffold = built as BaseScaffold;
      expect(scaffold.title, kAccessAdminTitle,
          reason: 'one title string, repeated by the route table and the '
              'Advanced menu entry in 06-10');
      expect(scaffold.body, isA<AccessAdminBody>());
    });

    test('the page is const-constructible, so createLocationBuilder can const '
        'it', () {
      // The `const` list below is the whole assertion, and it is a
      // compile-time one: this stops compiling the moment the page grows a
      // field that is not `const`-able or a constructor that is not `const`.
      // `createLocationBuilder` registers `FirstUserPage` exactly this way, and
      // 06-10 registers this page beside it.
      const routeTargets = <Widget>[AccessAdminPage()];
      expect(routeTargets.single, isA<AccessAdminPage>());
    });
  });

  // -------------------------------------------------------------------------
  // The stacking order
  // -------------------------------------------------------------------------

  group('the two sections', () {
    testWidgets('roles render above users — the commissioning order',
        (tester) async {
      await pumpBody(tester, overrides());

      expect(find.byKey(kAccessRolesSectionKey), findsOneWidget);
      expect(find.byKey(kAccessUsersSectionKey), findsOneWidget);

      // Rendered offsets, not tree order: a Column child list is not evidence
      // about what the operator sees, and the deployment doc's commissioning
      // sequence — roles, then accounts — is a claim about the screen.
      final roles = tester.getTopLeft(find.byKey(kAccessRolesSectionKey)).dy;
      final users = tester.getTopLeft(find.byKey(kAccessUsersSectionKey)).dy;
      expect(roles, lessThan(users),
          reason: 'roles are created first at commissioning, so the section '
              'that creates them is the one read first');
    });

    testWidgets('the Session card renders below users — the station knob '
        'after the people', (tester) async {
      await pumpBody(tester, overrides());

      expect(find.byKey(kAccessSessionSectionKey), findsOneWidget);
      final users = tester.getTopLeft(find.byKey(kAccessUsersSectionKey)).dy;
      final session =
          tester.getTopLeft(find.byKey(kAccessSessionSectionKey)).dy;
      expect(users, lessThan(session));
    });

    testWidgets('a station with no database still renders both sections, each '
        'with its own message', (tester) async {
      await pumpBody(tester, overrides(noDatabase: true));

      expect(find.byKey(kAccessRolesNoDatabaseKey), findsOneWidget);
      expect(find.byKey(kAccessUsersNoDatabaseKey), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: 'null is a resolved answer, not a pending one');
    });

    testWidgets('a store that failed leaves each section saying so in its own '
        'words', (tester) async {
      await pumpBody(
          tester, overrides(storeError: StateError('no connection')));

      expect(find.byKey(kAccessRolesUnavailableKey), findsOneWidget);
      expect(find.byKey(kAccessUsersUnavailableKey), findsOneWidget);
      expect(find.byKey(kAccessAdminLoadingKey), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  // The loading state the sections do not own
  // -------------------------------------------------------------------------

  group('while the store handle resolves', () {
    testWidgets('the page shows a progress indicator, never a blank',
        (tester) async {
      await pumpBody(tester, overrides(storeNeverResolves: true),
          settle: false);

      expect(find.byKey(kAccessAdminLoadingKey), findsOneWidget,
          reason: 'first_user.dart: "a progress indicator rather than an empty '
              'box: this route is reached deliberately, and a blank page reads '
              'as broken"');
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // And nothing else, so "still deciding" cannot be read as either
      // terminal state.
      expect(find.byKey(kAccessRolesSectionKey), findsNothing);
      expect(find.byKey(kAccessUsersSectionKey), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  // A window too short for two variable-height lists
  // -------------------------------------------------------------------------

  group('a short window', () {
    testWidgets('scrolls rather than clipping', (tester) async {
      // Well below kAccessAdminMinContentHeight: the case a panel in a cabinet
      // door, or a windowed session on a laptop, actually produces.
      await pumpBody(tester, overrides(), size: const Size(700, 320));

      expect(find.byType(Scrollable), findsWidgets,
          reason: 'both sections are unbounded and unscrolled by construction; '
              'the composing page owns the scroll view');
      expect(tester.takeException(), isNull,
          reason: 'a RenderFlex overflow is reported as an exception — this is '
              'the assertion that the page did not clip');

      // The bottom half is reachable, not merely laid out off-screen.
      expect(find.byKey(kAccessUsersSectionKey), findsOneWidget);
    });

    testWidgets('a tall window lays the same page out without an overflow',
        (tester) async {
      await pumpBody(tester, overrides(), size: const Size(1920, 1080));

      expect(tester.takeException(), isNull);
      expect(find.byKey(kAccessRolesSectionKey), findsOneWidget);
      expect(find.byKey(kAccessUsersSectionKey), findsOneWidget);
    });

    test('the height constants are the sum they claim to be', () {
      expect(kAccessAdminMinContentHeight,
          kAccessAdminChromeHeight + kAccessAdminMinListsHeight,
          reason: 'the threshold is derived from the two measurements, not '
              'nudged independently of them');
      expect(kAccessAdminChromeHeight, greaterThan(0));
      expect(kAccessAdminMinListsHeight, greaterThan(0));
    });
  });

  // -------------------------------------------------------------------------
  // The page composes and nothing else
  // -------------------------------------------------------------------------

  group('the body composes', () {
    testWidgets('a session without users sees the same two sections — this '
        'page holds no gate of its own', (tester) async {
      session = _configureOnly();
      await pumpBody(tester, overrides());

      // The gate is at the route (06-10), exactly as it is for the other eight
      // raised routes. A second gate here would be a second place to get it
      // wrong.
      expect(find.byKey(kAccessRolesSectionKey), findsOneWidget);
      expect(find.byKey(kAccessUsersSectionKey), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // No note at the foot
  //
  // The page carried a one-sentence "records who changed what … not a
  // security boundary" card here. It was taken off the screen on request; the
  // claim itself still stands in `docs/access-control-spec.md` §8 and
  // `docs/access-control-deployment.md` §1, for the person doing the
  // deployment.
  // -------------------------------------------------------------------------

  group('no note at the foot of the page', () {
    testWidgets('the page ends with the session section', (tester) async {
      await pumpBody(tester, overrides());

      expect(find.textContaining('records who changed what'), findsNothing);
      expect(find.textContaining('security boundary'), findsNothing);
      expect(find.byKey(kAccessSessionSectionKey), findsOneWidget);
    });
  });
}

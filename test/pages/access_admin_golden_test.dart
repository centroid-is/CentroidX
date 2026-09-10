/// Four goldens of the administration screen — the milestone's last new page.
///
///  * `access_admin_elevated.png`         — the page as the person who commissions a
///    station sees it: three roles with their group summaries and holder counts, three
///    accounts under all four column headings (one of them never signed in), and the
///    "guardrail, not security" note **collapsed**.
///  * `access_admin_operator_warning.png` — the role editor open on `Operator`: the
///    seven `CheckboxListTile`s with their labels *and* their descriptions, in
///    `AccessGroup.values` order, under the persistent warning banner. This is the
///    ROADMAP's named deliverable for the phase.
///  * `access_admin_lockout_refused.png`  — the delete dialog on the only role granting
///    `users`, blocked: the refusal sentence, the remaining holders named, the pointer
///    at the deployment doc's break-glass section, and **no confirming action** anywhere
///    in the frame. There is no typed-confirmation escape and the picture must not look
///    as though there is one.
///  * `access_admin_locked.png`           — the route as a session without `users` meets
///    it: the lock, the group named, the way out still in the app bar and the
///    navigation bar.
///
/// **[AccessAdminBody], never [AccessAdminPage], for the three body images.** The page is
/// a `BaseScaffold` wrapper and `BaseScaffold` calls `context.currentBeamLocation`, so it
/// cannot be pumped without a Beamer ancestor — 06-09 split the two for exactly this. The
/// locked image is the one exception: it is *about* the scaffold the gate puts up, so it
/// brings a router.
///
/// **The locked image is staged from literals.** `AccessGroup.users` from the enum and
/// [_kRouteTitle] as a string in this file. It deliberately does not read the route map's
/// constants: those are written in the same wave as this plan and may not exist at the
/// moment this file is compiled, and the route test is what pins the route's real group
/// and title. A golden's job here is an image, not a route assertion.
///
/// **Fonts are loaded here, twice.** `test/pages/` has no `flutter_test_config.dart` of
/// its own, so it uses `test/flutter_test_config.dart`, which registers **no font at
/// all**; and `lib/theme.dart` names `'roboto-mono'` as the theme's family. Without both
/// registrations every themed `Text` captures as Ahem rectangles and the question these
/// images exist to answer — are the seven descriptions legible? — cannot be asked.
///
/// **The muted (ISA-101) palette.** `HmiStateColors` falls back to `solarizedLight`
/// outside a themed app, which would put violet into pictures of a deliberately muted
/// page. The warning banner in particular has to read as the theme's warning surface and
/// not as orange or red: orange means forced or elevated, red is the plant's fault
/// colour, and nothing on this screen is either.
///
/// **Pinned with `withClock`, and with local-time fixtures.** The account rows render
/// `createdAt` and `lastLoginAt` through `DateFormat(...).format(at.toLocal())`, so the
/// fixture timestamps below are constructed as **local** `DateTime`s — a UTC one would
/// render differently on a machine in another zone and make this baseline unreproducible.
/// The same reasoning pins the shell header's clock.
///
/// **Every fixture, fake and override here is this file's own.** Importing another test
/// file executes its top-level state and makes a baseline nobody can reproduce.
///
/// To update: flutter test test/pages/access_admin_golden_test.dart --update-goldens --run-skipped
@Tags(['golden'])
library;

import 'dart:io' show File, Platform;

import 'package:beamer/beamer.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart' show ByteData, FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/access_admin_store.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/pages/access_admin.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc_dart/core/preferences.dart' show PreferencesApi;
import 'package:tfc/pages/access_roles_section.dart';
import 'package:tfc/pages/access_users_section.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/access_admin.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/theme.dart' show muted;
import 'package:tfc/widgets/access_admin_notice.dart';
import 'package:tfc/widgets/access_gate.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_repository.dart';

import '../helpers/golden_tolerance.dart';

// ---------------------------------------------------------------------------
// Fixtures — this file's own
// ---------------------------------------------------------------------------

/// The gate's title on the locked image, as a literal.
///
/// Deliberately a string here rather than the route map's constant: the map is written
/// in the same wave as this plan and may not exist when this file is compiled. The route
/// test is what pins the route's real group and title; this file's job is a picture.
const String _kRouteTitle = 'Access';

/// The instant the shell header is frozen at.
///
/// Local, not UTC: `formatTimestamp` renders it for somebody standing in front of the
/// panel, so a UTC fixture would put a different string in the image on a machine in
/// another zone.
final DateTime _frozen = DateTime(2026, 8, 31, 9, 0);

/// Three roles rather than the seeded four, because three is enough to show the two
/// things a roles list is read for — what a role grants and how many hold it — and the
/// fourth would only make the Operator editor image taller.
///
/// Exactly one of them grants `users`, which is what makes the lockout image reachable at
/// all: delete `Engineering` and nobody can manage roles or accounts afterwards.
List<AccessRole> _roles() => const [
      AccessRole(name: kOperatorRoleName, groups: {AccessGroup.operate}),
      AccessRole(
        name: 'Shift Leader',
        groups: {AccessGroup.operate, AccessGroup.setpoints},
      ),
      AccessRole(
        name: 'Engineering',
        groups: {
          AccessGroup.operate,
          AccessGroup.setpoints,
          AccessGroup.device,
          AccessGroup.force,
          AccessGroup.configure,
          AccessGroup.administer,
          AccessGroup.users,
        },
      ),
    ];

/// An account row. There is no credential in it at all: `UserSummary` declares
/// none, so the placeholder hash and salt this fixture used to carry have
/// nowhere left to go — and nothing on this screen ever rendered them.
UserSummary _user(
  String username,
  String roleName, {
  required DateTime createdAt,
  DateTime? lastLoginAt,
}) =>
    UserSummary(
      username: username,
      roleName: roleName,
      createdAt: createdAt,
      lastLoginAt: lastLoginAt,
      stationAccount: false,
    );

/// The roster, in the order the repository returns it: by username.
///
/// `commissioning` has never signed in, which is the row a roster is actually read to
/// find — a commissioning account nobody uses — and it is why `kAccessUserNever` has to
/// be in one of these images.
///
/// Two of the three hold `Engineering`, so the lockout refusal names two holders and its
/// sentence has to pluralise.
List<UserSummary> _users() => [
      _user('admin', 'Engineering',
          createdAt: DateTime(2026, 6, 2, 8, 15),
          lastLoginAt: DateTime(2026, 8, 31, 7, 5)),
      _user('commissioning', 'Engineering',
          createdAt: DateTime(2026, 6, 2, 8, 20)),
      _user('linar', 'Shift Leader',
          createdAt: DateTime(2026, 7, 14, 6, 30),
          lastLoginAt: DateTime(2026, 8, 30, 22, 10)),
    ];

// ---------------------------------------------------------------------------
// Doubles
// ---------------------------------------------------------------------------

/// A store that **answers** the two reads this page makes and refuses everything else.
///
/// `first_user_golden_test.dart`'s double throws on every method because that page
/// touches no repository; this page reads, so the shape here is
/// `history_view_locked_delete_golden_test.dart`'s: answer the reads, and let the
/// inherited `noSuchMethod` be the tripwire for anything a rendering pass should never
/// have called. None of these images drives a write — the lockout one is blocked by the
/// dialog's own pre-check, before `deleteRole` is ever reached.
class _AnsweringStore extends Fake implements AccessAdminStore {
  _AnsweringStore({required this.roleRows, required this.userRows});

  final List<AccessRole> roleRows;
  final List<UserSummary> userRows;

  @override
  Future<List<AccessRole>> roles() async => roleRows;

  @override
  Future<List<UserSummary>> listUsers() async => userRows;
}

/// A repository that is merely *present*. Only the locked image's [AccessGate] asks,
/// and it asks nothing but whether one exists.
class _PresentRepository extends Fake implements AccessRepository {}

/// A session that resolves immediately to whatever the image needs.
///
/// Overriding [build] keeps the captured frame chosen rather than raced: the real
/// controller chain reaches the database, the preferences store and the station keychain,
/// and a frame captured before it settles is `AsyncLoading`.
class _FixedSession extends AccessSessionController {
  _FixedSession(this._session);

  final AccessSession _session;

  @override
  Future<AccessSession> build() async => _session;

  @override
  Future<AccessSignInResult> signIn(String username, String password) async =>
      AccessSignInResult.ok;

  @override
  Future<void> signOut() async {}

  @override
  void poke() {}
}

/// The administrator the `users` gate exists for — the person who commissions a station.
///
/// Nothing in [AccessAdminBody] renders the session; the gate at the route is what reads
/// it. It is pinned here anyway because it is the claim the three elevated images make:
/// this is the page as somebody who got past that gate sees it.
AccessSession _withUsers() => const AccessSession(
      user: AuthenticatedUser(
        username: 'admin',
        roleName: 'Engineering',
        displayName: 'Anna S',
      ),
      groups: {
        AccessGroup.operate,
        AccessGroup.setpoints,
        AccessGroup.device,
        AccessGroup.force,
        AccessGroup.configure,
        AccessGroup.administer,
        AccessGroup.users,
      },
    );

/// A panel with nobody signed in — what the locked image is of.
AccessSession _anonymous() =>
    AccessSession.anonymous(const {AccessGroup.operate});

// ---------------------------------------------------------------------------
// Hosts
// ---------------------------------------------------------------------------

const Key _boundary = Key('access_admin_golden');

/// An empty in-memory device-local store: the card then shows the default
/// 15 minutes, which is what a fresh station shows.
class _MemoryPrefs extends Fake implements PreferencesApi {
  final Map<String, Object> _store = {};

  @override
  Future<int?> getInt(String key) async => _store[key] as int?;

  @override
  Future<void> setInt(String key, int value) async => _store[key] = value;
}

List<Override> _overrides({
  required AccessSession session,
  AccessAdminStore? store,
}) =>
    [
      accessRepositoryProvider.overrideWith((ref) async => _PresentRepository()),
      accessAdminStoreProvider.overrideWith((ref) async => store),
      accessSessionProvider.overrideWith(() => _FixedSession(session)),
      // The Session card reads the device-local store for the inactivity
      // timeout; without an override the platform channel never answers in a
      // test and the card's field renders empty — a baseline of a state no
      // settled station shows.
      localPreferencesProvider.overrideWithValue(_MemoryPrefs()),
    ];

/// The three body images' host.
///
/// The surface is painted **inside** the boundary rather than left to the `Scaffold`: a
/// `RepaintBoundary` captures only its own subtree and the Scaffold paints its background
/// behind the body, so a boundary placed at `Scaffold.body` captures a transparent image
/// that looks like a white page in any viewer. Phase 1 shipped two of those before the
/// trap was written down.
Widget _pageHost({
  required ThemeData theme,
  required AccessAdminStore store,
  required AccessSession session,
}) {
  return ProviderScope(
    overrides: _overrides(session: session, store: store),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: Scaffold(
        backgroundColor: theme.colorScheme.surface,
        body: RepaintBoundary(
          key: _boundary,
          child: ColoredBox(
            color: theme.colorScheme.surface,
            child: const AccessAdminBody(),
          ),
        ),
      ),
    ),
  );
}

/// The lockout image's host.
///
/// Identical content to [_pageHost], but the whole `MaterialApp` is what gets captured:
/// the dialog lives in the root navigator's overlay, which is outside any boundary placed
/// inside the body, so a boundary capture would photograph the page and miss the refusal
/// entirely.
Widget _dialogHost({
  required ThemeData theme,
  required AccessAdminStore store,
  required AccessSession session,
}) {
  return ProviderScope(
    overrides: _overrides(session: session, store: store),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: Scaffold(
        backgroundColor: theme.colorScheme.surface,
        body: const AccessAdminBody(),
      ),
    ),
  );
}

/// The menu `BaseScaffold` draws its navigation bar from.
///
/// Two top-level entries plus the Advanced parent is the app's own shape and the smallest
/// one that builds — `NavigationBar` asserts on fewer than two destinations. The paths are
/// spelled out here rather than looked up for the reason in the library comment.
void _registerShellMenu() {
  final registry = RouteRegistry();
  registry.menuItems.clear();
  registry
      .addMenuItem(const MenuItem(label: 'Home', path: '/', icon: Icons.home));
  registry.addMenuItem(const MenuItem(
    label: 'Advanced',
    path: '/advanced',
    icon: Icons.settings,
    children: [
      MenuItem(
          label: _kRouteTitle,
          path: '/advanced/access',
          icon: Icons.manage_accounts),
    ],
  ));
}

/// The router the locked image needs: the gated route, plus a `/` so the navigation bar
/// has a second destination to show.
BeamerDelegate _shellRouter(Widget gate) => BeamerDelegate(
      initialPath: '/advanced/access',
      locationBuilder: RoutesLocationBuilder(routes: {
        '/': (context, state, data) => const BeamPage(
              key: ValueKey('/'),
              title: 'Home',
              child: Scaffold(body: Center(child: Text('home-body'))),
            ),
        '/advanced/access': (context, state, data) => BeamPage(
              key: const ValueKey('/advanced/access'),
              title: _kRouteTitle,
              child: gate,
            ),
      }).call,
    );

/// The Beamer shell the gate is pumped in.
///
/// [BaseScaffold] calls `context.currentBeamLocation`, so it cannot be pumped without a
/// router above it, and the `ProviderScope` has to sit above `MaterialApp.router` so the
/// root navigator's overlay is inside it.
Widget _shellHost({
  required ThemeData theme,
  required BeamerDelegate router,
  required AccessAdminStore store,
  required AccessSession session,
}) {
  return ProviderScope(
    overrides: _overrides(session: session, store: store),
    child: BeamerProvider(
      routerDelegate: router,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: theme,
        routerDelegate: router,
        routeInformationParser: BeamerParser(),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

void _sizeView(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Loads the two families the theme needs plus the icon font.
Future<void> _loadRealFonts() async {
  Future<void> loadFont(String family, String path) async {
    final file = File(path);
    if (!file.existsSync()) return;
    await (FontLoader(family)
          ..addFont(Future.value(ByteData.view(file.readAsBytesSync().buffer))))
        .load();
  }

  await loadFont('Roboto', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');
  await loadFont('roboto-mono', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');

  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  for (final candidate in <String>[
    if (flutterRoot != null)
      '$flutterRoot/bin/cache/artifacts/material_fonts/'
          'MaterialIcons-Regular.otf',
    '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/'
        'MaterialIcons-Regular.otf',
  ]) {
    if (File(candidate).existsSync()) {
      await loadFont('MaterialIcons', candidate);
      break;
    }
  }
}

/// Asserts nothing in the frame was cut off by the bottom of the viewport.
///
/// The page owns an unconditional `SingleChildScrollView`, so content taller than the
/// window is *scrolled* rather than overflowing — which means an image of it would be
/// silently truncated and would still pass its own baseline. `find.text` cannot see that
/// and neither can a diff against a wrong picture.
void _expectNothingClipped(WidgetTester tester, Finder last, double height) {
  expect(
    tester.getBottomLeft(last).dy,
    lessThanOrEqualTo(height),
    reason: 'the page is taller than the captured frame, so the image would be '
        'a truncated page that still matches its own baseline',
  );
}

void main() {
  final (light, _) = muted();

  // Frames of prose on a real theme. The 0.01% default absorbs antialiasing drift on
  // small painter goldens, not on several hundred lines of text.
  useTolerantGoldenComparator(tolerance: 0.002);

  group('access administration goldens',
      skip: !Platform.isMacOS ? 'Golden tests only run on macOS' : null, () {
    setUpAll(_loadRealFonts);

    tearDown(() => RouteRegistry().menuItems.clear());

    testWidgets('the page, elevated, with the honesty note at its foot',
        (tester) async {
      await withClock(Clock.fixed(_frozen), () async {
        const size = Size(900, 1120);
        _sizeView(tester, size);

        await tester.pumpWidget(_pageHost(
          theme: light,
          store: _AnsweringStore(roleRows: _roles(), userRows: _users()),
          session: _withUsers(),
        ));
        await tester.pumpAndSettle();

        // The state key, asserted before the pixels are compared, so the image is not a
        // frame that had not decided yet.
        expect(find.byKey(kAccessAdminHonestySummaryKey), findsOneWidget);
        expect(find.byKey(kAccessAdminLoadingKey), findsNothing);
        // One sentence, with nothing to open. The note used to be an
        // `ExpansionTile`, and one caught mid-expansion would have made this
        // baseline a function of how many frames the harness pumped.
        expect(find.byType(ExpansionTile), findsNothing);

        // Both lists rendered rather than either terminal state.
        expect(find.byKey(kAccessRolesSectionKey), findsOneWidget);
        expect(find.byKey(kAccessUsersSectionKey), findsOneWidget);
        expect(find.byKey(kAccessUsersHeaderKey), findsOneWidget);
        for (final role in _roles()) {
          expect(find.byKey(kAccessRoleTileKey(role.name)), findsOneWidget);
        }
        for (final user in _users()) {
          expect(find.byKey(kAccessUserRowKey(user.username)), findsOneWidget);
        }
        // The row a roster is read to find.
        expect(find.text(kAccessUserNever), findsOneWidget);
        expect(tester.takeException(), isNull);

        _expectNothingClipped(
            tester, find.byKey(kAccessAdminHonestyKey), size.height);

        await expectLater(
          find.byKey(_boundary),
          matchesGoldenFile('goldens/access_admin_elevated.png'),
        );
      });
    });

    testWidgets('the Operator editor open, with the warning above the boxes',
        (tester) async {
      await withClock(Clock.fixed(_frozen), () async {
        const size = Size(900, 1640);
        _sizeView(tester, size);

        await tester.pumpWidget(_pageHost(
          theme: light,
          store: _AnsweringStore(roleRows: _roles(), userRows: _users()),
          session: _withUsers(),
        ));
        await tester.pumpAndSettle();

        // `Operator` and no other row: the banner is rendered for the protected row
        // alone, and it is the row that governs every logged-out panel.
        await tester.tap(find.byKey(kAccessRoleTileKey(kOperatorRoleName)));
        await tester.pumpAndSettle();

        // The state key.
        expect(find.byKey(kAccessOperatorWarningKey), findsOneWidget);

        // All seven, each with a label and a description, in the enum's order. An eye
        // can count seven boxes; it cannot see that the seventh is `users` rather than
        // a repeat.
        for (final group in AccessGroup.values) {
          expect(find.byKey(kAccessRoleGroupKey(kOperatorRoleName, group)),
              findsOneWidget);
          expect(find.text(group.label), findsWidgets);
          expect(find.text(group.description), findsOneWidget);
          // And legible, which is a different claim: `find.text` passes on a
          // string that rendered as one ellipsised line. The seven descriptions
          // are the longest strings on the page and a clipped one is exactly the
          // failure 06-01 exists to prevent, so each is checked at the render
          // object rather than at the widget.
          final paragraph = tester.renderObject<RenderParagraph>(
            find.descendant(
              of: find.text(group.description),
              matching: find.byType(RichText),
            ),
          );
          expect(paragraph.didExceedMaxLines, isFalse,
              reason: '"${group.description}" is clipped');
        }
        // The warning is above them, not beside or below. `lessThanOrEqualTo`
        // rather than `lessThan` because the two abut exactly — the banner's
        // bottom edge is the first checkbox's top edge, with no gap between
        // them — which is "above" and is also what the picture shows.
        final firstBox = find.byKey(
            kAccessRoleGroupKey(kOperatorRoleName, AccessGroup.values.first));
        expect(
          tester.getBottomLeft(find.byKey(kAccessOperatorWarningKey)).dy,
          lessThanOrEqualTo(tester.getTopLeft(firstBox).dy),
        );
        expect(
          tester.getTopLeft(find.byKey(kAccessOperatorWarningKey)).dy,
          lessThan(tester.getTopLeft(firstBox).dy),
        );
        // No other row opened with it.
        expect(find.byKey(kAccessAdminRefusalKey), findsNothing);
        expect(tester.takeException(), isNull);

        _expectNothingClipped(
            tester, find.byKey(kAccessAdminHonestyKey), size.height);

        await expectLater(
          find.byKey(_boundary),
          matchesGoldenFile('goldens/access_admin_operator_warning.png'),
        );
      });
    });

    testWidgets('the lockout refusal, with no way past it', (tester) async {
      await withClock(Clock.fixed(_frozen), () async {
        _sizeView(tester, const Size(900, 760));

        await tester.pumpWidget(_dialogHost(
          theme: light,
          store: _AnsweringStore(roleRows: _roles(), userRows: _users()),
          session: _withUsers(),
        ));
        await tester.pumpAndSettle();

        // `Engineering` is the only role granting `users`, and two accounts hold it, so
        // deleting it is trip route (d): nobody would be able to manage roles or
        // accounts afterwards. The dialog's own pre-check refuses before anything is
        // written — no `deleteRole` reaches the store, which is why the double does not
        // implement one.
        await tester.tap(find.byKey(kAccessRoleDeleteKey('Engineering')));
        await tester.pumpAndSettle();

        // The state key.
        expect(find.byKey(kAccessAdminRefusalKey), findsOneWidget);

        // The sentence, with the count in it, and both remaining holders named beneath.
        expect(
          find.text(kAccessAdminLastUsersHolderNote('Engineering', 2)),
          findsOneWidget,
        );
        expect(find.byKey(kAccessAdminNoticeNameKey('admin')), findsOneWidget);
        expect(find.byKey(kAccessAdminNoticeNameKey('commissioning')),
            findsOneWidget);
        // The break-glass pointer, which is the only place this milestone points at it
        // from a screen.
        expect(find.text(kAccessAdminBreakGlassNote), findsOneWidget);

        // The claim the picture has to make and an eye can only half-check: there is no
        // confirming action in the frame at all — not greyed, absent — and nothing to
        // type into either. 06-CONTEXT rejected a typed-confirmation override outright.
        expect(find.byKey(kAccessRoleDeleteConfirmKey), findsNothing);
        // Scoped to the refusal dialog since the Session card gave the PAGE a
        // legitimate TextField; the claim was always about the dialog.
        expect(
            find.descendant(
                of: find.byKey(kAccessAdminRefusalKey),
                matching: find.byType(TextField)),
            findsNothing);
        expect(tester.takeException(), isNull);

        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/access_admin_lockout_refused.png'),
        );
      });
    });

    testWidgets('the route, met by a session without users', (tester) async {
      await withClock(Clock.fixed(_frozen), () async {
        _sizeView(tester, const Size(1280, 800));
        _registerShellMenu();

        // Group and title from literals. See the library comment: the route map's
        // constants are written in this same wave and may not exist yet, and the route
        // test is what pins them.
        final router = _shellRouter(const AccessGate(
          group: AccessGroup.users,
          title: _kRouteTitle,
          child: AccessAdminPage(),
        ));

        await tester.pumpWidget(_shellHost(
          theme: light,
          router: router,
          store: _AnsweringStore(roleRows: _roles(), userRows: _users()),
          session: _anonymous(),
        ));
        await tester.pumpAndSettle();

        // The state key.
        expect(find.byKey(kAccessLockedBodyKey), findsOneWidget);
        // The group is named on the page rather than left as "permission denied".
        expect(find.text(kAccessLockedGroupNote(AccessGroup.users)),
            findsOneWidget);
        // The page behind the gate is not built at all — no query, no subscription, no
        // roster on screen.
        expect(find.byType(AccessAdminBody), findsNothing);
        expect(find.byKey(kAccessRolesSectionKey), findsNothing);
        expect(find.byKey(kAccessUsersSectionKey), findsNothing);
        // And the operator can leave: locked is not a dead end.
        expect(find.byType(NavigationBar), findsOneWidget);
        expect(
          tester
              .widget<ElevatedButton>(find.byKey(kAccessLockedSignInKey))
              .onPressed,
          isNotNull,
          reason: 'a locked control is tappable and explains itself; a greyed '
              'one tells the operator the app is broken',
        );
        expect(tester.takeException(), isNull);

        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/access_admin_locked.png'),
        );
      });
    });
  });
}

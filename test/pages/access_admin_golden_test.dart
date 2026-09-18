/// Six goldens of the administration screen — the milestone's last new page.
///
///  * `access_admin_elevated.png`         — the page as the person who commissions a
///    station sees it: four roles with their group summaries and holder counts, the
///    anonymous account pinned first with only its two controls, three accounts under
///    all four column headings (one of them never signed in), and the
///    "guardrail, not security" note **collapsed**.
///  * `access_admin_operator_warning.png` — the role editor open on `Operator`, the role
///    the anonymous account holds: the seven `CheckboxListTile`s with their labels *and*
///    their descriptions, in `AccessGroup.values` order, under the banner saying a
///    logged-out panel holds it.
///  * `access_admin_anonymous_roles.png`  — the roles dialog open on the anonymous
///    account, with the banner saying a role ticked there reaches every logged-out
///    panel.
///  * `access_admin_lockout_refused.png`  — the delete dialog on the only role granting
///    `users`, blocked: the refusal sentence, the remaining holders named, the pointer
///    at the deployment doc's break-glass section, and **no confirming action** anywhere
///    in the frame. There is no typed-confirmation escape and the picture must not look
///    as though there is one.
///  * `access_admin_locked.png`           — the route as a session without `users` meets
///    it: the lock, the group named, the way out still in the app bar and the
///    navigation bar.
///  * `access_admin_roles_picker.png`     — the roles dialog open on an account that
///    holds two: tick boxes rather than radio buttons, the `primary` tag against the
///    first, each role's grants underneath, and the sentence saying a second role only
///    ever widens. This is the picture that has to make "one account, several roles"
///    legible at a glance — the roster cell behind it (`Shift Leader + Maintenance`)
///    reads as one person with two roles only if the dialog agrees.
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

import 'dart:convert' show jsonEncode;
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
import 'package:tfc/pages/access_admin_proposals.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/proposal_state.dart';
import 'package:tfc_dart/core/preferences.dart' show PreferencesApi;
import 'package:tfc/pages/access_roles_section.dart';
import 'package:tfc/pages/access_session_section.dart';
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
import '../helpers/golden_platform.dart';

// ---------------------------------------------------------------------------
// Fixtures — this file's own
// ---------------------------------------------------------------------------

/// The gate's title on the locked image, as a literal.
///
/// Deliberately a string here rather than the route map's constant: the map is written
/// in the same wave as this plan and may not exist when this file is compiled. The route
/// test is what pins the route's real group and title; this file's job is a picture.
const String _kRouteTitle = 'Users & roles';

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
      // Present so that an account can hold two of these at once, which is
      // what `linar` does below. It grants `device` and `force` and no
      // `setpoints`-only overlap with Shift Leader, so the union of the two is
      // visibly wider than either.
      AccessRole(
        name: 'Maintenance',
        groups: {
          AccessGroup.operate,
          AccessGroup.device,
          AccessGroup.force,
        },
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
  List<String> alsoHolds = const [],
  String? homePage,
  bool alarmAutoNavigate = false,
}) =>
    UserSummary(
      username: username,
      roleName: roleName,
      // The decoded list, not the column: the roster speaks [UserSummary],
      // which carries the extra roles already read back — there is no
      // `encodeAdditionalRoles` here and no credential columns either, because
      // the type has nowhere to put one.
      additionalRoles: alsoHolds,
      createdAt: createdAt,
      lastLoginAt: lastLoginAt,
      stationAccount: false,
      homePage: homePage,
      alarmAutoNavigate: alarmAutoNavigate,
    );

/// [u] with alarm auto-navigation on. By hand because [UserSummary] is the
/// roster DTO and has no `copyWith` — the drift row main's fixture used here
/// did.
UserSummary _navigating(UserSummary u) => UserSummary(
      username: u.username,
      roleName: u.roleName,
      displayName: u.displayName,
      stationAccount: u.stationAccount,
      hasPassword: u.hasPassword,
      createdAt: u.createdAt,
      lastLoginAt: u.lastLoginAt,
      allowedPages: u.allowedPages,
      additionalRoles: u.additionalRoles,
      inactivityTimeoutMinutes: u.inactivityTimeoutMinutes,
      homePage: u.homePage,
      alarmAutoNavigate: true,
    );

/// The roster, in the order the repository returns it: by username.
///
/// `commissioning` has never signed in, which is the row a roster is actually read to
/// find — a commissioning account nobody uses — and it is why `kAccessUserNever` has to
/// be in one of these images.
///
/// Two of the three hold `Engineering`, so the lockout refusal names two holders and its
/// sentence has to pluralise.
///
/// `linar` holds **two** roles, which is the whole point of one of these rows: the shift
/// leader who also maintains the line is the person the single-role model made a site
/// invent a combinatorial "Shift Leader + Maintenance" role for. The roster cell has to
/// show both, and it has to read as one person rather than as two — see
/// [kRoleLabelSeparator].
List<UserSummary> _users() => [
      _user('admin', 'Engineering',
          createdAt: DateTime(2026, 6, 2, 8, 15),
          lastLoginAt: DateTime(2026, 8, 31, 7, 5)),
      // The reserved account the seed writes into every database. The section
      // pins it first whatever order the store returns it in.
      _user(kAnonymousUsername, kOperatorRoleName,
          createdAt: DateTime(2026, 6, 2, 8, 0)),
      _user('commissioning', 'Engineering',
          createdAt: DateTime(2026, 6, 2, 8, 20)),
      _user('linar', 'Shift Leader',
          alsoHolds: const ['Maintenance'],
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
/// 15 minutes and an uncommitted panel, which is what a fresh station shows.
///
/// `getString` is here for the panel-account read-out. A `Fake` throws on
/// anything it does not implement, so leaving it out does not render a
/// neutral card — it renders one with the read-out silently missing.
class _MemoryPrefs extends Fake implements PreferencesApi {
  final Map<String, Object> _store = {};

  @override
  Future<int?> getInt(String key) async => _store[key] as int?;

  @override
  Future<void> setInt(String key, int value) async => _store[key] = value;

  @override
  Future<bool?> getBool(String key) async => _store[key] as bool?;

  @override
  Future<void> setBool(String key, bool value) async => _store[key] = value;

  @override
  Future<String?> getString(String key) async => _store[key] as String?;

  @override
  Future<void> setString(String key, String value) async => _store[key] = value;
}

List<Override> _overrides({
  required AccessSession session,
  AccessAdminStore? store,
  List<PendingProposal> proposals = const [],
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
      // The agent's batch, already in the queue when the page opens. Empty on
      // every image but the proposals one, so the others stay the page a
      // station shows with nothing proposed.
      proposalStateProvider.overrideWith((ref) {
        final notifier = ProposalStateNotifier();
        for (final p in proposals) {
          notifier.addProposal(p);
        }
        return notifier;
      }),
    ];

/// A proposal as the MCP server wraps one — an agent's, with the
/// `operator_id` no row ever reads.
PendingProposal _mcpProposal(int id, String type, String op,
        Map<String, dynamic> body) =>
    PendingProposal(
      id: id,
      proposalType: type,
      title: body['title'] as String? ?? 'proposal',
      proposalJson: jsonEncode({
        ...body,
        'operator_id': 'sweeper-agent',
        '_proposal_type': type,
        '_op': op,
      }),
      operatorId: 'sweeper-agent',
      createdAt: _frozen,
    );

/// A batch of three an agent might send: a create that will ask for a
/// password, a floor change, and a delete the store will refuse — so the
/// image shows the note, the words and a warning at once.
List<PendingProposal> _proposedBatch() => [
      _mcpProposal(-1, 'access_account', 'create', {
        'title': 'Account "bjarni"',
        'username': 'bjarni',
        'roles': ['Shift Leader', 'Maintenance'],
        'station_account': false,
      }),
      _mcpProposal(-2, 'access_account', 'update', {
        'title': 'Account "anonymous"',
        'username': kAnonymousUsername,
        'field': 'roles',
        'roles': ['Shift Leader'],
        'warnings': [
          'This is the "anonymous" account: every panel with nobody signed '
              'in will be able to: operate, setpoints.',
        ],
      }),
      _mcpProposal(-3, 'access_role', 'delete', {
        'title': 'Role "Maintenance"',
        'name': 'Maintenance',
        'groups': ['operate', 'device', 'force'],
        'holders': ['linar'],
        'warnings': [
          'BLOCKED at the accept while linar still holds it. Move them with '
              'set_account_roles first.',
        ],
      }),
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
  List<PendingProposal> proposals = const [],
}) {
  return ProviderScope(
    overrides: _overrides(session: session, store: store, proposals: proposals),
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

/// The slack a timestamp column must keep between its text and the column
/// beside it, in logical pixels.
///
/// Not a taste number. At zero the two dates paint end to end and the row
/// reads `2026-06-02 08:152026-08-31 07:05` — one long number rather than two
/// dates. 8 is the smallest gap the eye still resolves as a column boundary
/// and is comfortably clear of layout rounding.
const double _kMinTimestampGap = 8;

/// Every account row gives its two timestamps room to be two timestamps.
///
/// The pixels are already pinned by the baseline beside this, so why assert
/// it? Because a baseline argues from itself: `--update-goldens` accepts
/// whatever the code now renders, and a collision re-baselined is a collision
/// blessed. This says the number out loud, and the actions column has widened
/// twice at the four flex columns' expense — 192 -> 240 for Pages, 240 -> 288
/// for the timeout — with the second one landing the collision.
///
/// Measured against the text's intrinsic width rather than the cell rects:
/// adjacent `Expanded`s always abut, so the gap lives inside the cell, between
/// the glyphs and its edge. Only meaningful with the real face loaded — under
/// the test harness's default font this measures square Ahem boxes and answers
/// a question nobody asked, which is why it lives in this file.
void _expectTimestampColumnsHaveAGap(WidgetTester tester) {
  for (final user in _users()) {
    for (final key in [
      kAccessUserCreatedKey(user.username),
      kAccessUserLastLoginKey(user.username),
    ]) {
      final finder = find.byKey(key);
      final slack = tester.getRect(finder).width -
          tester
              .renderObject<RenderParagraph>(finder)
              .getMaxIntrinsicWidth(double.infinity);
      expect(
        slack,
        greaterThanOrEqualTo(_kMinTimestampGap),
        reason: 'the $key cell leaves its timestamp ${slack}px of slack; '
            'below $_kMinTimestampGap it runs into the next column',
      );
    }
  }
}

void main() {
  final (light, _) = muted();

  useTolerantGoldenComparator();

  group('access administration goldens',
      skip: goldenSkip, () {
    setUpAll(_loadRealFonts);

    tearDown(() => RouteRegistry().menuItems.clear());

    testWidgets('the page, elevated', (tester) async {
      await withClock(Clock.fixed(_frozen), () async {
        const size = Size(900, 1200);
        _sizeView(tester, size);

        await tester.pumpWidget(_pageHost(
          theme: light,
          store: _AnsweringStore(roleRows: _roles(), userRows: _users()),
          session: _withUsers(),
        ));
        await tester.pumpAndSettle();

        // The state key, asserted before the pixels are compared, so the image is not a
        // frame that had not decided yet.
        expect(find.byKey(kAccessSessionSectionKey), findsOneWidget);
        expect(find.byKey(kAccessAdminLoadingKey), findsNothing);

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
        // The anonymous account: first, tagged, and holding roles and pages only.
        expect(
          tester.getTopLeft(find.byKey(kAccessUserRowKey(kAnonymousUsername))).dy,
          lessThan(tester.getTopLeft(find.byKey(kAccessUserRowKey('admin'))).dy),
        );
        expect(find.byKey(kAccessUserAnonymousTagKey), findsOneWidget);
        expect(find.byKey(kAccessUserDeleteKey(kAnonymousUsername)), findsNothing);
        expect(find.byKey(kAccessRoleDeleteKey(kOperatorRoleName)), findsOneWidget);
        // A drag handle on every role and every person; none on anonymous,
        // which is pinned first.
        for (final role in _roles()) {
          expect(find.byKey(kAccessRoleDragHandleKey(role.name)), findsOneWidget);
        }
        for (final user in _users()) {
          expect(find.byKey(kAccessUserDragHandleKey(user.username)),
              user.username == kAnonymousUsername ? findsNothing : findsOneWidget);
        }
        expect(tester.takeException(), isNull);

        _expectNothingClipped(
            tester, find.byKey(kAccessSessionSectionKey), size.height);
        _expectTimestampColumnsHaveAGap(tester);

        await expectLater(
          find.byKey(_boundary),
          matchesGoldenFile('goldens/access_admin_elevated.png'),
        );
      });
    });

    testWidgets('the batch an agent proposed, listed above the sections it '
        'changes', (tester) async {
      await withClock(Clock.fixed(_frozen), () async {
        const size = Size(900, 1500);
        _sizeView(tester, size);

        await tester.pumpWidget(_pageHost(
          theme: light,
          store: _AnsweringStore(roleRows: _roles(), userRows: _users()),
          session: _withUsers(),
          proposals: _proposedBatch(),
        ));
        await tester.pumpAndSettle();

        // Staged, and above both sections rather than beside either.
        expect(find.byKey(kAccessAdminProposalsKey), findsOneWidget);
        expect(
          tester.getTopLeft(find.byKey(kAccessAdminProposalsKey)).dy,
          lessThan(tester.getTopLeft(find.byKey(kAccessRolesSectionKey)).dy),
        );
        // The three, in words, with the password note and both warnings.
        expect(find.textContaining('Create account "bjarni"'), findsOneWidget);
        expect(find.textContaining('this is every logged-out panel'),
            findsOneWidget);
        expect(find.text('Delete role "Maintenance".'), findsOneWidget);
        expect(find.text(kAccessAdminProposalsPasswordNote), findsOneWidget);
        expect(find.textContaining('BLOCKED at the accept'), findsOneWidget);
        // Nothing is applied by staging: the Fake store has no write to
        // call, and reaching one would have thrown.
        expect(tester.takeException(), isNull);

        _expectNothingClipped(
            tester, find.byKey(kAccessSessionSectionKey), size.height);

        await expectLater(
          find.byKey(_boundary),
          matchesGoldenFile('goldens/access_admin_proposals.png'),
        );
      });
    });

    testWidgets('a role the logged-out panel holds, open, with the warning above '
        'the boxes',
        (tester) async {
      await withClock(Clock.fixed(_frozen), () async {
        // Tall enough for the whole open editor: the seven group checkboxes,
        // and below them the Pages block with its two mode options and a row
        // per page. Raised from 1700 when the Pages block landed —
        // `_expectNothingClipped` is what caught the truncation rather than
        // letting a cut-off image quietly match its own new baseline.
        const size = Size(900, 2000);
        _sizeView(tester, size);

        await tester.pumpWidget(_pageHost(
          theme: light,
          store: _AnsweringStore(roleRows: _roles(), userRows: _users()),
          session: _withUsers(),
        ));
        await tester.pumpAndSettle();

        // `Operator`, because the anonymous account holds it: the banner is rendered
        // for the roles every logged-out panel holds and no others.
        await tester.tap(find.byKey(kAccessRoleTileKey(kOperatorRoleName)));
        await tester.pumpAndSettle();

        // The state key.
        expect(find.byKey(kAccessRoleHeldByAnonymousKey), findsOneWidget);

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
          tester.getBottomLeft(find.byKey(kAccessRoleHeldByAnonymousKey)).dy,
          lessThanOrEqualTo(tester.getTopLeft(firstBox).dy),
        );
        expect(
          tester.getTopLeft(find.byKey(kAccessRoleHeldByAnonymousKey)).dy,
          lessThan(tester.getTopLeft(firstBox).dy),
        );
        // No other row opened with it.
        expect(find.byKey(kAccessAdminRefusalKey), findsNothing);
        expect(tester.takeException(), isNull);

        _expectNothingClipped(
            tester, find.byKey(kAccessSessionSectionKey), size.height);

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

    testWidgets('the roles dialog on an account that holds two',
        (tester) async {
      await withClock(Clock.fixed(_frozen), () async {
        _sizeView(tester, const Size(900, 760));

        await tester.pumpWidget(_dialogHost(
          theme: light,
          store: _AnsweringStore(roleRows: _roles(), userRows: _users()),
          session: _withUsers(),
        ));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(kAccessUserChangeRoleKey('linar')));
        await tester.pumpAndSettle();

        // The state key: the dialog is open and offers every role the store
        // returned.
        expect(find.byKey(kAccessUserRoleConfirmKey), findsOneWidget);
        for (final role in _roles()) {
          expect(find.byKey(kAccessUserRoleChoiceKey(role.name)),
              findsOneWidget);
        }

        // The two the account holds are ticked and the rest are not — the
        // claim the picture makes and an eye can only half-check, because a
        // checkbox and its outline differ by a few pixels.
        expect(find.byIcon(Icons.check_box), findsNWidgets(2));
        expect(
          find.byKey(kAccessUserRolePrimaryKey('Shift Leader')),
          findsOneWidget,
          reason: 'the role already held stays primary, so ticking a second '
              'one never moves role_name under somebody',
        );
        expect(find.byKey(kAccessUserRolePrimaryKey('Maintenance')),
            findsNothing);

        // Said in as many words, because an administrator ticking a second
        // role to "also let them do X" has to know it does not take away Y.
        expect(find.text(kAccessUserRoleDialogNote), findsOneWidget);
        expect(find.text(kAccessUserRolePrimaryNote), findsOneWidget);
        expect(find.byKey(kAccessUserRoleNoneKey), findsNothing);
        expect(tester.takeException(), isNull);

        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/access_admin_roles_picker.png'),
        );
      });
    });

    testWidgets('the roles dialog on the anonymous account, with its warning',
        (tester) async {
      await withClock(Clock.fixed(_frozen), () async {
        _sizeView(tester, const Size(900, 860));

        await tester.pumpWidget(_dialogHost(
          theme: light,
          store: _AnsweringStore(roleRows: _roles(), userRows: _users()),
          session: _withUsers(),
        ));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(kAccessUserChangeRoleKey(kAnonymousUsername)));
        await tester.pumpAndSettle();

        // The state key: the picker is open on the anonymous account, the banner
        // above everything else in it.
        expect(find.byKey(kAccessUserRoleConfirmKey), findsOneWidget);
        expect(find.byKey(kAccessAnonymousWarningKey), findsOneWidget);
        expect(find.text(kAccessAnonymousBannerNote), findsOneWidget);
        expect(
          tester.getBottomLeft(find.byKey(kAccessAnonymousWarningKey)).dy,
          lessThan(tester
              .getTopLeft(find.byKey(kAccessUserRoleChoiceKey(kOperatorRoleName)))
              .dy),
        );
        expect(find.byIcon(Icons.check_box), findsOneWidget);
        expect(find.byKey(kAccessUserRolePrimaryKey(kOperatorRoleName)),
            findsOneWidget);
        expect(tester.takeException(), isNull);

        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/access_admin_anonymous_roles.png'),
        );
      });
    });

    testWidgets('the home page dialog, with the tag it leaves on the row',
        (tester) async {
      await withClock(Clock.fixed(_frozen), () async {
        _sizeView(tester, const Size(900, 900));
        // The pages a home page may name: two plain pages and a section.
        final registry = RouteRegistry();
        registry.menuItems.clear();
        registry.addMenuItem(
            const MenuItem(label: 'Home', path: '/', icon: Icons.home));
        registry.addMenuItem(const MenuItem(
            label: 'Packing', path: '/packing', icon: Icons.inventory));
        registry.addMenuItem(const MenuItem(
          label: 'Halls',
          path: '/halls',
          icon: Icons.folder,
          isSection: true,
          children: [
            MenuItem(label: 'Freezer', path: '/halls/freezer', icon: Icons.ac_unit),
            MenuItem(label: 'Roe', path: '/halls/roe', icon: Icons.egg),
          ],
        ));

        // The roster speaks UserSummary on this branch (the wire's row), so
        // the home page is set the way the other rows are built.
        final users = [
          for (final u in _users())
            u.username == 'linar'
                ? _user('linar', 'Shift Leader',
                    alsoHolds: const ['Maintenance'],
                    createdAt: DateTime(2026, 7, 14, 6, 30),
                    lastLoginAt: DateTime(2026, 8, 30, 22, 10),
                    homePage: '/halls/freezer')
                : u,
        ];
        await tester.pumpWidget(_dialogHost(
          theme: light,
          store: _AnsweringStore(roleRows: _roles(), userRows: users),
          session: _withUsers(),
        ));
        await tester.pumpAndSettle();

        // The row names the page by its menu name, beside the roles.
        expect(find.byKey(kAccessUserHomePageTagKey('linar')), findsOneWidget);
        expect(find.text(kAccessUserHomePageTag('Freezer')), findsOneWidget);

        await tester.tap(find.byKey(kAccessUserHomePageKey('linar')));
        await tester.pumpAndSettle();

        // The state key: open on linar, the stored page chosen, sections as
        // headings rather than choices.
        expect(find.byKey(kAccessUserHomePageSaveKey), findsOneWidget);
        expect(find.text(kAccessUserHomePageNote), findsOneWidget);
        expect(find.byKey(kAccessUserHomePageOptionKey('/halls/freezer')),
            findsOneWidget);
        expect(find.byKey(kAccessUserHomePageOptionKey('/halls')), findsNothing);
        final chosen = tester.widget<RadioGroup<String>>(
            find.byType(RadioGroup<String>));
        expect(chosen.groupValue, '/halls/freezer');
        expect(tester.takeException(), isNull);

        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/access_admin_home_page.png'),
        );
      });
    });

    testWidgets('the alarm navigation confirmation, over a roster with one '
        'account already on', (tester) async {
      await withClock(Clock.fixed(_frozen), () async {
        const size = Size(900, 900);
        _sizeView(tester, size);

        final users = [
          for (final u in _users())
            u.username == 'linar' ? _navigating(u) : u,
        ];
        await tester.pumpWidget(_dialogHost(
          theme: light,
          store: _AnsweringStore(roleRows: _roles(), userRows: users),
          session: _withUsers(),
        ));
        await tester.pumpAndSettle();

        // The row states: linar on, everybody else off.
        String? tooltip(String username) => tester
            .widget<IconButton>(find.byKey(kAccessUserAlarmNavigateKey(username)))
            .tooltip;
        expect(tooltip('linar'), kAccessUserAlarmNavigateOnTooltip);
        expect(tooltip('admin'), kAccessUserAlarmNavigateOffTooltip);
        expect(tooltip(kAnonymousUsername), kAccessUserAlarmNavigateOffTooltip);
        // Eight actions still leave the timestamps their gap at 900 px.
        _expectTimestampColumnsHaveAGap(tester);

        await tester
            .tap(find.byKey(kAccessUserAlarmNavigateKey(kAnonymousUsername)));
        await tester.pumpAndSettle();

        expect(
            find.text(kAccessUserAlarmNavigateTitle(kAnonymousUsername, true)),
            findsOneWidget);
        expect(
            find.text(kAccessUserAlarmNavigateMessage(
                turningOn: true, anonymous: true)),
            findsOneWidget);
        expect(find.text(kAccessUserAlarmNavigateConfirmOn), findsOneWidget);
        expect(tester.takeException(), isNull);

        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/access_admin_alarm_navigate.png'),
        );
      });
    });
  });
}

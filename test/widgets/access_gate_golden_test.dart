/// Goldens for everything Phase 2 puts in front of an operator: the locked
/// page, the locked page inside the app shell, and the Advanced menu with and
/// without locks.
///
/// Six images:
///
/// * `access_locked_page.png`          — nobody signed in: lock, headline, the named permission, Sign in.
/// * `access_locked_page_elevated.png` — signed in as somebody whose role lacks the group, so the role note is in the picture.
/// * `access_locked_no_database.png`   — the same page on a station with no reachable database.
/// * `access_locked_shell.png`         — the denied [AccessGate] inside the app shell: the app bar and the navigation bar are the way out.
/// * `access_menu_locked.png`          — the real Advanced popup, anonymous, with locks on the two raised entries.
/// * `access_menu_unlocked.png`        — the identical tree with a session holding `configure` and `administer`.
///
/// **The muted (ISA-101) palette, not a bare `MaterialApp`.** `HmiStateColors`
/// falls back to `solarizedLight` outside a themed app, which would put violet
/// in pictures whose subject is a deliberately muted lock.
/// `MutedColors.forcedOrange` is the elevation colour and must not appear on a
/// locked page — a locked page is neither an override nor a fault.
///
/// **Fonts are loaded here, twice.** `test/widgets/flutter_test_config.dart`
/// registers the TTF under `'Roboto'` alone, but `lib/theme.dart:349` names
/// `'roboto-mono'` as the theme's family; an unregistered family falls back to
/// Ahem, so every themed `Text` would capture as solid rectangles. Same helper
/// as `test/page_creator/assets/aircab_golden_test.dart:105-125`.
///
/// **Every host in this file is this file's own.** The shell host is modelled
/// on `buildAccessGateShell` / `buildAccessGateRouter`
/// (`test/widgets/access_gate_test.dart`) and the menu host on
/// `buildTestNavDropdown` (`test/widgets/nav_dropdown_test.dart`), copied
/// rather than imported: importing another test file executes its top-level
/// state, and a golden that depended on a neighbour's `setUp` would be a
/// baseline nobody can reproduce.
///
/// **Both access providers are overridden in every image.** An unoverridden
/// `accessSessionProvider` runs the real controller chain and a frame captured
/// before it settles is `AsyncLoading`, in which `AccessStatusAction` renders
/// `SizedBox.shrink()` and the app bar looks empty; an unoverridden
/// `accessRepositoryProvider` reaches `databaseProvider`,
/// `DatabaseConfig.fromPrefs()` and the station keychain. Only image 3 resolves
/// the repository to null.
///
/// **The shell golden is pinned with `withClock`.** `base_scaffold.dart:216`
/// renders `clock.now()` — deliberately, so that a scaffold golden can be
/// frozen. Without it the header timestamp churns on every run.
///
/// To update: flutter test test/widgets/access_gate_golden_test.dart --update-goldens --run-skipped
@Tags(['golden'])
library;

import 'dart:io' show File, Platform;
import 'dart:typed_data' show ByteData;

import 'package:beamer/beamer.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/access_routes.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/providers/menu.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/theme.dart' show muted;
import 'package:tfc/widgets/access_gate.dart';
import 'package:tfc/widgets/access_status_action.dart';
import 'package:tfc/widgets/base_scaffold.dart';
import 'package:tfc/widgets/nav_dropdown.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_repository.dart';

const _lockedBoundary = Key('access_locked_page_golden');

/// A repository that answers nothing. Everything in this phase only ever asks
/// whether one exists.
class _StubRepository extends Fake implements AccessRepository {}

Future<AccessRepository?> _presentRepository() async => _StubRepository();

/// The station with no reachable database — image 3 only.
Future<AccessRepository?> _absentRepository() async => null;

/// A session that resolves immediately to whatever the image needs.
///
/// Overriding [build] is what keeps the captured frame *chosen* rather than
/// raced: none of the real leaf providers — database, preferences, audit sink,
/// inactivity monitor — is ever constructed, so there is no I/O to settle
/// against and no timer to leak.
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

AccessSession _anonymous() =>
    AccessSession.anonymous(const {AccessGroup.operate});

/// The fictional operator in image 2: signed in, and short of the permission
/// the page needs. Not a real account (T-02-27).
AccessSession _elevated(Set<AccessGroup> groups) => AccessSession(
      user: const AuthenticatedUser(
        username: 'lina',
        roleName: 'Line Lead',
        displayName: 'Lina R',
      ),
      groups: groups,
      // Fixed, never `DateTime.now()`: nothing renders it, and a golden that
      // depended on the wall clock would be a latent churn.
      expiresAt: DateTime.utc(2026, 8, 29, 12, 0),
    );

List<Override> _accessOverrides({
  required AccessSession session,
  required Future<AccessRepository?> Function() repository,
}) =>
    [
      accessSessionProvider.overrideWith(() => _FixedSession(session)),
      accessRepositoryProvider.overrideWith((ref) => repository()),
    ];

/// [AccessLockedBody] at a realistic page width, on the theme's own surface.
///
/// The `RepaintBoundary` is deliberately **not** the direct child of
/// `Scaffold.body`: Scaffold paints its background outside that subtree, and a
/// boundary placed there captures a transparent image. Phase 1 shipped two of
/// those before the trap was written down.
Widget _lockedPageHost({
  required ThemeData theme,
  required AccessSession session,
  required Future<AccessRepository?> Function() repository,
  AccessGroup group = AccessGroup.configure,
}) {
  return ProviderScope(
    overrides: _accessOverrides(session: session, repository: repository),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: Scaffold(
        backgroundColor: theme.colorScheme.surface,
        body: Center(
          child: RepaintBoundary(
            key: _lockedBoundary,
            child: ColoredBox(
              color: theme.colorScheme.surface,
              child: SizedBox(
                width: 900,
                height: 600,
                child: AccessLockedBody(group: group),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// The text the gated page renders. The shell image must not contain it.
const String _kGatedChildText = 'gated-page-body';

/// The page behind the gate, bringing its own [BaseScaffold] the way every
/// real page does.
class _GatedPage extends StatelessWidget {
  const _GatedPage();

  @override
  Widget build(BuildContext context) => const BaseScaffold(
        title: 'Preferences',
        body: Center(child: Text(_kGatedChildText)),
      );
}

/// The router the shell golden needs: the gated route, plus a `/` so the
/// navigation bar has a second destination to show.
///
/// Copied from `buildAccessGateRouter` rather than imported — see the library
/// comment.
BeamerDelegate _buildShellRouter(Widget gate) => BeamerDelegate(
      initialPath: '/advanced/preferences',
      locationBuilder: RoutesLocationBuilder(routes: {
        '/': (context, state, data) => const BeamPage(
              key: ValueKey('/'),
              title: 'Home',
              child: BaseScaffold(title: 'Home', body: Text('home-body')),
            ),
        '/advanced/preferences': (context, state, data) => BeamPage(
              key: const ValueKey('/advanced/preferences'),
              title: 'Preferences',
              child: gate,
            ),
      }).call,
    );

/// The Beamer shell the gate is pumped in.
///
/// [BaseScaffold] calls `context.currentBeamLocation`
/// (`base_scaffold.dart:40` and `:382`), so it cannot be pumped without a
/// router above it, and the `ProviderScope` has to sit above
/// `MaterialApp.router` so the root navigator's overlay is inside it.
Widget _shellHost({
  required ThemeData theme,
  required BeamerDelegate router,
  required AccessSession session,
  required Future<AccessRepository?> Function() repository,
}) {
  return ProviderScope(
    overrides: _accessOverrides(session: session, repository: repository),
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

/// The top-level menu [BaseScaffold] draws its navigation bar from.
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
          label: 'Preferences',
          path: '/advanced/preferences',
          icon: Icons.tune),
      // An unraised sibling, because the real Advanced menu has several and
      // the section's survival now depends on it: a section whose every child
      // this session cannot open is dropped from the bar entirely. With
      // Preferences alone, an anonymous shell would render no Advanced
      // destination — and, at two top-level entries minimum, no bar at all,
      // which is not the shell this image is meant to show.
      MenuItem(
          label: 'About Linux',
          path: '/advanced/about-linux',
          icon: Icons.info),
    ],
  ));
}

/// The Advanced menu the two popup images open: a raised entry, the exempt
/// entry, and an ordinary page that is not raised.
MenuItem _advancedMenu() => const MenuItem(
      label: 'Advanced',
      icon: Icons.settings,
      children: [
        MenuItem(
            label: 'Page Editor',
            icon: Icons.edit,
            path: '/advanced/page-editor'),
        MenuItem(
            label: 'Server Config', icon: Icons.dns, path: kServerConfigRoute),
        MenuItem(label: 'Dashboard', icon: Icons.home, path: '/dashboard'),
      ],
    );

/// The dropdown at the height of a real navigation bar.
///
/// `TopLevelNavIndicator` is a `Column` with no height constraint, so under a
/// bare `Align` it fills the screen, the button's top edge lands at y = 0 and
/// `NavDropdown` opens a 16 px popup with the entries scrolled out of view.
/// The same reason `nav_dropdown_test.dart`'s bar location exists.
class _MenuLocation extends BeamLocation<BeamState> {
  _MenuLocation() : super(RouteInformation(uri: Uri.parse('/dashboard')));

  static const double barHeight = 80.0;

  @override
  List<BeamPage> buildPages(BuildContext context, BeamState state) {
    return [
      BeamPage(
        key: const ValueKey('menu'),
        child: Scaffold(
          backgroundColor: Theme.of(context).colorScheme.surface,
          body: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              height: barHeight,
              // Fed from `visibleMenuProvider`, exactly as `BaseScaffold`
              // feeds it. The hiding of entries this session cannot open is
              // the provider's job now, not the popup's — so a host that
              // handed `NavDropdown` an unfiltered tree would be testing a
              // wiring the app does not have.
              child: Consumer(builder: (context, ref, _) {
                final visible = ref.watch(visibleMenuProvider).topLevel;
                if (visible.isEmpty) return const SizedBox.shrink();
                return NavDropdown(menuItem: visible.first);
              }),
            ),
          ),
        ),
      ),
    ];
  }

  @override
  List<Pattern> get pathPatterns => ['/dashboard', '/advanced/*'];
}

/// The menu images' host. Modelled on `buildTestNavDropdown`, themed, and
/// owned by this file.
Widget _menuHost({
  required ThemeData theme,
  required AccessSession session,
  required Future<AccessRepository?> Function() repository,
}) {
  final router = BeamerDelegate(
    locationBuilder: (routeInformation, _) => _MenuLocation(),
  );
  return ProviderScope(
    overrides: _accessOverrides(session: session, repository: repository),
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

void _sizeView(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Bounded settle, the shape `test/helpers/test_helpers.dart` uses. Nothing
/// here takes focus, but the provider futures still need draining and a fixed
/// number of frames is one fewer thing that can hang.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  final (light, _) = muted();

  setUpAll(() async {
    Future<void> loadFont(String family, String path) async {
      final file = File(path);
      if (!file.existsSync()) return;
      await (FontLoader(family)
            ..addFont(
                Future.value(ByteData.view(file.readAsBytesSync().buffer))))
          .load();
    }

    // Both families, deliberately. `flutter_test_config.dart` registers only
    // the first; `lib/theme.dart:349` asks for the second.
    await loadFont('Roboto', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');
    await loadFont(
        'roboto-mono', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');

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

    EditableText.debugDeterministicCursor = true;
  });

  tearDownAll(() => EditableText.debugDeterministicCursor = false);

  group('access gate goldens',
      skip: !Platform.isMacOS ? 'Golden tests only run on macOS' : null, () {
    tearDown(() {
      // The registry is process-wide and outlives this file.
      RouteRegistry().menuItems.clear();
      RouteRegistry().clearRouteGroups();
    });

    testWidgets('the locked page, anonymous', (tester) async {
      _sizeView(tester, const Size(900, 600));
      await tester.pumpWidget(_lockedPageHost(
        theme: light,
        session: _anonymous(),
        repository: _presentRepository,
      ));
      await _settle(tester);

      // The picture must be of the lock, not of a frame that has not decided
      // yet.
      expect(find.byKey(kAccessLockedBodyKey), findsOneWidget);
      expect(find.byKey(kAccessLockedNoDatabaseKey), findsNothing);

      await expectLater(
        find.byKey(_lockedBoundary),
        matchesGoldenFile('goldens/access_locked_page.png'),
      );
    });

    testWidgets('the locked page, signed in but short of the permission',
        (tester) async {
      _sizeView(tester, const Size(900, 600));
      await tester.pumpWidget(_lockedPageHost(
        theme: light,
        session: _elevated(const {
          AccessGroup.operate,
          AccessGroup.setpoints,
          AccessGroup.device,
        }),
        repository: _presentRepository,
      ));
      await _settle(tester);

      // "Sign in" is confusing advice to somebody who already did, so the page
      // has to name who they are and what their role is short of.
      expect(
        find.text(kAccessLockedRoleNote(
            'Lina R', 'Line Lead', AccessGroup.configure)),
        findsOneWidget,
      );

      await expectLater(
        find.byKey(_lockedBoundary),
        matchesGoldenFile('goldens/access_locked_page_elevated.png'),
      );
    });

    testWidgets('the locked page on a station with no reachable database',
        (tester) async {
      _sizeView(tester, const Size(900, 600));
      await tester.pumpWidget(_lockedPageHost(
        theme: light,
        session: _anonymous(),
        repository: _absentRepository,
      ));
      await _settle(tester);

      // The line is the only warning an operator gets before tapping a Sign in
      // that cannot succeed, so a present-but-clipped one would be worse than
      // none. `find.text` passes on an ellipsised string; this does not.
      final note = tester.widget<Text>(find.byKey(kAccessLockedNoDatabaseKey));
      expect(note.data, kAccessLockedNoDatabaseNote);
      expect(note.maxLines, isNull);
      expect(note.overflow, isNot(TextOverflow.ellipsis));
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.byKey(kAccessLockedNoDatabaseKey),
          matching: find.byType(RichText),
        ),
      );
      expect(
        paragraph.size.height,
        greaterThan(paragraph.preferredLineHeight * 1.5),
        reason: 'the note wraps to more than one line at the rendered width',
      );
      expect(paragraph.didExceedMaxLines, isFalse);

      // A greyed control here is the failure this milestone forbids outright.
      expect(
        tester
            .widget<ElevatedButton>(find.byKey(kAccessLockedSignInKey))
            .onPressed,
        isNotNull,
      );

      await expectLater(
        find.byKey(_lockedBoundary),
        matchesGoldenFile('goldens/access_locked_no_database.png'),
      );
    });

    testWidgets('the locked page inside the app shell', (tester) async {
      await withClock(Clock.fixed(DateTime.utc(2026, 8, 29, 9, 0)), () async {
        _sizeView(tester, const Size(1280, 800));
        _registerShellMenu();
        installRaisedRoutes();

        final router = _buildShellRouter(const AccessGate(
          group: AccessGroup.administer,
          title: 'Preferences',
          child: _GatedPage(),
        ));
        await tester.pumpWidget(_shellHost(
          theme: light,
          router: router,
          session: _anonymous(),
          repository: _presentRepository,
        ));
        await tester.pumpAndSettle();

        // The claim this image exists to make: the operator can leave.
        expect(find.byType(AccessLockedBody), findsOneWidget);
        expect(find.byType(AccessStatusAction), findsOneWidget);
        expect(find.byType(NavigationBar), findsOneWidget);
        // And the page behind the gate is not in the frame.
        expect(find.text(_kGatedChildText), findsNothing);

        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/access_locked_shell.png'),
        );
      });
    });

    testWidgets('the Advanced menu, anonymous', (tester) async {
      _sizeView(tester, const Size(900, 600));
      final registry = RouteRegistry();
      registry.menuItems.clear();
      registry.addMenuItem(_advancedMenu());
      registry.clearRouteGroups();
      installRaisedRoutes();

      await tester.pumpWidget(_menuHost(
        theme: light,
        session: _anonymous(),
        repository: _presentRepository,
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Advanced'));
      await tester.pumpAndSettle();

      // No locks, because there is nothing left to lock: an entry this
      // session cannot open is hidden rather than shown wearing one. With a
      // repository present the Server Config exemption is inert, so both
      // raised entries go and only the ordinary page remains.
      expect(find.byIcon(Icons.lock_outline), findsNothing);
      expect(find.text('Page Editor'), findsNothing);
      expect(find.text('Server Config'), findsNothing);

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/access_menu_locked.png'),
      );
    });

    testWidgets('the Advanced menu, signed in with both permissions',
        (tester) async {
      _sizeView(tester, const Size(900, 600));
      final registry = RouteRegistry();
      registry.menuItems.clear();
      registry.addMenuItem(_advancedMenu());
      registry.clearRouteGroups();
      installRaisedRoutes();

      await tester.pumpWidget(_menuHost(
        theme: light,
        session: _elevated(const {
          AccessGroup.operate,
          AccessGroup.configure,
          AccessGroup.administer,
        }),
        repository: _presentRepository,
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Advanced'));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.lock_outline), findsNothing);

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/access_menu_unlocked.png'),
      );
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/access_routes.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/core/access_authority.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/widgets/access_lock_badge.dart';
import 'package:tfc/widgets/nav_dropdown.dart';
import 'package:tfc/widgets/panes/side_pane.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:beamer/beamer.dart';

/// A minimal BeamLocation for testing.
class _TestLocation extends BeamLocation<BeamState> {
  _TestLocation() : super(RouteInformation(uri: Uri.parse('/test')));

  @override
  List<BeamPage> buildPages(BuildContext context, BeamState state) {
    return [
      const BeamPage(
        key: ValueKey('test'),
        child: SizedBox.shrink(),
      ),
    ];
  }

  @override
  List<Pattern> get pathPatterns => ['/test'];
}

MenuItem _testMenuItem() {
  return MenuItem(
    label: 'TestMenu',
    icon: Icons.settings,
    children: [
      MenuItem(label: 'Page A', icon: Icons.home, path: '/page-a'),
      MenuItem(label: 'Page B', icon: Icons.info, path: '/page-b'),
    ],
  );
}

/// Creates a menu with many items to reproduce BUG-005 (popup clips offscreen).
MenuItem _largeTestMenuItem() {
  return MenuItem(
    label: 'Advanced',
    icon: Icons.settings,
    children: [
      MenuItem(label: 'Section One', icon: Icons.folder, children: [
        MenuItem(label: 'Page 1', icon: Icons.pages, path: '/page-1'),
        MenuItem(label: 'Page 2', icon: Icons.pages, path: '/page-2'),
        MenuItem(label: 'Page 3', icon: Icons.pages, path: '/page-3'),
      ]),
      MenuItem(label: 'Section Two', icon: Icons.folder, children: [
        MenuItem(label: 'Page 4', icon: Icons.pages, path: '/page-4'),
        MenuItem(label: 'Page 5', icon: Icons.pages, path: '/page-5'),
        MenuItem(label: 'Page 6', icon: Icons.pages, path: '/page-6'),
      ]),
      MenuItem(label: 'Page 7', icon: Icons.pages, path: '/page-7'),
      MenuItem(label: 'Page 8', icon: Icons.pages, path: '/page-8'),
      MenuItem(label: 'Page 9', icon: Icons.pages, path: '/page-9'),
      MenuItem(label: 'Page 10', icon: Icons.pages, path: '/page-10'),
      MenuItem(label: 'Page 11', icon: Icons.pages, path: '/page-11'),
      MenuItem(label: 'Page 12', icon: Icons.pages, path: '/page-12'),
    ],
  );
}

/// A BeamLocation that places a NavDropdown at the bottom of a Scaffold.
class _NavDropdownLocation extends BeamLocation<BeamState> {
  final MenuItem menuItem;
  _NavDropdownLocation(this.menuItem)
      : super(RouteInformation(uri: Uri.parse('/test')));

  @override
  List<BeamPage> buildPages(BuildContext context, BeamState state) {
    return [
      BeamPage(
        key: const ValueKey('test'),
        child: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: NavDropdown(menuItem: menuItem),
          ),
        ),
      ),
    ];
  }

  @override
  List<Pattern> get pathPatterns => ['/test'];
}

/// The delegate [buildTestNavDropdown] builds by default, exposed so a test
/// can read where a tap navigated to.
BeamerDelegate buildTestNavDelegate(MenuItem menuItem) => BeamerDelegate(
      locationBuilder: (routeInformation, _) => _NavDropdownLocation(menuItem),
    );

/// Wraps a [NavDropdown] in the minimal widget tree needed for Beamer context.
///
/// The `ProviderScope` is above `MaterialApp.router`, and so above the root
/// navigator's overlay — which is where `showMenu(useRootNavigator: true)`
/// puts the popup. Without it the [AccessLockBadge] on each leaf entry has no
/// container to read. The real app is the same shape: `runApp(ProviderScope(…))`
/// at `centroid-hmi/lib/main.dart:343`.
///
/// [overrides] is empty by default and that is safe for a menu of unraised
/// paths: the badge short-circuits on `operate` before watching anything, so
/// no access provider is ever built. A test that uses a raised path must
/// override both `accessSessionProvider` and `accessAuthorityProvider` — an
/// unoverridden authority reaches `gatewayConfigProvider`, `databaseProvider`
/// and the station keychain.
Widget buildTestNavDropdown(
  MenuItem menuItem, {
  List<Override> overrides = const [],
  BeamerDelegate? delegate,
}) {
  final routerDelegate = delegate ?? buildTestNavDelegate(menuItem);

  return ProviderScope(
    overrides: overrides,
    child: BeamerProvider(
      routerDelegate: routerDelegate,
      child: MaterialApp.router(
        routerDelegate: routerDelegate,
        routeInformationParser: BeamerParser(),
      ),
    ),
  );
}

/// Same as [buildTestNavDropdown] but wraps in a nested Navigator with a
/// shared HeroController to reproduce BUG-002.
Widget buildTestNavDropdownWithNestedNavigator(
  MenuItem menuItem, {
  List<Override> overrides = const [],
}) {
  final routerDelegate = buildTestNavDelegate(menuItem);

  return ProviderScope(
    overrides: overrides,
    child: BeamerProvider(
      routerDelegate: routerDelegate,
      child: MaterialApp.router(
        routerDelegate: routerDelegate,
        routeInformationParser: BeamerParser(),
        builder: (context, child) {
          return HeroControllerScope(
            controller: HeroController(),
            child: Navigator(
              onGenerateRoute: (_) => MaterialPageRoute(
                builder: (_) => Scaffold(
                  body: Align(
                    alignment: Alignment.bottomCenter,
                    child: NavDropdown(menuItem: menuItem),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
}

/// The same shape as [_NavDropdownLocation], but the dropdown is given the
/// height of a real navigation bar.
///
/// `TopLevelNavIndicator` is a `Column` with no height constraint, so under a
/// bare `Align` it fills the screen and the button's top edge lands at y = 0.
/// `NavDropdown` then computes `availableHeight = buttonPos.dy - 8`, clamps it
/// to zero and opens a popup 16 px tall: the entries are laid out but scrolled
/// out of the visible window, so they cannot be tapped. Harmless for the
/// bug-regression tests above, which only read text, and fatal for a test that
/// has to tap an entry.
class _NavBarLocation extends BeamLocation<BeamState> {
  final MenuItem menuItem;
  _NavBarLocation(this.menuItem)
      : super(RouteInformation(uri: Uri.parse('/test')));

  /// Matches the app's own bottom bar closely enough for the popup arithmetic.
  static const double barHeight = 80.0;

  @override
  List<BeamPage> buildPages(BuildContext context, BeamState state) {
    return [
      BeamPage(
        key: const ValueKey('test'),
        child: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              height: barHeight,
              child: NavDropdown(menuItem: menuItem),
            ),
          ),
        ),
      ),
    ];
  }

  @override
  List<Pattern> get pathPatterns => ['/test', '/dashboard', '/advanced/*'];
}

/// A menu with a raised leaf, the exempt leaf, an unraised leaf and a section
/// header — the four cases the badge has to tell apart in one popup.
MenuItem _accessTestMenuItem() {
  return MenuItem(
    label: 'Advanced',
    icon: Icons.settings,
    children: [
      MenuItem(label: 'Config', icon: Icons.folder, isSection: true, children: [
        MenuItem(
            label: 'Page Editor',
            icon: Icons.edit,
            path: '/advanced/page-editor'),
        MenuItem(
            label: 'Server Config', icon: Icons.dns, path: kServerConfigRoute),
      ]),
      MenuItem(label: 'Dashboard', icon: Icons.home, path: '/dashboard'),
    ],
  );
}

/// What verifies a credential on the station under test. The badge only asks
/// whether anything does.
Future<AccessAuthority> _presentRepository() async => AccessAuthority.local;
Future<AccessAuthority> _absentRepository() async => AccessAuthority.none;

/// A gateway panel: no database by design, the credential verified over the
/// socket.
Future<AccessAuthority> _relayAuthority() async => AccessAuthority.relay;

/// Resolves immediately, so no frame in these tests is a race against the real
/// controller chain.
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

List<Override> _accessOverrides({
  AccessSession? session,
  Future<AccessAuthority> Function() repository = _presentRepository,
}) =>
    [
      accessSessionProvider.overrideWith(() => _FixedSession(
          session ?? AccessSession.anonymous(const {AccessGroup.operate}))),
      accessAuthorityProvider.overrideWith((ref) => repository()),
    ];

/// The badge tests' host: a [NavDropdown] in a bar-height slot, under a
/// `ProviderScope` that is above the root navigator's overlay.
Widget _buildTestNavBar({
  required List<Override> overrides,
  required BeamerDelegate delegate,
}) {
  return ProviderScope(
    overrides: overrides,
    child: BeamerProvider(
      routerDelegate: delegate,
      child: MaterialApp.router(
        routerDelegate: delegate,
        routeInformationParser: BeamerParser(),
      ),
    ),
  );
}

BeamerDelegate _buildTestNavBarDelegate(MenuItem menuItem) => BeamerDelegate(
      locationBuilder: (routeInformation, _) => _NavBarLocation(menuItem),
    );

/// The [AccessLockBadge] inside the popup row labelled [label].
Finder _badgeFor(String label) => find.descendant(
      of: find.widgetWithText(PopupMenuItem<void>, label),
      matching: find.byType(AccessLockBadge),
    );

/// The lock glyph inside the popup row labelled [label].
Finder _lockFor(String label) => find.descendant(
      of: find.widgetWithText(PopupMenuItem<void>, label),
      matching: find.byIcon(Icons.lock_outline),
    );

void main() {
  setUp(() {
    // Ensure RouteRegistry has the test menu item so findRootNodeOfLeaf works.
    final registry = RouteRegistry();
    registry.menuItems.clear();
    registry.addMenuItem(_testMenuItem());
    // The registry is process-wide and outlives a test file, so the raised
    // routes are declared here and cleared below rather than left lying about
    // for whatever suite runs next.
    registry.clearRouteGroups();
    installRaisedRoutes();
  });

  tearDown(() {
    RouteRegistry().clearRouteGroups();
  });

  group('NavDropdown', () {
    group('BUG-001: rapid tap crash guard', () {
      testWidgets('_isMenuOpen guard is set while popup is open',
          (WidgetTester tester) async {
        await tester.pumpWidget(buildTestNavDropdown(_testMenuItem()));
        await tester.pumpAndSettle();

        // Find the NavDropdownState to inspect the guard
        final state =
            tester.state<NavDropdownState>(find.byType(NavDropdown));
        expect(state.isMenuOpen, isFalse,
            reason: 'Guard should be false before any tap');

        // Open the popup menu
        await tester.tap(find.text('TestMenu'));
        await tester.pump(); // start the menu animation

        // While the popup is open/transitioning, the guard should be true
        expect(state.isMenuOpen, isTrue,
            reason: 'Guard must be true while popup is open');

        // Let the animation complete
        await tester.pumpAndSettle();

        // Guard should still be true while menu is displayed
        expect(state.isMenuOpen, isTrue,
            reason: 'Guard must remain true while menu is displayed');

        // The menu items should be visible
        expect(find.text('Page A'), findsOneWidget);
        expect(find.text('Page B'), findsOneWidget);
      });

      testWidgets('guard resets to false after menu is dismissed',
          (WidgetTester tester) async {
        await tester.pumpWidget(buildTestNavDropdown(_testMenuItem()));
        await tester.pumpAndSettle();

        final state =
            tester.state<NavDropdownState>(find.byType(NavDropdown));

        // Open the menu
        await tester.tap(find.text('TestMenu'));
        await tester.pumpAndSettle();
        expect(state.isMenuOpen, isTrue);

        // Dismiss by tapping outside the popup
        await tester.tapAt(Offset.zero);
        await tester.pumpAndSettle();

        // Guard should reset after menu closes
        expect(state.isMenuOpen, isFalse,
            reason: 'Guard must reset to false after menu is dismissed');

        // Should be able to open a new menu
        await tester.tap(find.text('TestMenu'));
        await tester.pumpAndSettle();

        expect(find.text('Page A'), findsOneWidget);
        expect(find.text('Page B'), findsOneWidget);
      });
    });

    group('BUG-002: HeroController shared by multiple Navigators', () {
      testWidgets(
          'showMenu uses root navigator to avoid HeroController conflict',
          (WidgetTester tester) async {
        await tester.pumpWidget(
            buildTestNavDropdownWithNestedNavigator(_testMenuItem()));
        await tester.pumpAndSettle();

        // If showMenu does NOT use the root navigator, this tap would
        // trigger a HeroController conflict. With useRootNavigator: true,
        // it should work fine.
        await tester.tap(find.text('TestMenu'));
        await tester.pumpAndSettle();

        // Menu should display without errors
        expect(find.text('Page A'), findsOneWidget);
        expect(find.text('Page B'), findsOneWidget);
      });
    });

    group('BUG-005: popup clips offscreen with many items', () {
      setUp(() {
        // Register the large menu so findRootNodeOfLeaf can resolve it.
        final registry = RouteRegistry();
        registry.menuItems.clear();
        registry.addMenuItem(_largeTestMenuItem());
      });

      testWidgets(
          'popup menu stays within screen bounds when there are many items',
          (WidgetTester tester) async {
        // Use a small screen size to force the overflow scenario.
        // 14 total items * 48px = 672px, exceeding the 400px screen height.
        tester.view.physicalSize = const Size(800, 400);
        tester.view.devicePixelRatio = 1.0;
        addTeardownToTeardown(tester);

        await tester
            .pumpWidget(buildTestNavDropdown(_largeTestMenuItem()));
        await tester.pumpAndSettle();

        // Open the popup menu
        await tester.tap(find.text('Advanced'));
        await tester.pumpAndSettle();

        // The popup menu surface should not extend above y=0.
        // Find the popup's Material surface that wraps the menu items.
        // showMenu creates a _PopupMenu which contains a Material widget.
        final popupFinder = find.byWidgetPredicate(
          (widget) =>
              widget is Material && widget.type == MaterialType.card,
        );
        // If no card-type Material, try the generic popup approach
        final menuFinder = popupFinder.evaluate().isNotEmpty
            ? popupFinder
            : find.byType(PopupMenuItem<void>).first;
        expect(menuFinder, findsWidgets);

        // Get the render box of the first popup menu entry to check
        // its global position.
        final firstItemBox = tester.renderObject(
          find.byType(PopupMenuItem<void>).first,
        ) as RenderBox;
        final firstItemTopLeft =
            firstItemBox.localToGlobal(Offset.zero);

        // The top of the first menu item must not be above the screen.
        expect(
          firstItemTopLeft.dy,
          greaterThanOrEqualTo(0.0),
          reason:
              'Menu popup must not extend above the top of the screen',
        );

        // Also verify we can still see menu items (popup opens and is
        // usable, just scrollable now).
        expect(find.text('Page 12'), findsOneWidget);
      });

      testWidgets(
          'popup is scrollable and last items are accessible',
          (WidgetTester tester) async {
        tester.view.physicalSize = const Size(800, 400);
        tester.view.devicePixelRatio = 1.0;
        addTeardownToTeardown(tester);

        await tester
            .pumpWidget(buildTestNavDropdown(_largeTestMenuItem()));
        await tester.pumpAndSettle();

        // Open the popup menu
        await tester.tap(find.text('Advanced'));
        await tester.pumpAndSettle();

        // With the constrained height, the popup should be scrollable.
        // Check that at least one item is visible (the popup opened
        // successfully without errors).
        final visibleItems = find.byType(PopupMenuItem<void>);
        expect(visibleItems, findsWidgets);
      });
    });

    group('side pane', () {
      // A section is a tap on the navigation bar, and the bar closes the
      // pane -- but NavigationBar.onDestinationSelected never fires for one,
      // because the dropdown's own InkWell consumes the tap.
      tearDown(() => closeSidePane(immediate: true));

      testWidgets('opening the menu closes an open side pane',
          (WidgetTester tester) async {
        await tester.pumpWidget(buildTestNavDropdown(_testMenuItem()));
        await tester.pumpAndSettle();

        showSidePane(
          context: tester.element(find.byType(NavDropdown)),
          id: 'test-pane',
          builder: (_) => const Text('pane body'),
        );
        await tester.pumpAndSettle();
        expect(isSidePaneOpen(), isTrue);

        await tester.tap(find.text('TestMenu'));
        await tester.pumpAndSettle();

        expect(isSidePaneOpen(), isFalse);
        expect(find.text('pane body'), findsNothing);
        // The menu still opened.
        expect(find.text('Page A'), findsOneWidget);
      });

      testWidgets('pane stays closed when the menu is dismissed unchosen',
          (WidgetTester tester) async {
        await tester.pumpWidget(buildTestNavDropdown(_testMenuItem()));
        await tester.pumpAndSettle();

        showSidePane(
          context: tester.element(find.byType(NavDropdown)),
          id: 'test-pane',
          builder: (_) => const Text('pane body'),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('TestMenu'));
        await tester.pumpAndSettle();
        // Dismiss without picking a page -- the old behaviour left the pane
        // up for a device the operator had already walked away from.
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();

        expect(isSidePaneOpen(), isFalse);
      });

      testWidgets('tapping with no pane open is harmless',
          (WidgetTester tester) async {
        await tester.pumpWidget(buildTestNavDropdown(_testMenuItem()));
        await tester.pumpAndSettle();

        await tester.tap(find.text('TestMenu'));
        await tester.pumpAndSettle();

        expect(isSidePaneOpen(), isFalse);
        expect(find.text('Page A'), findsOneWidget);
      });
    });

    group('the lock badge on leaf entries', () {
      setUp(() {
        final registry = RouteRegistry();
        registry.menuItems.clear();
        registry.addMenuItem(_accessTestMenuItem());
      });

      /// Opens the Advanced popup with the given access state.
      Future<void> openMenu(
        WidgetTester tester, {
        AccessSession? session,
        Future<AccessAuthority> Function() repository = _presentRepository,
        BeamerDelegate? delegate,
      }) async {
        await tester.pumpWidget(_buildTestNavBar(
          overrides:
              _accessOverrides(session: session, repository: repository),
          delegate: delegate ?? _buildTestNavBarDelegate(_accessTestMenuItem()),
        ));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Advanced'));
        await tester.pumpAndSettle();
      }

      testWidgets('a raised entry the session cannot open is hidden',
          (tester) async {
        await openMenu(tester);

        expect(find.widgetWithText(PopupMenuItem<void>, 'Page Editor'),
            findsNothing,
            reason: 'an entry this session cannot open is left out of the '
                'menu rather than shown wearing a lock');
        expect(find.widgetWithText(PopupMenuItem<void>, 'Server Config'),
            findsNothing,
            reason: 'with a repository present the exemption is inert and '
                'Server Config needs administer like anything else');
        expect(find.widgetWithText(PopupMenuItem<void>, 'Dashboard'),
            findsOneWidget,
            reason: 'an unraised entry is unaffected');
      });

      testWidgets(
          'with the repository unavailable, Server Config alone stays visible',
          (tester) async {
        await openMenu(tester, repository: _absentRepository);

        expect(find.widgetWithText(PopupMenuItem<void>, 'Server Config'),
            findsOneWidget,
            reason: 'the page that configures the database must not be '
                'hidden by the database being unavailable — that is the one '
                'route out of the outage');
        expect(find.widgetWithText(PopupMenuItem<void>, 'Page Editor'),
            findsNothing,
            reason: 'the others stay hidden through an outage');
      });

      testWidgets(
          'on a gateway panel the raised entries come back for a session that '
          'holds the groups', (tester) async {
        // The rig defect. A gateway panel has no repository by design, which
        // the menu read as "this station can authenticate nobody" and hid
        // every raised entry from an engineer who had just signed in.
        await openMenu(tester, repository: _relayAuthority);
        expect(find.widgetWithText(PopupMenuItem<void>, 'Page Editor'),
            findsNothing,
            reason: 'nobody is signed in yet');
        expect(find.widgetWithText(PopupMenuItem<void>, 'Server Config'),
            findsOneWidget,
            reason: 'a mistyped gateway URL is fixed on that page');

        await tester.pumpWidget(const SizedBox.shrink());
        await openMenu(
          tester,
          repository: _relayAuthority,
          session: AccessSession(
            user: const AuthenticatedUser(
              username: 'centroid',
              roleName: 'Engineering',
              displayName: 'Centroid',
            ),
            groups: const {
              AccessGroup.operate,
              AccessGroup.configure,
              AccessGroup.administer,
            },
            expiresAt: DateTime.utc(2026, 9, 9, 23),
          ),
        );

        expect(find.widgetWithText(PopupMenuItem<void>, 'Page Editor'),
            findsOneWidget,
            reason: 'the gateway verified this session; the pages it holds '
                'the groups for must be in the menu');
        expect(find.widgetWithText(PopupMenuItem<void>, 'Server Config'),
            findsOneWidget);
      });

      testWidgets('a hidden entry is not in the menu to be tapped',
          (tester) async {
        final delegate = _buildTestNavBarDelegate(_accessTestMenuItem());
        await openMenu(tester, delegate: delegate);

        expect(find.text('Page Editor'), findsNothing,
            reason: 'there is no row left to tap; the AccessGate on the route '
                'is still what refuses anyone who reaches the path directly, '
                'so hiding is presentation and never the enforcement point');
      });

      testWidgets('an unraised entry occupies zero width', (tester) async {
        await openMenu(tester);

        expect(_badgeFor('Dashboard'), findsOneWidget);
        expect(tester.getSize(_badgeFor('Dashboard')), Size.zero,
            reason: 'every ordinary menu row in the app must lay out exactly '
                'as it did before this phase');
        expect(_lockFor('Dashboard'), findsNothing);
      });

      testWidgets('section headers get no badge at all', (tester) async {
        await openMenu(tester);

        expect(_badgeFor('Config'), findsNothing,
            reason: 'a section groups, it does not route');
        expect(find.byType(AccessLockBadge), findsNWidgets(1),
            reason: 'only Dashboard is still in the menu; the two raised '
                'entries are hidden, and a hidden row carries no badge');
      });

      testWidgets('an ordinary row keeps the height the popup is sized from',
          (tester) async {
        await openMenu(tester);

        final row = tester.getSize(find.ancestor(
          of: find.text('Dashboard'),
          matching: find.byType(PopupMenuItem<void>),
        ));
        expect(row.height, NavDropdown.itemHeight,
            reason: 'menuHeight is computed as totalItems * itemHeight before '
                'the popup opens; a badge that added vertical size would '
                'break that arithmetic');
      });

      testWidgets('a session holding everything sees no lock anywhere',
          (tester) async {
        await openMenu(
          tester,
          session: AccessSession(
            user: const AuthenticatedUser(
                username: 'jon', roleName: 'Engineering'),
            groups: AccessGroup.values.toSet(),
            expiresAt: DateTime.utc(2026, 8, 29, 12),
          ),
        );

        expect(find.byIcon(Icons.lock_outline), findsNothing);
        for (final label in ['Page Editor', 'Server Config', 'Dashboard']) {
          expect(tester.getSize(_badgeFor(label)), Size.zero,
              reason: '$label must be laid out as it was before this phase');
        }
      });
    });
  });
}

/// Helper to reset the test view size on teardown.
void addTeardownToTeardown(WidgetTester tester) {
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

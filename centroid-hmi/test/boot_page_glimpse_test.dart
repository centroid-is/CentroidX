/// The boot seam, one frame at a time: a starting panel must not build a page
/// nobody asked for on its way to the session's home page.
///
/// Reported from a plant, seen first in the web client: for a moment after
/// start the operator saw a cabinet page — a button, an LED, a PLC — and then
/// the panel jumped to the account's home page. *Which* page it was is an
/// accident of ordering (`firstMenuPath` on a station whose Home was deleted,
/// or Home itself on one that still has it); that any configured page was
/// built at all is the defect. A built page runs its `initState`, its queries
/// and its OPC UA subscriptions, and a page that appears and is taken away
/// reads as a fault in the panel to the person in front of it.
///
/// Wired the way `main()` and `MyApp` wire it, as `boot_home_page_test.dart`
/// is, but with the two database round trips a real boot waits on — the
/// session, then the account's home page — held open until each test releases
/// them, and pumped one frame at a time. The assertion is on what is *built*
/// after every frame, never only on where the router settled: settling in the
/// right place is exactly what the reported panel did.
library;

import 'dart:async';

import 'package:beamer/beamer.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/home_page.dart';
import 'package:tfc/core/last_route.dart';
import 'package:tfc/core/runner_liveness.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/pages/page_view.dart' show AssetView;
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/home_page.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/transition_delegate.dart';
import 'package:tfc_access/tfc_access.dart';

import 'package:centroidx/main.dart';
import 'package:centroidx/navigation.dart';

MenuItem _page(String label, String path) => MenuItem(label: label, path: path, icon: Icons.pageview);

/// A station's pages with the Home page deleted. The cabinet page is the
/// first root page — the one `firstMenuPath` sends `/` to — and its path
/// sorts before every other so the test cannot pass by accident of any
/// other ordering either.
final _pagesWithoutHome = <MenuItem>[
  _page('Cabinet', '/+aaa'),
  _page('Line', '/line'),
  MenuItem(
    label: 'Halls',
    path: '/halls',
    icon: Icons.folder,
    isSection: true,
    children: [_page('Packing', '/halls/packing')],
  ),
];

/// The same station with its Home page still there.
final _pagesWithHome = <MenuItem>[
  _page('Home', '/'),
  ..._pagesWithoutHome,
];

/// A session that has not answered until the test releases it: a panel whose
/// database connect is still out when the first page mounts.
class _LateSession extends AccessSessionController {
  final Completer<void> _release = Completer<void>();

  void answer() => _release.complete();

  @override
  Future<AccessSession> build() async {
    await _release.future;
    return AccessSession.anonymous(const {AccessGroup.operate});
  }

  @override
  void poke() {}
}

/// A booted shell, with the two database answers a real boot waits on held
/// until the test gives them.
class _Boot {
  _Boot({
    required this.tester,
    required this.delegate,
    required this.debt,
    required this.session,
    required this.lookupHold,
  });

  final WidgetTester tester;
  final BeamerDelegate delegate;
  final BootHomePageDebt debt;
  final _LateSession session;

  /// The account's home-page read. Held open: on a station this is a second
  /// round trip after the session's, and the reported glimpse lives inside it.
  final Completer<void> lookupHold;

  String get path => delegate.configuration.uri.path;

  /// Pumps [count] frames, asserting after each that no page outside
  /// [allowed] has been built anywhere in the tree. `skipOffstage: false`
  /// because a page buried under another route is still a built page —
  /// subscribed and querying — even though nobody sees it.
  Future<void> frames(int count, {required Set<String> allowed}) async {
    for (var i = 0; i < count; i++) {
      await tester.pump();
      final built = _builtPages(tester);
      expect(built.difference(allowed), isEmpty, reason: 'frame $i at $path built $built; only $allowed may be');
    }
  }
}

Set<String> _builtPages(WidgetTester tester) =>
    tester.widgetList<AssetView>(find.byType(AssetView, skipOffstage: false)).map((view) => view.pageName).toSet();

/// The pages on the route the operator is actually looking at.
///
/// Beamer stacks every sub-matching route, so on a station that still has a
/// Home page, Home sits mounted under every other page for the life of the
/// process. That is a standing cost this test does not own; what it owns is
/// what the operator sees.
Set<String> _shownPages(WidgetTester tester) => tester
    .elementList(find.byType(AssetView, skipOffstage: false))
    .where((element) => ModalRoute.of(element)?.isCurrent ?? false)
    .map((element) => (element.widget as AssetView).pageName)
    .toSet();

/// Boots a router the way `main()` does, with [homePage] as the anonymous
/// account's home page and [pages] as the station's pages.
///
/// [known] false answers the home-page read as a database nobody could reach.
Future<_Boot> _boot(
  WidgetTester tester, {
  required List<MenuItem> pages,
  required String? homePage,
  bool known = true,
}) async {
  tester.binding.platformDispatcher.defaultRouteNameTestValue = '/';
  addTearDown(tester.binding.platformDispatcher.clearDefaultRouteNameTestValue);
  final topLevel = buildTopLevelMenuItems(isLinux: false, pageMenuItems: pages);
  RouteRegistry().menuItems.clear();
  for (final item in topLevel) {
    RouteRegistry().addMenuItem(item);
  }
  final pagePaths = <String>[
    for (final item in pages) ...[
      item.path!,
      for (final child in item.children) child.path!,
    ],
  ];
  final locationBuilder = createLocationBuilder(pages, pagePaths: pagePaths);
  final initialPath = resolveResumePath(
    epoch: EngineEpoch.unknown,
    lastRoute: null,
    startupPath: homePageDefault,
    isRoutable: locationBuilder.routes.containsKey,
  );
  final debt = BootHomePageDebt(
    owed: bootHomePageOwed(
      epoch: EngineEpoch.unknown,
      lastRoute: null,
      resumePath: initialPath,
      platformRoute: '/',
    ),
  );
  // Mirror main(): the first touch anywhere forgives the boot navigation.
  var listening = true;
  void forgive(PointerEvent event) {
    if (event is! PointerDownEvent) return;
    debt.forgive();
    listening = false;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(forgive);
  }

  GestureBinding.instance.pointerRouter.addGlobalRoute(forgive);
  addTearDown(() {
    if (listening) GestureBinding.instance.pointerRouter.removeGlobalRoute(forgive);
  });

  final topLevelPaths = <String>{
    '/',
    for (final item in topLevel)
      if (item.path != null && item.path != '/advanced') item.path!,
  };
  final delegate = BeamerDelegate(
    initialPath: initialPath,
    notFoundPage: const BeamPage(child: Text('not found')),
    // As MyApp: a page the router leaves is gone the same frame. With the
    // default delegate it would stay mounted for its exit animation, and a
    // page that is only ever painted mid-exit is not the defect this pins.
    transitionDelegate: MyNoAnimationTransitionDelegate(),
    clearBeamingHistoryOn: topLevelPaths,
    locationBuilder: (routeInformation, context) => locationBuilder(routeInformation, context),
  );
  final routeInformationProvider = PlatformRouteInformationProvider(
    initialRouteInformation: RouteInformation(
      uri: Uri.parse(normalizeInitialPlatformRoute(tester.binding.platformDispatcher.defaultRouteName)),
    ),
  );
  addTearDown(routeInformationProvider.dispose);
  final session = _LateSession();
  final lookupHold = Completer<void>();
  await tester.pumpWidget(ProviderScope(
    overrides: [
      accessSessionProvider.overrideWith(() => session),
      homePageLookupProvider.overrideWithValue((_) async {
        await lookupHold.future;
        return (known: known, page: known ? homePage : null);
      }),
      bootHomePageDebtProvider.overrideWithValue(debt),
    ],
    child: MaterialApp.router(
      routerDelegate: delegate,
      routeInformationParser: BeamerParser(),
      routeInformationProvider: routeInformationProvider,
    ),
  ));
  return _Boot(
    tester: tester,
    delegate: delegate,
    debt: debt,
    session: session,
    lookupHold: lookupHold,
  );
}

void main() {
  testWidgets('no Home page: the first page is never built on the way to the home page', (tester) async {
    final boot = await _boot(tester, pages: _pagesWithoutHome, homePage: '/line');
    // The first frame is the `/` stub; it beams to the first page after it.
    expect(_builtPages(tester), isEmpty);
    // The database has not answered: nothing may be built.
    await boot.frames(3, allowed: {'/line'});
    // The session is known. The home page is not — and this is the round trip
    // the reported glimpse lived in.
    boot.session.answer();
    await boot.frames(3, allowed: {'/line'});
    boot.lookupHold.complete();
    await boot.frames(5, allowed: {'/line'});

    expect(boot.path, '/line');
    expect(_builtPages(tester), {'/line'});
    expect(boot.debt.owed, isFalse);
  });

  testWidgets('a Home page is never shown on the way to the home page', (tester) async {
    final boot = await _boot(tester, pages: _pagesWithHome, homePage: '/line');
    expect(_shownPages(tester), isEmpty);
    for (var i = 0; i < 3; i++) {
      await tester.pump();
      expect(_shownPages(tester), isEmpty, reason: 'frame $i, no session yet');
    }
    boot.session.answer();
    for (var i = 0; i < 3; i++) {
      await tester.pump();
      expect(_shownPages(tester), isEmpty, reason: 'frame $i after the session, home page still unknown');
    }
    boot.lookupHold.complete();
    for (var i = 0; i < 5; i++) {
      await tester.pump();
      expect(_shownPages(tester).difference({'/line'}), isEmpty, reason: 'frame $i after the answer');
    }

    expect(boot.path, '/line');
    expect(_shownPages(tester), {'/line'});
  });

  testWidgets(
      'an account with no home page lands on the first page, '
      'once that is known', (tester) async {
    final boot = await _boot(tester, pages: _pagesWithoutHome, homePage: null);
    await boot.frames(3, allowed: const {});
    boot.session.answer();
    await boot.frames(3, allowed: const {});
    boot.lookupHold.complete();
    await boot.frames(5, allowed: {'/+aaa'});

    expect(boot.path, '/+aaa');
    expect(_builtPages(tester), {'/+aaa'});
    expect(boot.debt.owed, isFalse);
  });

  testWidgets('a database nobody could reach still opens the panel', (tester) async {
    final boot = await _boot(tester, pages: _pagesWithoutHome, homePage: '/line', known: false);
    boot.session.answer();
    await boot.frames(3, allowed: const {});
    boot.lookupHold.complete();
    await boot.frames(5, allowed: {'/+aaa'});

    expect(boot.path, '/+aaa');
    expect(_builtPages(tester), {'/+aaa'},
        reason: 'nobody could say where to open, so the panel opens where '
            'the router put it rather than waiting forever');
    expect(boot.debt.owed, isTrue, reason: 'the navigation is still owed once the database answers');
  });

  testWidgets('a touch while the home page is unknown opens the panel where it is', (tester) async {
    final boot = await _boot(tester, pages: _pagesWithoutHome, homePage: '/line');
    boot.session.answer();
    await boot.frames(3, allowed: const {});

    await tester.tapAt(const Offset(20, 20));
    await boot.frames(3, allowed: {'/+aaa'});
    expect(_builtPages(tester), {'/+aaa'}, reason: 'the operator has started working; the panel is theirs now');

    // The answer arriving later moves nothing.
    boot.lookupHold.complete();
    await boot.frames(5, allowed: {'/+aaa'});
    expect(boot.path, '/+aaa');
  });
}

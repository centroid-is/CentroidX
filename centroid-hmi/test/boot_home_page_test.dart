/// The boot seam, end to end: where a starting panel actually lands.
///
/// The router starts on `/`, or on the recorded route after an engine rebuild
/// ([resolveResumePath]). Then, once the session is known, `BaseScaffold`
/// takes the boot navigation to the home page of the account it answers as —
/// here the anonymous account — unless [bootHomePageOwed] says it is not owed.
/// Everything below is wired the way `main()` and `MyApp` wire it, including
/// whatever the platform reports as the initial route. Desktop embedders
/// report `/`; the eLinux embedder reports `''`, which defeats Beamer's own
/// `'/' -> initialPath` swap — the station bug behind #354 — so the router is
/// wired through the same normalizing RouteInformationProvider MyApp uses, and
/// every platform flavor is pinned here.
library;

import 'package:beamer/beamer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc/core/home_page.dart';
import 'package:tfc/core/last_route.dart';
import 'package:tfc/core/runner_liveness.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/home_page.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc_access/tfc_access.dart';

import 'package:centroidx/main.dart';
import 'package:centroidx/navigation.dart';

MenuItem _page(String label, String path) => MenuItem(label: label, path: path, icon: Icons.pageview);

/// Pages a small station would have: Home, a plain page, and a section
/// holding a nested page.
final _pageMenuItems = <MenuItem>[
  _page('Home', '/'),
  _page('Line', '/line'),
  MenuItem(label: 'Halls', path: '/halls', icon: Icons.folder, isSection: true, children: [
    _page('Packing', '/halls/packing'),
  ]),
];

class _Anonymous extends AccessSessionController {
  @override
  Future<AccessSession> build() async =>
      AccessSession.anonymous(const {AccessGroup.operate});

  @override
  void poke() {}
}

/// Boots a router the way `main()` does, with [homePage] as the anonymous
/// account's home page. Returns the delegate so the test can ask where the app
/// actually ended up.
Future<BeamerDelegate> _boot(
  WidgetTester tester,
  String? homePage, {
  // What the platform reports as the initial route: '/' on desktop
  // embedders, '' on eLinux.
  String platformRoute = '/',
  // Which engine generation this is and where the previous one was, for
  // the resume-after-rebuild seam.
  EngineEpoch epoch = EngineEpoch.unknown,
  String? lastRoute,
}) async {
  tester.binding.platformDispatcher.defaultRouteNameTestValue = platformRoute;
  addTearDown(tester.binding.platformDispatcher.clearDefaultRouteNameTestValue);
  final topLevel = buildTopLevelMenuItems(
    isLinux: false,
    pageMenuItems: _pageMenuItems,
  );
  // BaseScaffold draws the bottom NavigationBar from the RouteRegistry
  // singleton, the same one main() fills; it asserts on fewer than two
  // destinations, so the registry has to be populated for pages to build.
  RouteRegistry().menuItems.clear();
  for (final item in topLevel) {
    RouteRegistry().addMenuItem(item);
  }
  final locationBuilder = createLocationBuilder(
    _pageMenuItems,
    pagePaths: const ['/', '/line', '/halls', '/halls/packing'],
  );
  // Mirror main(): a rebuilt engine resumes the recorded route when it still
  // routes; everything else opens on Home.
  final initialPath = resolveResumePath(
    epoch: epoch,
    lastRoute: lastRoute,
    startupPath: homePageDefault,
    isRoutable: locationBuilder.routes.containsKey,
  );
  final debt = BootHomePageDebt(
    owed: bootHomePageOwed(
      epoch: epoch,
      lastRoute: lastRoute,
      resumePath: initialPath,
      platformRoute: platformRoute,
    ),
  );
  // Mirror main(): the top-level destinations clear beaming history, the
  // Advanced section excluded — a nested home page lives UNDER one of
  // these, so the set must not swallow it.
  final topLevelPaths = <String>{
    '/',
    for (final item in topLevel)
      if (item.path != null && item.path != '/advanced') item.path!,
  };
  final delegate = BeamerDelegate(
    initialPath: initialPath,
    notFoundPage: const BeamPage(child: Text('not found')),
    clearBeamingHistoryOn: topLevelPaths,
    locationBuilder: (routeInformation, context) => locationBuilder(routeInformation, context),
  );
  // Mirror MyApp: the initial route travels through the normalizing
  // provider, not straight from the platform into Beamer.
  final routeInformationProvider = PlatformRouteInformationProvider(
    initialRouteInformation: RouteInformation(
      uri: Uri.parse(normalizeInitialPlatformRoute(
          tester.binding.platformDispatcher.defaultRouteName)),
    ),
  );
  addTearDown(routeInformationProvider.dispose);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      accessSessionProvider.overrideWith(_Anonymous.new),
      homePageLookupProvider
          .overrideWithValue((_) async => (known: true, page: homePage)),
      bootHomePageDebtProvider.overrideWithValue(debt),
    ],
    child: MaterialApp.router(
      routerDelegate: delegate,
      routeInformationParser: BeamerParser(),
      routeInformationProvider: routeInformationProvider,
    ),
  ));
  for (var i = 0; i < 5; i++) {
    await tester.pump();
  }
  return delegate;
}

void main() {
  testWidgets('a top-level home page is where the app opens', (tester) async {
    final delegate = await _boot(tester, '/line');
    expect(delegate.configuration.uri.path, '/line');
  });

  testWidgets('a nested home page is where the app opens', (tester) async {
    final delegate = await _boot(tester, '/halls/packing');
    expect(delegate.configuration.uri.path, '/halls/packing');
  });

  testWidgets('a built-in destination as home page is where the app opens', (tester) async {
    final delegate = await _boot(tester, '/alarm-view');
    expect(delegate.configuration.uri.path, '/alarm-view');
  });

  testWidgets('no home page opens on /', (tester) async {
    final delegate = await _boot(tester, null);
    expect(delegate.configuration.uri.path, '/');
  });

  testWidgets('a home page deleted since it was chosen falls back to /', (tester) async {
    final delegate = await _boot(tester, '/gone');
    expect(delegate.configuration.uri.path, '/');
  });

  testWidgets('eLinux: an empty platform route still opens the home page', (tester) async {
    final delegate = await _boot(tester, '/halls/packing', platformRoute: '');
    expect(delegate.configuration.uri.path, '/halls/packing');
  });

  testWidgets('a bare platform route name counts as no opinion', (tester) async {
    final delegate = await _boot(tester, '/halls/packing', platformRoute: 'main');
    expect(delegate.configuration.uri.path, '/halls/packing');
  });

  testWidgets('a real deep link from the platform wins over the home page', (tester) async {
    final delegate = await _boot(tester, '/halls/packing', platformRoute: '/line');
    expect(delegate.configuration.uri.path, '/line');
  });

  testWidgets('eLinux: an empty platform route with no home page opens /', (tester) async {
    final delegate = await _boot(tester, null, platformRoute: '');
    expect(delegate.configuration.uri.path, '/');
  });

  // The Windows runner rebuilds the engine to recover a lost render context;
  // the new isolate is told its generation and puts the operator back where
  // they were instead of on the home page.
  const rebuilt = EngineEpoch(epoch: 2, reason: 'session change: remote connect');

  testWidgets('a rebuilt engine resumes the page the operator was on', (tester) async {
    final delegate = await _boot(tester, '/line', epoch: rebuilt, lastRoute: '/halls/packing');
    expect(delegate.configuration.uri.path, '/halls/packing');
  });

  testWidgets('a rebuilt engine resumes a built-in destination', (tester) async {
    final delegate = await _boot(tester, null, epoch: rebuilt, lastRoute: '/alarm-view');
    expect(delegate.configuration.uri.path, '/alarm-view');
  });

  testWidgets('a rebuilt engine that was on Home stays on Home', (tester) async {
    final delegate = await _boot(tester, '/line', epoch: rebuilt, lastRoute: '/');
    expect(delegate.configuration.uri.path, '/');
  });

  testWidgets('a process start ignores the recorded route', (tester) async {
    const first = EngineEpoch(epoch: 1, reason: 'initial start');
    final delegate = await _boot(tester, '/line', epoch: first, lastRoute: '/halls/packing');
    expect(delegate.configuration.uri.path, '/line');
  });

  testWidgets('a rebuilt engine whose recorded page is gone opens the home page', (tester) async {
    final delegate = await _boot(tester, '/line', epoch: rebuilt, lastRoute: '/gone');
    expect(delegate.configuration.uri.path, '/line');
  });

  testWidgets('eLinux-style empty platform route still resumes after a rebuild', (tester) async {
    final delegate = await _boot(tester, null, platformRoute: '', epoch: rebuilt, lastRoute: '/halls/packing');
    expect(delegate.configuration.uri.path, '/halls/packing');
  });
}

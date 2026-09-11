/// The white screen Jon reported on 0.2026.9.374, end to end.
///
/// The app was healthy — epoch 1, frames still being produced, 2 ms of timer
/// lag — and the panel was showing nothing at all: no app bar, no navigation
/// bar, no prompt. The one thing that had changed was that the access session
/// was gone.
///
/// The chain, and every link is exercised below:
///
///  1. This station has no Home page. `page_editor_top_level_order` starts at
///     `/speedbatchers`; there is no `/`. So `createLocationBuilder` registers
///     `/` as a [RouteRedirect] stub.
///  2. Beamer's `RoutesBeamLocation` stacks every sub-matching route, and `/`
///     sub-matches everything, so that stub is mounted *underneath every page
///     on the station* with its `State` alive for the life of the process.
///  3. `BaseScaffold._returnToStartupPage` beams to `resolveStartupPath(...)`
///     on every elevated-to-anonymous transition — a sign-out, or the
///     fifteen-minute inactivity expiry. Nothing is stored in `startup_url` on
///     this station, so that resolves to `/`.
///  4. The stub's page is revealed rather than created: `initState` does not
///     run again. The one-shot redirect never fired, and the panel sat on
///     `Scaffold(body: SizedBox.shrink())` — white — until somebody restarted
///     the app.
///
/// This test drives (3) through the real provider, and asserts the operator is
/// left looking at a page with chrome on it and a way back in, not a blank.
library;

import 'package:beamer/beamer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/widgets/access_status_action.dart';
import 'package:tfc/widgets/route_redirect.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/preferences.dart';

import 'package:centroidx/main.dart';
import 'package:centroidx/navigation.dart';

MenuItem _page(String label, String path) =>
    MenuItem(label: label, path: path, icon: Icons.pageview);

/// The live station's shape: pages, and **no `/`**.
final _pageMenuItems = <MenuItem>[
  _page('Speedbatchers', '/speedbatchers'),
  _page('Roe', '/roe'),
];

const List<String> _pagePaths = ['/speedbatchers', '/roe'];

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

  @override
  Future<void> remove(String key) async => _store.remove(key);
}

/// A session the test drives by hand, so the elevated-to-anonymous transition
/// that triggers the sign-out return is the real provider transition and not a
/// simulated beam.
class _DrivenSession extends AccessSessionController {
  @override
  Future<AccessSession> build() async => _elevated();

  void expire() => state = AsyncData(_anonymous());
}

AccessSession _elevated() => AccessSession(
      user: const AuthenticatedUser(
        username: 'centroid',
        roleName: 'Engineering',
        displayName: 'centroid',
      ),
      groups: AccessGroup.values.toSet(),
      expiresAt: DateTime.utc(2026, 9, 11, 14, 38),
    );

AccessSession _anonymous() =>
    AccessSession.anonymous(const {AccessGroup.operate});

Future<(BeamerDelegate, _DrivenSession)> _boot(WidgetTester tester) async {
  tester.binding.platformDispatcher.defaultRouteNameTestValue = '/';
  addTearDown(tester.binding.platformDispatcher.clearDefaultRouteNameTestValue);

  final topLevel =
      buildTopLevelMenuItems(isLinux: false, pageMenuItems: _pageMenuItems);
  RouteRegistry().menuItems.clear();
  for (final item in topLevel) {
    RouteRegistry().addMenuItem(item);
  }
  final locationBuilder =
      createLocationBuilder(_pageMenuItems, pagePaths: _pagePaths);

  // Nothing stored, exactly like the station: resolveStartupPath answers '/'.
  final startupPath = resolveStartupPath('/', menuItems: topLevel);
  expect(startupPath, '/');

  final topLevelPaths = <String>{
    '/',
    for (final item in topLevel)
      if (item.path != null && item.path != '/advanced') item.path!,
  };
  final delegate = BeamerDelegate(
    initialPath: startupPath,
    notFoundPage: const BeamPage(child: Text('not found')),
    clearBeamingHistoryOn: topLevelPaths,
    locationBuilder: (ri, ctx) => locationBuilder(ri, ctx),
  );

  final rip = PlatformRouteInformationProvider(
    initialRouteInformation: RouteInformation(
      uri: Uri.parse(normalizeInitialPlatformRoute(
          tester.binding.platformDispatcher.defaultRouteName)),
    ),
  );
  addTearDown(rip.dispose);

  final session = _DrivenSession();
  await tester.pumpWidget(ProviderScope(
    overrides: [
      accessSessionProvider.overrideWith(() => session),
      localPreferencesProvider.overrideWithValue(_MemoryPrefs()),
    ],
    child: BeamerProvider(
      routerDelegate: delegate,
      child: MaterialApp.router(
        routerDelegate: delegate,
        routeInformationParser: BeamerParser(),
        routeInformationProvider: rip,
      ),
    ),
  ));
  await tester.pump();
  await tester.pump();
  return (delegate, session);
}

/// The app-bar sign-in control: an anonymous panel's way back in.
Finder _signInAffordance() =>
    find.byWidgetPredicate((w) => w is IconButton && w.tooltip == 'Sign in');

void main() {
  testWidgets('a station with no Home page still boots onto a real page',
      (tester) async {
    final (delegate, _) = await _boot(tester);
    expect(delegate.configuration.uri.path, '/speedbatchers');
  });

  testWidgets(
      'the session ending does not leave the panel on a blank white page',
      (tester) async {
    final (delegate, session) = await _boot(tester);
    expect(delegate.configuration.uri.path, '/speedbatchers');

    // The sign-out / inactivity-expiry transition, through the real provider.
    // BaseScaffold's listener beams to the resolved startup path.
    session.expire();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    await tester.pump();

    // The redirect re-armed, so the app is on a real page and not parked on
    // the stub.
    expect(delegate.configuration.uri.path, '/speedbatchers');

    // And the page it is on has chrome: the navigation bar the operator
    // navigates with, and the app-bar Sign in control that says what state
    // the panel is in and offers the way back.
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(AccessStatusAction), findsWidgets);
    expect(_signInAffordance(), findsOneWidget);
  });

  testWidgets('and if the redirect is ever wedged, the stub is not blank',
      (tester) async {
    // The belt-and-braces half: the stub itself, rendered.
    await tester.pumpWidget(const MaterialApp(
      home: RouteRedirect(from: '/', target: '/speedbatchers'),
    ));
    await tester.pump();

    expect(find.byKey(kRouteRedirectBodyKey), findsOneWidget);
    expect(find.text(kRouteRedirectNote('/speedbatchers')), findsOneWidget);
    expect(find.byKey(kRouteRedirectGoKey), findsOneWidget);
  });
}

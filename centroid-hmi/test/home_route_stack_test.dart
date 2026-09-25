/// What a Home page costs while the operator is looking at something else.
///
/// Beamer's `RoutesBeamLocation` stacks a page for every route that
/// sub-matches the location, and `/` sub-matches every path. On a station
/// with a real Home page that meant the Home page was built underneath every
/// other page in the app — built, with its `State` alive and every one of its
/// assets subscribed to OPC UA — for the whole life of the process. Nobody was
/// looking at it, and on a plant where Home carries live equipment it was a
/// permanent extra subscription set on every panel.
///
/// The route table now serves `/` only when `/` is the location
/// ([RootRouteLocationBuilder]). These tests pin the thing that matters, which
/// is the subscription and not the pixels: the fake StateMan below counts the
/// live listeners on every key, and the Home page's key must have none while
/// the operator is on another page — and one again when they come back.
library;

import 'dart:async';

import 'package:beamer/beamer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/page_creator/assets/led.dart';
import 'package:tfc/page_creator/page.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/home_page.dart';
import 'package:tfc/providers/page_manager.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/transition_delegate.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/state_man.dart';

import 'package:centroidx/main.dart';
import 'package:centroidx/navigation.dart';
import 'package:centroidx/root_route_location_builder.dart';

const _homeKey = 'home.lamp';
const _lineKey = 'line.lamp';

MenuItem _page(String label, String path) => MenuItem(label: label, path: path, icon: Icons.pageview);

/// A station with a Home page that carries a live asset, and one more page.
final _pageMenuItems = <MenuItem>[
  _page('Home', '/'),
  _page('Line', '/line'),
];

PageManager _pageManager() => PageManager(
      pages: {
        '/': AssetPage(
          menuItem: _pageMenuItems[0],
          assets: [LEDConfig(key: _homeKey)],
          mirroringDisabled: false,
        ),
        '/line': AssetPage(
          menuItem: _pageMenuItems[1],
          assets: [LEDConfig(key: _lineKey)],
          mirroringDisabled: false,
        ),
      },
      prefs: _MemoryPrefs(),
    );

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

/// Counts what the pages actually ask of OPC UA: how many times each key was
/// subscribed, and how many listeners are on it right now.
class _CountingStateMan implements StateMan {
  final Map<String, int> subscribed = {};
  final Map<String, int> active = {};

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async {
    subscribed[key] = (subscribed[key] ?? 0) + 1;
    late final StreamController<DynamicValue> controller;
    controller = StreamController<DynamicValue>(
      onListen: () => active[key] = (active[key] ?? 0) + 1,
      onCancel: () => active[key] = (active[key] ?? 0) - 1,
    );
    return controller.stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError(
      '_CountingStateMan: ${invocation.memberName} is not part of this test',
    );
  }
}

class _Anonymous extends AccessSessionController {
  @override
  Future<AccessSession> build() async => AccessSession.anonymous(const {AccessGroup.operate});

  @override
  void poke() {}
}

Future<(BeamerDelegate, _CountingStateMan)> _boot(WidgetTester tester) async {
  tester.binding.platformDispatcher.defaultRouteNameTestValue = '/';
  addTearDown(tester.binding.platformDispatcher.clearDefaultRouteNameTestValue);

  final topLevel = buildTopLevelMenuItems(isLinux: false, pageMenuItems: _pageMenuItems);
  RouteRegistry().menuItems.clear();
  for (final item in topLevel) {
    RouteRegistry().addMenuItem(item);
  }
  final locationBuilder = createLocationBuilder(_pageMenuItems, pagePaths: const ['/', '/line']);

  final topLevelPaths = <String>{
    '/',
    for (final item in topLevel)
      if (item.path != null && item.path != '/advanced') item.path!,
  };
  final delegate = BeamerDelegate(
    initialPath: '/',
    notFoundPage: const BeamPage(child: Text('not found')),
    clearBeamingHistoryOn: topLevelPaths,
    // As MyApp wires it. With the default delegate a page that leaves the
    // stack stays mounted -- and subscribed -- for the length of its pop
    // animation, which zero-duration pumps never finish.
    transitionDelegate: MyNoAnimationTransitionDelegate(),
    locationBuilder: (ri, ctx) => locationBuilder(ri, ctx),
  );
  final rip = PlatformRouteInformationProvider(
    initialRouteInformation: RouteInformation(
      uri: Uri.parse(normalizeInitialPlatformRoute(tester.binding.platformDispatcher.defaultRouteName)),
    ),
  );
  addTearDown(rip.dispose);

  final stateMan = _CountingStateMan();
  await tester.pumpWidget(ProviderScope(
    overrides: [
      accessSessionProvider.overrideWith(_Anonymous.new),
      localPreferencesProvider.overrideWithValue(_MemoryPrefs()),
      homePageLookupProvider.overrideWithValue((_) async => (known: true, page: null)),
      // The plant pages, the way `main()` hands them over before the
      // database has answered.
      bootstrapPageManagerProvider.overrideWithValue(_pageManager()),
      stateManProvider.overrideWith((_) async => stateMan),
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
  await _settle(tester);
  return (delegate, stateMan);
}

/// The subscription opens in a microtask after the asset builds; a few pumps
/// carry it through.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump();
  }
}

/// The LED bound to [key], wherever it is in the tree.
Finder _ledFor(String key) => find.byWidgetPredicate((w) => w is Led && w.config.key == key);

void main() {
  group('RootRouteLocationBuilder', () {
    BeamPage page(String path) => BeamPage(key: ValueKey(path), child: Text(path));
    final routes = <Pattern, dynamic Function(BuildContext, BeamState, Object?)>{
      '/': (_, __, ___) => page('/'),
      '/line': (_, __, ___) => page('/line'),
      '/halls': (_, __, ___) => page('/halls'),
      '/halls/packing': (_, __, ___) => page('/halls/packing'),
    };

    List<Object?> stackFor(WidgetTester tester, String path) {
      final lb = RootRouteLocationBuilder(routes: routes);
      final location = lb(RouteInformation(uri: Uri.parse(path)), null);
      expect(location, isA<RoutesBeamLocation>(), reason: path);
      final built = location.buildPages(
        tester.element(find.byType(SizedBox)),
        location.state as BeamState,
      );
      return [for (final p in built) (p.key as ValueKey).value];
    }

    testWidgets('/ is served alone when / is the location', (tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      expect(stackFor(tester, '/'), ['/']);
    });

    testWidgets('/ is not stacked under any other page', (tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      expect(stackFor(tester, '/line'), ['/line']);
      // Genuine nesting is Beamer's own contract and is left alone: a section
      // still sits under its child.
      expect(stackFor(tester, '/halls/packing'), ['/halls', '/halls/packing']);
    });

    testWidgets('the one location the delegate keeps drops / as it moves', (tester) async {
      // The delegate reuses its location when the builder returns the same
      // runtime type -- `update()` on the old object, the new one discarded --
      // so the decision has to hold for a location that was created at `/`
      // and then moved. This is the case a filter in the builder alone got
      // wrong.
      await tester.pumpWidget(const SizedBox.shrink());
      final lb = RootRouteLocationBuilder(routes: routes);
      final location = lb(RouteInformation(uri: Uri.parse('/')), null);
      List<Object?> stack() => [
            for (final p in location.buildPages(tester.element(find.byType(SizedBox)), location.state as BeamState))
              (p.key as ValueKey).value
          ];
      expect(stack(), ['/']);
      location.update(null, RouteInformation(uri: Uri.parse('/line')), null, false, false);
      expect(stack(), ['/line']);
      location.update(null, RouteInformation(uri: Uri.parse('/')), null, false, false);
      expect(stack(), ['/']);
    });

    testWidgets('an unknown path is still not found', (tester) async {
      final lb = RootRouteLocationBuilder(routes: routes);
      expect(lb(RouteInformation(uri: Uri.parse('/nowhere')), null), isA<NotFound>());
    });

    test('the route table still lists /, so resume and menu checks see it', () {
      final lb = RootRouteLocationBuilder(routes: routes);
      expect(lb.routes.containsKey('/'), isTrue);
    });
  });

  group('a Home page on a station', () {
    testWidgets('is subscribed while the operator is on it', (tester) async {
      final (delegate, stateMan) = await _boot(tester);
      expect(delegate.configuration.uri.path, '/');
      expect(_ledFor(_homeKey), findsOneWidget);
      expect(stateMan.active[_homeKey], 1);
      expect(stateMan.subscribed[_lineKey], isNull);
    });

    testWidgets('is neither mounted nor subscribed under another page', (tester) async {
      final (delegate, stateMan) = await _boot(tester);
      expect(stateMan.active[_homeKey], 1);

      delegate.beamToNamed('/line');
      await _settle(tester);
      expect(delegate.configuration.uri.path, '/line');

      // The page the operator is on reads its own key ...
      expect(_ledFor(_lineKey), findsOneWidget);
      expect(stateMan.active[_lineKey], 1);
      // ... and Home reads nothing: its OPC UA subscription is gone, and so
      // are its assets from the tree.
      expect(stateMan.active[_homeKey], 0, reason: 'the Home page must not keep subscribing under /line');
      expect(_ledFor(_homeKey), findsNothing);
    });

    testWidgets('subscribes again when the operator comes back', (tester) async {
      final (delegate, stateMan) = await _boot(tester);
      delegate.beamToNamed('/line');
      await _settle(tester);
      expect(stateMan.active[_homeKey], 0);

      delegate.beamToNamed('/');
      await _settle(tester);
      expect(delegate.configuration.uri.path, '/');
      expect(_ledFor(_homeKey), findsOneWidget);
      expect(stateMan.active[_homeKey], 1);
      expect(stateMan.subscribed[_homeKey], 2);
      // And the page left behind let go of its own key.
      expect(_ledFor(_lineKey), findsNothing);
      expect(stateMan.active[_lineKey], 0);
    });
  });
}

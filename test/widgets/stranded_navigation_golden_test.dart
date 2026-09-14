/// The screen an operator used to be stranded on, cured.
///
/// The whitelist in these frames names two pages, both nested inside one
/// navigation section, and the panel has landed on a page that whitelist does
/// not cover. Before the fix this rendered as the refusal alone over a scaffold
/// with **no bottom bar at all**: `VisibleMenu.showsBar` read
/// `topLevel.length >= 2`, borrowed from Material's `NavigationBar` assert, and
/// one surviving top-level entry — the section — was one too few.
///
/// The image is the record of both halves of the repair: the section is on a
/// one-destination bar, and the refusal names the pages the session can open
/// rather than leaving the operator to guess that the icon at the bottom of the
/// screen is a dropdown.
library;

import 'package:beamer/beamer.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/alarm.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/theme.dart' show solarized;
import 'package:tfc/widgets/base_scaffold.dart';
import 'package:tfc/widgets/page_access_gate.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_repository.dart';

import 'alarm_fixture.dart';
import '../helpers/golden_fonts.dart';
import '../helpers/golden_platform.dart';

/// Frozen so the app bar's ticking clock does not churn the PNG every run —
/// the same reason the app-bar goldens pin it.
final Clock _goldenClock = Clock.fixed(DateTime(2026, 9, 14, 9, 20, 30));

const _frameKey = Key('stranded-navigation-golden');

class _StubRepository extends Fake implements AccessRepository {}

class _FixedSession extends AccessSessionController {
  _FixedSession(this._pages);
  final Set<String> _pages;

  @override
  Future<AccessSession> build() async => AccessSession(
        groups: const {AccessGroup.operate},
        allowedPages: _pages,
      );

  @override
  Future<AccessSignInResult> signIn(String u, String p) async =>
      AccessSignInResult.ok;
  @override
  Future<void> signOut() async {}
  @override
  void poke() {}
}

/// Neutral throughout — this repo is pushed and the shape is the whole point.
const _home = MenuItem(label: 'Home', path: '/', icon: Icons.home);
const _lines = MenuItem(
  label: 'Lines',
  path: '/line',
  icon: Icons.account_tree,
  isSection: true,
  children: [
    MenuItem(label: 'Line A', path: '/line/a', icon: Icons.linear_scale),
    MenuItem(label: 'Line B', path: '/line/b', icon: Icons.linear_scale),
    MenuItem(label: 'Line C', path: '/line/c', icon: Icons.linear_scale),
  ],
);

Widget _frame({required bool dark}) {
  final (light, darkTheme) = solarized();
  final delegate = BeamerDelegate(
    initialPath: '/',
    locationBuilder: RoutesLocationBuilder(routes: {
      '/': (context, state, data) => const BeamPage(
            key: ValueKey('/'),
            child: PageAccessGate(
              path: '/',
              title: 'Home',
              child: BaseScaffold(title: 'Home', body: Text('home-body')),
            ),
          ),
    }).call,
  );

  return ProviderScope(
    overrides: [
      accessSessionProvider
          .overrideWith(() => _FixedSession(const {'/line/a', '/line/b'})),
      accessRepositoryProvider.overrideWith((ref) async => _StubRepository()),
      alarmManProvider.overrideWith((ref) async => AlarmFixture()),
    ],
    child: RepaintBoundary(
      key: _frameKey,
      child: BeamerProvider(
        routerDelegate: delegate,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: dark ? darkTheme : light,
          routerDelegate: delegate,
          routeInformationParser: BeamerParser(),
        ),
      ),
    ),
  );
}

Future<void> _pump(WidgetTester tester, {required bool dark}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  RouteRegistry().clearRouteGroups();
  RouteRegistry().menuItems
    ..clear()
    ..addAll(const [_home, _lines]);

  await tester.pumpWidget(_frame(dark: dark));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadGoldenFonts);
  tearDown(() => RouteRegistry().menuItems.clear());

  group('the stranded operator, cured', skip: goldenSkip, () {
    testWidgets('a section-only whitelist keeps its bar and names its pages',
        (tester) async {
      await withClock(_goldenClock, () async {
        await _pump(tester, dark: false);
        await expectLater(
          find.byKey(_frameKey),
          matchesGoldenFile('goldens/stranded_navigation_cured.png'),
        );
      });
    });

    testWidgets('the same frame, dark', (tester) async {
      await withClock(_goldenClock, () async {
        await _pump(tester, dark: true);
        await expectLater(
          find.byKey(_frameKey),
          matchesGoldenFile('goldens/stranded_navigation_cured_dark.png'),
        );
      });
    });
  });
}

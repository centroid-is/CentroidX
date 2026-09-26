/// The operator who could not leave the screen.
///
/// Reported off a running panel: an account whose page whitelist named only
/// pages **nested inside one navigation section** got an entirely empty
/// navigation bar — no section heading, no entries — so the two pages it had
/// been granted were unreachable and the only thing on screen was the "This
/// page is not available" refusal. Adding one unrelated top-level page to the
/// same whitelist made both entries appear, which is what made it look like a
/// section-filtering fault.
///
/// It was not. `visibleMenu` filtered correctly the whole time and returned
/// the section with its two survivors; `VisibleMenu.showsBar` then threw the
/// bar away, because it read `topLevel.length >= 2` — Material's
/// `NavigationBar` assert, taken as if it were a rule about what an operator
/// may reach. One top-level entry is one destination, and one destination is a
/// bar.
///
/// These tests are at the widget, not the provider, because the provider was
/// never wrong: the assertion that matters is that something an operator can
/// press is on the screen.
library;

import 'dart:async';

import 'package:beamer/beamer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/widgets/base_scaffold.dart';
import 'package:tfc/widgets/page_access_gate.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_repository.dart';

class _StubRepository extends Fake implements AccessRepository {}

class _FixedSession extends AccessSessionController {
  _FixedSession(this._value);
  final AsyncValue<AccessSession> _value;

  @override
  Future<AccessSession> build() async {
    final value = _value;
    if (value is AsyncData<AccessSession>) return value.value;
    return Completer<AccessSession>().future;
  }

  @override
  Future<AccessSignInResult> signIn(String u, String p) async =>
      AccessSignInResult.ok;
  @override
  Future<void> signOut() async {}
  @override
  void poke() {}
}

// Neutral names throughout: this is a product repo and the shape of the fault
// is the whole of what matters.
const _home = MenuItem(label: 'Home', path: '/', icon: Icons.home);
const _lineA =
    MenuItem(label: 'Line A', path: '/line/a', icon: Icons.linear_scale);
const _lineB =
    MenuItem(label: 'Line B', path: '/line/b', icon: Icons.linear_scale);
const _lineC =
    MenuItem(label: 'Line C', path: '/line/c', icon: Icons.linear_scale);

/// A section with three pages under it — the shape of the reported menu.
const _lines = MenuItem(
  label: 'Lines',
  path: '/line',
  icon: Icons.account_tree,
  isSection: true,
  children: [_lineA, _lineB, _lineC],
);

void main() {
  setUp(() {
    RouteRegistry().clearRouteGroups();
    RouteRegistry().menuItems.clear();
  });
  tearDown(() => RouteRegistry().menuItems.clear());

  /// Every route gated the way the app gates them, so a tap on a destination
  /// lands on the real gate rather than on a stand-in that always says yes.
  BeamerDelegate buildRouter() {
    BeamPage page(String path, String title, String body) => BeamPage(
          key: ValueKey(path),
          child: PageAccessGate(
            path: path,
            title: title,
            child: BaseScaffold(title: title, body: Center(child: Text(body))),
          ),
        );

    return BeamerDelegate(
      initialPath: '/',
      locationBuilder: RoutesLocationBuilder(routes: {
        '/': (_, __, ___) => page('/', 'Home', 'the home page'),
        '/line/a': (_, __, ___) => page('/line/a', 'Line A', 'line A page'),
        '/line/b': (_, __, ___) => page('/line/b', 'Line B', 'line B page'),
        '/line/c': (_, __, ___) => page('/line/c', 'Line C', 'line C page'),
      }).call,
    );
  }

  /// [signedInAs] is what tells the two whitelist refusals apart. With nobody
  /// signed in and no page granted, the panel leads with the sign-in
  /// (`anonymousSeesNothing`); with an account signed in, "not available" is
  /// the honest first sentence, because a credential is not what is missing.
  /// The bar cases below do not care either way and leave it null.
  Widget host(BeamerDelegate router,
      {required Set<String> allowedPages, AuthenticatedUser? signedInAs}) {
    return ProviderScope(
      overrides: [
        accessSessionProvider.overrideWith(() => _FixedSession(
              AsyncValue.data(AccessSession(
                user: signedInAs,
                groups: const {AccessGroup.operate},
                allowedPages: allowedPages,
                expiresAt: signedInAs == null
                    ? null
                    : DateTime.utc(2026, 9, 17, 12),
              )),
            )),
        accessRepositoryProvider.overrideWith((ref) async => _StubRepository()),
      ],
      child: BeamerProvider(
        routerDelegate: router,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          routerDelegate: router,
          routeInformationParser: BeamerParser(),
        ),
      ),
    );
  }

  testWidgets(
      'a whitelist of nothing but section pages still gives the operator a bar',
      (tester) async {
    // The reported configuration, end to end. The account may see two pages,
    // both inside one section; it starts on the home page, which it may not
    // see. Before the fix this rendered the refusal over a bar-less scaffold:
    // no section, no entries, nothing to press.
    RouteRegistry().menuItems
      ..clear()
      ..addAll(const [_home, _lines]);

    final router = buildRouter();
    await tester.pumpWidget(
      host(router, allowedPages: const {'/line/a', '/line/b'}),
    );
    await tester.pumpAndSettle();

    // The refusal is honest: the home page is not opened and is not built.
    expect(find.byKey(kPageNotAvailableBodyKey), findsOneWidget);
    expect(find.text('the home page'), findsNothing);

    // And it is not a dead end. One top-level entry survives — the section —
    // so the bar is the single-destination one, and the section is on it.
    expect(find.byKey(kSingleDestinationBarKey), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing,
        reason: 'Material asserts on one destination; this bar is why the '
            'assert is no longer the app rule');
    expect(find.text('Lines'), findsWidgets);
  });

  testWidgets(
      'the refusal offers the pages the session can open, and they '
      'open', (tester) async {
    // The second half: the operator should not have to guess that the one
    // icon at the bottom of the screen is a dropdown. The pages are named
    // where they are looking, and pressing one actually goes there.
    RouteRegistry().menuItems
      ..clear()
      ..addAll(const [_home, _lines]);

    final router = buildRouter();
    await tester.pumpWidget(
      host(router, allowedPages: const {'/line/a', '/line/b'}),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(kPageNotAvailableDestinationsKey), findsOneWidget);
    expect(find.text(kPageNotAvailableElsewhereHeadline), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Line A'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Line B'), findsOneWidget);
    // Not offered: it is in the section but not in the whitelist.
    expect(find.widgetWithText(OutlinedButton, 'Line C'), findsNothing);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Line A'));
    await tester.pumpAndSettle();

    expect(find.text('line A page'), findsOneWidget);
    expect(find.byKey(kPageNotAvailableBodyKey), findsNothing);
  });

  testWidgets(
      'a top-level page beside section pages shows both — the state '
      'that accidentally worked', (tester) async {
    // This is the configuration that made the fault look like a section bug:
    // the same two section pages plus one unrelated top-level page put both
    // entries on the bar. It has to keep working, and now for the right
    // reason.
    RouteRegistry().menuItems
      ..clear()
      ..addAll(const [_home, _lines]);

    final router = buildRouter();
    await tester.pumpWidget(
      host(router, allowedPages: const {'/', '/line/a', '/line/b'}),
    );
    await tester.pumpAndSettle();

    // Home is whitelisted now, so the page itself opens.
    expect(find.text('the home page'), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byKey(kSingleDestinationBarKey), findsNothing);
    expect(find.text('Home'), findsWidgets);
    expect(find.text('Lines'), findsWidgets);
  });

  testWidgets('a single top-level leaf is a bar too', (tester) async {
    // The same counting fault, without a section in it: one whitelisted
    // top-level page used to mean no bar at all.
    RouteRegistry().menuItems
      ..clear()
      ..addAll(const [_home, _lineA]);

    final router = buildRouter();
    await tester.pumpWidget(host(router, allowedPages: const {'/line/a'}));
    await tester.pumpAndSettle();

    expect(find.byKey(kPageNotAvailableBodyKey), findsOneWidget);
    expect(find.byKey(kSingleDestinationBarKey), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('nav-line a')));
    await tester.pumpAndSettle();

    expect(find.text('line A page'), findsOneWidget);
  });

  testWidgets(
      'an account that can open nothing gets no bar and no empty '
      'offer', (tester) async {
    // The degenerate configuration. There is nothing to navigate to, so there
    // is no bar and no heading promising destinations there are none of — the
    // refusal and its sign-in button stand alone, which is the honest answer.
    RouteRegistry().menuItems
      ..clear()
      ..addAll(const [_home, _lines]);

    final router = buildRouter();
    await tester.pumpWidget(host(
      router,
      allowedPages: const <String>{},
      signedInAs: const AuthenticatedUser(
          username: 'lina', roleName: 'Line Lead', displayName: 'Lina R'),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(kPageNotAvailableBodyKey), findsOneWidget);
    expect(find.byKey(kSingleDestinationBarKey), findsNothing);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byKey(kPageNotAvailableDestinationsKey), findsNothing);
    expect(find.byKey(kPageNotAvailableSignInKey), findsOneWidget);
  });
}

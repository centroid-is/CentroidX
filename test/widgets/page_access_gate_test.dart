/// `PageAccessGate` — the route gate for the plant's own pages.
///
/// Two things are pinned here and both are holes this widget closed:
///
///  * **A page raised in the page editor is refused on a deep link.** Before
///    this gate, page-manager routes were a bare `AssetView`: a raised page
///    vanished from the menu and still opened to anyone who typed its URL, so
///    hiding was the whole of the enforcement. The truth table below is what
///    keeps that closed.
///  * **The whitelist is a filter, never a grant.** The group question is
///    asked first, and a page listed in somebody's whitelist still cannot
///    open if its group says no.
///
/// The boot window is deliberately permissive and that is tested too, because
/// it is the rule somebody will "fix" into failing closed: an unresolved
/// session must not blank every page on a panel that is merely still starting.
library;

import 'dart:async';

import 'package:beamer/beamer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/access_routes.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/widgets/access_gate.dart';
import 'package:tfc/widgets/page_access_gate.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_repository.dart';

class _StubRepository extends Fake implements AccessRepository {}

const _loadingRepo = AsyncValue<AccessRepository?>.loading();
final _presentRepo = AsyncValue<AccessRepository?>.data(_StubRepository());
const _absentRepo = AsyncValue<AccessRepository?>.data(null);

const _loadingSession = AsyncValue<AccessSession>.loading();

AsyncValue<AccessSession> _session({
  Set<AccessGroup> groups = const {AccessGroup.operate},
  Set<String>? pages,
  bool elevated = false,
}) =>
    AsyncValue<AccessSession>.data(AccessSession(
      user: elevated
          ? const AuthenticatedUser(
              username: 'lina', roleName: 'Line Lead', displayName: 'Lina R')
          : null,
      groups: groups,
      allowedPages: pages,
      expiresAt: elevated ? DateTime.utc(2026, 9, 11, 12) : null,
    ));

void main() {
  setUp(() {
    RouteRegistry().clearRouteGroups();
    RouteRegistry().menuItems.clear();
  });

  group('resolvePageAccess — the group half', () {
    test('an unraised page opens before anything has resolved', () {
      // The operate short-circuit. Without it every plant page would show a
      // spinner for as long as the database takes to answer, which on a cut
      // link is tens of seconds of a panel that reads as broken.
      expect(
        resolvePageAccess(
          group: AccessGroup.operate,
          path: '/fillet',
          repository: _loadingRepo,
          session: _loadingSession,
        ),
        AccessGateState.allowed,
      );
    });

    test('a raised page waits rather than guessing while loading', () {
      expect(
        resolvePageAccess(
          group: AccessGroup.configure,
          path: '/fillet',
          repository: _loadingRepo,
          session: _loadingSession,
        ),
        AccessGateState.waiting,
      );
    });

    test('a raised page is refused when the session lacks the group', () {
      expect(
        resolvePageAccess(
          group: AccessGroup.configure,
          path: '/fillet',
          repository: _presentRepo,
          session: _session(),
        ),
        AccessGateState.denied,
      );
    });

    test('a raised page opens when the session holds the group', () {
      expect(
        resolvePageAccess(
          group: AccessGroup.configure,
          path: '/fillet',
          repository: _presentRepo,
          session:
              _session(groups: {AccessGroup.operate, AccessGroup.configure}),
        ),
        AccessGateState.allowed,
      );
    });

    test('the Server Config outage exemption is honoured, not hardcoded', () {
      // Not a page, but the navigation filter asks this same function about
      // built-in routes. Hardcoding false here hid the one page that repairs
      // an outage, for the length of the outage.
      expect(
        resolvePageAccess(
          group: AccessGroup.administer,
          path: kServerConfigRoute,
          repository: _absentRepo,
          session: _session(),
        ),
        AccessGateState.allowed,
      );
      expect(
        resolvePageAccess(
          group: AccessGroup.configure,
          path: '/advanced/page-editor',
          repository: _absentRepo,
          session: _session(),
        ),
        AccessGateState.denied,
        reason: 'the others stay shut through an outage',
      );
    });
  });

  group('resolvePageAccess — the whitelist half', () {
    test('no whitelist admits every page', () {
      expect(
        resolvePageAccess(
          group: AccessGroup.operate,
          path: '/anything',
          repository: _presentRepo,
          session: _session(pages: null),
        ),
        AccessGateState.allowed,
      );
    });

    test('a whitelist admits exactly what it lists', () {
      final session = _session(pages: const {'/fillet'});
      expect(
        resolvePageAccess(
          group: AccessGroup.operate,
          path: '/fillet',
          repository: _presentRepo,
          session: session,
        ),
        AccessGateState.allowed,
      );
      expect(
        resolvePageAccess(
          group: AccessGroup.operate,
          path: '/packing',
          repository: _presentRepo,
          session: session,
        ),
        AccessGateState.denied,
      );
    });

    test('an empty whitelist admits nothing — block all', () {
      expect(
        resolvePageAccess(
          group: AccessGroup.operate,
          path: '/fillet',
          repository: _presentRepo,
          session: _session(pages: const <String>{}),
        ),
        AccessGateState.denied,
      );
    });

    test('the whitelist never grants what the group denies', () {
      // The composition rule. A page listed here and raised to `configure`
      // must still be refused for a session that does not hold `configure`;
      // the whitelist is a filter, and a filter cannot open a door.
      expect(
        resolvePageAccess(
          group: AccessGroup.configure,
          path: '/fillet',
          repository: _presentRepo,
          session: _session(pages: const {'/fillet'}),
        ),
        AccessGateState.denied,
      );
    });

    test('the access screen is exempt — no whitelist can hide it', () {
      // Layer 1 of the no-lockout argument, and the one that was prose rather
      // than code: the menu filter asks this same function about every entry
      // in the tree, so an empty whitelist used to drop `/advanced/access`
      // from the menu of the very person who could repair it.
      for (final pages in [const <String>{}, const {'/fillet'}]) {
        expect(
          resolvePageAccess(
            group: AccessGroup.users,
            path: kAccessAdminRoute,
            repository: _presentRepo,
            session: _session(groups: const {AccessGroup.users}, pages: pages),
          ),
          AccessGateState.allowed,
          reason: 'whitelist $pages must not reach the access screen',
        );
      }
    });

    test('the exemption is the whitelist half only, never the group half', () {
      // Exempt from the whitelist is not exempt from `users`. A session
      // without the group still meets the lock, which is what stops the
      // exemption becoming an open door on the one screen that edits roles.
      expect(
        resolvePageAccess(
          group: AccessGroup.users,
          path: kAccessAdminRoute,
          repository: _presentRepo,
          session: _session(groups: const {AccessGroup.operate}),
        ),
        AccessGateState.denied,
      );
    });

    test('every other Advanced route is whitelistable', () {
      // The other half of the fix. These are ordinary entries as far as the
      // whitelist is concerned — hidden when unlisted, granted when ticked —
      // which is what makes the picker's new rows mean something.
      final session = _session(
        groups: const {AccessGroup.configure},
        pages: const {'/advanced/alarm-editor'},
      );
      expect(
        resolvePageAccess(
          group: AccessGroup.configure,
          path: '/advanced/alarm-editor',
          repository: _presentRepo,
          session: session,
        ),
        AccessGateState.allowed,
      );
      expect(
        resolvePageAccess(
          group: AccessGroup.configure,
          path: '/advanced/page-editor',
          repository: _presentRepo,
          session: session,
        ),
        AccessGateState.denied,
      );
    });

    test('the boot window is not filtered', () {
      // `kSessionWhileLoading` carries no whitelist, so a page whose group is
      // `operate` opens while the session resolves. A `denied` here would
      // blank every page on every boot.
      expect(
        resolvePageAccess(
          group: AccessGroup.operate,
          path: '/fillet',
          repository: _loadingRepo,
          session: _loadingSession,
        ),
        AccessGateState.allowed,
      );
    });
  });

  group('the widget', () {
    // A Beamer host, because both refusal bodies come wrapped in a
    // `BaseScaffold` — deliberately, so the app bar with its sign-in control
    // and the navigation bar are present and a refused page is never a page
    // the operator cannot leave. `BaseScaffold` reads
    // `context.currentBeamLocation`, so it cannot be pumped bare.
    Widget host({
      required String path,
      required AsyncValue<AccessSession> session,
      AsyncValue<AccessRepository?>? repository,
    }) {
      // Two destinations: fewer and `NavigationBar` asserts, which would fail
      // these tests for a reason that has nothing to do with the gate.
      RouteRegistry().menuItems
        ..clear()
        ..addAll(const [
          MenuItem(label: 'Home', path: '/', icon: Icons.home),
          MenuItem(label: 'Packing', path: '/packing', icon: Icons.inventory),
        ]);

      final router = BeamerDelegate(
        locationBuilder: RoutesLocationBuilder(routes: {
          '*': (context, state, args) => BeamPage(
                key: ValueKey(path),
                child: PageAccessGate(
                  path: path,
                  title: 'Filleting',
                  child: const Text('the page itself'),
                ),
              ),
        }),
      );

      return ProviderScope(
        overrides: [
          accessSessionProvider.overrideWith(() => _FixedSession(session)),
          accessRepositoryProvider.overrideWith(
              (ref) async => (repository ?? _presentRepo).valueOrNull),
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

    testWidgets('an ordinary page renders its child with nothing added',
        (tester) async {
      await tester.pumpWidget(host(path: '/fillet', session: _session()));
      await tester.pumpAndSettle();

      expect(find.text('the page itself'), findsOneWidget);
      // Not wrapped in a scaffold of the gate's own: the page brings its own,
      // and a second one would double the app bar.
      expect(find.byType(PageNotAvailableBody), findsNothing);
      expect(find.byType(AccessLockedBody), findsNothing);
    });

    testWidgets('a whitelisted-out page shows the not-available body, and the '
        'page behind it is never built', (tester) async {
      await tester.pumpWidget(host(
        path: '/fillet',
        session: _session(pages: const {'/packing'}),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(kPageNotAvailableBodyKey), findsOneWidget);
      expect(find.text(kPageNotAvailableHeadline), findsOneWidget);
      expect(find.text('the page itself'), findsNothing,
          reason: 'a page must not run its initState, its queries or its OPC '
              'UA subscriptions behind a refusal');
      // Sign in is offered — a different account can carry a different
      // whitelist — but the headline does not promise it will help.
      expect(find.byKey(kPageNotAvailableSignInKey), findsOneWidget);
    });

    testWidgets('a group-refused page shows the group lock, not the '
        'not-available body', (tester) async {
      // The two refusals say different things. Getting them the wrong way
      // round tells somebody to sign in for a permission that is not what is
      // missing, or tells somebody with the wrong permission that the page
      // simply is not theirs.
      RouteRegistry().declareRouteGroup('/fillet', AccessGroup.configure);

      await tester.pumpWidget(host(path: '/fillet', session: _session()));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessLockedBodyKey), findsOneWidget);
      expect(find.text(kAccessLockedHeadline), findsOneWidget);
      expect(find.byKey(kPageNotAvailableBodyKey), findsNothing);
      expect(find.text('the page itself'), findsNothing);
    });

    testWidgets('a raised page is refused on a deep link — the closed hole',
        (tester) async {
      // This is the assertion the milestone is for. Reaching the path
      // directly, with no menu involved at all, must not open the page.
      RouteRegistry().declareRouteGroup('/fillet', AccessGroup.administer);

      await tester.pumpWidget(host(path: '/fillet', session: _session()));
      await tester.pumpAndSettle();

      expect(find.text('the page itself'), findsNothing);
    });

    testWidgets('a raised page waits rather than flashing its lock',
        (tester) async {
      RouteRegistry().declareRouteGroup('/fillet', AccessGroup.configure);

      await tester.pumpWidget(host(path: '/fillet', session: _loadingSession));
      await tester.pump();

      expect(find.byKey(kAccessGateWaitingKey), findsOneWidget);
      expect(find.text('the page itself'), findsNothing);
    });

    testWidgets('the not-available body names who is signed in', (tester) async {
      await tester.pumpWidget(host(
        path: '/fillet',
        session: _session(pages: const <String>{}, elevated: true),
      ));
      await tester.pumpAndSettle();

      expect(find.text(kPageNotAvailableRoleNote('Lina R', 'Line Lead')),
          findsOneWidget,
          reason: '"sign in" is confusing advice to somebody who already did');
    });
  });
}

/// A session that resolves to whatever the test needs, with none of the real
/// leaf providers constructed — so there is no I/O to settle against.
class _FixedSession extends AccessSessionController {
  _FixedSession(this._value);

  final AsyncValue<AccessSession> _value;

  @override
  Future<AccessSession> build() async {
    final value = _value;
    if (value is AsyncData<AccessSession>) return value.value;
    // Never completes: the loading state under test.
    return Completer<AccessSession>().future;
  }

  @override
  Future<AccessSignInResult> signIn(String username, String password) async =>
      AccessSignInResult.ok;

  @override
  Future<void> signOut() async {}

  @override
  void poke() {}
}

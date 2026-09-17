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
import 'package:tfc/core/access_authority.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/widgets/access_gate.dart';
import 'package:tfc/widgets/access_sign_in_dialog.dart';
import 'package:tfc/widgets/page_access_gate.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_repository.dart';

class _StubRepository extends Fake implements AccessRepository {}

/// The gate asks [AccessAuthority] — "can anything here verify a credential?"
/// — rather than "is there a repository?". The two answers coincide on a
/// direct station and part company on a gateway panel, which is the whole
/// reason the question was renamed; these three stand for the three states the
/// unit half exercises.
const _loadingAuthority = AsyncValue<AccessAuthority>.loading();
const _presentAuthority = AsyncValue<AccessAuthority>.data(AccessAuthority.local);
const _absentAuthority = AsyncValue<AccessAuthority>.data(AccessAuthority.none);

/// Still a repository, because the widget half drives the real
/// `accessAuthorityProvider`, which derives the authority from this one.
final _presentRepo = AsyncValue<AccessRepository?>.data(_StubRepository());

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
    test('an unraised page clears the group half before anything has resolved',
        () {
      // The operate short-circuit, asked on its own terms: the group half says
      // `allowed` with nothing resolved, which is what keeps a plant page off
      // the lock. What the *whole* function answers in that state is the
      // whitelist half's business — see 'the boot window waits' below.
      expect(
        resolveAccessGate(
          // No `path`: the group half does not take one. `resolvePageAccess`
          // is what turns a path into `allowWhenNobodyCanSignIn`, and asking
          // the group half "on its own terms" means handing it that answer
          // directly, which is what the `false` below is.
          group: AccessGroup.operate,
          authority: _loadingAuthority,
          session: _loadingSession,
          allowWhenNobodyCanSignIn: false,
        ),
        AccessGateState.allowed,
      );
    });

    test('a raised page waits rather than guessing while loading', () {
      expect(
        resolvePageAccess(
          group: AccessGroup.configure,
          path: '/fillet',
          authority: _loadingAuthority,
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
          authority: _presentAuthority,
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
          authority: _presentAuthority,
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
          authority: _absentAuthority,
          session: _session(),
        ),
        AccessGateState.allowed,
      );
      expect(
        resolvePageAccess(
          group: AccessGroup.configure,
          path: '/advanced/page-editor',
          authority: _absentAuthority,
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
          authority: _presentAuthority,
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
          authority: _presentAuthority,
          session: session,
        ),
        AccessGateState.allowed,
      );
      expect(
        resolvePageAccess(
          group: AccessGroup.operate,
          path: '/packing',
          authority: _presentAuthority,
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
          authority: _presentAuthority,
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
          authority: _presentAuthority,
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
            authority: _presentAuthority,
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
          authority: _presentAuthority,
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
          authority: _presentAuthority,
          session: session,
        ),
        AccessGateState.allowed,
      );
      expect(
        resolvePageAccess(
          group: AccessGroup.configure,
          path: '/advanced/page-editor',
          authority: _presentAuthority,
          session: session,
        ),
        AccessGateState.denied,
      );
    });

    test('the boot window waits rather than showing a page it may take back',
        () {
      // The regression this group exists for. This used to answer `allowed`,
      // resolving unfiltered on `kSessionWhileLoading` so that a slow database
      // never blanked a panel — and on a station that restricts what anonymous
      // may see, that rendered the home page in full for the second or two the
      // Postgres connect took and then replaced it with a refusal. Which page
      // this panel may show is not knowable until the session answers, and
      // `waiting` is the only honest answer to a question nobody has answered.
      expect(
        resolvePageAccess(
          group: AccessGroup.operate,
          path: '/fillet',
          authority: _loadingAuthority,
          session: _loadingSession,
        ),
        AccessGateState.waiting,
      );
    });

    test('a resolved repository does not end the wait on its own', () {
      // The session is the authority for the whitelist, and it resolves after
      // the repository does. Ending the wait here would reinstate the flash
      // with a shorter fuse.
      expect(
        resolvePageAccess(
          group: AccessGroup.operate,
          path: '/fillet',
          authority: _presentAuthority,
          session: _loadingSession,
        ),
        AccessGateState.waiting,
      );
    });

    test('an errored session resolves unfiltered, it does not wait forever',
        () {
      // A session that has failed will not un-fail on its own, so waiting on it
      // is waiting for good — a panel stuck on the sign-in screen with no way
      // off it. `kSessionWhileLoading` carries no whitelist, so the page opens
      // and the write guards go on refusing whatever is on it.
      expect(
        resolvePageAccess(
          group: AccessGroup.operate,
          path: '/fillet',
          authority: _presentAuthority,
          session: AsyncValue<AccessSession>.error('no', StackTrace.empty),
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
      AccessSessionController? controller,
      AccessSignInOpener? openSignIn,
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
                  openSignIn: openSignIn ?? showAccessSignInDialog,
                  child: const Text('the page itself'),
                ),
              ),
        }),
      );

      return ProviderScope(
        overrides: [
          accessSessionProvider
              .overrideWith(() => controller ?? _FixedSession(session)),
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

    testWidgets(
        'the boot window shows the sign-in body, and the page behind it is '
        'never built', (tester) async {
      // The reported fault, at the widget: on a station whose anonymous
      // account may see no page, opening the app showed the home page for the
      // one to two seconds the Postgres connect took and then took it away.
      // The page must not be built at all in that window — it would run its
      // `initState`, its queries and its OPC UA subscriptions for a page the
      // panel is about to refuse.
      await tester.pumpWidget(host(path: '/fillet', session: _loadingSession));
      await tester.pump();

      expect(find.byKey(kAccessCheckingBodyKey), findsOneWidget);
      expect(find.text(kAccessCheckingHeadline), findsOneWidget);
      expect(find.byKey(kAccessCheckingSignInKey), findsOneWidget);
      expect(find.text('the page itself'), findsNothing,
          reason: 'the flash was the page being built and then withdrawn');
      // Neither refusal: nothing has been refused and naming a cause here
      // would be a guess.
      expect(find.byKey(kPageNotAvailableBodyKey), findsNothing);
      expect(find.byKey(kAccessLockedBodyKey), findsNothing);
    });

    testWidgets('a restricted station never shows the page it is about to '
        'refuse', (tester) async {
      // The whole transition, in one test: loading -> resolved-with-an-empty
      // whitelist. The page must not appear at any point between them.
      //
      // The refusal it lands on is the SIGN-IN-FIRST one, not "not available",
      // and that is the distinction [anonymousSeesNothing] draws: nobody is
      // signed in and no page was granted, so the useful first sentence is the
      // sign-in rather than an explanation of a whitelist the operator cannot
      // see. The case below is the same transition for somebody who IS signed
      // in, where "not available" is the honest voice. What both arms assert
      // is the same property the name states: the page never appears.
      final controller = _SwitchableSession(_loadingSession);
      await tester.pumpWidget(host(
        path: '/fillet',
        session: _loadingSession,
        controller: controller,
      ));
      await tester.pump();
      expect(find.byKey(kAccessCheckingBodyKey), findsOneWidget);
      expect(find.text('the page itself'), findsNothing);

      controller.resolve(_session(pages: const <String>{}).requireValue);
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessSignInFirstBodyKey), findsOneWidget);
      expect(find.byKey(kPageNotAvailableBodyKey), findsNothing);
      expect(find.text('the page itself'), findsNothing);
    });

    testWidgets('a signed-in account outside the whitelist gets the '
        'not-available refusal, and still never the page', (tester) async {
      // The other voice of the same refusal. An account somebody signed in to
      // has a whitelist that simply does not carry this page, and telling that
      // person to sign in would send them hunting for a credential that
      // changes nothing.
      final controller = _SwitchableSession(_loadingSession);
      await tester.pumpWidget(host(
        path: '/fillet',
        session: _loadingSession,
        controller: controller,
      ));
      await tester.pump();
      expect(find.text('the page itself'), findsNothing);

      controller.resolve(
          _session(pages: const <String>{'/other'}, elevated: true)
              .requireValue);
      await tester.pumpAndSettle();

      expect(find.byKey(kPageNotAvailableBodyKey), findsOneWidget);
      expect(find.byKey(kAccessSignInFirstBodyKey), findsNothing);
      expect(find.text('the page itself'), findsNothing);
    });

    testWidgets('the sign-in offered while checking calls the injected opener',
        (tester) async {
      // Offered, not decorative: this screen is what a restricted panel boots
      // on, and the button on it is the one thing that changes the outcome.
      var taps = 0;
      await tester.pumpWidget(host(
        path: '/fillet',
        session: _loadingSession,
        openSignIn: (context, ref) async {
          taps++;
        },
      ));
      await tester.pump();

      await tester.tap(find.byKey(kAccessCheckingSignInKey));
      await tester.pump();

      expect(taps, 1);
    });

    testWidgets('nobody signed in and nothing shown to nobody: the sign-in '
        'leads', (tester) async {
      // The browser's first frame, and a walk-up station whose `anonymous`
      // row lists no pages. "This page is not available" is written for a
      // page somebody was not given; here no page was given to anyone, and
      // the honest first sentence is the one act that changes it.
      await tester.pumpWidget(host(
        path: '/fillet',
        session: _session(groups: const {}, pages: const <String>{}),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessSignInFirstBodyKey), findsOneWidget);
      expect(find.text(kAccessSignInFirstHeadline), findsOneWidget);
      expect(find.byKey(kAccessSignInFirstSignInKey), findsOneWidget);
      expect(find.byKey(kPageNotAvailableBodyKey), findsNothing);
      expect(find.byKey(kAccessLockedBodyKey), findsNothing);
      expect(find.text('the page itself'), findsNothing,
          reason: 'a different first sentence, the same refusal: the page '
              'behind it is still never built');
    });

    testWidgets('the sign-in-first body calls the injected opener',
        (tester) async {
      var opened = 0;
      await tester.pumpWidget(host(
        path: '/fillet',
        session: _session(groups: const {}, pages: const <String>{}),
        openSignIn: (context, ref) async {
          opened++;
        },
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAccessSignInFirstSignInKey));
      await tester.pump();
      expect(opened, 1);
    });

    test('anonymousSeesNothing is exactly anonymous with an empty whitelist',
        () {
      AccessSession session({Set<String>? pages, bool elevated = false}) =>
          _session(pages: pages, elevated: elevated).requireValue;
      expect(anonymousSeesNothing(session(pages: const <String>{})), isTrue);
      expect(anonymousSeesNothing(session(pages: null)), isFalse,
          reason: 'no whitelist admits every page — there is nothing to '
              'lead with a sign-in about');
      expect(anonymousSeesNothing(session(pages: const {'/packing'})), isFalse,
          reason: 'some pages were given; a page outside them is not '
              'available, which is the other body\'s sentence');
      expect(
          anonymousSeesNothing(
              session(pages: const <String>{}, elevated: true)),
          isFalse,
          reason: 'somebody DID sign in; telling them to is the confusion '
              'kPageNotAvailableRoleNote exists to avoid');
      expect(anonymousSeesNothing(null), isFalse);
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

/// A session that starts loading and is resolved by the test, so the boot
/// window and the frame after it can be asserted as one transition — which is
/// the shape of the fault, and which neither state can show on its own.
class _SwitchableSession extends AccessSessionController {
  _SwitchableSession(this._initial);

  final AsyncValue<AccessSession> _initial;
  final Completer<AccessSession> _resolved = Completer<AccessSession>();

  void resolve(AccessSession session) => _resolved.complete(session);

  @override
  Future<AccessSession> build() async {
    final value = _initial;
    if (value is AsyncData<AccessSession>) return value.value;
    return _resolved.future;
  }

  @override
  Future<AccessSignInResult> signIn(String username, String password) async =>
      AccessSignInResult.ok;

  @override
  Future<void> signOut() async {}

  @override
  void poke() {}
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

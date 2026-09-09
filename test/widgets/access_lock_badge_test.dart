/// The menu lock: when it appears, when it costs nothing, and that it never
/// disagrees with the route it points at.
///
/// Two claims carry the file. The first is that an unlocked entry is laid out
/// exactly as it was before this phase — asserted by measuring
/// `Size.zero`, never by `findsNothing` on the icon, because an invisible
/// widget that still takes 8 px of gap would pass the second and fail the
/// first. The second is that the badge and the gate cannot drift: the badge
/// calls `resolveAccessGate` and `routeAllowedWhenNobodyCanSignIn`
/// rather than keeping its own copy of "locked when…", so the repository
/// cases here are the same truth table plan 02-02 pinned, re-asserted through
/// a widget.
///
/// **Both access providers are overridden in every test.** An unoverridden
/// `accessAuthorityProvider` reaches `gatewayConfigProvider` and
/// `databaseProvider`, which read the device-local store,
/// `DatabaseConfig.fromPrefs()` and the station keychain; the test would
/// become a race against real I/O.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/access_routes.dart';
import 'package:tfc/core/access_authority.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/gateway_link.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/widgets/access_lock_badge.dart';
import 'package:tfc_access/tfc_access.dart';

/// Counts how many times each provider was actually built. Riverpod builds
/// lazily, so a zero here is proof the badge never watched it.
int _authorityBuilds = 0;
int _sessionBuilds = 0;

/// A session that resolves immediately to whatever the test needs, without
/// constructing the real controller chain (database, preferences, audit sink,
/// inactivity monitor). Copied from `test/widgets/access_golden_test.dart`.
class _FixedSession extends AccessSessionController {
  _FixedSession(this._session);

  final AccessSession _session;

  @override
  Future<AccessSession> build() async {
    _sessionBuilds++;
    return _session;
  }

  @override
  Future<AccessSignInResult> signIn(String username, String password) async =>
      AccessSignInResult.ok;

  @override
  Future<void> signOut() async {}

  @override
  void poke() {}
}

/// A session a test can move from lacking the group to holding it, without
/// re-pumping the tree — the same idiom as `access_gate_test.dart`, because
/// "the lock disappears when you sign in" is a claim about a rebuild, not
/// about a fresh mount.
class _MutableSession extends AccessSessionController {
  _MutableSession(this._initial);

  final AccessSession _initial;

  @override
  Future<AccessSession> build() async {
    _sessionBuilds++;
    return _initial;
  }

  void become(AccessSession next) => state = AsyncData(next);

  @override
  Future<AccessSignInResult> signIn(String username, String password) async =>
      AccessSignInResult.ok;

  @override
  Future<void> signOut() async {}

  @override
  void poke() {}
}

/// A session that never resolves — the boot window.
class _HangingSession extends AccessSessionController {
  @override
  Future<AccessSession> build() {
    _sessionBuilds++;
    return Completer<AccessSession>().future;
  }

  @override
  Future<AccessSignInResult> signIn(String username, String password) async =>
      AccessSignInResult.unavailable;

  @override
  Future<void> signOut() async {}

  @override
  void poke() {}
}

/// The authority states a widget test can be in. A resolved
/// [AccessAuthority.none] and a thrown one are the two causes of "this station
/// can authenticate nobody" that must produce identical badges.
Future<AccessAuthority> _presentRepository() async {
  _authorityBuilds++;
  return AccessAuthority.local;
}

Future<AccessAuthority> _absentRepository() async {
  _authorityBuilds++;
  return AccessAuthority.none;
}

/// A gateway panel: no repository by design, the credential verified over the
/// socket, so the session — not the missing database — decides the lock.
Future<AccessAuthority> _relayAuthority() async {
  _authorityBuilds++;
  return AccessAuthority.relay;
}

Future<AccessAuthority> _throwingRepository() async {
  _authorityBuilds++;
  throw StateError('postgres will not answer');
}

/// An authority that never resolves — the station still connecting.
Future<AccessAuthority> _hangingRepository() {
  _authorityBuilds++;
  return Completer<AccessAuthority>().future;
}

AccessSession _anonymous() =>
    AccessSession.anonymous(const {AccessGroup.operate});

AccessSession _holding(Set<AccessGroup> groups) => AccessSession(
      user: const AuthenticatedUser(
        username: 'jon',
        roleName: 'Engineering',
        displayName: 'Jon B',
      ),
      groups: groups,
      expiresAt: DateTime.utc(2026, 8, 29, 12),
    );

/// The badge in a `Row`, which is where it lives in the real menu: children of
/// a `Row` get unbounded width, so a badge with nothing to show measures
/// exactly `Size.zero` and one with a lock measures its glyph plus its own
/// gap.
Widget _host({
  required String? path,
  AccessSession? session,
  bool hangingSession = false,
  Future<AccessAuthority> Function() repository = _presentRepository,
  bool? relayCanAuthenticate,
}) {
  return ProviderScope(
    overrides: [
      accessSessionProvider.overrideWith(() => hangingSession
          ? _HangingSession()
          : _FixedSession(session ?? _anonymous())),
      accessAuthorityProvider.overrideWith((ref) => repository()),
      if (relayCanAuthenticate != null)
        relayCanAuthenticateProvider
            .overrideWith((ref) => relayCanAuthenticate),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.home, size: 20),
            const SizedBox(width: 12),
            const Flexible(child: Text('Page label')),
            AccessLockBadge(path: path),
          ],
        ),
      ),
    ),
  );
}

Size _badgeSize(WidgetTester tester) =>
    tester.getSize(find.byType(AccessLockBadge));

Finder get _lockGlyph => find.descendant(
      of: find.byType(AccessLockBadge),
      matching: find.byIcon(Icons.lock_outline),
    );

/// A `configure` route — one of the five that stay locked in every repository
/// state.
const String _kConfigureRoute = '/advanced/page-editor';

/// A route this build does not raise. Every ordinary page entry is one of
/// these, which is what makes the short-circuit worth having.
const String _kUnraisedRoute = '/dashboard';

void main() {
  setUp(() {
    _authorityBuilds = 0;
    _sessionBuilds = 0;
    RouteRegistry().clearRouteGroups();
    installRaisedRoutes();
  });

  tearDown(() {
    RouteRegistry().clearRouteGroups();
  });

  group('an entry the operator can open costs nothing', () {
    testWidgets('an unraised route renders zero width', (tester) async {
      await tester.pumpWidget(_host(path: _kUnraisedRoute));
      await tester.pumpAndSettle();

      expect(_badgeSize(tester), Size.zero,
          reason: 'an unraised menu row must lay out exactly as it did '
              'before this phase — no glyph and no gap');
      expect(_lockGlyph, findsNothing);
    });

    testWidgets('an unraised route never reads the session or the repository',
        (tester) async {
      await tester.pumpWidget(_host(path: _kUnraisedRoute));
      await tester.pumpAndSettle();

      expect(_sessionBuilds, 0,
          reason: 'the hundreds of ordinary entries must not each subscribe '
              'to the session');
      expect(_authorityBuilds, 0,
          reason: 'a build that raises nothing must render its menu without '
              'ever touching the database or the keychain');
    });

    testWidgets('a null path renders zero width', (tester) async {
      await tester.pumpWidget(_host(path: null));
      await tester.pumpAndSettle();

      expect(_badgeSize(tester), Size.zero);
      expect(_sessionBuilds, 0);
      expect(_authorityBuilds, 0);
    });

    testWidgets('a raised route the session holds renders zero width',
        (tester) async {
      await tester.pumpWidget(_host(
        path: _kConfigureRoute,
        session: _holding(const {AccessGroup.operate, AccessGroup.configure}),
      ));
      await tester.pumpAndSettle();

      expect(_badgeSize(tester), Size.zero);
      expect(_lockGlyph, findsNothing);
    });
  });

  group('an entry the operator cannot open shows a lock', () {
    testWidgets('a raised route an anonymous session cannot open',
        (tester) async {
      await tester.pumpWidget(_host(path: _kConfigureRoute));
      await tester.pumpAndSettle();

      expect(_lockGlyph, findsOneWidget);
      expect(_badgeSize(tester).width, greaterThan(0));
    });

    testWidgets('a signed-in session without the group still sees the lock',
        (tester) async {
      await tester.pumpWidget(_host(
        path: _kConfigureRoute,
        session: _holding(const {AccessGroup.operate, AccessGroup.setpoints}),
      ));
      await tester.pumpAndSettle();

      expect(_lockGlyph, findsOneWidget);
    });

    testWidgets('the lock is drawn in onSurfaceVariant, never a state colour',
        (tester) async {
      await tester.pumpWidget(_host(path: _kConfigureRoute));
      await tester.pumpAndSettle();

      final icon = tester.widget<Icon>(_lockGlyph);
      final context = tester.element(find.byType(AccessLockBadge));
      expect(icon.color, Theme.of(context).colorScheme.onSurfaceVariant,
          reason: 'orange means forced/override and, since plan 01-08, an '
              'elevated session; red means fault. A lock is neither');
      expect(icon.size, 16);
    });

    testWidgets('the semantics label names the missing group', (tester) async {
      // Disposed at the end of the body, not in a tearDown: the framework
      // verifies handles before tearDowns run.
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(_host(path: _kConfigureRoute));
      await tester.pumpAndSettle();

      final semantics = tester.widget<Semantics>(
        find
            .descendant(
              of: find.byType(AccessLockBadge),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(semantics.properties.label, isNotNull);
      expect(semantics.properties.label, contains('configure'),
          reason: 'the lock must not be glyph-only — a screen reader has to '
              'be told which permission is missing');
      expect(find.bySemanticsLabel(RegExp('configure')), findsOneWidget);

      handle.dispose();
    });
  });

  group('nothing renders while a dependency is still resolving', () {
    testWidgets('a repository that has not answered yet renders zero width',
        (tester) async {
      await tester.pumpWidget(
          _host(path: _kConfigureRoute, repository: _hangingRepository));
      await tester.pump();

      expect(_badgeSize(tester), Size.zero,
          reason: 'a lock that appears a frame late beats one that flashes on '
              'every menu open');
      expect(_lockGlyph, findsNothing);
    });

    testWidgets('a session that has not answered yet renders zero width',
        (tester) async {
      await tester.pumpWidget(_host(
        path: _kConfigureRoute,
        hangingSession: true,
      ));
      await tester.pump();
      await tester.pump();

      expect(_badgeSize(tester), Size.zero);
      expect(_lockGlyph, findsNothing);
    });
  });

  group('an unavailable repository: the amendment, through the badge', () {
    testWidgets('Server Config shows no lock when the repository is null',
        (tester) async {
      await tester.pumpWidget(
          _host(path: kServerConfigRoute, repository: _absentRepository));
      await tester.pumpAndSettle();

      expect(_badgeSize(tester), Size.zero,
          reason: 'the page that configures the database must not be locked '
              'by the database being unconfigured');
      expect(_lockGlyph, findsNothing);
    });

    testWidgets('Server Config shows no lock when the repository errors',
        (tester) async {
      await tester.pumpWidget(
          _host(path: kServerConfigRoute, repository: _throwingRepository));
      await tester.pumpAndSettle();

      expect(_badgeSize(tester), Size.zero,
          reason: 'a mistyped Postgres IP must not turn into an on-site '
              'recovery');
      expect(_lockGlyph, findsNothing);
    });

    testWidgets('a configure route shows a lock when the repository is null',
        (tester) async {
      await tester.pumpWidget(
          _host(path: _kConfigureRoute, repository: _absentRepository));
      await tester.pumpAndSettle();

      expect(_lockGlyph, findsOneWidget);
    });

    testWidgets('a configure route shows a lock when the repository errors',
        (tester) async {
      await tester.pumpWidget(
          _host(path: _kConfigureRoute, repository: _throwingRepository));
      await tester.pumpAndSettle();

      expect(_lockGlyph, findsOneWidget);
    });

    testWidgets(
        'a gateway panel locks a configure route while anonymous and unlocks '
        'it for a session holding the group', (tester) async {
      // The panel has no repository and never will. Before the authority
      // existed both of these rendered a lock — and the menu, which hides what
      // the badge locks, dropped the entry entirely.
      await tester.pumpWidget(_host(
        path: _kConfigureRoute,
        repository: _relayAuthority,
      ));
      await tester.pumpAndSettle();
      expect(_lockGlyph, findsOneWidget,
          reason: 'nobody is signed in yet, on any transport');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(_host(
        path: _kConfigureRoute,
        repository: _relayAuthority,
        session: _holding(const {AccessGroup.operate, AccessGroup.configure}),
      ));
      await tester.pumpAndSettle();

      expect(_badgeSize(tester), Size.zero);
      expect(_lockGlyph, findsNothing,
          reason: 'the gateway verified this session; the missing database is '
              'not a reason to lock the page');
    });

    testWidgets(
        'Server Config wears a lock on a healthy gateway panel, and the gate '
        'agrees', (tester) async {
      // The badge and the route gate share both halves of the exemption: the
      // path predicate and `relayCanAuthenticateProvider`. A badge that kept
      // its own copy of either is how a lock ends up on a page that opens.
      await tester.pumpWidget(_host(
        path: kServerConfigRoute,
        repository: _relayAuthority,
        relayCanAuthenticate: true,
      ));
      await tester.pumpAndSettle();

      expect(_lockGlyph, findsOneWidget,
          reason: 'a gateway panel has no repository by design; that must no '
              'longer read as a database outage');
    });

    testWidgets(
        'Server Config loses its lock when the gateway link cannot carry a '
        'sign-in', (tester) async {
      await tester.pumpWidget(_host(
        path: kServerConfigRoute,
        repository: _relayAuthority,
        relayCanAuthenticate: false,
      ));
      await tester.pumpAndSettle();

      expect(_badgeSize(tester), Size.zero);
      expect(_lockGlyph, findsNothing,
          reason: 'the page that fixes a mistyped gateway URL must not wear a '
              'lock the operator cannot pass');
    });

    testWidgets(
        'an unreachable gateway link unlocks Server Config and nothing else',
        (tester) async {
      for (final path in kRaisedRoutes.keys) {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(_host(
          path: path,
          repository: _relayAuthority,
          relayCanAuthenticate: false,
        ));
        await tester.pumpAndSettle();

        expect(
          _lockGlyph,
          path == kServerConfigRoute ? findsNothing : findsOneWidget,
          reason: path,
        );
      }
    });

    testWidgets('the two causes of unavailable give the same badge, per route',
        (tester) async {
      // Compared as measurements rather than against an expected value, so a
      // future divergence between the two causes fails here first.
      final sizes = <String, List<Size>>{};
      for (final path in kRaisedRoutes.keys) {
        for (final repository in [_absentRepository, _throwingRepository]) {
          await tester.pumpWidget(_host(path: path, repository: repository));
          await tester.pumpAndSettle();
          (sizes[path] ??= <Size>[]).add(_badgeSize(tester));
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }

      for (final entry in sizes.entries) {
        expect(entry.value[0], entry.value[1],
            reason: '${entry.key}: a resolved-null repository and an errored '
                'one are the same fact and must render the same badge');
      }
      expect(sizes[kServerConfigRoute]!.first, Size.zero);
      for (final path
          in kRaisedRoutes.keys.where((p) => p != kServerConfigRoute)) {
        expect(sizes[path]!.first.width, greaterThan(0),
            reason: '$path stays locked while the repository is unavailable');
      }
    });

    testWidgets('the exemption goes inert once a repository exists',
        (tester) async {
      await tester.pumpWidget(
          _host(path: kServerConfigRoute, repository: _presentRepository));
      await tester.pumpAndSettle();

      expect(_lockGlyph, findsOneWidget,
          reason: 'Server Config is exempt from the outage, not from the '
              'permission');
    });
  });

  group('the badge follows the session', () {
    testWidgets('every raised route locks for an anonymous session',
        (tester) async {
      for (final path in kRaisedRoutes.keys) {
        await tester.pumpWidget(_host(path: path));
        await tester.pumpAndSettle();
        expect(_lockGlyph, findsOneWidget, reason: '$path must show a lock');
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });

    testWidgets('no raised route locks for a session holding everything',
        (tester) async {
      final all = AccessGroup.values.toSet();
      for (final path in kRaisedRoutes.keys) {
        await tester.pumpWidget(_host(path: path, session: _holding(all)));
        await tester.pumpAndSettle();
        expect(_badgeSize(tester), Size.zero, reason: '$path must be open');
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });

    testWidgets('signing in makes the lock disappear without a remount',
        (tester) async {
      // The session provider is the only thing that changes; the widget tree
      // is pumped once and the same element rebuilds, which is what "without
      // reopening the menu twice" means in a test.
      final session = _MutableSession(_anonymous());
      await tester.pumpWidget(ProviderScope(
        overrides: [
          accessSessionProvider.overrideWith(() => session),
          accessAuthorityProvider.overrideWith((ref) => _presentRepository()),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: Row(children: [AccessLockBadge(path: _kConfigureRoute)]),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(_lockGlyph, findsOneWidget);

      session.become(
          _holding(const {AccessGroup.operate, AccessGroup.configure}));
      await tester.pumpAndSettle();

      expect(_badgeSize(tester), Size.zero,
          reason: 'signing in must unlock the entry in place');
    });
  });
}

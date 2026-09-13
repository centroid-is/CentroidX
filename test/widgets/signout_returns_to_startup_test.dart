/// Signing out returns the panel to its startup page.
///
/// An operator signs in, walks into a raised page — Server Config, the page
/// editor — and signs out, or the inactivity monitor does it for them. Before
/// this behaviour the screen stayed where it was: an anonymous session
/// looking at a page it cannot open from the menu, one tap away from a
/// denial prompt. The kiosk answer is the boot answer — beam to the same
/// startup URL the station opens on, resolved and validated the same way.
///
/// Both sign-out paths — the app-bar button and the inactivity expiry — are
/// one transition from here: the session goes from elevated to not. The
/// listener watches the transition, not the button, so both are this test.
///
/// Written RED first, against a scaffold that did not beam.
library;

import 'package:beamer/beamer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/startup_url.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/alarm.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/widgets/base_scaffold.dart';
import 'package:tfc_access/tfc_access.dart';

import '../helpers/page_editor_harness.dart' show FakeEditorPreferences;
import 'alarm_fixture.dart';

/// A session the test moves by hand. `become` is the sign-out and the
/// inactivity expiry alike: both end at `state = AsyncData(anonymous)`.
class _DrivenSession extends AccessSessionController {
  _DrivenSession(this._initial);

  final AccessSession _initial;

  @override
  Future<AccessSession> build() async => _initial;

  void become(AccessSession session) => state = AsyncData(session);

  @override
  Future<AccessSignInResult> signIn(String username, String password) async =>
      AccessSignInResult.ok;

  @override
  Future<void> signOut() async {}

  @override
  void poke() {}
}

AccessSession _anonymous() =>
    AccessSession.anonymous(const {AccessGroup.operate});

AccessSession _engineer() => AccessSession(
      user: const AuthenticatedUser(
        username: 'gudrun',
        roleName: 'Engineering',
        displayName: 'Guðrún',
      ),
      groups: const {AccessGroup.operate, AccessGroup.administer},
      expiresAt: DateTime.utc(2030),
    );

void _registerMenu() {
  final registry = RouteRegistry();
  registry.menuItems.clear();
  registry
      .addMenuItem(const MenuItem(label: 'Home', path: '/', icon: Icons.home));
  registry.addMenuItem(
      const MenuItem(label: 'Machines', path: '/machines', icon: Icons.build));
  registry.addMenuItem(const MenuItem(
    label: 'Advanced',
    path: '/advanced',
    icon: Icons.settings,
    children: [
      MenuItem(
          label: 'Server Config',
          path: '/advanced/server-config',
          icon: Icons.dns),
    ],
  ));
}

BeamPage _page(String path, String title, String body) => BeamPage(
      key: ValueKey(path),
      title: title,
      child: BaseScaffold(title: title, body: Text(body)),
    );

({Widget app, BeamerDelegate delegate}) _shell({
  required _DrivenSession session,
  required FakeEditorPreferences prefs,
  String initialPath = '/advanced/server-config',
}) {
  final delegate = BeamerDelegate(
    initialPath: initialPath,
    locationBuilder: RoutesLocationBuilder(routes: {
      '/': (context, state, data) => _page('/', 'Home', 'home-body'),
      '/machines': (context, state, data) =>
          _page('/machines', 'Machines', 'machines-body'),
      '/advanced/server-config': (context, state, data) => _page(
          '/advanced/server-config', 'Server Config', 'server-config-body'),
    }).call,
  );
  final app = ProviderScope(
    overrides: [
      alarmManProvider.overrideWith((ref) async => AlarmFixture()),
      accessSessionProvider.overrideWith(() => session),
      localPreferencesProvider.overrideWithValue(prefs),
    ],
    child: BeamerProvider(
      routerDelegate: delegate,
      child: MaterialApp.router(
        routerDelegate: delegate,
        routeInformationParser: BeamerParser(),
      ),
    ),
  );
  return (app: app, delegate: delegate);
}

void main() {
  setUp(_registerMenu);

  testWidgets('signing out beams from a raised page to the startup default',
      (tester) async {
    final session = _DrivenSession(_engineer());
    final shell = _shell(session: session, prefs: FakeEditorPreferences());

    await tester.pumpWidget(shell.app);
    await tester.pumpAndSettle();
    expect(find.text('server-config-body'), findsOneWidget);

    session.become(_anonymous());
    await tester.pumpAndSettle();

    expect(find.text('home-body'), findsOneWidget,
        reason: 'an anonymous session must not be left staring at a page it '
            'cannot reach from its own menu');
    expect(find.text('server-config-body'), findsNothing);
  });

  testWidgets('the chosen startup URL wins over the default', (tester) async {
    final prefs = FakeEditorPreferences();
    await writeStartupUrl(prefs, '/machines');
    final session = _DrivenSession(_engineer());
    final shell = _shell(session: session, prefs: prefs);

    await tester.pumpWidget(shell.app);
    await tester.pumpAndSettle();

    session.become(_anonymous());
    await tester.pumpAndSettle();

    expect(find.text('machines-body'), findsOneWidget,
        reason: 'sign-out lands where boot lands: the per-station choice');
  });

  testWidgets('a stored URL that is no longer routable falls back to /',
      (tester) async {
    final prefs = FakeEditorPreferences();
    await prefs.setString(startupUrlPrefsKey, '/deleted-page');
    final session = _DrivenSession(_engineer());
    final shell = _shell(session: session, prefs: prefs);

    await tester.pumpWidget(shell.app);
    await tester.pumpAndSettle();

    session.become(_anonymous());
    await tester.pumpAndSettle();

    expect(find.text('home-body'), findsOneWidget,
        reason: 'the same resolveStartupPath validation the boot path runs — '
            'a deleted startup page must not beam into a not-found screen');
  });

  testWidgets('already on the startup page: signing out does not re-beam',
      (tester) async {
    final session = _DrivenSession(_engineer());
    final shell = _shell(
        session: session, prefs: FakeEditorPreferences(), initialPath: '/');

    await tester.pumpWidget(shell.app);
    await tester.pumpAndSettle();
    final historyBefore = shell.delegate.beamingHistory.length;

    session.become(_anonymous());
    await tester.pumpAndSettle();

    expect(find.text('home-body'), findsOneWidget);
    expect(shell.delegate.beamingHistory.length, historyBefore,
        reason: 'beaming to the page already showing would only grow the '
            'back-stack the top-level clearing exists to keep empty');
  });

  group('a committed panel taking itself back', () {
    AccessSession panel() => AccessSession(
          user: const AuthenticatedUser(
            username: 'panel_a',
            roleName: kOperatorRoleName,
            stationAccount: true,
          ),
          groups: const {AccessGroup.operate},
        );

    testWidgets('a person falling to the panel account beams to startup',
        (tester) async {
      // Still elevated, so the elevated-to-anonymous rule alone misses it —
      // and the page the person raised is one the panel's account may not be
      // able to see.
      final session = _DrivenSession(_engineer());
      final shell = _shell(session: session, prefs: FakeEditorPreferences());

      await tester.pumpWidget(shell.app);
      await tester.pumpAndSettle();
      expect(find.text('server-config-body'), findsOneWidget);

      session.become(panel());
      await tester.pumpAndSettle();

      expect(find.text('home-body'), findsOneWidget);
    });

    testWidgets('the panel resuming from anonymous moves nothing',
        (tester) async {
      final session = _DrivenSession(_anonymous());
      final shell = _shell(session: session, prefs: FakeEditorPreferences());

      await tester.pumpWidget(shell.app);
      await tester.pumpAndSettle();

      session.become(panel());
      await tester.pumpAndSettle();

      expect(find.text('server-config-body'), findsOneWidget,
          reason: 'nobody was signed in, so no session ended');
    });

    testWidgets('the panel re-resolving in place moves nothing',
        (tester) async {
      final session = _DrivenSession(panel());
      final shell = _shell(session: session, prefs: FakeEditorPreferences());

      await tester.pumpWidget(shell.app);
      await tester.pumpAndSettle();

      session.become(AccessSession(
        user: const AuthenticatedUser(
          username: 'panel_a',
          roleName: 'Shift Leader',
          stationAccount: true,
        ),
        groups: const {AccessGroup.operate, AccessGroup.setpoints},
      ));
      await tester.pumpAndSettle();

      expect(find.text('server-config-body'), findsOneWidget,
          reason: 'an administrator editing the panel\'s role is not the '
              'panel ending');
    });

    testWidgets('a person switching to another person moves nothing',
        (tester) async {
      final session = _DrivenSession(_engineer());
      final shell = _shell(session: session, prefs: FakeEditorPreferences());

      await tester.pumpWidget(shell.app);
      await tester.pumpAndSettle();

      session.become(AccessSession(
        user: const AuthenticatedUser(username: 'anna', roleName: 'Engineering'),
        groups: const {AccessGroup.operate, AccessGroup.administer},
        expiresAt: DateTime.utc(2030),
      ));
      await tester.pumpAndSettle();

      expect(find.text('server-config-body'), findsOneWidget);
    });
  });

  testWidgets('signing IN moves nothing', (tester) async {
    final session = _DrivenSession(_anonymous());
    final shell = _shell(session: session, prefs: FakeEditorPreferences());

    await tester.pumpWidget(shell.app);
    await tester.pumpAndSettle();
    expect(find.text('server-config-body'), findsOneWidget);

    session.become(_engineer());
    await tester.pumpAndSettle();

    expect(find.text('server-config-body'), findsOneWidget,
        reason: 'elevation opens doors, it does not walk through any');
  });
}

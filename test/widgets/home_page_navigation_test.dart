/// A panel moves to a session's home page on its own at three moments: boot,
/// a session ending, and somebody signing in from the app bar.
///
/// Home pages are per account (`app_user.home_page`). The reserved anonymous
/// account's is where a logged-out panel opens; a station account's is where
/// its panel opens. These tests hand the pages in through
/// `homePageLookupProvider`, so no database is involved.
///
/// Sign-out and the inactivity expiry are one transition from here: the
/// session goes from elevated to not. The listener watches the transition,
/// not the button, so both are the sign-out tests.
library;

import 'package:beamer/beamer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/alarm.dart';
import 'package:tfc/providers/home_page.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/widgets/access_sign_in_dialog.dart';
import 'package:tfc/widgets/base_scaffold.dart';
import 'package:tfc_access/tfc_access.dart';

import '../helpers/page_editor_harness.dart' show FakeEditorPreferences;
import 'alarm_fixture.dart';

/// A session the test moves by hand. `become` is the sign-out and the
/// inactivity expiry alike: both end at `state = AsyncData(anonymous)`.
class _DrivenSession extends AccessSessionController {
  _DrivenSession(this._initial, {this.signsInAs});

  final AccessSession _initial;

  /// What a successful sign-in turns the session into.
  final AccessSession? signsInAs;

  @override
  Future<AccessSession> build() async => _initial;

  void become(AccessSession session) => state = AsyncData(session);

  @override
  Future<AccessSignInResult> signIn(String username, String password) async {
    become(signsInAs!);
    return AccessSignInResult.ok;
  }

  @override
  Future<String?> panelAccount() async => null;

  @override
  Future<void> signOut() async {}

  @override
  void poke() {}
}

/// Home pages by username, `anonymous` for the logged-out panel. An account
/// missing from the map has none. [known] false answers as an unreachable
/// database.
class _Pages {
  _Pages([Map<String, String> pages = const {}]) : pages = {...pages};

  final Map<String, String> pages;
  bool known = true;
  int lookups = 0;

  Future<HomePageAnswer> lookup(AccessSession session) async {
    lookups++;
    if (!known) return (known: false, page: null);
    return (
      known: true,
      page: pages[session.user?.username ?? kAnonymousUsername],
    );
  }
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

AccessSession _panel() => AccessSession(
      user: const AuthenticatedUser(
        username: 'panel_a',
        roleName: kOperatorRoleName,
        stationAccount: true,
      ),
      groups: const {AccessGroup.operate},
    );

void _registerMenu() {
  final registry = RouteRegistry();
  registry.menuItems.clear();
  registry
      .addMenuItem(const MenuItem(label: 'Home', path: '/', icon: Icons.home));
  registry.addMenuItem(
      const MenuItem(label: 'Machines', path: '/machines', icon: Icons.build));
  registry.addMenuItem(
      const MenuItem(label: 'Freezer', path: '/freezer', icon: Icons.ac_unit));
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

({Widget app, BeamerDelegate delegate, BootHomePageDebt debt}) _shell({
  required _DrivenSession session,
  _Pages? pages,
  String initialPath = '/advanced/server-config',
  BootHomePageDebt? debt,
}) {
  final lookup = pages ?? _Pages();
  // Every sign-out test starts on a raised page somebody navigated to, so the
  // boot navigation is already behind it unless a test says otherwise.
  final bootDebt = debt ?? BootHomePageDebt(owed: false);
  final delegate = BeamerDelegate(
    initialPath: initialPath,
    locationBuilder: RoutesLocationBuilder(routes: {
      '/': (context, state, data) => _page('/', 'Home', 'home-body'),
      '/machines': (context, state, data) =>
          _page('/machines', 'Machines', 'machines-body'),
      '/freezer': (context, state, data) =>
          _page('/freezer', 'Freezer', 'freezer-body'),
      '/advanced/server-config': (context, state, data) => _page(
          '/advanced/server-config', 'Server Config', 'server-config-body'),
    }).call,
  );
  final app = ProviderScope(
    overrides: [
      alarmManProvider.overrideWith((ref) async => AlarmFixture()),
      accessSessionProvider.overrideWith(() => session),
      localPreferencesProvider.overrideWithValue(FakeEditorPreferences()),
      homePageLookupProvider.overrideWithValue(lookup.lookup),
      bootHomePageDebtProvider.overrideWithValue(bootDebt),
    ],
    child: BeamerProvider(
      routerDelegate: delegate,
      child: MaterialApp.router(
        routerDelegate: delegate,
        routeInformationParser: BeamerParser(),
      ),
    ),
  );
  return (app: app, delegate: delegate, debt: bootDebt);
}

void main() {
  setUp(_registerMenu);

  group('a session ending', () {
    testWidgets('beams from a raised page to Home when the anonymous account '
        'has no home page', (tester) async {
      final session = _DrivenSession(_engineer());
      final shell = _shell(session: session);

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

    testWidgets('lands on the anonymous account\'s home page', (tester) async {
      final session = _DrivenSession(_engineer());
      final shell = _shell(
        session: session,
        pages: _Pages({kAnonymousUsername: '/machines', 'gudrun': '/freezer'}),
      );

      await tester.pumpWidget(shell.app);
      await tester.pumpAndSettle();

      session.become(_anonymous());
      await tester.pumpAndSettle();

      expect(find.text('machines-body'), findsOneWidget,
          reason: 'the page the logged-out panel opens on, not the page of '
              'the person who just left');
    });

    testWidgets('a home page that is no longer routable falls back to /',
        (tester) async {
      final session = _DrivenSession(_engineer());
      final shell = _shell(
        session: session,
        pages: _Pages({kAnonymousUsername: '/deleted-page'}),
      );

      await tester.pumpWidget(shell.app);
      await tester.pumpAndSettle();

      session.become(_anonymous());
      await tester.pumpAndSettle();

      expect(find.text('home-body'), findsOneWidget,
          reason: 'a deleted home page must not beam into a not-found screen');
    });

    testWidgets('already on the home page: does not re-beam', (tester) async {
      final session = _DrivenSession(_engineer());
      final shell = _shell(session: session, initialPath: '/');

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
      testWidgets('a person falling to the panel account lands on the panel '
          'account\'s home page', (tester) async {
        // Still elevated, so the elevated-to-anonymous rule alone misses it —
        // and the page the person raised is one the panel's account may not
        // be able to see.
        final session = _DrivenSession(_engineer());
        final shell = _shell(
          session: session,
          pages: _Pages({'panel_a': '/freezer', kAnonymousUsername: '/machines'}),
        );

        await tester.pumpWidget(shell.app);
        await tester.pumpAndSettle();
        expect(find.text('server-config-body'), findsOneWidget);

        session.become(_panel());
        await tester.pumpAndSettle();

        expect(find.text('freezer-body'), findsOneWidget);
      });

      testWidgets('the panel resuming from anonymous moves nothing',
          (tester) async {
        final session = _DrivenSession(_anonymous());
        final shell = _shell(
            session: session, pages: _Pages({'panel_a': '/freezer'}));

        await tester.pumpWidget(shell.app);
        await tester.pumpAndSettle();

        session.become(_panel());
        await tester.pumpAndSettle();

        expect(find.text('server-config-body'), findsOneWidget,
            reason: 'nobody was signed in, so no session ended');
      });

      testWidgets('the panel re-resolving in place moves nothing',
          (tester) async {
        final session = _DrivenSession(_panel());
        final shell = _shell(
            session: session, pages: _Pages({'panel_a': '/freezer'}));

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
        final shell =
            _shell(session: session, pages: _Pages({'anna': '/freezer'}));

        await tester.pumpWidget(shell.app);
        await tester.pumpAndSettle();

        session.become(AccessSession(
          user:
              const AuthenticatedUser(username: 'anna', roleName: 'Engineering'),
          groups: const {AccessGroup.operate, AccessGroup.administer},
          expiresAt: DateTime.utc(2030),
        ));
        await tester.pumpAndSettle();

        expect(find.text('server-config-body'), findsOneWidget);
      });
    });

    testWidgets('a session becoming elevated by itself moves nothing',
        (tester) async {
      // A sign-in from a refusal prompt: that person signed in to open the
      // page in front of them. Only the app-bar sign-in goes home.
      final session = _DrivenSession(_anonymous());
      final shell =
          _shell(session: session, pages: _Pages({'gudrun': '/freezer'}));

      await tester.pumpWidget(shell.app);
      await tester.pumpAndSettle();
      expect(find.text('server-config-body'), findsOneWidget);

      session.become(_engineer());
      await tester.pumpAndSettle();

      expect(find.text('server-config-body'), findsOneWidget,
          reason: 'elevation opens doors, it does not walk through any');
    });
  });

  group('boot', () {
    testWidgets('opens on the anonymous account\'s home page', (tester) async {
      final session = _DrivenSession(_anonymous());
      final shell = _shell(
        session: session,
        initialPath: '/',
        pages: _Pages({kAnonymousUsername: '/freezer'}),
        debt: BootHomePageDebt(),
      );

      await tester.pumpWidget(shell.app);
      await tester.pumpAndSettle();

      expect(find.text('freezer-body'), findsOneWidget);
      expect(shell.debt.owed, isFalse);
    });

    testWidgets('a panel that resumed its station account opens on that '
        'account\'s home page', (tester) async {
      final session = _DrivenSession(_panel());
      final shell = _shell(
        session: session,
        initialPath: '/',
        pages: _Pages({'panel_a': '/freezer', kAnonymousUsername: '/machines'}),
        debt: BootHomePageDebt(),
      );

      await tester.pumpWidget(shell.app);
      await tester.pumpAndSettle();

      expect(find.text('freezer-body'), findsOneWidget,
          reason: 'this is how two panels on one database still open on '
              'different pages');
    });

    testWidgets('no home page leaves the panel where the router put it',
        (tester) async {
      final session = _DrivenSession(_anonymous());
      final shell = _shell(
        session: session,
        initialPath: '/',
        debt: BootHomePageDebt(),
      );

      await tester.pumpWidget(shell.app);
      await tester.pumpAndSettle();
      final historyBefore = shell.delegate.beamingHistory.length;
      await tester.pumpAndSettle();

      expect(find.text('home-body'), findsOneWidget);
      expect(shell.delegate.beamingHistory.length, historyBefore);
      expect(shell.debt.owed, isFalse,
          reason: 'a known answer settles the debt, even when it is Home');
    });

    testWidgets('a forgiven debt — a touch, a deep link, a resumed rebuild — '
        'moves nothing', (tester) async {
      final session = _DrivenSession(_anonymous());
      final shell = _shell(
        session: session,
        initialPath: '/',
        pages: _Pages({kAnonymousUsername: '/freezer'}),
        debt: BootHomePageDebt()..forgive(),
      );

      await tester.pumpWidget(shell.app);
      await tester.pumpAndSettle();

      expect(find.text('home-body'), findsOneWidget);
    });

    testWidgets('a database that answers late still gets the panel there',
        (tester) async {
      final pages = _Pages({kAnonymousUsername: '/freezer'})..known = false;
      final session = _DrivenSession(_anonymous());
      final shell = _shell(
        session: session,
        initialPath: '/',
        pages: pages,
        debt: BootHomePageDebt(),
      );

      await tester.pumpWidget(shell.app);
      await tester.pumpAndSettle();
      expect(find.text('home-body'), findsOneWidget);
      expect(shell.debt.owed, isTrue,
          reason: 'nobody could say, so nothing is settled');

      // The session provider rebuilds when the database arrives.
      pages.known = true;
      session.become(_anonymous());
      await tester.pumpAndSettle();

      expect(find.text('freezer-body'), findsOneWidget);
      expect(shell.debt.owed, isFalse);
    });

    testWidgets('once paid, a later session change does not boot again',
        (tester) async {
      final session = _DrivenSession(_anonymous());
      final shell = _shell(
        session: session,
        initialPath: '/',
        pages: _Pages({kAnonymousUsername: '/freezer'}),
        debt: BootHomePageDebt(),
      );

      await tester.pumpWidget(shell.app);
      await tester.pumpAndSettle();
      shell.delegate.beamToNamed('/machines');
      await tester.pumpAndSettle();

      session.become(_anonymous());
      await tester.pumpAndSettle();

      expect(find.text('machines-body'), findsOneWidget);
    });
  });

  group('signing in from the app bar', () {
    Future<void> signIn(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.lock_open_outlined));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(kAccessSignInUsernameKey), 'gudrun');
      await tester.enterText(find.byKey(kAccessSignInPasswordKey), 'pw');
      await tester.tap(find.byKey(kAccessSignInSubmitKey));
      await tester.pumpAndSettle();
    }

    testWidgets('lands on the person\'s home page', (tester) async {
      final session = _DrivenSession(_anonymous(), signsInAs: _engineer());
      final shell = _shell(
        session: session,
        initialPath: '/machines',
        pages: _Pages({'gudrun': '/freezer'}),
      );

      await tester.pumpWidget(shell.app);
      await tester.pumpAndSettle();
      await signIn(tester);

      expect(find.text('freezer-body'), findsOneWidget);
    });

    testWidgets('an account with no home page stays where it is',
        (tester) async {
      final session = _DrivenSession(_anonymous(), signsInAs: _engineer());
      final shell = _shell(
        session: session,
        initialPath: '/machines',
        pages: _Pages({kAnonymousUsername: '/freezer'}),
      );

      await tester.pumpWidget(shell.app);
      await tester.pumpAndSettle();
      await signIn(tester);

      expect(find.text('machines-body'), findsOneWidget,
          reason: 'no page of its own is not a reason to move anybody to Home');
    });
  });
}

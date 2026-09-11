/// The app-bar sign-in affordance, and the semantic elevation colour it is
/// painted with.
///
/// The theme group lives here rather than in a theme test file of its own
/// because this widget is `HmiStateColors.orange`'s only consumer: keeping the
/// token's contract next to the thing that reads it is what stops the two
/// drifting apart.
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
import 'package:tfc/theme.dart';
import 'package:tfc/widgets/access_change_password_dialog.dart';
import 'package:tfc/widgets/access_sign_in_dialog.dart';
import 'package:tfc/widgets/access_status_action.dart';
import 'package:tfc_access/tfc_access.dart';

/// A session controller that answers with whatever the test says, and counts
/// what was asked of it. Overriding [build] means none of the real leaf
/// providers -- and so no database, no preferences and no timer -- is ever
/// touched.
class _FakeSessionController extends AccessSessionController {
  _FakeSessionController({this.session, this.hang = false, this.fail = false});

  final AccessSession? session;
  final bool hang;
  final bool fail;

  int signOutCalls = 0;
  int pokeCalls = 0;

  @override
  Future<AccessSession> build() {
    if (hang) return Completer<AccessSession>().future;
    if (fail) return Future<AccessSession>.error(StateError('no database'));
    return Future<AccessSession>.value(session!);
  }

  @override
  Future<void> signOut() async {
    signOutCalls++;
  }

  @override
  void poke() {
    pokeCalls++;
  }
}

/// A one-route Beamer shell around `BaseScaffold`, the same shape
/// `base_scaffold_backarrow_test.dart` uses -- `BaseScaffold` reads
/// `context.currentBeamLocation`, so it needs a router above it.
Widget _scaffoldShell({
  required _FakeSessionController controller,
  required Widget body,
}) {
  final delegate = BeamerDelegate(
    locationBuilder: RoutesLocationBuilder(routes: {
      '/': (context, state, data) => BeamPage(
            key: const ValueKey('/'),
            title: 'Home',
            child: BaseScaffold(title: 'Home', body: body),
          ),
    }).call,
  );

  return ProviderScope(
    overrides: [accessSessionProvider.overrideWith(() => controller)],
    child: BeamerProvider(
      routerDelegate: delegate,
      child: MaterialApp.router(
        routerDelegate: delegate,
        routeInformationParser: BeamerParser(),
      ),
    ),
  );
}

AccessSession _elevated({
  String username = 'anna',
  String roleName = 'Supervisor',
  String? displayName,
  bool stationAccount = false,
}) =>
    AccessSession(
      user: AuthenticatedUser(
        username: username,
        roleName: roleName,
        displayName: displayName,
        stationAccount: stationAccount,
      ),
      groups: const {AccessGroup.setpoints},
      expiresAt: DateTime.now().add(const Duration(minutes: 15)),
    );

final AccessSession _anonymous = AccessSession.anonymous(const {});

/// The widget under an app-bar-shaped host: right-aligned, unbounded on the
/// cross axis, exactly as `BaseScaffold` places it.
Widget _host({
  required _FakeSessionController controller,
  AccessSignInOpener? openSignIn,
  AccessChangePasswordOpener? openChangePassword,
  ThemeData? theme,
}) {
  // Each opener is only passed when the test supplies one, so the
  // "the default opener is the real dialog" assertions still see the
  // constructor's own defaults rather than a stand-in this helper injected.
  Widget action() {
    if (openSignIn != null && openChangePassword != null) {
      return AccessStatusAction(
        openSignIn: openSignIn,
        openChangePassword: openChangePassword,
      );
    }
    if (openSignIn != null) return AccessStatusAction(openSignIn: openSignIn);
    if (openChangePassword != null) {
      return AccessStatusAction(openChangePassword: openChangePassword);
    }
    return const AccessStatusAction();
  }

  return ProviderScope(
    overrides: [accessSessionProvider.overrideWith(() => controller)],
    child: MaterialApp(
      theme: theme,
      home: Scaffold(
        body: Align(
          alignment: Alignment.topRight,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [action()],
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('HmiStateColors.orange', () {
    test('solarizedLight.orange is the Solarized orange', () {
      expect(HmiStateColors.solarizedLight.orange, SolarizedColors.orange);
    });

    test('solarizedDark.orange is the Solarized orange', () {
      expect(HmiStateColors.solarizedDark.orange, SolarizedColors.orange);
    });

    test('mutedLight.orange is the muted forced orange', () {
      expect(HmiStateColors.mutedLight.orange, MutedColors.forcedOrange);
    });

    test('mutedDark.orange is the muted forced orange', () {
      expect(HmiStateColors.mutedDark.orange, MutedColors.forcedOrange);
    });

    test('forcedOrange is not manualOchre — a second ochre would be unreadable',
        () {
      expect(MutedColors.forcedOrange, isNot(MutedColors.manualOchre));
    });

    test('copyWith(orange:) replaces orange and leaves the rest alone', () {
      const base = HmiStateColors.mutedLight;
      final copy = base.copyWith(orange: const Color(0xFF123456));

      expect(copy.orange, const Color(0xFF123456));
      expect(copy.green, base.green);
      expect(copy.yellow, base.yellow);
      expect(copy.blue, base.blue);
      expect(copy.grey, base.grey);
      expect(copy.red, base.red);
      expect(copy.violet, base.violet);
      expect(copy.onState, base.onState);
    });

    test('copyWith() without orange keeps this palette\'s orange', () {
      const base = HmiStateColors.mutedLight;
      expect(base.copyWith().orange, base.orange);
    });

    test('lerp carries orange: t=0 is this palette, t=1 is the other', () {
      const a = HmiStateColors.mutedLight;
      const b = HmiStateColors.solarizedLight;

      expect(a.lerp(b, 0).orange, a.orange);
      expect(a.lerp(b, 1).orange, b.orange);
    });

    testWidgets('of() on a bare MaterialApp still answers with an orange',
        (tester) async {
      late HmiStateColors light;
      late HmiStateColors dark;

      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) {
          light = HmiStateColors.of(context);
          return const SizedBox.shrink();
        }),
      ));
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Builder(builder: (context) {
          dark = HmiStateColors.of(context);
          return const SizedBox.shrink();
        }),
      ));

      expect(light.orange, HmiStateColors.solarizedLight.orange);
      expect(dark.orange, HmiStateColors.solarizedDark.orange);
    });
  });

  group('AccessStatusAction', () {
    testWidgets('anonymous offers Sign in and shows no username',
        (tester) async {
      await tester.pumpWidget(_host(
        controller: _FakeSessionController(session: _anonymous),
        openSignIn: (_, __) async {},
      ));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Sign in'), findsOneWidget);
      expect(find.byIcon(Icons.lock_open_outlined), findsOneWidget);
      expect(find.byType(Text), findsNothing);
      expect(find.byIcon(Icons.logout), findsNothing);
    });

    testWidgets('elevated shows the username, the role and a sign-out control',
        (tester) async {
      await tester.pumpWidget(_host(
        controller: _FakeSessionController(session: _elevated()),
        openSignIn: (_, __) async {},
      ));
      await tester.pumpAndSettle();

      expect(find.text('anna'), findsOneWidget);
      expect(find.text('Supervisor'), findsOneWidget);
      expect(find.byTooltip('Sign out'), findsOneWidget);
      expect(find.byTooltip('Sign in'), findsNothing);
    });

    testWidgets('the display name is shown when the user has one',
        (tester) async {
      await tester.pumpWidget(_host(
        controller: _FakeSessionController(
          session: _elevated(displayName: 'Anna Jonsdottir'),
        ),
        openSignIn: (_, __) async {},
      ));
      await tester.pumpAndSettle();

      expect(find.text('Anna Jonsdottir'), findsOneWidget);
    });

    testWidgets("the elevated text is the theme's orange, not Colors.orange",
        (tester) async {
      const sentinel = Color(0xFF00C3A5);
      final theme = ThemeData(
        extensions: <ThemeExtension<dynamic>>[
          HmiStateColors.mutedLight.copyWith(orange: sentinel),
        ],
      );

      await tester.pumpWidget(_host(
        controller: _FakeSessionController(session: _elevated()),
        openSignIn: (_, __) async {},
        theme: theme,
      ));
      await tester.pumpAndSettle();

      final username = tester.widget<Text>(find.text('anna'));
      final role = tester.widget<Text>(find.text('Supervisor'));
      expect(username.style?.color, sentinel);
      expect(role.style?.color, sentinel);
      expect(username.style?.color, isNot(HmiStateColors.mutedLight.orange));
    });

    testWidgets('the elevated icons take the same orange', (tester) async {
      const sentinel = Color(0xFF00C3A5);
      final theme = ThemeData(
        extensions: <ThemeExtension<dynamic>>[
          HmiStateColors.mutedLight.copyWith(orange: sentinel),
        ],
      );

      await tester.pumpWidget(_host(
        controller: _FakeSessionController(session: _elevated()),
        openSignIn: (_, __) async {},
        theme: theme,
      ));
      await tester.pumpAndSettle();

      final person = tester.widget<Icon>(find.byIcon(Icons.person_outline));
      final logout = tester.widget<Icon>(find.byIcon(Icons.logout));
      expect(person.color, sentinel);
      expect(logout.color, sentinel);
    });

    testWidgets('tapping the anonymous affordance opens the dialog once',
        (tester) async {
      var opened = 0;
      await tester.pumpWidget(_host(
        controller: _FakeSessionController(session: _anonymous),
        openSignIn: (_, __) async => opened++,
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Sign in'));
      await tester.pumpAndSettle();

      expect(opened, 1);
    });

    testWidgets('tapping sign out calls signOut exactly once', (tester) async {
      final controller = _FakeSessionController(session: _elevated());
      await tester.pumpWidget(_host(
        controller: controller,
        openSignIn: (_, __) async {},
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Sign out'));
      await tester.pumpAndSettle();

      expect(controller.signOutCalls, 1);
    });

    testWidgets('while loading it renders nothing — the bar must not flicker',
        (tester) async {
      await tester.pumpWidget(_host(
        controller: _FakeSessionController(hang: true),
        openSignIn: (_, __) async {},
      ));
      await tester.pump();

      expect(find.byType(IconButton), findsNothing);
      expect(find.byType(Text), findsNothing);
      expect(tester.getSize(find.byType(AccessStatusAction)), Size.zero);
    });

    testWidgets('an errored session degrades to the sign-in affordance',
        (tester) async {
      await tester.pumpWidget(_host(
        controller: _FakeSessionController(fail: true),
        openSignIn: (_, __) async {},
      ));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Sign in'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('adds no timer of its own — pumping and settling leaves none',
        (tester) async {
      await tester.pumpWidget(_host(
        controller: _FakeSessionController(session: _elevated()),
        openSignIn: (_, __) async {},
      ));
      await tester.pumpAndSettle(const Duration(seconds: 1));
      // A pending timer at the end of this body fails the test on its own.
    });

    testWidgets('a 60-character username stays inside the app-bar budget',
        (tester) async {
      await tester.pumpWidget(_host(
        controller: _FakeSessionController(
          session: _elevated(displayName: 'a' * 60),
        ),
        openSignIn: (_, __) async {},
      ));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byType(AccessStatusAction)).width,
        lessThanOrEqualTo(kAccessStatusActionMaxWidth),
      );
      final username = tester.widget<Text>(find.text('a' * 60));
      expect(username.overflow, TextOverflow.ellipsis);
      expect(username.maxLines, 1);
    });

    testWidgets('says Sign in, never Login', (tester) async {
      await tester.pumpWidget(_host(
        controller: _FakeSessionController(session: _anonymous),
        openSignIn: (_, __) async {},
      ));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Login'), findsNothing);
      expect(find.text('Login'), findsNothing);
    });

    test('the default opener is the real sign-in dialog', () {
      expect(const AccessStatusAction().openSignIn,
          same(showAccessSignInDialog));
    });
  });

  group('the account menu', () {
    testWidgets('a personal session can open it and change its password',
        (tester) async {
      var opened = 0;
      await tester.pumpWidget(_host(
        controller: _FakeSessionController(session: _elevated()),
        openSignIn: (_, __) async {},
        openChangePassword: (_, __) async => opened++,
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(kAccessAccountMenuKey));
      await tester.pumpAndSettle();

      expect(find.text(kAccessAccountMenuChangePasswordLabel), findsOneWidget);

      await tester.tap(find.text(kAccessAccountMenuChangePasswordLabel));
      await tester.pumpAndSettle();

      expect(opened, 1);
    });

    testWidgets('a station account is not offered it', (tester) async {
      // A committed panel resumes its account with nobody having presented a
      // credential, and the account is shared — so there is no "your own
      // password" to change. It belongs to an administrator on the users
      // screen, where it records itself as an administrator doing it.
      await tester.pumpWidget(_host(
        controller: _FakeSessionController(
          session: _elevated(username: 'freezer', stationAccount: true),
        ),
        openSignIn: (_, __) async {},
        openChangePassword: (_, __) async {},
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessAccountMenuKey), findsNothing);
      expect(find.text('freezer'), findsOneWidget,
          reason: 'the identity is still shown — only the menu is withheld');
    });

    testWidgets('sign-out stays one tap, menu or no menu', (tester) async {
      // Spec §5 requires logging out to be explicit and one tap from the app
      // bar. Folding sign-out into the menu would have made it two.
      final controller = _FakeSessionController(session: _elevated());
      await tester.pumpWidget(_host(
        controller: controller,
        openSignIn: (_, __) async {},
        openChangePassword: (_, __) async {},
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Sign out'));
      await tester.pumpAndSettle();

      expect(controller.signOutCalls, 1);
    });

    testWidgets('costs nothing against the app-bar width budget',
        (tester) async {
      // The menu hangs off text that was already there, so the elevated row is
      // no wider than it was — which is what keeps the clock and the alarm
      // banner centred.
      await tester.pumpWidget(_host(
        controller: _FakeSessionController(
          session: _elevated(displayName: 'a' * 60),
        ),
        openSignIn: (_, __) async {},
        openChangePassword: (_, __) async {},
      ));
      await tester.pumpAndSettle();

      expect(
        tester.getSize(find.byType(AccessStatusAction)).width,
        lessThanOrEqualTo(kAccessStatusActionMaxWidth),
      );
    });

    testWidgets('is absent when nobody is signed in', (tester) async {
      await tester.pumpWidget(_host(
        controller: _FakeSessionController(session: _anonymous),
        openSignIn: (_, __) async {},
        openChangePassword: (_, __) async {},
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessAccountMenuKey), findsNothing);
    });

    test('the default opener is the real change-password dialog', () {
      expect(const AccessStatusAction().openChangePassword,
          same(showAccessChangePasswordDialog));
    });
  });

  group('BaseScaffold access wiring', () {
    setUp(() {
      // Two, not one: Material's NavigationBar asserts on fewer than two
      // destinations, and BaseScaffold always builds one.
      RouteRegistry().menuItems.clear();
      RouteRegistry().addMenuItem(
          const MenuItem(label: 'Home', path: '/', icon: Icons.home));
      RouteRegistry().addMenuItem(const MenuItem(
          label: 'Alarm View', path: '/alarm-view', icon: Icons.alarm));
    });
    tearDown(() => RouteRegistry().menuItems.clear());

    testWidgets('renders the access affordance in the app bar',
        (tester) async {
      await tester.pumpWidget(_scaffoldShell(
        controller: _FakeSessionController(session: _anonymous),
        body: const Text('page-body'),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(AccessStatusAction), findsOneWidget);
      expect(find.byTooltip('Sign in'), findsOneWidget);
    });

    testWidgets('shows who is signed in while elevated', (tester) async {
      await tester.pumpWidget(_scaffoldShell(
        controller: _FakeSessionController(session: _elevated()),
        body: const Text('page-body'),
      ));
      await tester.pumpAndSettle();

      expect(find.text('anna'), findsOneWidget);
      expect(find.byTooltip('Sign out'), findsOneWidget);
    });

    testWidgets('a pointer-down on the body pokes the session',
        (tester) async {
      final controller = _FakeSessionController(session: _elevated());
      await tester.pumpWidget(_scaffoldShell(
        controller: controller,
        body: const Text('page-body'),
      ));
      await tester.pumpAndSettle();
      expect(controller.pokeCalls, 0);

      await tester.tap(find.text('page-body'));
      await tester.pumpAndSettle();

      expect(controller.pokeCalls, 1);
    });

    testWidgets('the poke listener does not swallow the page\'s own taps',
        (tester) async {
      final controller = _FakeSessionController(session: _elevated());
      var pageTaps = 0;
      await tester.pumpWidget(_scaffoldShell(
        controller: controller,
        body: GestureDetector(
          onTap: () => pageTaps++,
          child: const Text('page-body'),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('page-body'));
      await tester.pumpAndSettle();

      expect(pageTaps, 1);
      expect(controller.pokeCalls, 1);
    });
  });
}

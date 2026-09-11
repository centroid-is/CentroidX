/// The rig defect, end to end: a gateway panel boots ANONYMOUS, an engineer
/// signs in over the socket, and the `/advanced` pages appear.
///
/// **The transition is the property.** A test that starts from an elevated
/// session proves nothing here — that case worked. The panel now boots with an
/// empty group set and elevates on `session.login`, and what broke was the
/// question asked in between: with no local repository (which is every gateway
/// panel, by design — `databaseProvider` returns null the moment the transport
/// is gateway) the gate answered "this station can authenticate nobody" and
/// denied every raised route, so `NavDropdown`, which hides what the gate
/// denies, took the whole Advanced section off the panel of a signed-in
/// engineer.
///
/// **Nothing on the decision path is faked.** The real
/// `AccessSessionController`, the real `accessAuthorityProvider`, the real
/// `resolveAccessGate`, the real menu widget. Only the edges are overridden —
/// the device-local store, the Postgres that a gateway panel does not have,
/// and the relay sign-in seam standing in for the socket — so what this file
/// measures is the chain that was wrong, not a restatement of the fix.
library;

import 'package:beamer/beamer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/access_routes.dart';
import 'package:tfc/core/access_authority.dart';
import 'package:tfc/core/gateway_config.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/widgets/access_gate.dart';
import 'package:tfc/widgets/nav_dropdown.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import '../helpers/test_helpers.dart';

/// The account on the rig: `centroid`, whose role is Engineering, which holds
/// every group including `configure` and `administer`.
const _engineer = AuthenticatedUser(
  username: 'centroid',
  roleName: 'Engineering',
  displayName: 'Centroid',
  stationAccount: false,
);

const _password = 'correct-horse';

/// The Advanced menu, cut down to one entry per interesting group and one
/// ordinary page that must be unaffected throughout.
MenuItem _advancedMenu() => MenuItem(
      label: 'Advanced',
      icon: Icons.settings,
      children: [
        MenuItem(label: 'Config', icon: Icons.folder, isSection: true, children: [
          MenuItem(
              label: 'Page Editor',
              icon: Icons.edit,
              path: '/advanced/page-editor'),
          MenuItem(
              label: 'Preferences',
              icon: Icons.tune,
              path: '/advanced/preferences'),
          MenuItem(
              label: 'Server Config', icon: Icons.dns, path: kServerConfigRoute),
        ]),
        MenuItem(label: 'Dashboard', icon: Icons.home, path: '/dashboard'),
      ],
    );

/// A gateway panel, built the way the rig is: gateway transport in the
/// device-local row, no Postgres, and a socket that verifies the credential.
///
/// The container is real all the way down from [accessAuthorityProvider]. What
/// stands in for the plant is exactly three things: the device-local store, the
/// database (null, which is what the gateway branch of `databaseProvider`
/// returns anyway) and the relay sign-in seam.
Future<ProviderContainer> _gatewayPanel() async {
  final local = InMemoryPreferences();
  await writeGatewayConfig(
    local,
    const GatewayConfig(
        mode: TransportMode.gateway, url: 'wss://centroidx-backend:9443'),
  );
  final container = ProviderContainer(
    overrides: [
      preferencesProvider.overrideWith((ref) => createTestPreferences()),
      localPreferencesProvider.overrideWithValue(local),
      databaseProvider.overrideWith((ref) async => null),
      stationNameProvider.overrideWithValue('svn-nes-ot-panel'),
      relaySignInProvider.overrideWith((ref) async =>
          ({required username, required password, station}) async {
            if (username != _engineer.username || password != _password) {
              throw StateError('the fake gateway was asked the wrong thing');
            }
            return const SessionLoginResult(
              user: _engineer,
              groups: {
                AccessGroup.operate,
                AccessGroup.configure,
                AccessGroup.administer,
                AccessGroup.users,
                AccessGroup.setpoints,
                AccessGroup.device,
                AccessGroup.force,
              },
            );
          }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// A `NavDropdown` in a bar-height slot under the panel's own container.
///
/// `UncontrolledProviderScope` rather than `ProviderScope`, so the test can
/// call `signIn` on the very container the widgets read — the sign-in has to
/// reach these widgets as a rebuild, not as a remount, which is precisely the
/// thing that was claimed to work and did not.
class _NavBarLocation extends BeamLocation<BeamState> {
  _NavBarLocation(this.menuItem)
      : super(RouteInformation(uri: Uri.parse('/dashboard')));

  final MenuItem menuItem;

  @override
  List<BeamPage> buildPages(BuildContext context, BeamState state) => [
        BeamPage(
          key: const ValueKey('nav'),
          child: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                height: 80,
                child: NavDropdown(menuItem: menuItem),
              ),
            ),
          ),
        ),
      ];

  @override
  List<Pattern> get pathPatterns => ['/dashboard'];
}

/// The menu host: the panel's own container, the real `NavDropdown`.
Widget _navHost(ProviderContainer container) {
  final delegate = BeamerDelegate(
    locationBuilder: (routeInformation, _) => _NavBarLocation(_advancedMenu()),
  );
  return UncontrolledProviderScope(
    container: container,
    child: BeamerProvider(
      routerDelegate: delegate,
      child: MaterialApp.router(
        routerDelegate: delegate,
        routeInformationParser: BeamerParser(),
      ),
    ),
  );
}

/// The gate on one raised route, under the same container.
Widget _gateHost(ProviderContainer container, AccessGroup group) {
  final delegate = BeamerDelegate(
    locationBuilder: (routeInformation, _) => BeamerLocationStub(group),
  );
  return UncontrolledProviderScope(
    container: container,
    child: BeamerProvider(
      routerDelegate: delegate,
      child: MaterialApp.router(
        routerDelegate: delegate,
        routeInformationParser: BeamerParser(),
      ),
    ),
  );
}

/// A location whose single page is an [AccessGate] over a marked child.
class BeamerLocationStub extends BeamLocation<BeamState> {
  BeamerLocationStub(this.group)
      : super(RouteInformation(uri: Uri.parse('/advanced/page-editor')));

  final AccessGroup group;

  static const Key childKey = Key('the-page-itself');

  @override
  List<BeamPage> buildPages(BuildContext context, BeamState state) => [
        BeamPage(
          key: const ValueKey('gated'),
          child: AccessGate(
            group: group,
            title: 'Page Editor',
            child: const Scaffold(body: SizedBox(key: childKey)),
          ),
        ),
      ];

  @override
  List<Pattern> get pathPatterns => ['/advanced/page-editor'];
}

Finder _row(String label) => find.widgetWithText(PopupMenuItem<void>, label);

Future<void> _openAdvanced(WidgetTester tester) async {
  await tester.tap(find.text('Advanced'));
  await tester.pumpAndSettle();
}

Future<void> _closeMenu(WidgetTester tester) async {
  await tester.tapAt(const Offset(5, 5));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    SecureStorage.setInstance(FakeSecureStorage());
    final registry = RouteRegistry();
    registry.clearRouteGroups();
    registry.menuItems.clear();
    // Two top-level destinations, because `BaseScaffold` — which the locked
    // page brings with it so the operator can leave — builds a
    // `NavigationBar`, and Material asserts that a navigation bar has at least
    // two of them.
    registry.addMenuItem(
        MenuItem(label: 'Overview', icon: Icons.dashboard, path: '/dashboard'));
    registry.addMenuItem(_advancedMenu());
    installRaisedRoutes();
  });

  tearDown(() {
    final registry = RouteRegistry();
    registry.clearRouteGroups();
    registry.menuItems.clear();
  });

  testWidgets(
      'a gateway panel that boots anonymous shows its Advanced pages once an '
      'engineer signs in', (tester) async {
    final container = await _gatewayPanel();

    await tester.pumpWidget(_navHost(container));
    await tester.pumpAndSettle();

    // The boot state: anonymous, with an empty group set beyond the operate
    // floor. This is what the panel does now on every start.
    final booted = await container.read(accessSessionProvider.future);
    expect(booted.isElevated, isFalse,
        reason: 'a gateway panel restores nothing — it boots anonymous');
    expect(await container.read(accessAuthorityProvider.future),
        AccessAuthority.relay,
        reason: 'no repository, and that is the design rather than an outage');

    await _openAdvanced(tester);
    expect(_row('Page Editor'), findsNothing,
        reason: 'nobody is signed in yet');
    expect(_row('Dashboard'), findsOneWidget,
        reason: 'an unraised page is unaffected in every arm of this test');
    await _closeMenu(tester);

    // The transition: the server verifies and answers, and the panel's session
    // becomes what the server resolved. No remount, no navigation.
    final result = await container
        .read(accessSessionProvider.notifier)
        .signIn(_engineer.username, _password);
    expect(result, AccessSignInResult.ok);
    await tester.pumpAndSettle();

    await _openAdvanced(tester);
    expect(_row('Page Editor'), findsOneWidget,
        reason: 'THE defect: a signed-in engineer holding configure must see '
            'the configure pages, on a gateway panel as on a direct one');
    expect(_row('Preferences'), findsOneWidget,
        reason: 'and the administer pages too — the rig account is '
            'Engineering, which holds every group');
    expect(_row('Server Config'), findsOneWidget);
    expect(_row('Dashboard'), findsOneWidget);
  });

  testWidgets(
      'the gate on a raised route opens on the same sign-in, without '
      'navigating', (tester) async {
    final container = await _gatewayPanel();

    await tester.pumpWidget(_gateHost(container, AccessGroup.configure));
    await tester.pumpAndSettle();

    expect(find.byKey(BeamerLocationStub.childKey), findsNothing);
    expect(find.byKey(kAccessLockedBodyKey), findsOneWidget,
        reason: 'anonymous is refused, and told how to get through');
    expect(find.byKey(kAccessLockedNoDatabaseKey), findsNothing,
        reason: 'a gateway panel must not be sent to fix a database it does '
            'not have and does not want');

    await container
        .read(accessSessionProvider.notifier)
        .signIn(_engineer.username, _password);
    await tester.pumpAndSettle();

    expect(find.byKey(BeamerLocationStub.childKey), findsOneWidget,
        reason: 'the page itself, reached by a rebuild rather than a push');
    expect(find.byKey(kAccessLockedBodyKey), findsNothing);
  });

  testWidgets('signing out on a gateway panel takes the pages away again',
      (tester) async {
    // The other half of the transition. A fix that simply stopped denying on a
    // gateway panel would pass the two tests above and fail this one.
    final container = await _gatewayPanel();

    await tester.pumpWidget(_navHost(container));
    await tester.pumpAndSettle();
    await container
        .read(accessSessionProvider.notifier)
        .signIn(_engineer.username, _password);
    await tester.pumpAndSettle();

    await _openAdvanced(tester);
    expect(_row('Page Editor'), findsOneWidget);
    await _closeMenu(tester);

    await container.read(accessSessionProvider.notifier).signOut();
    await tester.pumpAndSettle();

    await _openAdvanced(tester);
    expect(_row('Page Editor'), findsNothing,
        reason: 'the session is the authority in both directions');
    expect(_row('Server Config'), findsOneWidget,
        reason: 'the exemption is not a session question');
  });
}

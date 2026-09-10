/// The browser entrypoint: the eight routes of `docs/web-client-scope.md` and
/// nothing else.
///
/// ## Why this is a second entrypoint and not a flag
///
/// Everything outside the eight routes is meant to be **absent from the build**
/// rather than stubbed. A runtime flag cannot do that: dart2js has to compile
/// every imported library before it can drop a dead branch, so a `main.dart`
/// that merely skipped registering `/advanced/ip-settings` would still be
/// compiling D-Bus. `lib/main.dart` is untouched and remains the only
/// entrypoint any station ships.
///
///     flutter build web -t lib/main_web.dart
///
/// ## What is missing, and why none of it is a stub
///
/// Not registered here: IP Settings and About Linux (D-Bus, which is never
/// coming to the browser), the Knowledge Base and the tech-doc library
/// (`tfc_mcp_server`), History View, Key Repository, the MCP bridge settings,
/// and chat. Those are decisions, recorded with their reasons in
/// `docs/web-client-scope.md`, not gaps waiting to be filled.
///
/// The pages that *are* here reach a few surfaces that a browser genuinely
/// cannot hold — the OPC UA browse dialog, the UMAS symbol picker, the live
/// connection chips. Those go through compile-time seams (`live_browse.dart`,
/// `live_session_status.dart`) whose web arms answer exactly as the native ones
/// do when this process holds no session, which is also what a station in
/// gateway mode has always answered. The fields stay editable by hand.
///
/// ## Boot
///
/// No local database, no secrets, no D-Bus. The panel reaches the plant over
/// one wss socket and the gateway holds everything: preferences, alarms,
/// history, the audit trail, and the identity every write is checked against.
/// So this `main` does none of the native bootstrap `main.dart` does — no
/// SIGPIPE handling, no log-file redirection, no updater, no page manager
/// preloaded from local storage.
library;

import 'package:beamer/beamer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc/access_routes.dart';
import 'package:tfc/pages/access_admin.dart';
import 'package:tfc/pages/alarm_editor.dart';
import 'package:tfc/pages/alarm_view.dart';
import 'package:tfc/pages/audit_trail.dart';
import 'package:tfc/pages/not_found.dart';
import 'package:tfc/pages/page_editor.dart';
import 'package:tfc/pages/page_view.dart';
import 'package:tfc/pages/server_config.dart';
import 'package:tfc/providers/theme.dart';
import 'package:tfc/theme.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/routes.dart';
import 'package:tfc/transition_delegate.dart';
import 'package:tfc/widgets/access_gate.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: CentroidWebApp()));
}

/// The eight routes, with the same gates the native build applies.
///
/// `installRaisedRoutes` first, exactly as `createLocationBuilder` does it: the
/// navigation menu resolves a path's group through [RouteRegistry], and if the
/// table were built before the raised routes were declared the menu and the
/// gates could disagree about which entries are locked.
RoutesLocationBuilder buildWebRoutes() {
  installRaisedRoutes();

  // The `!` is deliberate and copied from `createLocationBuilder`: a path
  // missing from kRaisedRoutes throws when the route is built rather than
  // resolving to `operate` and quietly leaving the route open. A loud failure
  // at boot beats a silent open door — and that matters more here, not less,
  // because this build is reachable from any browser that can route to the
  // gateway.
  Widget gated(String path, String title, Widget child) => AccessGate(
        group: kRaisedRoutes[path]!,
        title: title,
        allowWhenNobodyCanSignIn: routeAllowedWhenNobodyCanSignIn(path),
        child: child,
      );

  return RoutesLocationBuilder(routes: {
    '/': (context, state, args) => const BeamPage(
          key: ValueKey('/'),
          title: 'Home',
          child: PlantPageView(pageName: '/'),
        ),
    AppRoutes.alarmView: (context, state, args) => const BeamPage(
          key: ValueKey(AppRoutes.alarmView),
          title: 'Alarm View',
          child: AlarmViewPage(),
        ),
    '/advanced/page-editor': (context, state, args) => BeamPage(
          key: const ValueKey('/advanced/page-editor'),
          title: 'Page Editor',
          child: gated(
              '/advanced/page-editor', 'Page Editor', const PageEditor()),
        ),
    '/advanced/alarm-editor': (context, state, args) => BeamPage(
          key: const ValueKey('/advanced/alarm-editor'),
          title: 'Alarm Editor',
          child: gated(
              '/advanced/alarm-editor', 'Alarm Editor', const AlarmEditorPage()),
        ),
    '/advanced/server-config': (context, state, args) => BeamPage(
          key: const ValueKey('/advanced/server-config'),
          title: 'Server Config',
          child: gated(
              '/advanced/server-config', 'Server Config', ServerConfigPage()),
        ),
    '/advanced/audit-trail': (context, state, args) => BeamPage(
          key: const ValueKey('/advanced/audit-trail'),
          title: 'Audit Trail',
          child: gated(
              '/advanced/audit-trail', 'Audit Trail', const AuditTrailPage()),
        ),
    '/advanced/access': (context, state, args) => BeamPage(
          key: const ValueKey('/advanced/access'),
          title: 'Access',
          child: gated('/advanced/access', 'Access', const AccessAdminPage()),
        ),
  });
}

/// The app shell.
///
/// Deliberately thinner than `MyApp`: no upgrader, no marionette hooks, no
/// elicitation dialog (that is MCP), and no startup-url handling — a browser
/// already has an address bar, which is the thing `startup_url` exists to
/// substitute for on a panel that has none.
class CentroidWebApp extends ConsumerStatefulWidget {
  const CentroidWebApp({super.key});

  @override
  ConsumerState<CentroidWebApp> createState() => _CentroidWebAppState();
}

class _CentroidWebAppState extends ConsumerState<CentroidWebApp> {
  late final BeamerDelegate _routerDelegate = BeamerDelegate(
    initialPath: '/',
    notFoundPage: const BeamPage(child: PageNotFound()),
    transitionDelegate: MyNoAnimationTransitionDelegate(),
    locationBuilder: buildWebRoutes(),
  );

  @override
  void dispose() {
    _routerDelegate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final themeAsync = ref.watch(themeNotifierProvider);
    final schemeAsync = ref.watch(colorSchemeNotifierProvider);
    final (light, dark) = themesForScheme(
        schemeAsync.valueOrNull ?? AppColorScheme.solarized);

    return MaterialApp.router(
      title: 'CentroidX',
      debugShowCheckedModeBanner: false,
      theme: light,
      darkTheme: dark,
      themeMode: themeAsync.when(
        data: (themeMode) => themeMode,
        loading: () => ThemeMode.system,
        error: (_, __) => ThemeMode.system,
      ),
      routerDelegate: _routerDelegate,
      routeInformationParser: BeamerParser(),
      backButtonDispatcher:
          BeamerBackButtonDispatcher(delegate: _routerDelegate),
    );
  }
}

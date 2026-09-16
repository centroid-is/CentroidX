/// The browser entrypoint: the eight routes of `docs/web-client-scope.md`, the
/// plant's own pages, and nothing else.
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
/// So this `main` does almost none of the native bootstrap `main.dart` does —
/// no SIGPIPE handling, no log-file redirection, no updater, no page manager
/// preloaded from local storage.
///
/// What it does do, it does because the boot path reads it before the first
/// frame. It opens the browser's own device-local store — the transport row,
/// the theme and the session live there, and `providers/
/// device_local_store_open.dart` says what "device-local" means in a tab —
/// and it names a keychain that holds nothing (`core/secure_storage/
/// browser.dart`). Both were missing once, and the result was a white screen
/// with an empty console: `createDeviceLocalPreferences()` threw its "init has
/// not run" `StateError` inside every provider on the boot path, Riverpod held
/// each throw as an `AsyncError` rather than reporting it, the home route
/// rendered the blank it renders when there are no pages, and no socket was
/// ever dialled because the transport row could not be read.
library;

import 'package:beamer/beamer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc/access_routes.dart';
import 'package:tfc/core/secure_storage/browser.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/page_creator/page.dart' show PageManager;
import 'package:tfc/pages/access_admin.dart';
import 'package:tfc/pages/alarm_editor.dart';
import 'package:tfc/pages/alarm_view.dart';
import 'package:tfc/pages/audit_trail.dart';
import 'package:tfc/pages/key_repository.dart';
import 'package:tfc/pages/not_found.dart';
import 'package:tfc/pages/page_editor.dart';
import 'package:tfc/pages/page_view.dart';
import 'package:tfc/pages/preferences.dart';
import 'package:tfc/pages/server_config.dart';
import 'package:tfc/providers/menu.dart'
    show menuComposerProvider, routablePathsProvider;
import 'package:tfc/providers/page_manager.dart'
    show bootstrapPageManagerProvider, pageManagerProvider;
import 'package:tfc/providers/preferences.dart'
    show initDeviceLocalPreferences;
import 'package:tfc/providers/theme.dart';
import 'package:tfc/core/web_logging.dart';
import 'package:tfc/theme.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/routes.dart';
import 'package:tfc/transition_delegate.dart';
import 'package:tfc/widgets/access_gate.dart';
import 'package:tfc/widgets/page_access_gate.dart';
import 'package:tfc/widgets/route_redirect.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart'
    show SecureStorage;

import 'navigation.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // The console is the only log a browser has, and `Logger` says nothing in
  // a release build unless told to — which is how the asset bug hid.
  routeLoggerToConsole();

  // The keychain — none — before the store. `Preferences.create` asks
  // `SecureStorage.getInstance()`, and the default that answers when nothing
  // was set asks `dart:io`'s `Platform`, which a browser cannot answer.
  SecureStorage.setInstance(BrowserSecureStorage());

  // The browser's per-origin store, before anything reads a preference. The
  // earliest read is `gatewayConfigProvider`, inside the first frame, and the
  // factory behind `localPreferencesProvider` throws when this has not run.
  // Same call, same ordering and same reason as `main.dart`;
  // `boot_ordering_test.dart` pins both entrypoints.
  await initDeviceLocalPreferences();

  runApp(ProviderScope(
    overrides: [
      // The navigation bar is composed from the pages the way the station
      // shell composes it, minus the platform flags a browser has no use for.
      // Without a composer the bar is the route registry's contents, which
      // is nothing — `installRaisedRoutes` declares groups, not entries — so
      // Server Config was reachable only by typing its address.
      menuComposerProvider.overrideWithValue(_composeWebMenu),
      // And every entry this build carries no route for is dropped before it
      // is offered, so an operator is never shown History View or IP Settings
      // and told "not found" on tap. The same filter the station applies
      // (`main.dart`) — with one difference that is the whole reason the
      // browser's routes are not a table built once at boot: a station knows
      // its pages before `runApp`, a browser learns them after sign-in and
      // again on every change, so the routable set follows the page manager
      // (`_webPlantPagePattern` serves whatever it holds) rather than being
      // read off a table that would never hold them.
      routablePathsProvider.overrideWith((ref) {
        final manager = ref.watch(pageManagerProvider).valueOrNull ??
            ref.watch(bootstrapPageManagerProvider);
        return {...kWebFixedRoutes, ...?manager?.pages.keys};
      }),
    ],
    child: const CentroidWebApp(),
  ));
}

/// The top-level menu, from the pages the page manager holds.
///
/// The station's own composition, with `isLinux` false: the D-Bus entries are
/// panel work by definition. Until page rows travel the relay the page
/// manager holds the built-in default (see `docs/web-client-scope.md`), so
/// the pages half of this is one Home entry for now; the Advanced half is
/// what makes the eight routes reachable from the bar.
List<MenuItem> _composeWebMenu(PageManager pageManager) {
  final items = buildTopLevelMenuItems(
    isLinux: false,
    pageMenuItems: pageManager.getRootMenuItems(),
    historyAtTopLevel: historyViewIsTopLevel(pageManager.topLevelOrder),
    reportsAtTopLevel: reportsIsTopLevel(pageManager.topLevelOrder),
  );
  pageManager.sortTopLevel(items);
  return items;
}

/// The eight routes, with the same gates the native build applies — and the
/// plant's pages, resolved live.
///
/// `installRaisedRoutes` first, exactly as `createLocationBuilder` does it: the
/// navigation menu resolves a path's group through [RouteRegistry], and if the
/// table were built before the raised routes were declared the menu and the
/// gates could disagree about which entries are locked.
///
/// **Why the plant's pages are one pattern and not one route each.** The
/// station registers a route per page (`main.dart`, `addRoute`) because it
/// knows its pages before `runApp`; a browser does not — its rows arrive over
/// the relay after sign-in and again on every change (`relayed_config_items.
/// dart`), and a Beamer route table is fixed once the delegate exists. So the
/// eight fixed routes are joined by [_webPlantPagePattern], which matches
/// every other path and hands it to [_WebPlantPage] to resolve against the
/// page manager *as it is now*: a page → the same `PageAccessGate` +
/// `AssetView` the station wraps it in, group and whitelist alike; no such
/// page → not found. Nothing is opened that the station would not open.
RoutesLocationBuilder buildWebRoutes() {
  installRaisedRoutes();
  return RoutesLocationBuilder(routes: {
    ..._webRouteTable(),
    _webPlantPagePattern: (context, state, args) {
      final path = state.uri.path;
      return BeamPage(
        key: ValueKey('page:$path'),
        child: _WebPlantPage(path: path),
      );
    },
  });
}

/// The eight fixed paths this build serves, for the routable filter and for
/// the wildcard to step around.
///
/// Read off the same table rather than kept as a second list, so a route
/// added to one cannot be forgotten by the other — the failure that filter
/// exists to prevent, one layer up.
final Set<String> kWebFixedRoutes =
    _webRouteTable().keys.cast<String>().toSet();

/// Every path that is not `/` and not one of the eight fixed routes.
///
/// A `RegExp` and not Beamer's `'*'`, for two reasons that are both about
/// what Beamer stacks. Beamer builds one page per matching route, sorted by
/// pattern length, and shows the last: a bare `'*'` (length 1) sorts beside
/// `'/'` and would cover Home on `/` or sit under it on a plant page depending
/// on map order, where this pattern is longer than every fixed key and so is
/// always the top page where it matches. And it does not match the fixed
/// routes at all, so no plant-page widget is ever mounted beneath Server
/// Config or the sign-in gate. `/` itself is excluded because Home is
/// [_WebHome]'s decision.
final RegExp _webPlantPagePattern = RegExp(
  '^(?!(?:${kWebFixedRoutes.where((p) => p != '/').map(RegExp.escape).join('|')})'
  r'(?:[/?#]|$))/.+',
);

/// One of the plant's pages, gated exactly as `main.dart` gates it —
/// `PageAccessGate` (the page's declared group, then the session's whitelist)
/// around `AssetView` — but resolved against the page manager as it is now,
/// so a page that arrives with the rows after sign-in, or changes while the
/// tab is open, is reachable without a reload. A path the manager does not
/// hold is not found, which is the answer the station's router gives too.
class _WebPlantPage extends ConsumerWidget {
  const _WebPlantPage({required this.path});

  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.watch(pageManagerProvider).valueOrNull ??
        ref.watch(bootstrapPageManagerProvider);
    final page = manager?.pages[path];
    if (page == null) return const PageNotFound();
    return PageAccessGate(
      path: path,
      title: page.menuItem.label,
      child: AssetView(pageName: path),
    );
  }
}

/// What `/` opens: the plant's Home when it has one, otherwise its first
/// reachable page — the same two answers `main.dart` gives, decided live.
///
/// The station decides this once, before `runApp`, from the pages it has
/// cached. A browser decides it on every build: before sign-in the page
/// manager holds the built-in default, which does have a `/`, so the gate in
/// front of it shows the sign-in; once the plant's rows arrive there may be
/// no page keyed `/` at all (the measured plant has none — every page lives
/// under a section), and `/` then redirects to the first page the menu
/// lists, through the same `RouteRedirect` the station uses, which only
/// beams while the router is actually at `/`. A plant with no pages keeps
/// the gated view, which says the page is not found rather than nothing.
///
/// **The account's own home page is not honoured here yet.** Since #564 a
/// station opens on the home page of the account its session resolves to
/// (`BaseScaffold`'s boot navigation, through `homePageLookupProvider`,
/// which reads `app_user.home_page` from the database). A browser has no
/// database and the wire carries no home page for the session's own account:
/// `session.login` answers the user and the groups, and `listUsers` — which
/// does carry `UserSummary.homePage` — takes `users`. So the lookup answers
/// "unknown", the boot debt is not owed on this entrypoint, and `/` resolves
/// as above. Closing it is the same wire addition the sign-in floor names
/// (`lib/providers/access.dart`, `_anonymousSession`): the `hello` result
/// and the `session.login` result carrying the admitted account's home page
/// beside its groups and pages, after which this widget honours it exactly
/// as `main.dart` does and falls back to the first menu path only where the
/// account names none.
class _WebHome extends ConsumerWidget {
  const _WebHome();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.watch(pageManagerProvider).valueOrNull ??
        ref.watch(bootstrapPageManagerProvider);
    final target = manager == null || manager.pages.containsKey('/')
        ? null
        : firstMenuPath(manager.getRootMenuItems());
    if (target == null) {
      return const PageAccessGate(
        path: '/',
        title: 'Home',
        child: AssetView(pageName: '/'),
      );
    }
    return RouteRedirect(from: '/', target: target);
  }
}

Map<Pattern, dynamic Function(BuildContext, BeamState, Object?)>
    _webRouteTable() {
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

  return {
    // Home — or the plant's first page when it has no Home. Decided live by
    // [_WebHome]; a hardcoded `AssetView('/')` here was "page not found" on a
    // plant whose every page lives under a section. The plant's other pages
    // are served by [_webPlantPagePattern], appended in [buildWebRoutes].
    '/': (context, state, args) => const BeamPage(
          key: ValueKey('/'),
          title: 'Home',
          child: _WebHome(),
        ),
    // Behind the page gate, as `main.dart` registers it: the whitelist can
    // drop Alarm View from the menu, and without the gate the address still
    // opened it — the exact hole `PageAccessGate` was written for
    // (`main.dart`, at this route). This table carried the bare page for a
    // while, which was a browser serving the alarm list to an identity whose
    // whitelist admitted nothing.
    AppRoutes.alarmView: (context, state, args) => const BeamPage(
          key: ValueKey(AppRoutes.alarmView),
          title: 'Alarm View',
          child: PageAccessGate(
            path: AppRoutes.alarmView,
            title: 'Alarm View',
            child: AlarmViewPage(),
          ),
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
    // Key mappings are plant configuration and travel over the socket like the
    // rest of it. The one part of this page that touched a filesystem — export
    // and import — is behind `pages/key_mappings_file.dart`, so the buttons
    // download and upload here instead of throwing.
    '/advanced/key-repository': (context, state, args) => BeamPage(
          key: const ValueKey('/advanced/key-repository'),
          title: 'Key Repository',
          child: gated('/advanced/key-repository', 'Key Repository',
              KeyRepositoryPage(proposalData: args is String ? args : null)),
        ),
    // The settings screen. Its MCP card is absent rather than disabled (see
    // `widgets/mcp_server_section.dart`), and its database card edits a
    // connection this client never opens — the gateway owns the database — so
    // what remains here is appearance, theme and the shared configuration keys.
    '/advanced/preferences': (context, state, args) => BeamPage(
          key: const ValueKey('/advanced/preferences'),
          title: 'Preferences',
          child: gated(
              '/advanced/preferences', 'Preferences', const PreferencesPage()),
        ),
  };
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

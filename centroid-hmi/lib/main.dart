import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:beamer/beamer.dart';
import 'package:dbus/dbus.dart';
import 'package:amplify_secure_storage_dart/amplify_secure_storage_dart.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:upgrader/upgrader.dart';
import 'package:centroidx_upgrader/centroidx_upgrader.dart';

import 'package:tfc/access_routes.dart';
import 'package:tfc/core/runner_liveness.dart';
import 'package:tfc/core/startup_url.dart';
import 'package:tfc/core/update_channel.dart';
import 'package:tfc/core/update_launch.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/routes.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/widgets/route_redirect.dart';
import 'package:tfc/pages/page_view.dart';
import 'package:tfc/pages/page_editor.dart';
import 'package:tfc/pages/not_found.dart';
import 'package:tfc/pages/preferences.dart';
import 'package:tfc/pages/alarm_editor.dart';
import 'package:tfc/pages/alarm_view.dart';
import 'package:tfc/pages/ip_settings.dart';
import 'package:tfc/pages/dbus_login.dart';
import 'package:tfc/pages/history_view.dart';
import 'package:tfc/pages/server_config.dart';
import 'package:tfc/pages/key_repository.dart';
import 'package:tfc/pages/about_linux.dart';
import 'package:tfc/pages/tech_doc_library.dart';
import 'package:tfc/pages/first_user.dart';
import 'package:tfc/pages/audit_trail.dart';
import 'package:tfc/pages/access_admin.dart';
import 'package:tfc/transition_delegate.dart';
import 'package:tfc/providers/theme.dart';
import 'package:tfc/core/feature_flags.dart';
import 'package:tfc/providers/preferences.dart'
    show createDeviceLocalPreferences;
import 'package:tfc/page_creator/page.dart';

import 'package:tfc/theme.dart';
import 'package:tfc/page_creator/assets/registry.dart';
import 'package:tfc/core/system_clock.dart';
import 'package:tfc/widgets/access_gate.dart';
import 'package:tfc/widgets/dbus_gate.dart';
import 'package:tfc/widgets/nav_dropdown.dart';
import 'package:mcp_dart/mcp_dart.dart' show ElicitResult;
import 'package:tfc/chat/chat_overlay.dart';
import 'package:tfc/chat/elicitation_dialog.dart';
import 'package:tfc/drawings/drawing_overlay.dart';
import 'package:tfc/providers/chat.dart';
import 'package:tfc/mcp/app_capture.dart';
import 'package:tfc/providers/mcp_bridge.dart';
import 'package:tfc/providers/navigator_key.dart';
import 'package:tfc/providers/page_manager.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/providers/scaffold_messenger_key.dart';

import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_dart/core/log_config.dart';
import 'package:tfc/core/secure_storage/macos.dart';
import 'package:tfc/core/secure_storage/other.dart';
import 'package:pdfrx/pdfrx.dart';

import 'package:tfc/widgets/access_session_ended_notice.dart';
import 'package:tfc/widgets/proposal_banner.dart';
import 'package:tfc/widgets/onscreen_keyboard.dart';
import 'package:tfc/marionette/route_logger.dart';
import 'package:tfc/widgets/panes/side_pane.dart';
import 'package:tfc/widgets/panes/standard_dialog.dart';

import 'marionette_init.dart';
import 'navigation.dart';
import 'package:tfc/providers/menu.dart';
import 'package:tfc/widgets/page_access_gate.dart';

/// Enable with: --dart-define=MARIONETTE=true
const _enableMarionette = bool.fromEnvironment('MARIONETTE');

/// Synchronous log file handle for MSIX debug logging.
///
/// In MSIX, neither Flutter's print() nor dart:io's stdout route through the
/// C++ freopen_s redirect. We open the log file directly from Dart using
/// synchronous IO (RandomAccessFile) to guarantee writes are flushed.
RandomAccessFile? _logFile;

void _debugPrint(Zone self, ZoneDelegate parent, Zone zone, String line) {
  if (_logFile != null) {
    _logFile!.writeStringSync('$line\n');
  }
  // Forward to parent so debugger/DevTools still works.
  parent.print(zone, line);
}

/// How much of one diagnostics dump is kept. The creator chain runs all the
/// way to the root; its head is what names the asset, so the tail is padding.
const int kCulpritLineLimit = 400;

/// The line a framework error is logged under: the exception, plus whatever
/// the details know about *which* widget caused it.
///
/// The message alone does not say WHICH Row overflowed — a layout error's
/// stack is the paint stack, all framework frames. The widget lives in the
/// details' information collector instead: "The relevant error-causing widget
/// was: Row  lib/foo.dart:123" for build errors, and for layout overflows "The
/// specific RenderFlex in question is: ... creator: Column <- Padding <- ...".
/// Those two are kept and everything else the collector offers is dropped, so
/// an overflow in the log names the asset rather than a paint stack.
///
/// The stack gets the same treatment. The logger prints its first eight
/// frames and for a framework error those are all framework — the app frame
/// that names the asset is the tenth or the thirtieth — so the app's own
/// frames are pulled out of the full trace and appended.
String describeFrameworkError(FlutterErrorDetails details) {
  final culprit = details.informationCollector
          ?.call()
          .map((n) => n.toStringDeep())
          .where((s) =>
              s.contains('error-causing widget') || s.contains('creator:'))
          .map((s) => s.length > kCulpritLineLimit
              ? '${s.substring(0, kCulpritLineLimit)}...'
              : s)
          .join('\n') ??
      '';
  final appFrames = appFramesOf(details.stack);
  return 'Flutter framework error: ${details.exceptionAsString()}'
      '${culprit.isEmpty ? '' : '\n$culprit'}'
      '${appFrames.isEmpty ? '' : '\napp frames:\n$appFrames'}';
}

/// The packages whose frames are worth printing: everything else in a
/// framework error's trace is Flutter's own machinery.
const List<String> kAppFramePackages = ['package:tfc', 'package:centroidx'];

/// At most this many app frames. The first few name the asset; past that the
/// trace is the route and the app shell, the same on every error.
const int kAppFrameLimit = 10;

/// The app's own frames from [stack], in order, at most [kAppFrameLimit].
///
/// Returns an empty string when [stack] is null or contains none — an error
/// raised entirely inside the framework has nothing of ours to point at, and
/// an empty section is better than a heading over nothing.
String appFramesOf(StackTrace? stack) {
  if (stack == null) return '';
  return stack
      .toString()
      .split('\n')
      .where((f) => kAppFramePackages.any(f.contains))
      .take(kAppFrameLimit)
      .join('\n');
}

/// This isolate's liveness clock. Global because [_startApp] and the
/// first-frame callback both need it and neither can be handed an argument.
RunnerLiveness? _liveness;

/// [args] are the Dart entrypoint arguments the Windows runner passes on every
/// engine start: `--engine-epoch=N` and `--engine-reason=...`. An RDP session
/// change destroys the engine and builds a new one, which is a whole new
/// isolate running this function again -- three of them inside one frozen
/// process on 2026-09-10, with nothing in either log to separate them. Now the
/// first thing the app does is say which generation it is and why.
void main(List<String> args) {
  final engineEpoch = EngineEpoch.fromArguments(args);

  // Ignore SIGPIPE so broken-pipe writes become IOExceptions instead of
  // killing the process.  The MCP HTTP server, OPC UA client, and pdfium
  // background isolate all perform native socket/pipe IO that can trigger
  // SIGPIPE when the remote end closes unexpectedly.
  if (Platform.isLinux || Platform.isMacOS) {
    try {
      ProcessSignal.sigpipe.watch().listen((_) {
        stderr.writeln('SIGPIPE received — broken pipe (ignored)');
      });
    } on SignalException {
      // flutter-elinux does not support signal watching
    }
  }

  final logFilePath = Platform.environment['CENTROID_LOG_FILE'];
  final debugMode = Platform.environment['CENTROID_STDOUT'] == '1' ||
      Platform.environment['CENTROID_STDOUT'] == 'true' ||
      logFilePath != null;

  // The Windows runner sets CENTROID_LOG_REDIRECTED once it has pointed
  // stdout/stderr at the log file *and* resynced the engine's streams to
  // match, at which point print() already reaches the file on its own.
  // Opening it here as well would write every line twice, so this direct
  // write is now only a fallback for runners that do not redirect.
  final runnerRedirectsOutput = Platform.environment['CENTROID_LOG_REDIRECTED'] == '1';

  if (debugMode && logFilePath != null && !runnerRedirectsOutput) {
    try {
      _logFile = File(logFilePath).openSync(mode: FileMode.append);
    } catch (_) {}
  }

  initLogConfig();

  // Route framework errors into the app logger, which writes to
  // CENTROID_LOG_FILE. Without this they go only to Flutter's default handler
  // and out on stdout -- and stdout does not survive the redirect in
  // run-hmi.ps1, so a red screen left no trace anywhere on disk and could only
  // be read off the operator's monitor.
  //
  // presentError is still called, so the red screen and the debug console
  // behave exactly as before; this only adds a copy that persists.
  final priorOnError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    logger.e(describeFrameworkError(details),
        error: details.exception, stackTrace: details.stack);
    if (priorOnError != null) priorOnError(details);
  };

  if (_enableMarionette) {
    initMarionette();
    _startLiveness(engineEpoch);
    _startApp(debugMode);
  } else {
    runZonedGuarded(
      () {
        WidgetsFlutterBinding.ensureInitialized();
        _startLiveness(engineEpoch);
        _startApp(debugMode);
      },
      (error, stackTrace) {
        // The logger, not stderr. FlutterError.onError above was routed here
        // precisely so a red screen persists to disk; its asynchronous twin
        // was left writing to stderr, which in a windowed MSIX build with no
        // console goes nowhere at all. An unhandled async error is the single
        // most valuable line this app can produce and it was being discarded.
        logger.e('Unhandled async error: $error', error: error, stackTrace: stackTrace);
      },
      zoneSpecification: debugMode ? ZoneSpecification(print: _debugPrint) : null,
    );
  }
}

/// Arms the UI isolate's own clock.
///
/// Deliberately the FIRST thing done once a binding exists, and before any of
/// the startup work in [_startApp]: the most informative stamp is the one that
/// never arrives, and it can only fail to arrive from a timer that was armed.
/// A station whose `main()` hangs loading preferences now produces "UI isolate
/// NEVER stamped" in hmi-runner.log instead of nothing at all.
void _startLiveness(EngineEpoch epoch) {
  final liveness = RunnerLiveness(epoch: epoch, logger: logger);
  _liveness = liveness;
  liveness.start();
}

/// All initialisation that depends on a Flutter binding being present,
/// through to [runApp].  Called from the same zone that initialised the
/// binding so that Flutter's zone-check in [runApp] is satisfied.
Future<void> _startApp([bool debugMode = false]) async {
  if (debugMode) {
    print('[CentroidX] v${Platform.version} starting...');
    print('[CentroidX] Platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    print('[CentroidX] Executable: ${Platform.resolvedExecutable}');
    print('[CentroidX] Environment: CENTROID_STDOUT=${Platform.environment['CENTROID_STDOUT'] ?? 'unset'}, '
        'CENTROID_LOG_FILE=${Platform.environment['CENTROID_LOG_FILE'] ?? 'unset'}, '
        'CENTROID_LOG_LEVEL=${Platform.environment['CENTROID_LOG_LEVEL'] ?? 'unset'}, '
        'CENTROID_OPCUA_LOG_LEVEL=${Platform.environment['CENTROID_OPCUA_LOG_LEVEL'] ?? 'unset'}');
  }

  if (kKnowledgeEnabled) {
    // pdfium is only used by the tech-doc/drawing viewers.
    pdfrxFlutterInitialize();
  }
  AmplifySecureStorageDart.registerWith();
  if (Platform.isWindows || Platform.isMacOS) {
    // Use the properly branded flutter_secure_storage implementation on
    // Windows and macOS; AwsSecureStorage (amplify, keychain service name
    // "com.amplify.awsCognitoAuthPlugin") remains only the Linux/eLinux
    // fallback inside SecureStorage.getInstance(). On macOS existing
    // installs have their secrets under the amplify service name, so wrap
    // the new storage in a one-time migration that falls back to (and
    // copies from) the old storage on a read miss.
    SecureStorage.setInstance(Platform.isMacOS ? MacOsMigratingSecureStorage() : OtherSecureStorage());
  }

  // Register your custom asset type
  // AssetRegistry.registerFromJsonFactory<ChecklistsConfig>(ChecklistsConfig.fromJson);
  // AssetRegistry.registerDefaultFactory<ChecklistsConfig>(ChecklistsConfig.preview);

  // AssetRegistry.registerFromJsonFactory<SpeedBatcherConfig>(SpeedBatcherConfig.fromJson);
  // AssetRegistry.registerDefaultFactory<SpeedBatcherConfig>(SpeedBatcherConfig.preview);

  // AssetRegistry.registerFromJsonFactory<AirCabConfig>(AirCabConfig.fromJson);
  // AssetRegistry.registerDefaultFactory<AirCabConfig>(AirCabConfig.preview);

  // AssetRegistry.registerFromJsonFactory<ElCabConfig>(ElCabConfig.fromJson);
  // AssetRegistry.registerDefaultFactory<ElCabConfig>(ElCabConfig.preview);

  // AssetRegistry.registerFromJsonFactory<RecipesConfig>(RecipesConfig.fromJson);
  // AssetRegistry.registerDefaultFactory<RecipesConfig>(RecipesConfig.preview);

  // AssetRegistry.registerFromJsonFactory<GateStatusConfig>(GateStatusConfig.fromJson);
  // AssetRegistry.registerDefaultFactory<GateStatusConfig>(GateStatusConfig.preview);

  final registry = RouteRegistry();

  // This is not ideal, if a second HMI adds a page, we will need to restart the app twice
  // Before `runApp`, so there is no `ProviderScope` to read
  // `localPreferencesProvider` from — the factory is the one construction
  // point spec §6 asks for, enforced by
  // `scripts/check-preferences-construction.sh`.
  final prefs = createDeviceLocalPreferences();
  final pageManager = PageManager(pages: {}, prefs: prefs);
  await pageManager.load();

  // systemd forgets runtime NTP servers on every restart and offers no way
  // to persist them over D-Bus, so the HMI is what carries the operator's
  // choice across a reboot. Fire-and-forget: a station without the polkit
  // rule will be refused, and that must not hold up or break startup.
  if (Platform.isLinux) {
    unawaited(applyStoredNtpServers(
      prefs: prefs,
      connect: () => DBusTimeSync(DBusClient.system()),
    ).then((applied) {
      if (applied != null) {
        logger.i('Re-applied ${applied.length} stored NTP server(s)');
      }
    }).catchError((Object e) {
      logger.w('Could not re-apply stored NTP servers: $e');
      return null;
    }));
  }

  final extraMenuItems = pageManager.getRootMenuItems();

  // The first menu, composed by the same function the provider will use.
  // `registry` is seeded here because the boot sequence below — the route
  // table and the startup-path resolution — runs before there is a
  // `ProviderScope` to read `menuTreeProvider` from. From the first frame
  // onwards the provider owns this list and rewrites it whenever the pages
  // change; nothing else may.
  final topLevelMenuItems = _composeTopLevelMenu(pageManager);
  registry.replaceMenu(
    topLevelMenuItems,
    declareGroups: () {
      installRaisedRoutes();
      declareMenuRouteGroups(topLevelMenuItems);
    },
  );

  final locationBuilder = createLocationBuilder(
    extraMenuItems,
    pagePaths: pageManager.pages.keys,
  );

  // Which page this station opens on, chosen per-station in the page
  // editor's Pages dialog. Device-local — stations on one database front
  // different equipment — and validated against the assembled menu so a
  // startup page deleted or unpublished since it was picked falls back
  // to '/'.
  final storedStartupUrl = await readStartupUrl(prefs);
  final startupPath = resolveStartupPath(
    storedStartupUrl,
    menuItems: topLevelMenuItems,
  );
  // One line that settles "why didn't it open on my page": whether the
  // choice ever reached this device's store, and whether validation kept it.
  logger.i(startupPath == storedStartupUrl
      ? 'Startup page: $startupPath'
      : 'Startup page: $storedStartupUrl is stored but no longer routable '
          '— falling back to $startupPath');

  // Paths at which Beamer should clear its beaming history. Landing on a
  // top-level destination means there is nowhere to go "back" to, so we drop
  // the accumulated history there — otherwise `canBeamBack` stays true and the
  // app-bar keeps a stale back-arrow on Home. The Advanced *section* item
  // ('/advanced') is a menu grouping, not a routable destination, so it is
  // excluded; its sub-pages are nested (not in this top-level list), which
  // keeps back navigation WITHIN Advanced working. Membership matches
  // isTopLevelDestinationPath, not a string prefix — a top-level page that
  // happens to slug to '/advanced-line' still clears. `/` is always
  // included so a deleted Home still clears.
  final topLevelPaths = <String>{
    '/',
    for (final item in topLevelMenuItems)
      if (item.path != null && item.path != '/advanced') item.path!,
  };

  // The channel is re-read on every check, so a change in Preferences takes
  // effect without a restart. buildGitSha comes from CI (--dart-define) and
  // lets the latest channel tell whether the running main build is stale.
  GitHubReleaseStore buildReleaseStore() => GitHubReleaseStore(
        owner: 'centroid-is',
        repo: 'tfc-hmi',
        channel: readUpdateChannel,
        buildSha: buildGitSha,
      );
  final upgrader = Upgrader(
    storeController: UpgraderStoreController(
      onWindows: buildReleaseStore,
      onLinux: buildReleaseStore,
      onMacOS: buildReleaseStore,
    ),
    debugLogging: true,
  );

  runApp(ProviderScope(
    overrides: [
      // The page manager above was loaded from local SharedPreferences in
      // 2.3 ms and used to build the menus; hand it to the app instead of
      // dropping it. `pageManagerProvider` still fetches the database copy
      // and still wins the moment it arrives — this only decides what the
      // plant page shows while that is outstanding. Without it a server that
      // is powered off or behind a cut link leaves the page blank for the ten
      // seconds the connection takes to give up.
      bootstrapPageManagerProvider.overrideWithValue(pageManager),
      // How `menuTreeProvider` assembles the whole top-level menu. The
      // composition lives here in the shell because it knows the Advanced
      // entry list and the platform flags; the provider lives in the package
      // and cannot reach back for them. Injecting it is what lets the menu be
      // recomposed whenever the pages change instead of once at boot — see
      // the pipeline note in `lib/providers/menu.dart`.
      //
      // One composition, two callers: the boot sequence above builds the
      // first menu with the same function, so what the provider produces on
      // its first build is what the app already had.
      menuComposerProvider.overrideWithValue(_composeTopLevelMenu),
      // What the router can serve. The menu recomposes when the database's
      // copy of the pages arrives; the route table does not, because it is
      // built once above. Intersecting the two is what stops a page created
      // on another station appearing in the menu here with nothing behind it
      // — the operator would tap it and get "not found". It still takes a
      // restart for such a page to become reachable, which is the same as
      // before this work and is stated on `routablePathsProvider`.
      routablePathsProvider.overrideWithValue(
        locationBuilder.routes.keys.whereType<String>().toSet(),
      ),
    ],
    child: UpgradeAlert(
      upgrader: upgrader,
      onUpdate: () {
        final targetVersion = upgrader.state.versionInfo?.appStoreVersion?.toString() ?? '';
        // The update itself is done by forking the bundled centroidx-manager,
        // which waits for this process to exit, installs, and relaunches --
        // so the success path exits and never comes back. startManagerUpdate
        // owns the other path: if the manager will not start, it says so
        // rather than leaving the operator looking at an app that did
        // nothing.
        unawaited(startManagerUpdate(
          targetVersion: targetVersion,
          readChannel: readUpdateChannel,
          launch: (version, channel) => managerLauncher.launchForUpdate(
            version: version,
            channel: channel,
            flutterPid: pid,
          ),
          // Reaches the log file; stderr in a windowed MSIX build does not,
          // and "the updater would not start" is precisely the thing an
          // operator reports as "the update button does nothing".
          log: logger.w,
          show: (message) =>
              globalScaffoldMessengerKey.currentState?.showSnackBar(
            SnackBar(
              content: Text(message),
              duration: const Duration(seconds: 10),
            ),
          ),
          onHandedOff: () => exit(0),
        ));
        return false;
      },
      child: MyApp(
        locationBuilder: locationBuilder,
        clearHistoryOn: topLevelPaths,
        initialPath: startupPath,
      ),
    ),
  ));

  // Startup is not "runApp returned", and it is not the first frame either.
  // The work an engine rebuild must not interrupt is the OPC UA bring-up:
  // the 2026-09-10 teardown landed 35 s in, while this generation was still
  // on "ST101.PSU attempt 2", and abandoned the half-open clients. So the
  // boundary reported to the runner is "every client has a clock watching it
  // or has said why it cannot" -- see StateMan.connectionsSettled.
  SchedulerBinding.instance.addPostFrameCallback((_) {
    unawaited(_reportStartupComplete());
  });
}

/// Waits for this generation's connections to settle, then tells the runner.
///
/// Best effort by construction: every failure path still reports, because a
/// runner that never hears "startup complete" holds a queued session-change
/// rebuild until its own backstop timeout, and an operator who has just
/// reconnected would be looking at a stale renderer in the meantime.
Future<void> _reportStartupComplete() async {
  final liveness = _liveness;
  if (liveness == null) return;
  try {
    final context = globalScaffoldMessengerKey.currentContext;
    if (context != null) {
      final container = ProviderScope.containerOf(context, listen: false);
      final stateMan = await container.read(stateManProvider.future);
      await stateMan.connectionsSettled();
    }
  } catch (error) {
    logger.w('Could not wait for connections to settle before reporting '
        'startup complete: $error');
  }
  liveness.reportStartupComplete();
}

Completer<DBusClient> dbusCompleter = Completer();

final managerLauncher = ManagerLauncher(
  assetLoader: (key) async {
    final bd = await rootBundle.load(key);
    return bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);
  },
);

/// Builds the app's route table.
///
/// [extraMenuItems] are the reachable (published) pages from the page
/// manager. [pagePaths] is every page path the manager knows, reachable or
/// not: paths in it that end up without a route — unpublished drafts, or
/// children of a draft section — are refused by redirecting to the fallback
/// page instead of dead-ending on "not found".
RoutesLocationBuilder createLocationBuilder(
  List<MenuItem> extraMenuItems, {
  Iterable<String> pagePaths = const [],
}) {
  // Route groups are declared by `RouteRegistry.replaceMenu`, which the boot
  // sequence calls once and `menuTreeProvider` calls on every recomposition —
  // clear, built-ins, then the operator's pages, in that order inside one
  // method so the layering cannot be assembled wrong at a call site. Nothing
  // is declared here: doing it in two places is how the menu and the route
  // table start disagreeing about which entries are locked.

  // Wraps a raised route's child in its gate. Two things here are deliberate:
  //
  //  - The `!`. A path missing from kRaisedRoutes throws when the route is
  //    built, rather than resolving to `operate` and quietly leaving the route
  //    open. A loud failure at boot beats a silent open door.
  //  - routeAllowedWhenNobodyCanSignIn(path), not a boolean at each call
  //    site. The menu badge asks the same function, so the one route that stays
  //    open on a station nobody can sign in at cannot drift into a lock icon on
  //    a page that opens, or the reverse. Exactly one place knows which route
  //    that is, and it is lib/access_routes.dart. The other half of that
  //    condition — whether a gateway panel's link can carry a sign-in — is not
  //    passed from here at all: AccessGate watches relayCanAuthenticateProvider
  //    itself, and the badge watches the same one.
  Widget gated(String path, String title, Widget child) => AccessGate(
        group: kRaisedRoutes[path]!,
        title: title,
        allowWhenNobodyCanSignIn: routeAllowedWhenNobodyCanSignIn(path),
        child: child,
      );

  // Nine routes are gated, and only nine. Two of them sit at `users`.
  // '/advanced/audit-trail' is raised for what it *displays* rather than what
  // it writes: the trail is every write anybody ever made, with old and new
  // values, so it sits beside the roles that govern it. '/advanced/access'
  // reads and writes the role table and the account list, which is the
  // definition of `users`-grade — and its store gates the writes but leaves the
  // reads ungated on purpose, so this gate is the whole of the enforcement for
  // reading it. Left open on purpose:
  //
  //  - '/advanced/about-linux', whose gate is on its controls rather than on
  //    the route. That line used to read "reads system information and changes
  //    nothing", which stopped being true when the Date & Time section landed:
  //    the page sets the clock, the timezone and the NTP servers over D-Bus,
  //    and Reboot / Power Off had only a confirm dialog in front of them. None
  //    of those is a tag or a preference, so neither `GuardedStateMan` nor
  //    `GuardedPreferences` covered them and they reached polkit — which the
  //    station rule grants the container unconditionally — with nothing having
  //    asked who was standing at the panel.
  //
  //    Raising the route was rejected: reading the hostname, the addresses and
  //    whether the clock is synchronised is operate-level work, and a locked
  //    page is how a station whose historised samples are timestamped an hour
  //    out goes unnoticed. So the four writing controls require `administer`
  //    through `guardGroupAction` (`lib/widgets/group_access_guard.dart`) and
  //    the reading half is unguarded, which is the split
  //    `system_clock_section.dart` was already documented as having and now
  //    actually enforces.
  //
  //    The cost, stated rather than softened: this is a page-local gate, so a
  //    future control added to About Linux does not inherit it the way a route
  //    gate would have. `SystemClockSection.settingsAllowed` is required with
  //    no default for that reason — the compiler is what catches the next
  //    caller.
  //  - '/advanced/history-view', AppRoutes.historyView and
  //    AppRoutes.alarmView are read surfaces, and read permissions are
  //    explicitly out of scope (docs/access-control-spec.md §Scope, §11).
  //
  //    '/advanced/knowledge-base' was on that list until 2026-08-30 and is
  //    now gated at `configure`.
  //    docs/access-control-write-path-sweep.md §3.1 found three raw-Drift
  //    index classes behind that page — twenty-six statements — and a caller
  //    that rewrites `page_editor_data`, the key the configure-gated page
  //    editor saves, so it was never the read surface this comment called it.
  //    The cost was accepted deliberately and is not softened here: an
  //    anonymous operator can no longer read a technical document or browse
  //    PLC code at the panel, which on a plant floor means finding somebody
  //    with a `configure` account or walking. It was chosen over leaving a
  //    write path around the page editor's gate. The drawings overlay below
  //    (:763-781) is a different surface — not this route, read-only — so a
  //    drawing is still available on the page an operator is standing at.
  //    Note that '/advanced/history-view' had to be corrected in this same
  //    comment for the same reason: both were called read surfaces because
  //    the menu label was read instead of the call sites.
  //
  //    One caveat, so this comment is not read as a clean bill of health:
  //    the history view is not purely a read surface. It deletes directly
  //    through Drift, in two places with two different accessors —
  //    lib/pages/history_view.dart:1108 `adb.deleteHistoryView(v.id)` from the
  //    button at :722, and :1165 `dbWrap.db.deleteHistoryViewPeriod(p.id)`
  //    from the button at :1074 — so an anonymous session can delete a saved
  //    view or a period. Grepping for one does not find the other.
  //
  //    Phase 3 will not catch them: it wraps StateMan.write and
  //    PreferencesApi.set*, and these are neither. They are now the fourth
  //    entry in docs/access-control-spec.md §6's bypass list, which said
  //    three until 2026-08-29. Gating the *route* is the wrong fix — it would
  //    block reading history, which is operate-level work; the fix belongs at
  //    the controls. Undecided.
  //  - AppRoutes.firstUser. Gating commissioning behind a sign-in on a station
  //    that has no users yet is the deadlock the first-user design exists to
  //    avoid.
  //  - Every page-manager page, which arrives through addRoute below and is
  //    not gated: those are the plant's own pages and are `operate` by
  //    definition. That sentence is what "nothing on the floor changes" means.
  final routes = {
    // '/': (context, state, args) => BeamPage(
    //       // this will be replaced most likely
    //       key: const ValueKey('/'),
    //       title: 'Home',
    //       child: Consumer(
    //         builder: (context, ref, _) {
    //           return AssetView(
    //             pageName: 'Home',
    //           );
    //         },
    //       ),
    //     ),
    '/advanced/ip-settings': (context, state, args) => BeamPage(
          key: const ValueKey('/advanced/ip-settings'),
          title: 'IP Settings',
          // Main's DbusGate inside the access gate: the two are different
          // questions in sequence — may this session open the page at all,
          // and then has the D-Bus login happened. Gate first, so an operator
          // without `administer` meets the lock rather than a login form for
          // a page they cannot open.
          child: gated(
            '/advanced/ip-settings',
            'IP Settings',
            DbusGate(
              title: 'IP Settings',
              shared: dbusCompleter,
              builder: (context, client, _) => IpSettingsPage(dbusClient: client),
            ),
          ),
        ),
    '/advanced/about-linux': (context, state, args) => BeamPage(
          key: const ValueKey('/advanced/about-linux'),
          title: 'About Linux',
          child: DbusGate(
            title: 'About Linux',
            shared: dbusCompleter,
            builder: (context, client, _) => AboutLinuxPage(dbusClient: client),
          ),
        ),
    '/advanced/page-editor': (context, state, args) => BeamPage(
        key: const ValueKey('/advanced/page-editor'),
        title: 'Page Editor',
        child: gated(
            '/advanced/page-editor', 'Page Editor', PageEditor(proposalData: args is String ? args : null))),
    '/advanced/preferences': (context, state, args) => BeamPage(
        key: const ValueKey('/advanced/preferences'),
        title: 'Preferences',
        child: gated('/advanced/preferences', 'Preferences', PreferencesPage())),
    '/advanced/alarm-editor': (context, state, args) => BeamPage(
        key: const ValueKey('/advanced/alarm-editor'),
        title: 'Alarm Editor',
        child: gated(
            '/advanced/alarm-editor', 'Alarm Editor', AlarmEditorPage(proposalData: args is String ? args : null))),
    AppRoutes.historyView: (context, state, args) =>
        BeamPage(key: const ValueKey(AppRoutes.historyView), title: 'History View', child: HistoryViewPage()),
    // History View lives at the top level now; the old address keeps working
    // for bookmarks and pages that link to it.
    '/advanced/history-view': (context, state, args) =>
        BeamPage(key: const ValueKey('/advanced/history-view'), title: 'History View', child: HistoryViewPage()),
    '/advanced/server-config': (context, state, args) => BeamPage(
        key: const ValueKey('/advanced/server-config'),
        title: 'Server Config',
        child: gated('/advanced/server-config', 'Server Config', ServerConfigPage())),
    '/advanced/key-repository': (context, state, args) => BeamPage(
        key: const ValueKey('/advanced/key-repository'),
        title: 'Key Repository',
        child: gated('/advanced/key-repository', 'Key Repository',
            KeyRepositoryPage(proposalData: args is String ? args : null))),
    AppRoutes.alarmView: (context, state, args) =>
        BeamPage(key: const ValueKey('/alarm-view'), title: 'Alarm View', child: AlarmViewPage()),
    // Registered unconditionally. The page itself decides whether the window
    // is open (firstUserWindowOpenProvider); gating the *route* on a database
    // read would 404 the address while the connection was still coming up,
    // which is exactly when somebody is commissioning the station.
    AppRoutes.firstUser: (context, state, args) =>
        BeamPage(key: const ValueKey(AppRoutes.firstUser), title: 'First account', child: const FirstUserPage()),
    '/advanced/audit-trail': (context, state, args) => BeamPage(
        key: const ValueKey('/advanced/audit-trail'),
        title: 'Audit Trail',
        child: gated('/advanced/audit-trail', 'Audit Trail', const AuditTrailPage())),
    '/advanced/access': (context, state, args) => BeamPage(
        key: const ValueKey('/advanced/access'),
        title: 'Access',
        child: gated('/advanced/access', 'Access', const AccessAdminPage())),
  };

  // Statement-level const guard rather than a collection-if inside the map
  // literal: AOT tree-shaking reliably folds the former, so a flag-off
  // build drops TechDocLibraryPage and everything it pulls in.
  if (kKnowledgeEnabled) {
    routes['/advanced/knowledge-base'] = (context, state, args) => BeamPage(
        key: const ValueKey('/advanced/knowledge-base'),
        title: 'Knowledge Base',
        // Gated inside the `if`, not outside it, so a flag-off build still
        // tree-shakes TechDocLibraryPage.
        child: gated('/advanced/knowledge-base', 'Knowledge Base', const TechDocLibraryPage()));
  }

  addRoute(MenuItem menuItem) {
    // Register route for this item if it has a non-empty path
    if (menuItem.path != null && menuItem.path!.isNotEmpty) {
      routes[menuItem.path!] = (context, state, args) => BeamPage(
            key: ValueKey(menuItem.path!),
            title: menuItem.label,
            // The enforcement point for the plant's own pages. Until this
            // landed, a page raised above `operate` in the page editor was
            // dropped from the menu and still opened to anyone who typed its
            // URL — hiding was the whole of the guard, which is the failure
            // mode the spec names. The gate also asks the page whitelist.
            //
            // Free on an unrestricted station: an undeclared page short-
            // circuits on `operate` and a session with no whitelist admits
            // every path, so the gate returns the child with nothing around
            // it, exactly as before.
            child: PageAccessGate(
              path: menuItem.path!,
              title: menuItem.label,
              child: Consumer(
                builder: (context, ref, _) {
                  return AssetView(pageName: menuItem.path!);
                },
              ),
            ),
          );
    }
    // Recurse into all children
    for (final child in menuItem.children) {
      addRoute(child);
    }
  }

  for (final menuItem in extraMenuItems) {
    addRoute(menuItem);
  }

  // '/' is an ordinary page and may have been deleted; the initial route must
  // still land somewhere. First reachable page if there is one — when no
  // pages exist at all the page manager has already regenerated the default
  // Home, so this only stays null when every page is an unpublished draft.
  final fallback = routes.containsKey('/') ? '/' : firstMenuPath(extraMenuItems);
  if (fallback != null) {
    if (!routes.containsKey('/')) {
      routes['/'] = (context, state, args) => BeamPage(
            key: const ValueKey('/'),
            title: 'Home',
            // `from` is what stops this stub -- which Beamer keeps mounted
            // underneath every page on a station with no Home -- from beaming
            // away from whatever the operator is looking at. See
            // `route_redirect.dart`: this is the widget that painted the panel
            // white for the whole of a signed-out session.
            child: RouteRedirect(from: '/', target: fallback),
          );
    }
    // Refuse direct navigation to pages that exist but are not reachable
    // (unpublished drafts and their subtrees).
    for (final path in pagePaths) {
      if (path.isEmpty || routes.containsKey(path)) continue;
      routes[path] = (context, state, args) => BeamPage(
            key: ValueKey('redirect-$path'),
            title: 'Redirecting',
            child: RouteRedirect(from: path, target: fallback),
          );
    }
  }

  return RoutesLocationBuilder(routes: routes);
}

/// Wires the elicitation UI handler into the MCP bridge so that write-tool
/// proposals trigger a confirm/deny dialog instead of auto-accepting.
///
/// The handler uses [navigatorKeyProvider] to obtain a valid [BuildContext]
/// below the app [Navigator], then shows an [ElicitationDialog] and
/// returns the user's response as an [ElicitResult].
void _wireElicitationHandler(WidgetRef ref) {
  final bridge = ref.read(mcpBridgeProvider);
  // Only set once — avoid replacing on every rebuild.
  if (bridge.elicitationHandler != null) return;

  bridge.elicitationHandler = (request) async {
    final navKey = ref.read(navigatorKeyProvider);
    final ctx = navKey?.currentContext;
    if (ctx == null || !ctx.mounted) {
      // No navigator context available — fall back to auto-accept.
      return const ElicitResult(action: 'accept', content: {'confirm': true});
    }
    final completer = Completer<ElicitResult>();
    showElicitationDialog(
      context: ctx,
      request: request,
      completer: completer,
    );
    return completer.future;
  };
}

class MyApp extends ConsumerWidget {
  MyApp({
    super.key,
    required RoutesLocationBuilder locationBuilder,
    Set<String> clearHistoryOn = const <String>{},
    String initialPath = '/',
  }) : routerDelegate = BeamerDelegate(
          initialPath: initialPath,
          notFoundPage: const BeamPage(child: PageNotFound()),
          transitionDelegate: MyNoAnimationTransitionDelegate(),
          clearBeamingHistoryOn: clearHistoryOn,
          locationBuilder: (routeInformation, context) => locationBuilder(routeInformation, context),
        ),
        // Beamer only swaps the incoming route for [initialPath] when that
        // route is exactly '/'. The eLinux embedder reports '' instead, so
        // without this normalization every station booted Home regardless
        // of the chosen startup page. See normalizeInitialPlatformRoute.
        routeInformationProvider = PlatformRouteInformationProvider(
          initialRouteInformation: RouteInformation(
            uri: Uri.parse(normalizeInitialPlatformRoute(
                WidgetsBinding.instance.platformDispatcher.defaultRouteName)),
          ),
        ) {
    // Marionette route logger: emits [ROUTE] /path log entries so agents
    // can verify navigation via getLogs instead of taking screenshots.
    // The const _enableMarionette guard ensures the MarionetteRouteLogger
    // import and this code path are tree-shaken from production builds.
    if (_enableMarionette) {
      MarionetteRouteLogger(routerDelegate);
    }

    // A docked side pane belongs to the page that opened it, but it lives in
    // the ROOT overlay, so nothing about leaving that page removes it: it
    // follows the operator to the next one, still showing a device that is no
    // longer on screen.
    //
    // Hung off the router rather than the navigation bar. The bar is only one
    // way to leave -- the back button, beamBack from a button on the page, a
    // deep link and the route guards all bypass it, and each would strand a
    // pane. One listener on the delegate covers every one of them.
    //
    // Immediate: the page underneath is already going, so an exit glide would
    // play over a page that is leaving anyway. It also lets an asset's
    // dispose() tear down what the pane was reading in the same frame, which
    // the glide made unsafe.
    routerDelegate.addListener(() {
      final path = routerDelegate.configuration.location;
      if (path == _lastPanePath) return;
      _lastPanePath = path;
      closeSidePane(immediate: true);
      closeAllFloatingDialogs();
    });
  }

  /// Last location the pane watcher saw, so a delegate rebuild that does not
  /// change the route leaves an open pane alone.
  String? _lastPanePath;

  final BeamerDelegate routerDelegate;

  /// Feeds the router its first route, normalized so an embedder that
  /// reports no route (eLinux reports '') still lands on [initialPath].
  final PlatformRouteInformationProvider routeInformationProvider;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeAsync = ref.watch(themeNotifierProvider);
    final schemeAsync = ref.watch(colorSchemeNotifierProvider);
    final (light, dark) = themesForScheme(
        schemeAsync.valueOrNull ?? AppColorScheme.solarized);

    // Initialize MCP server lifecycle management
    ref.watch(mcpServerLifecycleProvider);

    // Initialize chat lifecycle management (MCP bridge connect/disconnect).
    // Const-guarded so flag-off builds tree-shake the chat/LLM graph.
    if (kChatEnabled) {
      ref.watch(chatLifecycleProvider);
    }

    // Expose the BeamerDelegate's navigator key so overlay widgets
    // (chat, drawings, FAB) can show dialogs / access Navigator.
    // Defer to avoid modifying provider state during build.
    Future.microtask(() {
      ref.read(navigatorKeyProvider.notifier).state = routerDelegate.navigatorKey;
    });

    // Wire elicitation UI dialog into MCP bridge so write-tool proposals
    // show a confirm/deny dialog instead of auto-accepting. Chat-only:
    // the handler serves the in-process MCP client; external SSE clients
    // run their own elicitation UI.
    if (kChatEnabled) {
      _wireElicitationHandler(ref);
    }

    final app = MaterialApp.router(
      title: 'CentroidX',
      scaffoldMessengerKey: globalScaffoldMessengerKey,
      themeMode: themeAsync.when(
        data: (themeMode) => themeMode,
        loading: () => ThemeMode.system,
        error: (_, __) => ThemeMode.system,
      ),
      theme: light,
      darkTheme: dark,
      routerDelegate: routerDelegate,
      routeInformationParser: BeamerParser(),
      routeInformationProvider: routeInformationProvider,
      builder: (context, navigatorChild) {
        // Everything the operator sees, under one RepaintBoundary, so the
        // MCP `screenshot_window` tool can photograph it -- and with a slot
        // beside it where `render_page` draws a page offscreen. Here rather
        // than lower down because this is the highest point that still has
        // the theme, and the lowest that still has the overlays (proposal
        // banner, chat) which are part of the picture.
        return AppCaptureScope(
          child: Consumer(
            builder: (context, ref, _) {
              final drawingVisible = kKnowledgeEnabled && ref.watch(drawingVisibleProvider);
              final chatVisible = kChatEnabled && ref.watch(chatVisibleProvider);
              // Use select() to only rebuild when the SSE server running
              // state or port changes, NOT on every McpBridgeNotifier
              // notification (tool list updates, connection state
              // transitions, etc.).
              final mcpRunning = ref.watch(mcpBridgeProvider.select(
                (b) => b.isRunning,
              ));
              final mcpPort = ref.watch(mcpBridgeProvider.select(
                (b) => b.currentState.port,
              ));
              final chatEnabled = kChatEnabled && (ref.watch(mcpChatEnabledProvider).valueOrNull ?? false);

              return Stack(
                children: [
                  navigatorChild!, // existing HMI content
                  const ProposalBanner(),
                  // Says the session ended, once, from the one place in the
                  // app that is mounted exactly once. A session ending is
                  // otherwise entirely silent, and a silently signed-out panel
                  // is indistinguishable from a hung one to the person
                  // standing at it. Renders nothing until it fires.
                  const AccessSessionEndedNotice(),
                  if (kKnowledgeEnabled && drawingVisible) const DrawingOverlay(),
                  if (kChatEnabled && chatEnabled && chatVisible) const ChatOverlay(),
                  // Chat FAB and MCP indicator — hidden when a nav
                  // dropdown popup is open so the FAB does not render
                  // on top of the menu (the FAB lives above the
                  // Navigator's Overlay in the widget tree).
                  ValueListenableBuilder<bool>(
                    valueListenable: NavDropdown.isAnyMenuOpen,
                    builder: (context, navMenuOpen, _) {
                      return Stack(
                        children: [
                          // Chat FAB (when chat enabled but overlay closed)
                          if (kChatEnabled && chatEnabled && !chatVisible && !navMenuOpen)
                            Positioned(
                              bottom: 90,
                              right: 16,
                              child: FloatingActionButton(
                                key: const ValueKey<String>('chat-fab'),
                                onPressed: () => ref.read(chatVisibleProvider.notifier).state = true,
                                // tooltip removed: MaterialApp.builder is above
                                // Navigator's Overlay, so Tooltip crashes with
                                // "No Overlay widget found".
                                tooltip: null,
                                // heroTag disabled: Hero requires a Navigator
                                // ancestor, but this FAB is above the Navigator
                                // in the widget tree (MaterialApp.builder Stack).
                                heroTag: null,
                                child: const Icon(Icons.chat),
                              ),
                            ),
                          // MCP server status indicator (debug only). Under the
                          // logo, top right: at the bottom it sat on the last nav
                          // destination below ~1100 px wide, and just above the
                          // bar it covered whatever a page keeps in its bottom
                          // right corner (the key repository's Export button).
                          if (kDebugMode && mcpRunning && !navMenuOpen)
                            Positioned(
                              top: 58,
                              right: 8,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.green.withValues(alpha: 0.9),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.hub, color: Colors.white, size: 14),
                                    const SizedBox(width: 4),
                                    Text(
                                      'MCP :${mcpPort ?? '?'}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ],
              );
            },
          ),
        );
      },
    );

    // Escape drops focus from whatever text field is up, which is what takes
    // the flutter-elinux on-screen keyboard back down. Above everything, so
    // it covers every page, pane and dialog.
    return OnscreenKeyboardEscape(
      child: BeamerProvider(routerDelegate: routerDelegate, child: app),
    );
  }
}

/// How the whole top-level menu is assembled from the page manager.
///
/// The one composition, called from two places: the boot sequence, which needs
/// a menu before there is a `ProviderScope`, and `menuComposerProvider`, which
/// is how `menuTreeProvider` recomposes it whenever the pages change. Two
/// copies of this would be two menus that drift apart the first time either
/// is edited.
///
/// It lives in the shell rather than in the package because it knows the
/// Advanced entry list, the platform flags and the built-ins; the provider
/// lives in the package and is handed this as a callback.
List<MenuItem> _composeTopLevelMenu(PageManager pageManager) {
  // Home comes from the page manager like every other page — it is not pinned
  // here, so deleting it in the page editor really removes it. Built-ins
  // (Alarm View, History View) and the pages share one persisted top-level
  // order, editable in the page editor's Pages dialog.
  final items = buildTopLevelMenuItems(
    isLinux: Platform.isLinux,
    pageMenuItems: pageManager.getRootMenuItems(),
    // History View sits under Advanced unless the operator promoted it to the
    // top level in the page editor (recorded in the top-level order).
    historyAtTopLevel: historyViewIsTopLevel(pageManager.topLevelOrder),
  );
  // Then the order arranged in the page editor — built-ins included. No stored
  // order leaves the composition order above untouched. Ordering happens here,
  // before any visibility filtering, so the two stay separate concerns.
  pageManager.sortTopLevel(items);
  return items;
}

/// The app, in gateway mode, dialling the bench — and the pumping discipline
/// a real socket forces on a widget test.
///
/// ## What is real here
///
/// Everything below `lib/providers/`. The container is built with the app's
/// own providers and the same four overrides a station's boot would make from
/// its environment: the device-local preference store (in memory, holding a
/// gateway-mode `GatewayConfig` pointing at the bench's port), the station
/// name, and a `stateManFactoryProvider` that throws — so a page that reached
/// for a LOCAL StateMan would fail loudly instead of quietly opening an OPC UA
/// session beside the relay. `stateManProvider` therefore builds a real
/// `GatewayStateMan` over a real `RemoteStateMan`; `preferencesProvider` is
/// the real `RelayedPreferences`; the access, audit, template and config
/// stores are the real relayed ones; `databaseProvider` answers null because
/// that is what it answers in gateway mode. Sign-in goes through
/// `accessSessionProvider.signIn`, which is `session.login` on the wire.
///
/// ## Why every step is inside `tester.runAsync`
///
/// `testWidgets` runs its body under `FakeAsync`: timers are virtual and the
/// real event loop does not turn, so a `Future` completed by a socket read
/// never completes and `pumpAndSettle` spins on a spinner forever.
/// `test/providers/gateway_access_route_test.dart` avoids this by never being a
/// widget test. These cases ARE widget tests — the claim is about what the
/// page renders — so they run inside [WidgetTester.runAsync], where the real
/// loop runs, and wait with [untilFound]: pump a frame, look, sleep for real,
/// again. `pumpAndSettle` is deliberately not used anywhere in this lane; on
/// a page that shows a spinner while the wire answers it hangs, and the memory
/// `side-pane-tests-need-timed-pumps` records the same lesson.
///
/// ## The HTTP mock
///
/// `TestWidgetsFlutterBinding` installs `HttpOverrides.global` with a client
/// that answers 400 to everything, and `WebSocket.connect` goes through
/// `HttpClient`. The lane resets the override once, at binding start; the
/// panel's dial and the probe's dial both need it gone.
library;

import 'dart:async';
import 'dart:io';

import 'package:beamer/beamer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meta/meta.dart' show isTest;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/access_routes.dart';
import 'package:tfc/core/gateway_config.dart';
import 'package:tfc/core/gateway_state_man.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/access_templates.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/widgets/access_gate.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/guarded_state_man.dart';
import 'package:tfc_dart/core/preferences_api.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart';

import '../../helpers/test_helpers.dart';

/// The station name every audit row from this panel carries.
const String kPanelStation = 'e2e-panel';

/// The switch that runs the KNOWN RED cases.
///
/// A known-red case asserts the CORRECT behaviour for a defect that is
/// found and not yet fixed, so it fails by design until the fix lands. CI
/// runs the lane twice: once without this switch, where every known red is
/// reported as skipped with its reason and the run must be green; once with
/// it, where the reds are counted and a red that has turned green is the
/// signal to delete the marker. Locally, set it to see the defects fail.
const String kKnownRedVariable = 'CENTROIDX_E2E_PAGES_KNOWN_RED';

bool get knownRedEnabled => Platform.environment[kKnownRedVariable] == '1';

/// A case that is red on purpose until its defect is fixed. Same signature
/// as [testWidgets]; the description keeps its `KNOWN RED` prefix, which is
/// the only reason a skipped run prints (`testWidgets` takes a bare bool),
/// and the switch's name is in this file's doc.
@isTest
void knownRed(String description, WidgetTesterCallback callback) =>
    testWidgets(description, callback, skip: !knownRedEnabled);

/// The app's container, dialling `ws://127.0.0.1:[port]`.
final class Panel {
  Panel._(this.container, this.local);

  final ProviderContainer container;

  /// The device-local store: what `localPreferencesProvider` answers.
  final PreferencesApi local;

  static Future<Panel> dial(int port) async {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    SecureStorage.setInstance(FakeSecureStorage());
    useInMemoryDeviceLocalPreferences();
    // The server configuration page's import/export card asks
    // package_info_plus for the app version. Under `runAsync` the call
    // completes, and with no plugin it completes by throwing
    // (test/pages/server_config_reorder_golden_test.dart:136-149 hit the same
    // thing capturing a golden), so the channel answers here.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/package_info'),
      (call) async => <String, dynamic>{
        'appName': 'tfc-hmi',
        'packageName': 'is.centroid.tfc',
        'version': '1.0.0',
        'buildNumber': '1',
      },
    );

    final local = InMemoryPreferences();
    await writeGatewayConfig(
      local,
      GatewayConfig(
        mode: TransportMode.gateway,
        url: 'ws://${InternetAddress.loopbackIPv4.address}:$port',
      ),
    );
    final container = ProviderContainer(
      overrides: [
        localPreferencesProvider.overrideWithValue(local),
        stationNameProvider.overrideWithValue(kPanelStation),
        stateManFactoryProvider.overrideWithValue(({
          required StateManConfig config,
          required KeyMappings keyMappings,
          List<DeviceClient> deviceClients = const [],
        }) async =>
            throw StateError('a gateway panel reached for a LOCAL StateMan')),
      ],
    );
    addTearDown(container.dispose);
    return Panel._(container, local);
  }

  /// The real relay client under the app's guards — for assertions about
  /// what the panel itself was told.
  Future<RemoteStateMan> remote() async {
    final stateMan = await container.read(stateManProvider.future);
    final remote = stateMan is GuardedStateMan
        ? stateMan.innerAs<GatewayStateMan>()?.remote
        : null;
    if (remote == null) {
      throw StateError('the panel built ${stateMan.runtimeType}, not a '
          'GatewayStateMan over a RemoteStateMan');
    }
    return remote;
  }

  /// Waits for the link to be serving AND for the reads every gateway panel
  /// fires at boot to have answered.
  ///
  /// The second half is what a case that ends early needs: the access
  /// templates (`accessTemplates.list` / `.bindings`) are fetched the moment
  /// the policy is first read, and a container disposed with that request in
  /// flight makes `RemoteStateMan` throw "closed with pending request" after
  /// the case has completed — which `package:test` charges to the case.
  /// Measured on the first runs of this lane, in every case that mounted a
  /// locked page and left.
  Future<void> ready() async {
    final client = await remote();
    await client.linkReady.timeout(const Duration(seconds: 30));
    await container.read(accessSessionProvider.future);
    try {
      await container.read(accessTemplatesProvider.future);
    } on Object {
      // A refused read is a fine answer; what matters is that it answered.
    }
  }

  /// Signs in through the app's own controller — `session.login` on the wire,
  /// the session built from what the GATEWAY resolved.
  Future<AccessSignInResult> signIn(String username, String password) async {
    await container.read(accessSessionProvider.future);
    return container
        .read(accessSessionProvider.notifier)
        .signIn(username, password);
  }

  Future<AccessSession> session() =>
      container.read(accessSessionProvider.future);
}

/// Mounts [page] the way `centroid-hmi/lib/main.dart` mounts every raised
/// route: under a Beamer, inside `AccessGate` with the route's group from
/// `kRaisedRoutes`. The gate is real, the scaffold is real, the menu is the
/// registry's.
Widget hostRoute(Panel panel, String route, String title, Widget page) {
  final registry = RouteRegistry();
  if (registry.menuItems.isEmpty) {
    registry.addMenuItem(
        const MenuItem(label: 'Home', path: '/', icon: Icons.home));
  }
  final delegate = BeamerDelegate(
    locationBuilder: RoutesLocationBuilder(routes: {
      '/': (context, state, data) => BeamPage(
            key: const ValueKey('/'),
            title: title,
            child: AccessGate(
              group: kRaisedRoutes[route]!,
              title: title,
              allowWhenNobodyCanSignIn: routeAllowedWhenNobodyCanSignIn(route),
              child: page,
            ),
          ),
    }).call,
  );
  return UncontrolledProviderScope(
    container: panel.container,
    child: BeamerProvider(
      routerDelegate: delegate,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        routerDelegate: delegate,
        routeInformationParser: BeamerParser(),
      ),
    ),
  );
}

/// A tall, wide surface: the pages are desktop layouts and several of them
/// assert nothing above a minimum height.
Future<void> useDesktopSurface(WidgetTester tester,
    {Size size = const Size(1400, 2000)}) async {
  await tester.binding.setSurfaceSize(size);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() async {
    await tester.binding.setSurfaceSize(null);
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

/// Pumps a frame, looks for [finder], lets the real loop run, again — until
/// it is there or [within] has passed. The only wait this lane uses.
///
/// The pump is in the FAKE zone and the sleep in the REAL one, alternating,
/// which is the shape `test/e2e_assets/support/panel_bench.dart`'s
/// `pumpUntil` settled on: a `pump` from inside `runAsync` waits for the
/// pending async task to finish, which is itself, so it never returns.
Future<void> untilFound(WidgetTester tester, Finder finder,
    {Duration within = const Duration(seconds: 30), String? describe}) async {
  final stopwatch = Stopwatch()..start();
  while (true) {
    await tester.pump();
    if (finder.evaluate().isNotEmpty) return;
    if (stopwatch.elapsed > within) {
      fail('timed out after ${stopwatch.elapsed.inMilliseconds}ms waiting for '
          '${describe ?? finder.toString()}\n  on screen: '
          '${visibleTexts(tester)}');
    }
    await breathe(tester);
  }
}

/// The complement: [finder] must be ABSENT for the whole of [span]. The
/// shape a "never rendered" claim needs — one look at the end is one instant.
Future<void> neverFound(WidgetTester tester, Finder finder, Duration span,
    {required String describe}) async {
  final stopwatch = Stopwatch()..start();
  while (stopwatch.elapsed < span) {
    await tester.pump();
    if (finder.evaluate().isNotEmpty) {
      fail('$describe — but it appeared ${stopwatch.elapsed.inMilliseconds}ms '
          'in');
    }
    await breathe(tester);
  }
}

/// Waits for [predicate] — a claim about the backend, the plant or a provider,
/// never about the tree — with the real loop running between looks.
/// For use INSIDE [live].
Future<void> untilTrue(FutureOr<bool> Function() predicate,
    {Duration within = const Duration(seconds: 30), String? describe}) async {
  final stopwatch = Stopwatch()..start();
  while (!await predicate()) {
    if (stopwatch.elapsed > within) {
      fail('timed out after ${stopwatch.elapsed.inMilliseconds}ms waiting for '
          '${describe ?? 'a condition'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// Lets sockets deliver and the plant tick: one real sleep under the binding.
Future<void> breathe(WidgetTester tester,
    [Duration gap = const Duration(milliseconds: 50)]) =>
    tester.runAsync(() => Future<void>.delayed(gap));

/// A few frames with real time in between, for a tap or a keystroke to land.
Future<void> settleFrames(WidgetTester tester, {int frames = 5}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump();
    await breathe(tester);
  }
}

/// Takes the page down and lets its fake-zone timers expire.
///
/// Two reasons, both measured. A page's widgets arm one-second timers in
/// the fake zone (the gateway link's patience, a snackbar), and the binding
/// fails a case whose tree was disposed with one still pending. And a second
/// `hostRoute` pumped over the first in one case threw `No element` from
/// Beamer's title-setter while the first delegate was still the router's.
/// So every case ends here, and a case that mounts a second panel goes
/// through here between the two.
Future<void> dismount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  // Real time first: a request the page fired on its last frame needs the
  // socket to answer it before the container goes down.
  await breathe(tester, const Duration(milliseconds: 500));
  await tester.pump(const Duration(seconds: 3));
}

/// Every `Text` on screen, for a timeout message that says what WAS there.
String visibleTexts(WidgetTester tester) {
  final texts = tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
      .where((t) => t.trim().isNotEmpty)
      .take(60)
      .toList();
  return texts.isEmpty ? '(no text on screen)' : texts.join(' | ');
}

/// Runs [body] in the real zone: every dial, every sign-in, every read of a
/// provider that owns a timer, and every read-back from the backend.
/// Never a `pump` — see [untilFound].
Future<T> live<T>(WidgetTester tester, Future<T> Function() body) async =>
    (await tester.runAsync(body)) as T;

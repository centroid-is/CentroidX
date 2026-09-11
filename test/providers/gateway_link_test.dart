@TestOn('vm')

/// The first real-socket test in this package, and the scaffolding every later
/// Phase 15 plan stands on.
///
/// **Why real sockets at all.** `RemoteStateMan`'s `dial:` seam is reachable
/// only from inside `tfc_relay_client` — `ConnectAttempt`, `connect`,
/// `ConnectionSupervisor` and `ValueStore` are `src/`-only and the barrel
/// exports none of them (`tfc_relay_client.dart:52-63`). So the app cannot
/// fake a connection; it can only make one. The far end is
/// `test/helpers/scripted_gateway.dart`, bound to `InternetAddress.loopbackIPv4`
/// on an ephemeral port, speaking the real protocol frames.
///
/// **Every arm here is a plain `test()`, never a widget test.** The widget
/// binding runs in a fake-async zone that will not pump a real socket's
/// completions, so an arm written that way waits forever for a frame that has
/// already arrived. `test/providers/state_man_transport_test.dart` is the
/// in-repo precedent for the plain route in this very directory.
///
/// **Teardown is registered at acquisition, not after success.**
/// `RemoteStateMan`'s constructor starts dialling
/// (`remote_state_man.dart:213-214`), so a client built by an arm that then
/// fails an expectation keeps a backoff loop running for the rest of the run —
/// which is how unrelated widget tests start flaking. Every construction is
/// followed on the next line by `addTearDown(client.dispose)`, and
/// `ScriptedGateway.start` registers its own shutdown before it returns.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/core/gateway_config.dart';
import 'package:tfc/core/gateway_link_status.dart';
import 'package:tfc/core/gateway_state_man.dart';
import 'package:tfc/providers/access.dart' show stationNameProvider;
import 'package:tfc/providers/collector.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/gateway_link.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc_dart/core/access/guarded_state_man.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart';
// `PreferencesApi` is spelled in both packages: the protocol's is the wire
// surface the gateway serves, and `tfc_dart`'s is the store this station reads
// its transport row out of. This file wants the second one.
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    hide PreferencesApi;

import '../helpers/scripted_gateway.dart';
import '../helpers/test_helpers.dart';
import '../helpers/throwaway_ca.dart';

/// The credential the wire arm drives.
///
/// Long, obviously synthetic and carrying `-DO-NOT-LOG`, the shape
/// `auth_refusal_test.dart:79` established: a short or plausible token could
/// collide with ordinary prose in a string search and pass while leaking.
const String _credential =
    'ST101-PANEL-CREDENTIAL-3f9a2b7c4e1d8065-DO-NOT-LOG';

/// The attempt-0 backoff window. Small enough that a redial an arm waits for
/// happens inside its budget.
const Duration _base = Duration(milliseconds: 40);

/// The ceiling, far below the production 30 s, for the reason
/// `auth_refusal_test.dart:90-91` gives.
const Duration _cap = Duration(milliseconds: 200);

/// The budget for "the panel got where it was going".
const Duration _recovery = Duration(seconds: 5);

/// The client's knobs, with every production wait lowered deliberately and
/// greppably.
///
/// `allowTokenOverPlaintext` is on because these arms dial `ws://` on loopback
/// with a credential, which `ClientConfig.checkDialable` otherwise refuses by
/// name (`client_config.dart:371-375`) — correctly, for a plant LAN.
ClientConfig _fastConfig({String? token, ClientTlsConfig? tls}) => ClientConfig(
      controlDeadline: const Duration(milliseconds: 400),
      writeDeadline: const Duration(milliseconds: 400),
      freshnessDeadline: const Duration(seconds: 3),
      backoffBase: _base,
      backoffCap: _cap,
      deadlineFloor: const Duration(milliseconds: 50),
      token: token,
      tls: tls,
      allowTokenOverPlaintext: true,
    );

/// Completes with the first [LinkState] satisfying [predicate].
///
/// **Listen first, then seed.** `linkStates` is a broadcast stream and the
/// constructor has already started dialling, so a transition can complete
/// before an arm gets to look — a bare `firstWhere` on the stream then waits
/// for something that already happened, and a bare read of the synchronous
/// getter misses everything after it. Attaching the listener before offering
/// the seed is the only ordering with no window in it. This is the same F-5
/// hazard `lib/providers/gateway_link.dart` will have.
Future<LinkState> _until(
  RemoteStateMan client,
  bool Function(LinkState state) predicate, {
  Duration budget = _recovery,
}) {
  final completer = Completer<LinkState>();
  void offer(LinkState state) {
    if (predicate(state) && !completer.isCompleted) completer.complete(state);
  }

  final subscription = client.linkStates.listen(offer);
  offer(client.linkState);
  return completer.future
      .timeout(budget)
      .whenComplete(subscription.cancel);
}

/// A gateway that completes an ordinary session: hello, then a snapshot.
///
/// Without the subscribe snapshot the client never leaves `resyncing` —
/// `ResyncEngine.onHello` returns only once every page holds one.
Future<ScriptedGateway> _healthyGateway() =>
    ScriptedGateway.start((link, method, id) {
      if (method == Methods.hello) link.hello(id);
      if (method == Methods.subscribe) {
        link.snapshot(id, defaultPageSubscription);
      }
    });

/// How long an arm watches a **stopped** panel before believing it stopped.
///
/// A stop is an absence, and the only honest way to assert one is to wait
/// longer than the event would have taken. `auth_refusal_test.dart:87-114`'s
/// number, for its reason: several attempt-0 windows and more than one
/// ceiling, so a refusal that had left a retry scheduled would have redialled
/// inside it.
const Duration _quietWindow = Duration(milliseconds: 300);

/// The JSON-RPC code the gateway refuses a credential with.
///
/// Driven verbatim from this side of the package boundary the supervisor's own
/// constant sits on — the same two-literals-that-must-agree discipline
/// `auth_refusal_test.dart:60-70` uses. There is no shared constant to import:
/// `grep -rn 32003 packages/tfc_relay_protocol/lib` is empty.
const int _unauthorized = -32003;

/// The code for a protocol-version refusal, the arm this one sits beside.
const int _versionMismatch = -32004;

/// The gateway's own refusal text, with a credential spliced into it.
///
/// The untrusted peer is the one that writes this string, and the client
/// carries it into `stopReason` verbatim and on purpose
/// (`connection_supervisor.dart:596-600`). T-15-18 is what the app does with
/// it on the last hop to a screen: it may reach the paste-into-a-ticket field
/// and it may not reach the two lines an operator reads across a room.
const String _refusalMessage =
    'the credential $_credential is not in the station map';

/// This station's mapping, in the arms that drive the full provider stack.
///
/// It names [kScriptedSeededKey] because `GatewayStateMan` fixes the client's
/// subscription set from the mapping at construction, so a key absent here is
/// a key the scripted gateway is never asked for and a value that never lands.
final KeyMappings _gatewayMappings = KeyMappings(nodes: {
  kScriptedSeededKey: KeyMappingEntry(
      opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'Connected')),
});

/// The full provider stack a panel runs, with nothing about the transport
/// faked.
///
/// **`gatewayStateManFactoryProvider` is deliberately NOT overridden.** That
/// is the difference between this harness and every other one in this
/// directory: the object under observation is the real `GuardedStateMan` the
/// real `stateManProvider` builds around a real `GatewayStateMan` around a
/// real `RemoteStateMan` dialling a real socket. An arm that reached for a
/// hand-built `GatewayStateMan` would pass while `value is GatewayStateMan`
/// stayed false on every panel in the plant — which is the defect (15-RESEARCH
/// F-1) this whole plan exists to prevent.
///
/// The three things that *are* overridden are the ones with no bearing on the
/// transport: no Postgres, a fixed station name for the audit rows, and the
/// direct-mode construction seam left as a tripwire, because a gateway station
/// reaching it is a defect in itself.
ProviderContainer _harness({
  required PreferencesApi local,
  Duration? patience,
  List<Override> extra = const <Override>[],
}) {
  final container = ProviderContainer(
    overrides: [
      preferencesProvider.overrideWith((ref) => createTestPreferences(
            keyMappings: _gatewayMappings,
            stateManConfig: StateManConfig(opcua: const []),
          )),
      systemPreferencesProvider.overrideWith((ref) => createTestPreferences(
            keyMappings: _gatewayMappings,
            stateManConfig: StateManConfig(opcua: const []),
          )),
      localPreferencesProvider.overrideWithValue(local),
      databaseProvider.overrideWith((ref) async => null),
      stationNameProvider.overrideWithValue('phase15-panel'),
      collectorProvider.overrideWith((ref) async => null),
      stateManFactoryProvider.overrideWithValue(({
        required StateManConfig config,
        required KeyMappings keyMappings,
        List<DeviceClient> deviceClients = const [],
      }) async =>
          throw StateError('local StateMan construction reached')),
      if (patience != null)
        gatewayLinkPatienceProvider.overrideWithValue(patience),
      ...extra,
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// A device-local store seeded with [row], and the stack reading it.
Future<ProviderContainer> _panel(
  GatewayConfig row, {
  Duration? patience,
  List<Override> extra = const <Override>[],
}) async {
  final local = InMemoryPreferences();
  await writeGatewayConfig(local, row);
  return _harness(local: local, patience: patience, extra: extra);
}

/// The first report [container] publishes that satisfies [predicate].
///
/// Listens before it reads, the same no-window ordering [_until] documents:
/// the provider seeds synchronously on its first listener, and a listener
/// attached after a read would miss exactly that seed.
Future<GatewayLinkReport> _report(
  ProviderContainer container,
  bool Function(GatewayLinkReport report) predicate, {
  Duration budget = _recovery,
}) {
  final completer = Completer<GatewayLinkReport>();
  final subscription = container.listen<AsyncValue<GatewayLinkReport?>>(
    gatewayLinkProvider,
    (previous, next) {
      final report = next.valueOrNull;
      if (report != null && predicate(report) && !completer.isCompleted) {
        completer.complete(report);
      }
    },
    fireImmediately: true,
    onError: (Object error, StackTrace _) {
      if (!completer.isCompleted) completer.completeError(error);
    },
  );
  return completer.future.timeout(budget).whenComplete(subscription.close);
}

/// The first settled value [container] publishes, report or `null`.
///
/// **A bare `container.read(gatewayLinkProvider.future)` hangs here, and the
/// reason is worth knowing.** `gatewayConfigProvider` is a `FutureProvider`, so
/// the first build of `gatewayLinkProvider` runs while the device-local row is
/// still being read and publishes nothing. Riverpod rebuilds a dirty provider
/// **lazily**, and a `read` establishes no listener — so with nobody watching,
/// the rebuild that would have carried the answer never happens and the future
/// stays pending until the container is torn down. Every real consumer of this
/// provider is a widget that `watch`es it, which is what this helper models.
Future<GatewayLinkReport?> _settled(
  ProviderContainer container, {
  Duration budget = _recovery,
}) {
  final completer = Completer<GatewayLinkReport?>();
  final subscription = container.listen<AsyncValue<GatewayLinkReport?>>(
    gatewayLinkProvider,
    (previous, next) {
      if (next is AsyncData<GatewayLinkReport?> && !completer.isCompleted) {
        completer.complete(next.value);
      }
    },
    fireImmediately: true,
    onError: (Object error, StackTrace _) {
      if (!completer.isCompleted) completer.completeError(error);
    },
  );
  return completer.future.timeout(budget).whenComplete(subscription.close);
}

/// The last value [container] settles on inside [window], and whether it
/// settled at all.
///
/// **An arm about the missing-CA gap cannot use [_report].** That helper skips
/// nulls by construction, so on the defect it simply times out — and a timeout
/// names nothing, least of all "the panel published the same null it uses for a
/// direct station". This one watches a window close and reports what a panel is
/// left showing when it does, which is the operator-visible fact.
///
/// The window has to outlast at least two settles: the provider publishes
/// `null` while `stateManProvider` is still building, and only then can it
/// publish what the build failed with.
Future<GatewayLinkReport?> _lastSettled(
  ProviderContainer container, {
  Duration window = const Duration(milliseconds: 900),
}) async {
  GatewayLinkReport? last;
  var settled = false;
  final subscription = container.listen<AsyncValue<GatewayLinkReport?>>(
    gatewayLinkProvider,
    (previous, next) {
      if (next is AsyncData<GatewayLinkReport?>) {
        settled = true;
        last = next.value;
      }
    },
    fireImmediately: true,
  );
  await Future<void>.delayed(window);
  subscription.close();

  // Anti-vacuity, and it is the whole difference between "the panel shows
  // nothing" and "nobody looked": a provider that never left AsyncLoading
  // would satisfy an `isNull` assertion below for entirely the wrong reason.
  expect(settled, isTrue,
      reason: 'the provider never settled inside $window, so every assertion '
          'about what it settled on is about a value nobody published');
  return last;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    SecureStorage.setInstance(FakeSecureStorage());
  });

  group('the scaffolding Phase 15 stands on', () {
    // Assumption A2, and it runs first because three later plans are written
    // against it being true. `RemoteStateMan` mounts a pinned root with
    // `SecurityContext(withTrustedRoots: false)..setTrustedCertificates(path)`
    // (`remote_state_man.dart:124-132`); a PEM that does not parse there is a
    // fixture that cannot be used, and the phase has a specified fallback.
    test('the throwaway CA is a PEM SecurityContext parses, and it lives '
        'outside the checkout', () {
      final path = throwawayCaPath();

      expect(() {
        final context = SecurityContext(withTrustedRoots: false);
        context.setTrustedCertificates(path);
      }, returnsNormally,
          reason: 'this is the one call the fixture exists to survive; if it '
              'throws, the TLS leg of this phase falls back to dialling wss '
              'at a plaintext listener and no PEM is minted at all');

      // A test that mints a private key and leaves it in the checkout is a
      // private key one `git add -A` away from the history. systemTemp, and
      // nothing under the working directory, is the whole rule.
      expect(path, startsWith(Directory.systemTemp.path),
          reason: 'the key beside this PEM is a real RSA private key');
      expect(path, isNot(startsWith(Directory.current.path)),
          reason: 'no run may leave a .pem somewhere git add would find it');
    });

    test('a real client reaches ready against the scripted gateway', () async {
      final gateway = await _healthyGateway();

      final client = RemoteStateMan(
        uri: gateway.uri,
        config: _fastConfig(),
        keys: const {kScriptedSeededKey},
      );
      addTearDown(client.dispose);

      await _until(client, (state) => state == LinkState.ready);

      expect(client.linkState, LinkState.ready);
      expect(gateway.accepted, 1,
          reason: 'the far end agrees with the near end about how many times '
              'it was dialled; a disagreement means the client never got past '
              'the handshake and something else completed the arm');
    });

    test('a pushed update reaches the client', () async {
      final gateway = await _healthyGateway();

      final client = RemoteStateMan(
        uri: gateway.uri,
        config: _fastConfig(),
        keys: const {kScriptedSeededKey},
      );
      addTearDown(client.dispose);

      await _until(client, (state) => state == LinkState.ready);

      // The snapshot seeded `true` at seq 0. The push is the next sequence,
      // and it is what plan 15-04's criterion-4 guard measures: values flow
      // over a real socket and land definite, not merely grey.
      final arrived = client
          .subscribe(kScriptedSeededKey)
          .firstWhere((value) => value.value == false)
          .timeout(_recovery);
      gateway.links.last.update(1, const {1: false});

      final value = await arrived;
      expect(value.value, isFalse);
      expect(value.quality.isGood, isTrue,
          reason: 'a value that arrives under bad quality renders grey, which '
              'is what the operator sees when nothing is flowing at all — the '
              'two must not be indistinguishable');
      expect(client.read(kScriptedSeededKey)?.value, isFalse,
          reason: 'the synchronous read is what a widget rebuild sees');
    });

    test('the gateway records the frames the client sent', () async {
      final gateway = await _healthyGateway();

      final client = RemoteStateMan(
        uri: gateway.uri,
        config: _fastConfig(token: _credential),
        keys: const {kScriptedSeededKey},
      );
      addTearDown(client.dispose);

      await _until(client, (state) => state == LinkState.ready);

      final hello = gateway.frames
          .firstWhere((frame) => frame['method'] == Methods.hello);
      final params = hello['params'];
      expect(params, isA<Map<String, Object?>>());

      // The recording is what plan 15-03's dial-target arm reads: it proves
      // the configured credential is the one that crossed the wire, rather
      // than the one the app meant to send.
      expect((params! as Map)['token'], _credential);
      expect(gateway.hellos, hasLength(1),
          reason: 'hellos is the same observation, pre-filtered, and the two '
              'must not disagree');
    });

    // **This arm exists because a mutation turned nothing red.** Replacing
    // `ScriptedLink._send`'s `_closing`-and-`readyState` pair with the bare
    // `readyState` read from the upstream analog left the four arms above
    // green on 5 of 5 runs — none of them answers a frame on a link the
    // gateway is closing, so none of them can see the window. Measured here
    // instead, and it is deterministic on this machine at 5 of 5 both ways:
    // with the guard the send is dropped, without it `socket.add` throws
    // `Bad state: StreamSink is closed` while `readyState` still reads `open`.
    //
    // It matters because the scaffold is shared. A gateway that throws at
    // teardown throws in the ambient zone, which fails whichever *case* is
    // running rather than the one that caused it — a scaffold defect read as a
    // product defect, in another file.
    test('a frame answered on a link this gateway is closing is dropped, '
        'not thrown', () async {
      final gateway = await ScriptedGateway.start((link, method, id) {});

      final peer = await WebSocket.connect(gateway.uri.toString());
      addTearDown(() => peer.close().catchError((Object _) => null));
      await _untilTrue(() => gateway.links.isNotEmpty);
      final link = gateway.links.single;

      unawaited(link.close());

      // Anti-vacuity, and it is load-bearing: the whole claim is about the
      // window where `dart:io` has not moved `readyState` yet. If it has
      // already moved, the guard below is never consulted and this arm passes
      // while proving nothing.
      expect(link.socket.readyState, WebSocket.open,
          reason: 'the guard under test covers the window where readyState '
              'still reads open over a sink that throws; if that window is '
              'gone by here, this arm is asserting nothing');

      expect(() => link.result(1, null), returnsNormally,
          reason: 'the gateway asked for this close itself, so it knows the '
              'sink is gone even though readyState does not — that is the '
              'whole of the _closing flag, and dart:io will not tell you');
    });
  });

  // -------------------------------------------------------------------------
  // Criterion 2, over real sockets. Three refusals, three loopback listeners,
  // three kinds — and the panel plumbing that carries them, unfaked, from the
  // socket to something a widget could render.
  // -------------------------------------------------------------------------
  group('gatewayLinkProvider', () {
    test('surfaces a report through the guard on a real panel stack',
        () async {
      final gateway = await _healthyGateway();
      final container = await _panel(GatewayConfig(
          mode: TransportMode.gateway, url: gateway.uri.toString()));

      final report = await _report(container, (_) => true);

      expect(report, isA<GatewayLinkReport>());
      expect(report.url, gateway.uri);

      // The claim this arm exists to make, asserted rather than assumed: the
      // object the provider unwrapped is the one `stateManProvider` really
      // built, and that object is a `GuardedStateMan`. An arm that constructed
      // a bare `GatewayStateMan` would prove nothing — `value is
      // GatewayStateMan` is false on every panel in the plant (15-RESEARCH
      // F-1) and a test built that way stays green while the panel stays
      // blank.
      final stateMan = await container.read(stateManProvider.future);
      expect(stateMan, isA<GuardedStateMan>(),
          reason: 'if this is not the guard, the report reached the panel by '
              'a route no panel has');
      expect(stateMan, isNot(isA<GatewayStateMan>()),
          reason: 'the guard hides the adapter — the whole reason innerAs '
              'exists');
      expect((stateMan as GuardedStateMan).innerAs<GatewayStateMan>(),
          isNotNull);
    });

    test('direct mode publishes no report, and never builds a StateMan',
        () async {
      var built = false;
      final container = await _panel(
        const GatewayConfig(mode: TransportMode.direct),
        extra: [
          // The `test_helpers.dart:322-323` tripwire. A throw here is the only
          // way to observe a read that should never happen: a provider that
          // was built and then ignored looks identical to one that was not.
          stateManProvider.overrideWith((ref) {
            built = true;
            throw StateError('stateManProvider was built in direct mode');
          }),
        ],
      );

      expect(await _settled(container), isNull,
          reason: 'the chip and the status row are absent in direct mode, not '
              'empty');
      expect(built, isFalse,
          reason: 'the absence is decided on the config row before anything '
              'heavier is touched, which is what keeps '
              'base_scaffold_appbar_golden_test.dart — which overrides only '
              'alarmManProvider — from having to build a real StateMan');
      expect(container.read(gatewayLinkTimerProbeProvider).armedFor, isEmpty,
          reason: 'a station with no link has nothing whose patience could '
              'expire; a timer armed here is one running on every direct '
              'panel in the plant, forever, for nobody');
    });

    test('a closed port reads as unreachable, and the panel keeps retrying',
        () async {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();

      final container = await _panel(GatewayConfig(
          mode: TransportMode.gateway, url: 'ws://127.0.0.1:$port'));

      final report = await _report(
          container, (r) => r.kind != GatewayLinkKind.connecting);

      expect(report.kind, GatewayLinkKind.unreachable);
      expect(report.terminal, isFalse,
          reason: 'a cable and a switch can be fixed under a running panel, '
              'so the supervisor keeps dialling and the copy must not say it '
              'has given up');
      expect(report.raw, contains(GatewayLinkReasons.didNotAnswer));
      expect(report.sanHint, isNull);
    });

    test('relayCanAuthenticateProvider follows the link, and is true in '
        'direct mode', () async {
      // The seam the Server Config exemption is keyed on. The rule itself is
      // `gatewayLinkCanAuthenticate` (unit-tested over all seven kinds in
      // `test/core/gateway_link_status_test.dart`); this arm is that the
      // provider really reads the link rather than a constant, which is the
      // half a pure test cannot see.
      final direct =
          await _panel(const GatewayConfig(mode: TransportMode.direct));
      final directSub = direct.listen<bool>(
          relayCanAuthenticateProvider, (_, __) {},
          fireImmediately: true);
      addTearDown(directSub.close);
      await _untilTrue(() => direct.read(gatewayLinkProvider).hasValue);
      expect(direct.read(relayCanAuthenticateProvider), isTrue,
          reason: 'a direct station has no link to ask about, and the answer '
              'must not be the one that opens a page');

      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();

      final gateway = await _panel(GatewayConfig(
          mode: TransportMode.gateway, url: 'ws://127.0.0.1:$port'));
      final gatewaySub = gateway.listen<bool>(
          relayCanAuthenticateProvider, (_, __) {},
          fireImmediately: true);
      addTearDown(gatewaySub.close);

      await _untilTrue(() => !gateway.read(relayCanAuthenticateProvider));
      expect(gateway.read(relayCanAuthenticateProvider), isFalse,
          reason: 'nobody can sign in over a closed port, which is what keeps '
              'Server Config reachable on a mistyped gateway URL');
    });

    test('a wss dial that cannot be verified reads as a certificate refusal',
        () async {
      // No TLS server and no leaf: `_refusalReason` maps every
      // `HandshakeException` to one sentence regardless of cause
      // (15-RESEARCH F-2), so a `wss://` dial at a plaintext listener reaches
      // the identical app-visible input as a mis-issued certificate would.
      final plaintext = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => plaintext.close(force: true));
      plaintext.listen((request) => request.response.close());

      final container = await _panel(GatewayConfig(
        mode: TransportMode.gateway,
        url: 'wss://127.0.0.1:${plaintext.port}',
        caCertPath: throwawayCaPath(),
      ));

      final report = await _report(
          container, (r) => r.kind != GatewayLinkKind.connecting);

      expect(report.kind, GatewayLinkKind.untrustedCertificate);
      expect(report.terminal, isFalse,
          reason: 'a certificate can be replaced under a running panel');
      expect(report.raw, contains(GatewayLinkReasons.certificateNotTrusted));
      expect(report.sanHint, isNull,
          reason: 'dialled by address, so the name is not a candidate cause '
              'and a hint that is always shown is a hint nobody reads');
    });

    test('a hello answered -32003 is terminal, and the panel has stopped',
        () async {
      final gateway = await ScriptedGateway.start((link, method, id) {
        if (method != Methods.hello) return;
        link.error(id, _unauthorized, _refusalMessage);
        unawaited(link.close(CloseCodes.authExpired));
      });
      final container = await _panel(GatewayConfig(
          mode: TransportMode.gateway, url: gateway.uri.toString()));

      // The predicate is "settled", not "credentialRefused". Waiting on the
      // kind would turn every mutation of the kind into a five-second timeout,
      // and a timeout names nothing — the two assertions below fail with the
      // kind and the flag that actually moved.
      final report = await _report(
          container, (r) => r.kind != GatewayLinkKind.connecting);

      expect(report.kind, GatewayLinkKind.credentialRefused);
      expect(report.terminal, isTrue,
          reason: 'the gateway has already decided about this token and would '
              'refuse it again; a panel that kept dialling would be a busy '
              'loop against the one process serving every screen');

      // A stop is an absence. Wait longer than a redial would have taken, then
      // ask the far end how many times it was dialled.
      await Future<void>.delayed(_quietWindow);
      expect(gateway.accepted, 1,
          reason: 'the far end agrees the panel has genuinely stopped, rather '
              'than the near end merely saying so');

      // T-15-18. The refusal text is the untrusted peer's, and the client
      // carries it whole on purpose. `raw` is where it is allowed to land; the
      // two lines an operator reads across a room are this app's own words.
      expect(report.raw, contains(_credential));
      expect(report.headline, isNot(contains(_credential)));
      expect(report.detail, isNot(contains(_credential)));
    });

    test('a hello answered -32004 is a version refusal, and terminal',
        () async {
      final gateway = await ScriptedGateway.start((link, method, id) {
        if (method != Methods.hello) return;
        link.error(id, _versionMismatch,
            'this gateway speaks protocol 3 and the panel offered 2');
        unawaited(link.close(CloseCodes.protocolMismatch));
      });
      final container = await _panel(GatewayConfig(
          mode: TransportMode.gateway, url: gateway.uri.toString()));

      final report = await _report(
          container, (r) => r.kind != GatewayLinkKind.connecting);

      expect(report.kind, GatewayLinkKind.versionRefused);
      expect(report.terminal, isTrue);
      expect(report.raw, contains(GatewayLinkReasons.versionRefused));

      await Future<void>.delayed(_quietWindow);
      expect(gateway.accepted, 1);
    });

    test('values flow: the report reads connected and the value lands definite',
        () async {
      final gateway = await _healthyGateway();
      final container = await _panel(GatewayConfig(
          mode: TransportMode.gateway, url: gateway.uri.toString()));

      final report = await _report(
          container, (r) => r.kind == GatewayLinkKind.connected);
      expect(report.terminal, isFalse);
      expect(report.raw, isNull);

      // The offline stand-in for the rig's "grey `--- °C` flipped definite the
      // instant the socket established": the value has to arrive, and it has
      // to arrive under a quality that renders definite. A bad-quality reading
      // paints the same grey as no reading at all, and the two must not be
      // indistinguishable.
      final stateMan =
          await container.read(stateManProvider.future) as GuardedStateMan;
      final remote = stateMan.innerAs<GatewayStateMan>()!.remote;

      final arrived = remote
          .subscribe(kScriptedSeededKey)
          .firstWhere((value) => value.value == false)
          .timeout(_recovery);
      gateway.links.last.update(1, const {kScriptedSeededHandle: false});
      final value = await arrived;

      expect(value.value, isFalse);
      expect(value.quality.isGood, isTrue);
      expect(remote.read(kScriptedSeededKey)?.value, isFalse);
    });

    // -----------------------------------------------------------------------
    // "Never an indefinite spinner" as a measurement, not a phrase.
    // -----------------------------------------------------------------------
    test('the panel stops saying connecting even when nothing moves on the '
        'wire', () async {
      // Accepts the socket, answers nothing. Below the client's 1 s control
      // deadline the supervisor has produced no reason at all, so the only
      // thing that can change what the panel says is a clock.
      final gateway = await ScriptedGateway.start((link, method, id) {});
      final container = await _panel(
        GatewayConfig(
            mode: TransportMode.gateway, url: gateway.uri.toString()),
        patience: const Duration(milliseconds: 100),
      );

      final connecting = await _report(
          container, (r) => r.kind == GatewayLinkKind.connecting);
      expect(connecting.raw, isNull);
      expect(connecting.terminal, isFalse);

      final settled = await _report(
        container,
        (r) => r.kind != GatewayLinkKind.connecting,
        budget: const Duration(milliseconds: 700),
      );

      expect(settled.kind, GatewayLinkKind.unreachable);
      expect(settled.terminal, isFalse);
      expect(settled.raw, isNull,
          reason: 'no reason was ever reported — the supervisor is still '
              'inside its own control deadline. If this is non-null the '
              'client, not the patience window, is what ended the spinner and '
              'the property is untested');
      expect(gateway.accepted, 1,
          reason: 'and the wire did not move either: one socket, still open');
    });

    test('the patience timer is listener-gated and armed only while connecting',
        () async {
      final gateway = await ScriptedGateway.start((link, method, id) {});
      final container = await _panel(
        GatewayConfig(
            mode: TransportMode.gateway, url: gateway.uri.toString()),
        patience: const Duration(seconds: 30),
      );
      // Read before the dispose: a disposed container refuses reads, so the
      // observation has to be a handle taken while it was alive.
      final probe = container.read(gatewayLinkTimerProbeProvider);

      final subscription = container.listen<AsyncValue<GatewayLinkReport?>>(
          gatewayLinkProvider, (_, __) {},
          fireImmediately: true);
      await _report(container, (r) => r.kind == GatewayLinkKind.connecting);

      expect(probe.armed, isTrue,
          reason: 'a first attempt inside the window is the one report whose '
              'expiry no event announces');
      expect(probe.armedFor, isNotEmpty);
      expect(probe.armedFor, everyElement(GatewayLinkKind.connecting),
          reason: 'every other kind is a conclusion; re-deriving it on a '
              'timer would be a periodic timer with extra steps');

      subscription.close();
      container.dispose();

      expect(probe.armed, isFalse,
          reason: 'project memory timers-must-be-listener-gated: an always-on '
              'timer in plumbing fails unrelated widget tests with "A Timer '
              'is still pending"');
    });

    // -----------------------------------------------------------------------
    // The coupling. `lib/core/gateway_link_status.dart` sorts the client's
    // prose by prefix, and those prefixes are copies of literals in another
    // package. A unit test fed a hand-copied constant cannot tell a copy from
    // a retype; these compare against strings a real `ConnectionSupervisor`
    // wrote, over a real socket, in this run.
    // -----------------------------------------------------------------------
    test('the app\'s prefixes are prefixes of what a real supervisor wrote — '
        'the coupling', () async {
      final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = dead.port;
      await dead.close();

      final plaintext = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => plaintext.close(force: true));
      plaintext.listen((request) => request.response.close());

      final refusing = await ScriptedGateway.start((link, method, id) {
        if (method != Methods.hello) return;
        link.error(id, _unauthorized, _refusalMessage);
      });
      final stale = await ScriptedGateway.start((link, method, id) {
        if (method != Methods.hello) return;
        link.error(id, _versionMismatch, 'protocol 3, not 2');
      });

      Future<String> rawFrom(GatewayConfig row) async {
        final container = await _panel(row);
        final report = await _report(
            container, (r) => r.kind != GatewayLinkKind.connecting);
        return report.raw!;
      }

      final didNotAnswer = await rawFrom(GatewayConfig(
          mode: TransportMode.gateway, url: 'ws://127.0.0.1:$deadPort'));
      final notTrusted = await rawFrom(GatewayConfig(
        mode: TransportMode.gateway,
        url: 'wss://127.0.0.1:${plaintext.port}',
        caCertPath: throwawayCaPath(),
      ));
      final credential = await rawFrom(GatewayConfig(
          mode: TransportMode.gateway, url: refusing.uri.toString()));
      final version = await rawFrom(GatewayConfig(
          mode: TransportMode.gateway, url: stale.uri.toString()));

      // `startsWith`, not `contains`: every producer builds its string by
      // prepending a fixed sentence to an interpolated cause, so the prefix is
      // the part that is ours to match. `contains` would keep passing after a
      // reword moved our sentence into the middle of theirs, which is exactly
      // the silent reclassification this arm exists to catch.
      expect(didNotAnswer, startsWith(GatewayLinkReasons.didNotAnswer),
          reason: 'the fallback voice\'s evidence: this literal is what the '
              'unmatched majority of reasons look like');
      expect(notTrusted, startsWith(GatewayLinkReasons.certificateNotTrusted),
          reason: 'three of these literals carry an apostrophe. A straightened '
              'quote silently never matches, and every TLS fault quietly '
              'becomes a cable fault');
      expect(credential, startsWith(GatewayLinkReasons.credentialRefused));
      expect(version, startsWith(GatewayLinkReasons.versionRefused));
    });
  });

  // -------------------------------------------------------------------------
  // A transport that could not be built at all — the fourth case criterion 2
  // names and the one the phase shipped without.
  //
  // Every arm above dials. These do not get that far: a `caCertPath` naming a
  // file that is not there throws `PathNotFoundException` out of
  // `RemoteStateMan`'s constructor (`remote_state_man.dart:132`) and a missing
  // credential file throws out of `GatewayConfig.toClientConfig`, both **before
  // a client exists**. `stateManProvider` ends in `AsyncError`, and the defect
  // this group pins is what happened next: the provider published `null` — the
  // *same* value it publishes for a direct station — so the chip rendered
  // `SizedBox.shrink()` and the Transport card rendered no row. The panel knew
  // exactly what was wrong and said nothing.
  //
  // The paths below are absolute and under a directory no test creates, so a
  // machine where they happened to exist would fail these arms loudly rather
  // than pass them vacuously.
  // -------------------------------------------------------------------------
  group('a transport that could not be built', () {
    /// A directory nothing in this repository ever makes.
    const String kNowhere = '/no/such/phase15/plant-root.pem';
    const String kNoToken = '/no/such/phase15/station.token';

    test('a CA root that names no file is reported, not swallowed', () async {
      final container = await _panel(const GatewayConfig(
        mode: TransportMode.gateway,
        url: 'wss://10.50.10.11:9444',
        caCertPath: kNowhere,
      ));

      final settled = await _lastSettled(container);

      expect(settled, isNotNull,
          reason: 'this is the gap: a construction failure and "this is a '
              'direct station" both published null, so the operator got grey '
              'values on every page and nothing anywhere saying why');
      expect(settled!.kind, GatewayLinkKind.notBuilt,
          reason: 'not `unreachable`: that sentence sends the operator to the '
              'address, the port and the cable, and this fault is entirely on '
              'this station\'s own disk');
      expect(settled.terminal, isTrue,
          reason: 'there is no client and no retry loop — nothing about this '
              'will change until somebody fixes the path and restarts');
      expect(settled.raw, contains('PathNotFoundException'),
          reason: 'the paste-into-a-ticket field carries the panel\'s own '
              'error whole, the way it carries the gateway\'s on every other '
              'kind');
      expect(settled.detail, contains(kNowhere),
          reason: 'the message has to name the file that could not be opened; '
              'a panel that says only "something went wrong" sends the '
              'operator to the same wrong end of the wire the whole '
              'vocabulary exists to prevent');
    });

    test('a credential file that names no file is reported too', () async {
      final container = await _panel(GatewayConfig(
        mode: TransportMode.gateway,
        url: 'wss://10.50.10.11:9444',
        // A real PEM, so the CA is not what fails here and the arm is about
        // the token path alone.
        caCertPath: throwawayCaPath(),
        tokenPath: kNoToken,
      ));

      final settled = await _lastSettled(container);

      expect(settled, isNotNull);
      expect(settled!.kind, GatewayLinkKind.notBuilt);
      expect(settled.detail, contains(kNoToken));
      expect(settled.detail, isNot(contains(throwawayCaPath())),
          reason: 'naming the file that actually failed is the point; naming '
              'both would send the operator to the one that is fine');
    });

    test('a CA file that exists but is not a PEM is reported, and its '
        'contents never reach the prose', () async {
      // Obviously synthetic and carrying -DO-NOT-LOG, the shape
      // `auth_refusal_test.dart:79` established. This is the leak question
      // 15-07 verified across thirteen frames and this new surface must not
      // reopen: the report may name the *path* an operator typed, and may
      // never carry what is behind it.
      const String secret = 'PEM-BODY-SENTINEL-8c1d47ae-DO-NOT-LOG';
      final file = File('${Directory.systemTemp.createTempSync(
        'phase15-notapem',
      ).path}/plant-root.pem');
      file.writeAsStringSync(secret);
      addTearDown(() => file.parent.deleteSync(recursive: true));

      final container = await _panel(GatewayConfig(
        mode: TransportMode.gateway,
        url: 'wss://10.50.10.11:9444',
        caCertPath: file.path,
      ));

      final settled = await _lastSettled(container);

      expect(settled, isNotNull,
          reason: 'a CA file that is present but unusable fails in the same '
              'constructor as an absent one, and must reach a screen the same '
              'way');
      expect(settled!.kind, GatewayLinkKind.notBuilt);
      expect(settled.terminal, isTrue);
      // TlsException names no path, so this is the wider sentence rather than
      // the one that points at a filename — the branch the missing-file arms
      // above cannot reach.
      expect(settled.detail, isNot(contains(file.path)),
          reason: 'the failure named no file, and a surface that invented one '
              'would be guessing at the operator\'s expense');
      final said = '${settled.headline} ${settled.detail}';
      expect(said, isNot(contains(secret)),
          reason: 'the two lines an operator reads across a room are this '
              'app\'s own words; the file behind the path is not one of them');
    });

    // -----------------------------------------------------------------------
    // The paired negative arms. Both of these must be able to go red: a fix
    // that made *everything* report a failure would be caught here and
    // nowhere else, because absence is the thing no present affordance can
    // guard.
    // -----------------------------------------------------------------------
    test('direct mode with a CA path that names no file still publishes '
        'nothing', () async {
      var built = false;
      final container = await _panel(
        const GatewayConfig(mode: TransportMode.direct, caCertPath: kNowhere),
        extra: [
          stateManProvider.overrideWith((ref) {
            built = true;
            throw StateError('stateManProvider was built in direct mode');
          }),
        ],
      );

      expect(await _lastSettled(container), isNull,
          reason: 'the row is stale config on a station that runs its own '
              'sessions; a panel that grew a red pill over it would be '
              'reporting a fault it does not have');
      expect(built, isFalse,
          reason: 'and it decided that on the config row, without touching '
              'anything heavier — the property that keeps '
              'base_scaffold_appbar_golden_test.dart from needing a StateMan');
    });

    test('gateway mode that builds cleanly still reports the link, not a '
        'build failure', () async {
      // The other direction of the same guard. Without this, a change that
      // reported a build failure unconditionally would leave every arm above
      // green.
      final gateway = await _healthyGateway();
      final container = await _panel(GatewayConfig(
          mode: TransportMode.gateway, url: gateway.uri.toString()));

      final report = await _report(
          container, (r) => r.kind == GatewayLinkKind.connected);

      expect(report.terminal, isFalse);
      expect(report.raw, isNull,
          reason: 'a healthy link has no reason text at all, so a report '
              'carrying one here is a build failure wearing the wrong kind');
    });
  });

  // -------------------------------------------------------------------------
  // The declared absence, on the source text.
  //
  // **These exist because a mutation turned nothing red.** Replacing the
  // one-shot with an always-on `Timer.periodic` created at provider
  // construction left this file 15/15 green and `flutter test test/widgets`
  // 1134/1134 green. The reason is measurable: `grep -rln gatewayLinkProvider
  // lib/` returns only the provider's own file, so **nothing in the app
  // watches it yet** — the status row is plan 15-05 and the app-bar chip is
  // 15-06 — and project memory `timers-must-be-listener-gated`'s canary ("A
  // Timer is still pending" in an unrelated widget test) has nothing to fire
  // on. A guard nobody can break is a guard nobody will keep.
  //
  // So the rule is asserted where it *is* observable today: on the file's own
  // source, the discipline `audit_trail_test.dart:334-355` already uses for
  // the symmetrical no-timer rule in `lib/providers/audit_trail.dart`. When
  // 15-05 or 15-06 puts a widget in front of this provider, the behavioural
  // canary becomes available and should be added there — these do not replace
  // it, they cover the window in which it cannot exist.
  // -------------------------------------------------------------------------
  group('the timer rule, on the source', () {
    /// `lib/providers/gateway_link.dart` with every whole-line comment
    /// dropped, so the paragraph explaining the rule cannot satisfy the test
    /// enforcing it.
    List<String> sourceLines() {
      final file = File('lib/providers/gateway_link.dart');
      expect(file.existsSync(), isTrue,
          reason: 'run this suite from the package root; without the file '
              'every assertion below passes vacuously');
      return file
          .readAsLinesSync()
          .where((line) => !line.trimLeft().startsWith('//'))
          .toList();
    }

    test('the derivation reads a real file, not an empty one', () {
      // First, and in its own case: an absence asserted over nothing is the
      // failure mode this whole group is about.
      expect(sourceLines().length, greaterThan(40));
      expect(sourceLines().join('\n'), contains('gatewayLinkProvider'));
    });

    test('names no Timer.periodic', () {
      expect(sourceLines().join('\n'), isNot(contains('Timer.periodic')),
          reason: 'the patience window expires once and the conclusion it '
              'expires to is never `connecting` again, so a periodic timer '
              'here would be a clock running forever on every gateway panel '
              'to re-derive an answer that cannot change');
    });

    test('and it reaches for onListen and onCancel instead', () {
      // The paired half. An absence alone passes on a file that creates no
      // timer at all — including one somebody deleted the gating *and* the
      // timer from, which would take "never an indefinite spinner" with it.
      final source = sourceLines().join('\n');
      expect(source, contains('onListen:'));
      expect(source, contains('onCancel:'));
      expect(source, contains('Timer('),
          reason: 'and there is still a timer to gate — without one the '
              'panel says "connecting…" until something happens on the wire, '
              'which on a dead address is forever');
    });
  });
}

/// Polls [ready] until it holds, or the budget runs out.
///
/// A poll rather than a stream because the thing being waited for — a socket
/// accepted on the far end — announces nothing.
Future<void> _untilTrue(
  bool Function() ready, {
  Duration budget = _recovery,
}) async {
  final deadline = DateTime.now().add(budget);
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('the condition never held inside $budget');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

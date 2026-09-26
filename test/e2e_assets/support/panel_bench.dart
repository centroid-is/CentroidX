/// A real panel — the app's own provider stack — over a real plant.
///
/// ## What is real, and what is substituted
///
/// The chain a case drives is, hop for hop, the one an operator's panel runs:
///
/// ```text
/// tfc_plant_sim open62541 Server  (real socket, opc.tcp)
///   -> OpcUaUpstreamLink -> LocalStateMan -> RelayServer   (buildGateway)
///     -> ws://  through [LinkProxy]                         (real socket)
///       -> RemoteStateMan -> GatewayStateMan -> GuardedStateMan
///         -> stateManProvider -> valueFreshnessProvider -> keyStreamProvider
///           -> the asset widget, pumped by a WidgetTester
/// ```
///
/// Nothing on the value path is a double. `stateManProvider` is the production
/// provider building a production `GuardedStateMan` around a production
/// `GatewayStateMan` around a production `RemoteStateMan`; the reason that
/// matters is 15-RESEARCH F-1 — `value is GatewayStateMan` is false on every
/// real panel, so an arm that hand-built the adapter would prove nothing about
/// the object a panel actually holds. `GatewayStateMan`'s own doc records that
/// `StateMan` and `StateManApi` are different interfaces and it is the
/// adapter between them; this bench goes through it rather than around it.
///
/// What IS substituted, each one a station fact rather than a hop:
///
///  * **The device-local store is in memory**, seeded with a gateway-mode
///    transport row pointing at the proxy. On a station this is a file; the
///    row is the same row `readGatewayConfig` reads.
///  * **The shared store's key mappings and `state_man_config` come from
///    `createTestPreferences`** — the same seam every provider test in this
///    repository uses — because the mappings are derived from the plant spec
///    and no Postgres is involved on a gateway panel anyway
///    (`state_man.dart`'s gateway branch: "what a gateway panel still opens
///    beside the socket is device-local storage, which is a file").
///  * **Four durations on `ClientConfig`**, through `gatewayStateManFactory-
///    Provider`, which still calls the production `GatewayStateMan.create`.
///    `visible_staleness_test.dart:96-118` argues this at length: the object
///    under observation is unchanged, what moved is how long an arm waits.
///  * **`stateManFactoryProvider` throws.** A tripwire, not a stub: if the
///    stack ever reached the direct-mode constructor the transport row was not
///    read, and every case below would be running against no socket at all.
///  * **An operator is signed in.** `accessSessionProvider` is overridden with
///    a fixed session holding `operate` ([SignedInOperator]). The guard, the
///    tag policy and the refusal path are untouched — what is fixed is WHO is
///    at the panel, and it has to be, for a reason `access.dart:812-842`
///    spells out: a gateway panel that presented no credential deliberately
///    holds NO groups ("the honest screen is the lock", 2026-09-16), and a
///    real sign-in goes over the socket to the backend's access stores, which
///    a plant-only gateway does not carry (`LocalStateMan.accessTemplates is
///    not available: this gateway serves the plant, not the access-control
///    database`). Without this the first press on the pill was refused by
///    the panel's own `TagAccess.canWrite` before a byte went out, and the
///    actuation count stayed at zero.
///  * **`FaultProxy` is [LinkProxy]**, for the dependency reason its doc
///    gives.
///
/// ## The one instrument a fake source cannot provide
///
/// `RunningServer.actuationCount` counts writes **at the node**, inside the
/// OPC UA server, before any answer is composed. A duplicated command is
/// invisible to a read-back — the node holds the same value whether it was
/// moved once or twice — and only a plant that counted can tell. Every write
/// case asserts on that count and never on what the panel was told afterwards.
///
/// ## Why every socket is opened inside `tester.runAsync`
///
/// A widget test body runs under `FakeAsync`: every `Timer` and every
/// microtask created in it is parked until `pump` advances a clock that real
/// I/O does not read. The plant iterates its servers on a `Timer.periodic`,
/// the client runs a freshness watchdog, a heartbeat and a backoff on timers,
/// and the gateway ticks. Built in the fake zone, all of them would be
/// timers that never fire and the panel would sit at `connecting` for ever —
/// `visible_staleness_test.dart` hit exactly that and retreated to plain
/// `test()`s. This lane cannot retreat, because the point is `tester.tap` on
/// the real widget. So [standUp] runs entirely inside `runAsync`, where the
/// zone is real, and every provider that owns a timer is read there too, so
/// its timer is real. The widgets are then mounted in the fake zone, over an
/// `UncontrolledProviderScope` on the container the real zone built, and
/// driven by [pumpUntil], which alternates real waiting with fake pumping.
library;


import 'dart:convert' show jsonEncode;
import 'package:tfc/core/device_local_preferences.dart'
    show kConfigItemsCachePrefsKey;
import 'package:tfc_dart/core/config/key_mapping_codec.dart'
    show keyMappingItems;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc_access/tfc_access.dart'
    show AccessGroup, AccessSession, AuthenticatedUser;
import 'package:tfc/core/gateway_config.dart'
    show GatewayConfig, TransportMode, writeGatewayConfig;
import 'package:tfc/core/gateway_state_man.dart';
import 'package:tfc/providers/access.dart'
    show AccessSessionController, accessSessionProvider, stationNameProvider;
import 'package:tfc/providers/collector.dart';
import 'package:tfc/providers/config_store.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/providers/value_freshness.dart';
import 'package:tfc_dart/core/access/guarded_state_man.dart';
import 'package:tfc_dart/core/preferences_api.dart' show InMemoryPreferences;
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_plant_sim/tfc_plant_sim.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart' as relay;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show ConfigItemsFingerprint, ResolvedSeries, SeriesAddress, SeriesResolver;
import 'package:tfc_relay_server/tfc_relay_server.dart' show ServerConfig;

import '../../helpers/test_helpers.dart'
    show
        FakeSecureStorage,
        createTestConfigStore,
        createTestPreferences,
        kConfiguringTestSession;
import 'link_proxy.dart';

/// The plant key a node is reached by: `<ALIAS>.<node id>`.
///
/// Derived rather than written twice, `plant_bench.dart`'s rule: a bench whose
/// mapping and whose assertions each spelled the key would pass while
/// disagreeing.
String plantKey(String alias, String nodeId) => '$alias.$nodeId';

/// The client's knobs, every production wait lowered deliberately and
/// greppably.
///
/// `freshnessDeadline` is one second where production is three: the arms
/// that cut the link need a panel that has provably gone a whole deadline
/// without a frame, and three seconds of wall clock per cut is paid on every
/// run. Not lower — `visible_staleness_test.dart` uses 400 ms against a
/// scripted gateway that answers instantly, but this bench has a real OPC UA
/// publish interval, a real gateway tick and an FFI `runIterate` on the same
/// core, and a deadline the machine can miss under load is a deadline that
/// greys a healthy panel and fails the *value* arms.
ClientConfig fastClientConfig() => ClientConfig(
      controlDeadline: const Duration(seconds: 2),
      writeDeadline: const Duration(seconds: 2),
      freshnessDeadline: const Duration(seconds: 1),
      backoffBase: const Duration(milliseconds: 50),
      backoffCap: const Duration(milliseconds: 250),
      deadlineFloor: const Duration(milliseconds: 50),
      // A dial through a swallowing proxy completes TCP and then waits for an
      // upgrade answer that never comes; production waits ten seconds for it.
      // The heal arm would spend that ten seconds plus a backoff before the
      // first dial that can succeed, on every run.
      connectTimeout: const Duration(seconds: 2),
    );

/// A second upstream beside the OPC UA plant: a weigher, a Modbus device.
///
/// The bench derives the OPC UA links and their mappings from the plant spec;
/// anything that is not an OPC UA server is handed in here, already listening,
/// with the mapping entries that reach it.
final class ExtraUpstream {
  const ExtraUpstream({required this.link, required this.mappings});

  final relay.UpstreamLinkConfig link;
  final Map<String, KeyMappingEntry> mappings;
}

/// The whole bench: plant, gateway, the breakable link, and the panel's
/// provider container.
final class PanelBench {
  PanelBench._(this.plant, this.gateway, this.link, this.container,
      this.remote, this.witness, this.keys);

  /// The plant. `server()` is the lever, `actuations` the instrument.
  final FakePlant plant;

  /// The gateway. `gateway.plant` is the `LocalStateMan` — what the gateway
  /// itself believes, which a stale-screen arm compares the glass against.
  final relay.Gateway gateway;

  /// The **panel-facing** link. Break this and the plant is still moving
  /// behind it.
  final LinkProxy link;

  /// The panel's providers, built in the real zone. Mount widgets over it
  /// with [mount].
  final ProviderContainer container;

  /// The live client under the guard and the adapter, reached the only way a
  /// panel can reach it (`GuardedStateMan.innerAs`). For link-state waits and
  /// for the anti-vacuity reads — never for a value or a write, which must go
  /// through the widget.
  final RemoteStateMan remote;

  /// A second, bare client on the SAME gateway, dialling it directly and not
  /// through [link].
  ///
  /// The oracle for "the plant kept moving while this panel could not hear
  /// it". `gateway.plant.read` is not that oracle: the gateway's upstream
  /// subscriptions are demand-driven, so once its heartbeat reaper has closed
  /// the half-open session nothing on the gateway is watching the node either
  /// — the first version of the stale arm waited thirty seconds for the
  /// gateway to see a move it had stopped subscribing to. A witness keeps the
  /// gateway subscribed and sees every value the cut panel is not shown.
  final RemoteStateMan witness;

  /// Every key the panel subscribed.
  final Set<String> keys;

  bool _disposed = false;

  /// One running server, by the alias its spec gave it.
  RunningServer server([String alias = 'HALL1']) {
    final running = plant.servers[alias];
    if (running == null) {
      throw ArgumentError.value(alias, 'alias',
          'the spec stood up ${plant.servers.keys.join(', ')}');
    }
    return running;
  }

  /// How many times a client has moved [nodeId] at the plant.
  int actuations(String nodeId, {String alias = 'HALL1'}) =>
      server(alias).actuationCount(nodeId);

  /// Mounts [asset] the way a page does: inside a `MaterialApp`, in a box of
  /// a known size, over this bench's container.
  ///
  /// The size is not decoration. Every asset lays itself out against its box
  /// — `AutoSizedText` fits the readout to it, the conveyor paints to it —
  /// and an unconstrained child under `Center` would be zero by zero and
  /// paint nothing a finder could see.
  Future<void> mount(WidgetTester tester, Widget asset,
      {double width = 320, double height = 120}) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(width: width, height: height, child: asset),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  /// Tears everything down, once. Idempotent so the test body can run it in
  /// the real zone and a teardown can run it again on the failure path.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await witness.dispose();
    container.dispose();
    await link.shutdown();
    await gateway.stop();
    await plant.close();
  }
}

/// Stands the chain up and returns once the panel is `ready` and holds a
/// GOOD value from the plant.
///
/// **A GOOD value, not a non-null one** — `plant_bench.dart:238-248`'s
/// reason: `read` answers a placeholder for every subscribed key the moment it
/// is subscribed, so `read(key) != null` is true before the plant has said
/// anything. A bench that opened on that gate would hand every case a panel
/// holding nothing.
///
/// Call this INSIDE `tester.runAsync`. See the library doc for why.
Future<PanelBench> standUp({
  required String spec,
  List<ExtraUpstream> extraUpstreams = const <ExtraUpstream>[],
  Duration staleAfter = const Duration(seconds: 2),
}) async {
  final parsed = PlantSpec.parse(spec);
  final plant = await FakePlant.start(parsed);

  // Every node in the spec becomes a mapped key. Derived from the spec rather
  // than listed: a mapping that drifted from its plant would serve a
  // not-served key and read as a transmission fault.
  final nodes = <String, KeyMappingEntry>{
    for (final server in parsed.servers)
      for (final node in server.nodes)
        plantKey(server.alias, node.id): KeyMappingEntry()
          ..opcuaNode = (OpcUANodeConfig(
              namespace: node.namespace, identifier: node.id)
            ..serverAlias = server.alias),
    for (final extra in extraUpstreams) ...extra.mappings,
  };
  final mappings = KeyMappings(nodes: nodes);

  final config = relay.GatewayConfig(
    // Port zero: a literal collides with the neighbouring worktree the moment
    // two of these run at once, and the collision reads as a bug in the code
    // under test.
    server: ServerConfig(port: 0, tick: ServerConfig.minTick),
    links: <relay.UpstreamLinkConfig>[
      for (final server in parsed.servers)
        relay.UpstreamLinkConfig(
          alias: server.alias,
          protocol: relay.UpstreamProtocol.opcUa,
          endpoint: plant.servers[server.alias]!.endpoint,
          // In-process, as every OPC UA leg in tfc_relay_local does it: the
          // isolate is what production wants and what a test cannot reach
          // into.
          useIsolate: false,
        ),
      for (final extra in extraUpstreams) extra.link,
    ],
    keyMappingsPath: '',
    staleAfter: staleAfter,
  );

  final gateway = await relay.buildGateway(
    config,
    mappings: mappings,
    log: Logger(level: Level.off),
    resolver: const _PermissiveSeriesResolver(),
    // Discarded rather than printed: this lane provokes faults on purpose,
    // and a suite that printed a stack per provoked error trains everyone to
    // scroll past the one that matters.
    onError: (_, __, ___) {},
  );
  await gateway.plant.start();
  await gateway.server.start();

  final link = LinkProxy(targetPort: gateway.server.port);
  await link.start();

  // The station's transport row: gateway mode, dialling the proxy. Plaintext
  // `ws://` on loopback, which `undialable` allows — the trust ceremony is
  // for `wss`, and there is no token.
  final local = InMemoryPreferences();
  await writeGatewayConfig(
      local,
      GatewayConfig(
          mode: TransportMode.gateway, url: 'ws://127.0.0.1:${link.port}'));
  // **And the relayed row cache, which is where a gateway panel's key
  // mappings actually come from now.** Since the relay could write the
  // plant's configuration, a gateway panel reads its rows over the wire and
  // boots from their device-local cache (`stateManProvider`,
  // `configRowsComeOverTheWire`) — it no longer asks `configStoreProvider`
  // at all. This harness's gateway (`LocalStateMan`) serves no
  // `configItems`, so without this seed the panel booted on empty mappings,
  // subscribed to the alarm set alone, and every case timed out waiting for
  // the first value: the exact trap the `configStoreProvider` comment below
  // describes, one layer over. Written in the shape
  // `RelayedConfigItems._persist` writes, as `state_man_transport_test` does.
  await local.setString(
      kConfigItemsCachePrefsKey,
      jsonEncode({
        'fingerprint':
            const ConfigItemsFingerprint(count: 0, revSum: 0).toJson(),
        'items': [
          for (final item in keyMappingItems(mappings))
            {
              'kind': item.kind.wireName,
              'id': item.id,
              'payload': item.payload,
              'rev': 1,
            },
        ],
      }));

  final container = ProviderContainer(overrides: [
    preferencesProvider.overrideWith((ref) => createTestPreferences(
          keyMappings: mappings,
          stateManConfig: StateManConfig(opcua: const []),
        )),
    systemPreferencesProvider.overrideWith((ref) => createTestPreferences(
          keyMappings: mappings,
          stateManConfig: StateManConfig(opcua: const []),
        )),
    // **This is where the panel's key mappings actually come from.** Since
    // #465 the plant's wiring is `config_item` rows, and `stateManProvider`
    // reads `store.keyMappings` off this store — never the `key_mappings`
    // preference blob. A harness that seeded only `preferencesProvider`
    // (which `visible_staleness_test.dart` does, and gets away with because
    // its scripted gateway pushes its one key unasked) hands the client an
    // EMPTY mapping, and the panel subscribes to `ALARM.active` alone: link
    // ready, zero keys, every readout `---`. That was the first thing this
    // bench did.
    configStoreProvider.overrideWith((ref) => createTestConfigStore(
        keyMappings: mappings, session: kConfiguringTestSession)),
    localPreferencesProvider.overrideWithValue(local),
    databaseProvider.overrideWith((ref) async => null),
    stationNameProvider.overrideWithValue('e2e-assets-panel'),
    accessSessionProvider.overrideWith(SignedInOperator.new),
    collectorProvider.overrideWith((ref) async => null),
    stateManFactoryProvider.overrideWithValue(({
      required StateManConfig config,
      required KeyMappings keyMappings,
      List<DeviceClient> deviceClients = const [],
    }) async =>
        throw StateError('the direct-mode StateMan constructor was reached: '
            'the gateway transport row was not read, and nothing below is '
            'going over a socket')),
    gatewayStateManFactoryProvider.overrideWithValue(({
      required Uri uri,
      required ClientConfig clientConfig,
      required StateManConfig config,
      required KeyMappings keyMappings,
      String alias = '',
      RemoteStateMan Function({
        required Uri uri,
        required ClientConfig config,
        required Set<String> keys,
      })? buildRemote,
    }) =>
        GatewayStateMan.create(
          uri: uri,
          clientConfig: fastClientConfig(),
          config: config,
          keyMappings: keyMappings,
          alias: alias,
          buildRemote: buildRemote,
        )),
  ]);

  PanelBench? bench;
  try {
    final stateMan = await container.read(stateManProvider.future);
    // The claim every case rests on: the object the values come through is
    // the one a panel really has.
    if (stateMan is! GuardedStateMan) {
      throw StateError('stateManProvider answered ${stateMan.runtimeType}, '
          'not the GuardedStateMan a panel holds');
    }
    final remote = stateMan.innerAs<GatewayStateMan>()?.remote;
    if (remote == null) {
      throw StateError('the guard is not around a GatewayStateMan: this is '
          'not a gateway panel');
    }

    // Every provider that owns a timer, read HERE so the timer is real. The
    // freshness gate holds no timer but is the reason the stale arm can
    // fail; the session is read so the first tap does not build it in the
    // fake zone, where anything it listens to that owns a timer would leave
    // a fake timer pending and fail the test at teardown with a message
    // about nothing.
    container.read(valueFreshnessProvider);
    await container.read(accessSessionProvider.future);

    final keys = GatewayStateMan.subscriptionKeys(mappings);
    final witness = RemoteStateMan(
      uri: Uri.parse('ws://127.0.0.1:${gateway.server.port}'),
      config: fastClientConfig(),
      keys: mappings.nodes.keys.toSet(),
    );
    bench =
        PanelBench._(plant, gateway, link, container, remote, witness, keys);

    await until(() => remote.linkState == LinkState.ready,
        describe: 'the panel reaching ready over a real socket');
    await until(() => witness.linkState == LinkState.ready,
        describe: 'the witness reaching ready over its own socket');
    final firstKey = plantKey(
        parsed.servers.first.alias, parsed.servers.first.nodes.first.id);
    await until(() => remote.read(firstKey)?.quality.isGood ?? false,
        describe: 'the first plant value crossing PLC -> gateway -> panel and '
            'arriving GOOD');
    return bench;
  } on Object {
    if (bench != null) {
      await bench.dispose();
    } else {
      container.dispose();
      await link.shutdown();
      await gateway.stop();
      await plant.close();
    }
    rethrow;
  }
}

/// Waits for [predicate], polling in real time. For use INSIDE `runAsync`.
///
/// A window and never an instant: there are four asynchronous boundaries
/// between a PLC and a panel — the OPC UA publishing interval, the gateway's
/// ingest, the server's tick and the socket — and an instant read after any
/// of them is a race that passes on this machine and fails in CI.
Future<Duration> until(
  bool Function() predicate, {
  Duration within = const Duration(seconds: 30),
  String? describe,
}) async {
  final stopwatch = Stopwatch()..start();
  while (!predicate()) {
    if (stopwatch.elapsed > within) {
      fail('timed out after ${stopwatch.elapsed.inMilliseconds}ms waiting for '
          '${describe ?? 'a condition'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return stopwatch.elapsed;
}

/// Waits, in real time, until [predicate] holds of the WIDGET TREE.
///
/// The bridge between the two zones. Each turn lets the real world move for
/// twenty milliseconds inside `runAsync` — sockets deliver, the plant ticks,
/// the client adopts a value into its store and the key stream's subject —
/// then pumps one frame in the fake zone so the widgets rebuild from what
/// arrived. The predicate is evaluated after the pump, so it is looking at a
/// rendered frame and not at a stream.
///
/// The predicate is the only thing a case may assert on this way; a `pump`
/// with a duration would advance the FAKE clock, and the client's write and
/// control deadlines — created in the fake zone when a tap handler sends a
/// request — would then expire on a wire that has not been slow at all.
Future<Duration> pumpUntil(
  WidgetTester tester,
  bool Function() predicate, {
  Duration within = const Duration(seconds: 30),
  String? describe,
}) async {
  final stopwatch = Stopwatch()..start();
  await tester.pump();
  while (!predicate()) {
    if (stopwatch.elapsed > within) {
      fail('timed out after ${stopwatch.elapsed.inMilliseconds}ms waiting for '
          '${describe ?? 'the widget tree to reach a state'}');
    }
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
  return stopwatch.elapsed;
}

/// Pumps frames for [span] of real time and fails the moment [predicate]
/// holds of the widget tree.
///
/// The shape an honesty assertion needs: "the panel never showed a number it
/// should have withheld" is a claim about every frame in a window, and
/// checking once at the end of one is a claim about one frame.
Future<void> pumpNeverDuring(
  WidgetTester tester,
  bool Function() predicate,
  Duration span, {
  required String describe,
}) async {
  final stopwatch = Stopwatch()..start();
  while (stopwatch.elapsed < span) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    if (predicate()) {
      fail('$describe — but it was true '
          '${stopwatch.elapsed.inMilliseconds}ms in');
    }
  }
}

/// The process-wide seams a panel's provider stack reaches, pointed at memory.
///
/// Main's #465 made the device-local store a process-wide singleton that
/// `main()` opens before `runApp`, and `createDeviceLocalPreferences()` throws
/// rather than opening one lazily. Every bench builds `preferencesProvider`,
/// which reaches it, so the singleton is seeded here and reset after.
void bindPanelTestEnvironment() {
  setUp(() {
    setDeviceLocalPreferencesForTest(InMemoryPreferences());
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    SecureStorage.setInstance(FakeSecureStorage());
  });
  tearDown(resetDeviceLocalPreferencesForTest);
}

/// The session at the panel: an operator, signed in, holding `operate`.
///
/// The production controller's `build` on a gateway panel resolves to the
/// credential-less floor — no groups — and its sign-in dials the backend's
/// access stores. See the library doc for why neither is available here and
/// why fixing the identity is the honest substitution. The `_FixedSession`
/// shape from `access_templates_test.dart`, with the one session this lane
/// needs.
final class SignedInOperator extends AccessSessionController {
  @override
  Future<AccessSession> build() async => const AccessSession(
        user: AuthenticatedUser(username: 'e2e-operator', roleName: 'Operator'),
        groups: {AccessGroup.operate},
      );
}

/// Maps every series name to itself.
///
/// The fourth copy of this class, after `tfc_relay_server`'s,
/// `tfc_relay_client`'s and `tfc_relay_local`'s test support. A Dart package
/// cannot import another package's `test/` directory, and the alternative —
/// one copy in a `lib/` all four could reach — is precisely the production hole
/// `tfc_relay_local/test/support/permissive_resolver.dart` explains: a
/// resolver available in a `lib/` is the one a composition root binds, and a
/// gateway running it would police nothing. `buildGateway` requires one, and
/// nothing in this lane reads a series.
final class _PermissiveSeriesResolver implements SeriesResolver {
  const _PermissiveSeriesResolver();

  @override
  ResolvedSeries? resolve(String wireName) {
    final address = SeriesAddress.parse(wireName);
    return ResolvedSeries(
      table: address.series,
      member: address.member,
      plantKey: address.series,
    );
  }

  @override
  String? keyForTable(String table) => table;

  @override
  String? keyForNode(String nodeId) => nodeId;
}

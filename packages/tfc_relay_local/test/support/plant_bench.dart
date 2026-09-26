/// A real plant, a real gateway, and a link to the panel that can be broken.
///
/// ## What this is for, and why it is not `end_to_end_test.dart`
///
/// `end_to_end_test.dart` already stands the whole chain up — an in-process
/// OPC UA server, `OpcUaUpstreamLink`, `LocalStateMan`, `RelayServer`, a real
/// socket, `RemoteStateMan` — and proves the layers agree. It says so in its
/// own words: *"Six legs and no more… the value of an end-to-end test is that
/// it proves the layers agree, not that it re-proves each layer."* It is a
/// demonstration, and a demonstration is cooperative.
///
/// Its fault proxy sits at `targetPort: built.port` — **the PLC's port**
/// (`opcua_server_fixture.dart:256`). Every fault it can inject is upstream of
/// the gateway. The other harness, `ws_harness.dart`'s `relayFixture`, puts a
/// proxy on the **panel-facing** socket (`ws_harness.dart:338`) — but behind
/// its server sits a `FakeStateMan`, so nothing is moving underneath.
///
/// So the transmission has been attacked from the plant side with a real
/// panel, and from the panel side with a fake plant, and **never from the
/// panel side with a real plant**. That is the seam this bench exists for, and
/// it is where "the screen stops lying when the link dies" is actually
/// decided: the claim is about what a panel shows while values it was already
/// receiving keep changing at a plant it can no longer hear.
///
/// ## The one instrument a fake source cannot provide
///
/// `RunningServer.actuationCount` counts writes **at the node**, inside the
/// OPC UA server, before any answer is composed. "A write is never retried" is
/// a claim about actuations, and a duplicated command is invisible to a
/// read-back — the node holds the same number whether it was moved once or
/// twice. Only a plant that counted can tell. Every write case here asserts on
/// that count and not on what the panel was told afterwards.
///
/// ## Two proxies, and which one to reach for
///
/// * [link] — between the server and the panel. The new one. `ws://`, so the
///   bytes are the frames.
/// * [upstream] — between the gateway and a PLC, built only when asked for,
///   for a case that wants to lose a plant and a panel at once.
///
/// Nothing here throws out of the wiring, for `ws_harness.dart`'s reason: an
/// exception raised from a listener callback lands in the ambient isolate and
/// `package:test` attributes it to whichever case happens to be running.
library;

import 'dart:async';

import 'package:logger/logger.dart';
import 'package:tfc_dart/core/state_man.dart'
    show KeyMappings, KeyMappingEntry, OpcUANodeConfig;
import 'package:tfc_plant_sim/tfc_plant_sim.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/tfc_relay_server.dart' show ServerConfig;
import 'package:tfc_stateman_contract/faults.dart';
import 'package:test/test.dart';

import 'permissive_resolver.dart';

/// The namespace the plant sim publishes in, and the one a key mapping spells.
const int plantNamespace = 4;

/// The default plant: one hall, four shapes, and one node that records.
///
/// Small on purpose. A bench that stood up the demo fixture's three halls
/// would spend most of every case waiting for servers it does not assert on,
/// and a case that needs a second server asks for one.
const String defaultPlantSpec = '''
types:
  - name: RunMode
    kind: enum
    values: {0: fault, 1: stopped, 2: auto, 3: manual, 4: clean}
  - name: DriveStatus
    kind: struct
    members:
      - {name: run_mode, type: RunMode, value: 2}
      - {name: speed_hz, type: double, value: 50}
      - {name: fault_code, type: int, value: 0}
servers:
  - alias: HALL1
    nodes:
      # Moving fast, so a case can tell a withheld value from a frozen one.
      - {id: CN01.speed_hz, type: double, motion: ramp, min: 0, max: 50, period: 100ms}
      # The enum-inside-a-struct: the shape that drew every conveyor violet.
      - {id: CN01.drive, type: DriveStatus, motion: cycle, period: 300ms}
      # The actuator. Recording, so the plant counts what it was told to do.
      - {id: CN01.setpoint_kg, type: double, value: 12.5, motion: once, records: true}
      # Zero is a value, not an absence.
      - {id: CN01.rate, type: double, value: 0, motion: constant, period: 200ms}
      # Reports once and never again.
      - {id: CN01.recipe_id, type: double, value: 7, motion: once}
''';

/// The plant key a node is reached by: `<ALIAS>.<node id>`.
///
/// One spelling, derived rather than written twice: a bench whose mapping and
/// whose assertions each spelled the key out would pass while disagreeing.
String plantKey(String alias, String nodeId) => '$alias.$nodeId';

/// The whole bench: plant, gateway, the link between them and the panels.
final class PlantBench {
  PlantBench._(
    this.plant,
    this.gateway,
    this.panels,
    this.keys,
    this._link,
    this._upstream,
    this.statuses,
  );

  /// The plant. `bench.plant.servers['HALL1']!` is the lever, and
  /// `actuationCount` is the instrument.
  final FakePlant plant;

  /// The gateway: `gateway.plant` is the `LocalStateMan`, `gateway.server` the
  /// socket.
  final Gateway gateway;

  /// The panels, real `RemoteStateMan`s over a real socket.
  final List<RemoteStateMan> panels;

  /// Every key the panels subscribed to.
  final Set<String> keys;

  final FaultProxy? _link;
  final FaultProxy? _upstream;

  /// What each panel was told about its own link, in order.
  final List<List<StatusParams>> statuses;

  RemoteStateMan get panel => panels.first;

  /// The **panel-facing** link. The new lever: break this and a plant is still
  /// moving behind it.
  FaultProxy get link {
    final proxy = _link;
    if (proxy == null) {
      throw StateError('this bench was built with `breakableLink: false`; '
          'the panels are dialling the server directly and there is nothing '
          'in between to pull a lever on');
    }
    return proxy;
  }

  /// The **plant-facing** link, when one was asked for.
  FaultProxy get upstream {
    final proxy = _upstream;
    if (proxy == null) {
      throw StateError('this bench was built without an upstream proxy; pass '
          '`breakableUpstream: true` to stand one up');
    }
    return proxy;
  }

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
}

/// Stands up a plant, a gateway, a breakable link and [panels] panels.
///
/// Returns once every panel is `ready` and has a value from the plant, so a
/// case begins from a link that demonstrably worked — otherwise a case that
/// breaks the link cannot tell a fault it injected from one it inherited.
Future<PlantBench> standUpPlant({
  String spec = defaultPlantSpec,
  int panels = 1,
  bool breakableLink = true,
  bool breakableUpstream = false,
  Duration staleAfter = const Duration(seconds: 2),
  Set<String> extraKeys = const <String>{},
  ClientConfig? clientConfig,
  ServerConfig? serverConfig,
  void Function(RemoteStateMan panel)? watch,
}) async {
  final parsed = PlantSpec.parse(spec);
  final plant = await FakePlant.start(parsed);
  addTearDown(plant.close);

  // One proxy per PLC when asked for, so a case can lose one hall and keep
  // another. Keyed by alias because that is what the link config is written
  // from below.
  final upstreams = <String, FaultProxy>{};
  if (breakableUpstream) {
    for (final entry in plant.servers.entries) {
      final proxy = FaultProxy(targetPort: entry.value.port);
      await proxy.start();
      addTearDown(proxy.shutdown);
      upstreams[entry.key] = proxy;
    }
  }

  // Every node in the spec becomes a mapped key. Derived from the spec rather
  // than listed here: a bench whose mapping drifted from its plant would serve
  // `errorConfig` for the drifted keys and read as a transmission fault.
  final mappings = KeyMappings(nodes: <String, KeyMappingEntry>{
    for (final server in parsed.servers)
      for (final node in server.nodes)
        plantKey(server.alias, node.id): KeyMappingEntry()
          ..opcuaNode = (OpcUANodeConfig(
              namespace: node.namespace, identifier: node.id)
            ..serverAlias = server.alias),
  });

  final config = GatewayConfig(
    // Port zero, `end_to_end_test.dart`'s rule: a literal port collides with
    // the neighbouring worktree the moment two of these run at once, and the
    // collision reads as a bug in the code under test.
    server: serverConfig ?? ServerConfig(port: 0, tick: ServerConfig.minTick),
    links: <UpstreamLinkConfig>[
      for (final server in parsed.servers)
        UpstreamLinkConfig(
          alias: server.alias,
          protocol: UpstreamProtocol.opcUa,
          endpoint: upstreams.containsKey(server.alias)
              ? 'opc.tcp://127.0.0.1:${upstreams[server.alias]!.port}'
              : plant.servers[server.alias]!.endpoint,
          // In-process, as every OPC UA leg in this package does it: the
          // isolate is what production wants and what a test cannot reach into
          // to assert on.
          useIsolate: false,
        ),
    ],
    // Empty: this file hands `buildGateway` the mappings directly, and the
    // path is `main`'s business.
    keyMappingsPath: '',
    staleAfter: staleAfter,
  );

  final gateway = await buildGateway(
    config,
    mappings: mappings,
    log: Logger(level: Level.off),
    resolver: const PermissiveSeriesResolver(),
    // Discarded rather than printed: this file provokes faults on purpose, and
    // a suite that printed a stack per provoked error trains everyone to
    // scroll past the one that matters.
    onError: (_, __, ___) {},
  );
  addTearDown(gateway.stop);

  await gateway.plant.start();
  await gateway.server.start();

  FaultProxy? link;
  if (breakableLink) {
    link = FaultProxy(targetPort: gateway.server.port);
    await link.start();
    addTearDown(link.shutdown);
  }
  final port = link?.port ?? gateway.server.port;

  final keys = <String>{
    ...mappings.nodes.keys,
    // Both flavours of health key travel with the plant keys, as they do on a
    // real page.
    for (final server in parsed.servers) ...<String>[
      PipeKeys.upstreamConnected(server.alias),
      PipeKeys.upstreamState(server.alias),
    ],
    PipeKeys.connected,
    PipeKeys.linkDegraded,
    PipeKeys.pendingKeys,
    ...extraKeys,
  };

  final statuses = <List<StatusParams>>[];
  final dialled = <RemoteStateMan>[];
  for (var i = 0; i < panels; i++) {
    final mine = <StatusParams>[];
    statuses.add(mine);
    final client = RemoteStateMan(
      uri: Uri.parse('ws://127.0.0.1:$port'),
      config: clientConfig ?? ClientConfig(),
      keys: keys,
      onStatus: mine.add,
    );
    addTearDown(client.dispose);
    // Before the first snapshot, `end_to_end_test.dart:195-200`'s reason: a
    // stream taken after the subscribe snapshot has landed sees nothing until
    // the next value, which for a report-once key is never.
    watch?.call(client);
    dialled.add(client);
  }

  final firstKey = plantKey(parsed.servers.first.alias,
      parsed.servers.first.nodes.first.id);
  for (final client in dialled) {
    await until(() => client.linkState == LinkState.ready,
        describe: 'a panel reaching ready over a real socket');
    // **A GOOD value, not a non-null one.** `read` answers a placeholder for
    // every subscribed key the moment it is subscribed — `value: null` under
    // `Quality.uncertainNotYetKnown` (258) — so `read(key) != null` is true
    // before the plant has said anything at all. A bench that opened on that
    // gate would hand every case a panel holding nothing, and a case asserting
    // "this value is withheld" would pass because it had never arrived.
    await until(
        () => client.read(firstKey)?.quality.isGood ?? false,
        describe: 'the first plant value crossing PLC -> gateway -> panel '
            'and arriving GOOD');
  }

  return PlantBench._(
      plant, gateway, dialled, keys, link, upstreams.values.firstOrNull,
      statuses);
}

/// Waits for [predicate], polling, and returns how long it took.
///
/// **Every state read in this bench is inside one of these.** A window and
/// never an instant: there are four asynchronous boundaries between a PLC and
/// a panel — the OPC UA publishing interval, the gateway's ingest, the
/// server's tick and the socket — and an instant read after any of them is a
/// race that passes on this machine and fails in CI.
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

/// Breaks the link with [pull], waits until the panel has actually noticed,
/// then heals it with [heal] and waits until it is serving again.
///
/// **A fault that never fired makes a green case meaningless.** `killOnce()`
/// and the proxy's other levers act on the next turn of the event loop, so a
/// case that pulls one and immediately waits for `LinkState.ready` is waiting
/// for a state the link never left. Every such case would pass on a build
/// where the lever did nothing at all — which is the "can this check ever
/// fail?" class, and the class two adversarial reviews of the soak harness
/// found 27 of.
Future<void> breakAndHeal(
  PlantBench bench, {
  required void Function() pull,
  void Function()? heal,
  Duration noticed = const Duration(seconds: 30),
  Duration recovered = const Duration(seconds: 60),
}) async {
  pull();
  await until(() => bench.panel.linkState != LinkState.ready,
      within: noticed,
      describe: 'the panel to NOTICE the link was broken — if this times out '
          'the lever did nothing and every assertion after it is vacuous');
  heal?.call();
  await until(() => bench.panel.linkState == LinkState.ready,
      within: recovered, describe: 'the panel to recover the link');
}

/// Waits for [predicate] to be false for the whole of [span], or fails.
///
/// The shape an honesty assertion needs: "the panel never showed a number it
/// should have withheld" is a claim about every instant in a window, and
/// checking it once at the end of one is a claim about one instant.
Future<void> neverDuring(
  bool Function() predicate,
  Duration span, {
  required String describe,
}) async {
  final stopwatch = Stopwatch()..start();
  while (stopwatch.elapsed < span) {
    if (predicate()) {
      fail('$describe — but it was true '
          '${stopwatch.elapsed.inMilliseconds}ms in');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

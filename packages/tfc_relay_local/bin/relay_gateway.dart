/// The gateway process.
///
/// **The whole composition is visible on one screen below**, and that is this
/// file's entire value. Everything it does is a named function in
/// `lib/src/gateway_config.dart`; if `main` ever needs a second screen, the
/// thing that grew belongs in a function there rather than here.
///
/// Read it as four lines: build the plant, connect the plant, serve the plant,
/// and stop in the reverse order.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logger/logger.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart'
    show SecureStorage;
import 'package:tfc_dart/core/state_man_types.dart' show KeyMappings;
// The adapter is deliberately not on the package barrel (the seam type
// `TimeseriesSink` is the public surface); the composition root reaches it by
// its src path, exactly as 8b-02 recorded.
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show ResolvedSeries, SeriesResolver;
import 'package:tfc_relay_local/src/collect/timescale_sink.dart';
import 'package:tfc_relay_local/src/data/collection_plan_resolver.dart';
import 'package:tfc_relay_local/src/data/history_view_store.dart';
import 'package:tfc_relay_local/src/data/preference_store.dart';
import 'package:tfc_relay_local/src/data/timescale_reader.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart';

/// What this process says about itself when nobody has acknowledged what it
/// is.
///
/// Phase 13 made `centroidx-backend` the plant's one deployable and deleted
/// this binary's Dockerfile and compose fragment. The deletion is pinned by
/// `test/harness_only_test.dart`; this string is the other half, for the copy
/// of the source somebody already has on a rig.
///
/// The wording is asserted on by that test through a literal substring, so it
/// can be extended freely but the first line is load-bearing.
const String _harnessBanner = '''
=============================================================================
relay_gateway is a TEST HARNESS. It is not the plant's deployable.

The plant runs exactly one process: centroidx-backend
(packages/tfc_dart/bin/main.dart), which serves the relay WebSocket itself.
The eight M2200 weighers accept one TCP client each, so two processes owning
the plant is not a deployment choice — whichever loses the race loses the
weighers.

Pass --harness, or set CENTROIDX_RELAY_HARNESS=1, to silence this notice.
=============================================================================''';

Future<void> main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.write(gatewayUsage);
    return;
  }
  // A `--help` run is not a start, which is why this sits below the branch
  // above and above everything that binds a port: the notice is about what
  // this process *is*, and the answer only matters to somebody starting it.
  //
  // Loud, but still running. A refusal to start would break the harness
  // fixtures that shell out to this file, and a harness that has to be
  // special-cased is a harness people stop using.
  if (!args.contains('--harness') &&
      Platform.environment['CENTROIDX_RELAY_HARNESS'] != '1') {
    stderr.writeln(_harnessBanner);
  }
  // `--harness` needs no parser entry: `_configPath` looks only for `--config`
  // and ignores every other token, so an extra flag cannot reach the EX_USAGE
  // branch by being unrecognised. Checked, not assumed — the alternative was
  // stripping it from `args` here, which would be a second place that knows
  // the flag's spelling.
  final path = _configPath(args);
  if (path == null) {
    stderr.write(gatewayUsage);
    exitCode = 64; // EX_USAGE
    return;
  }

  // The level is chosen, not defaulted: this repository has already measured
  // `trace` + `PrettyPrinter` turning per-node logging into seconds of lag
  // (PR #210). A gateway logs conditions, not events.
  //
  // **`ProductionFilter` is not a preference either, and leaving it out was a
  // bug that shipped silently.** `package:logger`'s default is
  // `DevelopmentFilter`, whose whole body is inside an `assert` — so it logs
  // only when asserts are evaluated, and *"in release mode ALL logs are
  // omitted"* (`development_filter.dart:7`). `dart run` does not enable
  // asserts and `dart compile exe` cannot, so the gateway that runs at the
  // plant printed **nothing at all**: not the links it opened, not the port it
  // bound, not the reserved keys it refused, not the signal it stopped on.
  // Measured: a 25-second run against a live in-process PLC produced an empty
  // log and exit 0. A process whose only operator-facing output is suppressed
  // by its logging library's default is one nobody can diagnose, and the fault
  // it hides is the one that made somebody look.
  final log = Logger(
    filter: ProductionFilter(),
    level: Level.info,
    printer: PrefixPrinter(SimplePrinter(printTime: true)),
  );

  final config = GatewayConfig.readFile(path);
  final mappings = KeyMappings.fromJson(
      (jsonDecode(File(config.keyMappingsPath).readAsStringSync()) as Map)
          .cast<String, dynamic>());

  // Collection and history are ONE database connection, and the two halves are
  // built in this order for one reason: the reader needs the router's ingest
  // verdict to know which keys the plan may contain, and the router only
  // exists once `buildGateway` has run. So the sink and the reader are built
  // first — neither touches a database yet — and the mapping is installed into
  // [LateSeriesResolver] the moment the router exists, before the server is
  // started and therefore before any request can arrive.
  TimescaleSink? sink;
  final collection = config.collection;
  if (collection != null && collection.enabled) {
    sink = TimescaleSink(collection, publisherId: config.server.publisherId);
  }
  final held = sink;
  final resolver = LateSeriesResolver();
  final history = held == null
      ? null
      // The supplier, not the instance: `sink.start()` returns before it has
      // connected (WR-03), and the instance is replaced on reconnect.
      : TimescaleReader(database: () => held.database, resolver: resolver);
  // The same borrowed connection, and no second one: saved views live in the
  // database the sink already holds. `log.w` is the sink for the one thing
  // this store has to say — a retention horizon it could not determine, which
  // upstream would have reported as "nothing has been discarded yet" and said
  // nothing about.
  final views = held == null
      ? null
      : HistoryViewStore(database: () => held.database, log: log.w);
  // Installed BEFORE any `Preferences` is built, and process-wide because
  // that is the only scope `SecureStorage` has. `Preferences.create` asks
  // `SecureStorage.getInstance()` unconditionally and OUTSIDE the try that
  // guards the rest of it (`preferences.dart:219-220`), and the default on
  // Linux and macOS is a keychain-backed store. This gateway must never read
  // or write secret material — SEC-01, keys are mounted files — so refusing
  // is both the honest backend and one fewer thing a headless box has to
  // have. A refusal here is a bug in this process, not a deployment problem.
  SecureStorage.setInstance(const NoSecretStorage());
  final prefs = held == null
      ? null
      : PreferenceStore(database: () => held.database, log: log.w);

  final gateway = await buildGateway(config,
      mappings: mappings,
      log: log,
      resolver: resolver,
      timeseries: history,
      historyViews: views,
      preferences: prefs);

  // Once, at boot, naming every offender — HLTH-03 (T-08-51). Not one line per
  // panel that asks for one, and not a refusal to start: the rest of the file
  // is fine and a plant does not go dark for a typo.
  if (gateway.refusedKeys.isNotEmpty) {
    log.w('${gateway.refusedKeys.length} keymapping entries claim the '
        'reserved PIPE. prefix and were refused; every other entry is '
        'served: ${gateway.refusedKeys.join(', ')}');
  }

  // The same rule for the failure the rig actually shipped with
  // (RIG-TEST-FINDINGS.md F2): a mapped key no link claims looks servable to
  // every panel and answers errorConfig forever. The usual cause is an
  // `answers_to` that does not match the file's `server_alias` — the live
  // plant file says null on every OPC UA entry.
  final unclaimed = gateway.plant.router.unclaimedKeys;
  if (unclaimed.isNotEmpty) {
    log.w('${unclaimed.length} mapped keys are claimed by no configured '
        'link and will read errorConfig until the mapping or a link\'s '
        'answers_to changes: ${unclaimed.join(', ')}');
  }

  // SRV-08's status wiring is NOT here. It was, for exactly as long as it took
  // the end-to-end leg to notice that a gateway composed by anything but this
  // file announced nothing: it belongs to `buildGateway`, beside everything
  // else the composition owns, and `Gateway.stop` cancels it.
  await gateway.plant.start();

  // Collection: built only when the config's deliberate two-field act says
  // so — no block, or enabled: false, means no database object exists at all.
  CollectionRunner? runner;
  if (sink != null && collection != null) {
    // `unroutable:` is the router ingest's own verdict — the keys whose
    // mappings were refused at the door. Passed rather than re-derived, so
    // the plan cannot drift from `KeyRouter`'s rules; `Gateway.refusedKeys`
    // is NOT a substitute (it holds only the PIPE-prefix squatters).
    final plan = CollectionPlan.from(
      mappings,
      collection,
      unroutable: gateway.plant.router.lastIngest.rejected.keys.toSet(),
    );
    // **ONE plan object, read and written from.** The write side samples into
    // `CollectionEntry.table`; the read side maps a chart's plant key back to
    // the same string. Two plans built from the same file would agree until
    // the day one of them was built differently, and from that day the
    // gateway would serve history out of a table it never wrote.
    //
    // Installed before `gateway.server.start()` below, so no request is ever
    // answered against an uninstalled resolver — and the resolver refuses
    // everything until it is, rather than mapping anything by default.
    resolver.install(CollectionPlanResolver(
      plan: plan,
      router: gateway.plant.router,
    ));
    await sink.start();
    runner = CollectionRunner(
      plan: plan,
      stateMan: gateway.plant,
      sink: sink,
      health: gateway.plant.collectHealth,
    );
    // NOT awaited (WR-03): start() awaits ensureTable per entry, and on a
    // database that connects fast but answers slowly each of those is a
    // real round trip bounded only by queryTimeout — ~430 entries × 30 s of
    // sequential awaits between process start and the WebSocket existing.
    // Panels must never wait on retention registration: a database that is
    // down, slow or absent costs collection and nothing else. The startup
    // log moves to completion, where entryFailures is finally a fact; the
    // runner's own per-entry guards mean the future cannot reject in
    // ordinary operation, and the handler is for the day that stops being
    // true. stop() racing a still-starting runner is safe: collectEntry
    // re-checks _stopped across its awaits (WR-04).
    final started = runner;
    unawaited(runner.start().then((_) {
      // ONE line, 08-13's rule: a gateway whose startup is forty lines is
      // one whose real problem is invisible.
      log.i('collecting ${plan.entries.length} keys into '
          '"${collection.tablePrefix}"-prefixed tables '
          '(${plan.rejected.length} rejected, ${plan.adjusted.length} '
          'retention-adjusted, ${started.entryFailures.length} failed to '
          'start), and serving history for the same ${plan.entries.length}');
    }).catchError((Object error, StackTrace stack) {
      log.e('collection failed to start', error: error, stackTrace: stack);
    }));
  }

  await gateway.server.start();

  for (final link in config.links) {
    log.i('upstream ${link.alias}: '
        '${upstreamProtocolWireNames.entries.firstWhere(
              (e) => e.value == link.protocol,
            ).key} ${link.endpoint}');
  }
  log.i('serving on ${config.server.address.address}:${gateway.server.port}, '
      'TLS ${config.server.tls == null ? 'OFF' : 'on'}');

  final stopped = Completer<void>();
  // The handler is a named function in `lib/` — see [gatewayShutdown] for the
  // two ways the version that lived here failed, and for why "a bin/ file is
  // not addressable by any package: URI" is the reason nothing caught them.
  // Announcements off, then the server, then the links: see [Gateway.stop] for
  // what the reverse order serves a panel.
  final shutdown = gatewayShutdown(
    // Collection is torn down FIRST, with the plant side it subscribes to,
    // for 08-13's shutdown-ordering reason read from the historian's side:
    // the runner is a consumer of the plant's store and a holder of database
    // buffers, so it must stop sampling before the links it samples are
    // disposed, and its last rows must be flushed while the sink still owns
    // a connection. Then `Gateway.stop` does what it always did: the server
    // (so panels see a closed socket, not confident stale numbers), then the
    // plant and its links.
    // Each link of the chain runs even when the one before it threw
    // (IN-05): a subscription cancel throwing out of runner.stop() must not
    // abandon the sink's final flush and the gateway's own teardown.
    // gatewayShutdown still sees the first throw (it exits anyway, logging
    // it) — the finallys only keep the later links from being collateral.
    stop: () async {
      try {
        await runner?.stop();
      } finally {
        try {
          await sink?.close();
        } finally {
          await gateway.stop();
        }
      }
    },
    stopped: stopped,
    onSignal: (signal) => log.i('$signal: stopping'),
    onError: (error, stack) =>
        log.e('stop failed; exiting anyway', error: error, stackTrace: stack),
  );

  final sigint = ProcessSignal.sigint.watch().listen(shutdown);
  // SIGTERM is what a container runtime sends, and it is not deliverable on
  // Windows; the gateway's deployment target is Linux, and a listener that
  // throws at boot on a developer's machine would be worse than a signal that
  // is never raised there.
  final sigterm =
      Platform.isWindows ? null : ProcessSignal.sigterm.watch().listen(shutdown);

  await stopped.future;
  await sigint.cancel();
  await sigterm?.cancel();
}

/// The gateway's mapping, installed once — and **refusing everything until it
/// is**.
///
/// This exists to break one ordering knot and nothing else. `RelayServer`
/// takes its resolver as a required constructor argument (10-02, deliberately:
/// a resolver is the one seam where a permissive default is silent), and the
/// real resolver cannot be built until `buildGateway` has fed the `KeyRouter`,
/// because the collection plan needs the router's own ingest verdict for
/// `unroutable:` and re-deriving that verdict here would be a second spelling
/// of `KeyRouter`'s rules.
///
/// **Not a fallback.** Before [install] every lookup answers null, which
/// `SeriesResolver`'s contract defines as refuse (10-CONTEXT amendment 6: an
/// unmappable table is not served until it is mapped), and installing twice is
/// a [StateError] rather than a silent replacement. `main` installs
/// immediately after `buildGateway` returns and before `gateway.server.start()`,
/// so the uninstalled state is not reachable by any request — and a gateway
/// that does not historise never installs one, which is the correct answer for
/// a deployment with no database.
///
/// It lives in `bin/` rather than in a `lib/` deliberately: nothing can import
/// a `bin/` file, so this cannot become the resolver a second composition root
/// reaches for. The real one is `CollectionPlanResolver`, in
/// `tfc_relay_local/lib/src/data/`, and it is the only implementation in any
/// relay `lib/`.
final class LateSeriesResolver implements SeriesResolver {
  SeriesResolver? _installed;

  void install(SeriesResolver resolver) {
    if (_installed != null) {
      throw StateError('the series mapping is installed once, by the '
          'composition root. A second install is two answers to "which '
          'tables does this gateway serve", and the one that wins is '
          'whichever ran last');
    }
    _installed = resolver;
  }

  @override
  ResolvedSeries? resolve(String wireName) => _installed?.resolve(wireName);

  @override
  String? keyForTable(String table) => _installed?.keyForTable(table);

  @override
  String? keyForNode(String nodeId) => _installed?.keyForNode(nodeId);
}

/// `--config <path>` or `--config=<path>`. Both, because both get typed.
String? _configPath(List<String> args) {
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--config' && i + 1 < args.length) return args[i + 1];
    if (arg.startsWith('--config=')) return arg.substring('--config='.length);
  }
  return null;
}

/// The one object graph `centroidx-backend` serves the relay WebSocket from.
///
/// Every collaborator this phase built — the live values over the pipe, the
/// freshness sweep, the browse tree, the series resolver, the three data
/// services over the backend's own `Database`, the write router — is judged in
/// isolation by its own plan. None of that says anything about the graph the
/// **binary** constructs, and last milestone the graph the binary constructed
/// was the only one that shipped and the only one nothing had ever assembled
/// (Phase 10's CR-01, restated by 13-CONTEXT as criterion 4).
///
/// So there is exactly one function that builds it, [composeBackendRelay], and
/// exactly two callers: `bin/main.dart` and
/// `test/core/relay/backend_composition_test.dart`. A structural arm in that
/// test asserts the first of those appears **once**, because two composition
/// sites is two graphs and only one of them would be under test.
///
/// ## Why this file is under `lib/` and not in `bin/`
///
/// `bin/` is not addressable by any `package:` URI, so nothing in it can be
/// imported by a test. `tfc_relay_local`'s `buildGateway`
/// (`gateway_config.dart:586`) is here for the same reason and records the same
/// argument. That is not a style preference: it is the entire mechanism by
/// which criterion 4 is satisfiable at all. Moving any part of this graph into
/// `main` puts that part beyond the reach of every test in the workspace.
///
/// ## Allocation only. Nothing here binds, connects or starts.
///
/// [composeBackendRelay] returns the server **unstarted**, the way
/// `buildGateway` returns a gateway whose links are not open. Binding is the
/// caller's, which is what lets `bin/main.dart` print the boot line before it
/// binds — and lets the composition test assemble the whole graph without
/// opening a port.
///
/// ## What this file must never grow
///
/// A teardown on the shutdown path. [BackendRelayComposition.dispose] exists
/// for tests and for nothing else; `bin/main.dart`'s `_shutdown` is `Never`,
/// awaits nothing, and must never learn to close this server.
/// `test/core/pipe_shutdown_structure_test.dart` bans `.close(` anywhere in
/// `bin/*.dart` for that reason, and the process is about to `exit(0)` — the
/// sockets go with it.
library;

import 'package:logger/logger.dart';
import 'package:tfc_relay_server/tfc_relay_server.dart';

import '../database.dart';
import '../pipe_main_endpoint.dart';
import '../preferences.dart';
import '../state_man.dart' show KeyMappings;
import 'backend_browse.dart';
import 'backend_data_services.dart';
import 'backend_freshness.dart';
import 'backend_live_values.dart';
import 'backend_state_man.dart';
import 'backend_writes.dart';
import 'key_mapping_series_resolver.dart';
import 'relay_config.dart';

/// The access-control rule this backend ships with, **chosen here**.
///
/// `RelayServer`'s `policy` parameter has a default
/// (`relay_server.dart:146`), and a default that ships is a decision nobody
/// made. Naming it here makes changing it an edit somebody has to write down,
/// in a file a reviewer reads, rather than the silent consequence of an
/// argument nobody typed.
///
/// **The rule:** every tag is visible, and the `operate` role is what a write
/// takes — `AllVisibleOperatorWrites`, named for what it does rather than for
/// what it lacks (`key_policy.dart:120-135`). It is the right rule for SVN
/// today because there is no per-station policy data at the plant to hide
/// anything with, and a seam that hid a tag nobody configured would be policy
/// invented by the plumbing. When SVN grows a canteen wall display that must
/// not start a conveyor, this constant is where that becomes true.
///
/// **Deliberately NOT `const`.** Dart canonicalises const instances, so
/// `policy: const AllVisibleOperatorWrites()` and no argument at all are the
/// same object — indistinguishable by any assertion, which would make the
/// composition test's policy arm vacuous. A distinct instance is what lets
/// "somebody chose this" be a fact a test can read by identity.
final KeyPolicy backendRelayPolicy = AllVisibleOperatorWrites();

/// The assembled graph: everything [composeBackendRelay] built, still unstarted.
///
/// The collaborators are surfaced rather than hidden behind [server] because
/// criterion 4's arm walks them and asserts each runtime type. A graph whose
/// parts cannot be named is a graph whose parts cannot be pinned, and the fake
/// that ships is the one nothing could see.
final class BackendRelayComposition {
  BackendRelayComposition({
    required this.api,
    required this.liveValues,
    required this.freshness,
    required this.resolver,
    required this.policy,
    required this.server,
  });

  /// The `StateManApi` the server serves every session from.
  final BackendStateMan api;

  /// The live half over the pipe's cache. Wrapped by [freshness]; the adapter
  /// never reads it directly.
  final BackendLiveValues liveValues;

  /// The staleness watchdog around [liveValues], and what [api] actually reads.
  final BackendFreshnessSweep freshness;

  /// Browse node ids and history table names, from the same key mappings the
  /// pipe's workers were registered with.
  final KeyMappingSeriesResolver resolver;

  /// Who may see and who may actuate. See [backendRelayPolicy].
  final KeyPolicy policy;

  /// The listening end, **not yet listening**. `await server.start()` binds.
  final RelayServer server;

  /// Closes the server and releases the adapter.
  ///
  /// **For tests, and for nothing on the process's shutdown path.** The backend
  /// stops by `_shutdown` (`bin/main.dart:31`), which kills every acquisition
  /// worker and calls `exit(0)` without awaiting anything — an awaited teardown
  /// there has been measured at 5.76 s and is a container Docker SIGKILLs in
  /// the middle of a write. The sockets this closes go with the process anyway.
  Future<void> dispose() async {
    await server.close();
    await api.dispose();
  }
}

/// Builds the graph `centroidx-backend` serves the relay from. Allocation only.
///
/// [config] is the parsed `relay` section of the backend's own stateman file
/// (`relay_config.dart`); a null config means the relay is off and this
/// function is not called at all.
///
/// [pipe], [keyMappings], [database] and [prefs] are the four things
/// `bin/main.dart` already holds by the time it reaches the relay block. None
/// of them is created here: a composition root that opened its own database
/// connection would give the plant a second pool nobody counted.
///
/// [validator] is required when — and refused unless — [config] says the
/// composition root supplies the credential check. See the argument below.
///
/// [methodKeys] declares which mapped keys are *callables* rather than
/// variables. Production passes none and the default is none; see the paragraph
/// beside the `BackendBrowse` construction for why a contract leg passes one.
BackendRelayComposition composeBackendRelay({
  required RelayConfig config,
  required PipeMainEndpoint pipe,
  required KeyMappings keyMappings,
  required Database database,
  required Preferences prefs,
  KeyPolicy? policy,
  TokenValidator? validator,
  TimeseriesLimits? limits,
  Duration staleAfter = kBackendStaleAfter,
  Set<String> methodKeys = const <String>{},
  Logger? log,
}) {
  final logger = log ?? Logger();
  final serverConfig = config.toServerConfig();

  // ------------------------------------------------------------ credentials
  //
  // `RelayServer` throws when it is given both a `ServerConfig.auth` and an
  // explicit validator (`relay_server.dart:155`) — two sources of truth for
  // the credential check. 13-06 already makes that pair unrepresentable in the
  // config (`RelayCredentials` is a sealed three), and this function must not
  // re-introduce it at the call site by passing a `validator:` alongside an
  // `auth`. Refused here rather than forwarded, so the message names the
  // composition root instead of arriving from a server constructor in a
  // container log at 03:00 about a file somebody edited that afternoon.
  if (config.suppliesOwnValidator && validator == null) {
    throw ArgumentError('composeBackendRelay: ${config.source} declares '
        'credentials.source = "validator", which says the composition root '
        'supplies the credential check — and none was passed. A root that '
        'supplies none would leave RelayServer\'s permissive default checking '
        'tokens on the plant LAN. Pass `validator:`, or change the config to '
        '{"source": "token_file"} or {"source": "none"}');
  }
  if (!config.suppliesOwnValidator && validator != null) {
    throw ArgumentError('composeBackendRelay: a validator was passed, but '
        '${config.source} configures credentials as '
        '${config.credentials.description}. Two sources of truth for the '
        'credential check is what relay_server.dart:155 refuses; it is '
        'refused here so the refusal names the config file rather than the '
        'server constructor. Remove whichever is not the deployment');
  }

  // ------------------------------------------------------------- live values
  //
  // The real pipe. Reads are the cache and are synchronous by construction —
  // never a reach across the isolate port that could park a session, which is
  // the whole point of Phase 12.
  final liveValues = BackendLiveValues(
    pipe: pipe,
    keyMappings: keyMappings,
    staleAfter: staleAfter,
    logger: logger,
  );

  // The watchdog goes AROUND the live half, and the adapter reads through it.
  // The other order serves a value that has gone quiet to a panel still badged
  // good. The pipe is handed in as the link-transition observer, so a worker's
  // death and its respawn are each one announcement rather than a slow decay.
  final freshness = BackendFreshnessSweep(
    values: liveValues,
    staleAfter: staleAfter,
    pipe: pipe,
    logger: logger,
  );

  // --------------------------------------------------------------- discovery
  //
  // Both from the key mappings main already loaded to decide which worker got
  // spawned with which keys — so neither can disagree with the router. A browse
  // that reached into a worker is the stall this phase exists to prevent.
  final resolver = KeyMappingSeriesResolver(
    keyMappings: keyMappings,
    logger: logger,
  );

  // `methodKeys` defaults to EMPTY, and empty is the honest production answer:
  // `KeyMappingEntry` has no callable concept, so SVN's address space declares
  // no methods (13-04 Finding 1) and `bin/main.dart` passes nothing. `readValue`
  // is the SWEEP's read, not the live half's, so a detail pane shows the same
  // staleness the tag shows.
  //
  // It is a PARAMETER, and only 13-11's WebSocket contract leg passes one.
  // `checkBrowseNodeTypesDistinguishFoldersFromVariables` asserts that a
  // callable comes back typed `method` and is not expandable, and a mapping
  // cannot produce such a node however it is written — so a leg served from
  // this composition with no seam for the declared set would fail that check
  // with no bug behind it, and the only alternatives were to serve a
  // hand-assembled graph (which is what criterion 4 exists to forbid) or to
  // record the check as a gap (which criterion 1 forbids). The default keeps
  // production byte-for-byte what it was.
  final browse = BackendBrowse(
    keyMappings: keyMappings,
    readValue: freshness.read,
    methodKeys: methodKeys,
  );

  // ----------------------------------------------------------- data services
  //
  // Over the connection main already owns. `BackendHistoryViews` wants the
  // drift `AppDatabase` and `BackendTimeseries` wants the wrapper; both come
  // off the one `Database`, so there is one pool and one place it is opened.
  final timeseries = BackendTimeseries.overDatabase(
    database: database,
    resolver: resolver,
    // The ceilings' arithmetic is written out in `backend_data_services.dart`
    // beside the paragraph that justifies each number. Re-spelling one here is
    // how two numbers start disagreeing — the mistake 13-06's label scan
    // refuses for `ServerConfig`, and the same rule applies to this one.
    limits: limits ?? TimeseriesLimits(),
  );
  final historyViews = BackendHistoryViews.overDatabase(database: database.db);
  final preferences = BackendPreferences.overPreferences(prefs);

  // ------------------------------------------------------------------ writes
  //
  // Down the pipe, three-state, never auto-retried, and badging the value the
  // widget is already watching while it is in flight.
  //
  // The read-modify-write set is derived from the SAME mappings the workers
  // were registered with, for the reason the resolver above is: two derivations
  // of "which keys are array elements" is how a guard starts covering a
  // different set of keys from the one the router serves. Rig probe P4a is what
  // this argument costs when the set is absent — a blind element write answered
  // `applied` on a real PLC array.
  final writes = BackendWrites(
    pipe: pipe,
    values: freshness,
    readModifyWriteKeys: readModifyWriteKeysOf(keyMappings),
    logger: logger,
  );

  final api = BackendStateMan(
    values: freshness,
    writes: writes,
    browse: browse,
    timeseries: timeseries,
    historyViews: historyViews,
    preferences: preferences,
  );

  final chosenPolicy = policy ?? backendRelayPolicy;

  // Relay errors go to the backend's logger and not to `reportToStderr`, so a
  // session fault appears in the same stream as everything else the plant
  // prints. A message on a second stream is a message nobody correlates.
  void onError(Object error, StackTrace stack, String where) =>
      logger.e('relay: $where', error: error, stackTrace: stack);

  // **Spelled twice on purpose.** `RelayServer` tells "you configured nothing"
  // from "you configured a validator" by IDENTITY against its own
  // `permissiveDefault` (`relay_server.dart:155`), so
  // `validator: validator ?? RelayServer.permissiveDefault` would also work —
  // and would put a `validator:` argument in the source of a composition whose
  // whole promise is that it does not pass one alongside an `auth`. A promise
  // a reader can check by looking is worth six duplicated lines.
  final RelayServer server;
  if (validator == null) {
    server = RelayServer(
      api: api,
      config: serverConfig,
      // Named, never defaulted. See [backendRelayPolicy].
      policy: chosenPolicy,
      resolver: resolver,
      onError: onError,
    );
  } else {
    server = RelayServer(
      api: api,
      config: serverConfig,
      policy: chosenPolicy,
      resolver: resolver,
      validator: validator,
      onError: onError,
    );
  }

  return BackendRelayComposition(
    api: api,
    liveValues: liveValues,
    freshness: freshness,
    resolver: resolver,
    policy: chosenPolicy,
    server: server,
  );
}

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
/// for tests and for nothing else; `bin/main.dart`'s `_shutdown` awaits
/// nothing and must never learn to close this server.
/// `test/core/pipe_shutdown_structure_test.dart` bans `.close(` anywhere in
/// `bin/*.dart` for that reason, and the process is about to `exit(0)` — the
/// sockets go with it.
///
/// The one thing the shutdown path *does* reach this graph for is
/// `RelayServer.announceDraining()` — a queued 4002 close frame per socket,
/// releasing nothing and awaiting nothing, so a panel can tell a planned
/// restart from a broken network (rig probe P9). Announcing is not closing.
library;

import 'package:logger/logger.dart';
import 'package:tfc_relay_server/tfc_relay_server.dart';

import '../database.dart';
import '../pipe_main_endpoint.dart';
import '../preferences.dart';
import '../state_man.dart' show KeyMappings;
import 'backend_alarm_ack.dart';
import 'backend_alarms.dart' show AlarmAcknowledger;
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
  /// stops by `_shutdown` in `bin/main.dart`, which kills every acquisition
  /// worker, announces the drain and calls `exit(0)` without awaiting
  /// anything — an awaited teardown there has been measured at 5.76 s and is a
  /// container Docker SIGKILLs in the middle of a write. The sockets this
  /// closes go with the process anyway.
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
/// **[values] and [freshness] are now in that same category, and for a sharper
/// reason: alarms must run when this function is not called at all.** The relay
/// is off by default and SVN runs that way today (13-06), so a value source
/// that only exists inside this composition is a value source that only exists
/// when somebody has configured a WebSocket — and 14-05's alarm engine feeding
/// from it would go dark exactly where Phase 14 is aimed (D-8 / P-5). Whether
/// the plant is monitored must not be decided by a deployment choice about a
/// socket. So `bin/main.dart` builds the pair before the relay guard, hands it
/// to the engine, and passes it in here.
///
/// Supply **both or neither**; exactly one is refused below. When both are
/// given, [staleAfter] is not consulted — the pair already carries its own
/// deadline — and a disagreement between the two is logged rather than
/// silently resolved.
///
/// [alarms] is the alarm engine an accepted `ackAlarm` is handed to. Optional,
/// and null is a real deployment: a gateway composed without one refuses an
/// acknowledge by name rather than accepting it into nothing (14-12). It is
/// **not** the same argument as [values]/[freshness] — those exist because the
/// engine must run whether or not this function is called at all, whereas this
/// one exists because the *gateway* needs a way back to it.
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
  BackendLiveValues? values,
  BackendFreshnessSweep? freshness,
  AlarmAcknowledger? alarms,
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

  // ----------------------------------------------------- one value source
  //
  // Both or neither. Refused here rather than half-honoured, for the same
  // reason the two refusals above are: the mistake is a composition mistake,
  // and it must be loud at boot rather than a fault an operator meets at 03:00.
  //
  // What half a pair actually does is worse than it reads. `BackendLiveValues`
  // registers `pipe.onKeyRetired` in its constructor and
  // `BackendFreshnessSweep` registers `pipe.onWorkerDied` and
  // `onWorkerReady` — deliberately, because *"an obligation wired at a call
  // site is an obligation that can be forgotten at a call site"* (13-03). They
  // are plain fields, so the LAST object built wins and the earlier one goes
  // deaf without saying so. Supplying only `values` makes this function wrap a
  // second sweep around the caller's live half, and that second sweep takes
  // `onWorkerDied` off the sweep the caller is reading through. Supplying only
  // `freshness` is the mirror: a sweep wrapped around a live half this
  // composition does not surface, sitting beside one it built — two value
  // sources for one plant, disagreeing about which keys are stale.
  if ((values == null) != (freshness == null)) {
    throw ArgumentError('composeBackendRelay: `values` and `freshness` must be '
        'supplied together or not at all — '
        '${values == null ? '`freshness` was passed without `values`' : '`values` was passed without `freshness`'}. '
        'Each of these objects registers a pipe callback in its constructor '
        '(onKeyRetired on the live half, onWorkerDied and onWorkerReady on the '
        'sweep), and those are plain fields: a second one built here silently '
        'overwrites the caller\'s and the caller\'s object stops hearing about '
        'retired keys and dead workers. A sweep wrapped around a different '
        'live-values object is two value sources for one plant. Pass both — '
        'the pair `bin/main.dart` built for the alarm engine — or pass neither '
        'and let this function build them');
  }

  // ------------------------------------------------------------- live values
  //
  // The real pipe. Reads are the cache and are synchronous by construction —
  // never a reach across the isolate port that could park a session, which is
  // the whole point of Phase 12.
  //
  // Built here ONLY when the caller supplied none. `bin/main.dart` supplies a
  // pair, because the alarm engine needs one whether or not this function is
  // ever called — see the doc above.
  // Named `sweep` rather than `freshness` only because the parameter above owns
  // that name now. Everything downstream reads through this one.
  final BackendLiveValues liveValues;
  final BackendFreshnessSweep sweep;
  if (values != null) {
    liveValues = values;
    sweep = freshness!;
    if (liveValues.staleAfter != staleAfter) {
      logger.w('composeBackendRelay: the supplied value source carries a '
          '${liveValues.staleAfter.inSeconds}s staleness deadline and this '
          'call passed ${staleAfter.inSeconds}s. The SUPPLIED one wins — it is '
          'the pair the alarm engine is already reading through, and two '
          'deadlines for one plant is two answers to "is this value still '
          'true". Remove whichever is not the deployment');
    }
  } else {
    liveValues = BackendLiveValues(
      pipe: pipe,
      keyMappings: keyMappings,
      staleAfter: staleAfter,
      logger: logger,
    );

    // The watchdog goes AROUND the live half, and the adapter reads through it.
    // The other order serves a value that has gone quiet to a panel still
    // badged good. The pipe is handed in as the link-transition observer, so a
    // worker's death and its respawn are each one announcement rather than a
    // slow decay.
    sweep = BackendFreshnessSweep(
      values: liveValues,
      staleAfter: staleAfter,
      pipe: pipe,
      logger: logger,
    );
  }

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
    readValue: sweep.read,
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
    values: sweep,
    readModifyWriteKeys: readModifyWriteKeysOf(keyMappings),
    logger: logger,
  );

  final api = BackendStateMan(
    values: sweep,
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
  // ------------------------------------------------------------- the acks
  //
  // Null when there is no engine, and null is a real deployment rather than a
  // mistake: `tfc_relay_local`'s harness composes a gateway with none, and so
  // does every fixture in the server package. The gateway then refuses an
  // acknowledge **by name** (14-12's null-sink branch: "this gateway serves no
  // alarm engine") instead of accepting one into nothing and answering an
  // operator that it worked.
  //
  // Typed `AlarmAcknowledger` rather than `AlarmEngine` so this file names the
  // capability and not the implementation — and so a composition arm can hand
  // it a recorder and read the wiring off the server.
  final alarmAcks = alarms == null ? null : BackendAlarmAckSink(alarms);

  final RelayServer server;
  if (validator == null) {
    server = RelayServer(
      api: api,
      config: serverConfig,
      // Named, never defaulted. See [backendRelayPolicy].
      policy: chosenPolicy,
      resolver: resolver,
      alarmAcks: alarmAcks,
      onError: onError,
    );
  } else {
    server = RelayServer(
      api: api,
      config: serverConfig,
      policy: chosenPolicy,
      resolver: resolver,
      validator: validator,
      alarmAcks: alarmAcks,
      onError: onError,
    );
  }

  return BackendRelayComposition(
    api: api,
    liveValues: liveValues,
    freshness: sweep,
    resolver: resolver,
    policy: chosenPolicy,
    server: server,
  );
}

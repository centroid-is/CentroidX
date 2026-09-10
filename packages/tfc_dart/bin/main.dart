import 'dart:async';
import 'dart:io';

import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/preferences_watch.dart';
import 'package:tfc_dart/core/state_man_types.dart';
import 'package:tfc_dart/core/state_man_config_storage.dart';

import 'package:logger/logger.dart';
import 'package:tfc_dart/core/log_config.dart';
import 'package:tfc_dart/core/pipe_main_endpoint.dart';
import 'package:tfc_dart/core/relay/backend_alarm_history.dart';
import 'package:tfc_dart/core/relay/backend_alarms.dart';
import 'package:tfc_dart/core/relay/backend_composition.dart';
import 'package:tfc_dart/core/relay/backend_freshness.dart';
import 'package:tfc_dart/core/relay/backend_live_values.dart';
import 'package:tfc_dart/core/relay/relay_config.dart';
import 'package:tfc_relay_server/tfc_relay_server.dart';
import 'data_acquisition_isolate.dart';

/// Whether a shutdown is already under way.
///
/// A second SIGTERM — an operator pressing stop again, or Docker's own follow
/// up — must not schedule a second exit behind the first. It exits on the spot
/// instead: by then the workers are already dead and the drain has already been
/// announced, so there is nothing left that a further turn of the event loop
/// could deliver.
bool _shuttingDown = false;

/// The credential-and-role revocation poll (17-11, D-08), or null when the
/// relay is off or checks no token file.
///
/// Top-level so [_shutdown] can cancel it: a timer that outlives the process's
/// shutdown is a process that will not exit, and this file already learned that
/// lesson once with the config-watch restart timer. See the relay block in
/// [main] for what it does and why the interval is what it is.
Timer? _revocationTimer;

/// How often the backend re-reads the credential file and the role database and
/// closes any session whose access has been revoked (17-11).
///
/// **A named constant rather than a config knob, and ten seconds is honest.**
/// The relay section carries no poll interval and adding one would be a value
/// nobody diffs; a credential pulled off the disk should stop working in the
/// time it takes an operator to walk to the panel, and a file-digest comparison
/// plus a handful-of-rows database read at 0.1 Hz costs nothing. An env override
/// exists only so a test can drive the tick without waiting ten seconds of wall
/// clock.
Duration _revocationPollInterval() {
  final override =
      int.tryParse(Platform.environment['CENTROID_RELAY_REVOCATION_SECONDS'] ?? '');
  return Duration(seconds: override ?? 10);
}

/// The one way this process stops (PIPE-13).
///
/// Both exit paths reach it: the SIGTERM handler below and the config-watch
/// restart. Two of them existed and only one used to be thought about, which is
/// how the multi-second stall would have come back on the most common restart
/// in the plant — an operator saving a key mapping — rather than on the rare
/// one.
///
/// It kills every acquisition worker with `Isolate.immediate`, tells whatever
/// panels are connected that this is deliberate, and exits.
/// **It awaits nothing, and it must never learn to.** `StateMan.close()` awaits
/// an OPC UA `disconnect()` and `delete()`; that await has been measured at
/// 5.76 s against a server that stopped answering, and a container that takes
/// 5.76 s to stop is a container Docker SIGKILLs in the middle of whatever it
/// was doing. There is no future here for a caller to wait on — the return type
/// is `void` rather than `Future<void>` for that reason — and
/// `test/core/pipe_shutdown_structure_test.dart` scans this file and fails if
/// anything on this path grows an await.
///
/// ## Why the exit is a few turns late, and why that is not a teardown wait
///
/// The rig measured this shutdown from the other end (probe P9): every panel
/// was disconnected with **1006 and an empty reason**, which is the wire's way
/// of saying "the connection vanished" — indistinguishable from a pulled cable.
/// A panel cannot tell a planned restart from a plant-link failure, and those
/// call for opposite behaviour on the screen.
///
/// The signature used to be `Never`, and closing the sockets before `exit(0)`
/// is what changed it. **A synchronous close does not work**, and that was
/// measured rather than assumed (`drain_close_test.dart`, the `sync` arm):
/// `sink.close(4002, …)` queues the frame with a controller the socket consumer
/// drains on a *later* turn, so a process that exits in the same turn delivers
/// exactly as much as one that closed nothing — 1006.
///
/// **One turn is not enough either, and that took a second rig run to find.**
/// It is enough on a plain socket, which is all the test suite measured, and
/// the plant dials nothing but `wss://`. Probe P9's second run: the fix ran,
/// the log line below was printed, and every panel still saw 1006 — TLS off in
/// the same image and 4002 came back. A `SecureSocket` needs several rounds of
/// the event loop to encrypt and write what a plain one takes in the round it
/// is handed. `RelayServer.settleDrain()` yields a measured, hard-capped count
/// of them; `RelayServer.drainTurns` carries the numbers.
///
/// Those turns are **not** an awaited teardown, and the distinction is the
/// whole argument. Phase 12's law is about waiting on something that can hang:
/// an OPC UA `disconnect()` against a blackholed server waits on the network.
/// This waits on nothing — the workers are already dead by the line above, no
/// peer, socket or clock can extend it by a single turn, and every yield is
/// `Duration.zero`. A wall-clock budget would be the opposite: 50 ms would work
/// here and be a number nobody can argue with, and it is exactly the shape the
/// 5.76 s stall came in. If the loop is somehow wedged, the turns never come
/// and Docker's own SIGKILL ends it, which costs nothing this shutdown was
/// protecting: the acquisition isolates died synchronously, before anything was
/// deferred.
void _shutdown(PipeMainEndpoint pipe, Logger logger, String reason,
    BackendRelayComposition? relay) {
  logger.w('Shutting down ($reason): killing acquisition workers');
  // First, always, and synchronously. Everything below is a courtesy to
  // whoever is watching; this is the part that stops the plant being driven by
  // a process that is going away.
  pipe.shutdown();
  // Sync, no await, follows the config-watch restart timer's discipline: a
  // revocation poll still ticking after this would be a periodic task on a
  // process that is trying to exit. Cancelling is cheap and idempotent.
  _revocationTimer?.cancel();
  if (relay == null || _shuttingDown) exit(0);
  _shuttingDown = true;
  // Best effort by construction: the frames are queued, not flushed, and a
  // panel whose socket is not writable gets 1006 anyway. The alternative is
  // that every panel gets 1006 every time.
  relay.server.announceDraining();
  logger.w('Shutting down ($reason): told connected panels 4002 server '
      'draining; exiting after ${RelayServer.drainTurns} turns of the event '
      'loop');
  unawaited(RelayServer.settleDrain().then((_) => exit(0)));
}

void main() async {
  initLogConfig();
  final logger = Logger();

  // Main's end of the acquisition pipe: the value cache, the write router and
  // the handles PIPE-13 kills. Built here, before anything that can fail or
  // block, so the signal handler on the next line already has something to
  // kill — the workers register themselves into it as they are spawned.
  final pipe = PipeMainEndpoint();

  // Declared here and assigned much later, so the signal handler on the next
  // line can reach the relay once it exists without the handler having to be
  // registered after it. A SIGTERM that arrives before the relay is composed
  // finds null and exits immediately, which is correct: there is nobody
  // connected to tell.
  BackendRelayComposition? relay;

  // Exit cleanly on SIGTERM (Docker stop) even if stuck in a retry loop
  ProcessSignal.sigterm
      .watch()
      .listen((_) => _shutdown(pipe, logger, 'SIGTERM', relay));

  final dbConfig = await DatabaseConfig.fromEnv();
  final db = await Database.connectWithRetry(dbConfig);
  final prefs = await Preferences.create(db: db);

  final statemanConfigFilePath =
      Platform.environment['CENTROID_STATEMAN_FILE_PATH'];
  if (statemanConfigFilePath == null) {
    throw Exception("Stateman Config file path needs to be set");
  }
  final smConfig = await StateManConfigStorage.fromFile(statemanConfigFilePath);

  final keyMappings = await KeyMappings.fromPrefs(prefs, createDefault: false);

  // Alarm evaluation used to start HERE, and it is deliberately gone from this
  // point in the file (ALRM-01). What stood between these two lines was a
  // second `StateMan` — `alias: 'alarmman'`, `useIsolate: false`, built from a
  // copy of the same config — existing only so that an `AlarmMan`, the PANEL
  // class, could evaluate alarm rules on the backend. That is one extra OPC UA
  // session per configured server, against controllers that count sessions, on
  // the main isolate, to read values this process was already reading. It also
  // needed `alarmHandler.activeAlarms().listen((_) {})` — a subscription to
  // nothing, because `AlarmMan` wires its evaluators up only when somebody
  // listens.
  //
  // The replacement is `AlarmEngine`, built after the spawn loop below over the
  // pipe's own value source. `test/core/alarm_structure_test.dart` arms 1-3
  // fail if any of the three landmarks comes back.

  // Disabled servers are skipped entirely — no isolate, no connect loop.
  final opcuaServersToSpawn = smConfig.enabledOpcua;
  final jbtmServersToSpawn = smConfig.enabledJbtm;
  final modbusServersToSpawn = smConfig.enabledModbus;

  final disabledCount = smConfig.allServers.where((s) => !s.enabled).length;
  if (disabledCount > 0) {
    final names = smConfig.allServers
        .where((s) => !s.enabled)
        .map((s) => s.serverAlias ?? '<unnamed>')
        .join(', ');
    logger.i('Skipping $disabledCount disabled server(s): $names');
  }

  logger.i('Spawning ${opcuaServersToSpawn.length} OPC UA + '
      '${jbtmServersToSpawn.isEmpty ? 0 : 1} M2400 + '
      '${modbusServersToSpawn.isEmpty ? 0 : 1} Modbus DataAcquisition isolate(s)');

  // Spawn one isolate per OPC UA server
  for (final server in opcuaServersToSpawn) {
    final filtered = keyMappings.filterByServer(server.serverAlias);
    final collectedKeys = filtered.nodes.entries
        .where((e) => e.value.collect != null)
        .map((e) => e.key);
    logger.i(
        'Spawning isolate for server ${server.serverAlias} ${server.endpoint} with ${filtered.nodes.length} keys (${collectedKeys.length} collected):\n${collectedKeys.map((k) => '  - $k').join('\n')}');

    // The handle, not a discarded future: it is what the pipe writes through
    // and what shutdown kills. The keys it is registered with are this exact
    // partition, so the router cannot disagree with the spawn.
    final worker = await spawnDataAcquisitionIsolate(
      server: server,
      dbConfig: dbConfig,
      keyMappings: filtered,
    );
    pipe.addWorker(AcquisitionWorkerLink(worker), filtered.keys);
  }

  // Spawn one isolate for all M2400 servers
  if (jbtmServersToSpawn.isNotEmpty) {
    // Collect key mappings for all M2400 servers
    final m2400KeyMappings = KeyMappings(nodes: Map.fromEntries(
      keyMappings.nodes.entries.where((e) => e.value.m2400Node != null),
    ));
    final collectedKeys = m2400KeyMappings.nodes.entries
        .where((e) => e.value.collect != null)
        .map((e) => e.key);
    final aliases =
        jbtmServersToSpawn.map((s) => s.serverAlias ?? s.host).join(', ');
    logger.i(
        'Spawning M2400 isolate for [$aliases] with ${m2400KeyMappings.nodes.length} keys (${collectedKeys.length} collected):\n${collectedKeys.map((k) => '  - $k').join('\n')}');

    final worker = await spawnM2400DataAcquisitionIsolate(
      servers: jbtmServersToSpawn,
      dbConfig: dbConfig,
      keyMappings: m2400KeyMappings,
    );
    pipe.addWorker(AcquisitionWorkerLink(worker), m2400KeyMappings.keys);
  }

  // Spawn one isolate for all Modbus servers
  if (modbusServersToSpawn.isNotEmpty) {
    final modbusKeyMappings = KeyMappings(nodes: Map.fromEntries(
      keyMappings.nodes.entries.where((e) => e.value.modbusNode != null),
    ));
    final collectedKeys = modbusKeyMappings.nodes.entries
        .where((e) => e.value.collect != null)
        .map((e) => e.key);
    final aliases =
        modbusServersToSpawn.map((s) => s.serverAlias ?? s.host).join(', ');
    logger.i(
        'Spawning Modbus isolate for [$aliases] with ${modbusKeyMappings.nodes.length} keys (${collectedKeys.length} collected):\n${collectedKeys.map((k) => '  - $k').join('\n')}');

    final worker = await spawnModbusDataAcquisitionIsolate(
      servers: modbusServersToSpawn,
      dbConfig: dbConfig,
      keyMappings: modbusKeyMappings,
    );
    pipe.addWorker(AcquisitionWorkerLink(worker), modbusKeyMappings.keys);
  }

  logger.i('All isolates spawned (${pipe.workerCount} in the pipe), '
      'main thread waiting...');

  // ------------------------------------------------------- the value source
  //
  // **Built here, unconditionally, and NOT inside the relay block below.**
  //
  // `composeBackendRelay` used to build this pair for itself, and it still does
  // when nobody hands it one. But the relay is OFF BY DEFAULT and SVN runs that
  // way today, so a value source that only exists when a `relay` section exists
  // is a value source that usually does not exist — and the alarm engine below
  // reads through it. Leaving it there would mean that turning the WebSocket
  // off turns alarm evaluation off, which is a regression against the very
  // thing this file just deleted: the duplicate `alarmman` StateMan evaluated
  // unconditionally. A deployment choice about a socket must not decide whether
  // the plant is monitored (D-8 / P-5).
  //
  // There is exactly ONE pair, and that matters more than it reads.
  // `BackendLiveValues` claims `pipe.onKeyRetired` in its constructor and
  // `BackendFreshnessSweep` claims `onWorkerDied` and `onWorkerReady` in its
  // own — plain fields, last writer wins, no complaint. A second pair built
  // inside the composition would take those callbacks off this one, and this
  // one would go on serving the engine while hearing nothing about retired keys
  // or dead workers. So the pair is passed INTO `composeBackendRelay`, and that
  // function refuses half of one by name.
  //
  // The engine reads through the sweep and never through the live half: a rule
  // evaluated against a reading that stopped arriving ten seconds ago is a rule
  // asserting something about a plant it has lost touch with. 14-05's watcher
  // suspends on a non-good quality (CD-6) — which only works if something is
  // degrading the quality, and the sweep is that something.
  final liveValues = BackendLiveValues(
    pipe: pipe,
    keyMappings: keyMappings,
    staleAfter: kBackendStaleAfter,
    logger: logger,
  );
  final freshness = BackendFreshnessSweep(
    values: liveValues,
    staleAfter: kBackendStaleAfter,
    pipe: pipe,
    logger: logger,
  );

  // ------------------------------------------------------------- the alarms
  //
  // One engine, in one process, over one value source (ALRM-01, ALRM-02).
  //
  // **Two orderings are load-bearing here, and both are pinned by
  // `test/core/alarm_structure_test.dart` rather than left to the next reader's
  // judgement.**
  //
  // 1. `start()` comes after every `pipe.addWorker(...)`, which is why this
  //    block is below the spawn loops and not beside the config load. A
  //    subscribe for a key no worker owns costs no message and is silently
  //    dropped: an engine started first would start, log, publish an empty
  //    active set and never fire an alarm. Nothing throws, nothing is late, and
  //    the plant is simply unmonitored (D-7 / P-4).
  // 2. The value source is built above rather than inside the relay block, for
  //    the reason written out there.
  //
  // `clock: DateTime.now` is **the only place this literal appears on the whole
  // backend alarm path**, and that is a mechanism rather than a preference. An
  // alarm instant is a fact about the PLANT: `resolveAlarmStamp` prefers the
  // reading's own `sourceTimestamp` and labels what it used, so a `DateTime.now`
  // anywhere in `alarm.dart`, `alarm_stamp.dart`, `backend_alarms.dart`,
  // `backend_alarm_history.dart` or `alarm_rule_watcher.dart` is this machine's
  // wristwatch quietly replacing the plant's word (D-2). Arm 6 of the structural
  // test permits exactly one occurrence, here, and zero in those five files —
  // so please do not "tidy" this into a default on `AlarmEngine`.
  //
  // History is unconditional. There is no `historyToDb` and there will not be
  // one (D-6): a boolean deciding whether an object writes to a shared database
  // is a boolean somebody eventually sets wrong, and the cost is two processes
  // writing one plant's history into one table with no way to tell the copies
  // apart. This process is the one that owns the plant, so it is the one that
  // records it.
  final alarmHistory = AlarmHistoryWriter(db, logger: logger);

  final alarmEngine = AlarmEngine(
    values: freshness,
    // The backend's own `Preferences`, which IS a `PreferencesApi` — not the
    // relay's `BackendPreferences` adapter. The engine reads one row
    // (`alarm_man_config`) off the same store every other consumer reads, so
    // there is one configuration and one place it comes from.
    preferences: prefs,
    publisher: PipeStoreAlarmPublisher(pipe),
    clock: DateTime.now,
    history: alarmHistory,
    logger: logger,
  );
  // **Not wrapped in a try, and that is the opposite decision from the relay
  // block below — deliberately.** `start()` throws exactly one thing
  // (`UnsupportedError`, when a key mapping names a plant tag into the reserved
  // `ALARM.` namespace, T-14-18) and reports everything else an operator can get
  // wrong through `refusals` while carrying on. The relay's bind failure is not
  // fatal because a certificate or a busy port costs the panels their view of a
  // line that is still running; this one is fatal because a plant tag shadowing
  // `ALARM.active` would put a plant reading behind the alarm banner, and a
  // banner showing something other than the alarms is worse than no banner. It
  // is also a mistake that cannot happen by accident and is fixed in one line
  // of the key mappings.
  await alarmEngine.start();
  // What the engine is refusing to do, by name, at the level an operator's log
  // scraper already watches. Normally empty; a bad rule among two hundred costs
  // that rule and says so here rather than taking the other 199 with it.
  for (final refusal in alarmEngine.refusals) {
    logger.w('alarm engine: $refusal');
  }
  logger.i('Alarm engine started: ${alarmEngine.config?.alarms.length ?? 0} '
      'alarm(s) configured, ${alarmEngine.pendingAdoptionCount} history row(s) '
      'left open by a previous run awaiting their first verdict, history '
      '${alarmHistory.hasDatabase ? 'recorded to the database' : 'NOT recorded '
          '— no database'}');

  // ------------------------------------------------------------- the relay
  //
  // MOUNT-02. This process is the one that serves the relay WebSocket, because
  // it is the one that owns the plant: the M2200 weighers accept exactly one
  // TCP client each, so two processes talking to the line is not a deployment
  // choice somebody gets to make.
  //
  // Configured from the `relay` section of the file CENTROID_STATEMAN_FILE_PATH
  // already names, read once more here rather than threaded through the
  // generated StateManConfig. There is no gateway.json and no second config
  // world; `test/core/relay/no_gateway_json_test.dart` scans every file
  // reachable from this entrypoint and fails if the string appears.
  //
  // **Off by default.** No `relay` section means no WebSocket, one line in the
  // log saying so, and a backend that boots exactly as it does today — which is
  // what lets every plant backend at SVN take this binary before anybody turns
  // the socket on. A section with a typo in it is the opposite and throws here,
  // deliberately: a typo that read as "off" is a plant running unserved for a
  // week behind a green log (13-06).
  final relayBoot = await RelayBoot.fromStatemanFile(
    statemanConfigFilePath,
    env: Platform.environment,
  );
  // Unconditionally, on both branches. Whether the WebSocket is on is a fact
  // about this deployment that an operator must be able to read off a boot log
  // without knowing what to grep for.
  logger.i(relayBoot.bootLogLine);

  final relayConfig = relayBoot.config;
  if (relayConfig != null) {
    // Allocation only, and outside the try: a composition that refuses is a
    // configuration mistake — two credential sources, a validator nobody
    // supplied — and those are loud at boot, like a bad `relay` section.
    final composed = composeBackendRelay(
      config: relayConfig,
      pipe: pipe,
      keyMappings: keyMappings,
      database: db,
      prefs: prefs,
      // The pair built above, not a second one. See the value-source block:
      // both objects register pipe callbacks in their constructors, so a
      // composition that built its own would take them off the pair the alarm
      // engine is reading through — silently. Half a pair is refused by name.
      values: liveValues,
      freshness: freshness,
      // The engine started above, so a panel's Acknowledge has somewhere to
      // land. Without this argument the gateway refuses every acknowledge by
      // name — correctly, and uselessly: the operator is told the backend
      // serves no alarm engine while this process is running one.
      alarms: alarmEngine,
      // The boot file this process already parsed, for the per-identity
      // config family (ACCESS-04): without it every `backendConfig.*` frame
      // refuses by name (-32011) and the Server Config page is a screen with
      // nothing behind it. The same file, not a second path — one config
      // world (13-06).
      statemanFilePath: statemanConfigFilePath,
      log: logger,
    );
    // Visible to the shutdown path from here on. Assigned before `start()`
    // rather than after it: a SIGTERM that lands while the bind is in flight
    // still finds a server whose sockets — none yet — can be announced to,
    // and a failed bind leaves a composition that has nothing to drain rather
    // than a null that skips the drain for the rest of the process's life.
    relay = composed;
    try {
      // Populate the account cache the sweep resolves against BEFORE the bind,
      // so the very first hello can be graded. A no-op when the relay checks no
      // token file. See composeBackendRelay's refreshAccounts.
      await composed.refreshAccounts();
      await composed.server.start();
      logger.i('relay WebSocket bound on port ${composed.server.port}');

      // ------------------------------------------------- the revocation poll
      //
      // D-08, the hole nobody wrote down: the gateway's credential reload
      // deliberately does not own its own poll — the embedder owns
      // configuration watching — and until this call existed the embedder never
      // made it. So pulling a station's token off the disk changed nothing about
      // the session it already had, and a role demotion (which after Phase 17
      // also decides `configure` and `administer`) took effect only on the next
      // reconnect, which an operator can postpone by not reconnecting.
      //
      // Only for a token-file deployment: the digest-guarded reload throws on a
      // validator that does not read a file (a `validator`/`none` source), and
      // there is nothing to revoke there anyway.
      if (relayConfig.credentials is RelayTokenFileCredentials) {
        final interval = _revocationPollInterval();
        // Announced once, like the boot line: revocation being live is exactly
        // the kind of fact an operator must be able to read off a log, and its
        // absence has been invisible until now.
        logger.i('relay credential + role revocation poll live, every '
            '${interval.inSeconds}s (digest-guarded reload + account refresh)');
        _revocationTimer = Timer.periodic(interval, (_) async {
          // Every tick guarded: a rotation that produced a broken file — or a
          // database that blinked — must not disconnect the plant
          // (reload()'s own rule). The previously loaded credential set and the
          // previously cached accounts are both KEPT on a throw, so a later
          // good tick still revokes. Awaited inside the try rather than
          // fired-and-forgotten, because unawaited() attaches no handler.
          try {
            // The account cache first: a database-only demotion is invisible to
            // the file digest, so the resolver the sweep consults must be
            // refreshed on the same tick or the demotion never takes effect.
            await composed.refreshAccounts();
            await composed.server.reloadTokensIfChanged();
          } catch (error, stack) {
            logger.w(
                'relay revocation poll tick failed; keeping the previously '
                'loaded credentials and continuing',
                error: error,
                stackTrace: stack);
          }
        });
      }
    } catch (error, stack) {
      // **Not fatal, and this is the decision.** The plant is the job; the
      // WebSocket is a service on top of it. A backend that refuses to acquire
      // because a certificate expired or because something else already holds
      // the port is a worse outcome than a backend nobody can connect to: the
      // first stops the weighers being read and the line being controlled, the
      // second costs the panels their view of a line that is still running.
      // Warning level, named cause, and the process carries on.
      logger.w(
          'relay WebSocket failed to start; the backend keeps running the '
          'plant without it',
          error: error,
          stackTrace: stack);
    }
    // The shutdown path reaches this server for ONE thing: the 4002 close code
    // (`announceDraining`). It does not close it, does not await it and does
    // not release it — `_shutdown` kills the acquisition workers and calls
    // exit(0), and the sockets go with the process. See _shutdown above.
  }

  // Key mappings and alarm definitions were loaded above and then baked into
  // the spawned isolates; an HMI station editing them would otherwise need a
  // manual backend restart to take effect. Watch the two preference rows
  // (LISTEN/NOTIFY, with a slow digest poll as safety net) and restart the
  // whole process on a real change — the container runs with
  // `restart: unless-stopped`, so exiting cleanly relaunches with the fresh
  // config. Idle cost: one tiny server-side md5 query per poll interval.
  final pollSeconds = int.tryParse(
          Platform.environment['CENTROID_CONFIG_POLL_SECONDS'] ?? '') ??
      300;
  final configWatcher = PreferencesWatcher.forDatabase(
    db,
    keys: const {'key_mappings', 'alarm_man_config'},
    pollInterval: Duration(seconds: pollSeconds),
  );
  await configWatcher.start();
  // Quiet period so a burst of saves (an operator editing several things in a
  // row) causes one restart, not one per save. Each further change re-arms it.
  const restartQuiet = Duration(seconds: 10);
  Timer? restartTimer;
  configWatcher.changes.listen((key) {
    logger.w('Configuration "$key" changed in database; restarting backend '
        'in ${restartQuiet.inSeconds}s to apply it');
    restartTimer?.cancel();
    // The same shutdown as SIGTERM, deliberately (R-4). This path fires on
    // every operator config save, so an exit(0) that walked past the workers
    // would leave their OPC UA sessions to be torn down by process exit on the
    // most frequent restart this backend has.
    restartTimer = Timer(
      restartQuiet,
      () => _shutdown(pipe, logger, 'configuration "$key" changed', relay),
    );
  });

  // Keep main alive indefinitely
  await Completer<void>().future;
}

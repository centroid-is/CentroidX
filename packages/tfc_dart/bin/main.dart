import 'dart:async';
import 'dart:io';

import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/preferences_watch.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_dart/core/alarm.dart';

import 'package:logger/logger.dart';
import 'package:tfc_dart/core/log_config.dart';
import 'package:tfc_dart/core/pipe_main_endpoint.dart';
import 'package:tfc_dart/core/relay/backend_composition.dart';
import 'package:tfc_dart/core/relay/relay_config.dart';
import 'data_acquisition_isolate.dart';

/// Whether a shutdown is already under way.
///
/// A second SIGTERM — an operator pressing stop again, or Docker's own follow
/// up — must not schedule a second exit behind the first. It exits on the spot
/// instead: by then the workers are already dead and the drain has already been
/// announced, so there is nothing left that a further turn of the event loop
/// could deliver.
bool _shuttingDown = false;

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
/// ## Why the exit is one turn late, and why that is not a teardown wait
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
/// exactly as much as one that closed nothing — 1006. One turn of the event
/// loop is the smallest thing that works, and it delivers to twenty-five
/// simultaneous clients.
///
/// That turn is **not** an awaited teardown, and the distinction is the whole
/// argument. Phase 12's law is about waiting on something that can hang: an
/// OPC UA `disconnect()` against a blackholed server waits on the network. This
/// waits on nothing — the workers are already dead by the line above, and a
/// zero-duration timer is scheduled behind work the event loop is already
/// committed to. If that loop is somehow wedged, the timer never fires and
/// Docker's own SIGKILL ends it, which costs nothing this shutdown was
/// protecting: the acquisition isolates died synchronously, before anything was
/// deferred.
void _shutdown(PipeMainEndpoint pipe, Logger logger, String reason,
    BackendRelayComposition? relay) {
  logger.w('Shutting down ($reason): killing acquisition workers');
  // First, always, and synchronously. Everything below is a courtesy to
  // whoever is watching; this is the part that stops the plant being driven by
  // a process that is going away.
  pipe.shutdown();
  if (relay == null || _shuttingDown) exit(0);
  _shuttingDown = true;
  // Best effort by construction: the frames are queued, not flushed, and a
  // panel whose socket is not writable gets 1006 anyway. The alternative is
  // that every panel gets 1006 every time.
  relay.server.announceDraining();
  logger.w('Shutting down ($reason): told connected panels 4002 server '
      'draining; exiting on the next turn');
  Timer(Duration.zero, () => exit(0));
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
  final smConfig = await StateManConfig.fromFile(statemanConfigFilePath);

  final keyMappings = await KeyMappings.fromPrefs(prefs, createDefault: false);

  // Disable SSL for alarm StateMan to test if the issue is specific to
  // encrypted secure channel renewal
  final alarmSmConfig = smConfig.copy();
  // for (final opcuaConfig in alarmSmConfig.opcua) {
  //   opcuaConfig.sslCert = null;
  //   opcuaConfig.sslKey = null;
  //   opcuaConfig.password = null;
  //   opcuaConfig.username = null;
  // }

  // Create StateMan for alarm monitoring (with separate certificate)
  final stateMan = await StateMan.create(
    config: alarmSmConfig,
    keyMappings: keyMappings,
    useIsolate: false,
    alias: 'alarmman',
  );

  // Setup alarm monitoring with database persistence
  final alarmHandler = await AlarmMan.create(
    prefs,
    stateMan,
    historyToDb: true,
  );
  // AlarmMan only wires its evaluators up when someone listens to the active
  // stream. Nothing else in this process does, so without this subscription
  // no alarm was ever evaluated and historyToDb never wrote a row.
  alarmHandler.activeAlarms().listen((_) {});

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
      log: logger,
    );
    // Visible to the shutdown path from here on. Assigned before `start()`
    // rather than after it: a SIGTERM that lands while the bind is in flight
    // still finds a server whose sockets — none yet — can be announced to,
    // and a failed bind leaves a composition that has nothing to drain rather
    // than a null that skips the drain for the rest of the process's life.
    relay = composed;
    try {
      await composed.server.start();
      logger.i('relay WebSocket bound on port ${composed.server.port}');
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

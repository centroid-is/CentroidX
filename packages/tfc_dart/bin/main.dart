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
import 'data_acquisition_isolate.dart';

/// The one way this process stops (PIPE-13).
///
/// Both exit paths reach it: the SIGTERM handler below and the config-watch
/// restart. Two of them existed and only one used to be thought about, which is
/// how the multi-second stall would have come back on the most common restart
/// in the plant — an operator saving a key mapping — rather than on the rare
/// one.
///
/// It kills every acquisition worker with `Isolate.immediate` and then exits.
/// **It awaits nothing, and it must never learn to.** `StateMan.close()` awaits
/// an OPC UA `disconnect()` and `delete()`; that await has been measured at
/// 5.76 s against a server that stopped answering, and a container that takes
/// 5.76 s to stop is a container Docker SIGKILLs in the middle of whatever it
/// was doing. `Never` is the signature saying so: there is no future here for a
/// caller to wait on. `test/core/pipe_shutdown_structure_test.dart` scans this
/// file and fails if anything on this path grows an await.
Never _shutdown(PipeMainEndpoint pipe, Logger logger, String reason) {
  logger.w('Shutting down ($reason): killing acquisition workers');
  pipe.shutdown();
  exit(0);
}

void main() async {
  initLogConfig();
  final logger = Logger();

  // Main's end of the acquisition pipe: the value cache, the write router and
  // the handles PIPE-13 kills. Built here, before anything that can fail or
  // block, so the signal handler on the next line already has something to
  // kill — the workers register themselves into it as they are spawned.
  final pipe = PipeMainEndpoint();

  // Exit cleanly on SIGTERM (Docker stop) even if stuck in a retry loop
  ProcessSignal.sigterm
      .watch()
      .listen((_) => _shutdown(pipe, logger, 'SIGTERM'));

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
      () => _shutdown(pipe, logger, 'configuration "$key" changed'),
    );
  });

  // Keep main alive indefinitely
  await Completer<void>().future;
}

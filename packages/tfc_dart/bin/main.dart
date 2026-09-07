import 'dart:async';
import 'dart:io';

import 'package:tfc_dart/core/config/key_mapping_codec.dart' show keyMappingsOf;
import 'package:tfc_dart/core/config/key_mapping_rows.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/preferences_watch.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_dart/core/alarm.dart';

import 'package:logger/logger.dart';
import 'package:tfc_dart/core/log_config.dart';
import 'data_acquisition_isolate.dart';

void main() async {
  // Exit cleanly on SIGTERM (Docker stop) even if stuck in a retry loop
  ProcessSignal.sigterm.watch().listen((_) => exit(0));

  initLogConfig();
  final logger = Logger();

  final dbConfig = await DatabaseConfig.fromEnv();
  final db = await Database.connectWithRetry(dbConfig);
  final prefs = await Preferences.create(db: db);

  final statemanConfigFilePath =
      Platform.environment['CENTROID_STATEMAN_FILE_PATH'];
  if (statemanConfigFilePath == null) {
    throw Exception("Stateman Config file path needs to be set");
  }
  final smConfig = await StateManConfig.fromFile(statemanConfigFilePath);

  // Key mappings come from `config_item` rows, and from the old
  // `flutter_preferences.key_mappings` blob only while there are no rows to
  // read. The fallback is a read, not a dual-write: it reads the same physical
  // blob this line read before, and it exists because the backend container
  // can restart before any station has run the one-shot migration. It retires
  // itself the moment the rows are there, and goes with the blob in Phase 4.
  //
  // Post-cutover, the warning below appearing in the log means the migration
  // has not run — which is worth a line an engineer can grep for, because the
  // symptom otherwise is a backend quietly acquiring from an old key set.
  final mappingItems = await readSharedKeyMappingItems(db.db);
  final KeyMappings keyMappings;
  if (mappingItems.isNotEmpty) {
    keyMappings = keyMappingsOf(mappingItems);
    logger.i('Loaded ${keyMappings.nodes.length} key mappings from '
        'config_item rows');
  } else {
    logger.w('No config_item key_mapping rows found; falling back to the '
        'flutter_preferences.key_mappings blob. After the cutover this line '
        'means the blob → rows migration has not run.');
    keyMappings = await KeyMappings.fromPrefs(prefs, createDefault: false);
  }

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

    await spawnDataAcquisitionIsolate(
      server: server,
      dbConfig: dbConfig,
      keyMappings: filtered,
    );
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

    await spawnM2400DataAcquisitionIsolate(
      servers: jbtmServersToSpawn,
      dbConfig: dbConfig,
      keyMappings: m2400KeyMappings,
    );
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

    await spawnModbusDataAcquisitionIsolate(
      servers: modbusServersToSpawn,
      dbConfig: dbConfig,
      keyMappings: modbusKeyMappings,
    );
  }

  logger.i('All isolates spawned, main thread waiting...');

  // Key mappings and alarm definitions were loaded above and then baked into
  // the spawned isolates; an HMI station editing them would otherwise need a
  // manual backend restart to take effect. Restarting is the apply mechanism
  // here rather than an incremental re-point: the isolates hold their own
  // copies, the container runs with `restart: unless-stopped`, so exiting
  // cleanly relaunches with the fresh config, and that is the behaviour the
  // operators already know.
  //
  // The two configurations are watched by different machinery now, because
  // they live in different places. `alarm_man_config` is still a
  // `flutter_preferences` blob and keeps the digest watcher exactly as it was
  // until Phase 4. `key_mappings` is `config_item` rows, and rows are watched
  // by the `config_change` NOTIFY plus a two-integer poll — a digest over the
  // blob would only ever report that the row nobody writes any more has not
  // changed.
  final pollSeconds = int.tryParse(
          Platform.environment['CENTROID_CONFIG_POLL_SECONDS'] ?? '') ??
      300;

  // Quiet period so a burst of saves (an operator editing several things in a
  // row) causes one restart, not one per save. Each further change re-arms it.
  // One timer, armed in one place: two of them would mean a change seen by
  // both paths restarts the process twice, the second time mid-restart.
  const restartQuiet = Duration(seconds: 10);
  Timer? restartTimer;
  void restartSoon(String why) {
    logger.w('$why; restarting backend in ${restartQuiet.inSeconds}s to '
        'apply it');
    restartTimer?.cancel();
    restartTimer = Timer(restartQuiet, () => exit(0));
  }

  final configWatcher = PreferencesWatcher.forDatabase(
    db,
    keys: const {'alarm_man_config'},
    pollInterval: Duration(seconds: pollSeconds),
  );
  await configWatcher.start();
  configWatcher.changes.listen(
      (key) => restartSoon('Configuration "$key" changed in database'));

  // The rows half. Both paths answer a signal with the same cheap read and
  // restart only if the answer moved, so the notification is the fast path to
  // one check and the poll is the slow one — and a `config_change` row written
  // by something that is not a key mapping (pages, from Phase 3 on) does not
  // restart an acquisition backend that would boot to exactly the same state.
  var mappingFingerprint = await readSharedKeyMappingFingerprint(db.db);
  Future<void> checkMappings(String why) async {
    try {
      final now = await readSharedKeyMappingFingerprint(db.db);
      if (now == mappingFingerprint) return;
      mappingFingerprint = now;
      restartSoon('$why (${now.count} shared key mappings)');
    } catch (e) {
      // A failed read is not a change. Postgres being briefly unreachable is
      // the normal case on this path, and restarting on it would turn a
      // network blip into a restart loop.
      logger.w('Key-mapping check failed: $e');
    }
  }

  // `listenToChannel`'s stream *ends* when the connection carrying it dies —
  // no error, just `onDone` — so a subscriber that does not re-listen goes
  // silent for the life of the process after the first reconnect. Re-listening
  // is followed by an immediate check, so an edit made while the connection
  // was down is not waited out until the next poll.
  const relistenBackoff = Duration(seconds: 5);
  void listenForConfigChanges() {
    db.db.listenToChannel('config_change').listen(
      (_) => checkMappings('Shared configuration changed'),
      onError: (Object e) => logger.w('config_change channel error: $e'),
      onDone: () {
        logger.i('config_change channel ended; re-listening in '
            '${relistenBackoff.inSeconds}s');
        Timer(relistenBackoff, () {
          listenForConfigChanges();
          checkMappings('Shared configuration changed while disconnected');
        });
      },
    );
  }

  listenForConfigChanges();
  Timer.periodic(Duration(seconds: pollSeconds),
      (_) => checkMappings('Key mappings changed in database'));

  // Keep main alive indefinitely
  await Completer<void>().future;
}

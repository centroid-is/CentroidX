import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tfc_dart/core/config/key_mapping_codec.dart' show keyMappingsOf;
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_store.dart'
    show kPreferencesMigratedMarkerId;
import 'package:tfc_dart/core/config/key_mapping_rows.dart';
import 'package:tfc_dart/core/database.dart';
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

  final statemanConfigFilePath =
      Platform.environment['CENTROID_STATEMAN_FILE_PATH'];
  if (statemanConfigFilePath == null) {
    throw Exception("Stateman Config file path needs to be set");
  }
  final smConfig = await StateManConfig.fromFile(statemanConfigFilePath);

  // Key mappings come from `config_item` rows, and from nowhere else. The
  // `flutter_preferences.key_mappings` blob fallback retired with 04-12: it
  // existed because the backend container could restart before any station
  // had run the one-shot migration, and it is the last thing that made this
  // process a reader of a table the cutover drops.
  //
  // No rows is therefore fatal, and loudly so. A backend that invented a key
  // set would acquire nothing anybody is looking at, quietly, forever; the
  // container restarts on the throw and says which migration is missing every
  // time it does.
  final mappingItems = await readSharedKeyMappingItems(db.db);
  if (mappingItems.isEmpty) {
    throw StateError(
        'No config_item key_mapping rows: this backend is pointed at a '
        'database that holds no plant wiring at all. Either the blob → rows '
        'migration has not run (start a station, which runs it at attach), or '
        'this is the wrong database.');
  }
  final keyMappings = keyMappingsOf(mappingItems);
  logger.i('Loaded ${keyMappings.nodes.length} key mappings from '
      'config_item rows');

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

  // The alarm configuration, read as a value out of the shared row — one key,
  // through the same codec the stores write with, with no preferences object
  // in between. `AlarmMan`'s store is only ever used by `addAlarm` /
  // `removeAlarm` / `_saveConfig`, which are the alarm editor's operations;
  // this process has no editor and so has no business holding a writer.
  //
  // **It no longer writes the empty default when the row is absent.** That
  // write was inert for this process — `AlarmMan` seeds the same empty config
  // in memory either way — and it was a second author with none of the
  // station's machinery behind it: no checked group, no `origin='system'`, no
  // audit row. A process with one boot read and no reconcile cannot tell
  // "empty" from "not yet migrated", so it must not conclude "empty,
  // therefore write".
  //
  // Absent is not fatal. Alarms are one function of a process whose job is
  // acquisition; refusing to boot over them would trade the plant's data for
  // its annunciation. Which absence it is, though, is worth knowing, and the
  // migration marker is the purpose-built answer — the same question
  // `config_sync.dart`'s `_remoteIsMigrated` asks.
  final alarmConfigJson =
      await readSharedPreferenceValue(db.db, 'alarm_man_config');
  final AlarmManConfig alarmConfig;
  if (alarmConfigJson is String) {
    alarmConfig = AlarmManConfig.fromJson(jsonDecode(alarmConfigJson));
    logger.i('Loaded ${alarmConfig.alarms.length} alarms from the shared '
        'alarm_man_config row');
  } else {
    final migrated =
        await readSharedPreferenceValue(db.db, kPreferencesMigratedMarkerId) !=
            null;
    if (migrated) {
      logger.i('No alarm_man_config row and the preference migration has run: '
          'this plant has no alarms configured. Running with none.');
    } else {
      // Names the marker and not the retired table: this binary must not
      // mention that name at all, or the SC-2 gate cannot tell a log line
      // from a read. The marker is the more useful thing to grep for anyway,
      // because it is what the runbook checks.
      logger.w('No alarm_man_config row and no $kPreferencesMigratedMarkerId '
          'marker: the preference migration has not run, so the alarms this '
          'plant does have are not visible to this backend yet. Running with '
          'none — start a station, which migrates them at attach.');
    }
    alarmConfig = AlarmManConfig(alarms: []);
  }

  // Setup alarm monitoring with database persistence
  final alarmHandler = await AlarmMan.headless(
    config: alarmConfig,
    stateMan: stateMan,
    database: db,
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
  // **One watcher now.** Both configurations are `config_item` rows since
  // 04-11 moved `alarm_man_config` out of `flutter_preferences`, so both are
  // watched the same way: the `config_change` NOTIFY as the fast path and a
  // two-integer poll as the net under it. The digest watcher over the old
  // table is gone — kept until this plan only because the alarms were still
  // in it, and after the move it could only ever have reported that the row
  // nobody writes any more had not changed.
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

  // The kinds this process bakes into its isolates, and nothing else. A
  // `page` write must not restart an acquisition backend that would boot to
  // exactly the same state, and a `page_image` write must not either — an
  // operator pasting a picture would otherwise bounce the plant's data
  // acquisition.
  const watchedKinds = {ConfigKind.keyMapping, ConfigKind.preference};

  // Both paths answer a signal with the same cheap read and restart only if
  // the answer moved, so the notification is the fast path to one check and
  // the poll is the slow one.
  var mappingFingerprint = await readSharedConfigFingerprint(db.db, watchedKinds);
  Future<void> checkMappings(String why) async {
    try {
      final now = await readSharedConfigFingerprint(db.db, watchedKinds);
      if (now == mappingFingerprint) return;
      mappingFingerprint = now;
      restartSoon('$why (${now.count} shared key mapping and preference '
          'rows)');
    } catch (e) {
      // A failed read is not a change. Postgres being briefly unreachable is
      // the normal case on this path, and restarting on it would turn a
      // network blip into a restart loop.
      logger.w('Shared configuration check failed: $e');
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
      (_) => checkMappings('Shared configuration changed in database'));

  // Keep main alive indefinitely
  await Completer<void>().future;
}

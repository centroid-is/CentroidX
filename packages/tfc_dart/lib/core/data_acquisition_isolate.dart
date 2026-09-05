import 'dart:async';
import 'dart:isolate';

import 'package:logger/logger.dart';
import 'package:tfc_dart/core/collector.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/log_config.dart';
import 'package:tfc_dart/core/modbus_device_client.dart';
import 'package:tfc_dart/core/state_man.dart';

/// Configuration for spawning a DataAcquisition isolate.
class DataAcquisitionIsolateConfig {
  final Map<String, dynamic>? serverJson;
  final Map<String, dynamic> dbConfigJson;
  final Map<String, dynamic> keyMappingsJson;
  final List<Map<String, dynamic>> jbtmJson;
  final List<Map<String, dynamic>> modbusJson;
  final bool enableStatsLogging;

  DataAcquisitionIsolateConfig({
    this.serverJson,
    required this.dbConfigJson,
    required this.keyMappingsJson,
    this.jbtmJson = const [],
    this.modbusJson = const [],
    this.enableStatsLogging = false,
  });
}

/// Isolate entry point for running DataAcquisition.
///
/// Supports OPC UA (single server via [serverJson]) and/or M2400 devices
/// (multiple servers via [jbtmJson]).
///
/// The body runs inside a [runZonedGuarded] so that a stray asynchronous error
/// is logged instead of killing acquisition. Isolates are spawned with
/// `errorsAreFatal`, so before this guard existed one escaped rejection stopped
/// data collection for a whole server until the supervisor noticed. Every other
/// long-lived isolate in the product was already guarded this way — the drift
/// isolate (`_spawnGuardedIsolate`), the pool health monitor, and the UI
/// isolate — and this was the one that runs `pg.Pool` in-process, so a
/// `SocketException` surfacing from a socket callback with no Dart await chain
/// to carry it lands here and nowhere else.
///
/// Startup is deliberately NOT covered by the guard. If the setup below fails —
/// the database never comes up, the config is unusable — the error is rethrown
/// so the isolate dies and the supervisor respawns it. Swallowing that would
/// leave a live isolate with nothing running inside it, which is worse than the
/// crash it replaces: silent instead of loud, and with no path to recovery.
@pragma('vm:entry-point')
Future<void> dataAcquisitionIsolateEntry(
    DataAcquisitionIsolateConfig config) async {
  initLogConfig();
  final logger = Logger();

  // Completed only on a startup failure. Steady-state errors are handled by
  // the zone and must NOT complete it, or the isolate would exit on the first
  // recoverable hiccup.
  final startupFailed = Completer<void>();

  runZonedGuarded(
    () async {
      try {
        await _runDataAcquisition(config, logger);
      } catch (error, stack) {
        // Setup failed. Let the isolate die so the supervisor can respawn it.
        if (!startupFailed.isCompleted) {
          startupFailed.completeError(error, stack);
        }
      }
    },
    (error, stack) {
      // Steady state: log loudly and keep collecting. Loud matters — with the
      // isolate no longer dying, this line is the only evidence anything went
      // wrong, so it must never be quietened to a warning.
      logger.e(
        'Data acquisition isolate caught an unhandled error '
        '(isolate stays alive): $error\n$stack',
      );
    },
  );

  await startupFailed.future;
}

/// Sets up the acquisition stack and then parks forever.
///
/// Split out of [dataAcquisitionIsolateEntry] so the entry point can tell a
/// startup failure (fatal, respawn) from a steady-state stray error (log and
/// carry on). Everything it constructs — [StateMan], [Collector], [Database]
/// and every timer and stream they own — inherits the guarded zone.
Future<void> _runDataAcquisition(
    DataAcquisitionIsolateConfig config, Logger logger) async {
  final dbConfig = DatabaseConfig.fromJson(config.dbConfigJson);
  final keyMappings = KeyMappings.fromJson(config.keyMappingsJson);

  // Build OPC UA config
  final opcuaServers = <OpcUAConfig>[];
  String isolateName;
  if (config.serverJson != null) {
    final server = OpcUAConfig.fromJson(config.serverJson!);
    opcuaServers.add(server);
    isolateName = server.serverAlias ?? server.endpoint;
  } else if (config.jbtmJson.isNotEmpty) {
    isolateName = 'jbtm';
  } else {
    isolateName = 'modbus';
  }

  // Build M2400 configs
  final jbtmConfigs =
      config.jbtmJson.map((j) => M2400Config.fromJson(j)).toList();

  // Build Modbus configs
  final modbusConfigs =
      config.modbusJson.map((j) => ModbusConfig.fromJson(j)).toList();

  logger.i('Starting DataAcquisition isolate "$isolateName" '
      '(opcua: ${opcuaServers.length}, m2400: ${jbtmConfigs.length}, modbus: ${modbusConfigs.length})');

  final db = await Database.connectWithRetry(dbConfig, useIsolate: false);
  final smConfig = StateManConfig(
      opcua: opcuaServers, jbtm: jbtmConfigs, modbus: modbusConfigs);

  // Create M2400 device clients
  final m2400Clients = createM2400DeviceClients(jbtmConfigs);

  // Build Modbus device clients
  final modbusClients = buildModbusDeviceClients(modbusConfigs, keyMappings);

  // Combine all device clients
  final deviceClients = [...m2400Clients, ...modbusClients];

  final stateMan = await StateMan.create(
    config: smConfig,
    keyMappings: keyMappings,
    useIsolate: false, // Already in isolate, no need for nested isolates
    alias: 'data_acq',
    deviceClients: deviceClients,
  );

  // ignore: unused_local_variable
  final collector = Collector(
    config: CollectorConfig(collect: true),
    stateMan: stateMan,
    database: db,
  );

  logger.i('DataAcquisition isolate running for $isolateName');

  // Keep isolate alive indefinitely
  await Completer<void>().future;
}

/// Spawn a DataAcquisition isolate for a single OPC UA server.
/// Automatically respawns the isolate on failure with exponential backoff.
Future<void> spawnDataAcquisitionIsolate({
  required OpcUAConfig server,
  required DatabaseConfig dbConfig,
  required KeyMappings keyMappings,
  bool enableStatsLogging = false,
}) async {
  final config = DataAcquisitionIsolateConfig(
    serverJson: server.toJson(),
    dbConfigJson: dbConfig.toJson(),
    keyMappingsJson: keyMappings.toJson(),
    enableStatsLogging: enableStatsLogging,
  );

  final serverName = server.serverAlias ?? server.endpoint;
  await _spawnWithRespawn(config, serverName);
}

/// Spawn a single DataAcquisition isolate for all M2400 servers.
/// Automatically respawns on failure with exponential backoff.
Future<void> spawnM2400DataAcquisitionIsolate({
  required List<M2400Config> servers,
  required DatabaseConfig dbConfig,
  required KeyMappings keyMappings,
  bool enableStatsLogging = false,
}) async {
  final config = DataAcquisitionIsolateConfig(
    dbConfigJson: dbConfig.toJson(),
    keyMappingsJson: keyMappings.toJson(),
    jbtmJson: servers.map((s) => s.toJson()).toList(),
    enableStatsLogging: enableStatsLogging,
  );

  final aliases = servers.map((s) => s.serverAlias ?? s.host).join(', ');
  await _spawnWithRespawn(config, 'jbtm[$aliases]');
}

/// Spawn a single DataAcquisition isolate for all Modbus servers.
/// Automatically respawns on failure with exponential backoff.
Future<void> spawnModbusDataAcquisitionIsolate({
  required List<ModbusConfig> servers,
  required DatabaseConfig dbConfig,
  required KeyMappings keyMappings,
  bool enableStatsLogging = false,
}) async {
  final config = DataAcquisitionIsolateConfig(
    dbConfigJson: dbConfig.toJson(),
    keyMappingsJson: keyMappings.toJson(),
    modbusJson: servers.map((s) => s.toJson()).toList(),
    enableStatsLogging: enableStatsLogging,
  );

  final aliases = servers.map((s) => s.serverAlias ?? s.host).join(', ');
  await _spawnWithRespawn(config, 'modbus[$aliases]');
}

Future<void> _spawnWithRespawn(
    DataAcquisitionIsolateConfig config, String name) async {
  final logger = Logger();
  var restartDelay = const Duration(seconds: 2);
  const maxDelay = Duration(seconds: 30);

  // How long an isolate must stay up before we believe it is healthy and let
  // the backoff go back to its floor. Must be comfortably longer than the time
  // a doomed isolate takes to die, or a crash loop resets itself.
  const healthyAfter = Duration(seconds: 60);
  Timer? healthyTimer;

  Future<void> spawn() async {
    final errorPort = ReceivePort();
    final exitPort = ReceivePort();

    void scheduleRespawn(String reason) {
      healthyTimer?.cancel();
      errorPort.close();
      exitPort.close();
      logger.w(
          'Respawning isolate for $name in ${restartDelay.inSeconds}s ($reason)');
      Future.delayed(restartDelay, () {
        restartDelay = restartDelay * 2;
        if (restartDelay > maxDelay) restartDelay = maxDelay;
        spawn();
      });
    }

    errorPort.listen((message) {
      final error = message[0];
      final stackTrace = message[1];
      logger.e('Isolate error for $name:\n$error\n$stackTrace');
      scheduleRespawn('uncaught error');
    });

    exitPort.listen((_) {
      logger.e('Isolate exited unexpectedly for $name');
      scheduleRespawn('unexpected exit');
    });

    try {
      await Isolate.spawn(
        dataAcquisitionIsolateEntry,
        config,
        onError: errorPort.sendPort,
        onExit: exitPort.sendPort,
      );
      // Reset the backoff only once the isolate has proven it can STAY up.
      //
      // This used to reset immediately here, on a successful spawn — but a
      // doomed isolate always spawns successfully and dies afterwards, so the
      // doubling below was erased on every cycle. The delay never grew past its
      // 2s floor and `maxDelay` was unreachable: a reliably-failing isolate
      // respawned about thirty times a minute, forever, each attempt opening a
      // Postgres pool, an OPC UA session and (for the weigher isolate) eight
      // TCP sockets. That turned one dead isolate into sustained load on the
      // database and the PLCs, and buried the original error in respawn spam.
      healthyTimer?.cancel();
      healthyTimer = Timer(healthyAfter, () {
        restartDelay = const Duration(seconds: 2);
      });
    } catch (e) {
      logger.e('Failed to spawn isolate for $name: $e');
      scheduleRespawn('spawn failure');
    }
  }

  await spawn();
}

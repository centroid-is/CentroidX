import 'dart:async';
import 'dart:isolate';

import 'package:logger/logger.dart';
import 'package:meta/meta.dart' show visibleForTesting;
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

  /// Where the worker sends everything main is meant to see.
  ///
  /// Injected by the supervisor, not by the caller that builds the config —
  /// see [withToMain]. It is null only for a config that has not been handed
  /// to [_spawnWithRespawn] yet. A [SendPort] is explicitly sendable across
  /// `Isolate.spawn`, so it may live on the message object itself.
  ///
  /// This port carries three kinds of thing, distinguished by runtime type
  /// because the vocabulary is process-internal and must stay this small:
  ///   * the worker's own control [SendPort], sent once as its FIRST message —
  ///     the ready handshake;
  ///   * worker payloads (drained pipe frames, write outcomes);
  ///   * `null`, which the VM itself sends when the isolate exits — the death
  ///     sentinel. It is deliberately on this port and no other, so a single
  ///     ReceivePort's FIFO guarantee orders the worker's last batch ahead of
  ///     its own death notice. Two ports have no such guarantee, and main
  ///     would mark keys bad while their final values were still in flight.
  final SendPort? toMain;

  DataAcquisitionIsolateConfig({
    this.serverJson,
    required this.dbConfigJson,
    required this.keyMappingsJson,
    this.jbtmJson = const [],
    this.modbusJson = const [],
    this.enableStatsLogging = false,
    this.toMain,
  });

  /// The same config, addressed to [port].
  ///
  /// The supervisor owns one ReceivePort for the whole worker handle — it
  /// outlives every respawn — so this is called once, not per attempt.
  DataAcquisitionIsolateConfig withToMain(SendPort port) =>
      DataAcquisitionIsolateConfig(
        serverJson: serverJson,
        dbConfigJson: dbConfigJson,
        keyMappingsJson: keyMappingsJson,
        jbtmJson: jbtmJson,
        modbusJson: modbusJson,
        enableStatsLogging: enableStatsLogging,
        toMain: port,
      );
}

/// A supervised acquisition worker, from main's side of the port.
///
/// The handle outlives every respawn; the [Isolate] inside it is replaced.
/// That is what lets main hold one object per server — one subscription to
/// [messages], one entry in the write router — across a crash loop.
class DataAcquisitionWorker {
  DataAcquisitionWorker._(this.name, this._fromWorker);

  /// The supervisor's name for this worker (server alias, or the group name
  /// for the M2400/Modbus workers). Log-facing only.
  final String name;

  final ReceivePort _fromWorker;

  /// Single-subscription on purpose: there is exactly one main-side endpoint
  /// per worker, and a broadcast controller would silently drop everything
  /// sent between the handshake and main's `listen`.
  final StreamController<Object?> _out = StreamController<Object?>();

  final Completer<void> _firstReady = Completer<void>();

  Isolate? _isolate;
  SendPort? _controlPort;
  bool _shuttingDown = false;
  int _generation = 0;

  /// Everything the worker sent, plus `null` each time one dies.
  ///
  /// Ordering is the ReceivePort's, unaltered: a generation's payloads, then
  /// its `null`, then the next generation's control port.
  Stream<Object?> get messages => _out.stream;

  /// The live worker, or null before the first spawn and between a death and
  /// its replacement. This is what PIPE-13 kills.
  Isolate? get isolate => _isolate;

  /// The current worker's control port, or null until it handshakes.
  SendPort? get controlPort => _controlPort;

  /// Completes when the FIRST generation is ready. Later generations announce
  /// themselves by putting their control [SendPort] on [messages]; main
  /// replays its subscription snapshot from there.
  Future<void> get ready => _firstReady.future;

  /// How many workers have completed the handshake. 1 after a clean start;
  /// bumped by every respawn that gets far enough to talk.
  int get generation => _generation;

  /// True once [kill] has been called — the supervisor stops respawning.
  bool get isShuttingDown => _shuttingDown;

  /// Shut this worker down for good.
  ///
  /// `Isolate.immediate` runs no `finally` and flushes nothing: no shutdown
  /// path may await `disconnect()`/`delete()`/`StateMan.close()`, because
  /// those are what make an OPC UA teardown take seconds. Setting
  /// [_shuttingDown] first is what keeps the exit listener from reading this
  /// kill as a crash and respawning the worker we just stopped.
  void kill() {
    _shuttingDown = true;
    _isolate?.kill(priority: Isolate.immediate);
  }

  void _onSpawned(Isolate isolate) {
    _isolate = isolate;
  }

  void _onReady(SendPort control) {
    _controlPort = control;
    _generation++;
    if (!_firstReady.isCompleted) _firstReady.complete();
  }

  void _onExit() {
    _isolate = null;
    _controlPort = null;
  }

  void _forward(Object? message) {
    if (!_out.isClosed) _out.add(message);
  }

  void _dispose() {
    _fromWorker.close();
    if (!_out.isClosed) _out.close();
  }
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
Future<DataAcquisitionWorker> spawnDataAcquisitionIsolate({
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
  return _spawnWithRespawn(config, serverName);
}

/// Spawn a single DataAcquisition isolate for all M2400 servers.
/// Automatically respawns on failure with exponential backoff.
Future<DataAcquisitionWorker> spawnM2400DataAcquisitionIsolate({
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
  return _spawnWithRespawn(config, 'jbtm[$aliases]');
}

/// Spawn a single DataAcquisition isolate for all Modbus servers.
/// Automatically respawns on failure with exponential backoff.
Future<DataAcquisitionWorker> spawnModbusDataAcquisitionIsolate({
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
  return _spawnWithRespawn(config, 'modbus[$aliases]');
}

/// Test seam for [_spawnWithRespawn]: the real supervisor, driven with a
/// stand-in worker body so its lifecycle can be exercised without a Postgres
/// server, an OPC UA session or a Docker container.
///
/// [entryPoint] must be a top-level or static function — closures are not
/// sendable (dartbug.com/36983).
@visibleForTesting
Future<DataAcquisitionWorker> spawnWorkerForTest(
  DataAcquisitionIsolateConfig config,
  String name, {
  required void Function(DataAcquisitionIsolateConfig) entryPoint,
}) =>
    _spawnWithRespawn(config, name, entryPoint: entryPoint);

Future<DataAcquisitionWorker> _spawnWithRespawn(
  DataAcquisitionIsolateConfig config,
  String name, {
  void Function(DataAcquisitionIsolateConfig) entryPoint =
      dataAcquisitionIsolateEntry,
}) async {
  final logger = Logger();
  var restartDelay = const Duration(seconds: 2);
  const maxDelay = Duration(seconds: 30);

  // How long an isolate must stay up before we believe it is healthy and let
  // the backoff go back to its floor. Must be comfortably longer than the time
  // a doomed isolate takes to die, or a crash loop resets itself.
  const healthyAfter = Duration(seconds: 60);
  Timer? healthyTimer;

  // ONE port for the worker's data AND its onExit notice, for the whole life
  // of the handle. See [DataAcquisitionIsolateConfig.toMain]: sharing the port
  // is what makes `null` a death sentinel that is FIFO-ordered behind the
  // worker's last batch. It is created here, not per attempt, so main keeps a
  // single subscription across respawns.
  final fromWorker = ReceivePort();
  final handle = DataAcquisitionWorker._(name, fromWorker);
  final spawnConfig = config.withToMain(fromWorker.sendPort);

  // The current attempt's respawn trigger. The port listener below outlives
  // any one attempt, so it cannot close over a single `scheduleRespawn`.
  void Function(String reason)? respawnCurrentAttempt;

  fromWorker.listen((message) {
    if (message == null) {
      // The VM's onExit notice. Announce the death before anything else acts
      // on it — a shutting-down worker is still a worker that died, and main
      // marks its keys bad either way.
      handle._onExit();
      handle._forward(null);
      if (handle._shuttingDown) {
        handle._dispose();
        return;
      }
      logger.e('Isolate exited unexpectedly for $name');
      respawnCurrentAttempt?.call('unexpected exit');
      return;
    }
    if (message is SendPort) {
      // The handshake: the worker's first message is its control port.
      handle._onReady(message);
    }
    handle._forward(message);
  });

  Future<void> spawn() async {
    final errorPort = ReceivePort();

    // One attempt schedules at most one respawn. Both the error path and the
    // exit path can fire for the same dying worker (and a handshake timeout
    // kills the worker, producing an exit of its own), and each of those used
    // to be a separate turn of the ladder.
    var respawnScheduled = false;

    void scheduleRespawn(String reason) {
      if (handle._shuttingDown) return;
      if (respawnScheduled) return;
      respawnScheduled = true;
      healthyTimer?.cancel();
      errorPort.close();
      logger.w(
          'Respawning isolate for $name in ${restartDelay.inSeconds}s ($reason)');
      Future.delayed(restartDelay, () {
        if (handle._shuttingDown) return;
        restartDelay = restartDelay * 2;
        if (restartDelay > maxDelay) restartDelay = maxDelay;
        spawn();
      });
    }

    respawnCurrentAttempt = scheduleRespawn;

    errorPort.listen((message) {
      final error = message[0];
      final stackTrace = message[1];
      logger.e('Isolate error for $name:\n$error\n$stackTrace');
      scheduleRespawn('uncaught error');
    });

    try {
      final isolate = await Isolate.spawn(
        entryPoint,
        spawnConfig,
        onError: errorPort.sendPort,
        // Same port as the worker's data — see the listener above.
        onExit: fromWorker.sendPort,
      );
      handle._onSpawned(isolate);
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
  return handle;
}

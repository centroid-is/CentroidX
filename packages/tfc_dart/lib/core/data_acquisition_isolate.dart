import 'dart:async';
import 'dart:isolate';

import 'package:logger/logger.dart';
import 'package:meta/meta.dart' show visibleForTesting;
import 'package:tfc_dart/core/collector.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/log_config.dart';
import 'package:tfc_dart/core/modbus_device_client.dart';
import 'package:tfc_dart/core/pipe_worker_endpoint.dart';
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

/// How long a freshly spawned worker has to hand back its control port.
///
/// It bounds the spawn, so it must be short enough that a wedged worker does
/// not park main forever and long enough that a cold isolate on a loaded
/// machine is not mistaken for one. It deliberately does NOT cover standing
/// the acquisition stack up: the worker announces itself before it dials
/// Postgres or the PLC, so a database outage — which
/// [Database.connectWithRetry] rides out by design — cannot be mistaken for a
/// wedge and turned into a kill/respawn loop.
const kWorkerHandshakeDeadline = Duration(seconds: 30);

/// How long [DataAcquisitionWorker.kill]'s polite kill gets before the rude
/// one settles it. See that method for why there are two.
///
/// Sized against the two clocks it sits between: the acquisition pump yields
/// to the event loop every ~10 ms (`state_man.dart:590`), so a worker that is
/// merely busy is gone inside a tenth of this; and `pipe_shutdown_test.dart`
/// bounds the whole shutdown at 1000 ms, so even a wedged worker's escalation
/// leaves three quarters of that budget unspent.
const kWorkerKillGrace = Duration(milliseconds: 250);

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

  /// The current attempt's handshake, installed before the spawn so a worker
  /// that answers instantly cannot beat the listener to it.
  Completer<SendPort?>? _handshake;

  /// The CURRENT generation's `onError` port, held here so [_dispose] can close
  /// it.
  ///
  /// It is created per spawn attempt inside the supervisor and every respawn
  /// path closes it on the way past; a deliberate [kill] takes a different
  /// branch and used to close nothing, leaking one native port per call. A
  /// `ReceivePort` registered as a live isolate's error target is not collected
  /// on its own.
  ReceivePort? _errorPort;

  Isolate? _isolate;
  SendPort? _controlPort;
  bool _shuttingDown = false;
  int _generation = 0;
  int _handshakeTimeouts = 0;
  int _isolateErrors = 0;

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

  /// How many spawns were abandoned because the worker never handed back its
  /// control port inside the deadline.
  int get handshakeTimeouts => _handshakeTimeouts;

  /// How many uncaught errors this worker's generations have reported on their
  /// error port.
  ///
  /// Diagnostics — and the only way to observe that a killed generation's error
  /// port really was closed, since `ReceivePort` has no `isClosed` and a closed
  /// one silently drops what is sent to it.
  int get isolateErrors => _isolateErrors;

  /// The live generation's error port, for the arm that pins [kill] closing it.
  @visibleForTesting
  SendPort? get errorSendPort => _errorPort?.sendPort;

  /// True once [kill] has been called — the supervisor stops respawning.
  bool get isShuttingDown => _shuttingDown;

  /// Shut this worker down for good.
  ///
  /// Neither priority runs a `finally` or flushes anything: no shutdown path
  /// may await `disconnect()`/`delete()`/`StateMan.close()`, because those are
  /// what make an OPC UA teardown take seconds. Setting [_shuttingDown] first
  /// is what keeps the exit listener from reading this kill as a crash and
  /// respawning the worker we just stopped.
  ///
  /// ## Why the first kill is `beforeNextEvent` and not `immediate`
  ///
  /// `Isolate.immediate` interrupts the isolate wherever it is, by injecting
  /// an unwind error. A worker is inside `UA_Client_run_iterate` roughly half
  /// its wall time (`state_man.dart:590` — a 10 ms iterate, a 10 ms delay),
  /// and open62541 calls back into Dart from in there. The binding's
  /// callbacks are `NativeCallable.isolateLocal`, which the VM refuses to
  /// enter while an unwind is propagating — it does not throw, it aborts the
  /// **process**:
  ///
  ///     runtime_entry.cc: error: Cannot invoke native callback while unwind
  ///     error propagates.  isolate=<worker entry point>
  ///     … UA_Client_run_iterate → processServiceResponse
  ///       → backgroundPublish → processPublishResponse → [Dart] → FATAL
  ///
  /// That is a SIGABRT of the whole backend, taking the main isolate with it,
  /// and it is a coin flip on every shutdown with a subscribed server
  /// attached. macOS CI hit it first; nothing about it is macOS-specific.
  ///
  /// `beforeNextEvent` injects nothing. The in-flight `run_iterate` and its
  /// callbacks finish normally and the isolate dies at the next event-loop
  /// boundary — which the pump reaches every ~10 ms at its `await`, so this
  /// costs milliseconds, not the seconds a graceful `close()` costs.
  ///
  /// ## Why `immediate` is still here, on a timer
  ///
  /// `beforeNextEvent` cannot stop an isolate that never yields — a worker
  /// wedged in a blocking native call would simply not die, and a backend
  /// that does not stop when told is the failure this whole phase exists to
  /// prevent. So the polite kill gets [kWorkerKillGrace] and the rude one settles
  /// it. The escalation is a `Timer`, never an `await`: [kill] returns to its
  /// caller in the same turn it was called in, exactly as before.
  void kill() {
    _shuttingDown = true;
    final isolate = _isolate;
    if (isolate == null) return;
    isolate.kill(priority: Isolate.beforeNextEvent);
    Timer(kWorkerKillGrace, () {
      // Identity, not null-ness. `_onExit` clears `_isolate` when the polite
      // kill lands, so a worker that took it gets no second kill — but if a
      // respawn that was already in flight when [kill] was called got there
      // first, `_isolate` is a DIFFERENT isolate, and shooting it with
      // `immediate` would be the abort this method exists to avoid, aimed at
      // the wrong target. The hammer only ever hits the isolate it was raised
      // against.
      if (identical(_isolate, isolate)) {
        isolate.kill(priority: Isolate.immediate);
      }
    });
  }

  void _onSpawned(Isolate isolate) {
    _isolate = isolate;
  }

  void _onReady(SendPort control) {
    _controlPort = control;
    _generation++;
    if (!_firstReady.isCompleted) _firstReady.complete();
    final handshake = _handshake;
    if (handshake != null && !handshake.isCompleted) {
      handshake.complete(control);
    }
  }

  void _onExit() {
    _isolate = null;
    _controlPort = null;
    // A worker that died before it answered has answered: with nothing. The
    // spawn must not sit out the rest of the deadline for a corpse.
    final handshake = _handshake;
    if (handshake != null && !handshake.isCompleted) handshake.complete(null);
  }

  void _forward(Object? message) {
    if (!_out.isClosed) _out.add(message);
  }

  void _dispose() {
    _fromWorker.close();
    // The last generation's error port goes with it. This is the ONLY place a
    // deliberate kill can close it: the exit listener's shutdown branch
    // returns before `scheduleRespawn`, which is where every crash path closes
    // it, so without this line each kill() left one open ReceivePort behind —
    // still registered as the (now dead) isolate's onError target, and so not
    // reclaimed. Masked in production by the `exit(0)` right behind
    // `pipe.shutdown()`, but not for anything that kills a worker and keeps
    // running, which the pipe's own suites do repeatedly.
    //
    // Deliberately NOT closed on the crash path's way through this listener:
    // the error message and the exit notice travel on two different ports, so
    // closing the error port on the exit could discard an error still in
    // flight and lose the only log line that says what killed the worker.
    // `scheduleRespawn` closes it there instead, once the error has landed.
    _errorPort?.close();
    _errorPort = null;
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
        DataAcquisitionIsolateConfig config) =>
    runAcquisitionIsolate(config);

/// [dataAcquisitionIsolateEntry]'s whole body, with the [Database] as a
/// parameter.
///
/// The production entry point above is this function and nothing else, so a
/// caller that spawns it gets the real worker: the same handshake before the
/// database, the same [PipeControlInbox] holding the control port from that
/// instant, the same `runZonedGuarded` split between a fatal startup and a
/// survivable steady state, the same [PipeWorkerEndpoint] attached the moment
/// the stack is up.
///
/// It is split out because [buildAcquisitionStack]'s `database` seam (OQ-3)
/// was reachable only from a private function, and an isolate entry point must
/// be a top-level one. Without this, an integration test that wants a real
/// worker against a real PLC but no Postgres has to hand-assemble the entry
/// body — and a hand-assembled copy of the thing under test proves only that
/// the copy works. Pass a [Database] and [Database.connectWithRetry] is never
/// called; pass nothing, which production does, and it connects for real.
@visibleForTesting
Future<void> runAcquisitionIsolate(
  DataAcquisitionIsolateConfig config, {
  Database? database,
}) async {
  initLogConfig();
  final logger = Logger();

  // The handshake, and the FIRST thing this isolate does.
  //
  // It says "this worker exists and can be talked to", NOT "acquisition is
  // running". Sent here rather than after the stack is up because the two
  // failures look identical from main otherwise: a database that is down —
  // which Database.connectWithRetry rides out by design, for hours if it has
  // to — would silently blow the supervisor's handshake deadline and get a
  // patiently-waiting worker killed and respawned on the backoff ladder.
  //
  // The inbox is the control port's listener from this instant on, which is
  // before the acquisition stack exists. Anything main sends into that window
  // is held (subscribes/unsubscribes) or answered on the spot (writes, which
  // must never be executed late) — see [PipeControlInbox]. The pipe endpoint
  // attaches to it as soon as `StateMan` is up.
  final control = ReceivePort();
  final inbox = PipeControlInbox(toMain: config.toMain);
  control.listen(inbox.receive);
  config.toMain?.send(control.sendPort);

  // Completed only on a startup failure. Steady-state errors are handled by
  // the zone and must NOT complete it, or the isolate would exit on the first
  // recoverable hiccup.
  final startupFailed = Completer<void>();

  runZonedGuarded(
    () async {
      try {
        await _runDataAcquisition(config, logger,
            database: database, inbox: inbox);
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
///
/// [database] is the seam that lets the worker stand up with no Postgres
/// behind it: pass one and [Database.connectWithRetry] is never called. Null
/// — the production case — means connect for real.
///
/// [inbox] is the control port's listener, created by the entry point before
/// the handshake. Passing it here is what lets the pipe endpoint — which needs
/// the live [StateMan] and therefore cannot exist before this point — take over
/// a port main has already been holding, without a single control message being
/// dropped in between.
Future<void> _runDataAcquisition(
  DataAcquisitionIsolateConfig config,
  Logger logger, {
  Database? database,
  PipeControlInbox? inbox,
}) async {
  final stack =
      await buildAcquisitionStack(config, logger, database: database);

  // The worker's end of the pipe. It needs the live StateMan and the SendPort
  // main handed us at spawn, and nothing else. Without a `toMain` there is
  // nobody to pipe to (a config built by a caller that never went through the
  // supervisor), so the endpoint is simply not built.
  final toMain = config.toMain;
  if (inbox != null && toMain != null) {
    inbox.attach(PipeWorkerEndpoint(
      stateMan: StateManUpstream(stack.stateMan),
      toMain: toMain,
      logger: logger,
    ));
  }

  logger.i('DataAcquisition isolate running for ${stack.name}');

  // Keep isolate alive indefinitely
  await Completer<void>().future;
}

/// Everything the worker assembles before it parks.
///
/// Named so a test can hold it: the acquisition stack used to exist only as
/// locals inside a function that never returns, which is why nothing could
/// assert anything about it without a database and a PLC.
class AcquisitionStack {
  const AcquisitionStack({
    required this.name,
    required this.database,
    required this.stateMan,
    required this.collector,
  });

  /// What this worker calls itself in the logs: the OPC UA server's alias, or
  /// `jbtm`/`modbus` for the grouped workers.
  final String name;
  final Database database;
  final StateMan stateMan;
  final Collector collector;
}

/// Builds the acquisition stack — everything [_runDataAcquisition] does except
/// park.
///
/// Public (and [visibleForTesting]) only because the park makes the caller
/// unobservable; production goes through [_runDataAcquisition].
@visibleForTesting
Future<AcquisitionStack> buildAcquisitionStack(
  DataAcquisitionIsolateConfig config,
  Logger logger, {
  Database? database,
}) async {
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

  // An injected Database is already open — connecting again is the one thing
  // this seam exists to avoid.
  final db =
      database ?? await Database.connectWithRetry(dbConfig, useIsolate: false);
  final smConfig = StateManConfig(
      opcua: opcuaServers, jbtm: jbtmConfigs, modbus: modbusConfigs);

  // Create M2400 device clients
  final m2400Clients = createM2400DeviceClients(jbtmConfigs);

  // Build Modbus device clients
  final modbusClients = buildModbusDeviceClients(modbusConfigs, keyMappings);

  // Combine all device clients
  final deviceClients = [...m2400Clients, ...modbusClients];

  final stateMan = await OpcUaStateMan.create(
    config: smConfig,
    keyMappings: keyMappings,
    useIsolate: false, // Already in isolate, no need for nested isolates
    alias: 'data_acq',
    deviceClients: deviceClients,
  );

  final collector = Collector(
    config: CollectorConfig(collect: true),
    stateMan: stateMan,
    database: db,
  );

  return AcquisitionStack(
    name: isolateName,
    database: db,
    stateMan: stateMan,
    collector: collector,
  );
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
  Duration readyDeadline = kWorkerHandshakeDeadline,
}) =>
    _spawnWithRespawn(config, name,
        entryPoint: entryPoint, readyDeadline: readyDeadline);

Future<DataAcquisitionWorker> _spawnWithRespawn(
  DataAcquisitionIsolateConfig config,
  String name, {
  void Function(DataAcquisitionIsolateConfig) entryPoint =
      dataAcquisitionIsolateEntry,
  Duration readyDeadline = kWorkerHandshakeDeadline,
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
    // Held on the handle so the shutdown branch of the exit listener — which
    // never reaches `scheduleRespawn` — can still close it. See
    // [DataAcquisitionWorker._errorPort].
    handle._errorPort = errorPort;

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
      handle._isolateErrors++;
      final error = message[0];
      final stackTrace = message[1];
      logger.e('Isolate error for $name:\n$error\n$stackTrace');
      scheduleRespawn('uncaught error');
    });

    // Installed BEFORE the spawn: a worker that answers on its first turn
    // would otherwise reach the port listener while there is nothing to
    // complete, and the handshake would time out on a perfectly healthy
    // worker.
    final handshake = Completer<SendPort?>();
    handle._handshake = handshake;

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

      // The handshake. Bounded, because a worker can be alive and useless:
      // spawned, never wedged enough to die, never far enough along to talk.
      // Waiting on that forever parks main at startup with no diagnosis. On
      // expiry the wedged worker is killed — leaving it running beside its
      // replacement is two live sessions on one server — and the failure
      // rides the EXISTING backoff ladder rather than a second one of its own.
      final control =
          await handshake.future.timeout(readyDeadline, onTimeout: () => null);
      if (control == null && !handle._shuttingDown && !respawnScheduled) {
        handle._handshakeTimeouts++;
        logger.e('Isolate for $name never sent its control port within '
            '${readyDeadline.inSeconds}s; killing it');
        isolate.kill(priority: Isolate.immediate);
        scheduleRespawn('handshake timeout');
      }
    } catch (e) {
      logger.e('Failed to spawn isolate for $name: $e');
      scheduleRespawn('spawn failure');
    }
  }

  await spawn();
  return handle;
}

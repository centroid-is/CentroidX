import 'dart:async';
import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';

import '../proxy.dart';

final dockerComposePath = '${Directory.current.path}/test/integration';
const databaseName = 'testdb';

/// The Compose project name for this test process.
///
/// Compose derives its default project name from the basename of the directory
/// holding the compose file. Every worktree's copy lives at
/// `.../test/integration`, so every worktree used to resolve to the same
/// project, `integration` -- and Compose scopes container names, networks and
/// `down` by project.
///
/// The consequence was not a bind error, which is why this went undiagnosed for
/// so long. The second run's `up` found the first run's container already
/// matching the project and reported `Container test-db Running`, attaching to
/// a database another suite was using; the second run's `down` then stopped and
/// removed that container out from under it. The first run failed with
/// connection errors indistinguishable from a genuine resilience bug.
///
/// Scoping by pid (not by path) is what makes this correct rather than merely
/// better: two runs in the *same* checkout collide too.
///
/// Scoped to the process and no further, deliberately. Every suite in this run
/// shares this one project, exactly as they used to share the container called
/// `test-db`, because that sharing is what makes the lane tolerant of the
/// runner overlapping one suite's `tearDownAll` with the next suite's
/// `setUpAll`: `up` on an already-running project is a no-op instead of a
/// recreate. Scoping per *suite* was tried and measured -- it made each suite
/// build its own database and turned the lane from 2m53s into 17m51s, with
/// five suites failing set-up outright.
final composeProjectName = 'tfcdart-it-$pid';

/// The `-p <project>` prefix every Compose invocation in this file shares.
List<String> get _composeArgs =>
    ['compose', '-p', composeProjectName];

/// Where the host port for this run is recorded.
///
/// `dart test` runs each suite in its own isolate, so top-level state is *not*
/// shared between them -- but the port must be, or suites would disagree about
/// where the shared database is. A pid-scoped file is the handshake: the first
/// isolate to need a port picks one and writes it, and every later isolate
/// reads it back. It lives under `.dart_tool/`, which is already ignored, and
/// is scoped by pid so concurrent runs never read each other's.
File get _portFile =>
    File('${Directory.current.path}/.dart_tool/tfc_it_port_$pid');

/// The host port to publish the database on, agreed across this run's isolates.
///
/// **This has a race and the retry in [startDockerCompose] is why it is
/// tolerable.** Binding to port 0 and closing tells us a port that was free a
/// moment ago; between that close and Docker's bind, anything on the machine
/// can take it. The window is small and it is not zero.
///
/// It is not avoidable here the way it is elsewhere. Reading the port back from
/// `docker compose port` after an ephemeral publish *is* race-free, and that is
/// what the first version of this fix did -- but it makes the address change
/// every time the container is recreated, and the suites in this lane recreate
/// it constantly. A run-stable address is worth a bounded, retried race; a
/// moving one cost five failing suites.
Future<int> _reserveHostPort() async {
  final file = _portFile;
  if (file.existsSync()) {
    final recorded = int.tryParse(file.readAsStringSync().trim());
    if (recorded != null) return recorded;
  }

  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();

  file.parent.createSync(recursive: true);
  file.writeAsStringSync('$port');
  return port;
}

/// True when a native (non-Docker) TimescaleDB is provided externally.
/// Set TIMESCALEDB_EXTERNAL=1 in the environment to enable this mode.
bool get _useExternalDb =>
    Platform.environment['TIMESCALEDB_EXTERNAL'] == '1';

/// Simulates a database outage by switching the TCP proxy to reject mode.
/// The proxy keeps listening but immediately destroys incoming connections,
/// giving an instant connection-reset on all platforms (including Windows,
/// where closing the socket causes a slow connect-timeout instead of
/// ECONNREFUSED).
Future<void> stopTimescaleDb() async {
  await _dbProxy.reject();
  print('[db-proxy] rejecting connections');
}

/// Simulates database recovery by restarting the TCP proxy.
Future<void> startTimescaleDb() async {
  await _dbProxy.start();
  print('[db-proxy] forwarding on ${_dbProxy.port} → $_realPgPort');
  await waitForDatabaseReady();
}

// ---------------------------------------------------------------------------
// TCP proxy – sits between tests and PostgreSQL.
// To simulate DB outage: reject via the proxy.
// To simulate recovery: restart the proxy.
// PostgreSQL stays running the entire time – no platform-specific stop/start.
// ---------------------------------------------------------------------------

/// Port the database is reachable on directly, behind the proxy.
///
/// Under Docker this is whatever host port Compose published for the container
/// and is only known after `up`; under `TIMESCALEDB_EXTERNAL=1` it is the
/// conventional 5432 unless `TIMESCALEDB_PORT` says otherwise.
int _realPgPort = int.tryParse(
        Platform.environment['TIMESCALEDB_PORT'] ?? '') ??
    5432;

/// The proxy every test connects through.
///
/// `listenPort` is left at 0 on purpose. The old value was a literal, 15432,
/// which two worktrees fought over; the kernel picks this one and the socket it
/// picks is the socket that serves, so there is no window in which the number
/// is chosen but unowned. See [TcpProxy.start].
///
/// It is created once per isolate and never rebound, so the address handed out
/// by [getTestConfig] stays valid across a stop/start cycle even though the
/// database behind it was recreated. [TcpProxy.targetPort] is set once the
/// reserved host port is known.
final _dbProxy = TcpProxy(targetPort: _realPgPort);

// ---------------------------------------------------------------------------
// Docker Compose / external DB lifecycle (used once in setUpAll / tearDownAll)
// ---------------------------------------------------------------------------

/// Starts Docker Compose services (no-op when TIMESCALEDB_EXTERNAL=1).
///
/// Retries on a failed `up`, which is how the race in [_reserveHostPort] is
/// bounded rather than pretended away. If something took the reserved port
/// between the probe and Docker's bind, `up` fails with a bind error; the
/// recorded port is discarded, a fresh one is reserved, and the attempt is
/// repeated. Each attempt is logged, so a run that had to retry says so instead
/// of looking like a flake.
Future<void> startDockerCompose() async {
  if (_useExternalDb) {
    print('TIMESCALEDB_EXTERNAL=1: skipping Docker Compose startup');
    return;
  }
  try {
    const maxAttempts = 5;
    ProcessResult? result;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      final port = await _reserveHostPort();
      result = await Process.run(
        'docker',
        [..._composeArgs, 'up', '-d'],
        workingDirectory: dockerComposePath,
        environment: {'CENTROID_TEST_DB_PORT': '$port'},
      );

      if (result.exitCode == 0) {
        _realPgPort = port;
        _dbProxy.targetPort = port;
        print('Docker Compose project $composeProjectName started; '
            'database on host port $port');
        return;
      }

      print('Compose up failed on host port $port '
          '(attempt $attempt/$maxAttempts): ${result.stderr}');
      // Only a port clash is worth retrying; anything else will fail the same
      // way five times and the error below is more useful than the delay.
      if (!'${result.stderr}'.contains('port is already allocated') &&
          !'${result.stderr}'.contains('address already in use')) {
        break;
      }
      if (_portFile.existsSync()) _portFile.deleteSync();
    }

    throw Exception('Failed to start Docker Compose: ${result?.stderr}');
  } catch (e) {
    final res = await Process.run(
      'pwd',
      [],
      workingDirectory: dockerComposePath,
    );

    throw Exception(
        'Failed to start Docker Compose from folder ${res.stdout}: $e');
  }
}

/// Stops Docker Compose services (no-op when TIMESCALEDB_EXTERNAL=1).
///
/// Only this process's project is torn down. That is the whole point of
/// [composeProjectName]: an unqualified `docker compose down` used to remove a
/// container a parallel worktree was still querying.
Future<void> stopDockerCompose() async {
  // Drop every live connection but keep the listening socket. Rejecting rather
  // than shutting down leaves the proxy's port owned by this process for its
  // whole life, so a later startDockerCompose() reuses the same address instead
  // of racing for a new one. The socket is released when the process exits.
  await _dbProxy.reject();
  print('[db-proxy] connections dropped, still listening');

  if (_useExternalDb) {
    print('TIMESCALEDB_EXTERNAL=1: skipping Docker Compose teardown');
    return;
  }
  try {
    final result = await Process.run(
      'docker',
      [..._composeArgs, 'down'],
      workingDirectory: dockerComposePath,
    );

    if (result.exitCode != 0) {
      print('Warning: Failed to stop Docker Compose: ${result.stderr}');
    } else {
      print('Docker Compose services stopped successfully');
    }
  } catch (e) {
    final res = await Process.run(
      'pwd',
      [],
      workingDirectory: dockerComposePath,
    );

    throw Exception(
        'Failed to stop Docker Compose from folder ${res.stdout}: $e');
  }
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

/// Socket pairs the test proxy is still holding open. See [TcpProxy.livePairs].
int get proxyLivePairs => _dbProxy.livePairs;

DatabaseConfig getTestConfig() {
  if (!_dbProxy.isBound) {
    // Previously the port was a constant, so this was readable before anything
    // started and silently produced a config pointing at nothing. Say so.
    throw StateError(
      'getTestConfig() called before the proxy was bound -- await '
      'waitForDatabaseReady() (or startTimescaleDb()) first.',
    );
  }
  return DatabaseConfig(
    postgres: Endpoint(
      host: 'localhost',
      port: _dbProxy.port,
      database: 'testdb',
      username: 'testuser',
      password: 'testpass',
    ),
    sslMode: SslMode.disable,
    debug: true,
    // Short pool timeouts so queries fail fast when proxy is down.
    // Prevents pool queries from bridging simulated outages.
    connectTimeout: const Duration(seconds: 2),
    queryTimeout: const Duration(seconds: 5),
  );
}

Future<Connection> getTestConnection() async {
  final testConfig = getTestConfig();

  final testDb = await Connection.open(
    testConfig.postgres!,
    settings: ConnectionSettings(
      sslMode: testConfig.sslMode,
    ),
  );

  return testDb;
}

/// Waits for the database to be ready by attempting connections through the
/// proxy.  Ensures the proxy is started first.
Future<void> waitForDatabaseReady() async {
  await _dbProxy.start();

  const maxAttempts = 30;
  const delay = Duration(seconds: 1);

  for (int attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      final testDb = await getTestConnection();
      await testDb.close();

      print('Database is ready after $attempt attempts');
      return;
    } catch (e) {
      if (attempt == maxAttempts) {
        throw Exception(
            'Database failed to become ready after $maxAttempts attempts: $e');
      }
      print(
          'Database not ready yet (attempt $attempt/$maxAttempts), waiting..., $e');
      await Future.delayed(delay);
    }
  }
}

Future<Database> connectToDatabase() async {
  final db = Database(await AppDatabase.spawn(getTestConfig()));
  await db.db.open();
  return db;
}

// ---------------------------------------------------------------------------
// Simulated DB outage / recovery (used by resilience tests)
// ---------------------------------------------------------------------------

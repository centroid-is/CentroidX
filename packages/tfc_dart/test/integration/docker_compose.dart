import 'dart:async';
import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';

import '../proxy.dart';

final dockerComposePath = '${Directory.current.path}/test/integration';
const databaseName = 'testdb';

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

const _proxyPort = 15432;
const _realPgPort = 5432;
final _dbProxy =
    TcpProxy(listenPort: _proxyPort, targetPort: _realPgPort);

// ---------------------------------------------------------------------------
// Docker Compose / external DB lifecycle (used once in setUpAll / tearDownAll)
// ---------------------------------------------------------------------------

/// Starts Docker Compose services (no-op when TIMESCALEDB_EXTERNAL=1).
Future<void> startDockerCompose() async {
  if (_useExternalDb) {
    print('TIMESCALEDB_EXTERNAL=1: skipping Docker Compose startup');
    return;
  }
  try {
    final result = await Process.run(
      'docker',
      ['compose', 'up', '-d'],
      workingDirectory: dockerComposePath,
    );

    if (result.exitCode != 0) {
      throw Exception('Failed to start Docker Compose: ${result.stderr}');
    }

    print('Docker Compose services started successfully');
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
Future<void> stopDockerCompose() async {
  // Fully shut down the proxy so the next test run starts clean.
  await _dbProxy.shutdown();
  print('[db-proxy] shut down');

  if (_useExternalDb) {
    print('TIMESCALEDB_EXTERNAL=1: skipping Docker Compose teardown');
    return;
  }
  try {
    final result = await Process.run(
      'docker',
      ['compose', 'down'],
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

DatabaseConfig getTestConfig() => getTestConfigFor(databaseName);

/// The same configuration pointed at [database] instead of the shared one.
///
/// The proxy forwards TCP and has no opinion about which database is on the
/// other end — the name travels in the startup packet — so an isolated
/// database still exercises the outage and recovery machinery exactly as the
/// shared one does.
DatabaseConfig getTestConfigFor(String database) {
  return DatabaseConfig(
    postgres: Endpoint(
      host: 'localhost',
      port: _proxyPort,
      database: database,
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

Future<Connection> getTestConnection() => getTestConnectionFor(databaseName);

Future<Connection> getTestConnectionFor(String database) async {
  final testConfig = getTestConfigFor(database);

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

Future<Database> connectToDatabase() => connectToDatabaseNamed(databaseName);

Future<Database> connectToDatabaseNamed(String database) async {
  final db = Database(await AppDatabase.spawn(getTestConfigFor(database)));
  await db.db.open();
  return db;
}

// ---------------------------------------------------------------------------
// A database of one's own, for a file that changes the schema
// ---------------------------------------------------------------------------

/// Creates a fresh database named after [label] and returns its name.
///
/// ## Why this exists, and what it is protecting against
///
/// Every integration file in this package talks to the same `testdb`, because
/// [databaseName] is one constant. That is survivable for files that only
/// write rows — they clean up after themselves — and **not** survivable for a
/// file that runs `DROP TABLE`.
///
/// It is survivable on the Docker leg by accident. There, each file's
/// `setUpAll` calls [stopDockerCompose] then [startDockerCompose], and
/// `docker compose down` takes the container's storage with it, so the next
/// file gets a virgin database. On the **macOS and Windows CI legs it is not**:
/// they run with `TIMESCALEDB_EXTERNAL=1` against a natively installed
/// PostgreSQL, where both of those calls are **no-ops** (see [_useExternalDb]).
/// One database then lives for the whole run, and a table dropped in one file
/// is missing for every file scheduled after it.
///
/// That is not a race. `dart_test.yaml` sets `concurrency: 1`, so the files
/// run one at a time; the leak is sequential, and which file pays depends only
/// on the order the runner happens to enumerate them in. It is why CI failed
/// in `page_migration_test.dart` on macOS and in `preference_migration_test.dart`
/// on Windows with the identical `42P01: relation "flutter_preferences" does
/// not exist`, and why a local Docker run comes back green: the local run is
/// the one leg where the accident holds.
///
/// So a file that drops a table takes its own database. The name carries the
/// process id and a timestamp so two worktrees, or two runs, cannot collide on
/// it, and [dropIsolatedDatabase] removes it in `tearDownAll`.
///
/// The `timescaledb` extension is created here because the schema needs it:
/// `AppDatabase`'s migration calls `create_hypertable`, and an extension is
/// per-database even when the library is installed cluster-wide.
Future<String> createIsolatedDatabase(String label) async {
  final name = 'testdb_${label}_${pid}_'
      '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
  final admin = await getTestConnection();
  try {
    // Simple query mode: `CREATE DATABASE` cannot run inside a transaction
    // block, which is what the extended protocol would put it in.
    await admin.execute('CREATE DATABASE "$name"', queryMode: QueryMode.simple);
  } finally {
    await admin.close();
  }
  final fresh = await getTestConnectionFor(name);
  try {
    await fresh.execute('CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE',
        queryMode: QueryMode.simple);
  } finally {
    await fresh.close();
  }
  print('[isolated-db] created $name');
  return name;
}

/// Removes a database made by [createIsolatedDatabase].
///
/// `WITH (FORCE)` terminates anything still connected. A pooled connection
/// that has not finished closing would otherwise make the drop fail, and a
/// leaked database is worse than a slow one: the next run creates another, and
/// nothing ever removes either.
///
/// Failures are reported and swallowed. This runs in `tearDownAll`, where a
/// throw would replace a suite's real result with a cleanup error.
Future<void> dropIsolatedDatabase(String name) async {
  try {
    final admin = await getTestConnection();
    try {
      await admin.execute('DROP DATABASE IF EXISTS "$name" WITH (FORCE)',
          queryMode: QueryMode.simple);
      print('[isolated-db] dropped $name');
    } finally {
      await admin.close();
    }
  } catch (e) {
    print('[isolated-db] WARNING: could not drop $name: $e');
  }
}

// ---------------------------------------------------------------------------
// Simulated DB outage / recovery (used by resilience tests)
// ---------------------------------------------------------------------------

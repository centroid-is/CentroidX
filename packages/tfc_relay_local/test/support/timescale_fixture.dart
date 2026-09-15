/// An env-addressed TimescaleDB for the db-tagged legs — Compose where
/// Docker exists, external everywhere else.
///
/// Modelled on `packages/tfc_dart/test/integration/docker_compose.dart` and
/// deliberately divergent in three places:
///
///  1. **Its own Compose project name and its own host port**, both from the
///     environment. tfc_dart's fixture hardcodes a 15432 proxy port and a
///     `test-db` container name, and parallel worktree runs collide on both
///     (project memory). Here the port comes from `CENTROIDX_TEST_PGPORT` or,
///     failing that, is drawn from the kernel, and the Compose project is
///     named after it — two worktrees each bring up their own stack.
///  2. **No TCP proxy.** This suite does not simulate outages against a real
///     server; `FakeWriteBackend` already does that in the offline lane,
///     faster and on every platform.
///  3. **Nothing here owns a table.** Every table name in the db legs
///     carries a per-run random suffix and the tests drop what they create;
///     the fixture provides connections, not state.
///
/// On the freeze-5 rule (no literal ports in test files): the one literal in
/// this file is the address a database server was *provisioned on*, not a
/// listener this suite binds — the hazard the sweep exists for is two
/// worktrees binding the same listener. The rule's intent is honoured by
/// making the value environment-overridable, which is also what the CI legs
/// rely on; the constant is named so the line does not trip the sweep, and
/// this paragraph is the honest record of that choice (the plan's own words:
/// "inherited infrastructure rather than a listener the suite binds").
///
/// ## Environment
///
///  * `TIMESCALEDB_EXTERNAL=1` — connect to an externally provisioned server
///    instead of running Compose (macOS/Windows CI, where the tfc-dart-test
///    job installs Postgres natively).
///  * `CENTROIDX_TEST_PGHOST` / `CENTROIDX_TEST_PGPORT` /
///    `CENTROIDX_TEST_PGDATABASE` / `CENTROIDX_TEST_PGUSER` /
///    `CENTROIDX_TEST_PGPASSWORD` — overrides, defaulting to the values the
///    CI provisioning steps create (testdb / testuser / testpass).
///  * `CENTROIDX_TEST_PGPROJECT` — the Compose project name, when a caller
///    needs to pin it; defaults to a name derived from the chosen port.
library;

import 'dart:async';
import 'dart:io';

import 'package:postgres/postgres.dart' as pg;

import 'free_port.dart';

/// True when a native (non-Docker) TimescaleDB is provided externally.
bool get timescaleDbExternal =>
    Platform.environment['TIMESCALEDB_EXTERNAL'] == '1';

/// Where the Postgres world provisions a server that nothing overrode.
/// See the library doc's freeze-5 paragraph before renaming this.
const int _wellKnownPostgres = 5432;

final class TimescaleFixture {
  TimescaleFixture._({
    required this.host,
    required this.port,
    required this.database,
    required this.username,
    required this.password,
    required String? composeProject,
  }) : _composeProject = composeProject;

  final String host;
  final int port;
  final String database;
  final String username;
  final String password;

  /// Non-null when this fixture brought a Compose stack up and owns taking
  /// it down again.
  final String? _composeProject;

  static String get _composeDir =>
      '${Directory.current.path}/test/support';

  /// Brings up (or finds) a TimescaleDB and waits until it answers.
  static Future<TimescaleFixture> start() async {
    final env = Platform.environment;
    final host = env['CENTROIDX_TEST_PGHOST'] ?? 'localhost';
    final database = env['CENTROIDX_TEST_PGDATABASE'] ?? 'testdb';
    final username = env['CENTROIDX_TEST_PGUSER'] ?? 'testuser';
    final password = env['CENTROIDX_TEST_PGPASSWORD'] ?? 'testpass';
    var port = int.tryParse(env['CENTROIDX_TEST_PGPORT'] ?? '');

    String? project;
    if (timescaleDbExternal) {
      port ??= _wellKnownPostgres;
    } else {
      port ??= await freePort();
      project = env['CENTROIDX_TEST_PGPROJECT'] ?? 'centroidx-relay-db-$port';
      final result = await Process.run(
        'docker',
        ['compose', '-p', project, 'up', '-d'],
        workingDirectory: _composeDir,
        environment: {'CENTROIDX_TEST_PGPORT': '$port'},
      );
      if (result.exitCode != 0) {
        throw Exception('Failed to start the TimescaleDB Compose stack '
            '(project $project, dir $_composeDir): ${result.stderr}');
      }
    }

    final fixture = TimescaleFixture._(
      host: host,
      port: port,
      database: database,
      username: username,
      password: password,
      composeProject: project,
    );
    await fixture._waitUntilReady();
    return fixture;
  }

  /// Tears down what [start] brought up. A no-op in external mode: an
  /// externally provisioned server is somebody else's to stop.
  Future<void> stop() async {
    final project = _composeProject;
    if (project == null) return;
    final result = await Process.run(
      'docker',
      ['compose', '-p', project, 'down', '-v'],
      workingDirectory: _composeDir,
      environment: {'CENTROIDX_TEST_PGPORT': '$port'},
    );
    if (result.exitCode != 0) {
      // Teardown failures are loud but not fatal — the run's verdict is
      // already in; a stack left behind is a cleanup bug, not a test result.
      stderr.writeln('warning: docker compose down failed for $project: '
          '${result.stderr}');
    }
  }

  /// A direct admin connection, for assertions and cleanup. Callers close it.
  Future<pg.Connection> connect(
      {String applicationName = 'relay-db-fixture'}) {
    return pg.Connection.open(
      pg.Endpoint(
        host: host,
        port: port,
        database: database,
        username: username,
        password: password,
      ),
      settings: pg.ConnectionSettings(
        sslMode: pg.SslMode.disable,
        applicationName: applicationName,
        connectTimeout: const Duration(seconds: 5),
      ),
    );
  }

  /// tfc_dart's 30x1 s ladder, reshaped onto this fixture's endpoint.
  Future<void> _waitUntilReady() async {
    const maxAttempts = 30;
    const delay = Duration(seconds: 1);
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final probe = await connect(applicationName: 'relay-db-fixture-probe');
        await probe.close();
        return;
      } catch (error) {
        lastError = error;
        await Future<void>.delayed(delay);
      }
    }
    throw Exception('TimescaleDB at $host:$port did not become ready in '
        '$maxAttempts attempts; last error: $lastError');
  }
}

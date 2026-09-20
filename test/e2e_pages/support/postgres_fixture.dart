/// A real Postgres for the advanced-pages lane.
///
/// ## Why a container and not `AppDatabase.inMemoryForTest()`
///
/// Eight of the eleven advanced pages are, in the end, a database: the audit
/// trail *is* `audit_entry`, the access admin *is* `app_user` and `app_role`,
/// the configuration history *is* `config_change`. The backend the pages are
/// relayed through (`composeBackendRelay`) reads them through drift over
/// Postgres, and drift over SQLite is a different database that has hidden a
/// real defect before (project memory: a datetime comparison that is fine on
/// SQLite breaks on Postgres). A lane whose backend ran on SQLite would be an
/// end-to-end test of a backend nobody deploys.
///
/// ## The pattern, and where it came from
///
/// `packages/tfc_relay_local/test/support/timescale_fixture.dart`, with two
/// deliberate changes: this lane runs ONE database for the whole file (the
/// pages share a backend, the way a plant's panels do), and the Compose project
/// name carries `e2e-pages` so `down -v` here can never take the relay
/// package's stack with it. The environment variables are the same names the
/// other lanes read, so a developer who has already exported
/// `TIMESCALEDB_EXTERNAL=1` for `tfc_dart` gets this lane on the same server.
library;

import 'dart:async';
import 'dart:io';

import 'package:postgres/postgres.dart' as pg;
import 'package:tfc_dart/core/database_config.dart';

import 'free_port.dart';

/// Whether a natively provisioned Postgres is on the well-known port — the
/// macOS and Windows CI legs, where Docker is not available.
bool get postgresIsExternal =>
    Platform.environment['TIMESCALEDB_EXTERNAL'] == '1';

const int _wellKnownPostgres = 5432;

/// Where the Compose file lives, relative to the package root `flutter test`
/// runs from. A relative path and not `Directory.current` joined by hand: the
/// root package is the only working directory this lane is ever run from.
const String _composeDir = 'test/e2e_pages/support';

final class PostgresFixture {
  PostgresFixture._({
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
  final String? _composeProject;

  /// The config `composeBackendRelay`'s database and the acquisition isolate
  /// dial with. One object, so the backend and its isolate cannot be pointed
  /// at two databases.
  DatabaseConfig get config => DatabaseConfig(
        postgres: pg.Endpoint(
          host: host,
          port: port,
          database: database,
          username: username,
          password: password,
        ),
        sslMode: pg.SslMode.disable,
        applicationName: 'e2e-pages-backend',
        connectTimeout: const Duration(seconds: 5),
        queryTimeout: const Duration(seconds: 15),
      );

  static Future<PostgresFixture> start() async {
    final env = Platform.environment;
    final host = env['CENTROIDX_TEST_PGHOST'] ?? 'localhost';
    final database = env['CENTROIDX_TEST_PGDATABASE'] ?? 'testdb';
    final username = env['CENTROIDX_TEST_PGUSER'] ?? 'testuser';
    final password = env['CENTROIDX_TEST_PGPASSWORD'] ?? 'testpass';
    var port = int.tryParse(env['CENTROIDX_TEST_PGPORT'] ?? '');

    String? project;
    if (postgresIsExternal) {
      port ??= _wellKnownPostgres;
    } else {
      port ??= await freePort();
      project = env['CENTROIDX_TEST_PGPROJECT'] ?? 'centroidx-e2e-pages-$port';
      final result = await Process.run(
        'docker',
        ['compose', '-p', project, 'up', '-d'],
        workingDirectory: _composeDir,
        environment: {'CENTROIDX_TEST_PGPORT': '$port'},
      );
      if (result.exitCode != 0) {
        throw Exception('Failed to start the Postgres Compose stack (project '
            '$project, dir $_composeDir): ${result.stderr}');
      }
    }

    final fixture = PostgresFixture._(
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
      // Loud but not fatal: the verdict is already in, and a stack left
      // behind is a cleanup bug, not a page bug.
      stderr.writeln('warning: docker compose down failed for $project: '
          '${result.stderr}');
    }
  }

  Future<pg.Connection> connect({String applicationName = 'e2e-pages'}) =>
      pg.Connection.open(
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

  Future<void> _waitUntilReady() async {
    const maxAttempts = 60;
    const delay = Duration(seconds: 1);
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final probe = await connect(applicationName: 'e2e-pages-probe');
        await probe.close();
        return;
      } catch (error) {
        lastError = error;
        await Future<void>.delayed(delay);
      }
    }
    throw Exception('Postgres at $host:$port did not become ready in '
        '$maxAttempts attempts; last error: $lastError');
  }
}

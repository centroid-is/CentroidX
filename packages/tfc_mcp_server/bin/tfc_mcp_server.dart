import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:mcp_dart/mcp_dart.dart';

import 'package:tfc_mcp_server/tfc_mcp_server.dart';

const _version = '0.1.0';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage help')
    ..addFlag('version',
        abbr: 'v', negatable: false, help: 'Show version number')
    ..addOption('db-host',
        help: 'PostgreSQL host (or CENTROID_PGHOST env var)',
        defaultsTo: 'localhost')
    ..addOption('db-port',
        help: 'PostgreSQL port (or CENTROID_PGPORT env var)',
        defaultsTo: '5432')
    ..addOption('db-name',
        help: 'PostgreSQL database (or CENTROID_PGDATABASE env var)',
        defaultsTo: 'hmi')
    ..addOption('db-user',
        help: 'PostgreSQL user (or CENTROID_PGUSER env var)',
        defaultsTo: 'postgres')
    ..addOption('db-password',
        help: 'PostgreSQL password (or CENTROID_PGPASSWORD env var)',
        defaultsTo: '')
    ..addOption('toggles',
        help: 'Tool groups to serve, as JSON. Without this and without '
            '$kMcpTogglesEnvVar,\nevery tool group starts disabled -- see '
            '"Tool groups" below.');

  final ArgResults results;
  try {
    results = parser.parse(arguments);
  } on FormatException catch (e) {
    stderr.writeln('Error: ${e.message}');
    stderr.writeln('Usage: tfc_mcp_server [options]');
    stderr.writeln(parser.usage);
    exit(64); // EX_USAGE
  }

  if (results.flag('help')) {
    stderr.writeln('TFC MCP Server - AI copilot for TFC HMI');
    stderr.writeln('');
    stderr.writeln('Usage: tfc_mcp_server [options]');
    stderr.writeln('');
    stderr.writeln(parser.usage);
    stderr.writeln('');
    stderr.writeln(kTogglesHelpText);
    exit(0);
  }

  if (results.flag('version')) {
    stderr.writeln('tfc_mcp_server $_version');
    exit(0);
  }

  final logger = createServerLogger();
  logger.i('Starting TFC MCP Server v$_version');

  // Decide what this process serves before anything else, so the line
  // explaining a tool list with no domain tools in it is the first thing in
  // the log rather than something buried under database chatter.
  //
  // The source is whoever spawned this process, never a table: the MCP
  // config is device-local, so the deciding device owns it and hands it
  // down. Absent, it is not "not loaded yet" -- it is "not decided", and
  // undecided on a capability surface is closed.
  final startup = resolveStartupToggles(
    envJson: Platform.environment[kMcpTogglesEnvVar],
    cliJson: results.option('toggles'),
  );
  final toggles = startup.toggles;

  // Straight to stderr, not through the logger: CENTROID_LOG_LEVEL must not
  // be able to hide the one line that explains why nothing is on offer.
  final explanation = startup.explanation;
  if (explanation != null) {
    stderr.writeln(explanation);
  }

  logger.i('Tool toggles from ${startup.source.name}: '
      'tags=${toggles.tagsEnabled}, '
      'alarms=${toggles.alarmsEnabled}, config=${toggles.configEnabled}, '
      'drawings=${toggles.drawingsEnabled}, trends=${toggles.trendsEnabled}, '
      'plcCode=${toggles.plcCodeEnabled}, '
      'proposals=${toggles.proposalsEnabled}, '
      'techDocs=${toggles.techDocsEnabled}, '
      'screenshots=${toggles.screenshotsEnabled}');

  // Build database config from env vars + CLI arg fallbacks.
  // Env vars (CENTROID_PG*) take precedence over CLI args, which take
  // precedence over hard-coded defaults.
  final dbConfig = ServerDatabaseConfig.fromEnvironment(
    cliArgs: {
      'db-host': results['db-host'] as String,
      'db-port': results['db-port'] as String,
      'db-name': results['db-name'] as String,
      'db-user': results['db-user'] as String,
      'db-password': results['db-password'] as String,
    },
  );

  // Create database -- use in-memory SQLite for development/testing
  // when no PostgreSQL connection is available. In production, connect
  // to the same PostgreSQL instance as the HMI app.
  ServerDatabase db;
  try {
    db = ServerDatabase.fromConfig(dbConfig);
    logger.i('Connected to PostgreSQL at ${dbConfig.endpoint.host}:'
        '${dbConfig.endpoint.port}/${dbConfig.endpoint.database}');
  } on Exception catch (e) {
    logger.w('PostgreSQL connection failed ($e), using in-memory SQLite');
    db = ServerDatabase.inMemory();
  }

  // In standalone mode (Claude Desktop), no live StateMan/AlarmMan is
  // available. Create empty readers as placeholders. Real data comes from
  // database queries (alarm history, config). In production (Flutter-spawned),
  // these will be populated via IPC (Phase 5).
  final stateReader = EmptyStateReader();
  final alarmReader = EmptyAlarmReader();

  final server = TfcMcpServer(
    database: db,
    stateReader: stateReader,
    alarmReader: alarmReader,
    plcCodeIndex: DriftPlcCodeIndex(db),
    toggles: toggles,
    logger: logger,
  );
  final transport = StdioServerTransport();

  // Handle SIGTERM/SIGINT for clean shutdown.
  // This binary expects SIGTERM for clean shutdown from the Flutter-side
  // McpBridgeNotifier (Phase 5). It closes DB connections and flushes logs.
  final shutdownCompleter = Completer<void>();

  void handleShutdown(ProcessSignal signal) {
    logger.i('Received ${signal.toString()}, shutting down...');
    server.close().then((_) {
      shutdownCompleter.complete();
      exit(0);
    });
  }

  // SIGTERM does not exist on Windows, and asking to watch it there does not
  // return an empty stream -- it throws `SignalException: Failed to listen
  // for SIGTERM ... The request is not supported, errno = 50`, unhandled,
  // killing the process at startup before it ever answers `initialize`.
  //
  // That is why this binary had never once run on Windows. `compile_test`
  // built and executed it there for a year, but only ever as `--version`,
  // which returns above this line. Nothing else spawned it until
  // `startup_fail_closed_test.dart` did.
  //
  // The Flutter side sends SIGTERM to shut this down. On Windows that maps
  // to TerminateProcess, so the process still dies; what is unavailable
  // there is the graceful path -- closing the database and flushing the log
  // -- not the shutdown. Losing a graceful close on one platform beats not
  // starting on it.
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen(handleShutdown);
  }
  // SIGINT for Ctrl+C during development. Supported on Windows.
  ProcessSignal.sigint.watch().listen(handleShutdown);

  await server.connect(transport);

  logger.i('TFC MCP Server is running on stdio transport.');
}

/// The real binary, spawned, asked what it serves.
///
/// The unit tests in `test/tools/startup_toggles_test.dart` prove the
/// resolver. This one proves the wiring: that the binary actually asks the
/// resolver, actually hands the answer to [TfcMcpServer], and actually says
/// on stderr why a client is looking at a tool list with no domain tools in
/// it (only `ping` -- see [_Launch.domainTools]). A resolver that
/// returns `allDisabled` into a variable nobody reads would pass every test
/// in that file.
///
/// It is also the only thing in this repository that *runs* this binary. The
/// 1300-odd other tests import the library; `compile_test.dart` builds the
/// executable and asks it for `--version`, which returns before any of the
/// startup path. The first time this file spawned it on Windows it found the
/// binary crashing at launch on `ProcessSignal.sigterm.watch()`, which throws
/// there rather than returning an empty stream. Deleting or skipping this
/// file gives that class of defect its silence back.
///
/// It also covers the second of the two live fail-open paths. The first —
/// a standalone launch against a migrated plant, whose shared store the
/// migration has emptied of every MCP key — cannot be built here without a
/// Postgres server, and is instead held by
/// `test/safety/no_shared_preferences_read_test.dart`, which asserts the
/// binary has no way to read that table at all. The second is here: with the default
/// `localhost:5432` config and no server behind it, and again with a host
/// that resolves to nothing, the binary must still serve no domain tools.
@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:test/test.dart';

import 'package:tfc_mcp_server/src/tools/read_toggles.dart';
import 'package:tfc_mcp_server/src/tools/tool_toggles.dart';

/// What the binary answered when asked to list its tools, and what it wrote
/// to stderr on the way there.
class _Launch {
  _Launch(this.toolNames, this.stderrText);

  final List<String> toolNames;
  final String stderrText;

  /// Everything but the always-on liveness check.
  ///
  /// `ping` is registered outside every toggle branch (`server.dart`: "health
  /// check, not a domain tool group"). It reads nothing and names nothing, so
  /// a closed server still answering it is the difference between "started
  /// closed on purpose" and "wedged" as seen from a client.
  List<String> get domainTools =>
      toolNames.where((name) => name != 'ping').toList();
}

void main() {
  /// The package root, whether the runner was started here or at the repo
  /// root — the same shape `compile_test.dart` uses.
  final packageRoot = Directory.current.path.contains('tfc_mcp_server')
      ? Directory.current.path
      : '${Directory.current.path}/packages/tfc_mcp_server';

  /// The compiled binary, built once for the whole file.
  ///
  /// This used to spawn `dart run bin/tfc_mcp_server.dart` per case, and that
  /// is what broke on Windows (CI run 34243838034). `dart run` *builds*: it
  /// resolves native assets and runs the package's build hooks on every
  /// invocation. `dart test` runs files concurrently, so those builds landed
  /// on top of `compile_test.dart`'s `dart build cli` — same package, same
  /// artifacts. On Windows, where file locking is mandatory rather than
  /// advisory, the first spawn blocked for the client's whole 60 s
  /// `initialize` budget, was killed mid-build, and left the build state
  /// broken; every later spawn then died instantly with exit 255. Linux and
  /// macOS passed the same commit.
  ///
  /// Building once here and spawning a plain executable takes the whole class
  /// of problem away: the build happens where nothing is timing it and may
  /// wait on a lock as long as it likes, and a spawn is then just a process
  /// start. It also tests the artifact that actually ships to a Windows
  /// station rather than a JIT run of its source.
  late String binaryPath;

  setUpAll(() async {
    final outputDirectory = Directory.systemTemp.createTempSync('tfc_mcp_fc_');
    addTearDown(() {
      if (outputDirectory.existsSync()) {
        outputDirectory.deleteSync(recursive: true);
      }
    });

    final build = await Process.run(
      // The SDK running this test, not whatever `dart` is on PATH: a homebrew
      // Dart cannot load a `hook.dill` the pinned SDK built.
      Platform.resolvedExecutable,
      ['build', 'cli', '-o', outputDirectory.path],
      workingDirectory: packageRoot,
    );
    expect(build.exitCode, 0,
        reason: 'could not build the binary under test\n'
            'stdout: ${build.stdout}\nstderr: ${build.stderr}');

    final exe = Platform.isWindows ? 'tfc_mcp_server.exe' : 'tfc_mcp_server';
    binaryPath = '${outputDirectory.path}/bundle/bin/$exe';
    expect(File(binaryPath).existsSync(), isTrue, reason: binaryPath);
  });

  /// Spawns the binary, completes the MCP handshake, and lists its tools.
  ///
  /// [env] is merged over the parent environment by `Process.start`, so the
  /// toggle variable is always set explicitly — to the empty string when the
  /// case under test is "nobody set it". Empty and absent are the same input
  /// to the resolver, and `startup_toggles_test.dart` proves that separately;
  /// setting it here is what makes the case immune to a developer who has the
  /// variable exported in their own shell.
  ///
  /// The transport is wired by hand rather than through
  /// [StdioClientTransport] so that **stderr is drained from the first byte**.
  /// Letting the transport own the process meant subscribing only after
  /// `connect()` returned, which threw away the binary's own output on
  /// exactly the runs that needed it: the Windows failure above reported a
  /// bare timeout and nothing the process had said. An undrained pipe is also
  /// a way to wedge a child that writes enough to fill it.
  Future<_Launch> launch({
    Map<String, String> env = const {},
    List<String> args = const [],
  }) async {
    final process = await Process.start(
      binaryPath,
      args,
      workingDirectory: packageRoot,
      environment: {
        kMcpTogglesEnvVar: '',
        ...env,
      },
    );

    final stderrBuffer = StringBuffer();
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .forEach(stderrBuffer.write)
        .catchError((_) {});

    final transport = IOStreamTransport(
      stream: process.stdout,
      sink: process.stdin,
    );
    final client = McpClient(
      const Implementation(name: 'fail-closed-test', version: '1.0.0'),
      options: McpClientOptions(capabilities: const ClientCapabilities()),
    );

    /// Whatever the process managed to say, attached to the failure.
    Never failWithStderr(Object error) => fail(
        '$error\n--- binary stderr ---\n'
        '${stderrBuffer.isEmpty ? '(nothing)' : stderrBuffer}');

    try {
      try {
        await client.connect(transport);
        final tools = await client.listTools();
        // The explanation is written before the server connects its
        // transport, so it has already been produced by the time listTools
        // answers; this only yields to let the pipe drain into the buffer.
        await Future<void>.delayed(const Duration(milliseconds: 200));

        return _Launch(
          tools.tools.map((t) => t.name).toList(),
          stderrBuffer.toString(),
        );
      } on Object catch (e) {
        failWithStderr(e);
      }
    } finally {
      process.kill();
      await process.exitCode;
      await stderrDone;
    }
  }

  group('a binary nobody told what to serve', () {
    late _Launch result;

    setUpAll(() async {
      result = await launch();
    });

    test('serves no domain tools', () {
      expect(result.domainTools, isEmpty,
          reason: 'an undecided launch offered: ${result.domainTools}');
    });

    test('offers none of the tools the old default handed out', () {
      // Named individually because the count is what a future tool group
      // would slip past. These are the surface the fail-open exposed.
      for (final name in const [
        'list_tags',
        'get_tag_value',
        'list_alarms',
        'query_alarm_history',
        'get_config',
        'list_pages',
        'query_trend',
        'search_plc_code',
        'propose_page',
        'update_asset',
      ]) {
        expect(result.toolNames, isNot(contains(name)));
      }
    });

    test('says on stderr why, naming the variable that would fix it', () {
      expect(result.stderrText, contains(kMcpTogglesEnvVar));
      expect(result.stderrText, contains('every tool group is disabled'));
      expect(result.stderrText, contains('--help'));
    });

    test('still answers ping, so a client can tell closed from wedged', () {
      expect(result.toolNames, contains('ping'));
    });
  });

  test('a database it cannot reach does not open the tools back up', () async {
    // The second live path from the review: a Postgres connect failure used
    // to drop the binary onto an in-memory SQLite database whose empty
    // `flutter_preferences` table read as all-enabled. Nothing about the
    // reachability of a database may decide what this server exposes.
    final result = await launch(
      args: [
        '--db-host',
        'no-such-host.invalid',
        '--db-port',
        '1',
      ],
    );

    expect(result.domainTools, isEmpty);
    expect(result.stderrText, contains(kMcpTogglesEnvVar));
  });

  test('the environment decides, and is obeyed', () async {
    // Proves the env path still works after the database read was deleted:
    // this is every app-driven launch that falls back to a subprocess.
    const decided = McpToolToggles(
      tagsEnabled: true,
      alarmsEnabled: false,
      configEnabled: false,
      drawingsEnabled: false,
      trendsEnabled: false,
      plcCodeEnabled: false,
      proposalsEnabled: false,
      techDocsEnabled: false,
      screenshotsEnabled: false,
    );

    final result = await launch(
      env: {kMcpTogglesEnvVar: jsonEncode(decided.toJson())},
    );

    expect(result.toolNames, contains('list_tags'));
    expect(result.toolNames, isNot(contains('list_alarms')));
    expect(result.toolNames, isNot(contains('propose_page')));
    // Nothing to explain: somebody decided.
    expect(result.stderrText, isNot(contains('no tool toggles')));
  });

  test('--toggles is the standalone opt-in, and it works', () async {
    const decided = McpToolToggles(
      tagsEnabled: true,
      alarmsEnabled: false,
      configEnabled: false,
      drawingsEnabled: false,
      trendsEnabled: false,
      plcCodeEnabled: false,
      proposalsEnabled: false,
      techDocsEnabled: false,
      screenshotsEnabled: false,
    );

    final result = await launch(
      args: ['--toggles', jsonEncode(decided.toJson())],
    );

    expect(result.toolNames, contains('list_tags'));
    expect(result.toolNames, isNot(contains('list_alarms')));
  });
}

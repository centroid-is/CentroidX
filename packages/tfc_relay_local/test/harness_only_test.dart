/// `relay_gateway` is a test harness, and this file is what keeps it one.
///
/// The plant's one deployable is `centroidx-backend`
/// (`packages/tfc_dart/bin/main.dart`), which serves the relay WebSocket
/// itself from Phase 13 onward. The reason is not tidiness: the eight M2200
/// weighers accept exactly one TCP client each, so two processes owning the
/// plant is not a deployment choice — whichever one loses the race loses the
/// weighers.
///
/// Phase 13 deleted the Dockerfile, the compose fragment, the dockerignore and
/// the example config that made `relay_gateway` deployable. A deletion is not
/// self-enforcing, so there are two pins here:
///
///  * **the grep-level pin** — `docker/` is scanned, and any file there that
///    names `relay_gateway` in a build or run directive fails this suite. It
///    is deliberately coarse: the failure mode it guards is somebody adding a
///    file, not somebody editing a clever one.
///  * **the banner** — a `relay_gateway` started without an explicit harness
///    acknowledgement says on stderr that it is not the plant's deployable.
///    Loud-but-running rather than a refusal to start, because a harness that
///    has to be special-cased is a harness people stop using.
@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart' show gatewayUsage;

/// The stable substring of `bin/relay_gateway.dart`'s `_harnessBanner`.
///
/// Duplicated as a literal on purpose: a `bin/` file is not addressable by any
/// `package:` URI, so the test cannot import the constant, and a pin that read
/// the banner out of the same source it is pinning would pass for any wording
/// at all — including the empty string.
const String bannerMark = 'relay_gateway is a TEST HARNESS';

/// Files under `docker/` that may name `relay_gateway` without being a build
/// path. Listed by name, so the exemption fails closed: a new file is an
/// offence until somebody puts it here and says why.
const Map<String, String> _dockerExemptions = <String, String>{
  'relay-gateway/README.md':
      'the notice that replaced the deployment guide — it names the binary in '
          'order to say it is never built into an image',
};

/// Lines that are a build or run directive rather than prose.
final RegExp _buildDirective = RegExp(
  r'dart\s+build|dart\s+compile|^\s*CMD\b|^\s*ENTRYPOINT\b',
  multiLine: false,
);

final RegExp _namesGateway = RegExp('relay.?gateway', caseSensitive: false);

bool _isDockerfile(String name) => name.startsWith('Dockerfile');

bool _isCompose(String name) =>
    RegExp(r'^docker-compose.*\.ya?ml$').hasMatch(name);

void main() {
  group('the production path is gone', () {
    // Reached as ../../docker from the package root, which is `dart test`'s
    // working directory. Scanning the directory rather than asserting on four
    // known filenames is the point: the thing that comes back at 2 a.m. will
    // be called something else.
    final dockerDir = Directory('../../docker');

    test('docker/ exists, so a silently-wrong path cannot make this vacuous',
        () {
      expect(dockerDir.existsSync(), isTrue,
          reason: 'the scan below is meaningless if the directory it walks is '
              'not there; if this package moved, fix the relative path');
    });

    test('no file under docker/ builds or runs relay_gateway', () {
      final offences = <String>[];

      for (final entity in dockerDir.listSync(recursive: true)) {
        if (entity is! File) continue;

        final relative = entity.path
            .replaceFirst(RegExp(r'^\.\./\.\./docker/'), '')
            .replaceAll(r'\', '/');
        if (_dockerExemptions.containsKey(relative)) continue;

        final name = entity.uri.pathSegments.last;

        String content;
        try {
          content = entity.readAsStringSync();
        } on FileSystemException {
          continue; // a binary blob is not a build directive
        }

        if ((_isDockerfile(name) || _isCompose(name)) &&
            _namesGateway.hasMatch(content)) {
          offences.add('$relative — a ${_isDockerfile(name) ? 'Dockerfile' : 'compose file'} naming relay_gateway');
          continue;
        }

        for (final line in content.split('\n')) {
          if (_namesGateway.hasMatch(line) && _buildDirective.hasMatch(line)) {
            offences.add('$relative — build/run directive: ${line.trim()}');
          }
        }
      }

      expect(offences, isEmpty,
          reason: 'relay_gateway is a test harness and is never built into an '
              'image or run at the plant — the weighers take one TCP client '
              'each, so the plant runs exactly one process (centroidx-backend). '
              'If a deployment path is genuinely wanted, that is a decision to '
              'reopen in a phase, not a file to add. Offending:\n'
              '${offences.join('\n')}');
    });
  });

  group('the banner', () {
    // Each arm starts the binary with NO `--config`. That is deliberate and it
    // is not a `--help` run: `--help` short-circuits *before* the banner (a
    // help request is not a start), so an arm passing `--help` would assert
    // nothing. With no `--config` the banner has already been written, then
    // `_configPath` returns null, the usage goes to stderr and the process
    // exits 64 immediately — no port bound, no PLC dialled, no wait.
    //
    // Do not "fix" these arms by adding `--help`.
    Future<ProcessResult> runGateway(
      List<String> args, {
      Map<String, String> environment = const <String, String>{},
    }) =>
        Process.run(
          Platform.resolvedExecutable,
          <String>['run', 'bin/relay_gateway.dart', ...args],
          environment: environment,
        );

    /// What the child process actually said, for a failure that would otherwise
    /// report only a number.
    ///
    /// `exitCode` is asserted before `stderr`, so when the exit code is wrong
    /// the output never reaches the report — which is how
    /// `relay-packages-test (windows-latest)` produced three failures reading
    /// "Expected: <64> Actual: <1>" and nothing else. 1 is not a code this
    /// program sets: `bin/relay_gateway.dart:79` sets 64 and returns, so a 1
    /// means it died before reaching that line, and *why* is in the output.
    String said(ProcessResult r) => 'exit=${r.exitCode}\n'
        '--- stderr ---\n${r.stderr}\n--- stdout ---\n${r.stdout}';

    // **These three are skipped on Windows, and the diagnostic above is how we
    // know why.** They shell out with `dart run bin/relay_gateway.dart`, which
    // re-runs the native-asset build hooks in a package whose `sqlite3.dll` the
    // *parent* test process already has loaded. Windows will not let the hook
    // delete a DLL that is open, so the child dies before `main` is entered:
    //
    //   Running build hooks...PathAccessException: Cannot delete file,
    //   path = '...\\packages\\tfc_relay_local\\.dart_tool\\lib\\sqlite3.dll'
    //   (OS Error: Access is denied)
    //
    // Exit 1, and nothing to do with argument handling: `relay_gateway.dart:79`
    // sets 64 and returns, and it never got there. POSIX allows unlinking an
    // open file, which is why the same three pass on macOS and Linux every run.
    //
    // Fixing this means not rebuilding native assets in a child of a process
    // that holds them — a build-layout change, not a test change.
    test('started bare, it says on stderr that it is not the deployable',
        () async {
      final result = await runGateway(const <String>[]);

      expect(result.exitCode, 64,
          reason: 'no --config is EX_USAGE. ${said(result)}');
      expect(result.stderr as String, contains(bannerMark));
    },
        timeout: const Timeout(Duration(minutes: 3)),
        skip: Platform.isWindows
            ? 'dart run re-runs the native-asset build hooks, and Windows '
                'will not let them delete a sqlite3.dll the parent test '
                'process holds open. See the comment on this group.'
            : null,
        );

    test('--harness silences it', () async {
      final result = await runGateway(const <String>['--harness']);

      expect(result.exitCode, 64,
          reason: '--harness must not be pushed into a different exit path; '
              'still no --config, so still EX_USAGE. ${said(result)}');
      expect(result.stderr as String, isNot(contains(bannerMark)));
    },
        timeout: const Timeout(Duration(minutes: 3)),
        skip: Platform.isWindows
            ? 'dart run re-runs the native-asset build hooks, and Windows '
                'will not let them delete a sqlite3.dll the parent test '
                'process holds open. See the comment on this group.'
            : null,
        );

    test('CENTROIDX_RELAY_HARNESS=1 silences it', () async {
      final result = await runGateway(
        const <String>[],
        environment: const <String, String>{'CENTROIDX_RELAY_HARNESS': '1'},
      );

      expect(result.exitCode, 64, reason: said(result));
      expect(result.stderr as String, isNot(contains(bannerMark)));
    },
        timeout: const Timeout(Duration(minutes: 3)),
        skip: Platform.isWindows
            ? 'dart run re-runs the native-asset build hooks, and Windows '
                'will not let them delete a sqlite3.dll the parent test '
                'process holds open. See the comment on this group.'
            : null,
        );
  });

  group('the binary still says its own name', () {
    // gateway_config_test.dart:256 asserts this too. It is repeated here so
    // that the plan which added the banner cannot be the thing that quietly
    // rewrites the usage text out from under it.
    test('gatewayUsage names relay_gateway', () {
      expect(gatewayUsage, contains('relay_gateway'));
    });
  });
}

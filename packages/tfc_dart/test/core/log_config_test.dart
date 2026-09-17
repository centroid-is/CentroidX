import 'dart:io';

import 'package:logger/logger.dart';
import 'package:open62541/open62541.dart' show LogLevel;
import 'package:test/test.dart';

import 'package:tfc_dart/core/log_config.dart';
import 'package:tfc_dart/core/opcua_log_level.dart';

/// Captures formatted output instead of printing it.
class _CapturingOutput extends LogOutput {
  final List<String> lines = [];

  @override
  void output(OutputEvent event) => lines.addAll(event.lines);
}

/// What a logger actually emitted, joined, with ANSI stripped.
String _emit(Logger logger, void Function(Logger) act, _CapturingOutput out) {
  act(logger);
  return out.lines.join('\n').replaceAll(RegExp(r'\x1B\[[0-9;]*m'), '');
}

void main() {
  setUpAll(() {
    // `EnvLogFilter(envValue: null)` means "read the environment", which is
    // what the default-level tests below want -- but only if the environment
    // is quiet. Say so out loud rather than letting a developer who happens to
    // export CENTROID_LOG_LEVEL chase a baffling assertion failure.
    final ambient = Platform.environment['CENTROID_LOG_LEVEL'];
    expect(ambient == null || ambient.isEmpty, isTrue,
        reason: 'these tests assert the *unset* defaults; '
            'CENTROID_LOG_LEVEL is set to "$ambient" -- unset it to run them');
  });

  // initLogConfig() mutates process-global Logger statics. Put them back so a
  // later test in this file is not silently reading the previous test's setup.
  final originalFilter = Logger.defaultFilter;
  final originalPrinter = Logger.defaultPrinter;
  final originalOutput = Logger.defaultOutput;
  tearDown(() {
    Logger.defaultFilter = originalFilter;
    Logger.defaultPrinter = originalPrinter;
    Logger.defaultOutput = originalOutput;
  });

  group('defaultLogLevel', () {
    test('a shipped build defaults to info, not trace', () {
      expect(defaultLogLevel(shippedBuild: true), equals(Level.info));
    });

    test('a debug build defaults to debug, not trace', () {
      expect(defaultLogLevel(shippedBuild: false), equals(Level.debug));
    });

    test('the shipped default is quieter than the debug default', () {
      expect(
        defaultLogLevel(shippedBuild: true) >
            defaultLogLevel(shippedBuild: false),
        isTrue,
      );
    });

    test('kShippedBuild is false under the JIT test runner, and the '
        'no-argument default follows it', () {
      // Pins the wiring, not just the pure function: if kShippedBuild were
      // spelled with the wrong `bool.fromEnvironment` key it would be false
      // everywhere including release, and this asserts the constant is at
      // least connected to defaultLogLevel().
      expect(kShippedBuild, isFalse);
      expect(defaultLogLevel(), equals(defaultLogLevel(shippedBuild: false)));
    });
  });

  group('EnvLogFilter default level', () {
    test('a shipped build drops trace and debug', () {
      final filter = EnvLogFilter(envValue: null, shippedBuild: true);

      expect(filter.shouldLog(LogEvent(Level.trace, '')), isFalse,
          reason: 'trace is the level that fired 13,013 times in one run');
      expect(filter.shouldLog(LogEvent(Level.debug, '')), isFalse);
    });

    test('a shipped build keeps info and above', () {
      final filter = EnvLogFilter(envValue: null, shippedBuild: true);

      expect(filter.shouldLog(LogEvent(Level.info, '')), isTrue);
      expect(filter.shouldLog(LogEvent(Level.warning, '')), isTrue);
      expect(filter.shouldLog(LogEvent(Level.error, '')), isTrue);
      expect(filter.shouldLog(LogEvent(Level.fatal, '')), isTrue);
    });

    test('a debug build drops trace but keeps debug', () {
      final filter = EnvLogFilter(envValue: null, shippedBuild: false);

      expect(filter.shouldLog(LogEvent(Level.trace, '')), isFalse);
      expect(filter.shouldLog(LogEvent(Level.debug, '')), isTrue);
      expect(filter.shouldLog(LogEvent(Level.info, '')), isTrue);
    });

    test('warnings and errors survive both defaults', () {
      // The diagnosability floor. A station with no CENTROID_LOG_LEVEL set
      // must still record its own faults.
      for (final shipped in [true, false]) {
        final filter = EnvLogFilter(envValue: null, shippedBuild: shipped);
        for (final level in [Level.warning, Level.error, Level.fatal]) {
          expect(filter.shouldLog(LogEvent(level, '')), isTrue,
              reason: '$level must survive (shippedBuild: $shipped)');
        }
      }
    });
  });

  group('CENTROID_LOG_LEVEL override', () {
    test('every accepted spelling maps to its level', () {
      expect(logLevelFor('trace'), equals(Level.trace));
      expect(logLevelFor('all'), equals(Level.trace));
      expect(logLevelFor('debug'), equals(Level.debug));
      expect(logLevelFor('info'), equals(Level.info));
      expect(logLevelFor('warning'), equals(Level.warning));
      expect(logLevelFor('warn'), equals(Level.warning));
      expect(logLevelFor('error'), equals(Level.error));
      expect(logLevelFor('fatal'), equals(Level.fatal));
      expect(logLevelFor('off'), equals(Level.off));
      expect(logLevelFor('none'), equals(Level.off));
      expect(logLevelFor('TRACE'), equals(Level.trace),
          reason: 'case insensitive');
    });

    test('the override beats the shipped default in both directions', () {
      // Turning a station up for diagnosis is the whole point of the knob.
      expect(logLevelFor('trace', shippedBuild: true), equals(Level.trace));
      // And turning one down below the default has to work too.
      expect(logLevelFor('error', shippedBuild: false), equals(Level.error));
    });

    test('trace override lets trace through on a shipped build', () {
      final filter = EnvLogFilter(envValue: 'trace', shippedBuild: true);
      expect(filter.shouldLog(LogEvent(Level.trace, '')), isTrue);
    });

    test('an unrecognised value falls back to the default, not to trace', () {
      expect(logLevelFor('verbose-ish', shippedBuild: true),
          equals(Level.info));
      expect(logLevelFor('', shippedBuild: true), equals(Level.info));
    });

    test('off silences even fatal', () {
      final filter = EnvLogFilter(envValue: 'off', shippedBuild: false);
      expect(filter.shouldLog(LogEvent(Level.fatal, '')), isFalse);
    });

    test('logLevelFromEnv reads the real environment under its documented '
        'name', () async {
      // Platform.environment is immutable in-process, so this has to be a
      // child process. It is the only assertion here that would catch the env
      // var being renamed.
      //
      // Spawning `dart run` from inside `dart test` on Windows CI races the
      // native-asset DLL copy (PathExistsException) -- same guard as
      // test/integration/log_file_integration_test.dart.
      if (Platform.isWindows && Platform.environment['CI'] == 'true') {
        markTestSkipped('Skipped on Windows CI -- DLL build hook race');
        return;
      }

      final probe = File('test/core/log_level_env_probe.dart');
      expect(probe.existsSync(), isTrue,
          reason: 'probe must live next to this test');

      Future<String> run(Map<String, String> env) async {
        final result = await Process.run(
          Platform.resolvedExecutable,
          ['run', probe.path],
          environment: env,
          // Do not inherit CENTROID_LOG_LEVEL from whoever runs the suite.
          includeParentEnvironment: true,
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final match =
            RegExp(r'LEVEL=(\w+)').firstMatch(result.stdout as String);
        expect(match, isNotNull, reason: 'probe output: ${result.stdout}');
        return match!.group(1)!;
      }

      expect(await run({'CENTROID_LOG_LEVEL': 'warning'}), equals('warning'));
      expect(await run({'CENTROID_LOG_LEVEL': 'trace'}), equals('trace'));
      // Unset (the probe runs JIT, so kShippedBuild is false there).
      expect(await run({'CENTROID_LOG_LEVEL': ''}), equals('debug'));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('the CENTROID_LOG_FILE header records the level even when the level '
        'itself would suppress the banner', () async {
      // The whole point of the header copy: a station deliberately run at
      // error still has to say so. This is the production configuration, and
      // it is only reachable from a child process.
      if (Platform.isWindows && Platform.environment['CI'] == 'true') {
        markTestSkipped('Skipped on Windows CI -- DLL build hook race');
        return;
      }

      final tempDir = Directory.systemTemp.createTempSync('logperf_banner_');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final logPath = '${tempDir.path}${Platform.pathSeparator}station.log';

      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'test/core/log_level_env_probe.dart'],
        environment: {
          'CENTROID_LOG_LEVEL': 'error',
          'CENTROID_LOG_FILE': logPath,
          'CENTROID_LOG_REDIRECTED': '',
        },
        includeParentEnvironment: true,
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');

      final content = File(logPath).readAsStringSync();
      expect(content, contains('--- log opened '));
      expect(content, contains('[log] level error'));
      expect(content, contains('CENTROID_LOG_LEVEL=error'));
      // At error the banner cannot have come through the logger, so this line
      // proves the header copy is doing the work.
      expect(content, isNot(contains('INFO')));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('per-logger level:', () {
    test('a logger pinned to info is not dragged down to trace by the '
        'environment', () {
      final out = _CapturingOutput();
      final logger = Logger(
        filter: EnvLogFilter(envValue: 'trace', shippedBuild: false),
        printer: SimplePrinter(printTime: false, colors: false),
        output: out,
        level: Level.info,
      );

      final text = _emit(logger, (l) {
        l.t('TRACE_LINE');
        l.d('DEBUG_LINE');
        l.i('INFO_LINE');
      }, out);

      expect(text, isNot(contains('TRACE_LINE')));
      expect(text, isNot(contains('DEBUG_LINE')));
      expect(text, contains('INFO_LINE'));
    });

    test('a logger without a level: field is governed by the environment '
        'alone', () {
      final out = _CapturingOutput();
      final logger = Logger(
        filter: EnvLogFilter(envValue: 'trace', shippedBuild: false),
        printer: SimplePrinter(printTime: false, colors: false),
        output: out,
      );

      expect(_emit(logger, (l) => l.t('TRACE_LINE'), out),
          contains('TRACE_LINE'));
    });

    test('CENTROID_LOG_LEVEL=all overrides a per-logger floor', () {
      final out = _CapturingOutput();
      final logger = Logger(
        filter: EnvLogFilter(envValue: 'all', shippedBuild: false),
        printer: SimplePrinter(printTime: false, colors: false),
        output: out,
        level: Level.info,
      );

      expect(_emit(logger, (l) => l.t('TRACE_LINE'), out),
          contains('TRACE_LINE'));
      expect(logLevelOverridesLoggerFloor('all'), isTrue);
      expect(logLevelOverridesLoggerFloor('trace'), isFalse);
    });

    test('the per-logger floor cannot make a logger noisier than the '
        'environment', () {
      final out = _CapturingOutput();
      final logger = Logger(
        filter: EnvLogFilter(envValue: 'error', shippedBuild: false),
        printer: SimplePrinter(printTime: false, colors: false),
        output: out,
        level: Level.trace,
      );

      final text = _emit(logger, (l) {
        l.d('DEBUG_LINE');
        l.e('ERROR_LINE');
      }, out);

      expect(text, isNot(contains('DEBUG_LINE')));
      expect(text, contains('ERROR_LINE'));
    });
  });

  group('hotPathPrinter', () {
    test('formats an ordinary line without walking the stack', () {
      final lines = hotPathPrinter().log(LogEvent(Level.info, 'PLAIN'));
      final text =
          lines.join('\n').replaceAll(RegExp(r'\x1B\[[0-9;]*m'), '');

      expect(text, contains('PLAIN'));
      expect(text, isNot(contains('log_config_test.dart')),
          reason: 'methodCount: 0 means no StackTrace.current walk');
      expect(hotPathPrinter().methodCount, equals(0));
    });

    test('still prints frames when an error carries a stack trace', () {
      final lines = hotPathPrinter().log(LogEvent(
        Level.error,
        'BOOM',
        error: StateError('nope'),
        stackTrace: StackTrace.current,
      ));
      final text =
          lines.join('\n').replaceAll(RegExp(r'\x1B\[[0-9;]*m'), '');

      expect(text, contains('BOOM'));
      expect(text, contains('log_config_test.dart'),
          reason: 'errorMethodCount must stay non-zero: an error without a '
              'stack is not diagnosable');
    });
  });

  group('initLogConfig', () {
    test('installs EnvLogFilter as the default filter', () {
      initLogConfig();
      expect(Logger.defaultFilter(), isA<EnvLogFilter>());
    });

    test('installs the methodCount-free printer as the default', () {
      initLogConfig();
      final printer = Logger.defaultPrinter();
      expect(printer, isA<PrettyPrinter>());
      expect((printer as PrettyPrinter).methodCount, equals(0));
      expect(printer.errorMethodCount, greaterThan(0));
    });

    test('records which level was resolved, and where it came from', () {
      // Support reads a station log cold. "No debug lines" and "the subsystem
      // never ran" look identical without this.
      final banner = logLevelBanner();
      expect(banner, contains('[log] level '));
      expect(banner, contains(logLevelFromEnv().name));
      expect(banner, contains('CENTROID_LOG_LEVEL'));
      // Says where the value came from, so nobody has to guess.
      expect(banner, contains('unset, default for a debug build'),
          reason: 'no CENTROID_LOG_LEVEL in the test environment');
    });

    test('initLogConfig itself emits the banner, and at a level the default '
        'admits', () {
      // Capture what initLogConfig actually logs, not a re-creation of it.
      final captured = <LogEvent>[];
      void listener(LogEvent e) => captured.add(e);
      Logger.addLogListener(listener);
      final emitted = <String>[];
      void outListener(OutputEvent e) => emitted.addAll(e.lines);
      Logger.addOutputListener(outListener);
      try {
        initLogConfig();
      } finally {
        Logger.removeLogListener(listener);
        Logger.removeOutputListener(outListener);
      }

      final banners =
          captured.where((e) => '${e.message}'.contains('[log] level'));
      expect(banners, isNotEmpty,
          reason: 'initLogConfig must record the resolved level');
      expect(banners.first.level, equals(Level.info),
          reason: 'trace or debug would be invisible at the shipped default');
      // And it survived the filter all the way to output.
      expect(emitted.where((l) => l.contains('[log] level')), isNotEmpty);
    });

    test('a bare Logger() built after initLogConfig drops trace', () {
      initLogConfig();
      final out = _CapturingOutput();
      final logger = Logger(output: out);

      expect(_emit(logger, (l) => l.t('TRACE_LINE'), out),
          isNot(contains('TRACE_LINE')));
      expect(_emit(logger, (l) => l.w('WARN_LINE'), out),
          contains('WARN_LINE'));
    });
  });

  group('opcuaLogLevelFromEnv', () {
    test('returns a valid LogLevel', () {
      final level = opcuaLogLevelFromEnv();
      expect(LogLevel.values, contains(level));
    });
  });
}

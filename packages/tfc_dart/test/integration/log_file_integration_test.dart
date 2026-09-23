@TestOn('!browser')
library;

import 'dart:io';

import 'package:logger/logger.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/log_config.dart';

void main() {
  group('Combined Dart + open62541 file logging', () {
    late Directory tempDir;
    late String logFilePath;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('log_integration_');
      logFilePath = '${tempDir.path}${Platform.pathSeparator}test.log';
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('Dart logger output is written to log file via RandomAccessFile', () {
      initLogConfig();

      // Open the file the same way main.dart does
      final logFile = File(logFilePath).openSync(mode: FileMode.append);

      // Simulate what _debugPrint does: intercept print() and write to file
      final logger = Logger(
        // Explicitly trace: the default is info (log_config.dart), and this
        // test is about the file sink carrying every level it is handed, not
        // about which levels the default filter admits.
        filter: EnvLogFilter(envValue: 'trace'),
        printer: SimplePrinter(printTime: false),
        output: _FileLogOutput(logFile),
      );

      logger.i('dart info message');
      logger.w('dart warning message');
      logger.e('dart error message');
      logger.t('dart trace message');

      logFile.closeSync();

      final content = File(logFilePath).readAsStringSync();
      expect(content, contains('dart info message'));
      expect(content, contains('dart warning message'));
      expect(content, contains('dart error message'));
      expect(content, contains('dart trace message'));
    });

    test('open62541 native output and Dart logger output both reach same file',
        () async {
      // Spawning `dart run` from inside `dart test` on Windows causes a
      // native asset DLL copy race (PathExistsException). Skip when the
      // CI env var is set; the test passes locally and on macOS/Linux CI.
      if (Platform.isWindows &&
          Platform.environment['CI'] == 'true') {
        markTestSkipped('Skipped on Windows CI — DLL build hook race '
            '(runs locally and on macOS/Linux CI)');
        return;
      }

      final helperSrc = '${Directory.current.path}'
          '${Platform.pathSeparator}test'
          '${Platform.pathSeparator}integration'
          '${Platform.pathSeparator}log_file_test_helper.dart';

      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', helperSrc, logFilePath],
        workingDirectory: Directory.current.path,
      );

      // Append subprocess stdout/stderr (native open62541 output) to log file
      final logFile = File(logFilePath).openSync(mode: FileMode.append);
      logFile.writeStringSync(result.stdout as String);
      logFile.writeStringSync(result.stderr as String);
      logFile.closeSync();

      final content = File(logFilePath).readAsStringSync();

      // Dart logger output (written via RandomAccessFile by helper)
      expect(content, contains('DART_MARKER_INFO'),
          reason: 'Dart logger info output should be in the file');
      expect(content, contains('DART_MARKER_ERROR'),
          reason: 'Dart logger error output should be in the file');

      // open62541 native output (written to C stdout, captured by parent)
      expect(content, contains('info/client'),
          reason: 'open62541 native info output should be in the file');
    }, timeout: Timeout(Duration(seconds: 120)));


    test('second handle can open existing file in append mode', () {
      // Key regression test: the C++ side opens the log file first, then
      // Dart opens it in append mode. With freopen_s (exclusive lock) this
      // would throw PathAccessException. With CreateFileW + FILE_SHARE_WRITE
      // it succeeds. We simulate by opening the file twice.

      // First handle (simulates C++ CreateFileW)
      final handle1 = File(logFilePath).openSync(mode: FileMode.write);
      handle1.writeStringSync('first writer\n');

      // Second handle must succeed (would throw if sharing is denied)
      final handle2 = File(logFilePath).openSync(mode: FileMode.append);
      handle2.writeStringSync('second writer\n');

      handle1.closeSync();
      handle2.closeSync();

      // Both handles wrote successfully — file is non-empty
      final size = File(logFilePath).lengthSync();
      expect(size, greaterThan(0));
    });

    test('EnvLogFilter respects log level filtering', () {
      // CENTROID_LOG_LEVEL=trace → everything passes.
      final filter = EnvLogFilter(envValue: 'trace');

      for (final level in [
        Level.trace,
        Level.debug,
        Level.info,
        Level.warning,
        Level.error,
        Level.fatal,
      ]) {
        expect(
          filter.shouldLog(LogEvent(level, 'test')),
          isTrue,
          reason: '$level should pass at trace filter level',
        );
      }
    });

    test('Logger with EnvLogFilter writes only matching levels to file', () {
      initLogConfig();

      final logFile = File(logFilePath).openSync(mode: FileMode.append);

      // Create a logger that only shows warnings and above
      final warningFilter = _MinLevelFilter(Level.warning);
      final logger = Logger(
        filter: warningFilter,
        printer: SimplePrinter(printTime: false),
        output: _FileLogOutput(logFile),
      );

      logger.t('trace should not appear');
      logger.d('debug should not appear');
      logger.i('info should not appear');
      logger.w('warning should appear');
      logger.e('error should appear');

      logFile.closeSync();

      final content = File(logFilePath).readAsStringSync();
      expect(content, isNot(contains('trace should not appear')));
      expect(content, isNot(contains('debug should not appear')));
      expect(content, isNot(contains('info should not appear')));
      expect(content, contains('warning should appear'));
      expect(content, contains('error should appear'));
    });
  });
}

/// A LogOutput that writes to a RandomAccessFile (same as MSIX production path).
class _FileLogOutput extends LogOutput {
  final RandomAccessFile _file;
  _FileLogOutput(this._file);

  @override
  void output(OutputEvent event) {
    for (final line in event.lines) {
      _file.writeStringSync('$line\n');
    }
  }
}

/// A filter that only allows events at or above [minLevel].
class _MinLevelFilter extends LogFilter {
  final Level minLevel;
  _MinLevelFilter(this.minLevel);

  @override
  bool shouldLog(LogEvent event) => event.level >= minLevel;
}


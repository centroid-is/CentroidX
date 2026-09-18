import 'dart:io';

import 'package:logger/logger.dart';

/// True when this code was compiled for release or profile.
///
/// This is exactly how `package:flutter/foundation.dart` defines
/// `kReleaseMode` / `kProfileMode`; spelling the constants out here keeps
/// tfc_dart a pure Dart package (it is also run from `bin/` by the Dart VM,
/// where `foundation` is not available). Both are compile-time constants, so
/// the branch below folds away at build time.
const bool _kProductMode = bool.fromEnvironment('dart.vm.product');
const bool _kProfileMode = bool.fromEnvironment('dart.vm.profile');

/// Whether the running binary is a shipped build (release or profile) rather
/// than a JIT/debug run.
const bool kShippedBuild = _kProductMode || _kProfileMode;

/// Whether this build is running in a browser.
///
/// Spelled out rather than imported from `package:flutter/foundation.dart`,
/// for the same reason the two constants above it are: this package is pure
/// Dart and is run from `bin/` by the Dart VM, where `foundation` does not
/// exist. It is the same definition Flutter uses — dart2js compiles `int` and
/// `double` to one JS number, so `0` and `0.0` are identical there and on no
/// other platform — and it is a compile-time constant, so each branch below
/// folds away.
///
/// Private, because `tfc_dart.dart` exports this library and a public `kIsWeb`
/// here would collide with `foundation`'s in every Flutter file importing
/// both.
///
/// Every `Platform.environment` read in this file throws in a browser: there
/// is no environment, and `dart:io`'s web stub raises rather than returning an
/// empty map. `initLogConfig()` is the first thing `main()` calls, so without
/// these guards a web build died before its first frame.
const bool _kIsWeb = identical(0, 0.0);

/// One environment variable, or null where there is no environment.
String? _env(String name) => _kIsWeb ? null : Platform.environment[name];

/// The level used when CENTROID_LOG_LEVEL is unset.
///
/// * shipped builds -> [Level.info]. Trace and debug are the levels that carry
///   the per-sample and per-record log sites (one of them fired 13,013 times in
///   a single page load), and a default `PrettyPrinter` line measured 10-23us
///   to format depending on machine load, plus the console write on top. A
///   line the filter drops costs 43ns. Info and above are lifecycle events --
///   connected, subscribed, migrated, session lost -- which are what makes an
///   error in the log file interpretable weeks later, and are all event-driven
///   rather than per-sample.
/// * everything else -> [Level.debug]. Debug builds are attended; the extra
///   detail is worth its cost, but the trace firehose is not.
///
/// Deliberately *not* `assert`-gated the way `package:logger`'s
/// [DevelopmentFilter] is. That filter drops every line in release, which would
/// leave a station with no record of its own faults -- the opposite of what an
/// unattended industrial box needs. Errors and warnings must always survive.
Level defaultLogLevel({bool shippedBuild = kShippedBuild}) =>
    shippedBuild ? Level.info : Level.debug;

/// Maps a CENTROID_LOG_LEVEL string to a [Level].
///
/// Valid values: trace, debug, info, warning, error, fatal, off, all.
/// `all` behaves like `trace` but additionally overrides per-logger `level:`
/// floors -- see [EnvLogFilter].
///
/// Unset or unrecognised falls back to [defaultLogLevel].
Level logLevelFor(String? value, {bool shippedBuild = kShippedBuild}) {
  return switch (value?.toLowerCase()) {
    'all' || 'trace' => Level.trace,
    'debug' => Level.debug,
    'info' => Level.info,
    'warning' || 'warn' => Level.warning,
    'error' => Level.error,
    'fatal' => Level.fatal,
    'off' || 'none' => Level.off,
    _ => defaultLogLevel(shippedBuild: shippedBuild),
  };
}

/// Whether [value] asks for per-logger `level:` floors to be ignored.
///
/// Only the literal `all` does. It is the escape hatch for the handful of
/// loggers that pin themselves to `Level.info` because they are chatty
/// (modbus, UMAS): `CENTROID_LOG_LEVEL=trace` respects those floors,
/// `CENTROID_LOG_LEVEL=all` blows through them.
bool logLevelOverridesLoggerFloor(String? value) =>
    value?.toLowerCase() == 'all';

/// Reads CENTROID_LOG_LEVEL env var and returns the corresponding [Level].
///
/// Valid values: trace, debug, info, warning, error, fatal, off, all
/// Defaults to [defaultLogLevel] if unset or unrecognized.
Level logLevelFromEnv() => logLevelFor(_env('CENTROID_LOG_LEVEL'));

// `opcuaLogLevelFromEnv` is in `opcua_log_level.dart`. open62541's `LogLevel`
// comes from the FFI barrel, and this file is imported by `main.dart` itself —
// so that one `show LogLevel` put `dart:ffi` at the very root of the app's
// import graph, where dart2js refuses it outright.

/// A [LogFilter] that uses `CENTROID_LOG_LEVEL` to control which messages
/// are logged. Messages at or above the configured level pass through.
///
/// A per-logger level -- `Logger(level: Level.info)`, which `logger` stores on
/// [LogFilter.level] -- acts as a *floor*: such a logger never emits below its
/// own level even when the environment asks for more. That is the point of the
/// three loggers in this repo that set it (modbus/UMAS chatter). Set
/// `CENTROID_LOG_LEVEL=all` to ignore those floors.
///
/// [LogFilter.level] falls back to the static `Logger.level` (default
/// [Level.trace]) when no per-logger level was given, so the floor is a no-op
/// unless somebody opted in.
class EnvLogFilter extends LogFilter {
  final Level _minLevel;
  final bool _ignoreLoggerFloor;

  EnvLogFilter({String? envValue, bool? shippedBuild})
      : _minLevel = logLevelFor(
          envValue ?? _env('CENTROID_LOG_LEVEL'),
          shippedBuild: shippedBuild ?? kShippedBuild,
        ),
        _ignoreLoggerFloor = logLevelOverridesLoggerFloor(
            envValue ?? _env('CENTROID_LOG_LEVEL'));

  @override
  bool shouldLog(LogEvent event) {
    if (event.level < _minLevel) return false;
    if (_ignoreLoggerFloor) return true;
    final floor = level;
    return floor == null || event.level >= floor;
  }
}

/// The printer every bare `Logger()` gets once [initLogConfig] has run.
///
/// `PrettyPrinter`'s default `methodCount: 2` calls `StackTrace.current` and
/// walks it for *every* line, which is the bulk of what a single
/// `logger.t(...)` costs -- measured here, dropping it to zero took the same
/// call from 10.0us to 1.1us.
/// `errorMethodCount` is left alone, so anything logged with an error or an
/// explicit stack trace still prints a full frame list: the stack is kept
/// exactly where it is worth paying for.
///
/// Everything else is [PrettyPrinter]'s own default, deliberately -- this
/// becomes the format of nearly every log line in the app, and a performance
/// fix is no place to restyle them. The one addition is a timestamp:
/// [initLogConfig] exists to serve `CENTROID_LOG_FILE`, and a station log with
/// no clock in it cannot be lined up against a shift, an alarm, or anything
/// else that happened that day.
PrettyPrinter hotPathPrinter() => PrettyPrinter(
      methodCount: 0,
      errorMethodCount: 8,
      dateTimeFormat: DateTimeFormat.onlyTimeAndSinceStart,
    );

/// Writes each log line straight to the file, flushed as it goes.
///
/// Flushing per event costs a little throughput and buys the property that
/// matters when diagnosing a hang: whatever was logged before the process
/// stopped is actually on disk.
///
/// Deliberately a [RandomAccessFile] and not an [IOSink]. `IOSink.flush()`
/// marks the sink bound for the whole duration of the flush -- which is
/// asynchronous -- and any `writeln` landing in that window throws
/// `StateError: StreamSink is bound to a stream`. Flushing per event made
/// that window permanent. `logger` catches the throw and prints it, so the
/// symptom was a stack trace on stdout for nearly every line, and the line
/// itself missing from the file. `flush()` also throws *synchronously*, so
/// the `catchError` that was attached to it could never have caught it.
class _FileOutput extends LogOutput {
  _FileOutput(this._file);

  final RandomAccessFile _file;

  @override
  void output(OutputEvent event) {
    // Logging must never throw into whoever called the logger: LogOutput
    // failures surface as printed stack traces from inside logger itself,
    // which is far noisier than the line that was being logged.
    try {
      _file.writeStringSync('${event.lines.join('\n')}\n');
      _file.flushSync();
    } catch (_) {}
  }
}

RandomAccessFile? _logFile;

/// Call once at startup (before creating any Logger instances) to configure
/// the global log filter and printer from CENTROID_LOG_LEVEL, to record which
/// level was resolved (see [logLevelBanner]), and -- when CENTROID_LOG_FILE is
/// set -- to mirror every log line into that file.
///
/// The file sink exists because [ConsoleOutput] writes through `print()`,
/// which only reaches a file if whoever launched the process happens to be
/// capturing stdout. Under an IDE the output is trapped in a console pane no
/// tool can read, and when `flutter run` exits while the app keeps running,
/// the capture disappears entirely -- precisely when a fault needs a record.
/// Writing from inside the process removes that dependency.
void initLogConfig() {
  Logger.defaultFilter = () => EnvLogFilter();
  Logger.defaultPrinter = () => hotPathPrinter();

  final banner = logLevelBanner();
  _installFileOutput(banner);

  // Last, and exactly once: by now the file sink (if any) is installed, so
  // this lands in the file as well as the console. An earlier `return` used
  // to need its own copy of this line, which is how one of them drifted.
  Logger().i(banner);
}

/// Points [Logger.defaultOutput] at `CENTROID_LOG_FILE` when that is set and
/// the launcher has not already redirected stdout there.
void _installFileOutput(String banner) {
  // No environment and no filesystem in a browser, so no file sink.
  if (_kIsWeb) return;
  final path = Platform.environment['CENTROID_LOG_FILE'];
  if (path == null || path.isEmpty) return;

  // The Windows runner sets this once it has already pointed the process
  // stdout at that same file. ConsoleOutput therefore lands there anyway, and
  // opening it a second time here gives two writers with independent file
  // positions -- the runner writing from offset 0, this one appending at EOF,
  // each overwriting the other. main.dart already honours the flag for its
  // own file; the logger has to as well.
  if (Platform.environment['CENTROID_LOG_REDIRECTED'] == '1') return;

  try {
    _logFile ??= File(path).openSync(mode: FileMode.append);
    final file = _logFile!;
    Logger.defaultOutput = () => MultiOutput([ConsoleOutput(), _FileOutput(file)]);
    // The banner goes in the header too, not only through the logger: the
    // header is written straight to the file and is therefore unfiltered, so a
    // station deliberately run at warning or error still records which level
    // it is running at. Filtering out the one line that explains the
    // filtering would be a poor joke.
    file.writeStringSync('--- log opened ${DateTime.now().toIso8601String()} '
        '| $banner ---\n');
  } catch (e) {
    stderr.writeln('[log] file logging unavailable ($path): $e');
  }
}

/// One line naming the level this process resolved, and where it came from.
///
/// Support reads a station's log file cold, months later, with no idea what
/// the box was configured for. Without this, "there are no debug lines" and
/// "the subsystem never ran" look identical. Exposed separately so a caller
/// can put it wherever else it needs to go.
String logLevelBanner() {
  final env = _env('CENTROID_LOG_LEVEL');
  final source = (env == null || env.isEmpty)
      ? 'CENTROID_LOG_LEVEL unset, default for a '
          '${kShippedBuild ? 'release/profile' : 'debug'} build'
      : 'CENTROID_LOG_LEVEL=$env';
  return '[log] level ${logLevelFor(env).name} ($source). '
      'Set CENTROID_LOG_LEVEL to trace/debug/info/warning/error, '
      'or all to also override per-logger levels.';
}

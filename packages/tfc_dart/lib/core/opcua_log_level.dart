/// Reading the open62541 client's own log level from the environment.
///
/// Its own file, and not part of `log_config.dart`, because `LogLevel` is
/// exported by `package:open62541/open62541.dart` — the FFI barrel. Every
/// entrypoint in the repository imports `log_config.dart` for
/// `initLogConfig()`, so leaving this one function there made `dart:ffi`
/// reachable from `main.dart` in a single hop, and a web build a hard compile
/// error before it had read a line of app code.
///
/// Only code that builds a real OPC UA client needs this.
library;

import 'dart:io';

import 'package:open62541/open62541.dart' show LogLevel;

/// Reads CENTROID_OPCUA_LOG_LEVEL env var and returns the corresponding
/// open62541 [LogLevel].
///
/// Valid values: trace, debug, info, warning, error, fatal
/// Defaults to [LogLevel.UA_LOGLEVEL_INFO] if unset or unrecognized.
LogLevel opcuaLogLevelFromEnv() {
  final value = Platform.environment['CENTROID_OPCUA_LOG_LEVEL']?.toLowerCase();
  return switch (value) {
    'trace' => LogLevel.UA_LOGLEVEL_TRACE,
    'debug' => LogLevel.UA_LOGLEVEL_DEBUG,
    'info' => LogLevel.UA_LOGLEVEL_INFO,
    'warning' || 'warn' => LogLevel.UA_LOGLEVEL_WARNING,
    'error' => LogLevel.UA_LOGLEVEL_ERROR,
    'fatal' => LogLevel.UA_LOGLEVEL_FATAL,
    _ => LogLevel.UA_LOGLEVEL_INFO,
  };
}

// FFI-free subset of tfc_dart for MCP server and other pure-Dart consumers.
//
// This barrel export includes ONLY files that have zero transitive dependencies
// on open62541, jbtm, or amplify_secure_storage_dart. The MCP server imports
// this file instead of tfc_dart.dart to avoid FFI link errors with
// `dart compile exe`.
//
// Files deliberately excluded:
//   - core/database_drift.dart (imports alarm.dart -> open62541)
//   - core/database.dart (imports secure_storage/secure_storage.dart -> amplify)
//   - core/alarm.dart (imports state_man.dart, boolean_expression.dart -> open62541)
//   - core/state_man.dart (imports open62541, jbtm)
//   - core/boolean_expression.dart (imports open62541)
//   - core/collector.dart (imports open62541)
//   - core/preferences.dart (imports secure_storage/secure_storage.dart -> amplify)
//   - converter/dynamic_value_converter.dart (imports open62541)
//   - core/secure_storage/secure_storage.dart (imports amplify)

export 'core/ring_buffer.dart';
export 'core/fuzzy_match.dart';
export 'converter/duration_converter.dart';
export 'core/secure_storage/interface.dart'; // MySecureStorage abstract only
export 'core/mcp_tables.dart';
export 'core/mcp_database.dart';
export 'core/shift.dart';
export 'core/report.dart';
export 'core/report_math.dart';
export 'core/report_result.dart';
export 'core/report_store.dart';
export 'core/report_engine.dart';
export 'core/sql_dialect.dart';

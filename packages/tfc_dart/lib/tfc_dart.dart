// Core
export 'core/alarm.dart';
export 'core/boolean_expression.dart';
export 'core/fuzzy_match.dart';
export 'core/collector.dart';
export 'core/database.dart';
export 'core/log_config.dart';
export 'core/database_drift.dart' hide Alarm, AlarmHistory;
export 'core/preferences.dart';
export 'core/ring_buffer.dart';
// The types and the [StateMan] interface, not the OPC UA client. This barrel
// is imported by the report screens, which are as far from a PLC session as
// this repository gets — and exporting `state_man.dart` here put `dart:ffi`
// in the closure of every one of them. Code that builds a client imports
// `package:tfc_dart/core/state_man.dart` directly, which is what every such
// caller in this repository already does.
export 'core/state_man_types.dart';
export 'core/state_man_config_storage.dart';
export 'core/shift.dart';
export 'core/report.dart';
export 'core/report_math.dart';
export 'core/report_result.dart';
export 'core/production_window.dart';
export 'core/report_store.dart';
export 'core/report_engine.dart';
export 'core/sql_dialect.dart';

// Converters
export 'converter/duration_converter.dart';
export 'converter/dynamic_value_converter.dart';

// Secure Storage
export 'core/secure_storage/interface.dart';
export 'core/secure_storage/secure_storage.dart';

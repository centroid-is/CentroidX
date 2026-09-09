/// Wire protocol for the relay pipe.
///
/// Shapes only: no transport, no JSON-RPC envelope (json_rpc_2 owns that),
/// no I/O. Everything here round-trips through plain JSON maps.
///
/// Since plan 01-05 the package also carries the *declarations* the two ends
/// agree on — `StateManApi` and its sub-interfaces — which are still shapes
/// rather than behavior: nothing here implements them. One import gets a
/// consumer the interface, the value types it exchanges, and the store that
/// backs `listen`.
library;

export 'src/methods.dart';
export 'src/quality.dart';
export 'src/sanitize.dart';
export 'src/redact.dart';
export 'src/json_equality.dart';
export 'src/wire_value.dart';
export 'src/dynamic_value.dart';
export 'src/messages.dart';
export 'src/pipe_keys.dart';
export 'src/alarm_keys.dart';
export 'src/alarm_active_entry.dart';
export 'src/alarm_history.dart';
export 'src/freshness.dart';
export 'src/write_result.dart';
export 'src/hold_handle.dart';
export 'src/send_buffer.dart';
export 'src/hello_gate.dart';
export 'src/value_listenable.dart';
export 'src/value_store.dart';
export 'src/browse.dart';
export 'src/timeseries.dart';
export 'src/series_address.dart';
export 'src/result_too_large.dart';
export 'src/source_refusal.dart';
export 'src/history_view.dart';
export 'src/ulid.dart';
export 'src/preferences_api.dart';
export 'src/state_man_api.dart';
export 'src/write_outcome_log.dart';
export 'src/access_api.dart';
export 'src/hold_registry.dart';

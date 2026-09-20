/// Moved to `tfc_dart` so the backend serves the same class the panel calls —
/// the move `audit_trail_store.dart` made one milestone earlier, for the same
/// reason and with the same consequence.
///
/// The configuration history was unreachable from a relayed panel because the
/// only reader of `config_change` lived in the app, above the package the
/// gateway is built from. `BackendConfigHistory` could not call it without
/// this move, and a second reader would have been a second set of window,
/// cursor and decode rules to keep in step with the first.
///
/// Kept as an export so no call site changed, and so a `grep` for the old path
/// still lands somewhere true.
library;

export 'package:tfc_dart/core/config/config_change_store.dart';

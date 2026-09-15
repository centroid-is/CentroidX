/// What a Postgres `NOTIFY` payload says, and how often the connection
/// carrying it is checked for having died.
///
/// ## Why this is not in `database_drift.dart`
///
/// These three declarations are hand-written. There is no drift annotation
/// here, no `part` directive, and nothing in this file is generated — which is
/// what separates it from the twelve `Table` subclasses that cannot be moved
/// out of `database_drift.dart` without moving `@DriftDatabase` with them
/// (drift emits a table's implementation beside the *database's* annotation,
/// not beside the table's declaration; see `docs/drift-codegen-boundary.md`).
///
/// The cost of leaving them there was paid by every consumer.
/// `database_drift.dart` imports `dart:io`, `dart:isolate`, `drift/native.dart`
/// and `drift_postgres`; decoding a JSON string needs none of those, but a
/// reader who wanted [NotificationData] had to take all four. `TimeseriesSource`
/// — the seam a gateway panel reaches history through — was importing the whole
/// database layer for two type names.
///
/// ## What it is not
///
/// Not the payload's *producer*. The trigger functions that emit these strings
/// are SQL literals in `database_drift.dart`, next to the tables they fire on,
/// and they stay there: they are statements the database layer executes, and
/// they mean nothing away from the schema they name.
library;

import 'dart:convert';

/// How often the LISTEN/NOTIFY connection is checked for having died, on
/// behalf of the channel streams riding on it. See
/// `AppDatabase._ensureNotificationWatchdog`.
const kNotificationWatchdogInterval = Duration(seconds: 5);

enum NotificationAction {
  insert,
  update,
  delete,
}

class NotificationData {
  final NotificationAction action;
  final Map<String, dynamic> data;

  NotificationData({required this.action, required this.data});

  factory NotificationData.fromJson(String json) {
    final data = jsonDecode(json);
    return NotificationData(
        action: NotificationAction.values
            .byName((data['action'] as String).toLowerCase()),
        data: data['data'] as Map<String, dynamic>);
  }
}

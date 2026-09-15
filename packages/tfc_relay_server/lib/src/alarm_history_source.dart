/// The one seam an alarm-history read crosses on its way out of the gateway.
library;

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// Where a [Methods.alarmHistory] request goes.
///
/// ## Why a seam and not a dependency
///
/// `AlarmAckSink`'s argument verbatim: this package cannot name an alarm
/// engine. The engine and the `alarm_history` table live in `tfc_dart`, and
/// `tfc_dart` depends on *this* package — so a direct reference here would be
/// a cycle, and pulling the Flutter side into a pure-Dart server package's
/// version solve is the analyzer-cap blocker that has stopped this repo twice
/// in twelve months. The gateway takes the reader as an argument, injected at
/// `RelayServer` construction the way `TokenValidator` and `KeyPolicy` are.
///
/// It is on the barrel for that reason and only that reason — an embedder
/// writing `RelayServer(alarmHistory:)` has to be able to name the type.
///
/// ## Why this one DOES take the wire type, when `AlarmAckSink` does not
///
/// The difference is size, and the argument that decided it is `AlarmAckSink`'s
/// own: *"a seam an embedder implements should not oblige it to decode a wire
/// shape it did not choose."* An acknowledge is two plain values — a uid and an
/// index — so a server-local spelling of them costs nothing and buys
/// independence. A history row is thirteen fields, three of them nullable with
/// three different meanings for their absence, one of them a provenance with a
/// closed roster and a by-name refusal. Restating that as a second type would
/// be a second place the row's shape is written down, kept in step by nothing,
/// and the field most likely to drift is `tsSource` — the one a stop analysis
/// exists to be audited on.
///
/// So the implementer builds [AlarmHistoryEntry] directly. It is a pure-Dart
/// data class in a package the implementer already depends on, and the
/// constructor is where the refusals live, which means an engine that builds a
/// nonsense row finds out at its own call site rather than on the wire.
///
/// ## What it must NOT do
///
/// **Never answer an empty list for a failure.** An empty history is what a
/// plant that has never had an alarm looks like, and it is exactly the answer
/// `RelayAlarmSource.getRecentAlarms` was silently giving every gateway station
/// before this method existed. Throw instead: the gateway turns a throw into
/// `handlerFailed` and the panel shows it. Completing with `[]` means, and may
/// only mean, *this window genuinely contains no rows*.
///
/// ## Why it returns rows resolved against the BACKEND's configuration
///
/// `AlarmMan.getRecentAlarms` resolves each row against the local alarm
/// configuration and drops — via `whereType`, silently — every row whose
/// `alarm_uid` it cannot find. On one machine that join is free. Across this
/// wire the two copies are a backend that evaluated the rules and a panel
/// holding a device-local mirror of a preference, so the moment they disagree
/// the panel erases history it was correctly sent. The implementer does the
/// resolution, against the configuration the engine actually ran, and sends
/// `level` / `title` / `description` / `group` / `acknowledgeRequired` on the
/// row. See `alarm_history.dart`'s library doc.
abstract interface class AlarmHistorySource {
  /// The `alarm_history` rows overlapping the window, newest first.
  ///
  /// [limit] is a ceiling on rows, already checked against
  /// [AlarmHistoryParams.maxLimit] and known to be positive. [from] and [to]
  /// are UTC or null, and they bound the window by **overlap** rather than by
  /// start — `AlarmMan.getRecentAlarms` records why, and the reason is a
  /// measurement about downtime: an alarm that went off before [from] and only
  /// cleared inside the window is part of that window's stop, and a query that
  /// dropped it would report the stop as shorter than it was.
  ///
  /// **Ordering is `created_at` descending**, matching direct mode. Two
  /// transports that disagreed about which end of the list is newest is the
  /// divergence `RelayAlarmSource` exists to prevent.
  ///
  /// Called only after the gateway has checked that `AlarmKeys.active` is a key
  /// this station may see. An implementation does not repeat that decision and
  /// must not soften it.
  Future<List<AlarmHistoryEntry>> recentAlarms({
    required int limit,
    DateTime? from,
    DateTime? to,
  });
}

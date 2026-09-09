/// The one file in `tfc_dart` that names the gateway's alarm-history seam.
///
/// ## Why this is a separate file, and not a method on the writer
///
/// `backend_alarm_ack.dart`'s argument, unchanged: `backend_alarms.dart` and
/// `backend_alarm_history.dart` must not import `tfc_relay_server`, because the
/// alarm engine and its history writer are constructed **unconditionally** —
/// `bin/main.dart` builds them above the relay guard, so that turning the
/// WebSocket off does not turn the plant's alarms off — while the relay section
/// is optional and SVN runs with it absent today. A writer whose own
/// declaration named `AlarmHistorySource` would be a writer a backend with no
/// relay could not build. So the seam is named here, in a file constructed only
/// inside the relay composition.
///
/// `AlarmHistoryWriter` is the other half of the same table and deliberately
/// has no read method: it is the object the *engine* holds, and giving it one
/// would put the gateway's read on the engine's collaborator.
///
/// ## Why it is not thin, where the ack sink is
///
/// `BackendAlarmAckSink` is one field, one method and one `await`, and its test
/// counts the lines. This one carries a query and a projection, and that is the
/// correct place for both:
///
///  * **The query** is the one `AlarmMan.getRecentAlarms` runs — same table,
///    same `alarmHistoryOverlaps` window, same `created_at DESC`, same ceiling.
///    Sharing the window expression rather than restating it is the point:
///    `alarmHistoryOverlaps` is where the Postgres `::timestamp` casts live, it
///    is measured against a real server (`alarm_history_range_test.dart`,
///    `database_integration_test.dart`), and a second spelling of a datetime
///    comparison in this codebase is a second thing that silently degrades into
///    a lexicographic `text <= text` on one of the two backends.
///  * **The projection** is [AlarmHistoryEntry]'s thirteen fields, built here
///    because `AlarmHistorySource`'s doc says so: *"the implementer builds
///    [AlarmHistoryEntry] directly"*, the constructor being where the refusals
///    live.
///
/// ## The one place this deliberately differs from direct mode
///
/// `AlarmMan.getRecentAlarms` resolves each row against the local configuration
/// and returns `null` — dropped by `whereType`, silently — for a uid it cannot
/// find. **That drop is not reproduced here, and its absence is the property.**
/// On a direct station the configuration and the rows are one file on one
/// machine. In gateway mode they are a backend that evaluated the rules and a
/// panel holding a device-local mirror of a preference, so the moment they
/// disagree that join makes an alarm renamed last week erase its own history,
/// with no error anywhere. `alarm_history.dart`'s library doc is explicit that
/// this is what the wire type exists to make unrepresentable.
///
/// The row already carries its own `alarm_title`, `alarm_description`,
/// `alarm_level` and `expression` — what the alarm *was when it fired*, which
/// is a better answer than today's configuration anyway. Only `group` and
/// `acknowledgeRequired` are not columns, so only those two are looked up, and
/// an unresolvable lookup yields the empty group and `false` rather than
/// dropping the row.
library;

import 'package:drift/drift.dart' show OrderingMode, OrderingTerm;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show AlarmHistoryEntry;
import 'package:tfc_relay_server/tfc_relay_server.dart' show AlarmHistorySource;

import '../alarm.dart' show AlarmConfig, AlarmRule, alarmHistoryOverlaps;
import '../database_drift.dart' show AlarmHistoryData, AppDatabase;
import 'backend_alarms.dart' show AlarmDefinitions;

/// Answers a panel's `alarmHistory` out of the backend's own `alarm_history`.
///
/// **Completing with `[]` means the window is empty; a failure throws.** The
/// gateway turns the throw into `handlerFailed` and the panel shows it, which
/// is the whole point of the seam: an empty history is what a plant that has
/// never had an alarm looks like, and it is exactly the answer every gateway
/// station was silently given before this class existed. Nothing here catches
/// anything.
final class BackendAlarmHistorySource implements AlarmHistorySource {
  const BackendAlarmHistorySource({
    required this.database,
    required this.definitions,
  });

  /// The `alarm_history` this gateway reads.
  ///
  /// Public for [definitions]' reason: the composition arm asserts it is the
  /// database the rest of the graph was built over, rather than a second
  /// connection nobody counted.
  final AppDatabase database;

  /// The configuration the engine actually ran, for the two fields that are
  /// not columns.
  ///
  /// Public so the composition arm can assert it is *the* engine the panels are
  /// served from, rather than a second one holding a different configuration —
  /// `BackendAlarmAckSink.engine`'s argument, and it binds the same way.
  final AlarmDefinitions definitions;

  /// See [AlarmHistorySource.recentAlarms]. Mirrors
  /// `AlarmMan.getRecentAlarms`, which is the reference implementation for
  /// every semantic here: the overlap window, the descending order and the
  /// refusal to guess a rule.
  @override
  Future<List<AlarmHistoryEntry>> recentAlarms({
    required int limit,
    DateTime? from,
    DateTime? to,
  }) async {
    // [limit] arrives validated — positive, and under
    // `AlarmHistoryParams.maxLimit`, both checked by `AlarmHandlers.recent`
    // before this is called. Re-checking it here would be a second opinion that
    // can drift from the first; softening it would be worse, because a clamp
    // answers a short list to a caller that asked for a long one and says
    // nothing about the difference.
    final query = database.select(database.alarmHistory);
    if (from != null || to != null) {
      // The SHARED expression, never a second spelling. It bounds by overlap
      // rather than by start — an alarm that went off before [from] and only
      // cleared inside the window is part of that window's stop — and it is
      // where the `::timestamp` casts that make the comparison survive Postgres
      // live. See `alarmHistoryOverlaps`.
      query.where((t) => alarmHistoryOverlaps(t, from: from, to: to));
    }
    // `created_at DESC`, spelled exactly as `AlarmMan.getRecentAlarms` spells
    // it — no cast — and the sameness is the point: two transports that
    // disagreed about which end of the list is newest is the divergence
    // `RelayAlarmSource` exists to prevent, and a cast here that direct mode
    // does not have would BE that divergence.
    //
    // Worth knowing, and deliberately not fixed here: the column is TEXT
    // (`storeDateTimeAsText`) and holds two spellings — `2026-08-29 10:00:00`
    // from a `::timestamp` write, ISO-8601 with a `T` from a drift insert —
    // which do not sort against each other, ' ' being below 'T'. In production
    // only `AlarmHistoryWriter` inserts, and every one of its statements goes
    // through the cast, so every row on the plant carries the same spelling.
    // A mixed table would mis-order in direct mode too, and the fix belongs
    // where both read it from.
    final rows = await (query
          ..orderBy([
            (t) => OrderingTerm(
                expression: t.createdAt, mode: OrderingMode.desc),
          ])
          ..limit(limit))
        .get();

    // No `whereType`, no null, no drop. See the library doc.
    return <AlarmHistoryEntry>[for (final row in rows) _entryOf(row)];
  }

  /// One stored row as the wire sees it.
  AlarmHistoryEntry _entryOf(AlarmHistoryData row) {
    final alarm = _alarmOf(row.alarmUid);
    return AlarmHistoryEntry(
      uid: row.alarmUid,
      ruleIndex: row.ruleIndex,
      // The row's own three, because they are what the alarm was when it fired.
      // Today's configuration is a worse answer to the question a history page
      // asks, and on a renamed alarm it is a wrong one.
      level: row.alarmLevel,
      title: row.alarmTitle,
      description: row.alarmDescription,
      // Not a column. Resolved against the definitions the engine ran, so the
      // panel never has to join — it has no configuration to join against.
      group: alarm?.group ?? const <String>[],
      expression: row.expression,
      acknowledgeRequired: _ruleOf(alarm, row.ruleIndex)?.acknowledgeRequired ??
          false,
      active: row.active,
      pendingAck: row.pendingAck,
      createdAt: row.createdAt,
      deactivatedAt: row.deactivatedAt,
      // Straight through. `AlarmTsSource.wireName` is what the writer stored
      // and what the wire spells, so re-deriving it here would be a third
      // spelling of a provenance that a stop analysis is audited on.
      tsSource: row.tsSource,
    );
  }

  /// The definition behind [uid], or null when nothing configured claims it.
  ///
  /// Null is ordinary: a deleted or renamed alarm's rows outlive it, and the
  /// row is still that alarm's history.
  AlarmConfig? _alarmOf(String uid) {
    for (final alarm in definitions.config?.alarms ?? const <AlarmConfig>[]) {
      if (alarm.uid == uid) return alarm;
    }
    return null;
  }

  /// The rule [ruleIndex] names, or null when the row names none and when the
  /// one it names no longer exists.
  ///
  /// `AlarmMan.getRecentAlarms`'s bounds check, kept for its reason: a pre-v7
  /// row states no rule index, and a row whose index has since been deleted
  /// names a rule that is gone. Matching either to rule 0 would be a guess
  /// dressed as a fact, and the field it decides — `acknowledgeRequired` —
  /// is what puts a button on an operator's screen.
  static AlarmRule? _ruleOf(AlarmConfig? alarm, int? ruleIndex) {
    if (alarm == null || ruleIndex == null) return null;
    if (ruleIndex < 0 || ruleIndex >= alarm.rules.length) return null;
    return alarm.rules[ruleIndex];
  }
}

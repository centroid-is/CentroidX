/// `alarm_history`, written on activation as well as on deactivation.
///
/// One row per activation: opened when the rule goes true, closed when it
/// clears. Until this file the table only ever saw a row when an alarm
/// *finished*, so an alarm standing right now was invisible to every stop
/// analysis, to the panel's history read, and to anyone asking the plant
/// database what was wrong at the time.
///
/// ## 1. One row, two edges (D-4)
///
///  * **INSERT on activation** — `active = true`, `deactivated_at` a real SQL
///    NULL, `created_at` the transition's stamp, `ts_source` its provenance,
///    `rule_index` always supplied.
///  * **UPDATE on deactivation** — `active = false`, `deactivated_at` the
///    clearing evaluation's stamp, `deactivated_reason` one of [reasons].
///
/// Two rows would double-count every stop: `alarmHistoryOverlaps`
/// (`alarm.dart:212`) and `StopIntervalSource` both read a row as **one**
/// interval with a nullable end. The guarantee does not rest on this class
/// behaving — the v7 partial unique index
/// `(alarm_uid, rule_index) WHERE deactivated_at IS NULL` makes a second open
/// row unrepresentable, because discipline does not survive a crash between
/// the SELECT and the INSERT.
///
/// **`rule_index` is never omitted.** 14-01's arm 5 measured why: Postgres
/// treats NULLs as *distinct* in a unique index, so a row written without a
/// rule index gets no open-row protection at all. That is also why the index
/// must not later be "fixed" into `COALESCE(rule_index, -1)` — it would start
/// refusing the legacy rows that already have none.
///
/// ## 2. `deactivated_at` is a real SQL NULL, never `''`
///
/// `alarm.dart:490` binds `alarm.deactivated?.toIso8601String() ?? ''`. It has
/// never fired because `_removeActiveAlarm` always sets `deactivated` before
/// calling `_addToDb` — but an activation row is the first insert this codebase
/// has ever made with an empty deactivation, so it would have met it on day
/// one. 14-01's arm 6 measured the two shapes against a real server: a bound
/// SQL NULL passes `$9::timestamp`, and `''::timestamp` raises
/// `invalid input syntax for type timestamp` (SQLSTATE 22007). Here the
/// activation insert spells `NULL` as a literal, so there is no bind that could
/// ever carry an empty string.
///
/// ## 3. Open rows are read DIRECTLY, not through `getRecentAlarms` (P-9)
///
/// See [AlarmHistoryWriter.loadOpenRows].
///
/// ## 4. No database is a refusal, by name (P-12)
///
/// `alarm.dart:472` is `if (preferences.database == null) return;` — a silent
/// no-op on the persistence path, the silence-as-success Phase 13 spent a phase
/// removing. Every method here refuses instead, in `backend_state_man.dart:90`'s
/// shape: the member, the missing collaborator, one sentence saying what to
/// change. Construction is still permitted with none, because the backend may
/// boot before the plant database is reachable and a writer that refused to
/// *exist* would take the alarm engine down with it.
///
/// ## 5. The statements are Postgres-shaped, and that is deliberate
///
/// The `::timestamp` casts are inherited from `AlarmMan._addToDb` and are there
/// for the reason its comment gives: these columns are TEXT
/// (`storeDateTimeAsText`) and timestamps do not propagate correctly through
/// drift's own insert. Only the backend persists (D-6) and the backend's
/// database is TimescaleDB, so a SQLite dialect for these three statements
/// would be code no station runs.
library;

import 'package:drift/drift.dart' show Variable;
import 'package:logger/logger.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/alarm_stamp.dart';
import 'package:tfc_dart/core/database.dart' show Database;
import 'package:tfc_dart/core/database_drift.dart' show AppDatabase;

/// An `alarm_history` row that has no deactivation time.
///
/// The half of a row the restart reconciliation needs: enough to adopt the
/// activation back into the live set without inventing anything, and no more.
final class OpenAlarmRow {
  const OpenAlarmRow({
    required this.id,
    required this.alarmUid,
    required this.ruleIndex,
    required this.createdAt,
    required this.alarmLevel,
    required this.pendingAck,
    required this.tsSource,
    this.acknowledgedAt,
  });

  /// The row id. Also what travels to the panel as `AlarmActiveEntry.historyId`.
  final int id;

  final String alarmUid;

  /// Which rule of that alarm, or **null** for a row written before schema v7.
  ///
  /// A null here cannot be matched against any rule of any configuration, so
  /// the reconciliation closes it as [AlarmHistoryWriter.reasonInferredConfigChange]
  /// rather than guessing that it means rule 0.
  final int? ruleIndex;

  /// The instant the activation was recorded at — the plant's, if the plant
  /// had one. Adoption keeps it; this is the number a restart must not lose.
  final DateTime createdAt;

  final String alarmLevel;

  final bool pendingAck;

  /// `plant` or `backend_receipt`, or null on a row written before v7.
  ///
  /// Carried so that an adopted entry says on the wire what its stored row
  /// says. Re-deriving it as `plant` would relabel a backend guess as the
  /// plant's word in the one field a stop analysis exists to be audited on.
  final String? tsSource;

  /// When an operator acknowledged this activation, or null if nobody has.
  ///
  /// Carried so a restart does not put an acknowledged, still-standing alarm
  /// back on every banner. Before this column was written by anything, adoption
  /// had nothing to lose; now it does, and the engine restores the mark from
  /// here at the rule's first post-restart verdict. Without it, a backend
  /// restart would be indistinguishable from nobody having pressed the button.
  final DateTime? acknowledgedAt;

  @override
  String toString() => 'OpenAlarmRow(#$id $alarmUid rule $ruleIndex, '
      'opened ${createdAt.toIso8601String()}'
      '${acknowledgedAt == null ? '' : ', acknowledged '
          '${acknowledgedAt!.toIso8601String()}'})';
}

/// Writes and reconciles `alarm_history`. See the library doc.
final class AlarmHistoryWriter {
  /// Takes the database it will write through, which may be absent.
  ///
  /// Absent is stored, not rejected: see the library doc's point 4.
  AlarmHistoryWriter(this._database, {Logger? logger})
      : _logger = logger ?? Logger();

  final Database? _database;
  final Logger _logger;

  /// Whether this writer has a database behind it.
  ///
  /// For the composition root and for the engine's one start-up log line —
  /// **not** a flag anything branches its writes on. There is no `historyToDb`
  /// and there will not be one (D-6): a class that contains no insert cannot
  /// write one, and a boolean that decides whether an object persists is a
  /// boolean somebody sets wrong.
  bool get hasDatabase => _database != null;

  // ------------------------------------------------------------- the reasons

  /// The condition went false and the engine measured it.
  static const String reasonCleared = 'cleared';

  /// An operator acknowledged an already-cleared alarm (D-16 point 7).
  static const String reasonAcknowledged = 'acknowledged';

  /// The row was open at boot and its rule's first post-restart evaluation
  /// came out false. A reconstruction, not a measurement.
  static const String reasonInferredRestart = 'inferred_restart';

  /// The row was open at boot and its `(uid, rule_index)` is not in the
  /// current `alarm_man_config` at all, so no evaluation will ever come.
  static const String reasonInferredConfigChange = 'inferred_config_change';

  /// The condition went false on the FIRST evaluation after a D-3
  /// suspension, so this instant is when the SENSOR came back, not when the
  /// plant recovered. A bound, not a measurement.
  ///
  /// Distinct from [reasonInferredRestart] on purpose: both are
  /// reconstructions, but "the backend was down" and "the input was dead"
  /// send a maintainer to different cabinets. Named on the SVN rig's
  /// cooler-alarm evidence (2026-09-08), where an alarm held true on a stale
  /// input for the whole of its life — the clear it will eventually get is
  /// exactly this kind.
  static const String reasonInferredInputRecovery = 'inferred_input_recovery';

  /// Every reason a row may be closed with, spelled once.
  ///
  /// A stop analysis has to be able to tell a measured clear from a
  /// reconstructed one; two spellings of one reason would make that
  /// unqueryable, and nobody would notice until the numbers were already
  /// wrong (T-14-23).
  static const Set<String> reasons = <String>{
    reasonCleared,
    reasonAcknowledged,
    reasonInferredRestart,
    reasonInferredConfigChange,
    reasonInferredInputRecovery,
  };

  // ---------------------------------------------------------- the statements

  /// Opens a row. Ten bound values, one literal NULL, one `RETURNING id`.
  ///
  /// `deactivated_at` is the literal `NULL` rather than a bind, so the P-2
  /// empty string is not merely avoided but unrepresentable here.
  static const String insertStatement = r'''
    INSERT INTO alarm_history (
      alarm_uid, alarm_title, alarm_description, alarm_level,
      expression, active, pending_ack, created_at, deactivated_at,
      rule_index, ts_source
    ) VALUES (
      $1, $2, $3, $4,
      $5, $6, $7, $8::timestamp, NULL,
      $9, $10
    ) RETURNING id
  ''';

  /// Stamps an acknowledgement on one row, **without closing it**.
  ///
  /// Two columns are deliberately absent from the SET list, and their absence
  /// is the property (T-14-56):
  ///
  ///  * `deactivated_at` — an acknowledgement is not a clear. If the condition
  ///    is still true the stop is still running, and writing an end here would
  ///    report it as having finished the moment an operator pressed a button.
  ///    A stop that ran two hours becomes a stop that ran two minutes, in the
  ///    direction nobody audits. The engine closes the row separately, and
  ///    only in the case where the condition had already gone false.
  ///  * `active` — same argument, one column along. A row whose alarm is still
  ///    standing is still an active row.
  ///
  /// `acknowledged_at` had existed on this table since it was created and had
  /// never been written by anything (14-RESEARCH). This statement is the first
  /// write it has ever received.
  static const String acknowledgeStatement = r'''
    UPDATE alarm_history
       SET acknowledged_at = $1::timestamp
     WHERE id = $2
  ''';

  /// Records that an `acknowledgeRequired` rule cleared and nobody has seen it
  /// yet, **without closing the row**.
  ///
  /// The mirror of [acknowledgeStatement], and it omits the same two columns
  /// for a different reason: the condition HAS gone false, but the row is what
  /// keeps the unacknowledged fault discoverable, and 14-14's design is that it
  /// closes when the acknowledgement arrives, at the clearing instant.
  ///
  /// `pending_ack` was write-once-false until this statement existed
  /// (14-REVIEW CR-02). The INSERT bound `Variable.withBool(false)` and no
  /// UPDATE anywhere in this file mentioned the column, so the engine's
  /// `existing.pendingAck = true` lived in memory and nowhere else — and this
  /// backend restarts on every `alarm_man_config` or `key_mappings` save. A
  /// fault that fired and cleared between two glances at the screen was
  /// therefore closed as `inferred_restart` on the next restart and never
  /// appeared on any banner: the whole `acknowledgeRequired` feature did not
  /// survive one.
  static const String pendingAckStatement = r'''
    UPDATE alarm_history
       SET pending_ack = TRUE
     WHERE id = $1
  ''';

  /// Closes one row by id.
  static const String closeStatement = r'''
    UPDATE alarm_history
       SET active = FALSE,
           deactivated_at = $1::timestamp,
           deactivated_reason = $2
     WHERE id = $3
  ''';

  /// Every open row, whatever the current configuration says.
  ///
  /// See [loadOpenRows] for why this is not `getRecentAlarms`.
  static const String openRowsStatement = '''
    SELECT id, alarm_uid, rule_index, created_at, alarm_level,
           pending_ack, ts_source, acknowledged_at
      FROM alarm_history
     WHERE deactivated_at IS NULL
     ORDER BY id
  ''';

  // ------------------------------------------------------------------ writes

  /// Opens a row for an activation and returns its id.
  ///
  /// [stamp] is D-1's instant and D-2's provenance for the evaluation that
  /// flipped the rule; both go into the row, because "the plant said so" and
  /// "the backend guessed" are different facts.
  ///
  /// Throws whatever the server threw — notably SQLSTATE 23505 when a row for
  /// this `(alarm_uid, rule_index)` is already open. The caller decides what a
  /// failed write costs; this class does not decide it silently.
  Future<int> openActivation({
    required AlarmConfig alarm,
    required int ruleIndex,
    required AlarmRule rule,
    required String? expression,
    required AlarmStamp stamp,
  }) async {
    final db = _require('openActivation');
    final rows = await db.customWriteReturning(
      insertStatement,
      variables: <Variable>[
        Variable.withString(alarm.uid),
        Variable.withString(alarm.title),
        Variable.withString(alarm.description),
        Variable.withString(rule.level.name),
        Variable<String>(expression),
        Variable.withBool(true),
        Variable.withBool(false),
        Variable.withString(_sqlInstant(stamp.at)),
        // An int variable is a bigint on Postgres, which is what drift's own
        // dialect makes of `rule_index`. Getting that width wrong does not
        // present as a type error — it presents as SQLSTATE 08P01,
        // "insufficient data left in message" (14-01).
        Variable.withInt(ruleIndex),
        Variable.withString(stamp.source.wireName),
      ],
    );
    if (rows.isEmpty) {
      throw StateError(
          'AlarmHistoryWriter.openActivation: the INSERT for alarm '
          '"${alarm.uid}" rule $ruleIndex returned no id, so the activation '
          'cannot be closed later. The statement ends in RETURNING id; a '
          'database that answered nothing to it is not one this writer can '
          'keep a consistent history in.');
    }
    return rows.first.read<int>('id');
  }

  /// Records that an operator acknowledged the activation in row [id].
  ///
  /// [stamp] is the backend's own receipt instant (D-2's `backend_receipt`):
  /// an acknowledgement is a human act **here**, and there is no plant
  /// `sourceTime` for it. The row has one `ts_source` column and it belongs to
  /// the activation, so the provenance of this instant lives in the
  /// [AlarmStamp] the caller resolved and not in a second column.
  ///
  /// **This does not close the row** — see [acknowledgeStatement] for why that
  /// omission is the whole point. The caller closes it separately, and only
  /// when the condition had already cleared.
  ///
  /// A row that is not there any more is logged and not raised, on
  /// [closeActivation]'s argument: losing the alarm engine because somebody
  /// pruned history under a running backend is the wrong trade (T-14-24).
  Future<void> acknowledgeActivation({
    required int id,
    required AlarmStamp stamp,
  }) async {
    final db = _require('acknowledgeActivation');
    final affected = await db.customUpdate(
      acknowledgeStatement,
      variables: <Variable>[
        Variable.withString(_sqlInstant(stamp.at)),
        Variable.withInt(id),
      ],
      updates: {db.alarmHistory},
    );
    if (affected == 0) {
      _logger.w('AlarmHistoryWriter.acknowledgeActivation: alarm_history row '
          '#$id was not there to stamp. The acknowledgement still took effect '
          'on the banner — the engine\'s set moved first and deliberately — '
          'but nothing durable records that anybody saw this alarm.');
    }
  }

  /// Records on row [id] that its alarm is waiting to be acknowledged.
  ///
  /// See [pendingAckStatement]. A row that is not there any more is logged and
  /// not raised, on [closeActivation]'s argument (T-14-24) — but the sentence
  /// says what was lost, because what was lost is the durable half of "a fault
  /// occurred and nobody has seen it".
  Future<void> markPendingAck({required int id}) async {
    final db = _require('markPendingAck');
    final affected = await db.customUpdate(
      pendingAckStatement,
      variables: <Variable>[Variable.withInt(id)],
      updates: {db.alarmHistory},
    );
    if (affected == 0) {
      _logger.w('AlarmHistoryWriter.markPendingAck: alarm_history row #$id was '
          'not there to badge. The alarm is still held on this process\'s '
          'banner, but nothing durable records that a fault fired and cleared '
          'unseen — so a restart before somebody acknowledges it will lose the '
          'fault entirely.');
    }
  }

  /// Closes the row [id] at [stamp], saying how it was closed.
  ///
  /// [reason] must be one of [reasons]; anything else is refused rather than
  /// written, because an unqueryable reason is worse than a missing one.
  ///
  /// A row that is not there any more is logged and not raised: the operator
  /// may legitimately have deleted history under a running backend, and losing
  /// the alarm engine over it would be the wrong trade (T-14-24).
  Future<void> closeActivation({
    required int id,
    required AlarmStamp stamp,
    required String reason,
  }) async {
    final db = _require('closeActivation');
    if (!reasons.contains(reason)) {
      throw ArgumentError.value(
          reason,
          'reason',
          'AlarmHistoryWriter.closeActivation was given a deactivation reason '
              'that is not one of ${reasons.join(', ')}. The four are spelled '
              'once on this class so a stop analysis can tell a measured clear '
              'from a reconstructed one');
    }
    final affected = await db.customUpdate(
      closeStatement,
      variables: <Variable>[
        Variable.withString(_sqlInstant(stamp.at)),
        Variable.withString(reason),
        Variable.withInt(id),
      ],
      updates: {db.alarmHistory},
    );
    if (affected == 0) {
      _logger.w('AlarmHistoryWriter.closeActivation: alarm_history row #$id '
          'was not there to close as "$reason". Nothing was written. The row '
          'may have been deleted under a running backend; the engine keeps '
          'evaluating either way.');
    }
  }

  /// Every row with no deactivation time.
  ///
  /// **Deliberately not `getRecentAlarms` (P-9).** That method drops every row
  /// whose `alarmUid` is not in the current configuration
  /// (`alarm.dart:525-533`) — and that set is *precisely* the one the restart
  /// reconciliation exists to close. Reading open rows through it would leave a
  /// deleted alarm's row open forever, invisible to the only code that could
  /// ever close it, while the stop it represents kept growing. It also invents
  /// `acknowledgeRequired: false` and rebuilds an `Expression` per row, neither
  /// of which the reconciliation wants.
  Future<List<OpenAlarmRow>> loadOpenRows() async {
    final db = _require('loadOpenRows');
    final rows = await db.customSelect(openRowsStatement).get();
    return <OpenAlarmRow>[
      for (final row in rows)
        OpenAlarmRow(
          id: row.read<int>('id'),
          alarmUid: row.read<String>('alarm_uid'),
          ruleIndex: row.read<int?>('rule_index'),
          createdAt: parseStoredInstant(row.read<String>('created_at')),
          alarmLevel: row.read<String>('alarm_level'),
          pendingAck: row.read<bool>('pending_ack'),
          tsSource: row.read<String?>('ts_source'),
          acknowledgedAt: _optionalInstant(row.read<String?>('acknowledged_at')),
        ),
    ];
  }

  // ------------------------------------------------------------------ plumbing

  /// The refusal shape, from `backend_state_man.dart:90`.
  ///
  /// Three things, always, in this order: the member as it is spelled here, the
  /// collaborator that is missing, and one sentence saying what to change.
  /// Deliberately not "not implemented" and never a `return;` — the member IS
  /// implemented; what is absent is the thing behind it, and that is the only
  /// fact an operator can act on.
  AppDatabase _require(String member) {
    final database = _database;
    if (database == null) {
      throw UnsupportedError(
          'AlarmHistoryWriter.$member is not available: this writer was '
          'composed without a Database, so there is nowhere for the '
          'alarm_history row to go and an alarm would be evaluated into '
          'silence. Hand the backend\'s Database to the alarm engine in '
          'bin/main.dart, or compose the engine with no history writer at all '
          '— which it logs once at start.');
    }
    return database.db;
  }

  /// A nullable stored instant, read the way [parseStoredInstant] reads one.
  static DateTime? _optionalInstant(String? raw) =>
      raw == null ? null : parseStoredInstant(raw);

  /// An instant as the `::timestamp` casts want it.
  ///
  /// UTC always. The column is TEXT and the cast strips whatever zone it is
  /// given, so a local-time instant would be stored as a wall-clock reading
  /// with its offset silently discarded — the same row meaning two different
  /// instants on two stations.
  static String _sqlInstant(DateTime at) => at.toUtc().toIso8601String();
}

/// A stored `alarm_history` instant, read the way drift reads one.
///
/// These columns are TEXT (`storeDateTimeAsText`) and hold two shapes: drift's
/// own inserts store an ISO-8601 string ending in `Z`, while anything written
/// through a `::timestamp` cast comes back out as `2026-09-06 12:00:00` with no
/// zone at all. Drift's `_readDateTime` treats the zoneless case as UTC; so
/// does this, so the reconciliation and `getRecentAlarms` cannot disagree about
/// what a row means by the machine's UTC offset — which on an Icelandic station
/// is zero and on a developer's laptop is not.
DateTime parseStoredInstant(String raw) {
  final value = raw.trim();
  if (RegExp(r'[+-]\d{2}:?\d{2}$').hasMatch(value)) {
    return DateTime.parse(value).toUtc();
  }
  if (value.endsWith('Z')) return DateTime.parse(value).toUtc();
  return DateTime.parse('${value}Z').toUtc();
}

/// The report subsystem's write guard, built on the same argument
/// `guarded_history_views.dart` makes for saved views.
///
/// [ReportStore] writes the `report_config` and `shift_config` rows of
/// `flutter_preferences` with **raw SQL**, deliberately: the MCP server —
/// in-process and standalone — writes the same two rows and has no
/// `Preferences` to go through. That decision predates access control, and it
/// means `GuardedPreferences` can never see these writes: they pass no
/// `PreferencesApi.set*`. Same shape as the history view's five Drift writes,
/// same fix — a store that holds every write, checks it, and records it.
///
/// ## Why the group is `configure`
///
/// A report definition is station configuration somebody authored, exactly
/// like an alarm definition or a saved history view. It is also what the
/// `configure`-gated report editor saves, so anything higher would ship a
/// role that can open the editor and cannot save from it — the defect
/// `kPrefAccessRules` names as route parity, and the reason `report_config`
/// and `shift_config` are classified `configure` there too. The two must
/// agree: this constant gates the write, that rule classifies the key, and
/// `guarded_report_store_test.dart` asserts they say the same word.
///
/// ## Why reads are not here
///
/// Generating and reading a report is operate-level work — an operator
/// looking at last night's shift is doing their job, the same ruling spec §11
/// records for trends and history. `/reports` is deliberately absent from
/// `kRaisedRoutes` and must stay absent; `access_routes_test.dart` asserts it.
/// What a report may *reach* is bounded at the query instead, by
/// [kSqlSectionForbiddenTables]: an SQL section cannot name the access tables,
/// so authoring a report cannot become a way to publish credentials to a page
/// anyone can open.
library;

import 'package:logger/logger.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/tfc_dart.dart'
    show AlarmMetaLite, ReportManConfig, ReportStore, ShiftManConfig;

/// The `who` recorded when nobody is signed in.
const String _anonymousWho = 'anonymous';

/// The permission both report-subsystem writes require.
///
/// Changing this changes who may author reports and shift patterns. If you
/// change it, change the two `kPrefAccessRules` entries with it — a guard and
/// a classification that disagree is a role that can do half of one action.
const AccessGroup kReportConfigWriteGroup = AccessGroup.configure;

/// Every write the report subsystem makes, behind one object.
///
/// The two members carry the same names and signatures as [ReportStore]'s, so
/// a call site changes only its receiver. Reads stay on the plain store,
/// ungated and unaudited.
class GuardedReportStore {
  /// [session] is a **callback, not a value**, for the reason
  /// `GuardedStateMan` gives at its own constructor: the store outlives any
  /// one session, and a captured [AccessSession] would keep granting whatever
  /// the operator held when it was built, after the inactivity monitor had
  /// already dropped them back to anonymous.
  ///
  /// [onDenied] fires **before** the [AccessDenied] is thrown, so the shared
  /// prompt appears even at a call site that swallows the exception.
  GuardedReportStore({
    required ReportStore store,
    required AccessSession Function() session,
    required AuditSink audit,
    required String station,
    void Function(AccessDenied denial)? onDenied,
    Logger? logger,
  })  : _store = store,
        _session = session,
        _audit = audit,
        _station = station,
        _onDenied = onDenied,
        _logger = logger ?? Logger();

  final ReportStore _store;
  final AccessSession Function() _session;
  final AuditSink _audit;
  final String _station;
  final void Function(AccessDenied denial)? _onDenied;
  final Logger _logger;

  /// Report definitions are station configuration, so the rows ride the
  /// existing `pref` surface rather than inventing a fourth write surface for
  /// one page — the same choice `HistoryViewStore` made, and for the same
  /// reason: a year of rows should not read two ways.
  static final String _surface = AccessSurface.pref.wireName;

  /// The reads, forwarded untouched. Present so a call site can hold this
  /// object alone rather than both, and so nothing is tempted to keep an
  /// unguarded [ReportStore] beside it.
  Future<ReportManConfig> loadReports() => _store.loadReports();
  Future<ShiftManConfig> loadShifts() => _store.loadShifts();
  Future<Map<String, AlarmMetaLite>> loadAlarmMeta() => _store.loadAlarmMeta();

  /// Saves every report definition. Requires [kReportConfigWriteGroup].
  ///
  /// The row's `itemKey` is the preference key itself, because that is what
  /// the write lands on and what `kPrefAccessRules` classifies. The count goes
  /// in `newValue`: the definitions are a JSON blob far too large for an audit
  /// column, and "8 reports" is what a reader of the trail can actually use.
  Future<void> saveReports(ReportManConfig config) => _guard(
        itemKey: ReportManConfig.configKey,
        reason: 'saveReports',
        newValue: '${config.reports.length} reports',
        write: () => _store.saveReports(config),
      );

  /// Saves the shift calendar. Requires [kReportConfigWriteGroup].
  Future<void> saveShifts(ShiftManConfig config) => _guard(
        itemKey: ShiftManConfig.configKey,
        reason: 'saveShifts',
        newValue: '${config.shifts.length} shifts',
        write: () => _store.saveShifts(config),
      );

  /// Check, record, then write — the ordering `GuardedStateMan` established
  /// and `HistoryViewStore` reuses.
  ///
  /// The row comes **before** the write on both paths. On the permitted path a
  /// write that then fails at the database leaves a row for an action that was
  /// authorized, which is the lesser loss; on the deny path the row is the
  /// only evidence the guard fired and must exist even though the exception is
  /// about to be thrown.
  Future<void> _guard({
    required String itemKey,
    required String reason,
    required String newValue,
    required Future<void> Function() write,
  }) async {
    final actionId = newActionId();
    final session = _session();

    if (!session.can(kReportConfigWriteGroup)) {
      await _record(_row(
        session: session,
        itemKey: itemKey,
        newValue: newValue,
        allowed: false,
        reason: reason,
        actionId: actionId,
      ));

      final denial = AccessDenied(itemKey, kReportConfigWriteGroup);
      try {
        _onDenied?.call(denial);
      } on Object catch (error, stack) {
        // A listener's bug must not change what the caller sees.
        _logger.e('onDenied listener threw for "$itemKey"',
            error: error, stackTrace: stack);
      }
      throw denial;
    }

    await _record(_row(
      session: session,
      itemKey: itemKey,
      newValue: newValue,
      allowed: true,
      reason: reason,
      actionId: actionId,
    ));
    return write();
  }

  AuditRecord _row({
    required AccessSession session,
    required String itemKey,
    required String newValue,
    required bool allowed,
    required String reason,
    required String actionId,
  }) =>
      AuditRecord(
        at: DateTime.now(),
        who: session.user?.username ?? _anonymousWho,
        station: _station,
        roleName: session.roleName,
        surface: _surface,
        itemKey: itemKey,
        newValue: newValue,
        groupRequired: kReportConfigWriteGroup.name,
        allowed: allowed,
        reason: reason,
        actionId: actionId,
      );

  /// Append [row], and never let the sink's failure become the caller's — a
  /// report that will not save because the trail is down helps nobody.
  Future<void> _record(AuditRecord row) async {
    try {
      await _audit.record(row);
    } on Object catch (error, stack) {
      _logger.e(
        'AUDIT ROW LOST: action ${row.actionId}, ${row.who} on '
        '${row.surface}:${row.itemKey}, allowed: ${row.allowed}',
        error: error,
        stackTrace: stack,
      );
    }
  }
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_dart/core/mcp_database.dart';
import 'package:tfc_dart/tfc_dart.dart';

import '../core/guarded_report_store.dart';
import 'access.dart'; // stationNameProvider
import 'access_policy.dart'; // sessionInForce, RefAuditSink, reportAccessDenial
import 'server_database.dart';
import 'state_man.dart';

/// Cached instances, `identical()`-keyed on the database like
/// [driftTechDocIndexProvider]: a databaseProvider rebuild that yields the
/// same connection must not hand every downstream FutureProvider a fresh
/// store and re-trigger it.
ReportStore? _cachedStore;
McpDatabase? _storeDb;

/// The report/shift config store, or null while the database is down.
///
/// Report and shift configuration deliberately bypasses `Preferences`: the
/// same rows are written by the MCP server (in-process and standalone), and
/// the store over the shared table is the one path all writers agree on.
final reportStoreProvider = Provider<ReportStore?>((ref) {
  final db = ref.watch(mcpDatabaseProvider);
  if (db == null) {
    _cachedStore = null;
    _storeDb = null;
    return null;
  }
  if (identical(db, _storeDb) && _cachedStore != null) return _cachedStore;
  _storeDb = db;
  _cachedStore = ReportStore(db);
  return _cachedStore;
});

ReportEngine? _cachedEngine;
McpDatabase? _engineDb;

/// The report engine, or null while the database is down.
final reportEngineProvider = Provider<ReportEngine?>((ref) {
  final db = ref.watch(mcpDatabaseProvider);
  if (db == null) {
    _cachedEngine = null;
    _engineDb = null;
    return null;
  }
  if (identical(db, _engineDb) && _cachedEngine != null) return _cachedEngine;
  _engineDb = db;
  // ref.read at resolve time, not a captured StateMan: like alarmManProvider,
  // this avoids cascading engine rebuilds on StateMan reconnects — the
  // resolver re-reads through the provider on every call instead.
  _cachedEngine = ReportEngine(
    db,
    resolveKey: (key) =>
        ref.read(stateManProvider).valueOrNull?.resolveKey(key) ?? key,
  );
  return _cachedEngine;
});

/// Every report definition in the system.
final reportManConfigProvider = FutureProvider<ReportManConfig>((ref) async {
  final store = ref.watch(reportStoreProvider);
  if (store == null) return ReportManConfig();
  return store.loadReports();
});

/// The plant's shift pattern, resolved into a calendar.
final shiftCalendarProvider = FutureProvider<ShiftCalendar>((ref) async {
  final store = ref.watch(reportStoreProvider);
  if (store == null) return ShiftCalendar(ShiftManConfig());
  return ShiftCalendar(await store.loadShifts());
});

/// Every write the report subsystem makes, checked and recorded.
///
/// The plain [ReportStore] above stays for reads — generating a report is
/// operate-level work — but nothing in the app may save through it. Its two
/// writes land on `flutter_preferences` by raw SQL, which `GuardedPreferences`
/// cannot see, so this is the seam that gates and audits them instead;
/// `guarded_report_store.dart` says why the group is `configure`.
///
/// A provider rather than a field on the editor state, for the reason
/// `historyViewStoreProvider` gives: `sessionInForce`, [RefAuditSink] and
/// `reportAccessDenial` all need a provider `Ref`, and a `WidgetRef` is not
/// one.
///
/// Null when the database is not up, exactly like [reportStoreProvider].
final guardedReportStoreProvider = Provider<GuardedReportStore?>((ref) {
  final store = ref.watch(reportStoreProvider);
  if (store == null) return null;
  return GuardedReportStore(
    store: store,
    // Read at write time, never captured: the store outlives any one session.
    session: () => sessionInForce(ref),
    audit: RefAuditSink(ref),
    station: ref.watch(stationNameProvider),
    onDenied: (denial) => reportAccessDenial(ref, denial),
  );
});

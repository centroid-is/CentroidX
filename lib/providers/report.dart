import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_dart/core/mcp_database.dart';
import 'package:tfc_dart/tfc_dart.dart';

import 'package:tfc_dart/core/config/shared_row_preferences.dart';

import '../core/guarded_report_store.dart';
import 'access.dart'; // stationNameProvider
import 'access_policy.dart'; // sessionInForce, RefAuditSink, reportAccessDenial
import 'gateway.dart';
import 'preferences.dart';
import 'server_database.dart';
import 'state_man.dart';

/// Cached instances, `identical()`-keyed on the database like
/// [driftTechDocIndexProvider]: a databaseProvider rebuild that yields the
/// same connection must not hand every downstream FutureProvider a fresh
/// store and re-trigger it.
ReportStore? _cachedStore;
McpDatabase? _storeDb;

/// The report/shift config store, or null while the database is down **and
/// there is no relay to ask instead**.
///
/// ## Direct mode: the table, not `Preferences`
///
/// Report and shift configuration deliberately bypasses `Preferences` on a
/// station: the same rows are written by the MCP server (in-process and
/// standalone), and the store over the shared table is the one path all
/// writers agree on.
///
/// ## Gateway mode: the preference door, because it lands on the same rows
///
/// That argument is about a machine where the table exists. A relayed panel
/// has no database at all — `mcpDatabaseProvider` follows `databaseProvider`
/// into null — so this provider answered null, and with it
/// [guardedReportStoreProvider], the editor and the engine. The editor said
/// *"Database is not connected"*, which was true about the panel and false
/// about the plant: the backend was holding the reports the whole time.
///
/// The three documents — `report_config`, `shift_config`, `alarm_man_config`
/// — are shared `config_item` preference rows, and the relay already carries
/// those: `RelayedPreferences` sends a shared key over the wire, where the
/// gateway grades it with `KeyPolicy.canWritePreference`, audits it, and
/// compare-and-swaps it onto the very rows the MCP server writes. So the
/// gateway branch reaches the one path all writers agree on **through the
/// door that is already open**, rather than through a report family that
/// would be a second way to write the same three rows.
///
/// Not cached on `identical(db, …)` in that branch: there is no database to
/// key on. The store is a pair of closures over a provider `Ref`, so
/// rebuilding it costs nothing and holding a stale one across a transport
/// change would cost a panel reading a store whose client is gone.
final reportStoreProvider = Provider<ReportStore?>((ref) {
  final gateway = ref.watch(gatewayConfigProvider).valueOrNull;
  if (gateway != null && gateway.isGateway) {
    _cachedStore = null;
    _storeDb = null;
    return ReportStore(
      null,
      read: (key) async {
        final prefs = await ref.read(preferencesProvider.future);
        return prefs.getString(key);
      },
      write: (key, json) async {
        // `preferencesProvider` is non-nullable and answers a
        // `RelayedPreferences` in gateway mode, so the save lands on the
        // backend's shared rows — graded, audited and compare-and-swapped
        // there. A save that went nowhere while looking successful is the
        // failure this branch exists to stop, and the wire is what makes it
        // impossible rather than a check here.
        final prefs = await ref.read(preferencesProvider.future);
        await prefs.setString(key, json);
      },
    );
  }

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
    // The save lands on the shared rows under the guard's own action id —
    // compare-and-swapped, logged, announced to the other stations — rather
    // than through ReportStore's unguarded seam, which reaches them only at
    // their next sweep and the change log never. Preferences that are not
    // the shared rows (a test that overrode the store; a station whose
    // preferences fell back to device-local) take nothing here, and the
    // guard writes through the store, as it did before the rows existed —
    // a device-local `setString` would have put the plant's reports on one
    // panel's disk.
    //
    // Read, never awaited: the provider is built at boot and holds its value
    // for the life of the process, so a save finds it ready — and one that
    // does not (a test container without it) must not *build* it here, which
    // would open a database from inside a report save.
    rowWriter: (key, json, {required actionId}) async {
      if (!ref.exists(preferencesProvider)) return false;
      final prefs = ref.read(preferencesProvider).valueOrNull;
      if (prefs is! SharedRowPreferences) return false;
      await prefs.setStringUnderAction(key, json, actionId: actionId);
      return true;
    },
  );
});

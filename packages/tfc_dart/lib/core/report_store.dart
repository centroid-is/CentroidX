import 'dart:convert';

import 'package:drift/drift.dart';

import 'mcp_database.dart';
import 'report.dart';
import 'shift.dart';
import 'config/config_item.dart';
import 'config/config_item_table.dart';
import 'config/page_rows.dart' show readSharedPreferencePayload;
import 'config/preference_payload.dart';

/// The slice of an alarm definition a report needs. Parsed straight out of
/// the `alarm_man_config` preference JSON rather than through [AlarmConfig],
/// so this file stays importable by the FFI-free MCP server.
class AlarmMetaLite {
  final String uid;
  final String title;
  final bool countsAsStop;

  const AlarmMetaLite({
    required this.uid,
    required this.title,
    required this.countsAsStop,
  });
}

/// Loads and saves report and shift configuration through the shared
/// `flutter_preferences` table.
///
/// Deliberately raw SQL rather than the app's `Preferences` wrapper: the same
/// rows must be readable and writable from the Flutter app, the in-process
/// MCP server, and the standalone MCP binary, and only the table itself is
/// common to all three. Report and shift config therefore always goes through
/// this store, never through `Preferences`, so no local mirror can go stale.
class ReportStore {
  /// [write], when given, is where [saveReports] and [saveShifts] land: the
  /// app hands in the shared preference store's writer so a save is checked,
  /// recorded, compare-and-swapped and announced. Without it a save goes
  /// straight into [_db] — see [_upsertRow] for who that is for.
  ///
  /// [isPostgres] is kept for the callers that name it; the reads and the
  /// seam are drift builders now and need no placeholder dialect.
  ReportStore(this._db,
      {this.isPostgres = true,
      Future<void> Function(String key, String json)? write})
      : _write = write;

  final Future<void> Function(String key, String json)? _write;

  final McpDatabase _db;

  /// False only under the SQLite test harness.
  final bool isPostgres;


  Future<ReportManConfig> loadReports() async {
    final json = await _loadJson(ReportManConfig.configKey);
    if (json == null) return ReportManConfig();
    return ReportManConfig.fromJson(json);
  }

  Future<void> saveReports(ReportManConfig config) =>
      _saveJson(ReportManConfig.configKey, config.toJson());

  Future<ShiftManConfig> loadShifts() async {
    final json = await _loadJson(ShiftManConfig.configKey);
    if (json == null) return ShiftManConfig();
    return ShiftManConfig.fromJson(json);
  }

  Future<void> saveShifts(ShiftManConfig config) =>
      _saveJson(ShiftManConfig.configKey, config.toJson());

  /// The per-alarm facts the downtime and alarm sections read, keyed by uid.
  /// Missing or unparsable config yields an empty map — the report then
  /// falls back to treating every alarm as a stop, matching
  /// `AlarmConfig.countsAsStop`'s default.
  Future<Map<String, AlarmMetaLite>> loadAlarmMeta() async {
    final json = await _loadJson('alarm_man_config');
    final alarms = json?['alarms'];
    if (alarms is! List) return const {};
    final out = <String, AlarmMetaLite>{};
    for (final entry in alarms) {
      if (entry is! Map<String, dynamic>) continue;
      final uid = entry['uid'];
      if (uid is! String) continue;
      out[uid] = AlarmMetaLite(
        uid: uid,
        title: entry['title'] is String ? entry['title'] as String : uid,
        countsAsStop: entry['countsAsStop'] is bool
            ? entry['countsAsStop'] as bool
            : true,
      );
    }
    return out;
  }

  /// One shared preference document — `report_config`, `shift_config`,
  /// `alarm_man_config` — off its `config_item` row.
  ///
  /// The rows, never `flutter_preferences`: the branch that moved the plant's
  /// configuration onto rows copies the old table across once and then drops
  /// it, and `alarm_man_config` in particular is edited on the rows from then
  /// on. A report engine reading the old table would have used the alarm
  /// titles and stop flags as they were on cutover day, forever, and the
  /// downtime pareto would have named raw uids for every alarm added since.
  Future<Map<String, dynamic>?> _loadJson(String key) =>
      readSharedPreferencePayload(_db, key);

  Future<void> _saveJson(String key, Map<String, dynamic> json) async {
    final write = _write;
    if (write != null) return write(key, jsonEncode(json));
    await _upsertRow(key, jsonEncode(json));
  }

  /// The unguarded seam: one `config_item` preference row, written straight
  /// into [_db] with no compare-and-swap, no change row and no notification.
  ///
  /// What a test, a tool or a seed uses to put a configuration in front of a
  /// reader. **Not the app's path**: a station writes reports through
  /// `GuardedReportStore`, whose row writer goes through the shared
  /// preference store — checked, recorded, compare-and-swapped and announced
  /// to the other stations. A row written here reaches them only at their
  /// next sweep, and reaches the change log never.
  Future<void> _upsertRow(String key, String value) async {
    final table = $ConfigItemTableTable(_db);
    final item = ConfigItem.of(
      kind: ConfigKind.preference,
      id: key,
      value: preferencePayload(kPrefStringType, value),
    );
    Expression<bool> identity($ConfigItemTableTable t) =>
        t.kind.equals(item.kind.wireName) &
        t.id.equals(key) &
        t.scope.equals(ConfigScope.shared.wireName);
    final existing =
        await (_db.select(table)..where(identity)).getSingleOrNull();
    final companion = ConfigItemTableCompanion.insert(
      kind: item.kind.wireName,
      id: key,
      scope: ConfigScope.shared.wireName,
      payload: item.payload,
      rev: Value((existing?.rev ?? 0) + 1),
      updatedAt: DateTime.now(),
      updatedBy: 'report_store',
    );
    if (existing == null) {
      await _db.into(table).insert(companion);
    } else {
      await (_db.update(table)..where(identity)).write(companion);
    }
  }
}


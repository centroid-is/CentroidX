import 'dart:convert';

import 'package:drift/drift.dart';

import 'mcp_database.dart';
import 'report.dart';
import 'shift.dart';
import 'sql_dialect.dart';

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
  ReportStore(this._db, {this.isPostgres = true});

  final McpDatabase _db;

  /// False only under the SQLite test harness.
  final bool isPostgres;

  String _sql(String sql) => adaptSqlPlaceholders(sql, isPostgres: isPostgres);

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

  Future<Map<String, dynamic>?> _loadJson(String key) async {
    final rows = await _db.customSelect(
      _sql('SELECT value FROM flutter_preferences WHERE key = ?'),
      variables: [Variable.withString(key)],
    ).get();
    if (rows.isEmpty) return null;
    final value = rows.first.readNullable<String>('value');
    if (value == null || value.isEmpty) return null;
    try {
      final decoded = jsonDecode(value);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  Future<void> _saveJson(String key, Map<String, dynamic> json) async {
    await _db.customStatement(
      _sql('INSERT INTO flutter_preferences (key, value, type) '
          "VALUES (?, ?, 'String') "
          'ON CONFLICT (key) DO UPDATE SET value = excluded.value'),
      [key, jsonEncode(json)],
    );
  }
}

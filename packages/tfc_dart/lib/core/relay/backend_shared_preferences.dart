/// The backend's read path onto the shared preference rows.
///
/// ## Why this exists
///
/// `Preferences` used to load the plant's shared settings out of
/// `flutter_preferences` at construction, and the backend's one call —
/// `Preferences.create(db: db)` in `bin/main.dart` — got them for free. Main's
/// relational-configuration work (#465) retired that table: shared settings are
/// `config_item` rows now, served to the app by `SharedRowPreferences` over a
/// `ConfigStore`. `Preferences.create` still exists and still takes a database,
/// but it no longer reads anything from it.
///
/// So after the merge the backend held a store that answered null to every
/// shared key. Two things read it, and both matter:
///
///  * [AlarmEngine] reads `alarm_man_config`. Null there is "this plant has no
///    alarms", so the backend would have evaluated none — silently, on a plant
///    that has them. That is the safety-relevant half.
///  * The relay's `PreferencesSource` serves gateway panels. Null there is a
///    panel that reads its own settings as absent.
///
/// This class restores the reads by going at the rows directly, through
/// [readSharedPreferenceValue] — the same helper `bin/main.dart` already uses
/// for the migration markers, and the same `preference_payload.dart` codec both
/// preference stores write with, so the tag that separates `7` from `'7'`
/// survives.
///
/// ## Why it is not a `ConfigStore`
///
/// `SharedRowPreferences` is the app's answer and needs a `GuardedConfigStore`,
/// which needs a policy, a session callback, an audit sink and a station name.
/// The backend has none of those and must not grow them: every relayed write is
/// already graded and audited server-side by the policy decorator, and a second
/// guard here would put two checks and two `audit_entry` rows on one write. The
/// backend also has no device-local mirror for a `ConfigStore` to open against.
///
/// ## Reads only, and writes refused by name
///
/// Nothing here writes a shared row. The backend is not an author of the
/// plant's configuration — that is the same rule `bin/main.dart` states where
/// it declines to seed an empty `alarm_man_config`, and the same rule
/// `AlarmMan` states where it has no write path at all: a process with one boot
/// read and no reconcile cannot tell "empty" from "not yet migrated", so it
/// must not conclude "empty, therefore write".
///
/// A write that arrives anyway throws [UnsupportedError] rather than returning
/// quietly, so a panel writing a preference over the pipe is told, rather than
/// being told it worked. **That is a live gap, not a resolved one**: gateway
/// panels could write shared preferences through this route before the merge,
/// and cannot now. Closing it means a backend-side writer that shares the
/// relay's `action_id` with its audit row — a design, not a merge fix.
///
/// Secrets are untouched: they never lived in the shared table, and the
/// inherited keychain path handles them exactly as before.
library;

import 'package:drift/drift.dart' show GeneratedDatabase;

import '../database.dart';
import '../config/key_mapping_rows.dart'
    show readSharedPreferenceIds, readSharedPreferenceValue;
import '../preferences.dart';
import '../secure_storage/secure_storage.dart';

/// Reads the shared `config_item` preference rows; refuses to write them.
class BackendSharedPreferences extends Preferences {
  BackendSharedPreferences._({
    required Database database,
    required MySecureStorage secureStorage,
  })  : _rows = database.db,
        super(database: database, secureStorage: secureStorage);

  /// Builds the backend's store over [database].
  ///
  /// Async only to match `Preferences.create`, which every call site awaits —
  /// there is nothing to load, because every read goes to the row at the
  /// moment it is asked for. That is deliberate: the backend restarts to apply
  /// a configuration change (see `bin/main.dart`'s watcher), so a cache here
  /// would only add a second thing that can be stale.
  static Future<BackendSharedPreferences> create({
    required Database database,
  }) async =>
      BackendSharedPreferences._(
        database: database,
        secureStorage: SecureStorage.getInstance(),
      );

  final GeneratedDatabase _rows;

  Future<Object?> _shared(String key) => readSharedPreferenceValue(_rows, key);

  @override
  Future<String?> getString(String key, {bool secret = false}) async {
    if (secret) return super.getString(key, secret: true);
    final value = await _shared(key);
    return value is String ? value : value?.toString();
  }

  @override
  Future<bool?> getBool(String key, {bool secret = false}) async {
    if (secret) return super.getBool(key, secret: true);
    final value = await _shared(key);
    if (value is bool) return value;
    if (value is String) return value == 'true';
    return null;
  }

  @override
  Future<int?> getInt(String key, {bool secret = false}) async {
    if (secret) return super.getInt(key, secret: true);
    final value = await _shared(key);
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    return null;
  }

  @override
  Future<double?> getDouble(String key, {bool secret = false}) async {
    if (secret) return super.getDouble(key, secret: true);
    final value = await _shared(key);
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  @override
  Future<List<String>?> getStringList(String key, {bool secret = false}) async {
    if (secret) return super.getStringList(key, secret: true);
    final value = await _shared(key);
    if (value is List) return [for (final e in value) e.toString()];
    if (value is String) return value.split(',');
    return null;
  }

  @override
  Future<bool> containsKey(String key, {bool secret = false}) async {
    if (secret) return super.containsKey(key, secret: true);
    return await _shared(key) != null;
  }

  /// Every shared preference id, for a caller enumerating them.
  @override
  Future<Set<String>> getKeys({Set<String>? allowList}) async {
    final ids = await readSharedPreferenceIds(_rows);
    if (allowList == null) return ids;
    return ids.where(allowList.contains).toSet();
  }

  @override
  Future<Map<String, Object?>> getAll({Set<String>? allowList}) async {
    final keys = await getKeys(allowList: allowList);
    return {for (final key in keys) key: await _shared(key)};
  }

  Never _refuseWrite(String member) => throw UnsupportedError(
      'BackendSharedPreferences.$member: the backend does not write the '
      "plant's shared configuration. Every shared preference is a `config_item` "
      'row authored by a station, through the checked path that grades the '
      'write and records one audit row for it. A write from here would have '
      'none of that behind it, and a process with one boot read and no '
      'reconcile cannot tell an empty plant from an unmigrated one. See this '
      "library's header for the gap this leaves and what closing it needs.");

  @override
  Future<void> setString(String key, String value,
      {bool secret = false, bool saveToDb = true}) async {
    if (secret) return super.setString(key, value, secret: true);
    _refuseWrite('setString');
  }

  @override
  Future<void> setBool(String key, bool value,
      {bool secret = false, bool saveToDb = true}) async {
    if (secret) return super.setBool(key, value, secret: true);
    _refuseWrite('setBool');
  }

  @override
  Future<void> setInt(String key, int value,
      {bool secret = false, bool saveToDb = true}) async {
    if (secret) return super.setInt(key, value, secret: true);
    _refuseWrite('setInt');
  }

  @override
  Future<void> setDouble(String key, double value,
      {bool secret = false, bool saveToDb = true}) async {
    if (secret) return super.setDouble(key, value, secret: true);
    _refuseWrite('setDouble');
  }

  @override
  Future<void> setStringList(String key, List<String> value,
      {bool secret = false, bool saveToDb = true}) async {
    if (secret) return super.setStringList(key, value, secret: true);
    _refuseWrite('setStringList');
  }
}

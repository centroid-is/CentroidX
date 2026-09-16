import 'dart:io' show Directory;

import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tfc_dart/core/config/config_item.dart' show ConfigScope;
import 'package:tfc_dart/core/database_drift.dart' show AppDatabase;
import 'package:tfc_dart/core/preferences_api.dart';

/// A browser has no SQLite, so it has no mirror of the plant's `config_item`
/// rows and `configStoreProvider` cannot be built here. `stateManProvider`
/// and `pageManagerProvider` read this and go without one.
const bool kHasDeviceLocalMirror = false;

/// What [openDeviceLocalStore] hands back: the preferences view of the store,
/// and the database under it — which on this platform there never is.
typedef DeviceLocalStoreHandle = ({AppDatabase? db, PreferencesApi store});

/// The browser's own per-origin store, and no database.
///
/// `shared_preferences` on the web is `window.localStorage`, keyed by the
/// origin the page was served from — which is exactly the scope a
/// device-local store wants in a browser: two tabs on the same gateway share
/// one transport row, and a tab on a different origin holds its own. It is
/// what keeps the address typed into Server Config across a reload, which is
/// the browser's "restart to apply".
///
/// Nothing is imported and nothing is adopted: there is no legacy store on
/// this platform, no hostname, and no rows an older build could have written
/// under one. [scope], [station], [logger] and [directoryForTest] are the
/// station arm's concerns, accepted so the two arms share one signature.
Future<DeviceLocalStoreHandle> openDeviceLocalStore({
  required ConfigScope scope,
  required String station,
  required Logger logger,
  Future<Directory> Function()? directoryForTest,
}) async =>
    (db: null, store: BrowserDeviceLocalPreferences(SharedPreferencesAsync()));

/// [PreferencesApi] over [SharedPreferencesAsync].
///
/// One-to-one: [PreferencesApi] was modelled on this class's surface (its doc
/// comments still say "shared_preferences"), so every member forwards and none
/// translates. Its own class rather than a subtype of the plugin's because the
/// plugin type is not ours to extend, and because the construction has to sit
/// in `lib/providers/`, the one directory
/// `scripts/check-preferences-construction.sh` permits it in.
class BrowserDeviceLocalPreferences implements PreferencesApi {
  BrowserDeviceLocalPreferences(this._prefs);

  final SharedPreferencesAsync _prefs;

  @override
  Future<Set<String>> getKeys({Set<String>? allowList}) =>
      _prefs.getKeys(allowList: allowList);

  @override
  Future<Map<String, Object?>> getAll({Set<String>? allowList}) =>
      _prefs.getAll(allowList: allowList);

  @override
  Future<bool?> getBool(String key) => _prefs.getBool(key);

  @override
  Future<int?> getInt(String key) => _prefs.getInt(key);

  @override
  Future<double?> getDouble(String key) => _prefs.getDouble(key);

  @override
  Future<String?> getString(String key) => _prefs.getString(key);

  @override
  Future<List<String>?> getStringList(String key) => _prefs.getStringList(key);

  @override
  Future<bool> containsKey(String key) => _prefs.containsKey(key);

  @override
  Future<void> setBool(String key, bool value) => _prefs.setBool(key, value);

  @override
  Future<void> setInt(String key, int value) => _prefs.setInt(key, value);

  @override
  Future<void> setDouble(String key, double value) =>
      _prefs.setDouble(key, value);

  @override
  Future<void> setString(String key, String value) =>
      _prefs.setString(key, value);

  @override
  Future<void> setStringList(String key, List<String> value) =>
      _prefs.setStringList(key, value);

  @override
  Future<void> remove(String key) => _prefs.remove(key);

  @override
  Future<void> clear({Set<String>? allowList}) =>
      _prefs.clear(allowList: allowList);
}

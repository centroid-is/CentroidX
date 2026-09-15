/// The platform-free half of the preferences layer.
///
/// [PreferencesApi] is the interface every consumer in this repository should
/// name; `Preferences` in `preferences.dart` is the drift-backed implementation
/// and is the only part of this subsystem that needs a database, a filesystem
/// or `dart:io`. Splitting them is what lets configuration types — key
/// mappings, the StateMan config — be read on a platform that has no local
/// database at all. On the relay that is every browser client: preferences
/// there arrive over the socket, by construction, and a web build must be able
/// to name this interface without dragging drift and sqlite3 in behind it.
///
/// Nothing in this file may import `database.dart`, `drift`, or `dart:io`.
library;

import 'dart:async';

class PreferencesException implements Exception {
  final String message;
  PreferencesException(this.message);
}

abstract class PreferencesApi {
  /// Returns all keys on the the platform that match provided [parameters].
  ///
  /// If no restrictions are provided, fetches all keys stored on the platform.
  ///
  /// Ignores any keys whose values are types which are incompatible with shared_preferences.
  Future<Set<String>> getKeys({Set<String>? allowList});

  /// Returns all keys and values on the the platform that match provided [parameters].
  ///
  /// If no restrictions are provided, fetches all entries stored on the platform.
  ///
  /// Ignores any entries of types which are incompatible with shared_preferences.
  Future<Map<String, Object?>> getAll({Set<String>? allowList});

  /// Reads a value from the platform, throwing a [TypeError] if the value is
  /// not a bool.
  Future<bool?> getBool(String key);

  /// Reads a value from the platform, throwing a [TypeError] if the value is
  /// not an int.
  Future<int?> getInt(String key);

  /// Reads a value from the platform, throwing a [TypeError] if the value is
  /// not a double.
  Future<double?> getDouble(String key);

  /// Reads a value from the platform, throwing a [TypeError] if the value is
  /// not a String.
  Future<String?> getString(String key);

  /// Reads a list of string values from the platform, throwing a [TypeError]
  /// if the value not a List<String>.
  Future<List<String>?> getStringList(String key);

  /// Returns true if the the platform contains the given [key].
  Future<bool> containsKey(String key);

  /// Saves a boolean [value] to the platform.
  Future<void> setBool(String key, bool value);

  /// Saves an integer [value] to the platform.
  Future<void> setInt(String key, int value);

  /// Saves a double [value] to the platform.
  ///
  /// On platforms that do not support storing doubles,
  /// the value will be stored as a float.
  Future<void> setDouble(String key, double value);

  /// Saves a string [value] to the platform.
  ///
  /// Some platforms have special values that cannot be stored, please refer to
  /// the README for more information.
  Future<void> setString(String key, String value);

  /// Saves a list of strings [value] to the platform.
  Future<void> setStringList(String key, List<String> value);

  /// Removes an entry from the platform.
  Future<void> remove(String key);

  /// Clears all preferences from the platform.
  ///
  /// If no [parameters] are provided, and [SharedPreferencesAsync] has no filter,
  /// all preferences will be removed. This may include values not set by this instance,
  /// such as those stored by native code or by other packages using
  /// shared_preferences internally, which may cause unintended side effects.
  ///
  /// It is highly recommended that an [allowList] be provided to this call.
  Future<void> clear({Set<String>? allowList});
}

class KeyCache {
  Set<String> keys = {};
  DateTime lastUpdated = DateTime.now().subtract(const Duration(days: 100));
  Future<void>? cacheUpdate;
}

/// In-memory cache that mimics the SharedPreferences API.
class InMemoryPreferences implements PreferencesApi {
  final Map<String, Object> _cache = {};

  Future<Set<String>> getKeys({Set<String>? allowList}) async {
    if (allowList == null) return _cache.keys.toSet();
    return _cache.keys.where((k) => allowList.contains(k)).toSet();
  }

  Future<Map<String, Object?>> getAll({Set<String>? allowList}) async {
    if (allowList == null) return Map.from(_cache);
    return Map.fromEntries(
      _cache.entries.where((e) => allowList.contains(e.key)),
    );
  }

  Future<bool?> getBool(String key) async => _cache[key] as bool?;
  Future<int?> getInt(String key) async => _cache[key] as int?;
  Future<double?> getDouble(String key) async => _cache[key] as double?;
  Future<String?> getString(String key) async => _cache[key] as String?;
  Future<List<String>?> getStringList(String key) async =>
      _cache[key] as List<String>?;

  Future<bool> containsKey(String key) async => _cache.containsKey(key);

  Future<void> setBool(String key, bool value) async => _cache[key] = value;
  Future<void> setInt(String key, int value) async => _cache[key] = value;
  Future<void> setDouble(String key, double value) async => _cache[key] = value;
  Future<void> setString(String key, String value) async => _cache[key] = value;
  Future<void> setStringList(String key, List<String> value) async =>
      _cache[key] = value;

  Future<void> remove(String key) async => _cache.remove(key);

  void printAll() {
    if (_cache.isEmpty) {
      print('InMemoryPreferences: (empty)');
      return;
    }
    print('InMemoryPreferences:');
    for (final entry in _cache.entries) {
      print('  ${entry.key}: ${entry.value}');
    }
  }

  Future<void> clear({Set<String>? allowList}) async {
    if (allowList == null) {
      _cache.clear();
    } else {
      _cache.removeWhere((k, _) => allowList.contains(k));
    }
  }
}

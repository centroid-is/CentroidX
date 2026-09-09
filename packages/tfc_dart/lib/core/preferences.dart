import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show UpdateKind, Variable;
import 'package:meta/meta.dart' show visibleForTesting;

import 'database.dart';
import 'preferences_api.dart';
import 'secure_storage/secure_storage.dart';

// Every existing `import 'preferences.dart'` keeps seeing PreferencesApi,
// InMemoryPreferences and PreferencesException; only code that must stay
// web-safe imports preferences_api.dart directly.
export 'preferences_api.dart';

class Preferences implements PreferencesApi {
  final Database? database;
  final KeyCache keyCache = KeyCache();
  final InMemoryPreferences _memoryCache = InMemoryPreferences();
  final MySecureStorage secureStorage;
  final PreferencesApi? localCache;
  final StreamController<String> _onPreferencesChanged =
      StreamController<String>.broadcast();

  /// In-memory write-through cache for secret values.
  ///
  /// Secret reads go to the OS keychain (macOS Keychain, Windows Credential
  /// Manager, libsecret, ...). The riverpod provider chain re-creates
  /// [Preferences] and re-reads secret configs (e.g. `state_man_config`)
  /// whenever it rebuilds — which happens repeatedly while the database is
  /// unreachable — and some pages re-read secrets on every widget rebuild.
  /// Without a cache every one of those reads hits the keychain, which on
  /// macOS can mean a user-visible permission prompt.
  ///
  /// The cache is static so it survives [Preferences] re-creation: each
  /// secret key touches the keychain at most once per process. It stores
  /// the read *future*, not the resolved value, so overlapping first reads
  /// of the same key (startup provider chains) are deduplicated into one
  /// keychain hit instead of a stampede. Reads populate it (a missing key
  /// is cached as a null result), writes update it, [remove] evicts it,
  /// and a read that *fails* is evicted again — a transient keychain error
  /// must not be cached as "absent" or a default config would silently
  /// overwrite the user's real one. Note: this assumes all secret access
  /// in the process goes through [Preferences] against a single
  /// [MySecureStorage] backend; writing to secure storage directly behind
  /// its back leaves the cache stale (call [clearSecretCache] if you must
  /// do that, e.g. in tests).
  static final Map<String, Future<String?>> _secretCache = {};

  /// Clears the process-wide secret cache. Intended for tests, which create
  /// independent [Preferences] instances backed by fresh fake storages.
  static void clearSecretCache() => _secretCache.clear();

  Future<String?> _readSecret(String key) {
    final cached = _secretCache[key];
    if (cached != null) {
      return cached;
    }
    final future = secureStorage.read(key: key);
    _secretCache[key] = future;
    // Never cache a failed read: evict so the next caller retries the
    // keychain. The error itself still propagates to whoever awaits the
    // returned future.
    future.then((_) {}, onError: (Object _) {
      if (identical(_secretCache[key], future)) {
        _secretCache.remove(key);
      }
    });
    return future;
  }

  Future<void> _writeSecret(String key, String value) async {
    await secureStorage.write(key: key, value: value);
    _secretCache[key] = Future.value(value);
  }

  Future<void> _deleteSecret(String key) async {
    await secureStorage.delete(key: key);
    _secretCache.remove(key);
  }

  Preferences(
      {required this.database, required this.secureStorage, this.localCache});

  static Future<Preferences> create(
      {required Database? db, PreferencesApi? localCache}) async {
    final secureStorage = SecureStorage.getInstance();
    try {
      if (db == null) {
        final prefs = Preferences(
            database: null,
            secureStorage: secureStorage,
            localCache: localCache);
        if (localCache != null) {
          await prefs._loadFromLocalCache();
        }
        return prefs;
      }
      final prefs = Preferences(
          database: db, secureStorage: secureStorage, localCache: localCache);
      await prefs.loadFromPostgres();
      if (localCache != null) {
        await prefs.syncToLocalCache();
      }
      return prefs;
    } on PreferencesException catch (e) {
      stderr.writeln(e.message);
      return Preferences(
          database: db, secureStorage: secureStorage, localCache: localCache);
    }
  }

  Future<bool> _upsertToPostgres(String key, Object? value, String type) async {
    final valStr = value is List<String> ? value.join(',') : value?.toString();
    if (database == null) {
      return false;
    }
    final db = database!.db;
    // TODO: track changes, like have a timestamp and then we can revert to the previous value if we want
    // then we can do a insert with primary key as timestamp
    // and use drift instead of custom insert
    await db.customInsert(
      r'''INSERT INTO flutter_preferences (key, value, type) VALUES ($1, $2, $3) 
      ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, type = EXCLUDED.type''',
      variables: [
        Variable.withString(key),
        Variable.withString(valStr ?? ''),
        Variable.withString(type),
      ],
    );
    return true;
  }

  @override
  Future<Set<String>> getKeys({Set<String>? allowList}) async {
    return await _memoryCache.getKeys(allowList: allowList);
  }

  @override
  Future<Map<String, Object?>> getAll({Set<String>? allowList}) async {
    return await _memoryCache.getAll(allowList: allowList);
  }

  @override
  Future<bool?> getBool(String key, {bool secret = false}) async {
    if (secret) {
      final value = await _readSecret(key);
      return value == null ? null : value == 'true';
    } else {
      return await _memoryCache.getBool(key);
    }
  }

  @override
  Future<int?> getInt(String key, {bool secret = false}) async {
    if (secret) {
      final value = await _readSecret(key);
      return value == null ? null : int.parse(value);
    } else {
      return await _memoryCache.getInt(key);
    }
  }

  @override
  Future<double?> getDouble(String key, {bool secret = false}) async {
    if (secret) {
      final value = await _readSecret(key);
      return value == null ? null : double.parse(value);
    } else {
      return await _memoryCache.getDouble(key);
    }
  }

  @override
  Future<String?> getString(String key, {bool secret = false}) async {
    if (secret) {
      return await _readSecret(key);
    } else {
      return await _memoryCache.getString(key);
    }
  }

  @override
  Future<List<String>?> getStringList(String key, {bool secret = false}) async {
    if (secret) {
      final value = await _readSecret(key);
      return value?.split(',');
    } else {
      return await _memoryCache.getStringList(key);
    }
  }

  @override
  Future<bool> containsKey(String key, {bool secret = false}) async {
    if (secret) {
      throw UnimplementedError(
          'containsKey is not implemented for secret storage');
    } else {
      return await _memoryCache.containsKey(key);
    }
  }

  @override
  Future<void> setBool(String key, bool value,
      {bool saveToDb = true, bool secret = false}) async {
    if (secret) {
      await _writeSecret(key, value.toString());
      // Secret values are never persisted to Postgres in plaintext.
      _onPreferencesChanged.add(key);
      return;
    }
    await _memoryCache.setBool(key, value);
    await localCache?.setBool(key, value);
    if (saveToDb) {
      await _upsertToPostgres(key, value, 'bool');
    }
    _onPreferencesChanged.add(key);
  }

  @override
  Future<void> setInt(String key, int value,
      {bool saveToDb = true, bool secret = false}) async {
    if (secret) {
      await _writeSecret(key, value.toString());
      // Secret values are never persisted to Postgres in plaintext.
      _onPreferencesChanged.add(key);
      return;
    }
    await _memoryCache.setInt(key, value);
    await localCache?.setInt(key, value);
    if (saveToDb) {
      await _upsertToPostgres(key, value, 'int');
    }
    _onPreferencesChanged.add(key);
  }

  @override
  Future<void> setDouble(String key, double value,
      {bool saveToDb = true, bool secret = false}) async {
    if (secret) {
      await _writeSecret(key, value.toString());
      // Secret values are never persisted to Postgres in plaintext.
      _onPreferencesChanged.add(key);
      return;
    }
    await _memoryCache.setDouble(key, value);
    await localCache?.setDouble(key, value);
    if (saveToDb) {
      await _upsertToPostgres(key, value, 'double');
    }
    _onPreferencesChanged.add(key);
  }

  @override
  Future<void> setString(String key, String value,
      {bool saveToDb = true, bool secret = false}) async {
    if (secret) {
      await _writeSecret(key, value);
      // Secret values are never persisted to Postgres in plaintext.
      _onPreferencesChanged.add(key);
      return;
    }
    await _memoryCache.setString(key, value);
    await localCache?.setString(key, value);
    if (saveToDb) {
      await _upsertToPostgres(key, value, 'String');
    }
    _onPreferencesChanged.add(key);
  }

  @override
  Future<void> setStringList(String key, List<String> value,
      {bool saveToDb = true, bool secret = false}) async {
    if (secret) {
      await _writeSecret(key, value.join(','));
      // Secret values are never persisted to Postgres in plaintext.
      _onPreferencesChanged.add(key);
      return;
    }
    await _memoryCache.setStringList(key, value);
    await localCache?.setStringList(key, value);
    if (saveToDb) {
      await _upsertToPostgres(key, value, 'List<String>');
    }
    _onPreferencesChanged.add(key);
  }

  @override
  Future<void> remove(String key, {bool secret = false}) async {
    if (secret) {
      await _deleteSecret(key);
    } else {
      await _memoryCache.remove(key);
      await localCache?.remove(key);
      if (database != null) {
        await database!.db.customUpdate(
          r'DELETE FROM flutter_preferences WHERE key = $1',
          variables: [Variable.withString(key)],
          updateKind: UpdateKind.delete,
        );
      }
    }
    _onPreferencesChanged.add(key);
  }

  @override
  Future<void> clear({Set<String>? allowList}) async {
    await _memoryCache.clear(allowList: allowList);
    await localCache?.clear(allowList: allowList);
  }

  Stream<String> get onPreferencesChanged => _onPreferencesChanged.stream;

  Future<bool> isKeyInDatabase(String key) async {
    if (keyCache.lastUpdated
        .isBefore(DateTime.now().subtract(const Duration(minutes: 10)))) {
      if (keyCache.cacheUpdate != null) {
        await keyCache.cacheUpdate!;
      } else {
        // Start the update
        keyCache.cacheUpdate = _updateCache();
        await keyCache.cacheUpdate!;
        keyCache.cacheUpdate = null;
      }
    }
    return keyCache.keys.contains(key);
  }

  Future<void> _updateCache() async {
    if (database == null) {
      return;
    }
    final db = database!.db;
    final select = db.selectOnly(db.flutterPreferences)
      ..addColumns([db.flutterPreferences.key]);
    final result = await select.get();
    keyCache.keys = result
        .map((e) => e.read(db.flutterPreferences.key))
        .whereType<String>()
        .toSet();
    keyCache.lastUpdated = DateTime.now();
  }

  /// Loads all preferences from local cache into memory cache.
  /// Used as fallback when DB is unavailable.
  Future<void> _loadFromLocalCache() async {
    final cache = localCache!;
    final all = await cache.getAll();
    for (final entry in all.entries) {
      final value = entry.value;
      if (value == null) continue;
      if (value is bool) {
        await _memoryCache.setBool(entry.key, value);
      } else if (value is int) {
        await _memoryCache.setInt(entry.key, value);
      } else if (value is double) {
        await _memoryCache.setDouble(entry.key, value);
      } else if (value is String) {
        await _memoryCache.setString(entry.key, value);
      } else if (value is List<String>) {
        await _memoryCache.setStringList(entry.key, value);
      }
    }
  }

  /// Syncs all in-memory preferences to local cache.
  /// Called after loading from Postgres so local cache stays up to date.
  ///
  /// Only keys whose value actually differs are written. The local cache is
  /// `shared_preferences`, and on Windows its `_setValue` re-encodes the whole
  /// preference map and rewrites the entire file with `writeAsStringSync` per
  /// call — measured at 35.5 ms for four keys against a 754,707-byte file on a
  /// Mac NVMe, on the UI isolate, on every startup and every database
  /// reconnect. There is no batch-write API to fold those into one, so the
  /// only lever is not writing: on a normal restart Postgres hands back
  /// exactly what is already on disk and this does nothing at all. One
  /// `getAll` read replaces the per-key writes.
  ///
  /// Additive on purpose. Keys the local cache holds but the database has
  /// never heard of are left alone: `localPreferencesProvider` keeps
  /// per-station settings in the same store, and pruning would wipe them.
  @visibleForTesting
  Future<void> syncToLocalCache() async {
    final cache = localCache!;
    final all = await _memoryCache.getAll();
    final onDisk = await cache.getAll();
    for (final entry in all.entries) {
      final value = entry.value;
      if (value == null) continue;
      if (_sameStoredValue(onDisk[entry.key], value)) continue;
      if (value is bool) {
        await cache.setBool(entry.key, value);
      } else if (value is int) {
        await cache.setInt(entry.key, value);
      } else if (value is double) {
        await cache.setDouble(entry.key, value);
      } else if (value is String) {
        await cache.setString(entry.key, value);
      } else if (value is List<String>) {
        await cache.setStringList(entry.key, value);
      }
    }
  }

  /// Whether the value already on disk is indistinguishable from [wanted].
  ///
  /// Types are compared too, not just contents: `'7'` and `7` round-trip
  /// through shared_preferences as different things.
  static bool _sameStoredValue(Object? onDisk, Object wanted) {
    if (onDisk == null) return false;
    if (wanted is List<String>) {
      if (onDisk is! List) return false;
      if (onDisk.length != wanted.length) return false;
      for (var i = 0; i < wanted.length; i++) {
        if (onDisk[i] != wanted[i]) return false;
      }
      return true;
    }
    return onDisk.runtimeType == wanted.runtimeType && onDisk == wanted;
  }

  /// Loads all preferences from Postgres into memory cache.
  Future<void> loadFromPostgres() async {
    final db = database!.db;
    final result = await db.select(db.flutterPreferences).get();
    for (final row in result) {
      final key = row.key;
      final value = row.value;
      final type = row.type;
      switch (type) {
        case 'bool':
          if (value != null) {
            await _memoryCache.setBool(key, value == 'true');
          }
          break;
        case 'int':
          if (value != null) {
            await _memoryCache.setInt(key, int.parse(value));
          }
          break;
        case 'double':
          if (value != null) {
            await _memoryCache.setDouble(key, double.parse(value));
          }
          break;
        case 'String':
          if (value != null) {
            await _memoryCache.setString(key, value);
          }
          break;
        case 'List<String>':
          if (value != null) {
            await _memoryCache.setStringList(key, value.split(','));
          }
          break;
        default:
          throw Exception('Unsupported type: $type');
      }
    }
  }
}

/// A wrapper around SharedPreferencesAsync that implements PreferencesApi
// class SharedPreferencesWrapper implements PreferencesApi {
//   final SharedPreferencesAsync _prefs;

//   SharedPreferencesWrapper(this._prefs);

//   @override
//   Future<Set<String>> getKeys({Set<String>? allowList}) {
//     return _prefs.getKeys(allowList: allowList);
//   }

//   @override
//   Future<Map<String, Object?>> getAll({Set<String>? allowList}) {
//     return _prefs.getAll(allowList: allowList);
//   }

//   @override
//   Future<bool?> getBool(String key) {
//     return _prefs.getBool(key);
//   }

//   @override
//   Future<int?> getInt(String key) {
//     return _prefs.getInt(key);
//   }

//   @override
//   Future<double?> getDouble(String key) {
//     return _prefs.getDouble(key);
//   }

//   @override
//   Future<String?> getString(String key) {
//     return _prefs.getString(key);
//   }

//   @override
//   Future<List<String>?> getStringList(String key) {
//     return _prefs.getStringList(key);
//   }

//   @override
//   Future<bool> containsKey(String key) {
//     return _prefs.containsKey(key);
//   }

//   @override
//   Future<void> setBool(String key, bool value) {
//     return _prefs.setBool(key, value);
//   }

//   @override
//   Future<void> setInt(String key, int value) {
//     return _prefs.setInt(key, value);
//   }

//   @override
//   Future<void> setDouble(String key, double value) {
//     return _prefs.setDouble(key, value);
//   }

//   @override
//   Future<void> setString(String key, String value) {
//     return _prefs.setString(key, value);
//   }

//   @override
//   Future<void> setStringList(String key, List<String> value) {
//     return _prefs.setStringList(key, value);
//   }

//   @override
//   Future<void> remove(String key) {
//     return _prefs.remove(key);
//   }

//   @override
//   Future<void> clear({Set<String>? allowList}) {
//     return _prefs.clear(allowList: allowList);
//   }
// }

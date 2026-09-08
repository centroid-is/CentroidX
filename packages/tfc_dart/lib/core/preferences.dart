import 'dart:async';

import 'database.dart';
import 'secure_storage/secure_storage.dart';

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

/// A preferences store over an in-memory cache, a device-local mirror and the
/// OS keychain.
///
/// **It reads and writes no shared table.** Every Postgres path this class had
/// went to `flutter_preferences`, and 04-12 retired them with it: the shared
/// settings are `config_item` rows, served by [SharedRowPreferences], which
/// extends this class for exactly the parts that did not move — the secret
/// cache, the change stream and the local mirror.
///
/// What remains is therefore the base every preferences store shares plus the
/// keychain, and [database] is a handle it carries for callers rather than
/// one it uses. The subclass is where a shared write goes through
/// `ConfigStore`'s compare-and-swap and lands a change row; nothing here
/// writes anything a second station could see.
class Preferences implements PreferencesApi {
  /// The database handle, carried for callers that ask.
  ///
  /// Nothing in this class reads it any more. It survives because
  /// `preferencesProvider` hands one over and a caller reaching
  /// `prefs.database` must get what it always got rather than null.
  final Database? database;
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

  /// A store seeded from the device-local mirror, if there is one.
  ///
  /// [db] is carried through to [database] and otherwise unused: the load
  /// from Postgres this used to perform read `flutter_preferences`, and the
  /// shared settings have been `config_item` rows since 04-05. A caller that
  /// wants those builds [SharedRowPreferences] instead — which is what
  /// `preferencesProvider` does.
  static Future<Preferences> create(
      {required Database? db, PreferencesApi? localCache}) async {
    final prefs = Preferences(
        database: db,
        secureStorage: SecureStorage.getInstance(),
        localCache: localCache);
    if (localCache != null) {
      await prefs._loadFromLocalCache();
    }
    return prefs;
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

  /// [saveToDb] is accepted and ignored here, and that is not a silent
  /// no-op: this store has no shared database to save to, so there is nothing
  /// for the flag to turn off. It stays on the signature because it means
  /// something to [SharedRowPreferences], where `false` is a caller saying
  /// "this value is not the shared configuration" — `StateManConfig.toPrefs`
  /// writing a secret, in practice — and the subclass honours it.
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
    _onPreferencesChanged.add(key);
  }

  @override
  Future<void> remove(String key, {bool secret = false}) async {
    if (secret) {
      await _deleteSecret(key);
    } else {
      await _memoryCache.remove(key);
      await localCache?.remove(key);
    }
    _onPreferencesChanged.add(key);
  }

  @override
  Future<void> clear({Set<String>? allowList}) async {
    await _memoryCache.clear(allowList: allowList);
    await localCache?.clear(allowList: allowList);
  }

  Stream<String> get onPreferencesChanged => _onPreferencesChanged.stream;

  /// Whether the shared database holds [key] — which this store cannot say.
  ///
  /// It used to answer from a ten-minute cache of the old shared preference
  /// table's key column. With that table retired there is no shared key set
  /// here to consult, and
  /// the honest answer is neither true nor false. **Throws rather than
  /// answering false**: the one caller is the preferences editor, which uses
  /// it to mark a setting as stored rather than defaulted, and a blanket
  /// "not stored" would relabel every configured value on the page.
  ///
  /// [SharedRowPreferences] overrides it and answers from the rows, which is
  /// what every production caller is holding.
  Future<bool> isKeyInDatabase(String key) async {
    throw UnsupportedError(
        'This Preferences has no shared database: the old shared preference '
        'table retired in 04-12 and the shared settings are config_item rows. '
        'Ask SharedRowPreferences, which answers from those rows.');
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
}

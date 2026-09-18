/// The database *settings* — the type a Server Config form edits — split from
/// the database *runtime* that acts on them.
///
/// ## Why this is its own file
///
/// [DatabaseConfig] used to live in `database.dart` beside the 1,300-line
/// [Database] class. That is a natural place for it right up until something
/// has to name the settings without being able to open a connection. A Flutter
/// web build is exactly that: `database.dart` imports `database_drift.dart`,
/// which imports `drift/native.dart` -> `sqlite3` -> `dart:ffi`, and `dart:ffi`
/// is a hard compile error under dart2js, not a runtime one. So the Server
/// Config page — which only wants to *show and edit* a host, a port and an SSL
/// mode — could not be compiled for the browser at all.
///
/// Note what the blocker is and is not. `dart:io` is fine: Flutter web ships a
/// stub that compiles and throws if called, so [Platform.environment] below
/// costs nothing to link. Only `dart:ffi` cannot be linked. This file therefore
/// aims at one property and no more: **nothing reachable from here reaches
/// `dart:ffi`**.
///
/// `database.dart` re-exports this library, so every existing importer of
/// `core/database.dart` still sees [DatabaseConfig] and needed no edit. Import
/// *this* file directly only from code that must also compile for the browser.
///
/// ## The cycle that had to be cut
///
/// Moving the class alone would have achieved nothing. [DatabaseConfig] reads
/// its password through [SecureStorage], and `secure_storage.dart` imported
/// `preferences.dart` for one line — `Preferences.clearSecretCache()` — which
/// dragged the drift-backed preferences store, and through it `database.dart`,
/// straight back into the closure. That edge is now inverted: [SecureStorage]
/// exposes a generation counter and the caches check it, so the store knows
/// nothing about who caches its secrets. See `secure_storage/secure_storage.dart`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:json_annotation/json_annotation.dart' as json;
import 'package:postgres/postgres.dart' as pg;
import 'package:postgres/postgres.dart' show Endpoint, SslMode;

import 'database_connections.dart' show maxPoolConnectionsFromEnv;
import 'secure_storage/secure_storage.dart';

part 'database_config.g.dart';

class EndpointConverter
    implements json.JsonConverter<pg.Endpoint, Map<String, dynamic>> {
  const EndpointConverter();

  @override
  pg.Endpoint fromJson(Map<String, dynamic> json) {
    return pg.Endpoint(
      host: json['host'] as String,
      port: json['port'] as int,
      database: json['database'] as String,
      username: json['username'] as String?,
      password: json['password'] as String?,
      isUnixSocket: json['isUnixSocket'] as bool? ?? false,
    );
  }

  @override
  Map<String, dynamic> toJson(pg.Endpoint endpoint) => {
        'host': endpoint.host,
        'port': endpoint.port,
        'database': endpoint.database,
        'username': endpoint.username,
        'password': endpoint.password,
        'isUnixSocket': endpoint.isUnixSocket,
      };
}

class SslModeConverter implements json.JsonConverter<pg.SslMode, String> {
  const SslModeConverter();

  @override
  pg.SslMode fromJson(String json) {
    return pg.SslMode.values.firstWhere(
      (mode) => mode.name == json,
      orElse: () => pg.SslMode.disable,
    );
  }

  @override
  String toJson(pg.SslMode mode) => mode.name;
}

@json.JsonSerializable()
class DatabaseConfig {
  @EndpointConverter()
  pg.Endpoint? postgres;
  @SslModeConverter()
  pg.SslMode? sslMode;
  bool debug = false;

  /// Connections this process may pool for queries, or null for one.
  ///
  /// One is what a UI client needs and what the postgres package itself
  /// defaults to. Only a process that genuinely drains several sources in
  /// parallel -- the collector, roughly one connection per OPC UA server --
  /// should raise it, and [resolvePoolSize] caps whatever is set here.
  ///
  /// This is the budget for work, and now also the pool size. The pool used to
  /// be opened one wider, for the health monitor's standing connection; the
  /// monitor no longer holds one. See [poolConnectionCount].
  ///
  /// [fromEnv] reads it from `CENTROID_DB_MAX_POOL_CONNECTIONS`
  /// ([kMaxPoolConnectionsEnv]), which is how the collector sets it.
  int? maxPoolConnections;

  /// Pool connect timeout (not serialized to JSON).
  @json.JsonKey(includeFromJson: false, includeToJson: false)
  Duration connectTimeout;

  /// Pool query timeout (not serialized to JSON).
  @json.JsonKey(includeFromJson: false, includeToJson: false)
  Duration queryTimeout;

  /// What this process calls itself to the server (not serialized to JSON).
  ///
  /// Lands in `pg_stat_activity.application_name`, so `SELECT application_name,
  /// count(*) FROM pg_stat_activity GROUP BY 1` on a live plant server says
  /// which of the HMI, the collector and whatever else is holding sessions.
  /// Untagged, every one of them shows up as an empty string and the only way
  /// to tell them apart is by client port.
  ///
  /// Tests override it to a value unique per database so they can count their
  /// own backends without also counting connections another suite in the same
  /// `dart test` invocation still has open.
  @json.JsonKey(includeFromJson: false, includeToJson: false)
  String applicationName;

  DatabaseConfig({
    this.postgres,
    this.sslMode,
    this.debug = false,
    this.maxPoolConnections,
    this.connectTimeout = const Duration(seconds: 5),
    this.queryTimeout = const Duration(seconds: 30),
    this.applicationName = 'tfc_dart',
  });

  factory DatabaseConfig.fromJson(Map<String, dynamic> json) =>
      _$DatabaseConfigFromJson(json);

  Map<String, dynamic> toJson() => _$DatabaseConfigToJson(this);

  static const _configLocation = 'database_config';

  static Future<DatabaseConfig> fromEnv() async {
    if (Platform.environment['CENTROID_PGHOST'] == null) {
      throw Exception("Please provide environment variable CENTROID_PGHOST");
    }
    final host = Platform.environment['CENTROID_PGHOST']!;
    final port =
        int.tryParse(Platform.environment['CENTROID_PGPORT'] ?? '') ?? 5432;
    final database = Platform.environment['CENTROID_PGDATABASE'] ?? 'hmi';
    final username = Platform.environment['CENTROID_PGUSER'];
    final password = Platform.environment['CENTROID_PGPASSWORD'];
    final sslModeStr = Platform.environment['CENTROID_PGSSLMODE'];
    final debug = Platform.environment['CENTROID_DB_DEBUG'] == 'true';

    final sslMode = sslModeStr != null
        ? pg.SslMode.values.firstWhere(
            (mode) => mode.name == sslModeStr,
            orElse: () => pg.SslMode.disable,
          )
        : pg.SslMode.disable;

    return DatabaseConfig(
      postgres: pg.Endpoint(
        host: host,
        port: port,
        database: database,
        username: username,
        password: password,
      ),
      sslMode: sslMode,
      debug: debug,
      // The only way anything sets this. The collector -- the one process the
      // doc on [maxPoolConnections] says should raise it -- is configured
      // entirely from the environment, so without this the escape hatch was
      // documented but unreachable.
      maxPoolConnections: maxPoolConnectionsFromEnv(Platform.environment),
    );
  }

  /// Process-wide cache of the raw config JSON read from secure storage.
  ///
  /// [fromPrefs] sits on the `databaseProvider` rebuild path, which retries
  /// every 2 s while the database is unreachable — without a cache each
  /// retry is a keychain hit for the postgres password. Stores the read
  /// *future* so overlapping reads deduplicate; a failed read is evicted so
  /// the next call retries; [toPrefs] writes through.
  ///
  /// A swap of the [SecureStorage] instance drops it: the cache remembers
  /// which [SecureStorage.generation] filled it, and [_syncGeneration] treats
  /// a mismatch as a miss. `SecureStorage.setInstance` used to clear this
  /// eagerly by calling [clearPrefsCache], which meant the secret store had to
  /// import this library — see the cycle described at the top of this file.
  static Future<String?>? _configJsonCache;
  static int _configCacheGeneration = SecureStorage.generation;

  /// Drops anything cached under an older [SecureStorage] instance.
  static void _syncGeneration() {
    if (_configCacheGeneration != SecureStorage.generation) {
      _configJsonCache = null;
      _configCacheGeneration = SecureStorage.generation;
    }
  }

  /// Clears the process-wide config cache. Intended for tests.
  static void clearPrefsCache() => _configJsonCache = null;

  static Future<String?> _readConfigJson() {
    _syncGeneration();
    final cached = _configJsonCache;
    if (cached != null) {
      return cached;
    }
    final future = SecureStorage.getInstance().read(key: _configLocation);
    _configJsonCache = future;
    future.then((_) {}, onError: (Object _) {
      if (identical(_configJsonCache, future)) {
        _configJsonCache = null;
      }
    });
    return future;
  }

  static Future<DatabaseConfig> fromPrefs() async {
    var configJson = await _readConfigJson();
    DatabaseConfig config;
    if (configJson == null) {
      // If not found, create default config
      config = DatabaseConfig(
          postgres: null); // Or provide a default Endpoint if needed
      configJson = jsonEncode(config.toJson());
      await SecureStorage.getInstance()
          .write(key: _configLocation, value: configJson);
      _syncGeneration();
      _configJsonCache = Future.value(configJson);
    } else {
      config = DatabaseConfig.fromJson(jsonDecode(configJson));
    }
    return config;
  }

  Future<void> toPrefs() async {
    final prefs = SecureStorage.getInstance();
    final configJson = jsonEncode(toJson());
    await prefs.write(key: _configLocation, value: configJson);
    _syncGeneration();
    _configJsonCache = Future.value(configJson);
  }

  @override
  String toString() {
    return "DatabaseConfig(${jsonEncode(toJson())})";
  }
}

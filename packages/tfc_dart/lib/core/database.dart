import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:postgres/postgres.dart' as pg;
import 'package:postgres/postgres.dart' show Endpoint, SslMode;
import 'package:json_annotation/json_annotation.dart' as json;
export 'package:postgres/postgres.dart' show Sql;
import 'package:logger/logger.dart';
import 'package:meta/meta.dart' show visibleForTesting;

import 'secure_storage/secure_storage.dart';
import 'database_drift.dart';
import 'database_connections.dart';
import '../converter/duration_converter.dart';

part 'database.g.dart';

/// File-level logger. These diagnostics used to go to stderr, which in a
/// windowed MSIX build with no console is discarded outright.
final Logger _log = Logger();

// todo skoða
// https://github.com/osaxma/postgresql-dart-replication-example/blob/main/example/listen_v3.dart

extension IntervalToDuration on pg.Interval {
  Duration toDuration() {
    // TODO: THIS IS BAD
    // Convert months to approximate days (30 days per month)
    final monthDays = months * 30;
    final totalDays = days + monthDays;

    return Duration(
      days: totalDays,
      microseconds: microseconds,
    );
  }
}

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
  /// the next call retries; [toPrefs] writes through. Tests that swap the
  /// [SecureStorage] instance should call [clearPrefsCache].
  static Future<String?>? _configJsonCache;

  /// Clears the process-wide config cache. Intended for tests.
  static void clearPrefsCache() => _configJsonCache = null;

  static Future<String?> _readConfigJson() {
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
    _configJsonCache = Future.value(configJson);
  }

  @override
  String toString() {
    return "DatabaseConfig(${jsonEncode(toJson())})";
  }
}

class DatabaseException implements Exception {
  DatabaseException(this.message);

  final String message;
}

/// Rows one table may hold across the write buffer and the retry queue.
///
/// Was 100, which is not an outage buffer — it is a rounding error. A tag
/// sampled once a second filled it in a minute and forty seconds; a thirty
/// second outage over three hundred samples kept the last hundred and threw
/// away two hundred, oldest first, which is to say it threw away the
/// *beginning* of the incident: exactly the rows anyone investigating the
/// outage would want.
///
/// Ten thousand buys a hundred times the tolerance — a few hours at 1 Hz, about
/// seventeen minutes at 10 Hz — which covers a Postgres restart, a failover, or
/// a VM reboot, the outages that actually happen.
///
/// The cost is memory, and the cost is per table, not per process. A scalar
/// `_PendingWrite` is roughly 100 bytes (a DateTime, a boxed number, a sequence
/// int, object headers), so a saturated table is about a megabyte. The SVN
/// station collects 140 tags, so the worst case here alone is ~140 MB — not the
/// "few MB" a single-table reading of this number suggests. That is why
/// [kMaxQueuedRowsTotal] exists.
const int kMaxQueuedRowsPerTable = 10000;

/// Rows all tables together may hold.
///
/// The per-table cap keeps one noisy tag from starving the rest; this one keeps
/// the process from being killed. Without it, raising the per-table cap a
/// hundredfold would trade a silent, bounded data loss for an unbounded one —
/// an OOM kill loses the entire queue, every table at once, plus whatever the
/// process was doing. Struct samples make that worse: a ten-member row is
/// closer to 600 bytes than 100, and 140 tables of those at the per-table cap
/// would be most of a gigabyte.
///
/// 200 000 rows is roughly 20 MB of scalars, or 120 MB of wide structs. It is
/// reached only when many tables are saturated at once, i.e. in a long outage
/// on a busy line, and when it is reached the trimming is counted and logged
/// like any other drop rather than being silent.
const int kMaxQueuedRowsTotal = 200000;

/// The longest retention anything may ask for: ten years.
///
/// Also the number the UI clamps to. It is not an arbitrary round figure — it
/// has to stay well below [kLegacyMicrosecondCutoffMinutes] so that no value an
/// operator can enter is ever mistaken for a legacy microsecond value. See the
/// cutoff's own documentation for the two populations involved.
const int kMaxRetentionDays = 3650;

/// The shortest retention that will be installed.
///
/// This guard exists to catch a **unit-conversion artifact**, not to second-
/// guess an operator who wants a short window. That distinction sets the
/// threshold, and it is why this is a minute rather than an hour.
///
/// The defect was a cliff in [durationFromMinutesTolerant]: a `drop_after_min`
/// above the cutoff is re-read as *microseconds*, so a retention typed in days
/// came back as a fraction of a minute. The artifacts it produces are bounded
/// and land firmly in the seconds range. With the cutoff at fifty years
/// (26 280 000 minutes), a stored value is only misread when the typed day
/// count exceeds 18 250, and the misread duration is `days × 1440`
/// *microseconds*:
///
///   * 18 251 days (just over the cutoff) -> 26.3 s
///   * 36 500 days (a hundred years, a plausible fat-finger) -> 52.6 s
///   * the originally reported 3651 days, under the old cutoff -> 5.26 s
///
/// Every one is under a minute, so a one-minute floor rejects all of them, and
/// zero and negative with them.
///
/// An hour was the first choice here and it was wrong: it rejected a ten-minute
/// retention, which is a perfectly reasonable window for a high-rate diagnostic
/// tag — a vibration or current trace sampled at 100 Hz — and which the
/// integration suite legitimately uses. "Nothing legitimate asks for it" was an
/// assumption, and the test suite was evidence against it.
///
/// Policy about what an operator may *choose* lives in the UI, which clamps the
/// retention field to 1..[kMaxRetentionDays] days. This constant is the
/// narrower backstop for values already on disk, and it should stay narrow:
/// every minute of headroom it takes away is a configuration somebody might
/// legitimately need.
const Duration kMinRetentionDuration = Duration(minutes: 1);

/// Tables the retention machinery must never be pointed at.
///
/// These are the access-control tables from schema v6. `audit_entry` is the
/// audit trail — append-only, never pruned — and `app_user` / `app_role` are
/// the identities the trail refers to; a swept role table turns every historic
/// row into a name with nothing behind it.
///
/// [Database.registerRetentionPolicy] refuses any of these by name. See that
/// method for why the refusal lives there rather than in a test.
const Set<String> kRetentionExemptTables = {
  'audit_entry',
  'app_user',
  'app_role',
};

// https://docs.tigerdata.com/api/latest/data-retention/add_retention_policy/
@json.JsonSerializable(explicitToJson: true)
class RetentionPolicy {
  @DurationMinutesConverterNonNull()
  @json.JsonKey(name: 'drop_after_min')
  final Duration
      dropAfter; // Chunks fully older than this interval when the policy is run are dropped
  @DurationMinutesConverter()
  @json.JsonKey(name: 'schedule_interval_min')
  final Duration?
      scheduleInterval; // The interval between the finish time of the last execution and the next start. Defaults to NULL.

  const RetentionPolicy({required this.dropAfter, this.scheduleInterval});

  /// Whether this policy is safe to install.
  ///
  /// A [dropAfter] under [kMinRetentionDuration] — including zero and negative,
  /// which the retention field accepted without complaint — deletes the history
  /// rather than bounding it.
  bool get isUsable => dropAfter >= kMinRetentionDuration;

  /// Reads a stored policy, capping a [dropAfter] that is longer than
  /// [kMaxRetentionDays].
  ///
  /// The cap matters for configs that are already on disk. A station that was
  /// given 3651 days wrote 5_257_440 into `drop_after_min`, one minute-count
  /// past the old microsecond cutoff, and every start since has read it back as
  /// 5.26 *seconds*. Moving the cutoff restores the operator's meaning — 3651
  /// days — and this cap then brings it inside the supported range instead of
  /// letting an out-of-range number back into the system.
  ///
  /// Values *below* the minimum are deliberately left alone rather than raised
  /// to some default. A retention nobody chose is a retention nobody can be
  /// held to; these are refused at the point of installation instead, which
  /// leaves whatever policy the table already has untouched and deletes
  /// nothing. See [isUsable] and [AppDatabase.updateRetentionPolicy].
  factory RetentionPolicy.fromJson(Map<String, dynamic> json) {
    final p = _$RetentionPolicyFromJson(json);
    const max = Duration(days: kMaxRetentionDays);
    if (p.dropAfter <= max) return p;
    Database.logger.w(
        'Retention of ${p.dropAfter.inDays} days is longer than the supported '
        'maximum of $kMaxRetentionDays days; using $kMaxRetentionDays days.');
    return RetentionPolicy(
        dropAfter: max, scheduleInterval: p.scheduleInterval);
  }

  Map<String, dynamic> toJson() => _$RetentionPolicyToJson(this);

  @override
  bool operator ==(Object other) {
    if (other is RetentionPolicy) {
      return dropAfter == other.dropAfter &&
          scheduleInterval == other.scheduleInterval;
    }
    return false;
  }

  @override
  int get hashCode => dropAfter.hashCode ^ scheduleInterval.hashCode;

  @override
  String toString() =>
      'RetentionPolicy(dropAfter: $dropAfter, scheduleInterval: $scheduleInterval)';
}

class _PendingWrite {
  final DateTime time;
  final dynamic value;

  /// Monotonic sequence number for deterministic insertion-order sorting.
  /// [DateTime.now()] has limited resolution on Windows (~15 ms), so many
  /// writes created in a tight loop share the same timestamp.  Sorting by
  /// [time] alone gives a non-deterministic order for equal timestamps
  /// (Dart's [List.sort] is not guaranteed stable), which causes the wrong
  /// items to be dropped during queue overflow trimming.
  final int seq;
  static int _nextSeq = 0;

  _PendingWrite(this.time, this.value) : seq = _nextSeq++;

  Map<String, dynamic> toMap() {
    if (value is Map<String, dynamic>) {
      return {"time": time.toIso8601String(), ...value};
    } else {
      return {'time': time.toIso8601String(), 'value': value};
    }
  }
}

/// The Postgres type of a collected table's `value` column.
class ValueColumnType {
  final String dataType;
  final String udtName;
  const ValueColumnType(this.dataType, this.udtName);
}

/// Builds the min/max/last downsampling SQL used by
/// [Database.queryTimeseriesDataDownsampled].
///
/// [quotedTable] must already have its embedded double quotes doubled; it is
/// interpolated inside `"..."`. The statement takes three positional
/// parameters: `$1` the bucket interval, `$2`/`$3` the inclusive time bounds.
///
/// The per-bucket "last" value is TimescaleDB's `last(value, time)`, **not**
/// `(array_agg(value ORDER BY time DESC))[1]`. The two are equivalent — both
/// yield the value carried by the row with the greatest `time` in the bucket,
/// both propagate a NULL *value* on that newest row rather than skipping back
/// to an older non-null one, and neither defines which row wins when several
/// share the maximum `time`. A NULL *time* cannot arise: `time` is the
/// hypertable partitioning column, so Timescale enforces NOT NULL on it (the
/// one case where the two would differ, since `ORDER BY time DESC` sorts NULLs
/// first). The difference is entirely in the plan: `array_agg(... ORDER BY)`
/// forces a full sort of every row in range — measured as
/// `Sort Method: external merge  Disk: 60288kB` over 1.8M rows on the plant
/// database — while `last()` is computed in one pass off the existing time
/// index.
@visibleForTesting
String buildDownsampleSql(
    {required String quotedTable, required bool isArray}) {
  if (isArray) {
    // Unnest array elements, aggregate per-index, re-assemble arrays
    return r'''
        WITH elements AS (
          SELECT
            time,
            val,
            idx
          FROM "''' +
        quotedTable +
        r'''"
          CROSS JOIN LATERAL unnest(value) WITH ORDINALITY AS t(val, idx)
          WHERE time >= $2::timestamptz AND time <= $3::timestamptz
        ),
        agg AS (
          SELECT
            time_bucket($1::interval, time) AS bucket,
            idx,
            min(val)                                   AS min_val,
            max(val)                                   AS max_val,
            last(val, time)                            AS last_val
          FROM elements
          GROUP BY bucket, idx
        )
        SELECT bucket AS time, array_agg(min_val ORDER BY idx) AS value FROM agg GROUP BY bucket
        UNION ALL
        SELECT bucket + $1::interval * 0.5, array_agg(max_val ORDER BY idx) FROM agg GROUP BY bucket
        UNION ALL
        SELECT bucket + $1::interval, array_agg(last_val ORDER BY idx) FROM agg GROUP BY bucket
        ORDER BY 1
      ''';
  }
  return r'''
        WITH agg AS (
          SELECT
            time_bucket($1::interval, time) AS bucket,
            min(value)                                   AS min_val,
            max(value)                                   AS max_val,
            last(value, time)                            AS last_val
          FROM "''' +
      quotedTable +
      r'''"
          WHERE time >= $2::timestamptz AND time <= $3::timestamptz
          GROUP BY bucket
        )
        SELECT bucket              AS time, min_val  AS value FROM agg
        UNION ALL
        SELECT bucket + $1::interval * 0.5,  max_val  AS value FROM agg
        UNION ALL
        SELECT bucket + $1::interval,         last_val AS value FROM agg
        ORDER BY 1
      ''';
}

class Database {
  Database(
    this.db, {
    this.healthTimeout = const Duration(seconds: 30),
    int maxQueuedRowsPerTable = kMaxQueuedRowsPerTable,
    int maxQueuedRowsTotal = kMaxQueuedRowsTotal,
  })  : _maxRetryQueueSize = maxQueuedRowsPerTable,
        _maxTotalQueuedRows = maxQueuedRowsTotal {
    _startBatchFlushTimer();
    _initConnectionHealth();
  }

  /// How long to wait without a health event before assuming the isolate is dead.
  final Duration healthTimeout;

  /// Lightweight check if the database is reachable.
  /// Opens and immediately closes a single connection. Throws on failure.
  ///
  /// The close is scheduled on the open itself rather than awaited after the
  /// timeout, because the timeout only stops us waiting -- it does not stop
  /// the server finishing the handshake. A probe that gave up on a slow
  /// server used to leave that connection open for the rest of the day.
  static Future<void> probe(DatabaseConfig config) async {
    await openThenClose<pg.Connection>(
      pg.Connection.open(
        config.postgres!,
        settings: pg.ConnectionSettings(
          sslMode: config.sslMode ?? pg.SslMode.disable,
          // Its own tag: a probe is the shortest-lived connection here, so one
          // still sitting in pg_stat_activity is unambiguously the leak this
          // method's doc comment describes.
          applicationName: '${config.applicationName}:probe',
        ),
      ),
      (conn) => conn.close(),
      timeout: const Duration(seconds: 5),
    );
  }

  /// Probe the database, create an [AppDatabase], and open the connection.
  /// Retries with growing backoff until the database is reachable.
  /// Set [useIsolate] to false when already running inside an isolate.
  ///
  /// Every attempt that gets as far as building an [AppDatabase] is closed
  /// again if opening it fails. Each spawned DriftIsolate carries a pool whose
  /// health monitor holds a connection open by design, so an attempt left
  /// lying around costs a server slot until the process exits -- and this loop
  /// runs until it succeeds, which on a full server is never.
  static Future<Database> connectWithRetry(
    DatabaseConfig config, {
    bool useIsolate = true,
  }) async {
    return retryUntilOpen<Database>(
      probe: () => probe(config),
      build: () async => Database(useIsolate
          ? await AppDatabase.spawn(config)
          : await AppDatabase.create(config)),
      open: (db) async {
        await db.db.open();
        logger.i('Database connected');
      },
      dispose: (db) => db.close(),
      delay: backoffForAttempt,
      sleep: (d) => Future.delayed(d),
      onError: (e, attempt) => logger.w(
          'Database not reachable (attempt $attempt), retrying in '
          '${backoffForAttempt(attempt).inSeconds}s: $e'),
    );
  }

  AppDatabase db;
  Map<String, RetentionPolicy> retentionPolicies = {};
  static final Logger logger = Logger();
  final Map<String, Completer<void>> _tableCreationLocks = {};
  bool _lastConnectionState = true;
  final _connectionStateController = StreamController<bool>.broadcast();
  StreamSubscription<bool>? _healthSub;
  Timer? _healthTimeoutTimer;

  void _initConnectionHealth() {
    void resetTimeout() {
      _healthTimeoutTimer?.cancel();
      _healthTimeoutTimer = Timer(healthTimeout, () {
        // No health event received within the timeout window — assume dead.
        _lastConnectionState = false;
        _connectionStateController.add(false);
      });
    }

    _healthSub = db.connectionHealth?.listen(
      (state) {
        _lastConnectionState = state;
        _connectionStateController.add(state);
        resetTimeout();
      },
      onDone: () {
        // Health stream closed — isolate likely died.
        _healthTimeoutTimer?.cancel();
        _lastConnectionState = false;
        _connectionStateController.add(false);
      },
      onError: (error) {
        // Health stream errored — treat as disconnected.
        _healthTimeoutTimer?.cancel();
        _lastConnectionState = false;
        _connectionStateController.add(false);
      },
    );

    // Start initial timeout (if there IS a health stream to listen to).
    if (_healthSub != null) {
      resetTimeout();
    }
  }

  /// Multi-subscription stream of connection health.
  /// Each new listener immediately receives the last known state,
  /// then gets live updates. Safe for multiple StreamBuilders.
  late final Stream<bool> connectionState = Stream.multi((controller) {
    controller.add(_lastConnectionState);
    final sub = _connectionStateController.stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.onCancel = sub.cancel;
  });

  /// Retry a database operation with exponential backoff.
  /// Permanent PostgreSQL errors (schema mismatch, syntax errors, etc.) are
  /// re-thrown immediately without retrying, so they don't block the flush loop.
  /// Connection errors (SocketException, connection refused/reset) are also
  /// re-thrown immediately — retrying on a dead pool is pointless; the health
  /// monitor will handle pool recreation.
  Future<T> _withRetry<T>(Future<T> Function() operation,
      {int maxRetries = 5,
      Duration initialDelay = const Duration(seconds: 1)}) async {
    var delay = initialDelay;
    for (var attempt = 0; attempt < maxRetries; attempt++) {
      try {
        return await operation();
      } catch (e) {
        // Don't retry permanent errors — retrying will never help and blocks
        // the flush loop for all other tables while backoff runs.
        // When running via AppDatabase.spawn() (isolate mode), Drift wraps
        // pg.ServerException in DriftRemoteException, so we check by type first
        // then fall back to parsing the message string for the SQLSTATE code.
        if (_isPermanentDbError(e)) rethrow;

        // Don't retry connection errors — the pool is dead and retrying will
        // just burn through attempts on a broken socket. The health monitor
        // will detect this and recreate the pool/provider.
        if (_isConnectionError(e)) {
          logger.w('Connection error detected, not retrying (health monitor '
              'will handle recovery): $e');
          rethrow;
        }

        if (attempt == maxRetries - 1) rethrow;
        logger.w(
            'Database operation failed (attempt ${attempt + 1}/$maxRetries): $e');
        await Future.delayed(delay);
        delay *= 2; // Exponential backoff
      }
    }
    throw StateError('Unreachable');
  }

  /// Returns true if [e] is a permanent PostgreSQL error that should not be retried.
  ///
  /// In non-isolate mode the exception is [pg.ServerException] and we can read
  /// [pg.ServerException.code] directly.  In isolate mode (AppDatabase.spawn)
  /// Drift wraps it in a DriftRemoteException whose [toString] still contains
  /// the 5-char SQLSTATE code, so we fall back to parsing the message string.
  ///
  /// SQLSTATE class 42 = syntax/schema errors (42703 = undefined_column, …)
  /// SQLSTATE class 23 = integrity constraint violations
  /// SQLSTATE class 22 = data exceptions (22003 = numeric_value_out_of_range, …)
  static bool _isPermanentDbError(Object e) {
    if (e is pg.ServerException) {
      final code = e.code ?? '';
      return code.startsWith('42') ||
          code.startsWith('23') ||
          code.startsWith('22');
    }
    // DriftRemoteException message format: "Severity.error 42703: …"
    return RegExp(r'\b(42|23|22)[0-9A-Z]{3}\b').hasMatch(e.toString());
  }

  @visibleForTesting
  static bool isPermanentDbErrorForTest(Object e) => _isPermanentDbError(e);

  /// Returns true if [e] is a SQLSTATE class 22 *data exception*.
  ///
  /// Class 22 is, by definition, a complaint about the values in the statement
  /// rather than about the server: 22003 numeric_value_out_of_range, 22001
  /// string_data_right_truncation, 22P02 invalid_text_representation, 22008
  /// datetime_field_overflow. Re-sending the identical rows cannot succeed —
  /// not now, not in five seconds, not after the database comes back, because
  /// nothing about the database was ever the problem.
  ///
  /// This is the distinction the retry queue was missing. A batch containing a
  /// UDINT counter past 2^31 got 22003, was classified neither permanent nor
  /// connection-related, and went round the five-second retry loop *forever*,
  /// re-queueing itself each time until it aged out at the queue cap — taking
  /// with it every good row batched beside it and, once the counter was
  /// permanently past 2^31, every batch for that tag from then on. The only
  /// evidence was a `logger.w` in the acquisition isolate.
  ///
  /// Distinguishing it does not save the rows: a poisoned batch is lost either
  /// way. What it changes is that the loss is now immediate, counted (see
  /// [getStats]) and logged at error level, instead of being an invisible
  /// five-second heartbeat that also starves the queue for everything behind
  /// it.
  ///
  /// Note that [_isPermanentDbError] alone would not have been enough. The
  /// flush paths call [_ensureTableAndInsert] with `maxRetries: 1`, and
  /// [_withRetry] rethrows on its last attempt regardless of classification —
  /// so marking 22003 "permanent" changes nothing there. What matters is that
  /// the *callers* stop re-queueing it, which is what [_isDataError] gates.
  static bool _isDataError(Object e) {
    if (e is pg.ServerException) return (e.code ?? '').startsWith('22');
    return RegExp(r'\b22[0-9A-Z]{3}\b').hasMatch(e.toString());
  }

  @visibleForTesting
  static bool isDataErrorForTest(Object e) => _isDataError(e);

  /// Returns true if [e] indicates a broken network connection to the database.
  ///
  /// These errors mean the connection pool is dead and retrying on the same
  /// pool is pointless. The health monitor will detect the outage and trigger
  /// provider recreation with a fresh pool.
  static bool _isConnectionError(Object e) {
    if (e is SocketException) return true;
    final msg = e.toString();
    return msg.contains('SocketException') ||
        msg.contains('Connection reset by peer') ||
        msg.contains('Connection refused') ||
        msg.contains('Connection closed') ||
        msg.contains('broken pipe');
  }

  /// Returns true if [e] is specifically a "column does not exist" error (42703).
  static bool _isMissingColumnError(Object e) {
    if (e is pg.ServerException) return e.code == '42703';
    return e.toString().contains('42703');
  }

  // Batch write buffering
  final Map<String, List<_PendingWrite>> _writeBuffer = {};
  Timer? _flushTimer;
  bool _flushInProgress = false;
  static const _batchFlushInterval = Duration(milliseconds: 500);
  static const _maxBatchSize = 50;

  // Retry queue for failed writes (survives extended DB outages)
  final Map<String, List<_PendingWrite>> _retryQueue = {};
  bool _retryInProgress = false;

  /// The pending [_scheduleRetryFlush] wake-up, so shutdown can cancel it.
  Timer? _retryTimer;

  /// Whether a retry wake-up is still armed. A closed Database must have
  /// none: a pending [Timer] keeps the event loop alive, which is what stops
  /// a spawned isolate exiting when it is done.
  @visibleForTesting
  bool get hasPendingRetryForTest => _retryTimer != null;

  /// Set by [close]/[dispose]; stops the retry loop rescheduling itself.
  bool _shutDown = false;

  /// Rows one table may hold; [kMaxQueuedRowsPerTable] unless overridden.
  final int _maxRetryQueueSize;

  /// Rows all tables together may hold; [kMaxQueuedRowsTotal] unless overridden.
  final int _maxTotalQueuedRows;

  /// Rows discarded to keep within [_maxRetryQueueSize] / [_maxTotalQueuedRows],
  /// per table. These are rows the database never saw and never will.
  final Map<String, int> _droppedRows = {};

  /// Rows discarded because the server rejected their *content* — a SQLSTATE
  /// class 22 data exception, see [_isDataError]. Counted apart from
  /// [_droppedRows] because the causes and the remedies are different: overflow
  /// means the outage outlasted the buffer, poisoning means a value cannot go
  /// in the column it is aimed at and no amount of waiting will change that.
  final Map<String, int> _poisonedRows = {};

  /// Records rows that will never reach the database, and says so.
  ///
  /// Every discard in this class goes through here. Before, the discard sites
  /// each emitted a `logger.w` and nothing else: one warning per dropped row,
  /// at the same level as the "database is down, retrying" chatter it was
  /// buried in, with no running total and nothing an API could read. Nobody
  /// reads a log they are not already suspicious of, which is what made this a
  /// *silent* loss rather than merely a logged one.
  ///
  /// Now the count survives the outage in [getStats], the line is at error
  /// level, and it carries the running total for the table so a single line is
  /// enough to see the scale.
  void _recordDrop(String tableName, int count, String reason,
      {bool poisoned = false}) {
    if (count <= 0) return;
    final counter = poisoned ? _poisonedRows : _droppedRows;
    counter[tableName] = (counter[tableName] ?? 0) + count;
    logger.e('DATA LOST: discarded $count row(s) for "$tableName" ($reason). '
        'Total discarded for this table: ${counter[tableName]}.');
  }

  /// Rows currently held in memory and not yet written, across both queues.
  @visibleForTesting
  int get queuedRowCount =>
      _writeBuffer.values.fold<int>(0, (s, l) => s + l.length) +
      _retryQueue.values.fold<int>(0, (s, l) => s + l.length);

  /// Enforces [_maxTotalQueuedRows] by trimming the fullest retry queues first.
  ///
  /// The fullest first, so a single runaway tag is cut back before a slow one
  /// loses anything: the alternative — trimming everyone equally — punishes the
  /// tags that were behaving. Within a table it is still the oldest rows that
  /// go, for the same reason as everywhere else here.
  void _enforceGlobalCap() {
    var total = queuedRowCount;
    if (total <= _maxTotalQueuedRows) return;
    final byTable = _retryQueue.entries
        .where((e) => e.value.isNotEmpty)
        .toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    for (final entry in byTable) {
      if (total <= _maxTotalQueuedRows) break;
      final queue = entry.value;
      // Never take a table below the runner-up's length in one step, so the
      // trimming spreads across the offenders instead of gutting one.
      final excess = total - _maxTotalQueuedRows;
      final take = excess < queue.length ? excess : queue.length;
      queue.sort((a, b) => a.seq.compareTo(b.seq));
      queue.removeRange(0, take);
      total -= take;
      _recordDrop(entry.key, take,
          'total queued rows across all tables exceeded $_maxTotalQueuedRows');
    }
  }

  Future<void> open() async {
    try {
      await db.open();
    } catch (e) {
      throw DatabaseException('Failed to open database: $e');
    }
  }

  /// Installs [retention] for [tableName], unless [tableName] is one the
  /// retention machinery may never touch.
  ///
  /// This method exists for time-series: a collected tag's table is bounded by
  /// dropping chunks older than the policy. The audit trail is the opposite
  /// kind of table — append-only, never pruned — and if it were ever swept by
  /// this the trail would be worthless, which is the one failure mode an audit
  /// trail cannot recover from.
  ///
  /// The name arriving here is a free string: the single call site is
  /// `collector.dart`, passing `entry.name ?? entry.key` from the collector
  /// config. So a test asserting that today's config *happens* not to name
  /// `audit_entry` would hold only until somebody named a key that. Refusing
  /// here is what makes it structural, and refusing at this point rather than
  /// deeper is deliberate: [_applyRetentionPolicy] is also reachable from
  /// [_createTimeseriesTable], but that path is gated on
  /// `retentionPolicies.containsKey`, so keeping the name out of the map keeps
  /// it out of every path.
  ///
  /// It refuses rather than throws, following [_applyRetentionPolicy]
  /// immediately below: a misconfigured collect entry must not stop the
  /// collector starting, and a table with no retention policy simply keeps
  /// everything — the safe direction to fail in.
  Future<void> registerRetentionPolicy(
      String tableName, RetentionPolicy retention) async {
    if (kRetentionExemptTables.contains(tableName)) {
      logger.e('Retention policy for "$tableName" refused: it is append-only '
          'and never pruned, and this machinery deletes rows. No policy has '
          'been installed and none ever will be. If a collected key is named '
          '"$tableName", rename it — the collector config, not this guard, is '
          'what needs fixing.');
      return;
    }
    retentionPolicies[tableName] = retention;
    // We will actually create the table when the first data point is inserted,
    // because we need to know the type of the value column beforehand
    try {
      if (await db.tableExists(tableName)) {
        final currentRetention = await db.getRetentionPolicy(tableName);
        if (currentRetention != retention) {
          await _applyRetentionPolicy(tableName, retention);
        }
      }
    } catch (e) {
      logger.w(
          'Could not check/update retention policy for $tableName (DB may be down): $e');
      // Will be applied when table is created during first insert
    }
  }

  /// Installs [retention], unless doing so would delete the table's history.
  ///
  /// A refusal is logged at error level and swallowed. Swallowing is the point:
  /// the alternative outcomes are both worse. Letting it through deletes the
  /// history; letting it propagate out of [_createTimeseriesTable] would abort
  /// the table creation and the tag would record nothing at all. A table with
  /// no retention policy simply keeps everything, which is the safe direction
  /// to fail in, and the error line says so in terms an operator can act on.
  Future<void> _applyRetentionPolicy(
      String tableName, RetentionPolicy retention) async {
    if (!retention.isUsable) {
      logger.e('Retention policy for "$tableName" rejected: dropAfter is '
          '${retention.dropAfter}, which is under $kMinRetentionDuration and '
          'would drop the table\'s history rather than bound it. No policy has '
          'been installed, so "$tableName" now keeps its data indefinitely. '
          'Fix the retention setting for this key (1..$kMaxRetentionDays days).');
      return;
    }
    await db.updateRetentionPolicy(tableName, retention);
  }

  // Track tables that need creation (when DB was down during first insert)
  final Set<String> _pendingTableCreation = {};

  /// Tables we have already complained about being untypeable, so a tag that
  /// is null for an hour produces one line rather than one per sample.
  final Set<String> _warnedUntypeable = {};

  /// Whether [value] carries enough information to give a column a type.
  ///
  /// Null does not. [postgresTypeFor] answers TEXT for it, which is a guess
  /// dressed as an answer: the column is created TEXT, and Postgres does not
  /// then reject the doubles that follow — it coerces them, so the table
  /// records '42.5' as a string for the rest of its life with nothing in the
  /// logs to say so. Charts get a String where they expect a num, and
  /// [AppDatabase.queryTimeseriesDataDownsampled] silently falls back to the
  /// raw query because `text` is in neither of its numeric type sets.
  ///
  /// A struct is typeable when at least one member is, since the members that
  /// are not can be left out of the CREATE and arrive later through schema
  /// evolution, typed from a value that actually has one.
  static bool _canInferType(dynamic value) {
    if (value == null) return false;
    if (value is Map<String, dynamic>) {
      return value.values.any((v) => v != null);
    }
    return true;
  }

  /// Insert a time-series data point (buffered for batch writes)
  Future<void> insertTimeseriesData(
      String tableName, DateTime time, dynamic value) async {
    if (tableName.isEmpty) {
      throw ArgumentError('Table name cannot be empty');
    }

    // Try to ensure table exists, but don't fail if DB is unavailable
    if (!_writeBuffer.containsKey(tableName) &&
        !_pendingTableCreation.contains(tableName)) {
      try {
        if (!await db.tableExists(tableName)) {
          // A sample that cannot type the table is dropped here rather than
          // buffered. Buffering it would only move the decision downstream:
          // the table still would not exist, the insert would fail 42P01,
          // `_isPermanentDbError` would re-raise it, and it would be retried
          // every five seconds forever — strictly worse than the TEXT column
          // this guard exists to prevent. Dropping is also the honest answer.
          // A null tells us the value is absent; it does not tell us what the
          // value would have been, and no column type can be built from it.
          if (!_canInferType(value)) {
            if (_warnedUntypeable.add(tableName)) {
              logger.w('$tableName: first sample is null, so there is nothing '
                  'to infer a column type from. Skipping samples until a '
                  'non-null value arrives.');
            }
            return;
          }
          await _tryToCreateTimeseriesTable(tableName, value);
        }
      } catch (e) {
        logger.w(
            'Could not verify table $tableName exists (DB may be down), will retry: $e');
        _pendingTableCreation.add(tableName);
      }
    }

    // Always add to buffer, even if DB is down
    final buffer = _writeBuffer.putIfAbsent(tableName, () => []);
    buffer.add(_PendingWrite(time, value));

    // Enforce max queue size across writeBuffer + retryQueue (drop oldest)
    final retryQueue = _retryQueue[tableName] ?? [];
    final totalPending = buffer.length + retryQueue.length;
    if (totalPending > _maxRetryQueueSize) {
      // Drop from retryQueue first (oldest), then from buffer
      if (retryQueue.isNotEmpty) {
        final dropped = retryQueue.removeAt(0);
        _recordDrop(tableName, 1,
            'queue full at $_maxRetryQueueSize rows; oldest was ${dropped.time}');
      } else if (buffer.length > 1) {
        final dropped = buffer.removeAt(0);
        _recordDrop(tableName, 1,
            'queue full at $_maxRetryQueueSize rows; oldest was ${dropped.time}');
      }
    }

    // Flush immediately if batch size reached
    if (_writeBuffer[tableName]!.length >= _maxBatchSize) {
      final writes = _writeBuffer[tableName]!;
      _writeBuffer[tableName] = [];

      _writeCount++;
      _totalWriteTime.start();

      try {
        await _ensureTableAndInsert(tableName, writes, maxRetries: 1);
      } catch (e) {
        _totalWriteTime.stop();
        _handleFailedBatch(tableName, writes, e);
        return;
      }

      _totalWriteTime.stop();
    }
  }

  /// Ensure table exists and insert rows.
  /// Handles schema evolution: if the OPC UA struct gained new fields since the
  /// table was created, adds the missing columns via ALTER TABLE and retries.
  ///
  /// [maxRetries] controls how many times transient errors are retried.
  /// Use a low value (0–1) in flush paths that already have higher-level retry
  /// (via [_queueForRetry]) to avoid blocking the data pipeline for tens of
  /// seconds during a sustained DB outage.
  Future<void> _ensureTableAndInsert(
      String tableName, List<_PendingWrite> writes,
      {int maxRetries = 5}) async {
    // Create table if it was pending
    if (_pendingTableCreation.contains(tableName)) {
      if (!await db.tableExists(tableName)) {
        // The same rule as the fast path in [insertTimeseriesData], applied
        // to a batch: type the table from the first write that can type it,
        // not blindly from the first write. A database that was down while a
        // tag was null gets here with nulls at the head of the batch, and
        // `writes.first` would pick one of them.
        final typeable =
            writes.where((w) => _canInferType(w.value)).firstOrNull;
        if (typeable == null) {
          if (_warnedUntypeable.add(tableName)) {
            logger.w('$tableName: every buffered sample is null, so there is '
                'nothing to infer a column type from. Dropping '
                '${writes.length} sample(s) until a non-null value arrives.');
          }
          // Dropped, not re-queued: re-queueing would retry the same
          // untypeable batch every five seconds until it overflowed.
          return;
        }
        await _tryToCreateTimeseriesTable(tableName, typeable.value);
      }
      _pendingTableCreation.remove(tableName);
    }
    final rows = writes.map((w) => w.toMap()).toList();
    try {
      await _withRetry(() => db.tableInsertBatch(tableName, rows),
          maxRetries: maxRetries);
    } catch (e) {
      if (!_isMissingColumnError(e)) rethrow; // 42703 = undefined_column
      await _addMissingColumn(tableName, e, rows);
      // Retry once — any further new columns will be caught next flush cycle
      await db.tableInsertBatch(tableName, rows);
    }
  }

  /// Parses the column name from a PostgreSQL 42703 error and adds it to the table.
  /// Accepts both [pg.ServerException] (direct mode) and DriftRemoteException
  /// (isolate mode) — both contain the column name in their string representation.
  Future<void> _addMissingColumn(
      String tableName, Object error, List<Map<String, dynamic>> rows) async {
    final errorStr =
        error is pg.ServerException ? error.message : error.toString();
    final match = RegExp(r'column "([^"]+)"').firstMatch(errorStr);
    if (match == null) {
      logger.e('Could not parse missing column name from: $errorStr');
      throw DatabaseException(
          'Schema evolution failed: cannot parse column name from "$errorStr"');
    }
    final colName = match.group(1)!;
    // Find a non-null value for this column across all rows to infer its type
    dynamic colValue;
    for (final row in rows) {
      if (row[colName] != null) {
        colValue = row[colName];
        break;
      }
    }
    if (colValue == null) {
      // Every row is null for a column that does not exist yet. Adding it
      // would mean typing it from a null — the same TEXT guess this change
      // exists to remove — and refusing outright would fail the same 42703
      // on the caller's retry, forever. Drop the key instead: a null in a
      // column that does not exist carries no information, and the column
      // will be created properly by the first batch that has a real value.
      for (final row in rows) {
        row.remove(colName);
      }
      logger.i('Schema evolution: "$colName" is null in every row of this '
          'batch, so there is no type to give it; omitting it from the '
          'insert until a batch carries a value');
      return;
    }
    final colType = postgresTypeFor(colValue);
    final quotedTable = tableName.replaceAll('"', '""');
    final quotedCol = colName.replaceAll('"', '""');
    logger.i(
        'Schema evolution: adding column "$colName" ($colType) to "$tableName"');
    await db.customStatement(
        'ALTER TABLE "$quotedTable" ADD COLUMN IF NOT EXISTS "$quotedCol" $colType');
  }

  /// Get performance statistics
  ///
  /// This used to report only what went well — writes and waits — which is why
  /// an outage that discarded two thirds of a tag's samples was invisible from
  /// the outside. The `dropped_*`, `poisoned_*` and `queued_*` entries are the
  /// other half of the picture: what was thrown away, per table, and how close
  /// the buffers are to throwing away more.
  Map<String, dynamic> getStats() {
    final uptime = _totalWriteTime.elapsed.inMilliseconds > 0
        ? _totalWriteTime.elapsed.inSeconds
        : 1;
    return {
      'total_writes': _writeCount,
      'writes_per_sec': _writeCount / uptime,
      'total_waits': _waitCount,
      'avg_wait_ms':
          _waitCount > 0 ? _totalWaitTime.elapsedMilliseconds / _waitCount : 0,
      'total_write_time_ms': _totalWriteTime.elapsedMilliseconds,
      'avg_write_ms': _writeCount > 0
          ? _totalWriteTime.elapsedMilliseconds / _writeCount
          : 0,
      // Rows discarded because a queue filled up during an outage.
      'dropped_rows': _droppedRows.values.fold<int>(0, (s, n) => s + n),
      'dropped_rows_by_table': Map<String, int>.unmodifiable(_droppedRows),
      // Rows discarded because the server rejected their contents.
      'poisoned_rows': _poisonedRows.values.fold<int>(0, (s, n) => s + n),
      'poisoned_rows_by_table': Map<String, int>.unmodifiable(_poisonedRows),
      // How full the buffers are right now — the early warning for the above.
      'queued_rows': queuedRowCount,
      'queued_rows_by_table': <String, int>{
        for (final t in {..._writeBuffer.keys, ..._retryQueue.keys})
          t: (_writeBuffer[t]?.length ?? 0) + (_retryQueue[t]?.length ?? 0),
      },
      'max_queued_rows_per_table': _maxRetryQueueSize,
      'max_queued_rows_total': _maxTotalQueuedRows,
    };
  }

  /// Reset performance statistics
  ///
  /// Deliberately does *not* clear the drop counters. They are a record of data
  /// that no longer exists anywhere; a stats reset is a UI convenience and must
  /// not be able to erase the evidence of a loss.
  void resetStats() {
    _writeCount = 0;
    _waitCount = 0;
    _totalWaitTime.reset();
    _totalWriteTime.reset();
  }

  /// Start the periodic batch flush timer
  void _startBatchFlushTimer() {
    _flushTimer = Timer.periodic(_batchFlushInterval, (_) async {
      await _flushAllBatches();
    });
  }

  /// Flush all pending writes to the database
  Future<void> _flushAllBatches() async {
    if (_writeBuffer.isEmpty) return;

    if (_flushInProgress) {
      final pendingCount =
          _writeBuffer.values.fold<int>(0, (sum, list) => sum + list.length);
      logger.w(
          'Flush already in progress, $pendingCount items waiting - not keeping up with data rate');
      return;
    }

    _flushInProgress = true;

    // Snapshot the current buffer and clear it
    final batchesToFlush = Map<String, List<_PendingWrite>>.from(_writeBuffer);
    _writeBuffer.clear();

    // Flush each table's batch
    try {
      for (final entry in batchesToFlush.entries) {
        final tableName = entry.key;
        final writes = entry.value;
        if (writes.isEmpty) continue;

        try {
          _writeCount++;
          _totalWriteTime.start();

          await _ensureTableAndInsert(tableName, writes, maxRetries: 1);

          _totalWriteTime.stop();
        } catch (e) {
          _totalWriteTime.stop();
          _handleFailedBatch(tableName, writes, e);
        }
      }
    } finally {
      _flushInProgress = false;
    }
  }

  /// Flush all pending writes immediately (useful for tests)
  Future<void> flush() => _flushAllBatches();

  /// Queue failed writes for later retry (drops oldest if queue full).
  ///
  /// When multiple concurrent flushes fail, the order they call this method is
  /// non-deterministic. To always drop the globally oldest data regardless of
  /// call order, items are sorted by monotonic sequence number before trimming.
  /// (Sorting by timestamp alone is non-deterministic on Windows where
  /// DateTime.now() has ~15 ms resolution and Dart's List.sort is not stable.)
  void _queueForRetry(String tableName, List<_PendingWrite> writes) {
    final queue = _retryQueue.putIfAbsent(tableName, () => []);
    queue.addAll(writes);
    if (queue.length > _maxRetryQueueSize) {
      queue.sort((a, b) => a.seq.compareTo(b.seq));
      final overflow = queue.length - _maxRetryQueueSize;
      queue.removeRange(0, overflow);
      _recordDrop(tableName, overflow,
          'retry queue full at $_maxRetryQueueSize rows');
    }
    _enforceGlobalCap();
    _scheduleRetryFlush();
  }

  /// Decides what to do with a batch whose insert failed, and does it.
  ///
  /// A data exception ([_isDataError]) is the batch's own fault and cannot be
  /// cured by retrying, so it is dropped here and counted. Anything else is
  /// assumed to be the database's fault — down, restarting, out of connections
  /// — and goes back on the retry queue to be tried again when it recovers.
  void _handleFailedBatch(
      String tableName, List<_PendingWrite> writes, Object error) {
    if (_isDataError(error)) {
      _recordDrop(
          tableName,
          writes.length,
          'the server rejected the contents of this batch and always will: '
              '$error. A counter that has outgrown an INTEGER column is the '
              'usual cause; widen it with ALTER TABLE "$tableName" ALTER COLUMN '
              '<column> TYPE BIGINT',
          poisoned: true);
      return;
    }
    logger.w(
        'Batch failed for $tableName, queuing ${writes.length} rows for retry: '
        '$error');
    _queueForRetry(tableName, writes);
  }

  /// Schedule periodic retry of queued writes
  void _scheduleRetryFlush() {
    if (_shutDown || _retryInProgress || _retryQueue.isEmpty) return;
    _retryInProgress = true;

    // A Timer, not a bare Future.delayed: a closed Database must be able to
    // stop this. The loop re-queues on failure and re-schedules itself, so
    // without a handle it outlives the object that owns it -- and every
    // config reload that rebuilds the Database adds another immortal copy,
    // each holding its whole retry queue. A killed acquisition isolate
    // leaves one of these in the supervisor's process.
    _retryTimer = Timer(const Duration(seconds: 5), () async {
      _retryTimer = null;
      if (_shutDown) {
        _retryInProgress = false;
        return;
      }
      // Snapshot and clear
      final batch = Map<String, List<_PendingWrite>>.from(_retryQueue);
      _retryQueue.clear();

      for (final entry in batch.entries) {
        final tableName = entry.key;
        final writes = entry.value;
        if (writes.isEmpty) continue;

        try {
          await _ensureTableAndInsert(tableName, writes, maxRetries: 1);
          logger.i(
              'Retry flush succeeded for $tableName: ${writes.length} items');
        } catch (e) {
          // Still failing — re-queue (drops oldest if full), unless the batch
          // itself is the problem, in which case re-queueing is the infinite
          // loop this method used to run.
          _handleFailedBatch(tableName, writes, e);
        }
      }

      _retryInProgress = false;

      // Schedule another flush if items remain
      if (_retryQueue.isNotEmpty) {
        final total =
            _retryQueue.values.fold<int>(0, (sum, list) => sum + list.length);
        logger.w('Retry queue: $total items still pending');
        _scheduleRetryFlush();
      }
    });
  }

  /// Dispose resources - flushes pending data before shutdown
  Future<void> dispose() async {
    _shutDown = true;
    _flushTimer?.cancel();
    _retryTimer?.cancel();
    _retryTimer = null;
    _healthTimeoutTimer?.cancel();
    await _healthSub?.cancel();
    await _connectionStateController.close();
    // Attempt to flush any remaining data
    try {
      await _flushAllBatches();
    } catch (e) {
      logger.w('Failed to flush remaining data on dispose: $e');
    }
  }

  // Performance instrumentation
  int _writeCount = 0;
  int _waitCount = 0;
  final Stopwatch _totalWaitTime = Stopwatch();
  final Stopwatch _totalWriteTime = Stopwatch();
  Future<Map<String, List<TimeseriesData<dynamic>>>>
      queryTimeseriesDataMultiple(List<String> tableNames, DateTime to,
          {String? orderBy = 'time ASC', DateTime? from}) async {
    Map<String, List<String>> tapleMap = {};
    for (final tableName in tableNames) {
      tapleMap[tableName] = ['value', 'time'];
    }
    final where = from != null
        ? r'time >= $1::timestamptz AND time <= $2::timestamptz'
        : r'time >= $1::timestamptz';
    final whereArgs = from != null
        ? [from.toUtc().toIso8601String(), to.toUtc().toIso8601String()]
        : [to.toUtc().toIso8601String()];
    final rows = await db.tableQueryMultiple(tapleMap,
        where: where, whereArgs: whereArgs, orderBy: orderBy);
    final map = Map<String, List<TimeseriesData<dynamic>>>();
    for (final row in rows) {
      final time = row.data['time'];
      if (time == null) continue;
      final d = row.data;
      final nonNullTuples =
          d.entries.where((e) => e.value != null && e.key != 'time').toList();
      for (final tuple in nonNullTuples) {
        if (!map.containsKey(tuple.key)) {
          map[tuple.key] = [];
        }
        map[tuple.key]!.add(TimeseriesData(tuple.value, time));
      }
    }
    return map;
  }

  /// Query time-series data with performance analysis
  Future<List<TimeseriesData<dynamic>>> queryTimeseriesData(
      String tableName, DateTime to,
      {String? orderBy = 'time ASC', DateTime? from}) async {
    // final totalStart = DateTime.now();
    // print('🔍 queryTimeseriesData: Starting query for table $tableName');
    // print('📅 queryTimeseriesData: Querying since $since');

    // // Analyze table performance first
    // await db.analyzeTablePerformance(tableName);

    late final List<QueryRow> result;

    // final queryStart = DateTime.now();
    if (from != null) {
      final startTime = from.isBefore(to) ? from : to;
      final endTime = from.isBefore(to) ? to : from;
      // If from is provided, we need to query from that time
      // We need to query from the time of the first data point in the table
      // Use ISO8601 strings for PostgreSQL timestamptz compatibility
      result = await db.tableQuery(tableName,
          where: r'time >= $1::timestamptz AND time <= $2::timestamptz',
          whereArgs: [
            startTime.toUtc().toIso8601String(),
            endTime.toUtc().toIso8601String()
          ],
          orderBy: orderBy);
    } else {
      // Use ISO8601 string for PostgreSQL timestamptz compatibility
      result = await db.tableQuery(tableName,
          where: r'time >= $1::timestamptz',
          whereArgs: [to.toUtc().toIso8601String()],
          orderBy: orderBy);
    }

    // final queryDuration = DateTime.now().difference(queryStart);
    // print(
    //     '⏱️  queryTimeseriesData: Database query took ${queryDuration.inMilliseconds}ms, returned ${result.length} rows');

    // final processStart = DateTime.now();
    if (result.isEmpty) {
      // An empty window is ordinary -- a chart scrolled past the start of the
      // data does it on every frame of the scroll -- so this is debug, not a
      // pair of unfilterable prints.
      logger.d('queryTimeseriesData: no results for $tableName '
          '(from=${from?.toUtc().toIso8601String()} '
          'to=${to.toUtc().toIso8601String()})');
      return [];
    }

    if (result.first.data.containsKey('time')) {
      final processed = result.map((row) {
        // Read time as raw value - PostgreSQL returns DateTime directly
        final rawTime = row.data['time'];
        final DateTime time;
        if (rawTime is DateTime) {
          time = rawTime;
        } else if (rawTime is String) {
          time = DateTime.parse(rawTime);
        } else {
          throw DatabaseException(
              'Unexpected time format: ${rawTime.runtimeType}');
        }
        if (row.data.length == 2 && row.data.containsKey('value')) {
          return TimeseriesData(row.data['value'], time);
        }
        row.data.remove('time');
        return TimeseriesData(row.data, time);
      }).toList();

      // final processDuration = DateTime.now().difference(processStart);
      // final totalDuration = DateTime.now().difference(totalStart);
      // print(
      //     '⏱️  queryTimeseriesData: Data processing took ${processDuration.inMilliseconds}ms');
      // print(
      //     '⏱️  queryTimeseriesData: Total operation took ${totalDuration.inMilliseconds}ms');
      return processed;
    }

    throw DatabaseException('Time column not found in table $tableName');
  }

  /// Postgres type of a collected table's `value` column.
  ///
  /// Deliberately **not** cached, though it costs an `information_schema`
  /// round trip (~2 ms) per downsampled series. A cache was built here and
  /// removed: the type is only stable while the table is, and a retype drops
  /// and recreates it. A remembered type that outlives its table fails in two
  /// different ways — over-claiming makes the statement error, under-claiming
  /// silently drops to the raw fallback and stops downsampling for the rest of
  /// the session with no error at all. Each needed its own fix and CI caught
  /// both.
  ///
  /// The saving did not justify that. Within a single History View refresh
  /// every series is a different table, so each is looked up once either way;
  /// the cache only paid off on repeat queries. If this is revisited, the
  /// invalidation story has to come first.
  Future<ValueColumnType?> _valueColumnType(String tableName) async {
    final typeResult = await db.customSelect(
      r'''
      SELECT data_type, udt_name
      FROM information_schema.columns
      WHERE table_name = $1 AND column_name = 'value'
      ''',
      variables: [Variable.withString(tableName)],
    ).get();

    if (typeResult.isEmpty) return null;

    return ValueColumnType(
      typeResult.first.data['data_type'] as String,
      typeResult.first.data['udt_name'] as String,
    );
  }

  /// Query time-series data with server-side downsampling using TimescaleDB time_bucket().
  ///
  /// For each bucket, returns 3 points: min value, max value, and last value,
  /// preserving spikes and step changes while reducing density.
  ///
  /// The bucket interval is auto-calculated from the time range and [maxPoints]:
  ///   bucketInterval = (to - from) / (maxPoints / 3)
  ///
  /// Supports scalar numeric columns (DOUBLE PRECISION, INTEGER) and
  /// numeric array columns (DOUBLE PRECISION[]). For unsupported column types
  /// (boolean, text, jsonb), falls back to the raw query.
  Future<List<TimeseriesData<dynamic>>> queryTimeseriesDataDownsampled(
      String tableName, DateTime from, DateTime to,
      {int maxPoints = 1000}) async {
    final startTime = from.isBefore(to) ? from : to;
    final endTime = from.isBefore(to) ? to : from;
    final rangeMs = endTime.difference(startTime).inMilliseconds;

    // If the range is tiny, just return raw data
    if (rangeMs <= 0) {
      return queryTimeseriesData(tableName, endTime, from: startTime);
    }

    // Each bucket produces 3 points (min, max, last), so we need maxPoints/3 buckets
    final numBuckets = (maxPoints / 3).floor();
    if (numBuckets <= 0) {
      return queryTimeseriesData(tableName, endTime, from: startTime);
    }

    final bucketMs = (rangeMs / numBuckets).ceil();
    final intervalStr = '$bucketMs milliseconds';
    final quotedTable = tableName.replaceAll('"', '""');

    // Detect column type to choose the right SQL.
    final valueType = await _valueColumnType(tableName);
    if (valueType == null) {
      return queryTimeseriesData(tableName, endTime, from: startTime);
    }

    final dataType = valueType.dataType;
    final udtName = valueType.udtName;
    final isArray = dataType == 'ARRAY' || udtName.startsWith('_');

    // Only support numeric types
    const scalarNumericTypes = {
      'double precision',
      'integer',
      'bigint',
      'real',
      'smallint',
      'numeric'
    };
    const arrayNumericUdts = {
      '_float8',
      '_float4',
      '_int4',
      '_int8',
      '_int2',
      '_numeric'
    };
    if (!scalarNumericTypes.contains(dataType) &&
        !arrayNumericUdts.contains(udtName)) {
      return queryTimeseriesData(tableName, endTime, from: startTime);
    }

    final sql =
        buildDownsampleSql(quotedTable: quotedTable, isArray: isArray);

    final result = await db.customSelect(sql, variables: [
      Variable.withString(intervalStr),
      Variable.withString(startTime.toUtc().toIso8601String()),
      Variable.withString(endTime.toUtc().toIso8601String()),
    ]).get();

    if (result.isEmpty) {
      return [];
    }

    return result.map((row) {
      final rawTime = row.data['time'];
      final DateTime time;
      if (rawTime is DateTime) {
        time = rawTime;
      } else if (rawTime is String) {
        time = DateTime.parse(rawTime);
      } else {
        throw DatabaseException(
            'Unexpected time format: ${rawTime.runtimeType}');
      }
      return TimeseriesData(row.data['value'], time);
    }).toList();
  }

  /// columns: {tableName: columnName}
  Future<void> createView(String viewName, Map<String, String> columns) async {
    if (columns.isEmpty) {
      throw DatabaseException('createView("$viewName"): columns map is empty');
    }

    // Quote identifiers safely
    String q(String ident) => '"${ident.replaceAll('"', '""')}"';

    final qView = q(viewName);
    final tables = columns.keys.toList();

    // Build alias map t0, t1, ...
    final aliasFor = <String, String>{};
    for (var i = 0; i < tables.length; i++) {
      aliasFor[tables[i]] = 't$i';
    }

    // CTE: all distinct timestamps across all tables
    final allTimes =
        tables.map((t) => 'SELECT time FROM ${q(t)}').join('\nUNION\n');

    // SELECT list: time + requested columns, aliased as table_col
    final selectCols = <String>['at.time AS "time"'];
    for (final t in tables) {
      final alias = aliasFor[t]!;
      final col = columns[t]!;
      final outAlias = '${t}_${col}';
      selectCols.add('$alias.${q(col)} AS ${q(outAlias)}');
    }

    // LEFT JOIN each table to the all_times spine
    final joins = tables.map((t) {
      final alias = aliasFor[t]!;
      return 'LEFT JOIN ${q(t)} $alias ON $alias.time = at.time';
    }).join('\n');

    final isPg = db.postgres; // PgDatabase vs. Native (sqlite)
    final createKeyword = isPg ? 'MATERIALIZED VIEW' : 'VIEW';
    final dropStmt = isPg
        ? 'DROP MATERIALIZED VIEW IF EXISTS $qView CASCADE;'
        : 'DROP VIEW IF EXISTS $qView CASCADE;';

    final createSql = '''
CREATE $createKeyword $qView AS
WITH all_times AS (
  $allTimes
)
SELECT
  ${selectCols.join(',\n  ')}
FROM all_times at
$joins
ORDER BY at.time;
''';

    // Execute (separate statements for compatibility)
    await db.customStatement(dropStmt);
    await db.customStatement(createSql);

    // Postgres-only: add a UNIQUE index on time to allow REFRESH CONCURRENTLY
    if (isPg) {
      final idxName = ('${viewName}_time_uidx'
              .toLowerCase()
              .replaceAll(RegExp(r'[^a-z0-9_]+'), '_'))
          .replaceAll(RegExp(r'_+'), '_');
      await db.customStatement(
          'CREATE UNIQUE INDEX IF NOT EXISTS $idxName ON $qView ("time");');
    }
  }

  /// Count time-series data points in regular time intervals
  /// Returns a map of counts for each interval, from oldest to newest {bucketStart: count, ...}
  /// [interval] is the duration of each bucket
  /// [howMany] is the number of buckets to count
  /// [since] is the end time for the buckets (defaults to now)
  Future<Map<DateTime, int>> countTimeseriesDataMultiple(
      String tableName, Duration interval, int howMany,
      {DateTime? since}) async {
    if (howMany <= 0) {
      return {};
    }

    final endTime = since ?? DateTime.now();
    final bucketStarts = <DateTime>[];
    final bucketEnds = <DateTime>[];

    // Generate time buckets from oldest to newest
    for (int i = howMany - 1; i >= 0; i--) {
      final bucketStart = endTime.subtract(interval * (i + 1));
      final bucketEnd = endTime.subtract(interval * i);
      bucketStarts.add(bucketStart);
      bucketEnds.add(bucketEnd);
    }

    // Build a UNION query for the specific number of intervals
    final unionQueries = <String>[];
    for (int i = 0; i < howMany; i++) {
      final startTime = bucketStarts[i].toIso8601String();
      final endTime = bucketEnds[i].toIso8601String();
      unionQueries.add('''
          SELECT COUNT(*) as count FROM "$tableName"
          WHERE time >= '$startTime' AND time < '$endTime'
        ''');
    }
    final sql = unionQueries.join(' UNION ALL ');

    final result = await db.customSelect(sql).get();

    // Extract counts from result rows
    final counts = <DateTime, int>{};
    for (int i = 0; i < result.length; i++) {
      counts[bucketStarts[i]] = result[i].read<int>('count');
    }
    return counts;
  }

  Future<void> _createTimeseriesTable(
      String tableName, RetentionPolicy retention, dynamic value) async {
    if (value is Map<String, dynamic>) {
      // Create table with columns for each key in the complex object
      await _createComplexTimeseriesTable(tableName, retention, value);
    } else {
      String valueType = postgresTypeFor(value);
      await db
          .createTable(tableName, {'value': valueType, 'time': 'TIMESTAMPTZ'});
      await _applyRetentionPolicy(tableName, retention);
    }
  }

  /// Create table for complex objects with separate columns for each key
  Future<void> _createComplexTimeseriesTable(String tableName,
      RetentionPolicy retention, Map<String, dynamic> value) async {
    Map<String, String> columns = {};

    for (final entry in value.entries) {
      final columnName = entry.key;
      final columnValue = entry.value;
      // A member that is null in the sample we happen to be creating from
      // gets no column now. Giving it one would mean typing it TEXT from a
      // null and then coercing every real value into a string forever; left
      // out, the first sample that carries a value adds it through
      // [_addMissingColumn] with the type that value actually has.
      if (columnValue == null) continue;
      final columnType = postgresTypeFor(columnValue);
      columns[columnName] = columnType;
    }

    await db.createTable(tableName, {'time': 'TIMESTAMPTZ', ...columns});
    await _applyRetentionPolicy(tableName, retention);
  }

  /// Get PostgreSQL type for a value
  ///
  /// A Dart `int` is 64-bit and is given a 64-bit column. It used to be given
  /// `INTEGER`, which is int4, and the mismatch was permanent rather than
  /// merely wrong: a UDINT/DWORD/ULINT counter or an OPC UA UInt32/UInt64 that
  /// crosses 2^31 makes every insert for that tag fail `22003: integer out of
  /// range`, and a counter does not come back down. The tag recorded nothing
  /// again, ever, and took the well-behaved rows batched alongside it with it.
  ///
  /// Note this only helps tables created from here on. A table that is already
  /// `INTEGER` in the field stays that way; what saves those is that the batch
  /// now fails visibly (see [_isDataError]) instead of cycling in silence, so
  /// the column can be widened by hand.
  @visibleForTesting
  static String postgresTypeFor(dynamic value) {
    if (value is List) {
      // Infer array type from first element, default to TEXT[]
      if (value.isEmpty) {
        // todo this is error prone, I think we should just skip it, and create it by altering the table afterwards when there is a value
        return 'TEXT[]';
      }
      final first = value.first;
      switch (first) {
        case int():
          return 'BIGINT[]';
        case double():
          return 'DOUBLE PRECISION[]';
        case bool():
          return 'BOOLEAN[]';
        case String():
          return 'TEXT[]';
        case Duration():
          return 'INTERVAL[]';
        case DateTime():
          return 'TIMESTAMPTZ[]';
        default:
          return 'JSONB[]'; // fallback for complex/nested objects
      }
    }
    switch (value) {
      case int():
        return 'BIGINT';
      case double():
        return 'DOUBLE PRECISION';
      case bool():
        return 'BOOLEAN';
      case String():
        return 'TEXT';
      case null:
        return 'TEXT'; // Allow NULL values, TODO: I DONT LIKE THIS
      case Duration():
        return 'INTERVAL';
      case DateTime():
        return 'TIMESTAMPTZ';
      default:
        return 'JSONB'; // For complex nested objects
    }
  }

  /// Returns true if the table was created successfully, false if it already exists or policy is missing
  Future<bool> _tryToCreateTimeseriesTable(
      String tableName, dynamic value) async {
    // Check again after waiting - table might have been created
    // if (await db.tableExists(tableName)) {
    //   return true;
    // }

    if (!retentionPolicies.containsKey(tableName)) {
      // Silent data loss: the timeseries table is never created and the
      // historian simply stops recording that tag. Worth an error, and worth
      // one that reaches the log file.
      _log.e(
          'Table $tableName does not exist, and no retention policy is set '
          '-- nothing will be recorded for it');
      return false;
    }

    // Acquire lock for this table
    final completer = Completer<void>();
    logger.t("Lock Creating table $tableName");

    _tableCreationLocks[tableName] = completer;

    try {
      logger.t("Creating table $tableName");
      await _createTimeseriesTable(
          tableName, retentionPolicies[tableName]!, value);
    } finally {
      // Release lock
      _tableCreationLocks.remove(tableName);
      completer.complete();
    }
    return true;
  }

  /// Releases everything this object holds: its timers, the health
  /// subscription, and the pool (with its DriftIsolate) underneath.
  ///
  /// [connectWithRetry] calls this on an attempt it is throwing away, so it
  /// has to be complete. Leaving the batch flush timer running on a discarded
  /// attempt would be the same leak in a different shape.
  Future<void> close() async {
    _shutDown = true;
    _flushTimer?.cancel();
    _retryTimer?.cancel();
    _retryTimer = null;
    _healthTimeoutTimer?.cancel();
    await _healthSub?.cancel();
    if (!_connectionStateController.isClosed) {
      await _connectionStateController.close();
    }
    await db.close();
  }
}

class TimeseriesData<T> {
  final T value;
  final DateTime time;

  @override
  String toString() {
    return 'TimeseriesData(value: $value, time: $time)';
  }

  TimeseriesData(this.value, this.time);
}

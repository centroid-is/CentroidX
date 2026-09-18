/// The TimescaleDB adapter behind the [TimeseriesSink] seam — **the one file
/// in this package that knows `tfc_dart`'s `Database` exists**, which the
/// freeze suite's seam sweep enforces by counting import sites.
///
/// ## The wrap verdict, with the evidence
///
/// Phase 8 judged every incumbent on two criteria: is it testable through
/// constructor injection, and does it hold global state. `Database` passes
/// both, in favour of **wrapping**:
///
///  * *Constructor injection.* `Database(AppDatabase db, {…})`
///    (`database.dart:496-505`) takes its backend as a parameter, and
///    `AppDatabase.forTest(config, QueryExecutor)` is a public
///    `@visibleForTesting` **generative** constructor added specifically so a
///    test can subclass and override `tableExists` / `tableInsertBatch`
///    (`database_drift.dart:141-153` — its doc comment says exactly why it
///    exists). `tfc_dart`'s own `FakeWriteBackend` proves the write path is
///    unit-testable with no server anywhere, and this package's copy of it
///    drives every offline case in `timescale_sink_test.dart`.
///  * *Global state.* Three statics, none load-bearing here:
///    `Database.logger` is a `Logger`; `DatabaseConfig._configJsonCache`
///    sits only on the `fromPrefs`/SecureStorage path, which the gateway
///    never takes — its config comes from `GatewayConfig`; and
///    `_PendingWrite._nextSeq` is a monotonic counter whose whole purpose is
///    deterministic drop ordering.
///  * *What rebuilding would cost.* Type inference and the null-first-sample
///    rule (`database.dart:907-913`, `:1004-1026`), ALTER-TABLE schema
///    evolution with the null-column rule (`:1042-1082`), the BIGINT lesson
///    (`:1696-1753`), the retention clamps (`:279-319`) and per-table drop
///    accounting (`:796`, `:1085-1127`) — each with a dedicated test file
///    under `packages/tfc_dart/test/core/`. That is accumulated failure
///    knowledge with correct semantics, and unlike `StateMan` there is no
///    semantic layer above it that the relay disagrees with.
///
/// ## The retry queue is not a violation of the no-retry rule
///
/// The standing rule is *no auto-retry upstream*: a setpoint silently
/// re-applied after an operator gave up is a safety event, which is why
/// `WriteResult` has three states and readback is the only confirmation. A
/// row buffered for TimescaleDB is **not a command to the plant**. There is
/// no actuator behind it and nobody standing at a machine because of it, and
/// the failure mode of *not* retrying is the one this project actually cares
/// about: a silent hole in the history exactly across the incident somebody
/// will later be asked to explain. `Database`'s queue is bounded (10 000 rows
/// per table, 200 000 total, `database.dart:242-277`), drops oldest-first,
/// counts every drop with a reason, and `resetStats` deliberately refuses to
/// clear those counters (`:1128-1133`). The rule that applies to the
/// historian is not *no retry* — it is *no silent anything*, and this file's
/// contribution is that the counters become readable numbers in [stats]
/// rather than log lines. Do not "fix" the queue away.
///
/// ## What the wrapper refuses to inherit
///
///  1. *`connectWithRetry`'s ladder on the startup path.* It retries until it
///     succeeds — "which on a full server is never" is in its own doc — and
///     it cannot be cancelled. The connect loop here does `probe()` (bounded
///     at 5 s), then `AppDatabase.spawn`/`create` and `open()`, in a
///     background future that checks the closed flag between attempts and
///     backs off. [start] awaits none of it.
///  2. *The constructor-started flush timer.* `Database`'s constructor starts
///     a 500 ms `Timer.periodic` before the caller can say a word (`:503`,
///     `:1136-1140`). A disabled sink therefore never constructs the object
///     at all, and every test that does must `close()` in teardown. That
///     timer lives in `tfc_dart`'s `lib`, where this package's timer sweep
///     cannot see it — which is exactly why it is written down here.
///  3. *The collector's fire-and-forget insert.* `collector.dart:267` does
///     `unawaited(insertValue(value))`. This sink **awaits**
///     `insertTimeseriesData` — a buffer append in the common case — and the
///     freeze suite forbids a handlerless `unawaited(` in this directory.
///  4. *Two shutdown methods.* `dispose()` (`:1284-1298`) and `close()`
///     (`:1793-1804`) differ: only `close()` closes the pool underneath. The
///     seam exposes one method; this adapter flushes, then calls `close()`.
///
/// ## Counting honesty
///
/// [SinkStats.rowsWritten] is derived: rows handed to `Database` minus what
/// its stats still hold as queued or dropped. One corner is invisible to
/// that arithmetic: a sample skipped by the null-first-sample rule (a table
/// that does not exist yet and a value that cannot type it) is skipped by
/// `Database` without a counter. It is also the one loss that carries no
/// information — a null for a table with no type is not a datum.
library;

import 'dart:async';

import 'package:postgres/postgres.dart' as pg;
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';

import 'advisory_lock.dart';
import 'collection_config.dart';
import 'timeseries_sink.dart';

/// Produces an **opened** `Database` or throws.
///
/// The production path (used when no factory is injected) probes first, then
/// builds the backend and opens it. An injected factory replaces that path
/// wholesale — it is the unit-test seam, and what it returns is trusted to
/// be ready.
typedef SinkBackendFactory = Future<Database> Function(DatabaseConfig config);

final class TimescaleSink implements TimeseriesSink {
  TimescaleSink(
    this.config, {
    this.publisherId,
    this.useIsolate = true,
    SinkBackendFactory? backendFactory,
    Future<void> Function(Duration delay)? sleep,
  })  : _backendFactory = backendFactory,
        _sleep = sleep;

  /// The process-level decision this adapter executes. All refusals — empty
  /// prefix without soleWriter, enabled without an endpoint — happened at
  /// this object's construction; by the time a sink exists the config is
  /// coherent.
  final CollectionConfig config;

  /// Suffixed into `pg_stat_activity.application_name` via
  /// [CollectionConfig.applicationNameFor], so `SELECT application_name,
  /// count(*) FROM pg_stat_activity GROUP BY 1` names this gateway.
  final String? publisherId;

  /// `AppDatabase.spawn` (true) keeps Postgres work off the isolate the
  /// `LagMonitor` measures — the production default. Fixtures pass false for
  /// `AppDatabase.create`, the same knob shape 08-07 chose for OPC UA.
  final bool useIsolate;

  final SinkBackendFactory? _backendFactory;

  /// The between-attempt pause, injectable so tests never wait on the real
  /// ladder. The default races the delay against [close], so shutdown does
  /// not wait out a 30 s backoff.
  final Future<void> Function(Duration delay)? _sleep;

  Database? _db;
  StreamSubscription<bool>? _dbStateSub;

  /// The wrapped connection, **for reading only**, or null while the connect
  /// loop has not landed.
  ///
  /// The one seam 10-07's `TimescaleReader` reaches through, and the reason it
  /// exists is the reason it is a getter and not a constructor argument
  /// somewhere: a gateway that both historises and serves history must do both
  /// over **one** pool. A second `Database` would double this process's
  /// connection count against a plant Postgres and give 8b's `SELECT
  /// application_name, count(*) FROM pg_stat_activity GROUP BY 1` a second
  /// name to account for (T-10-28), on a server the application's own
  /// collector is also connected to.
  ///
  /// Null is a real, ordinary state and callers must handle it rather than
  /// wait on it: [start] returns immediately and the connect loop runs in the
  /// background (WR-03), so a query in that window is answered "not connected,
  /// worth retrying" — never a hang and never a refusal.
  ///
  /// **Reading only.** Nothing outside this file may insert through it or
  /// touch retention; `freeze_test.dart` sweeps `lib/src/data/` for both
  /// doors, and 8b's whole side-by-side verdict rests on the gateway's
  /// retention policies being decided in exactly one place, which is
  /// [ensureTable] above.
  Database? get database => _db;

  /// The namespace lock, held on its own out-of-pool session for the
  /// process's life (see advisory_lock.dart's doc). Null while refused or
  /// lost — and while null, nothing is inserted.
  ///
  /// **The residual window, recorded honestly (WR-02):** rows already handed
  /// to the wrapped [Database] before a lock loss sit in its bounded retry
  /// queue, and that layer's own 500 ms flush timer drains them on pool
  /// reconnect without consulting this lock — it cannot be told to wait
  /// without a second adapter under the seam. Every path THIS adapter owns
  /// (insert, [flush], the close-path flush) stands down while the lock is
  /// not provably held, so the exposure is exactly the already-queued rows,
  /// capped by the queue caps, all real samples with real timestamps; it
  /// closes when re-acquisition lands or the process stops.
  AdvisoryLock? _lock;

  /// The re-acquire loop after a lost lock session — stored like
  /// [_connecting], for the same close() reason.
  Future<void>? _reacquiring;

  /// The background connect loop, **stored rather than awaited** so [close]
  /// can wait for it instead of pulling the backend out from under an
  /// in-flight attempt (the `_reopenSessionIfNeeded` shape from 08-07).
  Future<void>? _connecting;

  bool _closed = false;
  Future<void>? _closeFuture;
  final Completer<void> _closing = Completer<void>();

  /// Rows accepted before the backend exists — but only while nobody else
  /// owns the namespace. Bounded by the config's total cap; overflow drops
  /// oldest and is counted like every other loss.
  ///
  /// A **refusal drains this pen and closes it** (WR-01): rows a refused
  /// gateway keeps are rows a takeover would replay into tables the previous
  /// holder was writing for that whole window — both writers' samples of the
  /// same keys, doubled row density across exactly the stretch somebody will
  /// later chart. Refusal and lock loss reach the same verdict: not the
  /// owner → a counted drop. The pen serves only the nobody-holds-it-yet
  /// connect window.
  final List<_PendingRow> _preBuffer = <_PendingRow>[];
  int _preDropped = 0;

  /// True from the moment a connect attempt is refused the namespace lock
  /// until an attempt acquires it. While true, nothing is penned.
  bool _lockRefused = false;

  /// Rows handed to `Database.insertTimeseriesData` without it throwing.
  int _handedOver = 0;

  /// Rows lost at the seam itself (a table name the layer below refuses).
  int _sinkDropped = 0;

  /// What the wrapped `Database` still held — queued, dropped or poisoned —
  /// at the moment [close] let go of it (IN-01). Its stats vanish with it,
  /// and without this capture a post-close [stats] read would report every
  /// row ever handed over as written, including the ones the final flush
  /// could not push. "A lost row is a counted row" has to survive shutdown,
  /// because shutdown is exactly when a post-mortem reads these numbers.
  int _lostAtClose = 0;

  String? _lastError;

  /// What has been ensured, so a repeat with the same retention issues
  /// nothing new and a (re)connect can replay the set.
  final Map<String, RetentionPolicy?> _ensured = <String, RetentionPolicy?>{};

  bool _lastConnected = false;
  final StreamController<bool> _connectedCtrl =
      StreamController<bool>.broadcast();

  /// Starts the background connect loop and returns **immediately** — a
  /// database that is down, slow or absent costs collection and nothing
  /// else, so nothing about gateway startup may wait here. Disabled means
  /// no backend is ever constructed; see the class doc's flush-timer note.
  Future<void> start() async {
    if (!config.enabled || _closed) return;
    _connecting ??= _connectLoop();
  }

  Future<void> _connectLoop() async {
    var attempt = 0;
    while (!_closed) {
      try {
        final factory = _backendFactory;
        final db = factory != null
            ? await factory(_databaseConfig())
            : await _openProduction();
        if (_closed) {
          await db.close();
          return;
        }
        _lockRefused = false;
        _adopt(db);
        try {
          await _replay(db);
        } catch (error) {
          _recordFailure('replay', error);
        }
        return;
      } catch (error) {
        if (error is AdvisoryLockRefused) {
          // WR-01: another collector owns this namespace right now, so the
          // pen holds samples of the same keys the holder is writing.
          // Replaying them after a takeover would back-fill the contested
          // window with a second writer's rows; the honest verdict is the
          // lock-loss one — counted drops, here and for every insert until
          // an attempt acquires.
          _lockRefused = true;
          _preDropped += _preBuffer.length;
          _preBuffer.clear();
        }
        _recordFailure('connect', error);
        attempt++;
        await _pause(_backoffFor(attempt));
      }
    }
  }

  /// The production path: bounded probe, then build, then open. This — not
  /// `Database.connectWithRetry` — is deliberate: that ladder retries until
  /// it succeeds and cannot be cancelled, and an attempt it abandons on a
  /// full server leaks a pool slot until the process exits.
  Future<Database> _openProduction() async {
    final dbConfig = _databaseConfig();
    await Database.probe(dbConfig);
    // Ownership before rows: the lock is taken BEFORE the pool is built, so
    // a refused gateway never holds so much as a pool slot, let alone a
    // write path. A refusal throws AdvisoryLockRefused, which the connect
    // loop records (naming the holder) and retries on the same backoff —
    // the second gateway keeps asking, and takes over the day the first
    // releases.
    _lock = await _acquireLock();
    try {
      final backend = useIsolate
          ? await AppDatabase.spawn(dbConfig)
          : await AppDatabase.create(dbConfig);
      final db = Database(
        backend,
        maxQueuedRowsPerTable: config.maxQueuedRowsPerTable,
        maxQueuedRowsTotal: config.maxQueuedRowsTotal,
      );
      try {
        await db.open();
      } catch (error) {
        // An attempt being thrown away must release everything it holds —
        // close() is complete where dispose() is not (class doc, item 4).
        await db.close();
        rethrow;
      }
      return db;
    } catch (error) {
      final lock = _lock;
      _lock = null;
      if (lock != null) await lock.release();
      rethrow;
    }
  }

  Future<AdvisoryLock> _acquireLock() {
    final endpoint = config.endpoint!;
    return AdvisoryLock.acquire(
      endpoint: pg.Endpoint(
        host: endpoint.host,
        port: endpoint.port,
        database: endpoint.database,
        username: endpoint.username,
        password: endpoint.password,
      ),
      sslMode: _sslModeFor(config.sslMode),
      applicationName: config.applicationNameFor(publisherId),
      tablePrefix: config.tablePrefix,
      connectTimeout: config.connectTimeout,
    );
  }

  /// After a lost lock session: degraded, not thrashing. Re-acquiring is
  /// resync-shaped, not a write retry — the same argument 08-07 records for
  /// the subscribe ladder — and it runs on the connect loop's own bounded
  /// backoff. Detection rides the insert path (see [insert]) because this
  /// package's timer discipline forbids a watchdog clock here; the runner
  /// inserts continuously, so silence is bounded by the sample cadence.
  Future<void> _reacquireLoop() async {
    var attempt = 0;
    while (!_closed) {
      try {
        final stale = _lock;
        _lock = null;
        if (stale != null) await stale.release();
        _lock = await _acquireLock();
        return;
      } catch (error) {
        _recordFailure('lock', error);
        attempt++;
        await _pause(_backoffFor(attempt));
      }
    }
  }

  void _adopt(Database db) {
    _db = db;
    _dbStateSub = db.connectionState.listen(
      (up) {
        _lastConnected = up;
        if (!_connectedCtrl.isClosed) _connectedCtrl.add(up);
      },
      onError: (Object _) {},
    );
  }

  /// Replays what arrived before the backend existed: the ensured tables
  /// first (so retention is registered before the first insert creates the
  /// table), then the held rows in arrival order.
  Future<void> _replay(Database db) async {
    for (final entry in _ensured.entries) {
      await _registerRetention(db, entry.key, entry.value);
    }
    while (_preBuffer.isNotEmpty) {
      final row = _preBuffer.removeAt(0);
      try {
        await db.insertTimeseriesData(row.table, row.time, row.value);
        _handedOver++;
      } catch (error) {
        _sinkDropped++;
        _recordFailure('replay', error);
      }
    }
  }

  @override
  Future<void> ensureTable(String table, RetentionPolicy? retention) async {
    if (!config.enabled || _closed) return;
    if (_ensured.containsKey(table) &&
        _sameRetention(_ensured[table], retention)) {
      return;
    }
    _ensured[table] = retention;
    final db = _db;
    if (db == null) return; // replayed when the connect loop lands
    await _registerRetention(db, table, retention);
  }

  /// A null retention means **install no policy** (the seam's contract). It
  /// is expressed as a zero-`dropAfter` policy because `Database` refuses to
  /// create a table it has no policy entry for, and `_applyRetentionPolicy`
  /// refuses to *install* anything under a minute — so the table is created,
  /// keeps everything, and no `add_retention_policy` ever runs. The safe
  /// direction to fail in, per `database.dart:866-885`.
  ///
  /// **What the catch below can and cannot see (8b-REVIEW IN-02, recorded
  /// rather than fixed):** `registerRetentionPolicy` swallows a failed
  /// check/update on an *existing* table internally (`database.dart:852-863`
  /// — catch, `logger.w`, normal return), so a transient
  /// `updateRetentionPolicy` failure leaves the old policy installed until
  /// restart and this method returns as if it succeeded. The catch here
  /// only ever fires on isolate-transport failures. A wanted-vs-confirmed
  /// split in [_ensured] would therefore confirm blindly, and verifying by
  /// reading the catalog back would add a round trip per table on the very
  /// startup path WR-03 just unblocked. The exposure is one Postgres log
  /// line wide and self-heals at the next process start; the honest fix
  /// belongs in `tfc_dart` (surface the failure), not in a wrapper
  /// pretending it can see it.
  Future<void> _registerRetention(
      Database db, String table, RetentionPolicy? retention) async {
    try {
      await db.registerRetentionPolicy(
          table, retention ?? const RetentionPolicy(dropAfter: Duration.zero));
    } catch (error) {
      _recordFailure('ensureTable', error);
    }
  }

  static bool _sameRetention(RetentionPolicy? a, RetentionPolicy? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    return a.dropAfter == b.dropAfter &&
        a.scheduleInterval == b.scheduleInterval;
  }

  @override
  Future<void> insert(String table, DateTime time, Object? value) async {
    if (!config.enabled) return;
    if (_closed) {
      // IN-01: a straggler handed to a closed sink is a lost row, and a
      // lost row is a counted row — never a silent return.
      _sinkDropped++;
      return;
    }
    final db = _db;
    if (db == null) {
      if (_lockRefused) {
        // WR-01: refused the namespace — the same verdict as a lost lock
        // session, one connect earlier. `lastError` already names the
        // holder (the one detail the redactor lets through).
        _preDropped++;
        return;
      }
      _preBuffer.add(_PendingRow(table, time, value));
      if (_preBuffer.length > config.maxQueuedRowsTotal) {
        _preBuffer.removeAt(0);
        _preDropped++;
        _lastError ??= 'collect: rows dropped while waiting for the first '
            'connection (holding pen full)';
      }
      return;
    }
    final lock = _lock;
    if (_backendFactory == null && (lock == null || !lock.isHeld)) {
      // The production path holds the namespace lock or inserts nothing.
      // A lost lock session means another gateway may own these tables
      // right now; the honest verdict for the row is a counted drop, and
      // the remedy is re-acquisition, not a buffer.
      _sinkDropped++;
      _lastError = 'collect: degraded — the collection lock session was '
          'lost; dropping rows and re-acquiring';
      _reacquiring ??= _reacquireLoop().whenComplete(() => _reacquiring = null);
      return;
    }
    try {
      await db.insertTimeseriesData(table, time, value);
      _handedOver++;
    } catch (error) {
      // The seam's contract: insert NEVER throws. A row the layer below
      // refused is a counted loss, not an exception on the value path.
      _sinkDropped++;
      _recordFailure('insert', error);
    }
  }

  @override
  Future<void> flush() async {
    final db = _db;
    if (db == null) return;
    final lock = _lock;
    if (_backendFactory == null && (lock == null || !lock.isHeld)) {
      // WR-02: the queue drains only while the namespace is provably ours.
      // Another gateway may own these tables right now; pushing the backlog
      // is two writers in one namespace, one layer below where the insert
      // guard stands. The remedy is the same one: re-acquisition.
      _reacquiring ??= _reacquireLoop().whenComplete(() => _reacquiring = null);
      return;
    }
    try {
      await db.flush();
    } catch (error) {
      _recordFailure('flush', error);
    }
  }

  @override
  Future<void> close() => _closeFuture ??= _shutdown();

  Future<void> _shutdown() async {
    _closed = true;
    if (!_closing.isCompleted) _closing.complete();
    try {
      await _connecting;
    } catch (_) {
      // The loop records its own failures; shutdown proceeds regardless.
    }
    try {
      await _reacquiring;
    } catch (_) {
      // Same: recorded where it happened.
    }
    final db = _db;
    _db = null;
    await _dbStateSub?.cancel();
    if (db != null) {
      // Flush first: close() does not (only dispose() would, and dispose()
      // leaves the pool open — the seam picked close(), so the flush is
      // this adapter's job). Unless the lock died (WR-02): a final flush
      // into a namespace another gateway may own by now is the same two-
      // writer defect, at the worst moment to create it.
      final lockAtClose = _lock;
      if (_backendFactory != null ||
          (lockAtClose != null && lockAtClose.isHeld)) {
        try {
          await db.flush();
        } catch (error) {
          _recordFailure('close', error);
        }
      }
      // IN-01: whatever the flush could not push (or the guard above kept
      // back) is about to be discarded by db.close() with its counters —
      // fold it into this adapter's own drop count while the numbers can
      // still be read.
      try {
        final dbStats = db.getStats();
        _lostAtClose = ((dbStats['queued_rows'] as int?) ?? 0) +
            ((dbStats['dropped_rows'] as int?) ?? 0) +
            ((dbStats['poisoned_rows'] as int?) ?? 0);
      } catch (error) {
        _recordFailure('close', error);
      }
      try {
        await db.close();
      } catch (error) {
        _recordFailure('close', error);
      }
    }
    final lock = _lock;
    _lock = null;
    if (lock != null) {
      try {
        await lock.release();
      } catch (error) {
        _recordFailure('close', error);
      }
    }
    await _connectedCtrl.close();
  }

  @override
  SinkStats get stats {
    final dbStats = _db?.getStats();
    final dbQueued = (dbStats?['queued_rows'] as int?) ?? 0;
    final dbDropped = ((dbStats?['dropped_rows'] as int?) ?? 0) +
        ((dbStats?['poisoned_rows'] as int?) ?? 0);
    final written = _handedOver - dbQueued - dbDropped - _lostAtClose;
    return SinkStats(
      rowsWritten: written < 0 ? 0 : written,
      rowsDropped: dbDropped + _preDropped + _sinkDropped + _lostAtClose,
      rowsQueued: dbQueued + _preBuffer.length,
      lastError: _lastError,
    );
  }

  /// Replays the last known state to every new listener, then live updates —
  /// `Database.connectionState`'s own shape, continued upward.
  @override
  late final Stream<bool> connected = Stream.multi((controller) {
    controller.add(_lastConnected);
    final sub = _connectedCtrl.stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.onCancel = sub.cancel;
  });

  DatabaseConfig _databaseConfig() {
    final endpoint = config.endpoint;
    if (endpoint == null) {
      // CollectionConfig refuses enabled-without-endpoint at construction;
      // reaching this is a programming error, not a runtime state.
      throw StateError('collection is enabled with no endpoint');
    }
    return DatabaseConfig(
      postgres: pg.Endpoint(
        host: endpoint.host,
        port: endpoint.port,
        database: endpoint.database,
        username: endpoint.username,
        password: endpoint.password,
      ),
      sslMode: _sslModeFor(config.sslMode),
      maxPoolConnections: config.maxPoolConnections,
      connectTimeout: config.connectTimeout,
      queryTimeout: config.queryTimeout,
      applicationName: config.applicationNameFor(publisherId),
    );
  }

  /// [collectionSslModes] is a closed set the config already validated; the
  /// default arm exists for exhaustiveness, and it fails safe — `disable`
  /// never silently *upgrades* a mode the operator chose.
  static pg.SslMode _sslModeFor(String mode) => switch (mode) {
        'require' => pg.SslMode.require,
        'verifyFull' => pg.SslMode.verifyFull,
        _ => pg.SslMode.disable,
      };

  Future<void> _pause(Duration delay) {
    final sleep = _sleep;
    if (sleep != null) return sleep(delay);
    // Future.delayed cannot be cancelled; racing it against the closing
    // signal means shutdown never waits out a backoff. The residual delayed
    // future resolves harmlessly.
    return Future.any(<Future<void>>[
      Future<void>.delayed(delay),
      _closing.future,
    ]);
  }

  /// 1, 2, 4, 8, 16 s, capped at 30 — the repository's reconnect shape.
  static Duration _backoffFor(int attempt) {
    final shift = attempt < 5 ? attempt : 5;
    final seconds = 1 << shift;
    return Duration(seconds: seconds > 30 ? 30 : seconds);
  }

  /// Stores a **redacted** account of [error] as [SinkStats.lastError].
  ///
  /// This string becomes `PIPE.collect.last_error`, a key value any panel
  /// can subscribe to, and raw Postgres errors name the host, the database
  /// and the user (T-8b-07). Nothing of the driver's message survives except
  /// the failure class and, when one is present, the five-character SQLSTATE
  /// — a code fixed by the SQL standard that can name no deployment.
  void _recordFailure(String phase, Object error) {
    if (error is AdvisoryLockRefused) {
      // The one error whose detail survives: the holder's application_name
      // is a name this project mints itself (T-8b-05's "says which
      // process"), not a host, database or credential.
      _lastError = 'collect: refused — another collector holds this '
          'namespace${error.holder == null ? '' : ': ${error.holder}'}';
      return;
    }
    final type = error.runtimeType.toString();
    // The code is taken typed when the driver's exception arrives intact,
    // and otherwise only from the driver's own message shape —
    // `ServerException.toString()` is '$severity $code: $message'
    // (postgres exceptions.dart:160), which is also how the code survives
    // an isolate hop as a string. A bare five-character token elsewhere in
    // a message (a port, a pid) must not be laundered into a claim of
    // standard-fixed provenance (IN-04).
    final sqlState = error is pg.ServerException
        ? error.code
        : RegExp(r'Severity\.\w+\s+((?:08|22|23|28|3D|42|53|57)[0-9A-Z]{3}):')
            .firstMatch(error.toString())
            ?.group(1);
    final detail = sqlState == null ? type : '$type, SQLSTATE $sqlState';
    _lastError = 'collect: $phase failed: $detail (details withheld: raw '
        'driver errors can name the host, database and user)';
  }
}

final class _PendingRow {
  _PendingRow(this.table, this.time, this.value);
  final String table;
  final DateTime time;
  final Object? value;
}

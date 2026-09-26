/// The seam the TimescaleDB adapter implements and the collection runner
/// talks to.
///
/// ## Why a seam, and why the thing behind it is wrapped rather than rebuilt
///
/// Somebody will later ask why the runner does not just call `Database`
/// directly. Four lines, with the evidence:
///
///  1. `Database` takes its backend as a constructor parameter
///     (`database.dart:496-505`), and `AppDatabase.forTest` is a public
///     `@visibleForTesting` generative constructor added specifically so a
///     test can subclass and override `tableExists` / `tableInsertBatch`
///     (`database_drift.dart:141-153`) — the thing is injectable and
///     fakeable, and it holds no singleton.
///  2. Its 1 817 lines encode type inference, the null-first-sample rule,
///     ALTER-TABLE schema evolution and per-table drop accounting, each with
///     its own test file under `packages/tfc_dart/test/core/` — rebuilding
///     any of that here would be a second implementation to diverge.
///  3. So it is **wrapped, not rebuilt** — 8b-02's `collect/
///     timescale_sink.dart`, the ONE file in this package allowed to import
///     the database layer (`freeze_test.dart`'s seam sweep is what makes
///     "one" true).
///  4. And the seam exists so the gateway does not inherit what the wrap
///     must contain: `Database`'s constructor-started flush timer and its
///     retry-until-open connect loop, neither of which may run on the
///     gateway's value path.
///
/// ## What is deliberately NOT here
///
/// No query method — Phase 10 owns reads. No retry knob — no auto-retry, at
/// any layer, ever. No table enumeration — the [CollectionPlan] already
/// carries every table this process may touch, computed once and validated.
library;

import 'package:tfc_dart/tfc_dart.dart' show RetentionPolicy;

/// What the sink can say about itself, synchronously, at any moment.
///
/// These four numbers are where the `PIPE.collect.*` health keys get their
/// values (`getStats()`'s shape: `dropped_rows`, `queued_rows`, and the
/// write counter). **A lost row is a counted row** — any sample that is
/// dropped, skipped or refused shows up in [rowsDropped], where an operator
/// can read the number.
final class SinkStats {
  const SinkStats({
    required this.rowsWritten,
    required this.rowsDropped,
    required this.rowsQueued,
    this.lastError,
  });

  /// Rows that reached the database.
  final int rowsWritten;

  /// Rows dropped, skipped or refused — the historian's no-silent-anything
  /// number.
  final int rowsDropped;

  /// Rows waiting in the sink's buffers right now: the early warning for
  /// [rowsDropped].
  final int rowsQueued;

  /// The last error, **already redacted**.
  ///
  /// A raw Postgres error carries the host, the database and the user, and
  /// this string becomes `PIPE.collect.last_error` — a key value any panel
  /// can read (T-8b-03). The implementation redacts before it stores; by
  /// the time a string is here it is safe to serve. 8b-02 does the
  /// redaction and tests it.
  final String? lastError;
}

/// One historian, behind one seam.
///
/// The runner (8b-03) drives this; the TimescaleDB adapter (8b-02)
/// implements it; `FakeSink` in `test/support/` implements it too, so the
/// runner's tests need no database.
abstract interface class TimeseriesSink {
  /// Makes [table] exist with [retention] installed, or records why not.
  ///
  /// Idempotent — the runner may call it on every (re)connect. A null
  /// [retention] means **install no policy**: the table keeps everything,
  /// which is the safe direction to fail in (`database.dart:874-885`).
  Future<void> ensureTable(String table, RetentionPolicy? retention);

  /// Buffers one sample. **Fast and non-throwing — it buffers.**
  ///
  /// A sink that threw out of `insert` would put a database fault on the
  /// value path, which the house rules forbid: the gateway serves thirty
  /// panels, and a database that is down, slow, full or absent must degrade
  /// collection and nothing else. A sample the sink cannot take is counted
  /// in [SinkStats.rowsDropped], never thrown.
  Future<void> insert(String table, DateTime time, Object? value);

  /// Pushes everything buffered toward the database, bounded by the
  /// implementation's own deadline. What cannot be flushed stays counted
  /// in [SinkStats.rowsQueued].
  Future<void> flush();

  /// Releases the connection and stops the buffers.
  ///
  /// The seam exposes ONE shutdown method, deliberately — the wrapped layer
  /// has two with different flush semantics (`database.dart:1793-1804`'s
  /// `close` versus `:1284-1298`'s `dispose`), and a caller offered both
  /// will eventually call the wrong one during a teardown. The adapter
  /// picks; the runner cannot.
  Future<void> close();

  /// The four numbers, readable synchronously.
  SinkStats get stats;

  /// Whether the sink can currently reach its database. A stream rather
  /// than a getter: connection states are read inside `until()`/`within()`
  /// windows or not at all — never an instant read of a wall-clock-derived
  /// boolean.
  Stream<bool> get connected;
}

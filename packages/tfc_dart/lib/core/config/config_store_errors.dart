/// What a [ConfigStore] write throws, and why each one is its own type.
///
/// Three failures a shared configuration write can have, three things an
/// operator can do about them, so three types rather than one message:
///
///  * [ConfigStoreOfflineException] — Postgres is not reachable. Nothing was
///    written; try again when the connection light is green.
///  * [ConfigConflict] — another station edited the same key first. Reload and
///    re-apply; the other station's work is intact.
///  * [ConfigStoreUnsafePoolException] — this process is misconfigured. Not an
///    operator's problem at all; an engineer has to fix an environment
///    variable.
///
/// Every [toString] is written to be shown to an operator verbatim, because
/// that is what the editor's snackbar will do with it.
///
/// ## Why not the old `PreferencesException`
///
/// It was thrown *and swallowed* inside `Preferences.create`, so a
/// `catch (PreferencesException)` around a save would also have caught a
/// failure that had nothing to do with the save — which would make the
/// editor's three catch arms indistinguishable from each other. It is gone
/// with the Postgres paths that raised it (04-12); the reasoning is kept
/// because it is what these three types are shaped against.
library;

/// A write that needs Postgres, with no Postgres to write to.
///
/// This is the exception SC-4 is about. The situation used to be a silent
/// success: `Preferences._upsertToPostgres` returned `false` when
/// `database == null`, every caller ignored the return value, and
/// `key_repository.dart:878-882` showed a green *"Key mappings saved
/// successfully!"* over a write that reached nothing. An operator then
/// believed the plant's wiring was saved when it was not. That writer was
/// deleted in 04-12; this type is what replaced its return value.
///
/// Thrown in two places, distinguished by [cause]:
///
///  * **Before any transaction**, when the store has no remote at all — the
///    station booted with Postgres unreachable. [cause] is null.
///  * **Out of a failed transaction**, when the connection died mid-write and
///    `Database.isConnectionError` recognised the driver's complaint. [cause]
///    is the original error, so a log line still carries the driver detail
///    the message deliberately hides from the operator.
class ConfigStoreOfflineException implements Exception {
  const ConfigStoreOfflineException({required this.attempted, this.cause});

  /// What the operator was trying to save, in their words rather than the
  /// database's: `'key mappings: 3 keys (CN04.Belt.Speed, …)'`. The refusal is
  /// only useful if it names the work that did not land, so the operator knows
  /// what to redo.
  final String attempted;

  /// The driver error, when there was one. Null when the store never had a
  /// remote — nothing failed in that case, the write was refused before it
  /// could.
  final Object? cause;

  @override
  String toString() => 'Not saved — the shared database is unreachable. '
      'Nothing was written. Attempted: $attempted.'
      '${cause == null ? '' : ' ($cause)'}';
}

/// A compare-and-swap on `rev` found the row already moved.
///
/// Another station wrote this entity between this station's last read and this
/// save. Nothing of this save was committed — the store throws this *out of*
/// the transaction precisely so drift issues a `ROLLBACK` — so the other
/// station's edit is intact and this one has to be reapplied on top of it.
///
/// Never swallowed inside the transaction body: skipping the lost key and
/// carrying on would commit the rest, leaving the editor believing the whole
/// save landed, and would leave the connection in an aborted state that the
/// health monitor's next `SELECT 1` reads as "Postgres is down".
class ConfigConflict implements Exception {
  const ConfigConflict(this.key, {required this.expectedRev});

  /// An entity this station believed did not exist and that already does —
  /// C-12, the insert arm's collision.
  ///
  /// The same exception rather than a second type: to everybody above this
  /// layer the two are one situation ("the world moved under your save"), and
  /// undo-a-delete refusing to re-create a row somebody else re-created is the
  /// case this exists for. Only the sentence differs, because "expected
  /// revision 0" would be an odd thing to tell an operator.
  const ConfigConflict.created(this.key) : expectedRev = 0;

  /// The entity id whose revision moved — a mapping key, here.
  final String key;

  /// The revision this station believed was stored. The row is at some higher
  /// one; the difference is somebody else's edit. Zero means this station
  /// believed there was no row at all — see [ConfigConflict.created].
  final int expectedRev;

  @override
  String toString() => expectedRev == 0
      ? 'Not saved — "$key" was created on another station while you were '
          'editing. Nothing was written; reload and apply your change again.'
      : 'Not saved — "$key" was changed on another station while you were '
          'editing (expected revision $expectedRev). Nothing was written; '
          'reload and apply your change again.';
}

/// The remote's connection pool is larger than one, so a drift transaction on
/// it is not atomic.
///
/// `drift_postgres` declares `NoTransactionDelegate`, so drift issues literal
/// `BEGIN TRANSACTION` / `COMMIT TRANSACTION` as ordinary statements — and
/// `AppDatabase` hands it a `pg.Pool`, which picks *any* free connection per
/// statement. Nothing pins the `BEGIN`, the statements inside it and the
/// `COMMIT` to one socket. It works today only because
/// `resolvePoolSize(null) == 1`, so there is one connection to pick.
///
/// A shared write under a wider pool would therefore be a compare-and-swap
/// whose guard and whose write could land on different connections: exactly
/// the corruption `rev` exists to prevent, with no symptom until two stations
/// disagree about the plant's wiring. Refusing is the only honest answer, so
/// the store fails closed and names the variable to change.
class ConfigStoreUnsafePoolException implements Exception {
  const ConfigStoreUnsafePoolException({
    required this.attempted,
    required this.poolSize,
  });

  /// What the operator was trying to save, as [ConfigStoreOfflineException]
  /// carries it.
  final String attempted;

  /// The resolved pool size — what `resolvePoolSize` made of
  /// `CENTROID_DB_MAX_POOL_CONNECTIONS`.
  final int poolSize;

  @override
  String toString() =>
      'Not saved — this process pools $poolSize database connections, and a '
      'configuration write is only safe over one. Set '
      'CENTROID_DB_MAX_POOL_CONNECTIONS=1 (or leave it unset) and restart. '
      'Nothing was written. Attempted: $attempted.';
}

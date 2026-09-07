/// The one-shot copy of `flutter_preferences.key_mappings` into `config_item`
/// rows, run once against the database several stations share.
///
/// ## Why any of this is here
///
/// Several SVN stations share one Postgres and boot together. Drift's schema
/// versioning gates the *DDL* — `CREATE TABLE IF NOT EXISTS` is safe to run
/// from four machines at once — but it does not gate a *data* copy: two
/// stations reading the blob and inserting rows from it at the same time is
/// the failure mode this module exists to prevent, and it produces a doubled
/// change log and a doubled audit trail rather than an error anyone would see.
///
/// So the whole copy runs inside one transaction whose **first statement** is
/// `pg_try_advisory_xact_lock`, and a station that does not get the lock skips
/// immediately. It does not wait: `pg_advisory_lock` (the blocking form) would
/// put a lock-length stall on the boot path of every station but one, at the
/// exact moment the database is busiest, and the station that skipped comes up
/// on its local mirror and picks the rows up from the ordinary reconcile
/// seconds later. Nothing is lost by skipping.
///
/// ## Two things that look like details and are not
///
/// **The dialect is read from the executor, never from `AppDatabase.postgres`.**
/// That getter is `executor is PgDatabase`, and the app's database is built
/// with `AppDatabase.spawn`, whose executor is a DriftIsolate *remote* proxy —
/// so `db.postgres` is `false` on every station against a real TimescaleDB.
/// A lock guarded by it would be silently skipped in production and only in
/// production. `executor.dialect` is correct through the isolate: the remote
/// executor reports the dialect the server sent in its handshake.
///
/// **The lock is the transaction-scoped form.** `drift_postgres` declares
/// `NoTransactionDelegate`, so drift emulates a transaction with literal
/// `BEGIN`/`COMMIT` statements over a `pg.Pool` that hands out a connection
/// *per statement*. It is atomic today only because the pool defaults to one
/// connection. A session-level `pg_advisory_lock` under that pool could be
/// taken on one socket and released on another — or never released. The
/// `_xact_` form is released by the `COMMIT`/`ROLLBACK` drift issues on the
/// connection that holds it, which is the only variant that is safe here. And
/// because the same pool assumption is what makes the copy atomic at all, a
/// process whose pool is wider than one connection is refused outright.
///
/// ## What it deliberately does not do
///
/// It does not delete or rewrite `flutter_preferences.key_mappings`. That row
/// is the rollback insurance for the cutover and it is Phase 4's to drop.
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:logger/logger.dart';
import 'package:meta/meta.dart';
import 'package:tfc_access/tfc_access.dart' show newActionId;

import '../database.dart';
import '../database_connections.dart';
import '../database_drift.dart';
import 'config_change.dart';
import 'config_item.dart';
import 'key_mapping_codec.dart';

/// The advisory-lock namespace every configuration migration in this codebase
/// takes its lock in: `'CXMG'` as an int, so a lock seen in `pg_locks` is
/// traceable to this repository by grep.
///
/// A literal pair rather than anything derived at runtime: `hashtext()` is an
/// undocumented internal whose output has changed between major versions, and
/// a lock key that changes with the server version is not a lock.
const int kConfigLockNamespace = 0x43584D47;

/// The key-mappings migration's lock id within [kConfigLockNamespace].
///
/// `2` is reserved for the pages and assets migration in Phase 3; take the
/// next free number rather than reusing this one, so two different migrations
/// can never block each other.
const int kKeyMappingMigrationLock = 1;

/// The id of the shared row that records that this migration has run.
///
/// `kind='preference'`, `scope='shared'`, and underscore-prefixed so that it
/// is bookkeeping rather than a preference: `SqlitePreferences` already filters
/// underscore-prefixed ids out of `getKeys`, `getAll` and `clear`, so no
/// preferences surface will ever list it.
///
/// It exists because "are there any key mapping rows?" is not a complete
/// answer on its own. A plant that legitimately has zero mappings — or one
/// whose mappings were all deleted after the migration — would re-run the copy
/// on every boot forever, and each re-run would resurrect keys an operator had
/// deleted on purpose. The flag has to be about the migration, not about the
/// keys.
const String kKeyMappingsMigratedMarkerId = '_migrated.key_mappings';

/// `updated_by` and `who` on every row this migration writes. Not a username:
/// no human pressed anything, and naming one who did not would be worse than
/// naming none.
const String _migrationActor = 'migration';

/// `role_name` on the change rows. The migration runs before any session
/// exists, under no role — `'system'` says that rather than inventing one.
const String _migrationRole = 'system';

final Logger _logger = Logger();

/// What one call to [migrateKeyMappingsBlobToRows] did.
///
/// Every arm is a normal outcome and none of them is an error: the migration
/// is called unconditionally on the attach path, from every station, on every
/// boot, and it has to be able to say "not mine to do" as often as it says
/// "done". A failure — an unreadable blob — throws instead, because an outcome
/// that pretended success would leave a plant with an empty configuration and
/// a log line saying the migration was fine.
enum MigrationOutcome {
  /// The blob was copied. The log line carries how many keys.
  migrated,

  /// Rows or the marker were already there; nothing was written.
  alreadyDone,

  /// Another station holds the lock and is doing it right now; nothing was
  /// written and nothing waited.
  heldByAnother,

  /// `flutter_preferences` has no `key_mappings` row to copy.
  noBlob,

  /// The database is not Postgres — a local mirror, or a test. Nothing was
  /// written.
  notPostgres,

  /// The process pools more than one connection, which makes the transaction
  /// this needs non-atomic. Refused; see the library doc.
  unsafePool,
}

/// Copies `flutter_preferences.key_mappings` into one `config_item` row per
/// key, once, on whichever station gets the lock first.
///
/// Safe to call unconditionally and from every station: it is idempotent, it
/// refuses anything that is not a single-connection Postgres, and it never
/// blocks on the lock. [remote] must be the *shared* database — the local
/// SQLite mirror returns [MigrationOutcome.notPostgres] and is untouched.
///
/// Throws [FormatException] if the stored blob cannot be parsed. That is
/// deliberate and is the one case that is not an outcome: a migration that
/// turned an unrecognisable blob into an empty configuration would look
/// exactly like a successful one.
Future<MigrationOutcome> migrateKeyMappingsBlobToRows(Database remote) async {
  final db = remote.db;

  // C-3: the executor's dialect, never `db.postgres` — see the library doc.
  if (db.executor.dialect != SqlDialect.postgres) {
    _logger.i('key_mappings migration: database is ${db.executor.dialect.name}, '
        'not postgres; nothing to do');
    return MigrationOutcome.notPostgres;
  }

  // C-4: before opening anything, because with a wider pool the BEGIN, the
  // lock, the copy and the COMMIT are not pinned to one socket, and a
  // half-copied configuration is worse than an unmigrated one.
  final pool = resolvePoolSize(db.config.maxPoolConnections);
  if (pool > 1) {
    _logger.w('key_mappings migration: refusing to run with a pool of $pool '
        'connections — drift emulates the Postgres transaction this needs with '
        'bare BEGIN/COMMIT over a per-statement pool, which is atomic only at '
        'a pool of one. Run the migration from a process with '
        '$kMaxPoolConnectionsEnv unset or set to 1.');
    return MigrationOutcome.unsafePool;
  }

  return db.transaction(() async {
    // First statement in the transaction, always. Everything below it is
    // protected by it, including the idempotency gate: a gate read outside the
    // lock is a race with the station that is mid-copy.
    final lock = await db.customSelect(
      // `::int4` on both placeholders, and not decoration: drift binds every
      // Dart `int` as `bigint`, and the two-argument advisory-lock functions
      // are declared `(int4, int4)` — the one-argument form is the only
      // `bigint` one. Without the casts Postgres answers `42883: function
      // pg_try_advisory_xact_lock(bigint, bigint) does not exist` and the
      // migration fails at the first statement of the transaction, on a
      // station, where nothing else would have caught it. Both constants are
      // well inside int4 for the same reason.
      r'SELECT pg_try_advisory_xact_lock($1::int4, $2::int4) AS got',
      variables: [
        Variable.withInt(kConfigLockNamespace),
        Variable.withInt(kKeyMappingMigrationLock),
      ],
    ).getSingle();
    if (!lock.read<bool>('got')) {
      _logger.i('key_mappings migration: another station holds the lock; '
          'skipping — this station boots on its mirror and the rows arrive '
          'with the next reconcile');
      return MigrationOutcome.heldByAnother;
    }
    return copyKeyMappingsIntoRows(db);
  });
}

/// The copy itself, with the lock already held and a transaction already open.
///
/// Split out so the ordering this migration depends on — gate, then read, then
/// rows, then the marker **last** — is provable against an in-memory database
/// without a server. It is not a second entry point: called without the lock
/// it is exactly the race [migrateKeyMappingsBlobToRows] exists to prevent.
///
/// The marker going last, inside the same transaction, is what makes a process
/// killed mid-copy harmless: the implicit `ROLLBACK` takes the rows and the
/// marker away together, and the next station finds nothing and copies
/// cleanly. A marker written first would leave a database that believes it has
/// migrated and has not.
@visibleForTesting
Future<MigrationOutcome> copyKeyMappingsIntoRows(AppDatabase db) async {
  if (await _alreadyMigrated(db)) {
    _logger.i('key_mappings migration: already migrated; nothing to do');
    return MigrationOutcome.alreadyDone;
  }

  final blob = await _readBlob(db);
  if (blob == null) {
    _logger.i('key_mappings migration: no key_mappings row in '
        'flutter_preferences; nothing to copy');
    return MigrationOutcome.noBlob;
  }

  // Throws on anything unrecognisable, and the transaction unwinds with it.
  // `keyMappingItemsFromBlob` is the only parser of this blob in the codebase
  // and the one the round-trip test proves against the real plant value.
  final items = keyMappingItemsFromBlob(blob);

  final at = DateTime.now();
  final actionId = newActionId();
  final station = Platform.localHostname;

  for (final item in items) {
    await _insertItem(db, item, at: at);
    // Built through `ConfigChange.of` rather than by hand: it is what
    // guarantees each side is `encodeEntity()` and therefore restorable.
    await _insertChange(
      db,
      ConfigChange.of(
        at: at,
        actionId: actionId,
        who: _migrationActor,
        station: station,
        roleName: _migrationRole,
        after: item,
      ),
    );
  }

  // Last, and no change row of its own: the marker is this module's
  // bookkeeping, not a piece of the plant's configuration, and a history that
  // listed it would invite an undo that re-armed the migration.
  await _insertItem(
    db,
    ConfigItem.of(
      kind: ConfigKind.preference,
      id: kKeyMappingsMigratedMarkerId,
      value: {'type': 'String', 'value': at.toIso8601String()},
    ),
    at: at,
  );

  _logger.i('key_mappings migration: ${items.length} keys copied from '
      'flutter_preferences to config_item');
  return MigrationOutcome.migrated;
}

/// Whether the shared store already holds the migration's result.
///
/// Either a shared `key_mapping` row or the marker: the rows answer the
/// ordinary case in one indexed lookup, the marker answers the plant that has
/// none. See [kKeyMappingsMigratedMarkerId].
Future<bool> _alreadyMigrated(AppDatabase db) async {
  final t = db.configItemTable;
  final query = db.selectOnly(t)
    ..addColumns([t.id])
    ..where(t.scope.equals(ConfigScope.shared.wireName) &
        (t.kind.equals(ConfigKind.keyMapping.wireName) |
            (t.kind.equals(ConfigKind.preference.wireName) &
                t.id.equals(kKeyMappingsMigratedMarkerId))))
    ..limit(1);
  return (await query.get()).isNotEmpty;
}

/// The stored blob, or null when there is nothing to migrate.
///
/// A row whose value is null counts as nothing rather than as a broken blob:
/// the key has never been saved. A row holding something unparseable is a
/// different matter and reaches [keyMappingItemsFromBlob], which throws.
Future<String?> _readBlob(AppDatabase db) async {
  final row = await (db.select(db.flutterPreferences)
        ..where((t) => t.key.equals(kKeyMappingsPrefKey)))
      .getSingleOrNull();
  return row?.value;
}

/// One `config_item` row at `rev` 1 — a row this database has written once.
Future<void> _insertItem(AppDatabase db, ConfigItem item,
        {required DateTime at}) =>
    db.into(db.configItemTable).insert(ConfigItemTableCompanion.insert(
          kind: item.kind.wireName,
          id: item.id,
          scope: item.scope.wireName,
          parentId: Value(item.parentId),
          sortIndex: Value(item.sortIndex),
          payload: item.payload,
          rev: const Value(1),
          updatedAt: at,
          updatedBy: _migrationActor,
        ));

Future<void> _insertChange(AppDatabase db, ConfigChange change) =>
    db.into(db.configChangeTable).insert(ConfigChangeTableCompanion.insert(
          at: change.at,
          actionId: change.actionId,
          who: change.who,
          station: change.station,
          roleName: change.roleName,
          kind: change.kind.wireName,
          entityId: change.entityId,
          scope: change.scope.wireName,
          op: change.op.wireName,
          oldValue: Value(change.oldValue),
          newValue: Value(change.newValue),
        ));

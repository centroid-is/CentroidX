/// The one-shot copy of a `flutter_preferences` blob into `config_item` rows,
/// run once against the database several stations share.
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
/// ## Why the parser is a callback
///
/// This is the generic half of what `key_mapping_migration.dart` landed in
/// Phase 2, hoisted so the pages migration can be the same code. It could not
/// simply be copied: the pages parser is `pageItemsFromBlob`, which needs
/// `AssetPage`, which needs Flutter, and this package deliberately has none so
/// that the backend, the collector and the MCP `dart compile exe` binary can
/// reach it. Routing around that constraint rather than parameterising over it
/// is how D-3 happened.
///
/// So the transaction, the lock, the gate, the sort keys and the marker live
/// here, and *what a blob means* arrives as a [BlobParser]. The parse runs
/// **inside** the transaction, so an unreadable blob unwinds the copy instead
/// of half-writing it.
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
/// It does not delete or rewrite the `flutter_preferences` row it read. That
/// row is the rollback insurance for the cutover and it is Phase 4's to drop.
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:logger/logger.dart';
import 'package:tfc_access/tfc_access.dart' show newActionId;

import '../database_connections.dart';
import '../database_drift.dart';
import 'config_change.dart';
import 'config_history_policy.dart';
import 'config_item.dart';
import 'sort_keys.dart';

/// The advisory-lock namespace every configuration migration in this codebase
/// takes its lock in: `'CXMG'` as an int, so a lock seen in `pg_locks` is
/// traceable to this repository by grep.
///
/// A literal pair rather than anything derived at runtime: `hashtext()` is an
/// undocumented internal whose output has changed between major versions, and
/// a lock key that changes with the server version is not a lock.
const int kConfigLockNamespace = 0x43584D47;

/// The pages-and-assets migration's lock id within [kConfigLockNamespace].
///
/// It lives here rather than beside its caller because its caller is in the
/// **app** — the page codec needs Flutter — and both the reservation
/// (`key_mapping_migration.dart`'s lock id 1 names it) and the integration
/// test that holds the lock from a second connection are in this package.
/// Take the next free number for a new migration rather than reusing one, so
/// two different migrations can never block each other.
const int kPageMigrationLock = 2;

/// `updated_by` and `who` on every row a migration writes. Not a username: no
/// human pressed anything, and naming one who did not would be worse than
/// naming none.
const String _migrationActor = 'migration';

/// `role_name` on the change rows. A migration runs before any session
/// exists, under no role — `'system'` says that rather than inventing one.
const String _migrationRole = 'system';

final Logger _logger = Logger();

/// Turns the stored blob into the rows that replace it.
///
/// Injected because the page codec cannot live in this package: it needs
/// `AssetPage`, which needs Flutter. Called **inside** the transaction, so a
/// [FormatException] out of it unwinds the copy — the property
/// `key_mapping_migration.dart` relies on and states.
typedef BlobParser = List<ConfigItem> Function(String blob);

/// What one call to a blob→rows migration did.
///
/// Every arm is a normal outcome and none of them is an error: a migration is
/// called unconditionally on the attach path, from every station, on every
/// boot, and it has to be able to say "not mine to do" as often as it says
/// "done". A failure — an unreadable blob — throws instead, because an outcome
/// that pretended success would leave a plant with an empty configuration and
/// a log line saying the migration was fine.
enum MigrationOutcome {
  /// The blob was copied. The log line carries how many items.
  migrated,

  /// Rows or the marker were already there; nothing was written.
  alreadyDone,

  /// Another station holds the lock and is doing it right now; nothing was
  /// written and nothing waited.
  heldByAnother,

  /// `flutter_preferences` has no row under this key to copy.
  noBlob,

  /// The database is not Postgres — a local mirror, or a test. Nothing was
  /// written.
  notPostgres,

  /// The process pools more than one connection, which makes the transaction
  /// this needs non-atomic. Refused; see the library doc.
  unsafePool,
}

/// Copies `flutter_preferences.`[prefKey] into `config_item` rows, once, on
/// whichever station gets the lock first.
///
/// [kinds] is what the copy may produce and what the idempotency gate looks
/// for; [markerId] is the shared `preference` row that records the migration
/// itself, written **last, inside the same transaction**; [lockId] is this
/// migration's id within [kConfigLockNamespace]; [label] prefixes every log
/// line. [db] must be the *shared* database — a SQLite mirror returns
/// [MigrationOutcome.notPostgres] and is untouched.
///
/// Safe to call unconditionally and from every station: it is idempotent, it
/// refuses anything that is not a single-connection Postgres, and it never
/// blocks on the lock.
///
/// Throws [FormatException] if [parse] cannot read the stored blob. That is
/// deliberate and is the one case that is not an outcome: a migration that
/// turned an unrecognisable blob into an empty configuration would look
/// exactly like a successful one.
Future<MigrationOutcome> copyBlobIntoRows(
  AppDatabase db, {
  required String prefKey,
  required String markerId,
  required int lockId,
  required Set<ConfigKind> kinds,
  required BlobParser parse,
  required String label,
  String itemNoun = 'items',
}) async {
  // C-3: the executor's dialect, never `db.postgres` — see the library doc.
  if (db.executor.dialect != SqlDialect.postgres) {
    _logger.i('$label migration: database is ${db.executor.dialect.name}, '
        'not postgres; nothing to do');
    return MigrationOutcome.notPostgres;
  }

  // C-4: before opening anything, because with a wider pool the BEGIN, the
  // lock, the copy and the COMMIT are not pinned to one socket, and a
  // half-copied configuration is worse than an unmigrated one.
  final pool = resolvePoolSize(db.config.maxPoolConnections);
  if (pool > 1) {
    _logger.w('$label migration: refusing to run with a pool of $pool '
        'connections — drift emulates the Postgres transaction this needs '
        'with bare BEGIN/COMMIT over a per-statement pool, which is atomic '
        'only at a pool of one. Run the migration from a process with '
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
        Variable.withInt(lockId),
      ],
    ).getSingle();
    if (!lock.read<bool>('got')) {
      _logger.i('$label migration: another station holds the lock; '
          'skipping — this station boots on its mirror and the rows arrive '
          'with the next reconcile');
      return MigrationOutcome.heldByAnother;
    }
    return copyBlobIntoRowsLocked(
      db,
      prefKey: prefKey,
      markerId: markerId,
      kinds: kinds,
      parse: parse,
      label: label,
      itemNoun: itemNoun,
    );
  });
}

/// The copy itself, with the lock already held and a transaction already open.
///
/// Split out so the ordering every migration depends on — gate, then read,
/// then parse, then rows, then the marker **last** — is provable against an
/// in-memory database without a server. It is not a second entry point: called
/// without the lock it is exactly the race [copyBlobIntoRows] exists to
/// prevent.
///
/// The marker going last, inside the same transaction, is what makes a process
/// killed mid-copy harmless: the implicit `ROLLBACK` takes the rows and the
/// marker away together, and the next station finds nothing and copies
/// cleanly. A marker written first would leave a database that believes it has
/// migrated and has not.
///
/// Not `@visibleForTesting`: the callers that name a blob — the key-mappings
/// migration here, the pages migration in the app — delegate to it for their
/// own test seams, so the annotation would be a warning on production code
/// rather than a fence around it. The fence is the doc above and the fact
/// that [copyBlobIntoRows] is the only thing that takes the lock.
Future<MigrationOutcome> copyBlobIntoRowsLocked(
  AppDatabase db, {
  required String prefKey,
  required String markerId,
  required Set<ConfigKind> kinds,
  required BlobParser parse,
  required String label,
  String itemNoun = 'items',
}) async {
  if (await _alreadyMigrated(db, markerId: markerId)) {
    _logger.i('$label migration: already migrated; nothing to do');
    return MigrationOutcome.alreadyDone;
  }

  final blob = await _readBlob(db, prefKey);
  if (blob == null) {
    // The marker is written all the same. It records that this plant was
    // looked at and had nothing to move — which is exactly the answer the
    // sync engine's empty-remote guard and the preference migration's sibling
    // gate need from it. Without it a plant that never stored this blob would
    // have "no rows and no marker" forever: every sweep against a legitimately
    // empty remote refused, and the preference migration skipped on every
    // boot.
    await _insertItem(db, _markerItem(markerId), at: DateTime.now());
    _logger.i('$label migration: no $prefKey row in flutter_preferences; '
        'nothing to copy. Marker written, so this is asked once.');
    return MigrationOutcome.noBlob;
  }

  // Throws on anything unrecognisable, and the transaction unwinds with it.
  final parsed = parse(blob);
  for (final item in parsed) {
    if (!kinds.contains(item.kind)) {
      throw StateError('$label migration: the parser produced a '
          '${item.kind.wireName} item ("${item.id}"), which is not one of the '
          'kinds this migration may write ($kinds)');
    }
  }

  // The codecs emit `sortIndex` as a rank; the store holds it as a gapped key.
  // With no stored keys to preserve this degenerates to `(ordinal + 1) *
  // kSortKeyGap`, which is the only definition of the first keys there is —
  // copying the arithmetic here is how the first save after the migration
  // would come to diff as a full rewrite.
  final items = assignSortKeys(parsed, const {});

  final at = DateTime.now();
  final actionId = newActionId();
  final station = Platform.localHostname;

  for (final item in items) {
    await _writeItem(db, item,
        at: at, actionId: actionId, station: station);
  }

  // Last, and no change row of its own: the marker is bookkeeping, not a piece
  // of the plant's configuration, and a history that listed it would invite an
  // undo that re-armed the migration.
  await _insertItem(db, _markerItem(markerId, at: at), at: at);

  _logger.i('$label migration: ${items.length} $itemNoun copied from '
      'flutter_preferences to config_item');
  return MigrationOutcome.migrated;
}

/// Whether the shared store already holds this migration's result.
///
/// **The marker, and only the marker.** An earlier version also answered yes
/// to "any shared row of one of the kinds exists", and that read a boot
/// default as proof the migration had run: a fresh station attached to an
/// empty plant seeds `exampleKey` through `seedDefaultIfEmpty`, and a station
/// whose copy was then rolled back — power cut, dropped connection — or that
/// simply lost the lock race found one `key_mapping` row, answered
/// `alreadyDone`, and the plant's four hundred real keys never left the blob.
/// Silently, and on every boot after.
///
/// So the marker is the whole gate — the rule `preference_migration.dart`
/// already states for itself — and the copy writes **over** any row a seed
/// left behind (see [_writeItem]), because the blob is the plant's
/// configuration and the seed is a placeholder.
///
/// A plant with no pages, or one whose pages were all deleted after the
/// migration, is exactly why the flag is about the migration and not about
/// the rows: re-running the copy would resurrect what an operator deleted.
Future<bool> _alreadyMigrated(
  AppDatabase db, {
  required String markerId,
}) async {
  final t = db.configItemTable;
  final query = db.selectOnly(t)
    ..addColumns([t.id])
    ..where(t.scope.equals(ConfigScope.shared.wireName) &
        t.kind.equals(ConfigKind.preference.wireName) &
        t.id.equals(markerId))
    ..limit(1);
  return (await query.get()).isNotEmpty;
}

/// The marker row: a `String` preference holding when the migration ran.
ConfigItem _markerItem(String markerId, {DateTime? at}) => ConfigItem.of(
      kind: ConfigKind.preference,
      id: markerId,
      value: {
        'type': 'String',
        'value': (at ?? DateTime.now()).toIso8601String(),
      },
    );

/// Writes [item] over whatever is stored, and its change row.
///
/// The ordinary case is an insert. The case this exists for is a row that is
/// already there — a `seedDefaultIfEmpty` placeholder, or a station's boot
/// default — which the blob overwrites: the blob is what the plant configured
/// and the seed is what a station invented while it could not see the blob.
/// A row that already holds exactly this content is left alone rather than
/// rewritten, because writing identical bytes would log an edit nobody made.
///
/// An existing row's `rev` is carried forward and bumped rather than reset,
/// so a station holding the old revision loses its next compare-and-swap
/// instead of matching a number that means something else now. Same shape,
/// same reasons, as `preference_migration.dart`'s writer.
Future<void> _writeItem(
  AppDatabase db,
  ConfigItem item, {
  required DateTime at,
  required String actionId,
  required String station,
}) async {
  final existing = await (db.select(db.configItemTable)
        ..where((t) =>
            t.kind.equals(item.kind.wireName) &
            t.id.equals(item.id) &
            t.scope.equals(item.scope.wireName)))
      .getSingleOrNull();
  final before = existing == null
      ? null
      : ConfigItem(
          kind: item.kind,
          id: item.id,
          scope: item.scope,
          parentId: existing.parentId,
          sortIndex: existing.sortIndex,
          payload: existing.payload,
          rev: existing.rev,
        );
  if (before != null && before.sameContentAs(item)) return;

  final companion = ConfigItemTableCompanion.insert(
    kind: item.kind.wireName,
    id: item.id,
    scope: item.scope.wireName,
    parentId: Value(item.parentId),
    sortIndex: Value(item.sortIndex),
    payload: item.payload,
    rev: Value((existing?.rev ?? 0) + 1),
    updatedAt: at,
    updatedBy: _migrationActor,
  );
  if (existing == null) {
    await db.into(db.configItemTable).insert(companion);
  } else {
    await (db.update(db.configItemTable)
          ..where((t) =>
              t.kind.equals(item.kind.wireName) &
              t.id.equals(item.id) &
              t.scope.equals(item.scope.wireName)))
        .write(companion);
  }
  // Built through `ConfigChange.of` rather than by hand: it is what
  // guarantees each side is `encodeEntity()` and therefore restorable, and
  // what makes the row an `update` when a seed was overwritten rather than an
  // `insert` that would contradict the row it describes.
  await _insertChange(
    db,
    ConfigChange.of(
      at: at,
      actionId: actionId,
      who: _migrationActor,
      station: station,
      roleName: _migrationRole,
      before: before,
      after: item,
    ),
  );
}

/// The stored blob, or null when there is nothing to migrate.
///
/// A row whose value is null counts as nothing rather than as a broken blob:
/// the key has never been saved. A row holding something unparseable is a
/// different matter and reaches the [BlobParser], which throws.
Future<String?> _readBlob(AppDatabase db, String prefKey) async {
  final row = await (db.select(db.flutterPreferences)
        ..where((t) => t.key.equals(prefKey)))
      .getSingleOrNull();
  return row?.value;
}

/// One `config_item` row at `rev` 1 — the marker, which nothing seeds.
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

/// One row of the change log for a migrated entity — unless the entity is one
/// that carries no history, which the migration asks about for the same reason
/// the store does: `config_change` is never pruned, so a kind exempted for the
/// size of its payload or the secrecy of it must be exempt on every path into
/// the table, including this one. See `config_history_policy.dart`.
Future<void> _insertChange(AppDatabase db, ConfigChange change) =>
    historyExempt(change.kind, change.entityId)
        ? Future<void>.value()
        : db
            .into(db.configChangeTable)
            .insert(ConfigChangeTableCompanion.insert(
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

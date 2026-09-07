/// The repository that owns `key_mapping` rows: an in-memory snapshot, filled
/// from local SQLite at boot, with exactly one write path to Postgres.
///
/// ## Who owns what
///
/// Postgres owns every `scope='shared'` row and is the only place a shared
/// write lands. The local SQLite file (`config.sqlite`) is two things at once:
/// a **mirror** of those shared rows, so a station whose Postgres is
/// unreachable still boots holding the plant's wiring, and the **owner** of
/// this station's own rows. That is why the constructor takes both an
/// [AppDatabase] (always present, always local) and a [Database] remote that
/// may be null for the life of the process.
///
/// The asymmetry in the two types is forced rather than chosen: [Database] is
/// what carries the pool configuration and the connection-error classifier
/// this store needs, and it *cannot* wrap a SQLite config at all — its factory
/// picks `spawn`/`create` on `config.postgres != null`
/// (`database_drift.dart:1191-1194`). So the local side is the bare
/// [AppDatabase] and the remote side is the wrapper.
///
/// ## What this object is not
///
/// It performs **no access check and writes no `audit_entry` row**. Both are
/// the app layer's job: `AccessPolicy`, `AccessSession` and `AuditSink` all
/// need a session, and this library sits below the layer that has one. The
/// attribution — `actionId`, `who`, `roleName`, `reason` — arrives as
/// parameters, exactly as `SqlitePreferences._writeRow` already takes `at` and
/// `actionId` from its caller so that a bulk operation reads as one action.
///
/// It also imports nothing outside `tfc_dart`'s core: no `flutter_riverpod`,
/// no `package:flutter`, no `tfc_access` policy types. That is what lets the
/// backend and the collector reach it, and what lets every behaviour here be
/// proved against two in-memory SQLite databases with no Postgres and no
/// Docker.
///
/// ## No dialect branch, deliberately
///
/// There is no `if (postgres) … else …` anywhere in this file. Drift's typed
/// query builders emit the right dialect from `executor.dialect`, so the
/// compare-and-swap, the inserts and the guarded deletes are one piece of code
/// for both backends — which is also what makes an in-memory SQLite stand-in
/// for the remote a real test of the SQL rather than a mock.
///
/// If a branch ever becomes necessary, it must be
/// `db.executor.dialect == SqlDialect.postgres`. **Never `AppDatabase.postgres`
/// or `AppDatabase.native`**: both are `false` on every station, because the
/// app builds its database with [AppDatabase.spawn] and the resulting executor
/// is a DriftIsolate *remote*, not a `PgDatabase`. The remote executor reports
/// the server's dialect from its handshake, which is why the `executor.dialect`
/// form is right and the `is PgDatabase` form is not.
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:logger/logger.dart';
import 'package:meta/meta.dart';

import '../database.dart';
import '../database_connections.dart';
import '../database_drift.dart';
import '../state_man.dart' show KeyMappings;
import 'config_change.dart';
import 'config_diff.dart';
import 'config_item.dart';
import 'config_store_errors.dart';
// Prefixed: the codec's `keyMappingItems` and this store's getter of the same
// name are two different things, and inside the class the getter would win.
import 'key_mapping_codec.dart' as codec;

/// The local row that records how far this station has consumed the shared
/// change log.
///
/// `kind='preference'` at the station's own scope, with an underscore-prefixed
/// id so that [SqlitePreferences] never surfaces it as a setting — the
/// convention the one-shot import marker established. Written by the sync
/// engine; this store only restores it at [ConfigStore.open].
const String kKeyMappingsWatermarkId = '_sync.key_mappings.watermark';

/// Only ever used off the happy path — the re-home, and a mirror write that
/// failed after the shared write had already committed. Nothing here logs per
/// read or per write.
final Logger _logger = Logger();

/// What one call to [ConfigStore.writeKeyMappings] did.
class ConfigWriteResult {
  const ConfigWriteResult({required this.diff, required this.actionId});

  /// What was actually written — [ConfigDiff.none] when the save was a no-op.
  /// This is what `StateMan.updateKeyMappings` re-points its live
  /// subscriptions from, rather than recomputing one from two full blobs.
  final ConfigDiff diff;

  /// The caller's own action id, handed back so the `audit_entry` row the app
  /// layer writes carries the same correlation id as the `config_change` rows
  /// beneath it.
  final String actionId;

  @override
  String toString() => 'ConfigWriteResult($diff, action: $actionId)';
}

/// The key-mapping repository. See the library doc for ownership.
class ConfigStore {
  ConfigStore({
    required AppDatabase local,
    required ConfigScope stationScope,
    required String station,
    Database? remote,
  })  : _local = local,
        _stationScope = stationScope,
        _station = station,
        _remote = remote?.db;

  /// `config.sqlite` — the mirror of the shared rows and the owner of this
  /// station's own.
  final AppDatabase _local;

  /// This station's scope. Used for the Phase-1 cache row the re-home removes
  /// and for the watermark row, never for a `key_mapping` row: those are
  /// shared by definition.
  final ConfigScope _stationScope;

  /// The hostname stamped on every change row this store writes.
  final String _station;

  /// The Postgres side, or null when this process never reached it.
  AppDatabase? _remote;

  /// The shared `key_mapping` rows, keyed by mapping key. Replaced wholesale
  /// on every swap; never handed out.
  Map<String, ConfigItem> _snapshot = const {};

  /// How far this station has consumed the shared change log.
  int _watermark = 0;

  final StreamController<ConfigDiff> _changes =
      StreamController<ConfigDiff>.broadcast();

  /// Fills the snapshot from local SQLite, having first re-homed a Phase-1
  /// station-scoped cache into shared rows. No network, no Postgres, ~2 ms.
  ///
  /// Idempotent: every step is a no-op the second time, so a caller that is
  /// not sure whether the store is open may simply open it.
  Future<void> open() async {
    await _rehomePhase1Cache();
    _snapshot = {
      for (final row in await _sharedMappingRows()) row.id: _itemOf(row),
    };
    _watermark = await _readWatermark();
  }

  /// The mappings, as a **fresh object every call**.
  ///
  /// Not an optimisation to skip: `common.dart:834` reaches into a live
  /// `KeyMappings` and assigns into `nodes` directly. If that object were the
  /// store's own, the mutation would land in the baseline the *next* save is
  /// diffed against, the diff would come back empty, and the save would report
  /// success having written nothing. [keyMappingsOf] rebuilds every entry from
  /// its payload, so nothing a caller does to what it is handed can reach in
  /// here.
  KeyMappings get keyMappings => codec.keyMappingsOf(keyMappingItems);

  /// The stored items, as a fresh list every call, in canonical key order —
  /// the order [keyMappingItems] itself produces, so a diff of a round trip
  /// reports no change from ordering alone.
  ///
  /// [ConfigItem] is immutable, so a copy of the list is the whole defence.
  List<ConfigItem> get keyMappingItems {
    final ids = _snapshot.keys.toList()..sort();
    return [for (final id in ids) _snapshot[id]!];
  }

  /// Emits once after every snapshot swap.
  Stream<ConfigDiff> get keyMappingChanges => _changes.stream;

  /// How far this station has consumed the shared change log.
  int get watermark => _watermark;

  /// Whether a shared write can even be attempted right now.
  bool get hasRemote => _remote != null;

  /// Points the write path at [remote].
  ///
  /// **A reconnect must call this again.** The store's object identity is
  /// stable for the life of the process on purpose — that is what lets a
  /// provider publish it without anything downstream rebuilding the plant
  /// connection every time a key changes — but `databaseProvider` builds a
  /// *new* [Database] when Postgres comes back, and the handle taken here is
  /// the old one. Nothing detects that: a write through a closed handle fails
  /// with a driver error rather than reporting itself as offline. Re-attaching
  /// on every rebuild of the database provider is the app layer's job, and is
  /// why this is a method rather than a constructor argument.
  void attachRemote(Database remote) => _remote = remote.db;

  /// Forgets the remote. The snapshot and the mirror are untouched.
  void detachRemote() => _remote = null;

  /// Points the write path at a bare [AppDatabase].
  ///
  /// The seam every unit test in this library uses, and the reason the write
  /// path is written against the [AppDatabase] surface rather than [Database]:
  /// the [Database] wrapper cannot wrap a SQLite config at all, so without
  /// this there would be no way to exercise the compare-and-swap, the change
  /// rows or the rollback except against a real Postgres. Attaching a second
  /// in-memory [AppDatabase] as "the remote" runs the same generated schema
  /// and the same SQL, so what the tests prove is the statements rather than a
  /// mock's idea of them.
  @visibleForTesting
  void attachRemoteDatabase(AppDatabase remote) => _remote = remote;

  /// The one write path: the shared rows on the remote, the mirror behind it,
  /// the snapshot, and one event.
  ///
  /// [actionId] is the caller's and is shared with the `audit_entry` row the
  /// app layer writes for the same action, so a save that touched nine keys
  /// reads as one operation with nine rows beneath it rather than nine
  /// unrelated ones. [who] and [roleName] are likewise the caller's: this
  /// layer has no session to ask.
  ///
  /// ## Order of the checks, and why refusal comes before the diff
  ///
  /// The remote and the pool are checked **before** the diff is computed, so a
  /// save with nowhere to go is refused even when it happens to change
  /// nothing. That is the fail-loud reading of the offline rule: a caller
  /// whose write cannot reach Postgres is told so every time, rather than
  /// being told so only when it would have written something. A caller that
  /// legitimately saves-if-changed while offline — a boot seed, say — must
  /// therefore compare against [keyMappingItems] itself rather than calling
  /// this and hoping.
  ///
  /// Throws [ConfigStoreOfflineException] when there is no remote or the
  /// connection dies mid-write, [ConfigStoreUnsafePoolException] when the
  /// pool is wider than one, and [ConfigConflict] when another station moved
  /// a row first. In every one of those cases nothing is committed anywhere.
  Future<ConfigWriteResult> writeKeyMappings(
    KeyMappings wanted, {
    required String actionId,
    required String who,
    required String roleName,
    String? reason,
  }) async {
    final attempted = _describe(wanted);

    final remote = _remote;
    if (remote == null) {
      throw ConfigStoreOfflineException(attempted: attempted);
    }
    final poolSize = resolvePoolSize(remote.config.maxPoolConnections);
    if (poolSize > 1) {
      throw ConfigStoreUnsafePoolException(
          attempted: attempted, poolSize: poolSize);
    }

    final diff = diffConfigItems(
      stored: keyMappingItems,
      wanted: codec.keyMappingItems(wanted),
    );
    // SC-1's other half. Save pressed twice is not a change, so it is not a
    // row, not a change entry, not an audit entry and not an event — the same
    // rule the local row writer applies at `sqlite_preferences.dart:399`.
    if (diff.isEmpty) {
      return ConfigWriteResult(diff: ConfigDiff.none, actionId: actionId);
    }

    final at = DateTime.now();
    final written = <String, ConfigItem>{};
    try {
      await remote.transaction(() async {
        for (final item in diff.added) {
          await remote.into(remote.configItemTable).insert(
                ConfigItemTableCompanion.insert(
                  kind: item.kind.wireName,
                  id: item.id,
                  scope: item.scope.wireName,
                  parentId: Value(item.parentId),
                  sortIndex: Value(item.sortIndex),
                  payload: item.payload,
                  rev: const Value(1),
                  updatedAt: at,
                  updatedBy: who,
                ),
              );
          written[item.id] =
              item.stored(rev: 1, updatedAt: at, updatedBy: who);
          await _appendChange(
              remote,
              ConfigChange.of(
                at: at,
                actionId: actionId,
                who: who,
                station: _station,
                roleName: roleName,
                after: item,
                reason: reason,
              ));
        }

        for (final item in diff.changed) {
          // The revision comes from the snapshot, never from a read inside
          // this transaction: re-reading it here would turn the compare-and-
          // swap back into the read-check-write it exists to replace, and the
          // window it closes is precisely the one another station writes in.
          final stored = _snapshot[item.id]!;
          final won = await (remote.update(remote.configItemTable)
                ..where((t) => _identity(t, item) & t.rev.equals(stored.rev)))
              .write(ConfigItemTableCompanion(
            payload: Value(item.payload),
            parentId: Value(item.parentId),
            sortIndex: Value(item.sortIndex),
            rev: Value(stored.rev + 1),
            updatedAt: Value(at),
            updatedBy: Value(who),
          ));
          // Throwing is what makes drift issue ROLLBACK. Skipping the lost key
          // and carrying on would commit the rest of the save, leave the
          // editor believing all of it landed, and leave the connection in an
          // aborted state that the health monitor's next `SELECT 1` reads as
          // "Postgres is down".
          if (won != 1) {
            throw ConfigConflict(item.id, expectedRev: stored.rev);
          }
          written[item.id] = item.stored(
              rev: stored.rev + 1, updatedAt: at, updatedBy: who);
          await _appendChange(
              remote,
              ConfigChange.of(
                at: at,
                actionId: actionId,
                who: who,
                station: _station,
                roleName: roleName,
                before: stored,
                after: item,
                reason: reason,
              ));
        }

        for (final item in diff.removed) {
          // Guarded by `rev` for the same reason an update is: an unguarded
          // delete would silently throw away an edit another station made
          // between this station's read and this save.
          final won = await (remote.delete(remote.configItemTable)
                ..where((t) => _identity(t, item) & t.rev.equals(item.rev)))
              .go();
          if (won != 1) {
            throw ConfigConflict(item.id, expectedRev: item.rev);
          }
          await _appendChange(
              remote,
              ConfigChange.of(
                at: at,
                actionId: actionId,
                who: who,
                station: _station,
                roleName: roleName,
                before: item,
                reason: reason,
              ));
        }
      });
    } on ConfigConflict {
      // Already the right shape, and already rolled back.
      rethrow;
    } catch (e) {
      // The write *is* the probe. `Database.connectionState` is not consulted:
      // it is up to 30 s stale, and with a pool of one our own aborted
      // transaction can make it false, so trusting it would tell an operator
      // who is online that the database is down.
      if (Database.isConnectionError(e)) {
        throw ConfigStoreOfflineException(attempted: attempted, cause: e);
      }
      rethrow;
    }

    // Past here the remote has committed and the save has happened. The mirror
    // is a cache of that fact, so its failure is logged rather than reported
    // as a failed save — the boot after would read a stale row and 02-04's
    // reconcile would repair it, whereas telling the operator the save failed
    // would have them do it twice.
    final next = Map<String, ConfigItem>.of(_snapshot);
    for (final item in diff.removed) {
      next.remove(item.id);
    }
    next.addAll(written);
    _snapshot = next;

    try {
      await _writeMirror(diff, written);
    } catch (e) {
      _logger.e('key_mappings mirror write failed after the shared write '
          'committed; this station will read a stale row until the next '
          'reconcile: $e');
    }

    _changes.add(diff);
    return ConfigWriteResult(diff: diff, actionId: actionId);
  }

  /// Releases the change stream. The databases are the caller's to close.
  Future<void> close() => _changes.close();

  // ---------------------------------------------------------------------
  // The write path's helpers
  // ---------------------------------------------------------------------

  /// One row's primary key. Every part is a bound variable, never
  /// interpolated: a mapping key is operator-authored text and has no business
  /// reaching the database as SQL.
  Expression<bool> _identity($ConfigItemTableTable t, ConfigItem item) =>
      t.kind.equals(item.kind.wireName) &
      t.id.equals(item.id) &
      t.scope.equals(item.scope.wireName);

  /// Appends one row to [db]'s change log.
  ///
  /// Always built through [ConfigChange.of] by the caller, which is the one
  /// place `encodeEntity()` — payload **and** position — is applied. Sides
  /// encoded by hand lose position and make a restore write the entity back in
  /// the wrong place.
  Future<void> _appendChange(AppDatabase db, ConfigChange change) =>
      db.into(db.configChangeTable).insert(
            ConfigChangeTableCompanion.insert(
              at: change.at,
              actionId: change.actionId,
              who: change.who,
              station: change.station,
              roleName: change.roleName,
              reason: Value(change.reason),
              kind: change.kind.wireName,
              entityId: change.entityId,
              scope: change.scope.wireName,
              op: change.op.wireName,
              oldValue: Value(change.oldValue),
              newValue: Value(change.newValue),
            ),
          );

  /// Brings the local mirror level with what the remote just committed.
  ///
  /// Plain upserts and unguarded deletes: **the mirror never compare-and-
  /// swaps**. It is a copy of a decision already made elsewhere, and guarding
  /// it would let a stale local revision refuse to record what Postgres has
  /// already accepted.
  ///
  /// No `config_change` rows either. The shared history lives on the remote;
  /// writing it locally as well would be two histories of one event, with two
  /// id spaces that nothing reconciles.
  Future<void> _writeMirror(
      ConfigDiff diff, Map<String, ConfigItem> written) async {
    await _local.transaction(() async {
      for (final item in diff.removed) {
        await (_local.delete(_local.configItemTable)
              ..where((t) => _identity(t, item)))
            .go();
      }
      for (final item in written.values) {
        final companion = ConfigItemTableCompanion.insert(
          kind: item.kind.wireName,
          id: item.id,
          scope: item.scope.wireName,
          parentId: Value(item.parentId),
          sortIndex: Value(item.sortIndex),
          payload: item.payload,
          rev: Value(item.rev),
          updatedAt: item.updatedAt!,
          updatedBy: item.updatedBy!,
        );
        final replaced = await (_local.update(_local.configItemTable)
              ..where((t) => _identity(t, item)))
            .write(companion);
        if (replaced == 0) {
          await _local.into(_local.configItemTable).insert(companion);
        }
      }
    });
  }

  /// What the operator was trying to save, in their words.
  ///
  /// A refusal is only useful if it names the work that did not land, so this
  /// carries the count and enough keys to recognise the save by. Three names,
  /// because the plant has ten thousand and an operator reading a snackbar
  /// needs to recognise the save, not audit it.
  static String _describe(KeyMappings wanted) {
    final keys = wanted.nodes.keys.toList()..sort();
    final shown = keys.take(3).join(', ');
    final tail = keys.length > 3 ? ', …' : '';
    return 'key mappings: ${keys.length} '
        '${keys.length == 1 ? 'key' : 'keys'}'
        '${keys.isEmpty ? '' : ' ($shown$tail)'}';
  }

  // ---------------------------------------------------------------------
  // The re-home (C-5)
  // ---------------------------------------------------------------------

  /// Moves Phase 1's station-scoped `key_mappings` cache into shared rows and
  /// removes it, in **one local transaction**.
  ///
  /// ## Why a move and not a delete
  ///
  /// Phase 1 cached the whole blob at `station:<hostname>` scope, and
  /// `PageManager` reads it back before `runApp`. Simply deleting it on the
  /// cutover boot would be correct only if the shared rows were already there
  /// — and the boot where they are *not* is exactly the boot this has to
  /// survive: Postgres unreachable, migration not yet run, station coming up
  /// on its mirror. Deleting first would leave that station with no key
  /// mappings at all, which on the floor is every mimic blank and nothing
  /// saying why. So the blob is decomposed into shared rows first, and the
  /// cache row goes in the same transaction as the rows that replace it.
  ///
  /// There is no ordering in which the blob is gone and the rows are not,
  /// because there is no ordering: one transaction, and drift buffers a
  /// transaction's stream notifications until it commits, so nothing —
  /// including a `watch()` in the same process — can observe the gap.
  ///
  /// ## Why no marker row
  ///
  /// The delete is unconditional on every boot. It is a no-op when the row is
  /// absent, which is the case from the second boot onwards, and it logs only
  /// when it did something. That is deliberately weaker than the marker the
  /// one-shot import uses, and it buys one thing: while the rest of this phase
  /// lands, `Preferences.syncToLocalCache` still copies `key_mappings` down
  /// and re-creates the row. A marker would let that copy survive; an
  /// unconditional delete removes it again at the next restart, so the store
  /// self-heals until 02-06 stops it being written.
  ///
  /// ## Why nothing is logged in the change log
  ///
  /// Moving a cache between scopes is not an edit to the plant. The local
  /// `config_change` table records what an operator did on this station, and
  /// filling it with a bookkeeping move would be a history nobody reads.
  Future<void> _rehomePhase1Cache() async {
    await _local.transaction(() async {
      final cached = await (_local.select(_local.configItemTable)
            ..where((t) =>
                t.kind.equals(ConfigKind.preference.wireName) &
                t.id.equals(codec.kKeyMappingsPrefKey) &
                t.scope.equals(_stationScope.wireName)))
          .getSingleOrNull();
      // The ordinary case from the second boot onwards. Nothing to do, and
      // nothing to say about it.
      if (cached == null) return;

      final existing = await _sharedMappingRows();
      var seeded = 0;
      if (existing.isEmpty) {
        final List<ConfigItem> items;
        try {
          items =
              codec.keyMappingItemsFromBlob(_unwrapCachedBlob(cached.payload));
        } catch (e) {
          // Leave the row. It is the only remaining evidence of what this
          // station was configured with, and a station booting empty with the
          // blob still on disk is recoverable by hand; one booting empty with
          // it deleted is not.
          _logger.e('key_mappings rehome: the cached blob is unreadable, so '
              'the station row is left in place as evidence and this station '
              'boots with no mappings until the sync engine fills them: $e');
          return;
        }
        final at = DateTime.now();
        for (final item in items) {
          await _local.into(_local.configItemTable).insert(
                ConfigItemTableCompanion.insert(
                  kind: item.kind.wireName,
                  id: item.id,
                  scope: ConfigScope.shared.wireName,
                  payload: item.payload,
                  // Zero, not one: a cached blob carries no revision, so the
                  // mirror claims none rather than inventing one that a
                  // compare-and-swap would then trust.
                  rev: const Value(0),
                  updatedAt: at,
                  updatedBy: _rehomedBy,
                ),
              );
        }
        seeded = items.length;
      }

      await (_local.delete(_local.configItemTable)
            ..where((t) =>
                t.kind.equals(ConfigKind.preference.wireName) &
                t.id.equals(codec.kKeyMappingsPrefKey) &
                t.scope.equals(_stationScope.wireName)))
          .go();

      _logger.i(seeded > 0
          ? 'key_mappings rehome: $seeded keys moved to shared scope'
          : 'key_mappings rehome: station-scoped cache removed; '
              '${existing.length} shared rows were already present');
    });
  }

  /// The blob out of a Phase-1 preference payload.
  ///
  /// [SqlitePreferences] stores every preference as `{"type": …, "value": …}`
  /// so that `'7'` and `7` stay two different preferences. The blob is the
  /// `value` of a `String`-tagged row; anything else is not a cached
  /// `key_mappings` and the caller treats it as unreadable.
  static String _unwrapCachedBlob(String payload) {
    final decoded = jsonDecode(payload);
    if (decoded is! Map || decoded['type'] != 'String') {
      throw FormatException(
          'the cached key_mappings row is not a String preference: $payload');
    }
    final value = decoded['value'];
    if (value is! String) {
      throw FormatException(
          'the cached key_mappings row holds ${value.runtimeType}, not a blob');
    }
    return value;
  }

  // ---------------------------------------------------------------------
  // Local reads
  // ---------------------------------------------------------------------

  Future<List<ConfigItemRow>> _sharedMappingRows() =>
      (_local.select(_local.configItemTable)
            ..where((t) =>
                t.kind.equals(ConfigKind.keyMapping.wireName) &
                t.scope.equals(ConfigScope.shared.wireName)))
          .get();

  /// How far the sync engine has consumed the shared change log, or zero.
  ///
  /// Read-only here: 02-04 owns the write. Defined now so the row's shape is
  /// settled in one place — a `SqlitePreferences`-typed `int` at this
  /// station's scope, with an underscore-prefixed id so it is invisible to
  /// `getKeys`, `getAll` and `clear`.
  ///
  /// An unreadable watermark reads as zero rather than throwing: re-consuming
  /// the log from the beginning is slow and harmless, and refusing to boot
  /// over a corrupt bookkeeping row is neither.
  Future<int> _readWatermark() async {
    final row = await (_local.select(_local.configItemTable)
          ..where((t) =>
              t.kind.equals(ConfigKind.preference.wireName) &
              t.id.equals(kKeyMappingsWatermarkId) &
              t.scope.equals(_stationScope.wireName)))
        .getSingleOrNull();
    if (row == null) return 0;
    try {
      final decoded = jsonDecode(row.payload);
      if (decoded is Map && decoded['value'] is int) {
        return decoded['value'] as int;
      }
    } on FormatException {
      // Falls through to the log line below.
    }
    _logger.w('key_mappings watermark is unreadable (${row.payload}); '
        'consuming the change log from the beginning');
    return 0;
  }

  /// The item a mirror row describes. Carries `rev`, which is what the
  /// compare-and-swap guards with.
  ConfigItem _itemOf(ConfigItemRow row) => ConfigItem(
        kind: ConfigKind.keyMapping,
        id: row.id,
        scope: ConfigScope.shared,
        parentId: row.parentId,
        sortIndex: row.sortIndex,
        payload: row.payload,
        rev: row.rev,
        updatedAt: row.updatedAt,
        updatedBy: row.updatedBy,
      );
}

/// The `updated_by` of a mirror row the re-home created.
///
/// Not `'anonymous'`: nobody wrote these, they were carried over from a cache
/// whose own row said nothing about who wrote it. Naming the move is what
/// stops a history reader attributing the plant's whole wiring to one
/// unidentified person at one instant.
const String _rehomedBy = 'rehome';

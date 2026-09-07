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

import '../database.dart';
import '../database_drift.dart';
import '../state_man.dart' show KeyMappings;
import 'config_diff.dart';
import 'config_item.dart';
import 'key_mapping_codec.dart';

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
  KeyMappings get keyMappings => keyMappingsOf(keyMappingItems);

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
  void attachRemote(Database remote) => _remote = remote.db;

  /// Forgets the remote. The snapshot and the mirror are untouched.
  void detachRemote() => _remote = null;

  /// The one write path.
  Future<ConfigWriteResult> writeKeyMappings(
    KeyMappings wanted, {
    required String actionId,
    required String who,
    required String roleName,
    String? reason,
  }) =>
      throw UnimplementedError();

  /// Releases the change stream. The databases are the caller's to close.
  Future<void> close() => _changes.close();

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
                t.id.equals(kKeyMappingsPrefKey) &
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
          items = keyMappingItemsFromBlob(_unwrapCachedBlob(cached.payload));
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
                t.id.equals(kKeyMappingsPrefKey) &
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

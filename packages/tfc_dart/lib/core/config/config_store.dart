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

import '../database.dart';
import '../database_drift.dart';
import '../state_man.dart' show KeyMappings;
import 'config_diff.dart';
import 'config_item.dart';

/// The local row that records how far this station has consumed the shared
/// change log.
///
/// `kind='preference'` at the station's own scope, with an underscore-prefixed
/// id so that [SqlitePreferences] never surfaces it as a setting — the
/// convention the one-shot import marker established. Written by the sync
/// engine; this store only restores it at [ConfigStore.open].
const String kKeyMappingsWatermarkId = '_sync.key_mappings.watermark';

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
  /// station-scoped cache into shared rows. No network, no Postgres.
  Future<void> open() => throw UnimplementedError();

  /// The mappings, as a **fresh object every call**.
  KeyMappings get keyMappings => throw UnimplementedError();

  /// The stored items, as a fresh list every call, in canonical key order.
  List<ConfigItem> get keyMappingItems => throw UnimplementedError();

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
}

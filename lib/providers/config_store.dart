import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';
import 'package:tfc_dart/core/access/guarded_config_store.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_store.dart';
import 'package:tfc_dart/core/config/key_mapping_migration.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_connections.dart' show kMaxPoolConnectionsEnv;

import 'access.dart';
import 'access_policy.dart';
import 'database.dart';
import 'preferences.dart';

/// Only ever used off the happy path: the migration's verdict and an attach
/// that failed. Nothing here logs per read or per write.
final Logger _logger = Logger();

/// The shared configuration store, **guarded**, with an object identity that
/// never changes for the life of the process.
///
/// ## Nothing here may watch `databaseProvider`
///
/// This is the third instance of the house rule (`preferences.dart:186-191`
/// for the session, `state_man.dart:136-141` for the same). `databaseProvider`
/// builds a **whole new [Database]** and invalidates itself on every reconnect
/// (`database.dart:48-58`), so a `ref.watch` here would throw this store away
/// and build another one each time Postgres blinked — losing the snapshot the
/// plant's mimics are drawn from, the change stream every listener holds, and
/// the live subscriptions downstream of it. The store keeps its identity and
/// the *remote* is attached and detached underneath it by the listener below.
///
/// That is also why the re-attach is not optional. `Database.db` is never
/// reassigned anywhere in this tree, so the handle taken at the last attach is
/// the old one after a reconnect, and a write through a closed handle fails
/// with a driver error rather than reporting itself as offline
/// (`config_store.dart`'s `attachRemote` doc). `attachRemote` is idempotent
/// per handle and a *different* handle detaches the old engine and reconciles
/// from scratch, so calling it on every rebuild is both necessary and cheap.
final configStoreProvider = FutureProvider<GuardedConfigStore>((ref) async {
  final store = ConfigStore(
    local: deviceLocalDatabase(),
    stationScope: ConfigScope.forStation(ref.read(stationNameProvider)),
    station: ref.read(stationNameProvider),
  );
  // Fills the snapshot from the local mirror, having first re-homed Phase 1's
  // station-scoped blob. No network: a station with no Postgres serves the
  // plant's wiring from here and comes up.
  await store.open();
  ref.onDispose(store.close);

  final guarded = GuardedConfigStore(
    inner: store,
    policy: ref.read(accessPolicyProvider),
    // A callback, and never a watch on the session provider: a watch would
    // rebuild this provider on every sign-in, sign-out and inactivity timeout,
    // which for this provider means throwing the snapshot away.
    session: () => sessionInForce(ref),
    audit: RefAuditSink(ref),
    station: ref.read(stationNameProvider),
    onDenied: (denial) => reportAccessDenial(ref, denial),
  );

  // The attachment, serialised: a reconnect that arrives while the previous
  // attach is still migrating must queue behind it rather than interleave two
  // migrations and two reconciles on one store.
  var pending = Future<void>.value();
  ref.listen<AsyncValue<Database?>>(
    databaseProvider,
    (previous, next) {
      // A provider that has not answered yet is not a station that has gone
      // offline. Detaching on `loading` would drop the remote on every
      // refresh, and the write path would report "the shared database is
      // unreachable" to an operator whose database is fine.
      if (next.isLoading && !next.hasValue) return;
      final db = next.valueOrNull;
      pending = pending.then((_) => _attach(store, guarded, db));
    },
    fireImmediately: true,
  );

  return guarded;
});

/// Points [store] at [db], having first given the blob→rows migration its one
/// chance to run against it.
///
/// Never throws: this runs from a provider listener with nobody to catch it,
/// and a station whose shared database is misbehaving must still come up on
/// its mirror.
Future<void> _attach(
    ConfigStore store, GuardedConfigStore guarded, Database? db) async {
  if (db == null) {
    store.detachRemote();
    return;
  }
  try {
    _logMigration(await migrateKeyMappingsBlobToRows(db));
    store.attachRemote(db);
    await guarded.seedDefaultIfEmpty();
  } catch (error, stackTrace) {
    _logger.e(
      'The shared configuration store could not be attached. This station '
      'serves the key mappings its local mirror holds and will try again at '
      'the next database reconnect.',
      error: error,
      stackTrace: stackTrace,
    );
  }
}

/// Says what the migration did, at the level its consequences deserve.
///
/// An **exhaustive switch with no default arm**: a new [MigrationOutcome]
/// must fail compilation here rather than fall silently into a `default` that
/// says nothing. The return value of that function is not ignorable — a
/// migration that did not run is a station serving nothing, and the only
/// place that is visible is this line.
void _logMigration(MigrationOutcome outcome) {
  switch (outcome) {
    case MigrationOutcome.migrated:
      _logger.i('key_mappings migration: the blob was copied into rows; this '
          'plant is now on relational configuration');
    case MigrationOutcome.alreadyDone:
      _logger.i('key_mappings migration: already done, nothing written');
    case MigrationOutcome.heldByAnother:
      // Not a failure and not even a delay worth naming: the reconcile that
      // the attach below queues brings the rows here seconds later.
      _logger.i('key_mappings migration: another station holds the lock and '
          'is running it; this station picks the rows up at its next '
          'reconcile');
    case MigrationOutcome.noBlob:
      _logger.w('key_mappings migration: the shared database has no '
          'key_mappings blob to copy. On a fresh plant that is expected; on '
          'this plant it means this station is pointed at the wrong database');
    case MigrationOutcome.notPostgres:
      // Unreachable from here — the listener only fires with a real Database,
      // and Database cannot wrap a SQLite config at all. Reaching it means
      // something upstream changed, and a loud line is how that is found.
      _logger.e('key_mappings migration: the attached shared database does '
          'not report the postgres dialect. This path only ever runs against '
          'Postgres, so this is a bug in how the database was built, not a '
          'configuration mistake');
    case MigrationOutcome.unsafePool:
      // The split-brain the coordinated rollout exists to prevent, and the
      // line the cutover runbook greps for. Deliberately NOT a boot refusal:
      // a panel on a plant floor has to come up. Deliberately not silent
      // either.
      _logger.e(
          'key_mappings migration REFUSED: this process pools more than one '
          'connection ($kMaxPoolConnectionsEnv), and the transaction the '
          'migration needs is atomic only at a pool of one. Three '
          'consequences: (1) this station DID NOT migrate; (2) it will serve '
          'empty or stale key mappings until a correctly-configured station '
          'runs the migration, after which its reconcile converges it; and '
          '(3) every shared configuration write from this process is refused '
          'by the store\'s own pool guard. Set $kMaxPoolConnectionsEnv to 1 '
          '(or unset it) and restart this station.');
  }
}

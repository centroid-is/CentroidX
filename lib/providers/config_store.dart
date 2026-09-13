import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';
import 'package:tfc_dart/core/access/guarded_config_store.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_store.dart';
import 'package:tfc_dart/core/config/key_mapping_migration.dart';
import 'package:tfc_dart/core/config/preference_migration.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_connections.dart' show kMaxPoolConnectionsEnv;

import '../core/config/page_migration.dart';

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
  // `unawaited()` would not do here: it attaches no error handler, so a throw
  // out of a dispose would become an unhandled asynchronous error in whatever
  // zone the container happened to be torn down in.
  ref.onDispose(() {
    store.close().catchError((Object e) =>
        _logger.w('the configuration store did not close cleanly: $e'));
  });

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
    // Both migrations before the store is handed to the sync engine, and in
    // this order: the key mappings first because Phase 2 shipped them first
    // and a plant mid-rollout may have them on rows already, the pages second.
    // They take different advisory locks and share nothing but the
    // transaction discipline, so a station that loses one may still win the
    // other — which is why the outcome of each is logged on its own line.
    _logMigration('key_mappings', await migrateKeyMappingsBlobToRows(db));
    _logMigration('pages', await migratePageBlobToRows(db));
    // Third, and after both, because it refuses to run until their markers
    // are there: its families are what is *left* in `flutter_preferences`
    // once the two blobs have gone, and a run before them would write rows
    // those migrations are about to write differently.
    //
    // Wired here rather than behind a hand-run command, and that is the whole
    // delivery mechanism: the cutover window's step 4 is "deploy the build and
    // start one station", and this is what makes that sentence true. A
    // migration only invocable by hand would leave the window with no command
    // and 04-12's drop gates unreachable.
    _logPreferenceMigration(await migratePreferencesIntoRows(db));
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

/// The one line the cutover runbook's step 4 greps for, at the level each
/// outcome deserves.
///
/// Separate from [_logMigration] because this migration's result is not a bare
/// outcome: the runbook needs the per-family counts and 04-12's drop tool
/// needs the unknown names, so the evidence is the line rather than a
/// paraphrase of it. An **exhaustive switch with no default arm**, for the
/// same reason its sibling has one.
void _logPreferenceMigration(PreferenceMigrationResult result) {
  switch (result.outcome) {
    case PreferenceMigrationOutcome.migrated:
      // The evidence line itself, verbatim — counts, families, unknown names.
      _logger.i(result.evidenceLine);
    case PreferenceMigrationOutcome.alreadyDone:
      _logger.i('Preference migration: already done, nothing written');
    case PreferenceMigrationOutcome.heldByAnother:
      _logger.i('Preference migration: another station holds the lock and '
          'is running it; this station picks the rows up at its next '
          'reconcile');
    case PreferenceMigrationOutcome.noTable:
      // Every boot after 04-12 drops the table lands here. Not a warning:
      // this is the end state the whole milestone is walking towards.
      _logger.i('Preference migration: flutter_preferences is gone; nothing '
          'left to copy');
    case PreferenceMigrationOutcome.siblingsNotMigrated:
      // Loud, because it means the plant is half-migrated and the runbook's
      // evidence line will be missing — but a skip, so the station comes up.
      _logger.w('Preference migration: skipped because the key_mappings or '
          'pages migration has not run. This station is serving what it has; '
          're-check the attach ordering before running the cutover window.');
    case PreferenceMigrationOutcome.notPostgres:
      _logger.e('Preference migration: the attached shared database does not '
          'report the postgres dialect. This path only ever runs against '
          'Postgres, so this is a bug in how the database was built.');
    case PreferenceMigrationOutcome.unsafePool:
      _logger.e('Preference migration: refused because this process pools '
          'more than one connection. Nothing was written.');
  }
}

/// Says what the migration did, at the level its consequences deserve.
///
/// An **exhaustive switch with no default arm**: a new [MigrationOutcome]
/// must fail compilation here rather than fall silently into a `default` that
/// says nothing. The return value of that function is not ignorable — a
/// migration that did not run is a station serving nothing, and the only
/// place that is visible is this line.
void _logMigration(String label, MigrationOutcome outcome) {
  switch (outcome) {
    case MigrationOutcome.migrated:
      _logger.i('$label migration: the blob was copied into rows; this '
          'plant is now on relational configuration');
    case MigrationOutcome.alreadyDone:
      _logger.i('$label migration: already done, nothing written');
    case MigrationOutcome.heldByAnother:
      // Not a failure and not even a delay worth naming: the reconcile that
      // the attach below queues brings the rows here seconds later.
      _logger.i('$label migration: another station holds the lock and '
          'is running it; this station picks the rows up at its next '
          'reconcile');
    case MigrationOutcome.noBlob:
      _logger.w('$label migration: the shared database has no $label '
          'blob to copy. On a fresh plant that is expected; on this plant it '
          'means this station is pointed at the wrong database');
    case MigrationOutcome.notPostgres:
      // Unreachable from here — the listener only fires with a real Database,
      // and Database cannot wrap a SQLite config at all. Reaching it means
      // something upstream changed, and a loud line is how that is found.
      _logger.e('$label migration: the attached shared database does '
          'not report the postgres dialect. This path only ever runs against '
          'Postgres, so this is a bug in how the database was built, not a '
          'configuration mistake');
    case MigrationOutcome.unsafePool:
      // The split-brain the coordinated rollout exists to prevent, and the
      // line the cutover runbook greps for. Deliberately NOT a boot refusal:
      // a panel on a plant floor has to come up. Deliberately not silent
      // either.
      _logger.e(
          '$label migration REFUSED: this process pools more than one '
          'connection ($kMaxPoolConnectionsEnv), and the transaction the '
          'migration needs is atomic only at a pool of one. Three '
          'consequences: (1) this station DID NOT migrate; (2) it will serve '
          'empty or stale $label until a correctly-configured station '
          'runs the migration, after which its reconcile converges it; and '
          '(3) every shared configuration write from this process is refused '
          'by the store\'s own pool guard. Set $kMaxPoolConnectionsEnv to 1 '
          '(or unset it) and restart this station.');
  }
}

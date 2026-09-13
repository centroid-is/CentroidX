/// The repository that owns the plant's shared configuration rows — key
/// mappings, pages and their assets ([kSharedConfigKinds]): an in-memory
/// snapshot, filled from local SQLite at boot, with exactly one write path to
/// Postgres.
///
/// One store and one snapshot across the kinds, rather than one per kind,
/// because a save is one transaction and one action: a page and the assets on
/// it move together, and two stores would mean two compare-and-swaps, two
/// change logs to correlate and no way to roll one back when the other lost.
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
/// There is exactly one in the whole library — `config_sync.dart`'s gate on
/// the notification channel, because LISTEN/NOTIFY is a thing SQLite does not
/// have rather than a thing it spells differently. Everywhere else, and
/// nowhere in this file, there is no `if (postgres) … else …`. Drift's typed
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
import 'config_history_policy.dart';
import 'config_item.dart';
import 'config_store_errors.dart';
// Prefixed: the codec's `keyMappingItems` and this store's getter of the same
// name are two different things, and inside the class the getter would win.
import 'key_mapping_codec.dart' as codec;
// One constant, and no policy type: the marker is how the sync engine tells a
// plant with no key mappings from one whose migration has not run. Spelling it
// out here instead would be a second definition of the same row.
import 'key_mapping_migration.dart' show kKeyMappingsMigratedMarkerId;
import 'sort_keys.dart';

part 'config_sync.dart';

/// The local row that records how far this station has consumed the shared
/// change log.
///
/// `kind='preference'` at the station's own scope, with an underscore-prefixed
/// id so that [SqlitePreferences] never surfaces it as a setting — the
/// convention the one-shot import marker established. Written by the sync
/// engine; this store only restores it at [ConfigStore.open].
const String kKeyMappingsWatermarkId = '_sync.key_mappings.watermark';

/// The kinds Postgres owns, every station mirrors, and the sync engine is
/// allowed to replace.
///
/// **What keeps a station's own rows out is the scope filter, not this set.**
/// Every read here and in the sync engine is `kind IN (…) AND scope='shared'`
/// — the boot fill, the rev sweep, the remote revision read and the change-log
/// pull alike. The **watermark** is a `preference` row at
/// `station:<hostname>`, so no sweep can see it and no station's position can
/// overwrite another's, whatever this set says.
///
/// The **migration markers are not**, and an earlier draft of this paragraph
/// said they were. [kPreferencesMigratedMarkerId] and its siblings are
/// `scope='shared'` rows and have to be: `_remoteIsMigrated` reads them off
/// the remote to tell an empty shared store from an unmigrated one, which is a
/// question about the plant and not about this machine. They are in the sweep
/// and in the change log like any shared row — which is why `config_undo.dart`
/// refuses to restore an underscore-prefixed preference by name, rather than
/// relying on a scope that does not separate them.
///
/// [ConfigKind.preference] joined the set in 04-05, when the shared
/// `PreferencesApi` moved off `flutter_preferences` onto rows. Two reasons,
/// and the first is not a preference at all:
///
///   * A kind outside this set is outside the boot snapshot, and a kind
///     outside the snapshot has no `rev` for [writeItems] to compare and swap
///     against. Its every write would diff as an *insert*, so the second one
///     would collide with the row the first wrote — the shared store would
///     have been unusable rather than merely un-synced.
///   * `flutter_preferences` had a keyed NOTIFY that reached every station.
///     A shared preference this station could not hear another station change
///     would be a regression against the table this milestone replaces.
///
/// [ConfigKind.pageImage] is in the set and has to be. It writes no
/// `config_change` rows at all (`config_history_policy.dart`), so the rev
/// sweep is the *only* net under it: a kind left out of here would not
/// propagate slowly, it would propagate never.
const Set<ConfigKind> kSharedConfigKinds = {
  ConfigKind.keyMapping,
  ConfigKind.page,
  ConfigKind.asset,
  ConfigKind.pageImage,
  ConfigKind.preference,
};

/// The marker the page/asset blob→rows migration writes last.
///
/// Same contract as [kKeyMappingsMigratedMarkerId] and the same reason for
/// existing: it is the only thing that tells a plant with legitimately no
/// pages from one whose migration has not run yet. Pages and their assets come
/// out of one blob in one transaction, so they share one marker — a state
/// where the pages migrated and their assets did not is not reachable.
const String kPagesMigratedMarkerId = '_migrated.pages';

/// The marker the `flutter_preferences`→rows migration writes last.
///
/// Defined here, with the other two, rather than in the migration that writes
/// it (04-11): [kMigrationMarkerIds] must name a marker for every kind under
/// sync, and `preference` came under sync in 04-05 — one plan earlier. Until
/// the migration lands, `_remoteIsMigrated(preference)` answers false, which
/// costs nothing: a kind is only *refused* when this station holds mirrored
/// rows of it and the remote holds none, and before the migration both are
/// empty.
const String kPreferencesMigratedMarkerId = '_migrated.preferences';

/// Which marker row answers "has this kind been migrated?".
///
/// Per kind, and never one shared answer, because the question is per kind:
/// on the cutover boot the key mappings are on rows and the pages are still in
/// the blob, so a single flag would either refuse a sweep that should run or
/// permit one that empties the mirror. Every kind under sync must have an
/// entry — a kind with none would have "the remote holds nothing" read as
/// "everything was deleted", which is the one answer that loses data.
const Map<ConfigKind, String> kMigrationMarkerIds = {
  ConfigKind.keyMapping: kKeyMappingsMigratedMarkerId,
  ConfigKind.page: kPagesMigratedMarkerId,
  ConfigKind.asset: kPagesMigratedMarkerId,
  // The images come out of the same page blob in the same transaction, so the
  // page marker is the honest answer for them too: there is no state where the
  // pages migrated and their images did not.
  ConfigKind.pageImage: kPagesMigratedMarkerId,
  // Its own marker: the preferences leave `flutter_preferences` in their own
  // migration (04-11), on a plant whose pages may have moved a release
  // earlier, so the page marker would be an answer to a different question.
  ConfigKind.preference: kPreferencesMigratedMarkerId,
};

/// The wire names of [kinds], for an `IN` clause. Bound variables, never
/// interpolated, exactly as [ConfigStore._identity] is.
List<String> _wireNamesOf(Iterable<ConfigKind> kinds) =>
    [for (final kind in kinds) kind.wireName];

/// Canonical item order: kind, then id. The same order `config_diff` sorts
/// into, so a snapshot read and a diff of it agree.
int _byKindThenId(ConfigItem a, ConfigItem b) {
  final byKind = a.kind.index.compareTo(b.kind.index);
  return byKind != 0 ? byKind : a.id.compareTo(b.id);
}

/// One item's identity inside an in-memory snapshot: its kind and its id.
///
/// `config_item`'s primary key is `(kind, id, scope)` and the **scope is
/// deliberately not here**: a snapshot holds one scope — shared — so carrying
/// it would be a constant in every key. `config_diff`'s own `_key` does carry
/// it, because a diff may legitimately be handed a station-scoped item beside
/// a shared one and collapsing those two would make a station's own setting
/// look like an edit to everybody's.
///
/// The kind, on the other hand, is load-bearing today and structural from
/// Phase 3: a page path and a mapping key may be the same string, the table
/// allows it, and an index keyed by id alone would have one silently evict the
/// other. The symptom of that would be a mimic bound to a key that resolves to
/// a page — so the composite key lands now, while this store holds one kind
/// and the change is provably behaviour-preserving.
String configSnapshotKey(ConfigKind kind, String id) =>
    '${kind.wireName} $id';

/// [item]'s key in a snapshot. See [configSnapshotKey].
String _snapshotKeyOf(ConfigItem item) => configSnapshotKey(item.kind, item.id);

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

/// The shared-configuration repository. See the library doc for ownership.
class ConfigStore {
  ConfigStore({
    required AppDatabase local,
    required ConfigScope stationScope,
    required String station,
    Database? remote,
    Duration sweepInterval = kConfigSweepInterval,
  })  : _local = local,
        _stationScope = stationScope,
        _station = station,
        _sweepInterval = sweepInterval {
    // A remote given here is attached exactly as one given later is, timer and
    // notification channel included. Two ways to hand over a remote is
    // tolerable; two meanings of "attached" is not.
    if (remote != null) _attach(remote.db);
  }

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

  /// The sync engine for the attached remote, or null when there is none. Its
  /// life is the attachment: see [_ConfigSync].
  _ConfigSync? _sync;

  /// How often the attached engine runs its full revision sweep.
  final Duration _sweepInterval;

  /// The shared rows, keyed by [configSnapshotKey] — kind and id, never id
  /// alone. Replaced wholesale on every swap; never handed out.
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
  ///
  /// Runs on the sync engine's serialisation chain when a remote is attached.
  /// Without that, an `open()` racing a reconcile would refill the snapshot
  /// from the mirror behind the reconcile's back and quietly undo it — which
  /// is the shape of every "the station came up with yesterday's wiring" bug
  /// this milestone exists to end.
  Future<void> open() {
    final sync = _sync;
    return sync == null ? _open() : sync.serialise(_open);
  }

  Future<void> _open() async {
    await _rehomePhase1Cache();
    final snapshot = <String, ConfigItem>{};
    for (final row in await _sharedRowsOf(kSharedConfigKinds)) {
      final item = _itemOf(row);
      if (item != null) snapshot[_snapshotKeyOf(item)] = item;
    }
    _snapshot = snapshot;
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
  List<ConfigItem> get keyMappingItems => itemsOf(const {
        ConfigKind.keyMapping,
      });

  /// The stored items in [kinds], as a fresh list every call, in canonical
  /// (kind, id) order.
  ///
  /// The read half of the store going item-shaped. A caller asking for
  /// `{page, asset}` gets those and nothing else — which is what makes
  /// [writeItems]' replace-within-kinds contract expressible: the same set
  /// names what is compared and what may therefore be removed.
  ///
  /// [ConfigItem] is immutable, so a copy of the list is the whole defence.
  List<ConfigItem> itemsOf(Set<ConfigKind> kinds) {
    final items = [
      for (final item in _snapshot.values)
        if (kinds.contains(item.kind)) item,
    ];
    return items..sort(_byKindThenId);
  }

  /// Emits once after every snapshot swap.
  Stream<ConfigDiff> get keyMappingChanges => _changes.stream;

  /// How far this station has consumed the shared change log.
  int get watermark => _watermark;

  /// Whether a shared write can even be attempted right now.
  bool get hasRemote => _remote != null;

  /// Points the write path at [remote] and starts the sync engine: a full
  /// revision reconcile, the `config_change` notification channel, and the
  /// five-minute sweep.
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
  ///
  /// Idempotent per handle: attaching the same [Database] twice reconciles
  /// once and leaves one subscription and one timer. Attaching a *different*
  /// one detaches the old first — which is why the re-attach reconciles rather
  /// than pulls: notifications sent while nothing was listening are gone, and
  /// no watermark can describe what they said.
  ///
  /// Returns immediately. The reconcile is queued; [syncSettled] is how a test
  /// waits for it.
  void attachRemote(Database remote) => _attach(remote.db);

  /// Cancels the notification subscription and the sweep timer, and forgets
  /// the remote. The snapshot and the mirror are untouched — they are exactly
  /// what an offline boot serves.
  void detachRemote() {
    _sync?.stop();
    _sync = null;
    _remote = null;
  }

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
  ///
  /// [startSync] false attaches everything except the things that run on their
  /// own: no initial reconcile, no notification channel, no sweep timer.
  /// [pullChanges] and [reconcile] still work, and are then the *only* way
  /// anything is applied.
  ///
  /// Two kinds of test need it. One drives the pull and the sweep by hand and
  /// asserts which rows each of them touched, which a background reconcile
  /// would answer for them. The other has to control the window between
  /// another station's write and this store's next save: with sync running
  /// that window closes on its own — a property the integration suite proves
  /// on purpose, and one a compare-and-swap test may not quietly depend on.
  @visibleForTesting
  void attachRemoteDatabase(AppDatabase remote, {bool startSync = true}) =>
      _attach(remote, startSync: startSync);

  void _attach(AppDatabase remote, {bool startSync = true}) {
    if (identical(_remote, remote) && _sync?.started == startSync) return;
    detachRemote();
    _remote = remote;
    final sync = _ConfigSync(this, remote, _sweepInterval);
    _sync = sync;
    if (!startSync) return;
    sync.start();
    sync._swallow(sync.reconcile());
  }

  /// Runs [task] on the sync engine's serialisation chain, so a notification
  /// apply cannot land in the middle of a caller's check-then-write.
  ///
  /// [writeItems] runs on it too. An earlier version kept it off, so that a
  /// save would never wait behind a sweep, and trusted the compare-and-swap —
  /// but the CAS guards the *remote* against a stale writer, not the snapshot
  /// against an apply landing between a save's diff and its snapshot swap.
  /// That gap is the one `_apply` reads across: a pull that had already
  /// fetched "P is absent" when the save inserted P went on to delete P from
  /// the snapshot and the mirror, and the page the operator had just created
  /// vanished from their own editor until the next sweep. A sweep is one
  /// short query per kind and the chain is idle between notifications, so
  /// the wait a save pays is microseconds in the ordinary case and
  /// milliseconds in the unusual one; the lost write was worth more.
  ///
  /// **Re-entrant.** A task already running on the chain that calls this
  /// again — `config_undo.dart` asserts its verdict here and then calls
  /// [writeItems], which is itself on the chain — runs [task] directly rather
  /// than queueing it behind itself, which would deadlock. The chain marks its
  /// zone, and that mark is what tells the two apart.
  ///
  /// A store with no engine runs [task] directly, and so does one whose engine
  /// was stopped between the queue and the run — a detach mid-flight. That is
  /// deliberate: after a detach the store has no remote, so the task refuses
  /// with the ordinary [ConfigStoreOfflineException] rather than returning a
  /// success nobody made.
  Future<T> serialiseWrite<T>(Future<T> Function() task) async {
    final sync = _sync;
    if (sync == null || _ConfigSync.onChain) return task();
    final done = <T>[];
    await sync.serialise(() async => done.add(await task()));
    return done.isEmpty ? await task() : done.single;
  }

  /// Completes when every sync task queued so far has been applied.
  ///
  /// The app does not need this to *serve* configuration — the stream and the
  /// snapshot are the interface, and both are only ever updated at the end of
  /// one of these tasks. It needs it to answer one question: **is the shared
  /// store empty, or has this station simply not read it yet?** The snapshot
  /// is filled from the local mirror, so a fresh station attached to a fully
  /// configured plant holds nothing until the first reconcile lands. A boot
  /// seed that did not wait here would write its example key into a plant with
  /// four hundred of its own.
  ///
  /// A store with no remote settles immediately: there is nothing queued and
  /// nothing coming.
  Future<void> get syncSettled => _sync?.settled ?? Future<void>.value();

  /// Consumes the shared change log from the watermark — the fast path a
  /// notification triggers, exposed so the unit lane can trigger it by hand.
  @visibleForTesting
  Future<void> pullChanges() => _sync?.pull() ?? Future<void>.value();

  /// Where the post-commit nudge goes, when a test wants to see it.
  ///
  /// `pg_notify` needs a Postgres server, and everything else about the nudge
  /// — when it fires, which kinds it names, that it never fires for a
  /// rolled-back write — is provable without one. The transport itself is
  /// proved against a real server in 04-09's integration test.
  @visibleForTesting
  Future<void> Function(String channel, String payload)? notifyChannelForTest;

  /// One notification, as the LISTEN subscription would deliver it.
  ///
  /// The receiving half of the same split: the payload's meaning is decided
  /// here and the delivery is Postgres's problem.
  @visibleForTesting
  Future<void> handleNotificationForTest(String payload) =>
      _sync?.onNotification(payload) ?? Future<void>.value();

  /// The full revision sweep — the net under the watermark, exposed for the
  /// same reason.
  @visibleForTesting
  Future<void> reconcile() => _sync?.reconcile() ?? Future<void>.value();

  /// Brings the snapshot level with the remote now, rather than at the next
  /// notification or sweep.
  ///
  /// For a caller that has just been told another station won a row and is
  /// about to reload from the snapshot: the conflict is evidence the snapshot
  /// is behind, so a reload that does not sweep first may show the operator
  /// the layout they already had. Completes when the sweep has been applied;
  /// resolves at once with nothing done when no remote is attached, which is
  /// the ordinary offline case and not an error.
  Future<void> resync() => _sync?.reconcile() ?? Future<void>.value();

  /// Whether the five-minute sweep is running. False for a store with no
  /// remote, which is the whole point: a widget test that never attached one
  /// must not be left holding a periodic timer.
  @visibleForTesting
  bool get sweepTimerActive => _sync?.sweepTimerActive ?? false;

  /// Whether a `config_change` LISTEN subscription is open. False against a
  /// non-Postgres remote — see [_ConfigSync._listen].
  @visibleForTesting
  bool get notificationsActive => _sync?.notificationsActive ?? false;

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
  }) =>
      writeItems(
        kinds: const {ConfigKind.keyMapping},
        wanted: codec.keyMappingItems(wanted),
        actionId: actionId,
        who: who,
        roleName: roleName,
        reason: reason,
      );

  /// The one write path, for every kind: the shared rows on the remote, the
  /// mirror behind them, the snapshot, and one event.
  ///
  /// ## Replace within kinds
  ///
  /// [wanted] is the complete configuration **of [kinds]**, and [kinds] is
  /// what bounds the damage. A stored item of a kind in [kinds] that is absent
  /// from [wanted] is a removal; a stored item of any other kind is not in the
  /// comparison at all. That is what lets a pages save be a whole-pages
  /// replace without it also being a delete of every key mapping on the plant
  /// (T-03-01). An item in [wanted] whose kind is outside [kinds] is an
  /// [ArgumentError]: it could only ever be inserted and never removed, which
  /// is a write path with no matching read and the shape of a leak.
  ///
  /// ## Ordering keys
  ///
  /// [wanted]'s `sortIndex` values are read as **ordinals** — rank within a
  /// parent, as the codecs emit them, 0..n-1 — and rewritten to stored keys
  /// against this store's own snapshot immediately before the diff. An item
  /// whose relative order did not change keeps the exact key it had and never
  /// reaches the diff, which is what makes dragging one asset one row rather
  /// than one row per sibling. See `sort_keys.dart`.
  ///
  /// [actionId] is the caller's and is shared with the `audit_entry` row the
  /// app layer writes for the same action. [who] and [roleName] are likewise
  /// the caller's: this layer has no session to ask.
  ///
  /// ## Order of the checks, and why refusal comes before the diff
  ///
  /// The remote and the pool are checked **before** the diff is computed, so a
  /// save with nowhere to go is refused even when it happens to change
  /// nothing. That is the fail-loud reading of the offline rule: a caller
  /// whose write cannot reach Postgres is told so every time, rather than
  /// being told so only when it would have written something. A caller that
  /// legitimately saves-if-changed while offline — a boot seed, say — must
  /// therefore compare against [itemsOf] itself rather than calling this and
  /// hoping.
  ///
  /// Throws [ConfigStoreOfflineException] when there is no remote or the
  /// connection dies mid-write, [ConfigStoreUnsafePoolException] when the
  /// pool is wider than one, and [ConfigConflict] when another station moved
  /// a row first. In every one of those cases nothing is committed anywhere.
  Future<ConfigWriteResult> writeItems({
    required Set<ConfigKind> kinds,
    required List<ConfigItem> wanted,
    required String actionId,
    required String who,
    required String roleName,
    String? reason,
  }) =>
      serialiseWrite(() => _writeItems(
            kinds: kinds,
            wanted: wanted,
            actionId: actionId,
            who: who,
            roleName: roleName,
            reason: reason,
          ));

  Future<ConfigWriteResult> _writeItems({
    required Set<ConfigKind> kinds,
    required List<ConfigItem> wanted,
    required String actionId,
    required String who,
    required String roleName,
    String? reason,
  }) async {
    final attempted = _describeItems(kinds, wanted);
    final seen = <String>{};
    for (final item in wanted) {
      // Scope, before kind. The snapshot this diff compares against is keyed
      // by (kind, id) and holds shared rows only, while `config_diff` keys by
      // (kind, id, **scope**) — so a station-scoped item smuggled in here
      // would be diffed as an insert *and* leave its shared namesake reading
      // as removed: one save that writes a `station:` row into Postgres and
      // deletes the shared one. No caller can do that today, but `preference`
      // is the first kind that legitimately exists at both scopes, so the
      // accident now has material to work with.
      if (!item.scope.isShared) {
        throw ArgumentError.value(
            item.scope,
            'wanted',
            'holds ${item.kind.wireName} "${item.id}" at ${item.scope}, which '
                'is this station\'s own row. Only shared rows are written '
                'here; a station row belongs to its own store.');
      }
      if (!kinds.contains(item.kind)) {
        throw ArgumentError.value(
            item.kind,
            'wanted',
            'holds a ${item.kind.wireName} item (${item.id}) outside the '
                'kinds being replaced ($attempted). Such an item could be '
                'inserted and never removed; name its kind in `kinds` or '
                'leave it out.');
      }
      // Two items with one identity would be collapsed by the diff, which
      // keys by (kind, id, scope) and keeps whichever came last — so one of
      // them would silently never be written, and nothing would say so. A
      // caller that produced a duplicate has a bug upstream (two pages
      // adopting one row, say), and that must surface here rather than as
      // an asset that vanished from a mimic.
      if (!seen.add(_snapshotKeyOf(item))) {
        throw ArgumentError.value(
            item.id,
            'wanted',
            'holds ${item.kind.wireName} "${item.id}" twice. The diff keys '
                'by identity and would keep one of them at random; the '
                'caller has to decide which is the real one.');
      }
    }

    final remote = _remote;
    if (remote == null) {
      throw ConfigStoreOfflineException(attempted: attempted);
    }
    final poolSize = resolvePoolSize(remote.config.maxPoolConnections);
    if (poolSize > 1) {
      throw ConfigStoreUnsafePoolException(
          attempted: attempted, poolSize: poolSize);
    }

    final stored = itemsOf(kinds);
    // The revisions this save compares-and-swaps against, captured **once**,
    // here, with the diff. A pull or a sweep may swap `_snapshot` at any await
    // below — including between two statements of the transaction. Reading the
    // revision off the live snapshot at that point would move the target under
    // the CAS: another station's edit that the sync had just applied would be
    // matched at its *new* revision and overwritten with a payload derived
    // from the old one, which is precisely the lost write the CAS exists to
    // refuse. The diff was computed against this list, so this list is what
    // the CAS must guard with.
    final storedByKey = {for (final item in stored) _snapshotKeyOf(item): item};
    // Ordinals become stored keys here, and here only: after the refusals, so
    // an offline save is still refused before any work, and immediately before
    // the diff, so what the diff compares is what will be written. An item
    // whose relative order did not change comes out of this holding the exact
    // key the snapshot holds, which is what makes it invisible to the diff.
    final keyed = assignSortKeys(wanted, {
      for (final item in stored)
        if (item.sortIndex != null) _snapshotKeyOf(item): item.sortIndex!,
    });
    final diff = diffConfigItems(stored: stored, wanted: keyed);
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
          // C-12. An insert has no `rev` to compare against, so its collision
          // is the (kind, id, scope) primary key — and left to the driver that
          // surfaces as a raw unique-violation from inside the transaction:
          // a stack trace where the update arm gives a sentence. The read is
          // inside the transaction and immediately before the insert, which is
          // as narrow as this can be made without a rev to swap on; the unique
          // constraint is still the backstop underneath it.
          final existing = await (remote.select(remote.configItemTable)
                ..where((t) => _identity(t, item))
                ..limit(1))
              .getSingleOrNull();
          if (existing != null) {
            throw ConfigConflict.created(item.id);
          }
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
          written[_snapshotKeyOf(item)] =
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
          // The revision comes from the list the diff was computed against,
          // never from a read inside this transaction and never from the
          // live `_snapshot`: re-reading it would turn the compare-and-swap
          // back into the read-check-write it exists to replace, and the
          // window it closes is precisely the one another station writes in.
          final stored = storedByKey[_snapshotKeyOf(item)]!;
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
          written[_snapshotKeyOf(item)] = item.stored(
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
      next.remove(_snapshotKeyOf(item));
    }
    next.addAll(written);
    _snapshot = next;

    try {
      await _writeMirror(diff, written);
    } catch (e) {
      _markMirrorDirty(diff, written);
      _logger.e('config mirror write failed after the shared write '
          'committed; this station serves the change from memory and the '
          'mirror is repaired at the next sweep: $e');
    }

    await _nudgeExemptKinds(remote, diff);

    _changes.add(diff);
    return ConfigWriteResult(diff: diff, actionId: actionId);
  }

  /// Tells the other stations to reconcile the exempt kinds this commit
  /// touched, because nothing else will.
  ///
  /// Both of the ways a station hears about a shared write are driven by
  /// change rows — the `AFTER INSERT ON config_change` trigger
  /// (`database_drift.dart:731-733`) and the `config_change.id` watermark
  /// (`config_sync.dart:12-13`) — and an exempt item writes none. Without this
  /// the other stations would learn about an uploaded image only on the
  /// five-minute rev sweep: the asset would arrive in seconds and the picture
  /// it points at minutes later, which is a broken mimic in between and a
  /// regression against the keyed `flutter_preferences` trigger this milestone
  /// replaces.
  ///
  /// Three properties, each deliberate:
  ///
  ///   * **exempt kinds only.** An ordinary kind already notified through the
  ///     trigger; naming it here would be a second notification for one save.
  ///   * **after the commit, as its own statement.** A rolled-back write never
  ///     gets here, and a nudge for a write that then failed would ask for an
  ///     idempotent reconcile against committed state — harmless either way.
  ///   * **failure is logged, never thrown.** The save has already happened;
  ///     telling the operator it failed would have them do it twice. A
  ///     connection that dies between the commit and this notify degrades that
  ///     one write's propagation to sweep latency, which is the same failure
  ///     an ordinary write has when a notification is lost with its
  ///     connection.
  Future<void> _nudgeExemptKinds(AppDatabase remote, ConfigDiff diff) async {
    final kinds = <ConfigKind>{
      for (final item in [...diff.added, ...diff.changed, ...diff.removed])
        if (historyExempt(item.kind, item.id)) item.kind,
    };
    if (kinds.isEmpty) return;
    final send = notifyChannelForTest ?? remote.notifyChannel;
    try {
      await send(kConfigChangeChannel, encodeReconcileNudge(kinds));
    } catch (e) {
      _logger.w('the reconcile nudge for '
          '${kinds.map((k) => k.wireName).join(', ')} was not sent; the other '
          'stations will pick this write up on their next sweep instead: $e');
    }
  }

  /// Releases the change stream and everything an attach started. The
  /// databases are the caller's to close.
  ///
  /// The detach is not tidiness: a sweep timer outliving the store it feeds
  /// would go on reading a database its owner has closed, once every five
  /// minutes, for the life of the process.
  Future<void> close() {
    detachRemote();
    return _changes.close();
  }

  // ---------------------------------------------------------------------
  // What the sync engine reaches back into. See config_sync.dart.
  // ---------------------------------------------------------------------

  /// Adopts what a pull or a sweep read from the remote: the snapshot, then
  /// the mirror, then at most one event.
  ///
  /// [fresh] is keyed by [configSnapshotKey] and is every item to take as it
  /// now stands — including ones whose
  /// payload did not change but whose `rev` did, because the next
  /// compare-and-swap guards on that number and a stale one loses to a
  /// conflict nobody caused. [diff] is what to *announce*, which is content
  /// only, and may be empty when the whole apply was revisions.
  ///
  /// The order matches the write path's: the snapshot moves first because the
  /// plant's live subscriptions hang off it, and the mirror is a cache of a
  /// decision already made elsewhere, so a failure to write it is logged and
  /// repaired by the next sweep rather than reported.
  Future<void> _applyRemoteState(
      ConfigDiff diff, Map<String, ConfigItem> fresh) async {
    final next = Map<String, ConfigItem>.of(_snapshot);
    for (final item in diff.removed) {
      next.remove(_snapshotKeyOf(item));
    }
    next.addAll(fresh);
    _snapshot = next;

    try {
      await _writeMirror(diff, fresh);
    } catch (e) {
      // Remembered, because nothing else would repair it: the sweep compares
      // the remote against the *snapshot*, which now holds the change, so it
      // has no reason to re-read a row the mirror missed. Without the note
      // the mirror stayed behind for the life of the process and the next
      // offline boot served the pre-change wiring.
      _markMirrorDirty(diff, fresh);
      _logger.e('config mirror write failed while applying a shared change; '
          'this station serves the change from memory and the mirror is '
          'repaired at the next sweep: $e');
    }

    // No event for an apply that only moved revisions: every listener
    // re-points live subscriptions on one, and doing that for a write nobody
    // made is the noise this milestone exists to remove.
    if (diff.isNotEmpty) _changes.add(diff);
  }

  /// The mirror rows a write could not land, keyed as the snapshot is, each
  /// with the last item known under that key — for the identity a delete
  /// needs when the snapshot no longer holds it.
  final Map<String, ConfigItem> _mirrorDirty = {};

  void _markMirrorDirty(ConfigDiff diff, Map<String, ConfigItem> written) {
    for (final item in diff.removed) {
      _mirrorDirty[_snapshotKeyOf(item)] = item;
    }
    _mirrorDirty.addAll(written);
  }

  /// Retries the mirror rows [_markMirrorDirty] recorded, from what the
  /// snapshot holds for them now: a key the snapshot has is upserted, a key it
  /// no longer has is deleted. Run by the sweep; a failure leaves the keys
  /// noted for the next one.
  Future<void> _repairMirror() async {
    if (_mirrorDirty.isEmpty) return;
    final removed = <ConfigItem>[];
    final written = <String, ConfigItem>{};
    for (final entry in _mirrorDirty.entries) {
      final current = _snapshot[entry.key];
      if (current == null) {
        removed.add(entry.value);
      } else {
        written[entry.key] = current;
      }
    }
    try {
      await _writeMirror(
          ConfigDiff(added: const [], changed: const [], removed: removed),
          written);
      _mirrorDirty.clear();
      _logger.i('config mirror repaired: ${written.length} row(s) rewritten, '
          '${removed.length} removed');
    } catch (e) {
      _logger.w('config mirror repair failed; retried at the next sweep: $e');
    }
  }

  /// Records how far the shared change log has been consumed, in memory and in
  /// the local row [open] restores it from.
  ///
  /// Never goes backwards: a sweep that read an older maximum than a pull
  /// already consumed must not re-arm rows that have been applied.
  ///
  /// A failed row write is logged and dropped. The cost of losing it is that
  /// the next boot re-consumes part of a log it has already seen, which is
  /// idempotent and cheap; refusing to serve a live change because a
  /// bookkeeping row would not write is not.
  Future<void> _advanceWatermark(int value) async {
    if (value <= _watermark) return;
    _watermark = value;
    final companion = ConfigItemTableCompanion.insert(
      kind: ConfigKind.preference.wireName,
      id: kKeyMappingsWatermarkId,
      scope: _stationScope.wireName,
      // The `{"type": …, "value": …}` shape [SqlitePreferences] stores every
      // preference in, so the row is readable by the same code that reads the
      // rest of them rather than being a private format in a shared table.
      payload: ConfigItem.of(
        kind: ConfigKind.preference,
        id: kKeyMappingsWatermarkId,
        value: {'type': 'int', 'value': value},
        scope: _stationScope,
      ).payload,
      updatedAt: DateTime.now(),
      updatedBy: _syncWriter,
    );
    try {
      final replaced = await (_local.update(_local.configItemTable)
            ..where((t) =>
                t.kind.equals(ConfigKind.preference.wireName) &
                t.id.equals(kKeyMappingsWatermarkId) &
                t.scope.equals(_stationScope.wireName)))
          .write(companion);
      if (replaced == 0) {
        await _local.into(_local.configItemTable).insert(companion);
      }
    } catch (e) {
      _logger.w('key_mappings watermark row not written ($value); the next '
          'boot re-consumes part of a log it has already seen: $e');
    }
  }

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
  ///
  /// **The exemption is asked here and not at the call sites.** All three arms
  /// of [writeItems] end up in this method, and a fourth added later would
  /// too; asking in the arms would make the rule something a future arm has to
  /// remember. What is skipped is only the change row — the `config_item`
  /// write and its compare-and-swap have already happened and are untouched.
  /// See `config_history_policy.dart`.
  Future<void> _appendChange(AppDatabase db, ConfigChange change) =>
      historyExempt(change.kind, change.entityId)
          ? Future<void>.value()
          : db.into(db.configChangeTable).insert(
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
  /// carries the count and enough ids to recognise the save by. Three names,
  /// because the plant has ten thousand keys and an operator reading a
  /// snackbar needs to recognise the save, not audit it.
  ///
  /// A single-kind save reads in that kind's own words — "key mappings: 2
  /// keys (…)", which is what it said before this became generic and what the
  /// offline tests hold it to. A save spanning kinds (a page and its assets)
  /// has no such noun and says "configuration".
  static String _describeItems(Set<ConfigKind> kinds, List<ConfigItem> wanted) {
    final ids = [for (final item in wanted) item.id]..sort();
    final shown = ids.take(3).join(', ');
    final tail = ids.length > 3 ? ', …' : '';
    // A kind with no entry falls back to the generic noun rather than
    // throwing: this runs on the refusal path, and a save that could not be
    // written must not fail again while explaining itself.
    final (plural, one, many) = (kinds.length == 1
        ? _nouns[kinds.single] ?? _configurationNoun
        : _configurationNoun);
    return '$plural: ${ids.length} ${ids.length == 1 ? one : many}'
        '${ids.isEmpty ? '' : ' ($shown$tail)'}';
  }

  /// Per kind: what to call a save of it, and what to call one of its items.
  static const Map<ConfigKind, (String, String, String)> _nouns = {
    ConfigKind.keyMapping: ('key mappings', 'key', 'keys'),
    ConfigKind.page: ('pages', 'page', 'pages'),
    ConfigKind.asset: ('assets', 'asset', 'assets'),
    ConfigKind.preference: ('preferences', 'preference', 'preferences'),
    ConfigKind.pageImage: ('images', 'image', 'images'),
  };

  static const (String, String, String) _configurationNoun =
      ('configuration', 'item', 'items');

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

      final existing = await _sharedRowsOf(const {ConfigKind.keyMapping});
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

  /// The shared mirror rows of [kinds].
  ///
  /// Takes the kinds rather than assuming them: the boot fill wants every
  /// shared kind, and the re-home wants key mappings alone — it is asking
  /// whether *this* blob has already been decomposed, and a page row would be
  /// no answer to that.
  Future<List<ConfigItemRow>> _sharedRowsOf(Set<ConfigKind> kinds) =>
      (_local.select(_local.configItemTable)
            ..where((t) =>
                t.kind.isIn(_wireNamesOf(kinds)) &
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

  /// The item a stored row describes, or null when this build does not know
  /// the row's kind or scope.
  ///
  /// Kind and scope are read from the row rather than assumed from whatever
  /// the query filtered on: one snapshot now holds three kinds, and a
  /// hardcoded pair would label a page as a key mapping the moment the filter
  /// widened past the read that set it.
  ///
  /// Null rather than a throw, for the reason [ConfigKind.byWireName] is
  /// nullable: a row written by a newer station against the shared database
  /// must be skippable by an older one, not fatal to its whole boot.
  ///
  /// Carries `rev`, which is what the compare-and-swap guards with.
  ConfigItem? _itemOf(ConfigItemRow row) {
    final kind = ConfigKind.byWireName(row.kind);
    final scope = ConfigScope.byWireName(row.scope);
    if (kind == null || scope == null) {
      _logger.w('config row ${row.kind}:${row.id}@${row.scope} is of a kind '
          'or scope this build does not know; skipped');
      return null;
    }
    return ConfigItem(
      kind: kind,
      id: row.id,
      scope: scope,
      parentId: row.parentId,
      sortIndex: row.sortIndex,
      payload: row.payload,
      rev: row.rev,
      updatedAt: row.updatedAt,
      updatedBy: row.updatedBy,
    );
  }
}

/// The `updated_by` of a mirror row the re-home created.
///
/// Not `'anonymous'`: nobody wrote these, they were carried over from a cache
/// whose own row said nothing about who wrote it. Naming the move is what
/// stops a history reader attributing the plant's whole wiring to one
/// unidentified person at one instant.
const String _rehomedBy = 'rehome';

/// The Postgres half of [ConfigStore]: how a station learns that somebody
/// else changed the plant's wiring.
///
/// A `part` of `config_store.dart` rather than a library of its own, because
/// every operation here ends in the store's own state — the snapshot, the
/// mirror, the watermark row and the change stream. Reaching them through a
/// published interface would mean publishing three members that exist only for
/// this file to call, on a class the app layer holds.
///
/// ## Two paths, and why there have to be two
///
/// **The fast path** is `config_change.id` as a watermark: a NOTIFY arrives,
/// the store reads `SELECT DISTINCT entity_id … WHERE id > <watermark>`,
/// re-reads exactly those `config_item` rows and applies them. One indexed
/// query and a handful of rows for an ordinary save.
///
/// **The net** is a full revision sweep: `kind, id, rev` for every shared
/// `key_mapping` row — two short columns per key, some 80 kB for this plant
/// against the 530 kB blob the milestone retires — compared against the
/// snapshot's revisions, with anything that differs (or exists on only one
/// side) re-read through the same apply path.
///
/// The net is not optional and it is deliberately **not** a second `id >`
/// read. `config_change.id` is a `SERIAL`: the value is assigned at `INSERT`
/// and becomes visible at `COMMIT`, so a transaction that took id 100 and
/// committed after one that took 101 is invisible forever to any reader that
/// has advanced past 101 — and a poll built on the same predicate misses it
/// identically. `rev` has no sequence semantics: it is a property of the row
/// as it stands, so a reader that missed the moment still sees the difference
/// afterwards. That is C-6, and
/// `test/integration/config_store_integration_test.dart` builds the
/// out-of-order commit by hand and proves the sweep catches what the pull
/// cannot.
///
/// ## Failures are abandoned, never propagated
///
/// Everything here is remote reads plus local writes — there is no transaction
/// on the shared connection to leave aborted (C-5). A read that throws is
/// logged and the attempt is dropped: the next notification or the next sweep
/// retries, and the snapshot is only ever swapped after a complete read, so an
/// abandoned attempt leaves the station exactly as it was. Nothing here throws
/// into [ConfigStore.attachRemote] or a timer callback.
part of 'config_store.dart';

/// How often the rev sweep runs while a remote is attached.
///
/// Five minutes is the worst case for noticing a change that the change log
/// cannot describe — an out-of-order commit, a row edited in `psql`, a
/// notification lost with a connection. Ordinary saves arrive in
/// milliseconds through the fast path; this is the floor under them, not the
/// mechanism.
const Duration kConfigSweepInterval = Duration(minutes: 5);

/// How long to wait before re-opening a notification channel that ended.
///
/// [AppDatabase.listenToChannel]'s stream *ends* — `onDone`, no error — when
/// the connection carrying it dies, so a subscriber that does not re-listen
/// goes silent for the life of the process after the first reconnect. The
/// symptom would be a station that only ever learns about edits from the
/// five-minute sweep, which nobody would notice until an operator complained
/// that a save "takes minutes to reach the other screens". `bin/main.dart`
/// answers the same problem the same way.
const Duration kConfigRelistenBackoff = Duration(seconds: 5);

/// `updated_by` on the watermark row. Not a person: no operator wrote it.
const String _syncWriter = 'sync';

/// The sync engine for one attached remote.
///
/// Created by [ConfigStore.attachRemote] and thrown away by
/// [ConfigStore.detachRemote] — the object's life *is* the attachment, so
/// there is no "attached?" flag to get out of step with a timer that is still
/// running. A reconnect builds a new [Database] and therefore a new one of
/// these, which is exactly right: the notifications that arrived during the
/// gap are gone, so the re-attach must reconcile rather than pull.
class _KeyMappingSync {
  _KeyMappingSync(this._store, this._remote, this._sweepInterval);

  final ConfigStore _store;
  final AppDatabase _remote;
  final Duration _sweepInterval;

  /// The 5-minute net. Started by [start] and cancelled by [stop] — a store
  /// with no remote runs no timer at all, so a widget test that never attached
  /// one leaks nothing.
  Timer? _sweepTimer;

  /// The `config_change` LISTEN subscription, on Postgres only.
  StreamSubscription<String>? _channel;

  /// The re-listen backoff, held so [stop] can cancel it: a timer left running
  /// would re-open a channel on a remote the store has already let go of.
  Timer? _relisten;

  /// Set by [stop]. Read by the re-listen timer and by every apply, so work
  /// already in flight when the store detached lands nowhere.
  bool _stopped = false;

  /// Whether [start] has run. A sync engine that was never started still
  /// pulls and reconciles when asked — it simply never asks itself.
  bool _started = false;

  /// The serialisation chain. Two notifications arriving together, or a
  /// notification landing during a sweep, must not interleave their reads and
  /// their swaps — the loser would compute its diff against a snapshot that no
  /// longer exists and re-report an edit that had already been applied. Same
  /// shape as `lib/providers/state_man.dart:88`.
  Future<void> _pending = Future<void>.value();

  /// The tail of the chain: completes when everything queued so far has been
  /// applied.
  Future<void> get settled => _pending;

  bool get sweepTimerActive => _sweepTimer?.isActive ?? false;

  bool get notificationsActive => _channel != null;

  bool get started => _started;

  /// Starts the net and the notification channel. The caller queues the
  /// initial [reconcile].
  void start() {
    _started = true;
    _sweepTimer = Timer.periodic(_sweepInterval, (_) => _swallow(reconcile()));
    _listen();
  }

  /// Cancels everything this object started. Idempotent.
  void stop() {
    _stopped = true;
    _sweepTimer?.cancel();
    _sweepTimer = null;
    _relisten?.cancel();
    _relisten = null;
    final channel = _channel;
    _channel = null;
    // The cancel is awaited by nobody: it sends UNLISTEN over the shared
    // notification connection and detach is synchronous by design (02-05
    // calls it from a provider rebuild). A failure there is the connection's
    // problem and `listenToChannel`'s own onCancel already handles it.
    _swallow(channel?.cancel() ?? Future<void>.value());
  }

  /// Runs [body] after everything already queued, and hands back a future the
  /// caller may await. Tests do; the app never has to.
  Future<void> serialise(Future<void> Function() body) {
    final result = _pending.then((_) => _stopped ? null : body());
    // The chain itself must never carry an error forward, or one failed pull
    // would poison every apply after it.
    _pending = result.catchError((Object _) {});
    return result;
  }

  /// The fast path: consume the shared change log from the watermark.
  Future<void> pull() => serialise(_pull);

  /// The net: compare every shared revision against the snapshot.
  Future<void> reconcile() => serialise(_reconcile);

  // ---------------------------------------------------------------------
  // The two paths
  // ---------------------------------------------------------------------

  /// `SELECT DISTINCT entity_id, max(id) FROM config_change WHERE id >
  /// <watermark> AND kind='key_mapping' AND scope='shared'`, then a targeted
  /// re-read of those rows.
  ///
  /// The change row's `new_value` is deliberately not trusted: the
  /// `config_item` row is the truth and the log is only a pointer at it. The
  /// same reason [ConfigDiff.changed] carries only the new side — a value read
  /// from a log is what somebody once wrote, not what is stored now.
  ///
  /// The watermark advances only to the highest id *this query matched*, never
  /// to the log's global maximum: a page's change row that this station has no
  /// business consuming must not carry the watermark past a key-mapping row
  /// committed beside it.
  Future<void> _pull() async {
    final watermark = _store._watermark;
    try {
      final t = _remote.configChangeTable;
      final highest = t.id.max();
      final rows = await (_remote.selectOnly(t)
            ..addColumns([t.entityId, highest])
            ..where(t.id.isBiggerThanValue(watermark) &
                t.kind.equals(ConfigKind.keyMapping.wireName) &
                t.scope.equals(ConfigScope.shared.wireName))
            ..groupBy([t.entityId]))
          .get();
      if (rows.isEmpty) return;

      final ids = <String>{};
      var advanceTo = watermark;
      for (final row in rows) {
        ids.add(row.read(t.entityId)!);
        final id = row.read(highest);
        if (id != null && id > advanceTo) advanceTo = id;
      }

      await _apply(ids);
      await _store._advanceWatermark(advanceTo);
    } catch (e) {
      _logger.w('key_mappings pull from watermark $watermark abandoned; the '
          'next notification or sweep retries it: $e');
    }
  }

  /// The net. See the library doc for why it is a revision comparison and not
  /// a second read of the change log.
  Future<void> _reconcile() async {
    try {
      // Read first, and before the revisions. Anything that commits after this
      // is either caught by the revision read below or is a change row above
      // this id, which the fast path will consume — advancing past a row that
      // committed between the two reads is the one way this could lose work.
      final advanceTo = await _maxChangeId();

      final revs = await _remoteRevisions();
      if (revs.isEmpty &&
          _store._snapshot.isNotEmpty &&
          !await _remoteIsMigrated()) {
        // The cutover boot: this station reached Postgres before any station
        // ran the blob→rows migration. Reading "no rows" as "every key was
        // deleted" would empty the mirror too, and the station would come up
        // with no mappings at all — every mimic on the floor blank, with
        // nothing saying why. 02-03's marker is what tells the two apart: it
        // is written last, inside the migration's own transaction, precisely
        // so that a plant with legitimately zero mappings is distinguishable
        // from one that has not been migrated. 02-02 took the same reading of
        // an empty result for the backend's boot.
        _logger.w('key_mappings reconcile: the shared store holds no '
            'key_mapping rows and no migration marker, so it has not been '
            'migrated yet; keeping this station\'s ${_store._snapshot.length} '
            'mirrored keys');
        return;
      }

      final candidates = <String>{};
      for (final entry in revs.entries) {
        final stored = _store._snapshot[entry.key];
        if (stored == null || stored.rev != entry.value) {
          candidates.add(entry.key);
        }
      }
      for (final id in _store._snapshot.keys) {
        if (!revs.containsKey(id)) candidates.add(id);
      }

      if (candidates.isNotEmpty) await _apply(candidates);
      await _store._advanceWatermark(advanceTo);
    } catch (e) {
      _logger.w('key_mappings reconcile abandoned; the next sweep retries '
          'it: $e');
    }
  }

  // ---------------------------------------------------------------------
  // The one apply path
  // ---------------------------------------------------------------------

  /// Re-reads [ids] from the remote and applies whatever they turn out to be.
  ///
  /// Both paths end here, so there is one definition of what applying a remote
  /// change means: absent rows are removals, present rows replace what the
  /// snapshot holds, and the diff the store emits is computed **over these ids
  /// only**. That last part is what stops a targeted pull looking like a
  /// wholesale delete of every key it did not ask about.
  Future<void> _apply(Set<String> ids) async {
    final fetched = await _readItems(ids);

    // An id that was asked for and did not come back is gone from the shared
    // store. Taken before the filtering below, because a row that is *absent*
    // and a row that is *unchanged* must not end up in the same bucket.
    final removedIds = {
      for (final id in ids)
        if (!fetched.containsKey(id) && _store._snapshot.containsKey(id)) id,
    };

    // A row whose revision and content both match what is already held is not
    // an update; dropping it here keeps the mirror write and the emitted diff
    // to what actually moved.
    final fresh = Map<String, ConfigItem>.of(fetched)
      ..removeWhere((id, item) {
        final stored = _store._snapshot[id];
        return stored != null &&
            stored.rev == item.rev &&
            stored.sameContentAs(item);
      });

    if (fresh.isEmpty && removedIds.isEmpty) return;
    if (_stopped) return;

    // The stored side is restricted to the ids actually in play — the ones
    // that came back changed and the ones that did not come back at all.
    // Handing the whole snapshot over would report every key this pull never
    // asked about as removed.
    //
    // The comparison itself is content-only: `rev`, `updated_at` and
    // `updated_by` describe the write rather than the configuration, so a row
    // whose revision moved and whose payload did not is still applied — the
    // snapshot and the mirror take the new revision, which the next
    // compare-and-swap guards on — without being announced as an edit nobody
    // made.
    final diff = diffConfigItems(
      stored: [
        for (final id in {...fresh.keys, ...removedIds})
          if (_store._snapshot.containsKey(id)) _store._snapshot[id]!,
      ],
      wanted: fresh.values,
    );
    await _store._applyRemoteState(diff, fresh);
  }

  // ---------------------------------------------------------------------
  // Remote reads
  // ---------------------------------------------------------------------

  /// The shared `key_mapping` rows named by [ids], keyed by id. An id with no
  /// row is simply absent — that is how a delete reaches [_apply].
  Future<Map<String, ConfigItem>> _readItems(Set<String> ids) async {
    final rows = await (_remote.select(_remote.configItemTable)
          ..where((t) =>
              t.kind.equals(ConfigKind.keyMapping.wireName) &
              t.scope.equals(ConfigScope.shared.wireName) &
              t.id.isIn(ids.toList())))
        .get();
    return {for (final row in rows) row.id: _store._itemOf(row)};
  }

  /// `id → rev` for every shared `key_mapping` row. Two short columns per key,
  /// which is what makes a five-minute full comparison affordable at all.
  Future<Map<String, int>> _remoteRevisions() async {
    final t = _remote.configItemTable;
    final rows = await (_remote.selectOnly(t)
          ..addColumns([t.id, t.rev])
          ..where(t.kind.equals(ConfigKind.keyMapping.wireName) &
              t.scope.equals(ConfigScope.shared.wireName)))
        .get();
    return {for (final row in rows) row.read(t.id)!: row.read(t.rev)!};
  }

  /// The highest id in the shared change log, or the current watermark when
  /// the log is empty.
  Future<int> _maxChangeId() async {
    final t = _remote.configChangeTable;
    final highest = t.id.max();
    final row =
        await (_remote.selectOnly(t)..addColumns([highest])).getSingle();
    return row.read(highest) ?? _store._watermark;
  }

  /// Whether the blob→rows migration has run against this remote.
  ///
  /// Only ever asked when the remote holds no `key_mapping` rows at all, which
  /// is rare enough that the extra indexed lookup costs nothing and specific
  /// enough that guessing would be indefensible. See [_reconcile].
  Future<bool> _remoteIsMigrated() async {
    final t = _remote.configItemTable;
    final query = _remote.selectOnly(t)
      ..addColumns([t.id])
      ..where(t.kind.equals(ConfigKind.preference.wireName) &
          t.id.equals(kKeyMappingsMigratedMarkerId) &
          t.scope.equals(ConfigScope.shared.wireName))
      ..limit(1);
    return (await query.get()).isNotEmpty;
  }

  // ---------------------------------------------------------------------
  // The notification channel
  // ---------------------------------------------------------------------

  /// Subscribes to `config_change` — the statement-level trigger 02-02
  /// installed, whose payload is deliberately empty.
  ///
  /// Gated on the dialect, and on `executor.dialect` rather than
  /// `AppDatabase.postgres`: that getter is **false on every station**,
  /// because the app opens its database through [AppDatabase.spawn] and the
  /// resulting executor is a DriftIsolate remote rather than a `PgDatabase`.
  /// The gate matters beyond tidiness — `listenToChannel` on a SQLite executor
  /// logs a warning and closes the stream, which [_listen]'s own `onDone`
  /// would answer with a fresh timer every five seconds for the life of the
  /// process.
  void _listen() {
    if (_stopped) return;
    if (_remote.executor.dialect != SqlDialect.postgres) return;
    _channel = _remote.listenToChannel('config_change').listen(
      // The payload carries nothing by design, so the notification says only
      // "something changed" and the pull decides whether any of it was a key
      // mapping. From Phase 3 a page edit lands on this channel too.
      (_) => _swallow(pull()),
      onError: (Object e) =>
          _logger.w('config_change channel error, ignored: $e'),
      onDone: () {
        if (_stopped) return;
        _channel = null;
        _relisten = Timer(kConfigRelistenBackoff, () {
          if (_stopped) return;
          _listen();
          // An edit made while the connection was down is not waited out: the
          // watermark pull is exactly the query that answers "what did I
          // miss".
          _swallow(pull());
        });
      },
    );
  }

  /// Attaches a handler to a future nothing awaits.
  ///
  /// `unawaited()` would not do: it marks the future as intentionally dropped
  /// and attaches no error handler, so a throw becomes an unhandled
  /// asynchronous error that takes down the zone. Everything reached from here
  /// already logs its own failures; this is the backstop.
  void _swallow(Future<void> future) {
    future.catchError((Object e) {
      _logger.w('key_mappings sync task failed: $e');
    });
  }
}

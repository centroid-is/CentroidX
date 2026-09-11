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
/// ## The remote wins outright, and only over what it owns
///
/// This is a **replace**, not a merge, and the distinction is the difference
/// between a reconcile and a slow leak. For the row set under sync — kind
/// `key_mapping` at `scope='shared'` — the remote's rows replace this
/// station's: a row present locally and absent remotely is *deleted*, from the
/// snapshot and from the mirror, not left alone as an unmatched extra. A merge
/// would let a row the server has never heard of survive every future sweep,
/// with a legitimate-looking id and nothing downstream able to tell it from
/// configuration somebody wrote.
///
/// The other half is as load-bearing as the first: **"absent from a shared
/// remote" says nothing about a `station:<hostname>` row, or about a row of
/// another kind.** Those are different row sets that happen to share a table.
/// Every read here filters on `kind` *and* `scope`, every snapshot item
/// carries both (`ConfigStore._itemOf` sets them from what the query filtered
/// on), and every mirror delete names both — so a sweep of the shared key
/// mappings structurally cannot reach this station's own settings, the
/// watermark row sitting beside them, or a page. `the remote wins outright,
/// and only over shared key mappings` in `config_sync_test.dart` is that
/// property, asserted over the whole local table rather than over the rows the
/// sweep was looking at.
///
/// The single exception is stated where it lives: an empty remote with no
/// migration marker is refused rather than applied, because on the cutover
/// boot it means the migration has not run. See [_reconcile].
///
/// ## What "the row set under sync" means now
///
/// [kSharedConfigKinds] — key mappings, pages, assets, page images **and
/// preferences**, the last since 04-05 moved the shared `PreferencesApi` onto
/// rows. So the kind set is no longer what holds a station's own rows back;
/// every read here filters on `scope='shared'` as well, and that filter is
/// what does the work. The row a station owns and the watermark beside it are
/// `station:<hostname>` preferences and are structurally out of reach.
///
/// The migration markers are **not** out of reach and must not be: they are
/// shared rows, because [_remoteIsMigrated] asks the remote whether the
/// *plant* has been migrated. They sweep and log like anything else.
///
/// Page images are in the set for a reason worth stating where the sweep is
/// described: they write no `config_change` rows at all
/// (`config_history_policy.dart`), so neither the trigger nor the watermark
/// can ever see one and this sweep is their only net. That is also why an
/// exempt write sends its own notification naming the kinds to reconcile —
/// see [onNotification], the arm that answers it.
///
/// A row is identified by a **(kind, id) pair** rather than a bare id, all the
/// way through both paths. That is not tidiness. A page path and a mapping key
/// may be the same string — the table allows it — so an apply keyed by id
/// alone would re-read one and write it over the other, and the symptom would
/// be a mimic bound to a key that resolves to a page.
///
/// The marker guard in [_reconcile] is asked **per kind**, which is the one
/// genuinely non-mechanical part of the widening. On the cutover boot the key
/// mappings are already on rows and the pages are still in the blob: one
/// shared answer would either refuse a sweep that should run or permit the one
/// that empties the mirror. See [_refusedKinds].
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

/// The one channel a station listens on for shared configuration.
///
/// Two things notify on it: the `AFTER INSERT ON config_change` trigger, whose
/// payload is empty, and [ConfigStore._nudgeExemptKinds], whose payload names
/// kinds. One channel rather than two because a receiver has to be listening
/// on it for either to arrive, and a second channel would be a second thing to
/// re-listen to after every reconnect.
const String kConfigChangeChannel = 'config_change';

/// `updated_by` on the watermark row. Not a person: no operator wrote it.
const String _syncWriter = 'sync';

/// The zone value that marks code running on the serialisation chain, so a
/// task on it that asks to be serialised again is run in place rather than
/// queued behind itself. See [ConfigStore.serialiseWrite].
const Symbol _kOnSyncChain = #tfcConfigSyncChain;

/// One row's identity to this engine: its kind and its id.
///
/// A record rather than a bare id, because a page path and a mapping key may
/// be the same string and the pair is what the primary key is made of. Scope
/// is not here for the same reason it is not in [configSnapshotKey]: every
/// read in this file filters on `shared`.
typedef _Ref = (ConfigKind kind, String id);

/// The sync engine for one attached remote.
///
/// Created by [ConfigStore.attachRemote] and thrown away by
/// [ConfigStore.detachRemote] — the object's life *is* the attachment, so
/// there is no "attached?" flag to get out of step with a timer that is still
/// running. A reconnect builds a new [Database] and therefore a new one of
/// these, which is exactly right: the notifications that arrived during the
/// gap are gone, so the re-attach must reconcile rather than pull.
class _ConfigSync {
  _ConfigSync(this._store, this._remote, this._sweepInterval);

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

  /// Whether the caller is already running on the chain.
  static bool get onChain => Zone.current[_kOnSyncChain] == true;

  /// How many tasks are on the chain right now — running, or queued behind
  /// one that is. Zero means the chain is idle.
  int _inFlight = 0;

  /// Runs [body] after everything already queued, and hands back a future the
  /// caller may await. Tests do; the app never has to.
  ///
  /// [body] runs in a zone carrying [_kOnSyncChain], which is what lets a
  /// write it performs recognise that it is already serialised.
  ///
  /// **An idle chain runs [body] directly rather than chaining it on the last
  /// task's completed future.** A `.then` on an already-completed future
  /// schedules its callback as a microtask in the zone that *future* was
  /// created in, not the caller's. A store built outside a widget test's
  /// fake-async zone — in `setUp` — therefore left every write it was asked
  /// for in the test body waiting on a real microtask the fake-async loop
  /// never drains, and the test hung until the runner killed it. Chaining
  /// behind a task that is genuinely in flight registers a listener instead,
  /// and a listener runs in the zone it was registered from.
  Future<void> serialise(Future<void> Function() body) {
    Future<void> run() async {
      _inFlight++;
      try {
        if (_stopped) return;
        await runZoned(body, zoneValues: {_kOnSyncChain: true});
      } finally {
        _inFlight--;
      }
    }

    final result = _inFlight == 0 ? run() : _pending.then((_) => run());
    // The chain itself must never carry an error forward, or one failed pull
    // would poison every apply after it.
    _pending = result.catchError((Object _) {});
    return result;
  }

  /// The fast path: consume the shared change log from the watermark.
  Future<void> pull() => serialise(_pull);

  /// The net: compare every shared revision against the snapshot.
  Future<void> reconcile() => serialise(_reconcile);

  /// What one notification means.
  ///
  /// An empty payload is the trigger's and means "consume the change log" —
  /// the fast path, unchanged. A payload naming kinds is
  /// [ConfigStore._nudgeExemptKinds]'s, and means "compare those kinds'
  /// revisions now": those kinds write no change rows, so there is nothing for
  /// the watermark path to find and nothing for it to advance to. Advancing
  /// the watermark on one would be worse than useless — it would carry it past
  /// change rows this station has not read.
  Future<void> onNotification(String payload) {
    final kinds = decodeReconcileNudge(payload);
    if (kinds == null) return pull();
    if (kinds.isEmpty) {
      // A nudge naming only kinds this build has never heard of. There is
      // nothing this station can do with them and nothing it needs to.
      _logger.d('config nudge named no kind this build knows: "$payload"');
      return Future<void>.value();
    }
    return serialise(() => _reconcileKinds(kinds, advanceWatermark: false));
  }

  // ---------------------------------------------------------------------
  // The two paths
  // ---------------------------------------------------------------------

  /// `SELECT kind, entity_id, max(id) FROM config_change WHERE id >
  /// <watermark> AND kind IN <shared kinds> AND scope='shared' GROUP BY kind,
  /// entity_id`, then a targeted re-read of those rows.
  ///
  /// Grouped by kind **and** entity id, because those two together are what
  /// names a row.
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
            ..addColumns([t.kind, t.entityId, highest])
            ..where(t.id.isBiggerThanValue(watermark) &
                t.kind.isIn(_wireNamesOf(kSharedConfigKinds)) &
                t.scope.equals(ConfigScope.shared.wireName))
            ..groupBy([t.kind, t.entityId]))
          .get();
      if (rows.isEmpty) return;

      final refs = <_Ref>{};
      var advanceTo = watermark;
      for (final row in rows) {
        final id = row.read(highest);
        if (id != null && id > advanceTo) advanceTo = id;
        // The `WHERE` above admits only wire names this build knows, so the
        // null arm is unreachable; it is written out rather than forced so
        // that a kind added to the table and not to the enum cannot crash a
        // station's sync.
        final kind = ConfigKind.byWireName(row.read(t.kind)!);
        if (kind == null) continue;
        refs.add((kind, row.read(t.entityId)!));
      }

      await _apply(refs);
      await _store._advanceWatermark(advanceTo);
    } catch (e) {
      _logger.w('config pull from watermark $watermark abandoned; the '
          'next notification or sweep retries it: $e');
    }
  }

  /// The net. See the library doc for why it is a revision comparison and not
  /// a second read of the change log.
  Future<void> _reconcile() =>
      _reconcileKinds(kSharedConfigKinds, advanceWatermark: true);

  /// The net, over [kinds] only.
  ///
  /// The periodic sweep passes every kind under sync and advances the
  /// watermark with what it read. A nudge passes the exempt kinds it names and
  /// does **not**: those kinds append no change rows, so the log's maximum id
  /// says nothing about them, and adopting it would skip somebody else's
  /// ordinary write.
  Future<void> _reconcileKinds(Set<ConfigKind> kinds,
      {required bool advanceWatermark}) async {
    final swept = kinds.intersection(kSharedConfigKinds);
    if (swept.isEmpty) return;
    try {
      // Read first, and before the revisions, which narrows one window as far
      // as two statements can: a transaction that commits between these two
      // reads is seen by the revision read below. What is left is a row that
      // took an id below this maximum and commits after the revision read —
      // and that row is invisible to the watermark and to this sweep both.
      // The **next** sweep catches it, which is why the net is periodic rather
      // than something that runs once at attach: five minutes is the stated
      // worst case, not an accident.
      final advanceTo = advanceWatermark ? await _maxChangeId() : 0;

      final revs = await _remoteRevisions(swept);
      final refused = await _refusedKinds(revs, swept);

      final candidates = <_Ref>{};
      for (final entry in revs.entries) {
        if (refused.contains(entry.key.$1)) continue;
        final stored = _store._snapshot[_key(entry.key)];
        if (stored == null || stored.rev != entry.value) {
          candidates.add(entry.key);
        }
      }
      // Over the snapshot's items of the kinds under sync, never over its
      // keys: the snapshot holds pages, assets and key mappings, and an id
      // present under one kind says nothing about the same id under another.
      for (final item in _store._snapshot.values) {
        if (!swept.contains(item.kind)) continue;
        if (refused.contains(item.kind)) continue;
        final ref = (item.kind, item.id);
        if (!revs.containsKey(ref)) candidates.add(ref);
      }

      if (candidates.isNotEmpty) await _apply(candidates);
      // A sweep that refused a kind has read change rows it is not willing
      // to act on, so it must not claim the log up to them: advancing here
      // would carry the watermark past that kind's rows — the migration's own,
      // on the cutover boot — and the pull would never re-read them. The
      // other kinds' rows were applied by the revision comparison just above,
      // so nothing is lost by leaving the watermark where it was; the next
      // sweep after the migration lands advances it.
      if (advanceWatermark && refused.isEmpty) {
        await _store._advanceWatermark(advanceTo);
      }
      await _store._repairMirror();
    } catch (e) {
      _logger.w('config reconcile abandoned; the next sweep retries it: $e');
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
  Future<void> _apply(Set<_Ref> refs) async {
    final fetched = await _readItems(refs);

    // A row that was asked for and did not come back is gone from the shared
    // store. Taken before the filtering below, because a row that is *absent*
    // and a row that is *unchanged* must not end up in the same bucket.
    final removedRefs = {
      for (final ref in refs)
        if (!fetched.containsKey(ref) && _store._snapshot.containsKey(_key(ref)))
          ref,
    };

    // A row whose revision and content both match what is already held is not
    // an update; dropping it here keeps the mirror write and the emitted diff
    // to what actually moved.
    // Keyed by [configSnapshotKey] from here on, because that is what the
    // store's snapshot is keyed by and [ConfigStore._applyRemoteState] adds
    // this map to it wholesale.
    final fresh = <String, ConfigItem>{
      for (final entry in fetched.entries) _key(entry.key): entry.value,
    }..removeWhere((key, item) {
        final stored = _store._snapshot[key];
        return stored != null &&
            stored.rev == item.rev &&
            stored.sameContentAs(item);
      });

    if (fresh.isEmpty && removedRefs.isEmpty) return;
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
        for (final key in {...fresh.keys, ...removedRefs.map(_key)})
          if (_store._snapshot.containsKey(key)) _store._snapshot[key]!,
      ],
      wanted: fresh.values,
    );
    await _store._applyRemoteState(diff, fresh);
  }

  // ---------------------------------------------------------------------
  // Remote reads
  // ---------------------------------------------------------------------

  /// The shared rows named by [refs], keyed by the same pair. A ref with no
  /// row is simply absent — that is how a delete reaches [_apply].
  ///
  /// The `WHERE` is the cross product of the kinds and the ids, because SQL
  /// has no portable "IN over pairs"; the rows that come back are then
  /// filtered down to the pairs actually asked for. Over-reading is harmless
  /// and one indexed statement is worth more than an exact predicate — but
  /// *keeping* the extra rows would not be: a page whose path equals a mapping
  /// key would arrive uninvited and be applied.
  Future<Map<_Ref, ConfigItem>> _readItems(Set<_Ref> refs) async {
    final kinds = {for (final ref in refs) ref.$1};
    final ids = {for (final ref in refs) ref.$2};
    final rows = await (_remote.select(_remote.configItemTable)
          ..where((t) =>
              t.kind.isIn(_wireNamesOf(kinds)) &
              t.scope.equals(ConfigScope.shared.wireName) &
              t.id.isIn(ids.toList())))
        .get();
    final fetched = <_Ref, ConfigItem>{};
    for (final row in rows) {
      final item = _store._itemOf(row);
      if (item == null) continue;
      final ref = (item.kind, item.id);
      if (refs.contains(ref)) fetched[ref] = item;
    }
    return fetched;
  }

  /// `(kind, id) → rev` for every shared row under sync. Three short columns
  /// per row, which is what makes a five-minute full comparison affordable at
  /// all.
  Future<Map<_Ref, int>> _remoteRevisions(Set<ConfigKind> kinds) async {
    final t = _remote.configItemTable;
    final rows = await (_remote.selectOnly(t)
          ..addColumns([t.kind, t.id, t.rev])
          ..where(t.kind.isIn(_wireNamesOf(kinds)) &
              t.scope.equals(ConfigScope.shared.wireName)))
        .get();
    final revs = <_Ref, int>{};
    for (final row in rows) {
      final kind = ConfigKind.byWireName(row.read(t.kind)!);
      if (kind == null) continue;
      revs[(kind, row.read(t.id)!)] = row.read(t.rev)!;
    }
    return revs;
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

  /// The kinds this sweep must leave alone, because for them "the remote
  /// holds nothing" cannot yet be told from "the remote holds nothing *yet*".
  ///
  /// The cutover boot, asked once per kind. A station reaches Postgres before
  /// some kind's blob→rows migration has run: the remote has no rows of that
  /// kind, and reading that as "every one of them was deleted" would empty the
  /// mirror too — the station comes up with no pages, or no mappings, and
  /// nothing on the floor saying why. The marker is what tells the two apart.
  /// It is written last, inside the migration's own transaction, precisely so
  /// that a plant with legitimately zero rows of a kind is distinguishable
  /// from one that has not been migrated.
  ///
  /// **Per kind, and never one shared answer.** During the cutover the key
  /// mappings are on rows and the pages are still in the blob; a single flag
  /// would have to be wrong about one of them. The three conditions are all
  /// required and each rules out a different mistake: no remote rows of the
  /// kind (otherwise the remote plainly owns them), some held locally
  /// (otherwise there is nothing to protect and refusing would only stall the
  /// first reconcile of a fresh station), and no marker (otherwise the empty
  /// remote is the truth and this station's rows are what is stale).
  Future<Set<ConfigKind>> _refusedKinds(
      Map<_Ref, int> revs, Set<ConfigKind> kinds) async {
    final refused = <ConfigKind>{};
    for (final kind in kinds) {
      if (revs.keys.any((ref) => ref.$1 == kind)) continue;
      final held = [
        for (final item in _store._snapshot.values)
          if (item.kind == kind) item,
      ];
      if (held.isEmpty) continue;
      if (await _remoteIsMigrated(kind)) continue;
      refused.add(kind);
      _logger.w('config reconcile: the shared store holds no '
          '${kind.wireName} rows and no ${kind.wireName} migration marker, so '
          'that kind has not been migrated yet; keeping this station\'s '
          '${held.length} mirrored rows');
    }
    return refused;
  }

  /// Whether [kind]'s blob→rows migration has run against this remote.
  ///
  /// Only ever asked when the remote holds no rows of that kind at all, which
  /// is rare enough that the extra indexed lookup costs nothing and specific
  /// enough that guessing would be indefensible. See [_refusedKinds].
  Future<bool> _remoteIsMigrated(ConfigKind kind) async {
    final marker = kMigrationMarkerIds[kind];
    // A kind under sync with no marker in the table. Answering "migrated"
    // would let the empty-remote sweep delete this station's rows on the
    // cutover boot, so the safe answer is the conservative one — and it is
    // loud, because a missing entry is a developer error.
    if (marker == null) {
      _logger.e('config reconcile: ${kind.wireName} is under sync but has no '
          'entry in kMigrationMarkerIds, so an empty remote cannot be told '
          'from an unmigrated one; treating it as unmigrated');
      return false;
    }
    final t = _remote.configItemTable;
    final query = _remote.selectOnly(t)
      ..addColumns([t.id])
      ..where(t.kind.equals(ConfigKind.preference.wireName) &
          t.id.equals(marker) &
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
    _channel = _remote.listenToChannel(kConfigChangeChannel).listen(
      // The trigger's payload carries nothing by design, so that notification
      // says only "something changed" and the pull decides what of it this
      // station wanted. From Phase 3 a page edit lands on this channel too,
      // and from Phase 4 so does a nudge naming the exempt kinds a write
      // touched — see [onNotification].
      (payload) => _swallow(onNotification(payload)),
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

  /// A row's (kind, id) pair as the store's snapshot keys it.
  static String _key(_Ref ref) => configSnapshotKey(ref.$1, ref.$2);

  /// Attaches a handler to a future nothing awaits.
  ///
  /// `unawaited()` would not do: it marks the future as intentionally dropped
  /// and attaches no error handler, so a throw becomes an unhandled
  /// asynchronous error that takes down the zone. Everything reached from here
  /// already logs its own failures; this is the backstop.
  void _swallow(Future<void> future) {
    future.catchError((Object e) {
      _logger.w('config sync task failed: $e');
    });
  }
}

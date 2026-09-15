/// The fifteen `PreferencesApi` members over `tfc_dart`'s shared
/// `flutter_preferences` table.
///
/// ## TRAP 8: a `Preferences` built by hand answers "no keys"
///
/// `getKeys` and `getAll` read an **in-memory cache**
/// (`preferences.dart:267-274`), not the table. The only thing that fills that
/// cache is `Preferences.create`, which awaits `loadFromPostgres()` (`:233`).
/// A gateway that constructed `Preferences(database: db, …)` directly — the
/// public constructor, which compiles and looks right — would answer an empty
/// set to a store that at SVN today holds **four rows and 675,890 bytes**,
/// `key_mappings` alone being 530,287 of them (`svn-prefs-live-20260811.csv`,
/// measured). Nothing throws. The first symptom is a settings page that looks
/// like a fresh install, which is not a thing anybody reports as a fault, and
/// the second is somebody re-entering configuration that was never lost.
///
/// So this store never uses the constructor. [_load] goes through
/// `Preferences.create`, and there is a case asserting a freshly built store
/// answers a seeded database's keys.
///
/// ## The cache is rebuilt, never patched
///
/// The cache is a process-local copy of a table **other processes write** — an
/// HMI station at SVN saves its settings straight into it. When
/// `preference_change_feed.dart` hears that happen it calls [invalidate], and
/// the next call rebuilds through `Preferences.create` rather than refreshing
/// the one key that changed.
///
/// A per-key refresh was considered and rejected, for a reason worth writing
/// down: upstream offers no way to **evict** a key from the cache that does not
/// also delete its row. `Preferences.remove` clears the entry *and* issues a
/// `DELETE` (`preferences.dart:421-436`), so reflecting somebody else's delete
/// with it would mean this gateway issuing a delete of its own — against a row
/// that a racing writer may have just re-created. `loadFromPostgres` on the
/// live instance has the mirror-image flaw: it overwrites and adds, and never
/// removes, so a deleted key would live in the cache forever. Rebuilding is
/// the only operation that is total, and its cost is one full read — 660 KiB
/// at SVN's present size, on a change nobody makes twice a minute.
///
/// ## The seam stays at two files
///
/// This file does not import `core/database.dart`. It takes 10-07's
/// [DatabaseSupplier] from next door and hands what it returns to
/// `Preferences.create`, whose `db` parameter has exactly that type — so the
/// call is statically checked and `freeze_test.dart`'s
/// `declaredSeamImportFiles` does not move. `history_view_store.dart`'s
/// library doc carries the full argument.
///
/// `Preferences.create` accepts a **null** database and quietly degrades to a
/// memory-only store when given one. That is Trap 8 wearing a second hat, so
/// [_load] refuses instead: null means the historian is not up, and
/// [PreferenceStoreUnavailable] is retryable and says so.
///
/// ## SEC-01: `secret:` is not spelled in this file
///
/// The concrete `Preferences` carries a `{bool secret = false}` on twelve
/// members, which routes the call to the OS keychain instead of the table. The
/// interface this store implements omits it, every call below uses the
/// non-secret overload, and `preference_store_test.dart` greps this source for
/// the word — because the obvious future edit is to add it back "for
/// symmetry", and that one client-supplied boolean would be remote retrieval
/// of the secure store (T-10-35).
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show UpdateKind, Variable;
import 'package:tfc_dart/core/preferences.dart' show Preferences;
import 'package:tfc_dart/core/secure_storage/interface.dart'
    show MySecureStorage;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show DataServiceMethods, PreferencesApi, ResultTooLarge, SourceRefusal;

import 'preference_change_feed.dart';
import 'read_limits.dart';
import 'timescale_reader.dart' show DatabaseSupplier;

/// The preference store cannot be reached right now.
///
/// A separate type from `HistorianUnavailable` even though the absent thing is
/// the same `Database`: a client that asked for a setting and was told "the
/// historian is not connected" would go and look at charts. Not a member of
/// the sealed `TimeseriesReadRefusal` family for the same reason — the switch
/// that family exists for is about *reads of recorded samples*.
final class PreferenceStoreUnavailable implements SourceRefusal {
  const PreferenceStoreUnavailable();

  /// Whether retrying the identical request could ever succeed.
  ///
  /// **True, and it is the one refusal in this phase for which -32011 is the
  /// right answer.** `data_handlers.dart`'s `_sized` reads this and rethrows,
  /// so the catch-all still maps it to `handlerFailed` — the wire's
  /// "possibly transient: retrying is legitimate", which is precisely what a
  /// disconnected historian is. It implements [SourceRefusal] anyway rather
  /// than staying a bare `Exception`, because the interface is the place the
  /// claim is written down and an unclaimed refusal is one nobody can tell
  /// from an unconsidered one.
  @override
  bool get retryable => true;

  @override
  String get message =>
      'the preference store is not connected; this is worth retrying';

  @override
  String toString() => message;
}

/// A stored value this gateway cannot put on the wire (10-REVIEW WR-06).
///
/// ## Why a refusal and not a handler failure
///
/// `getAll` measures its own answer with `utf8.encode(jsonEncode(all))`, and
/// `all` comes from a table **other processes write** — an SVN HMI station
/// writes it directly. A stored non-finite double, or anything else
/// `jsonEncode` refuses, made that line throw `JsonUnsupportedObjectError`:
/// neither a [ResultTooLarge] nor a [SourceRefusal], so `_sized` caught
/// neither and it reached the catch-all as `handlerFailed` (-32011) — which
/// the wire documents as *possibly transient*. Every settings page that opened
/// then retried forever a call no retry can fix, which is the precise failure
/// `_sized` was written to prevent, arriving through the one call site that
/// encodes early enough to give a good answer.
///
/// The gateway's own ingress is clean — `RelaySession._defuse` sanitises every
/// inbound frame, so `1e999` cannot be *written* through this pipe. The
/// exposure is the shared table, which is exactly the kind of thing that will
/// not be fixed by asking nicely.
///
/// ## And why it names the key
///
/// "Something in the store cannot be encoded" is not actionable; "this key is"
/// is one `UPDATE` away from fixed. Finding it costs one extra pass, key by
/// key, on a path that has **already** failed — see `PreferenceStore.getAll`.
final class UnencodablePreference implements SourceRefusal {
  const UnencodablePreference(this.key, this.detail);

  /// The preference key whose value could not be encoded, or null if the
  /// key-by-key pass could not single one out.
  final String? key;

  /// What `jsonEncode` said, trimmed to its first line.
  final String detail;

  /// **False.** A value the encoder refuses is refused on every attempt; the
  /// row has to change first.
  @override
  bool get retryable => false;

  @override
  String get message => key == null
      ? 'a stored preference holds a value this gateway cannot encode as JSON '
          '($detail), and the key-by-key pass could not single it out. The '
          'table is written by other processes — an HMI station writes it '
          'directly — so this is a row somebody else stored, not one this '
          'pipe accepted. Read the keys you need with an allowList until it '
          'is corrected'
      : 'the preference "$key" holds a value this gateway cannot encode as '
          'JSON ($detail), so the whole store cannot be read in one call. The '
          'table is written by other processes — an HMI station writes it '
          'directly — so this is a row somebody else stored, not one this '
          'pipe accepted. Correct that row, or read the keys you need with an '
          'allowList that leaves it out. Retrying unchanged cannot succeed';

  @override
  String toString() => message;
}

/// A secure store that refuses every request.
///
/// Installed by the gateway's composition root. The gateway must never read or
/// write secret material — SEC-01 says keys are mounted files, not preference
/// rows — and this makes that true by construction rather than by convention.
///
/// It also removes a dependency this process should not have. `Preferences`
/// asks `SecureStorage.getInstance()` **unconditionally**, outside the `try`
/// that guards the rest of `create` (`preferences.dart:219-220`), and the
/// default on Linux and macOS builds an `AwsSecureStorage` over the OS
/// keychain. A headless gateway has no session keyring to talk to, and a
/// failure there would take down a call that never wanted a secret in the
/// first place.
final class NoSecretStorage implements MySecureStorage {
  const NoSecretStorage();

  static Never _refuse(String op) => throw StateError(
      'this gateway does not handle secret material: $op was asked of the '
      'refusing secure store. SEC-01 — keys are mounted files, not '
      'preference rows, and nothing reachable from the pipe may request one');

  @override
  Future<String?> read({required String key}) async => _refuse('read');

  @override
  Future<void> write({required String key, required String value}) async =>
      _refuse('write');

  @override
  Future<void> delete({required String key}) async => _refuse('delete');
}

/// `PreferencesApi` over the shared `flutter_preferences` table.
final class PreferenceStore implements PreferencesApi {
  PreferenceStore({required this.database, this.log, ReadLimits? limits})
      : limits = limits ?? ReadLimits() {
    _feed = PreferenceChangeFeed(
      database: database,
      local: _local.stream,
      invalidate: invalidate,
      resync: resync,
      log: log,
    );
  }

  /// The shared instance, borrowed per call. See the library doc.
  final DatabaseSupplier database;

  /// The outbound ceilings. See `read_limits.dart` for the arithmetic.
  final ReadLimits limits;

  /// Where a swallowed failure goes. Optional and injected, following
  /// `HistoryViewStore`'s shape: a store built in a test asserts what it was
  /// told, and one built by `bin/relay_gateway.dart` writes to the gateway's
  /// logger.
  final void Function(String message)? log;

  /// Writes made **through this gateway**, forwarded from whichever
  /// `Preferences` instance is current.
  ///
  /// Broadcast and forwarded rather than handed out directly, because the
  /// instance is rebuilt whenever the cache is invalidated or the database
  /// is swapped, and a subscriber holding the old instance's stream would go
  /// quiet without anything closing.
  final StreamController<String> _local = StreamController<String>.broadcast();

  late final PreferenceChangeFeed _feed;

  /// The merged change signal: this gateway's writes and everybody else's.
  PreferenceChangeFeed get feed => _feed;

  /// The `Preferences` currently loaded, or null when it must be rebuilt.
  Future<Preferences>? _loaded;

  /// The database instance [_loaded] was built over, for the swap check.
  ///
  /// Deliberately `Object?`: only [identical] is asked of it, and naming the
  /// real type here would mean importing the seam.
  Object? _loadedOver;

  StreamSubscription<String>? _localSource;

  bool _closed = false;

  /// The loaded `Preferences`, built if it is absent or built over a
  /// database instance the supplier has since replaced.
  ///
  /// The *future* is cached rather than the value, so two concurrent first
  /// calls share one `loadFromPostgres` instead of racing two.
  Future<Preferences> _load() async {
    if (_closed) throw StateError('this preference store has been closed');
    final db = database();
    if (db == null) throw const PreferenceStoreUnavailable();
    final loaded = _loaded;
    if (loaded != null && identical(_loadedOver, db)) return loaded;

    // `create` and not the constructor. See TRAP 8 in the library doc.
    final building = Preferences.create(db: db);
    _loaded = building;
    _loadedOver = db;
    final Preferences prefs;
    try {
      prefs = await building;
    } catch (_) {
      // A failed build must not be cached as the answer: the next caller has
      // to try again rather than inherit a broken instance forever.
      if (identical(_loaded, building)) {
        _loaded = null;
        _loadedOver = null;
      }
      rethrow;
    }
    await _localSource?.cancel();
    _localSource = prefs.onPreferencesChanged.listen(
      (key) {
        if (!_local.isClosed) _local.add(key);
      },
      onError: (Object e) {
        log?.call('preference change stream error: $e');
      },
    );
    return prefs;
  }

  // ------------------------------------------------------------------- reads

  @override
  Future<Set<String>> getKeys({Set<String>? allowList}) async =>
      (await _load()).getKeys(allowList: allowList);

  /// Every key and value, or every one in [allowList] — refused if the
  /// **encoded** answer would be over [ReadLimits.maxPreferenceBytes].
  ///
  /// ## Why encoded, and not the sum of the value lengths
  ///
  /// The frame is what fills the session's priority lane, and JSON escaping is
  /// not free: the store's two big rows are themselves JSON documents, so every
  /// `"` inside them becomes `\"` on the way out. Measured on the live store,
  /// the encoded map is **11.7 % larger** than the sum of its values — 754 707
  /// B against 675 890. A cap that measured the raw lengths would let through
  /// an answer eleven percent over its own ceiling, which is the same class of
  /// mistake as having no cap.
  ///
  /// The measurement is through the same `jsonEncode` the wire uses, and the
  /// cost is one encode of an answer that is about to be encoded again by
  /// `json_rpc_2` anyway. That double encode is the price of not guessing; at
  /// three quarters of a megabyte it is a few milliseconds, on a call a panel
  /// makes when a settings page opens.
  ///
  /// ## And why the allow-list is what the refusal names
  ///
  /// There is no smaller method to suggest. `getAll` with no allow-list is the
  /// whole store by definition, and the store grows with the plant — one
  /// `key_mappings` entry per tag. The fix is the parameter every real caller
  /// should already be passing, which the interface's own doc calls "highly
  /// recommended".
  ///
  /// **Nothing is truncated.** A partial map is a settings page rendering its
  /// *defaults* over values that are really there, with nothing saying so.
  @override
  Future<Map<String, Object?>> getAll({Set<String>? allowList}) async {
    final all = await _allOf(allowList);
    final String json;
    try {
      json = jsonEncode(all);
    } on JsonUnsupportedObjectError catch (bad) {
      // 10-REVIEW WR-06. The measurement already has the answer in hand; what
      // it did not have was a *type* the wire could read as permanent.
      throw UnencodablePreference(_firstUnencodable(all), _oneLine(bad));
    }
    final encoded = utf8.encode(json).length;
    if (encoded > limits.maxPreferenceBytes) {
      throw ResultTooLarge.bytes(
        limit: limits.maxPreferenceBytes,
        // Exact, unlike the row ceiling's: this one had to build the answer to
        // measure it, so it knows the size rather than a floor.
        measured: encoded,
        detail: 'this is the whole store encoded, and it grows with the plant '
            '— key_mappings carries one entry per tag',
        suggestion: '${DataServiceMethods.prefGetAll} with an allowList '
            'naming the keys this page actually needs',
      );
    }
    return all;
  }

  /// The cache's whole answer, **uncapped**.
  ///
  /// [ReadLimits.maxPreferenceBytes] is a ceiling on what crosses a socket, and
  /// [resync] is not crossing one: it diffs the store against itself in this
  /// process to work out which keys to announce. Subjecting it to the wire's
  /// cap would mean a plant whose store outgrew 1 MiB stopped announcing
  /// preference changes altogether — [resync] catches and logs, so the failure
  /// would be a quiet one, and "nobody saw the edit" is the failure DB-03
  /// exists to prevent.
  Future<Map<String, Object?>> _allOf(Set<String>? allowList) async =>
      (await _load()).getAll(allowList: allowList);

  /// The first key in [all] whose value `jsonEncode` refuses, or null.
  ///
  /// **One extra pass, on a path that has already failed.** That is the whole
  /// justification: this runs only after the bulk encode threw, so the cost is
  /// paid by a request that was not going to be answered anyway — and what it
  /// buys is the difference between "something in the store" and "this key",
  /// which is the difference between a support call and an `UPDATE`.
  ///
  /// Null is a legitimate answer and is not a failure: a value can be
  /// unencodable in a way that only shows up in composition (a cycle), and a
  /// refusal that guessed a key would send somebody to correct a row that is
  /// fine.
  static String? _firstUnencodable(Map<String, Object?> all) {
    for (final entry in all.entries) {
      try {
        jsonEncode(<String, Object?>{entry.key: entry.value});
      } on JsonUnsupportedObjectError {
        return entry.key;
      }
    }
    return null;
  }

  /// The first line of [error]'s own message.
  ///
  /// The whole `toString()` of a `JsonUnsupportedObjectError` carries the
  /// offending object, which is the thing that could not be encoded — putting
  /// it in a refusal that is about to be encoded is the same trap one turn
  /// later.
  static String _oneLine(Object error) {
    final text = error.runtimeType.toString();
    return text.split('\n').first;
  }

  @override
  Future<bool?> getBool(String key) async => (await _load()).getBool(key);

  @override
  Future<int?> getInt(String key) async => (await _load()).getInt(key);

  @override
  Future<double?> getDouble(String key) async => (await _load()).getDouble(key);

  @override
  Future<String?> getString(String key) async => (await _load()).getString(key);

  @override
  Future<List<String>?> getStringList(String key) async =>
      (await _load()).getStringList(key);

  @override
  Future<bool> containsKey(String key) async =>
      (await _load()).containsKey(key);

  // ------------------------------------------------------------------ writes

  @override
  Future<void> setBool(String key, bool value) async =>
      (await _load()).setBool(key, value);

  @override
  Future<void> setInt(String key, int value) async =>
      (await _load()).setInt(key, value);

  @override
  Future<void> setDouble(String key, double value) async =>
      (await _load()).setDouble(key, value);

  @override
  Future<void> setString(String key, String value) async =>
      (await _load()).setString(key, value);

  @override
  Future<void> setStringList(String key, List<String> value) async =>
      (await _load()).setStringList(key, value);

  @override
  Future<void> remove(String key) async => (await _load()).remove(key);

  /// Removes every stored preference, or every one named by [allowList].
  ///
  /// **Not a delegation, and this is the one member that could not be.**
  /// `Preferences.clear` empties the memory cache and the local cache and
  /// **never touches Postgres** (`preferences.dart:439-442`). Through this
  /// gateway that would be a clear that undoes itself: the cache is refilled
  /// from the table on the next rebuild, so every key would come back, and
  /// nothing anywhere would have said the call did not do what it said. It
  /// also fires no change event, so no connected panel would hear about it
  /// either.
  ///
  /// So it is a remove per key. That also gives the wire the right shape:
  /// each `remove` announces its key, and `data_handlers.dart` coalesces the
  /// burst into **one** `preferences.changed` frame carrying the whole set
  /// (10-05), rather than one frame per key.
  ///
  /// **One statement and one turn, not a `remove` per key.** The obvious
  /// implementation — loop over the keys calling [remove] — was written,
  /// measured and rejected: each `remove` awaits a round trip, so the event
  /// loop turns between them, and `data_handlers._scheduleFlush`'s `Timer.run`
  /// fires in every gap. Eight keys produced **eight** frames. At the five
  /// hundred keys 10-05 sized the coalescing for, that is T-10-19 restored
  /// from the caller's side: five hundred priority-lane frames per connected
  /// client and then `close(4004)`, which every operator reads as the network
  /// having dropped.
  ///
  /// So the rows go in one `DELETE`, the memory cache is emptied by upstream's
  /// own `clear` — which touches memory and nothing else, the one place that
  /// behaviour is what is wanted — and the keys are announced in a single
  /// pass with no `await` between them. Everything the burst announces is
  /// therefore pending before the flush timer can run, and the wire sees one
  /// frame carrying the whole set.
  ///
  /// **The blast radius is real and is not this file's to narrow.** With no
  /// allow-list this deletes `key_mappings` — the gateway's own routing
  /// configuration — from the shared table, and the interface's own doc says
  /// as much ("It is highly recommended that an allowList be provided"). The
  /// gate on the call is 10-05's `operate` role, which is the same role that
  /// writes a motor setpoint; narrowing it further is a policy decision, and
  /// policy lives in `policy_state_man.dart`, not here. Recorded as a threat
  /// flag rather than quietly refused, because a store that silently declined
  /// an unrestricted clear would be a fourth behaviour nobody could predict
  /// from the interface.
  @override
  Future<void> clear({Set<String>? allowList}) async {
    // **Rebuilt first, and the database borrowed once** (10-REVIEW WR-07).
    //
    // The key list comes from `Preferences.getKeys`, which reads the in-memory
    // cache — the file's own TRAP 8 paragraph says so. The cache is only as
    // fresh as the last [invalidate], which happens on a NOTIFY that the
    // 250 ms de-duplication window may have suppressed or that arrived while
    // nothing was listening. So a key another process created since the last
    // rebuild survived a `clear()` and the call reported success. `clear` is
    // the one method on this interface whose whole contract is *totality*, and
    // "everything, as of whenever we last looked" is not it.
    //
    // The second, narrower gap on the same lines: [_load] borrowed the
    // database and the DELETE borrowed it again, so a sink reconnect between
    // the two awaits deleted rows from one instance using a key list built
    // from another. One borrow, held across both.
    invalidate();
    final prefs = await _load();
    final db = database() ?? _noStore();
    final keys = (await prefs.getKeys(allowList: allowList)).toList();
    if (keys.isEmpty) return;

    // Placeholders rather than an array parameter, following
    // `preferences_watch.dart:56-63` — the one shape in this repository that
    // is known to bind a key list through this driver.
    final placeholders =
        List.generate(keys.length, (i) => '\$${i + 1}').join(', ');
    await db.db.customUpdate(
          'DELETE FROM flutter_preferences WHERE key IN ($placeholders)',
          variables: [for (final key in keys) Variable.withString(key)],
          updateKind: UpdateKind.delete,
        );
    // Memory only, deliberately: this is the single call site where
    // upstream's Postgres-untouching `clear` is the right primitive, because
    // the statement above has already done the durable half.
    await prefs.clear(allowList: keys.toSet());

    // No `await` in this loop. That is the whole point — see the doc above.
    for (final key in keys) {
      if (!_local.isClosed) _local.add(key);
    }
  }

  /// The supplier answered null between [_load] and here.
  ///
  /// Written as a `Never` so the expression it guards keeps the static type
  /// [DatabaseSupplier] declares — 10-08's seam trick, which is what lets
  /// this file call a drift method without importing the database layer.
  Never _noStore() => throw const PreferenceStoreUnavailable();

  // ------------------------------------------------------------------ events

  /// Every key whose value changed, **whoever changed it**.
  ///
  /// The merged feed and not `Preferences`' own stream: that one fires only
  /// for writes made through this instance (`preferences.dart:154-155`), and
  /// at SVN an HMI station writes the table directly.
  /// `preference_change_feed.dart` carries the merge, the de-duplication and
  /// the gap handling.
  @override
  Stream<String> get onPreferencesChanged => _feed.changes;

  /// Drops the loaded cache so the next call rebuilds it from the table.
  ///
  /// Called by the feed when somebody else wrote. Synchronous and lazy on
  /// purpose: a burst of notifications with no read between them costs one
  /// rebuild, not one per key.
  void invalidate() {
    _loaded = null;
    _loadedOver = null;
  }

  /// Rebuilds from the table and answers every key whose value changed.
  ///
  /// This is how a gap in the notification stream stops being silent. The
  /// feed calls it after every successful (re-)listen, so changes made while
  /// nothing was listening — a dead notify connection, or simply no session
  /// connected, because the channel is listener-gated — are announced rather
  /// than lost.
  ///
  /// Answers an empty set, and says so in the log, when the store could not
  /// be read: a resync that failed must never be reported as "nothing
  /// changed".
  Future<Set<String>> resync() async {
    if (_closed) return const <String>{};
    final Map<String, Object?> before;
    try {
      before = await _allOf(null);
    } catch (e) {
      log?.call('preference resync could not read the store: $e');
      return const <String>{};
    }
    invalidate();
    final Map<String, Object?> after;
    try {
      after = await _allOf(null);
    } catch (e) {
      log?.call('preference resync could not re-read the store: $e');
      return const <String>{};
    }
    final changed = <String>{};
    for (final key in <String>{...before.keys, ...after.keys}) {
      if (!_sameStoredValue(before[key], after[key])) changed.add(key);
    }
    return changed;
  }

  /// Whether two cached values are indistinguishable.
  ///
  /// Lists element by element: `getStringList` hands back a new `List` on
  /// every rebuild, and `==` on two lists is identity — so a comparison that
  /// did not do this would report every string-list preference as changed on
  /// every resync.
  static bool _sameStoredValue(Object? a, Object? b) {
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
      return true;
    }
    return a == b;
  }

  /// Releases the feed, its channel subscription and the forwarded stream.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _feed.close();
    await _localSource?.cancel();
    _localSource = null;
    await _local.close();
    _loaded = null;
    _loadedOver = null;
  }
}

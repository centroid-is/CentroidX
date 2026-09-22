/// The fifteen `PreferencesApi` members over the plant's shared preference
/// rows — `config_item` rows of kind `preference`, shared scope.
///
/// ## After main's #465: the rows, not the retired table
///
/// This store was written over `tfc_dart`'s `flutter_preferences` table, which
/// `Preferences.create` filled a cache from. #465 retired that table: the
/// shared settings are `config_item` rows, and `Preferences.create(db:)` now
/// reads nothing from the database it is handed. Built over it, this store
/// answered every key a station had written as absent and kept every write in
/// this process only — the `db` lane's round-trip, row-count and
/// other-writer cases are what showed it.
///
/// So the store now goes where the backend goes. Reads decode the rows with
/// `readSharedConfigItemsOfKind` and `decodePreferencePayload`, the codec both
/// stations write with, so `7` and `'7'` stay apart. Writes go through
/// `BackendConfigWriter` — the backend's one writer of shared configuration,
/// which reads the plant's current rows from Postgres before every write and
/// lands it through `ConfigStore.writeItems`, so the change log and the
/// compare-and-swap see a harness write exactly as they see a station's.
/// There is no session here to attribute a write to, so every write carries
/// [writerIdentity].
///
/// ## TRAP 8: the cache has to have been filled from the rows
///
/// `getKeys`, `getAll` and the getters answer from an **in-memory copy** of
/// the rows ([_load]). A store that started from an empty map would answer an
/// empty set to a plant that at SVN today holds `key_mappings` alone at
/// 530,287 bytes (`svn-prefs-live-20260811.csv`, measured). Nothing throws;
/// the first symptom is a settings page that looks like a fresh install. So
/// the copy is only ever built by reading every shared preference row, and
/// there is a case asserting a freshly built store answers a seeded
/// database's keys.
///
/// ## The cache is rebuilt, never patched from outside
///
/// The copy is of rows **other processes write** — an HMI station at SVN saves
/// its settings straight into them. When `preference_change_feed.dart` hears
/// that happen it calls [invalidate], and the next call rebuilds the whole
/// copy rather than refreshing the one key that changed: a rebuild is total,
/// so a row somebody else deleted cannot live on in it. The store's own writes
/// patch the copy after the row has landed, which is what lets [resync]
/// compare what this store last knew against what the table holds now.
///
/// ## The seam stays at two files
///
/// This file does not import `core/database.dart`. It takes 10-07's
/// [DatabaseSupplier] from next door and reaches the drift database through
/// it, so `freeze_test.dart`'s `declaredSeamImportFiles` does not move.
/// `history_view_store.dart`'s library doc carries the full argument. A null
/// supplier answer means the historian is not up, and
/// [PreferenceStoreUnavailable] is retryable and says so.
///
/// ## SEC-01: `secret:` is not spelled in this file
///
/// The concrete `Preferences` carries a `{bool secret = false}` on twelve
/// members, which routes the call to the OS keychain instead of the table.
/// The interface this store implements omits it and nothing below reaches a
/// `Preferences` at all; `preference_store_test.dart` greps this source for
/// the word — because the obvious future edit is to add it back "for
/// symmetry", and that one client-supplied boolean would be remote retrieval
/// of the secure store (T-10-35).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:tfc_dart/core/config/config_item.dart'
    show ConfigKind;
import 'package:tfc_dart/core/config/key_mapping_rows.dart'
    show readSharedConfigItemsOfKind;
import 'package:tfc_dart/core/config/preference_payload.dart';
import 'package:tfc_dart/core/relay/backend_config_writer.dart'
    show BackendConfigWriter;
import 'package:tfc_dart/core/secure_storage/interface.dart'
    show MySecureStorage;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show DataServiceMethods, PreferencesApi, ResultTooLarge, SourceRefusal;

import 'preference_change_feed.dart';
import 'read_limits.dart';
import 'timescale_reader.dart' show DatabaseSupplier, SuppliedDatabase;

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

/// `PreferencesApi` over the plant's shared `config_item` preference rows.
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

  /// Who the change log records for a write made through this store. The
  /// harness has no session to take a user or a role from.
  static const String writerIdentity = 'relay_gateway';

  /// Where the rows come from. Called per operation, never cached: the sink
  /// replaces its `Database` on reconnect, and a store holding the old one
  /// would read through a closed connection.
  final DatabaseSupplier database;

  /// The ceiling [getAll] enforces on its encoded answer.
  final ReadLimits limits;

  final void Function(String message)? log;

  /// This store's own writes, as keys. Merged into [onPreferencesChanged] by
  /// the feed, which also de-duplicates the NOTIFY each of them causes.
  final StreamController<String> _local = StreamController<String>.broadcast();

  late final PreferenceChangeFeed _feed;

  /// The change feed behind [onPreferencesChanged], exposed so a test can
  /// read whether its channel is up.
  PreferenceChangeFeed get feed => _feed;

  /// The copy of the shared rows, or null when it must be rebuilt.
  Future<Map<String, Object?>>? _loaded;

  /// The `Database` [_loaded] was read over. A different one — the sink
  /// reconnected — means the copy is rebuilt rather than trusted.
  Object? _loadedOver;

  /// The writer, and the `Database` it was built over, for the same reason.
  BackendConfigWriter? _writer;
  Object? _writerOver;

  bool _closed = false;

  SuppliedDatabase _database() {
    if (_closed) throw StateError('this preference store has been closed');
    final db = database();
    if (db == null) throw const PreferenceStoreUnavailable();
    return db;
  }

  /// The copy of the rows, read in full if it is absent or was read over a
  /// connection that has since been replaced. See TRAP 8 in the library doc.
  Future<Map<String, Object?>> _load() async {
    final db = _database();
    final loaded = _loaded;
    if (loaded != null && identical(_loadedOver, db)) return loaded;

    final building = _readRows(db);
    _loaded = building;
    _loadedOver = db;
    try {
      return await building;
    } catch (_) {
      // A failed read must not be cached as the answer: the next caller has
      // to try again rather than inherit a broken copy forever.
      if (identical(_loaded, building)) {
        _loaded = null;
        _loadedOver = null;
      }
      rethrow;
    }
  }

  /// Every shared preference row, decoded. One query, whatever the count.
  static Future<Map<String, Object?>> _readRows(SuppliedDatabase db) async {
    final items = await readSharedConfigItemsOfKind(
        db.db, ConfigKind.preference);
    return <String, Object?>{
      for (final item in items) item.id: decodePreferencePayload(item.payload),
    };
  }

  BackendConfigWriter _writerFor(SuppliedDatabase db) {
    final held = _writer;
    if (held != null && identical(_writerOver, db)) return held;
    final previous = _writer;
    _writer = null;
    _writerOver = null;
    if (previous != null) unawaited(previous.close());
    final built = BackendConfigWriter.create(
        remote: db, station: Platform.localHostname);
    if (built == null) {
      // `create` has already logged why; the store refuses the write by name
      // rather than keeping it in memory and reporting success.
      throw StateError('this gateway could not build its configuration '
          'writer, so it cannot write the shared preference rows. Nothing '
          'was written.');
    }
    _writer = built;
    _writerOver = db;
    return built;
  }

  // ------------------------------------------------------------------- reads

  @override
  Future<Set<String>> getKeys({Set<String>? allowList}) async {
    final keys = (await _load()).keys;
    return allowList == null
        ? keys.toSet()
        : keys.where(allowList.contains).toSet();
  }

  /// Every stored value — or the ones [allowList] names — measured on the
  /// **encoded** bytes before it is answered.
  ///
  /// A value `jsonEncode` refuses (a non-finite double is the one a row can
  /// hold) is an [UnencodablePreference] naming the key: permanent, because
  /// no retry changes what is stored (10-REVIEW WR-06).
  @override
  Future<Map<String, Object?>> getAll({Set<String>? allowList}) async {
    final all = await _allOf(allowList);
    final String json;
    try {
      json = jsonEncode(all);
    } on JsonUnsupportedObjectError catch (bad) {
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

  Future<Map<String, Object?>> _allOf(Set<String>? allowList) async {
    final rows = await _load();
    return <String, Object?>{
      for (final entry in rows.entries)
        if (allowList == null || allowList.contains(entry.key))
          entry.key: entry.value,
    };
  }

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

  static String _oneLine(Object error) {
    final text = error.runtimeType.toString();
    return text.split('\n').first;
  }

  /// A stored value of another type is a [TypeError], as the interface
  /// promises — the casts below are the refusal, and `async` makes it a
  /// rejected future rather than a synchronous throw.
  @override
  Future<bool?> getBool(String key) async => (await _load())[key] as bool?;

  @override
  Future<int?> getInt(String key) async => (await _load())[key] as int?;

  @override
  Future<double?> getDouble(String key) async =>
      (await _load())[key] as double?;

  @override
  Future<String?> getString(String key) async =>
      (await _load())[key] as String?;

  @override
  Future<List<String>?> getStringList(String key) async =>
      ((await _load())[key] as List?)?.cast<String>().toList();

  @override
  Future<bool> containsKey(String key) async =>
      (await _load()).containsKey(key);

  // ------------------------------------------------------------------ writes

  @override
  Future<void> setBool(String key, bool value) =>
      _set(key, kPrefBoolType, value);

  @override
  Future<void> setInt(String key, int value) => _set(key, kPrefIntType, value);

  @override
  Future<void> setDouble(String key, double value) =>
      _set(key, kPrefDoubleType, value);

  @override
  Future<void> setString(String key, String value) =>
      _set(key, kPrefStringType, value);

  @override
  Future<void> setStringList(String key, List<String> value) =>
      _set(key, kPrefStringListType, List<String>.unmodifiable(value));

  /// Lands the row, then patches the copy and announces the key. The copy is
  /// loaded first so that [resync] has what this store knew to compare
  /// against, exactly as it would after a read.
  Future<void> _set(String key, String type, Object value) async {
    final db = _database();
    final rows = await _load();
    await _writerFor(db).setPreference(key, type, value,
        who: writerIdentity,
        roleName: writerIdentity,
        station: Platform.localHostname);
    rows[key] = value;
    if (!_local.isClosed) _local.add(key);
  }

  @override
  Future<void> remove(String key) async {
    final db = _database();
    final rows = await _load();
    await _writerFor(db).removePreference(key,
        who: writerIdentity,
        roleName: writerIdentity,
        station: Platform.localHostname);
    rows.remove(key);
    if (!_local.isClosed) _local.add(key);
  }

  /// Removes the rows [allowList] names — or every shared preference row when
  /// it is null — and announces them in **one turn**.
  ///
  /// The keys are what the **table** holds, not what the copy last saw: the
  /// copy is rebuilt first, so a key another process created since the last
  /// rebuild is removed too. `clear` is the one member whose whole contract is
  /// totality.
  ///
  /// No `await` sits between the announcements. A settings page coalesces
  /// changes per frame; a loop that yielded between keys would let the flush
  /// timer fire in every gap and turn one clear into one frame per key.
  @override
  Future<void> clear({Set<String>? allowList}) async {
    final db = _database();
    invalidate();
    final rows = await _load();
    final keys = allowList == null
        ? rows.keys.toSet()
        : rows.keys.where(allowList.contains).toSet();
    if (keys.isEmpty) return;
    await _writerFor(db).clearPreferences(keys,
        who: writerIdentity,
        roleName: writerIdentity,
        station: Platform.localHostname);
    // The writer keeps bookkeeping and reserved rows whatever the list says,
    // so the copy is re-read rather than trimmed by the same list.
    invalidate();
    final after = await _load();
    for (final key in keys) {
      if (after.containsKey(key)) continue;
      if (!_local.isClosed) _local.add(key);
    }
  }

  // ------------------------------------------------------------------ events

  /// Every key that changed, whoever changed it: this store's own writes and
  /// any other process's, merged and de-duplicated by the feed.
  @override
  Stream<String> get onPreferencesChanged => _feed.changes;

  /// Drops the copy, so the next call reads the rows again.
  void invalidate() {
    _loaded = null;
    _loadedOver = null;
  }

  /// Rebuilds the copy and answers every key whose value differs from what
  /// the copy held — the changes nobody was listening for.
  Future<Set<String>> resync() async {
    if (_closed) return const <String>{};
    final Map<String, Object?> before;
    try {
      before = Map<String, Object?>.of(await _load());
    } catch (e) {
      log?.call('preference resync could not read the store: $e');
      return const <String>{};
    }
    invalidate();
    final Map<String, Object?> after;
    try {
      after = await _load();
    } catch (e) {
      log?.call('preference resync could not re-read the store: $e');
      return const <String>{};
    }
    final changed = <String>{};
    for (final key in <String>{...before.keys, ...after.keys}) {
      if (before.containsKey(key) != after.containsKey(key) ||
          !_sameStoredValue(before[key], after[key])) {
        changed.add(key);
      }
    }
    return changed;
  }

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

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _feed.close();
    await _local.close();
    _loaded = null;
    _loadedOver = null;
    final writer = _writer;
    _writer = null;
    _writerOver = null;
    await writer?.close();
  }
}

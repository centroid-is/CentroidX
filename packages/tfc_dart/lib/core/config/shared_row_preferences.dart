/// The shared preference store, as `config_item` rows: what
/// `preferencesProvider` serves once `flutter_preferences` stops being the
/// place a shared setting lives.
library;

import 'dart:async';


import '../access/guarded_config_store.dart';
import '../database.dart';
import '../preferences.dart';
import '../secure_storage/interface.dart';
import 'config_item.dart';
import 'config_store.dart' show ConfigWriteResult;
import 'preference_payload.dart';

/// The `item_key` a [clear] is checked and recorded under.
///
/// There is no one key to name and the whole store is what was affected. It
/// matches no rule in `kPrefAccessRules`, so [AccessPolicy.groupForPref]
/// answers `administer` — which is the right answer for "delete every shared
/// setting in the plant", and the same string `GuardedPreferences` used.
const String kWholeStoreItemKey = '*';

/// Ids beginning with this are bookkeeping and are not preferences.
///
/// The one shared row that qualifies is the `flutter_preferences` migration
/// marker (`kPreferencesMigratedMarkerId`), which the sync engine reads to
/// tell an empty shared store from an unmigrated one. It is invisible to
/// [getKeys], [getAll] and [clear] for the reason `SqlitePreferences`' import
/// marker is — but note the sharper rule below in [_wantedWith]: invisible is
/// not the same as absent, and a write that dropped it from the replace set
/// would delete it.
const String _internalIdPrefix = '_';

/// How a row write reaches the guard: checked, or as the app acting for
/// itself.
typedef _PreferenceWriter = Future<ConfigWriteResult> Function(
  List<ConfigItem> wanted, {
  required String prefKey,
  String? reason,
});

/// The same, for a write that lands in the keychain rather than in a row.
///
/// Separate because there is nothing to diff and nothing to replace — the
/// guard checks, records a row naming neither side of the value, and then runs
/// [write]. It exists at all because `GuardedPreferences` checked and recorded
/// secret writes too, and the one write in the app that must never fall out of
/// the trail is the one that stores a credential.
typedef _SecretWriter = Future<void> Function({
  required String prefKey,
  required Future<void> Function() write,
  String? reason,
});

/// A [Preferences] whose shared values are `kind='preference'` rows at
/// [ConfigScope.shared], written through [GuardedConfigStore].
///
/// ## Why this exists at all
///
/// "Drop `flutter_preferences`" is really "replace the shared `PreferencesApi`
/// implementation". Every Postgres path in [Preferences] is that one table:
/// `_upsertToPostgres`, `loadFromPostgres`, the `DELETE` in [remove] and
/// `isKeyInDatabase`'s key cache. This class is those four paths re-expressed
/// over rows, so the eight remaining shared key families — `alarm_man_config`,
/// `page_editor_top_level_order`, `page_editor_image:<id>`,
/// `<bucket>.recipes`, `server_config_envelope`, `state_man_config`,
/// `collector_config` and `update_channel` — move without a caller changing.
///
/// ## Why not "generalise SqlitePreferences to take a scope"
///
/// The write paths differ in kind, not in detail. Local rows are owned by this
/// machine and written directly; shared rows are owned by Postgres and must go
/// through [ConfigStore]'s compare-and-swap, its refusal when offline and its
/// change-row append. One class pretending otherwise would either bypass the
/// guard locally or drag the guard into the local path — and the local path is
/// where the session itself is stored, so a check in front of it would need a
/// session to read the session. The two stores share the *codec*
/// (`preference_payload.dart`) and nothing else.
///
/// ## One guard, and it is not this one
///
/// [GuardedPreferences] is not wrapped around this class and must not be: the
/// check lives in [GuardedConfigStore.writePreference], one layer down, where
/// the same call that checks also mints the `action_id` that the
/// `audit_entry` and the `config_change` rows share. Wrapping would produce
/// two audit rows for one write and two ideas of who did it. The deny path is
/// unchanged in the ways that matter — [AccessDenied] out of the setter,
/// `onDenied` fired, a row written before the throw, and a key no rule names
/// answering `administer` rather than falling open.
///
/// ## Extends [Preferences] rather than implementing [PreferencesApi]
///
/// The provider's callers use members [PreferencesApi] does not have —
/// `setString(key, value, secret: true)`, `saveToDb: false`,
/// [onPreferencesChanged], [isKeyInDatabase], the `database` escape — so the
/// narrower interface would force every one of them to change, which is what
/// "callers change nothing" forbids. Extending also keeps the secret path
/// *exactly* where it was: secrets are the OS keychain's, never a row, and
/// `super` owns the process-wide read cache that keeps macOS from prompting
/// once per widget rebuild. Every non-secret member is overridden below; the
/// secret arms delegate up.
class SharedRowPreferences extends Preferences {
  /// The ordinary, checked store.
  ///
  /// [database] is the shared [Database] handle, carried only so the
  /// `database` escape [Preferences] obliges this class to expose keeps
  /// answering what it answered before. Nothing here reads it.
  SharedRowPreferences({
    required GuardedConfigStore store,
    required MySecureStorage secureStorage,
    Database? database,
  }) : this._(
          store: store,
          secureStorage: secureStorage,
          database: database,
          writer: store.writePreference,
          secretWriter: store.writeSecret,
          events: StreamController<String>.broadcast(),
          ownsEvents: true,
        );

  SharedRowPreferences._({
    required GuardedConfigStore store,
    required MySecureStorage secureStorage,
    required Database? database,
    required _PreferenceWriter writer,
    required _SecretWriter secretWriter,
    required StreamController<String> events,
    required bool ownsEvents,
  })  : _store = store,
        _writer = writer,
        _secretWriter = secretWriter,
        _events = events,
        _ownsEvents = ownsEvents,
        super(
          database: database,
          secureStorage: secureStorage,
        ) {
    if (ownsEvents) {
      // The change feed, and not a local echo: a shared preference another
      // station wrote must reach a listener here, which is what the keyed
      // `flutter_preferences` NOTIFY did and what a store-and-forward of our
      // own writes would not. Our own writes come back through the same
      // stream, so they are announced once rather than twice.
      _diffs = _store.inner.keyMappingChanges.listen((diff) {
        for (final item in [...diff.added, ...diff.changed, ...diff.removed]) {
          if (item.kind != ConfigKind.preference) continue;
          if (_isInternal(item.id)) continue;
          _events.add(item.id);
        }
      });
    }
  }

  final GuardedConfigStore _store;
  final _PreferenceWriter _writer;
  final _SecretWriter _secretWriter;
  final StreamController<String> _events;
  final bool _ownsEvents;
  StreamSubscription<Object?>? _diffs;
  SharedRowPreferences? _system;

  /// The unchecked write path, for the defaults the app writes for itself.
  ///
  /// The same object in every respect but the writer: same store, same
  /// keychain, same event stream, so a boot default is announced to the same
  /// listeners an operator's edit is. See
  /// [GuardedConfigStore.writePreferenceAsSystem] for what it is and is not
  /// for.
  Preferences get systemWrites => _system ??= SharedRowPreferences._(
        store: _store,
        secureStorage: secureStorage,
        database: database,
        writer: _store.writePreferenceAsSystem,
        secretWriter: _store.writeSecretAsSystem,
        events: _events,
        ownsEvents: false,
      );

  // ---------------------------------------------------------------------
  // Reads — from the snapshot, which is filled from the local mirror at boot
  // and kept level by the sync engine. No network on this path.
  // ---------------------------------------------------------------------

  /// Every shared preference row this station holds, bookkeeping included,
  /// keyed by id.
  ///
  /// **Bookkeeping included, deliberately.** [_wantedWith] builds a write's
  /// replace set from this, and `writeItems` replaces within kinds: a marker
  /// row left out of the set would be deleted by the next preference write,
  /// and the station would then read an un-migrated shared store as an empty
  /// one. The filtering happens where the values are *served*, not here.
  ///
  /// Shared scope is asserted rather than assumed. The snapshot is filled by
  /// `kind IN (…) AND scope='shared'` everywhere, so a station row cannot be
  /// in it — but this store must never serve one if that ever changes, since
  /// the watermark and the import marker are station-scoped preference rows.
  Map<String, ConfigItem> _rows() => {
        for (final item in _store.inner.itemsOf(const {ConfigKind.preference}))
          if (item.scope == ConfigScope.shared) item.id: item,
      };

  /// The value [key] holds, or null when there is no row or the row holds
  /// something this build cannot read.
  Object? _read(String key) {
    final item = _rows()[key];
    return item == null ? null : decodePreferencePayload(item.payload);
  }

  @override
  Future<bool?> getBool(String key, {bool secret = false}) async =>
      secret ? super.getBool(key, secret: true) : _read(key) as bool?;

  @override
  Future<int?> getInt(String key, {bool secret = false}) async =>
      secret ? super.getInt(key, secret: true) : _read(key) as int?;

  @override
  Future<double?> getDouble(String key, {bool secret = false}) async =>
      secret ? super.getDouble(key, secret: true) : _read(key) as double?;

  @override
  Future<String?> getString(String key, {bool secret = false}) async =>
      secret ? super.getString(key, secret: true) : _read(key) as String?;

  @override
  Future<List<String>?> getStringList(String key, {bool secret = false}) async =>
      secret
          ? super.getStringList(key, secret: true)
          : _read(key) as List<String>?;

  @override
  Future<bool> containsKey(String key, {bool secret = false}) async {
    // The same refusal `Preferences` gives: the keychain has no "is it there"
    // that does not read it, and reading a secret to answer a boolean is how
    // a credential ends up somewhere it was not asked for.
    if (secret) return super.containsKey(key, secret: true);
    return _rows().containsKey(key);
  }

  @override
  Future<Set<String>> getKeys({Set<String>? allowList}) async => {
        for (final entry in _rows().entries)
          if (_isServed(entry.key, allowList) &&
              decodePreferencePayload(entry.value.payload) != null)
            entry.key,
      };

  @override
  Future<Map<String, Object?>> getAll({Set<String>? allowList}) async {
    final all = <String, Object?>{};
    for (final entry in _rows().entries) {
      if (!_isServed(entry.key, allowList)) continue;
      final value = decodePreferencePayload(entry.value.payload);
      // `PreferencesApi.getAll` "ignores any entries of types which are
      // incompatible": a row an older station cannot read must cost that one
      // row, never the whole read.
      if (value == null) continue;
      all[entry.key] = value;
    }
    return all;
  }

  /// Whether [key] is a preference a caller asked for, rather than a marker
  /// row or a key outside [allowList].
  ///
  /// On a **read**, `allowList` narrows. On [clear] it removes — the opposite
  /// reading, and the one `InMemoryPreferences`, `SqlitePreferences` and
  /// `SharedPreferencesAsyncWindows` all have. Inverted, a clear wipes the
  /// plant, so the two are separate methods rather than one shared helper.
  bool _isServed(String key, Set<String>? allowList) =>
      !_isInternal(key) && (allowList == null || allowList.contains(key));

  @override
  Future<bool> isKeyInDatabase(String key) async => _rows().containsKey(key);

  // ---------------------------------------------------------------------
  // Writes — one row, through the one guarded save.
  // ---------------------------------------------------------------------

  @override
  Future<void> setBool(String key, bool value,
          {bool saveToDb = true, bool secret = false}) =>
      _set(key, kPrefBoolType, value, saveToDb: saveToDb, secret: secret);

  @override
  Future<void> setInt(String key, int value,
          {bool saveToDb = true, bool secret = false}) =>
      _set(key, kPrefIntType, value, saveToDb: saveToDb, secret: secret);

  @override
  Future<void> setDouble(String key, double value,
          {bool saveToDb = true, bool secret = false}) =>
      _set(key, kPrefDoubleType, value, saveToDb: saveToDb, secret: secret);

  @override
  Future<void> setString(String key, String value,
          {bool saveToDb = true, bool secret = false}) =>
      _set(key, kPrefStringType, value, saveToDb: saveToDb, secret: secret);

  @override
  Future<void> setStringList(String key, List<String> value,
          {bool saveToDb = true, bool secret = false}) =>
      _set(key, kPrefStringListType, value,
          saveToDb: saveToDb, secret: secret);

  /// One preference, written as the whole shared set with one item replaced.
  ///
  /// [saveToDb] false is the caller saying "this value is not the shared
  /// store's" — `StateManConfig.toPrefs` writes the local half of a config
  /// that way. There is no in-memory tier under this store to write it to
  /// instead, so it writes nothing and announces the key, which is what the
  /// caller observed before: `_upsertToPostgres` was the only thing
  /// `saveToDb` ever guarded.
  Future<void> _set(
    String key,
    String type,
    Object value, {
    required bool saveToDb,
    required bool secret,
  }) async {
    if (secret) {
      // Never a row. `super` writes the keychain, keeps the process-wide read
      // cache honest, and returns without touching the shared store.
      await _setSecret(key, type, value);
      _events.add(key);
      return;
    }
    if (!saveToDb) {
      _events.add(key);
      return;
    }
    final item = ConfigItem.of(
      kind: ConfigKind.preference,
      id: key,
      value: preferencePayload(type, value),
    );
    // No dedupe here, and that is not an oversight: the store compares
    // structurally and returns without writing a row, a change row, an audit
    // row or an event when nothing moved — and it does so *after* refusing an
    // offline write, so a caller whose write cannot reach Postgres is told
    // every time rather than only when it would have written something.
    await _writer(_wantedWith(key, item), prefKey: key);
  }

  /// The secret write: checked and recorded by the guard, then delegated up
  /// so the keychain and its read cache stay [Preferences]' business.
  ///
  /// Typed by the same tag the row would have carried, so a secret and a
  /// shared value of the same key round-trip the way they did before.
  Future<void> _setSecret(String key, String type, Object value) =>
      _secretWriter(
        prefKey: key,
        write: () => _writeSecretValue(key, type, value),
      );

  Future<void> _writeSecretValue(String key, String type, Object value) {
    switch (type) {
      case kPrefBoolType:
        return super.setBool(key, value as bool, secret: true);
      case kPrefIntType:
        return super.setInt(key, value as int, secret: true);
      case kPrefDoubleType:
        return super.setDouble(key, value as double, secret: true);
      case kPrefStringListType:
        return super.setStringList(key, value as List<String>, secret: true);
      default:
        return super.setString(key, value as String, secret: true);
    }
  }

  /// Removes one shared preference.
  ///
  /// **A bookkeeping row is not one, and naming it does not make it one.**
  /// [clear] has always kept the `_`-prefixed rows and this did not, and the
  /// asymmetry was the bug: the only internal shared row is the
  /// `flutter_preferences` migration marker, which `config_sync.dart` reads at
  /// `scope='shared'` to tell an empty remote from an unmigrated one. Deleting
  /// it makes every station read a fully migrated plant as one whose migration
  /// has not run — and once 04-12 has dropped `flutter_preferences`, there is
  /// nothing left to re-read it from.
  ///
  /// **A deliberate divergence from `SqlitePreferences`**, whose [remove] is
  /// *not* filtered and says so: its marker is this station's own account of a
  /// local import, naming it is how an operator asks for that import to run
  /// again, and the worst case is one station re-reading one file. Here the
  /// row belongs to the whole plant and the worst case is every station
  /// mistaking a migrated store for an unmigrated one, so the same reasoning
  /// lands on the opposite answer.
  ///
  /// **Refused silently, and the silence is load-bearing rather than lazy.**
  /// The general worry about a silent no-op — that a caller who named one
  /// specific key is ignored without a word — does not apply here, because
  /// **no caller can name this key**: an internal id is `_`-prefixed and
  /// [getKeys] and [getAll] never surface one, so the preferences editor
  /// cannot offer it and nothing builds one. Reaching this line at all is a
  /// programming error, not an operator's mistake, and matching [clear] is
  /// worth more than a log line nobody will read. A throw was the other
  /// candidate and is worse: a panel that stops beats nothing, and nothing is
  /// what is at stake.
  ///
  /// **There are two silent returns in this method and only this one is
  /// right.** The other — `if (!rows.containsKey(key)) return;` below —
  /// answers "the snapshot does not hold that key", which on a station whose
  /// sync is lagging is *not* the same as "the plant does not hold that key":
  /// an operator's delete is then neither performed, nor checked, nor
  /// recorded, and they are told nothing. **That is a real defect, flagged
  /// for 04-12/04-13, and it is not this one.** They are written down together
  /// so that whoever eventually fixes it does not "tidy up" the guard above
  /// on the way past, and so that whoever tidies the guard does not conclude
  /// the one below is equally deliberate.
  ///
  /// Reads are **not** filtered, and that is not a half-applied rule.
  /// [containsKey] still answers for a marker, because asking whether a
  /// migration has run is the marker's whole purpose and a read destroys
  /// nothing.
  @override
  Future<void> remove(String key, {bool secret = false}) async {
    if (secret) {
      // Checked and recorded exactly as a secret write is: a deletion of a
      // credential is as much a configuration change as setting one. Above
      // the rule below on purpose: an internal id names a *row*, and this
      // deletes a keychain entry.
      await _secretWriter(
          prefKey: key, write: () => super.remove(key, secret: true));
      _events.add(key);
      return;
    }
    // Bookkeeping is not a preference, and this is the guard [clear] already
    // has. Silent on purpose — see the doc: the id is unreachable to callers,
    // so there is nobody to tell. NOT the same as the silent return below it.
    if (_isInternal(key)) return;
    final rows = _rows();
    // "Removing what was never there is not a change" — said here as well as
    // in the store, because the store would refuse it when offline and a
    // no-op that fails is a confusing thing to explain to an operator.
    //
    // **Suspect, and deliberately left alone here.** This reads the local
    // snapshot, so on a station whose sync is lagging it answers "not there"
    // about a row the plant does have; the operator's delete is then silently
    // dropped rather than attempted, checked or recorded. Flagged for
    // 04-12/04-13 rather than changed in a plan about bookkeeping rows,
    // because the fix is a decision about what an unsynced delete should do
    // and not a line edit.
    if (!rows.containsKey(key)) return;
    final wanted = [
      for (final entry in rows.entries)
        if (entry.key != key) entry.value,
    ];
    await _writer(wanted, prefKey: key);
  }

  /// Removes every shared preference, or only those named in [allowList].
  ///
  /// **[allowList] is a removal list, not a keep-list.** Inverted, this wipes
  /// the plant's configuration.
  ///
  /// Checked and recorded as [kWholeStoreItemKey], which no rule in
  /// `kPrefAccessRules` names and which therefore requires `administer`. That
  /// is the intended answer rather than an accident of the fail-closed
  /// default: this deletes settings belonging to three different groups in one
  /// action, so the strictest of them is the only defensible check.
  ///
  /// The marker rows survive, for the reason [_rows] gives.
  @override
  Future<void> clear({Set<String>? allowList}) async {
    final rows = _rows();
    final wanted = [
      for (final entry in rows.entries)
        if (_isInternal(entry.key) ||
            (allowList != null && !allowList.contains(entry.key)))
          entry.value,
    ];
    if (wanted.length == rows.length) return;
    await _writer(wanted, prefKey: kWholeStoreItemKey);
  }

  /// Every shared preference that must exist after a write of [key], with
  /// [item] in place of whatever was there.
  ///
  /// The **full** set, because `writeItems` replaces within kinds: passing the
  /// one item that changed would delete every sibling — every other shared
  /// preference in the plant, in one save. `shared_preferences_rows_test.dart`
  /// seeds three keys, writes one and asserts three remain.
  List<ConfigItem> _wantedWith(String key, ConfigItem item) {
    final wanted = <ConfigItem>[];
    var replaced = false;
    for (final entry in _rows().entries) {
      if (entry.key == key) {
        wanted.add(item);
        replaced = true;
      } else {
        wanted.add(entry.value);
      }
    }
    if (!replaced) wanted.add(item);
    return wanted;
  }

  // ---------------------------------------------------------------------
  // The change feed
  // ---------------------------------------------------------------------

  /// The keys that have changed, from wherever they changed.
  ///
  /// Three sources, one stream: this station's own shared writes and any other
  /// station's, both arriving through [ConfigStore]'s change feed, plus secret
  /// writes, which touch no row and so have no other way to be announced.
  /// [Preferences]' own controller is left unused — a write here does not go
  /// through it.
  @override
  Stream<String> get onPreferencesChanged => _events.stream;

  /// Releases the change-feed subscription and the stream.
  ///
  /// The store and the databases are the provider's to close. Calling this on
  /// [systemWrites] does nothing: it shares its parent's stream and closing it
  /// from there would silence the parent.
  Future<void> close() async {
    if (!_ownsEvents) return;
    await _diffs?.cancel();
    _diffs = null;
    await _events.close();
  }

  // ---------------------------------------------------------------------
  // The `flutter_preferences` paths, now answered by the store
  // ---------------------------------------------------------------------

  static bool _isInternal(String id) => id.startsWith(_internalIdPrefix);
}

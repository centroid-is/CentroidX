/// The device-local preference store: one `config_item` row per preference.
library;

import 'package:drift/drift.dart';
import 'package:logger/logger.dart';
import 'package:tfc_access/tfc_access.dart' show newActionId;

import 'config/config_change.dart';
import 'config/config_history_policy.dart';
import 'config/config_item.dart';
import 'config/preference_payload.dart';
import 'database_drift.dart';
import 'preferences.dart';

/// The `who` and `updated_by` of every row this store writes.
///
/// See the note on attribution in [SqlitePreferences]: there is no session to
/// name, and naming one that does not exist would be worse than naming none.
const String _anonymous = 'anonymous';

/// The `role_name` of every change row this store writes. Empty, not a role
/// name, for the same reason [_anonymous] is anonymous.
const String _noRole = '';

/// Ids beginning with this are the store's own bookkeeping and are not
/// preferences.
const String _internalIdPrefix = '_';

/// Only ever used off the happy path — a legacy value of a type this API
/// cannot carry. Nothing here logs per write.
final Logger _logger = Logger();

/// A [PreferencesApi] over `config_item` rows at one [ConfigScope].
///
/// Each preference is one row of `kind='preference'`, `id=<the key>`, at this
/// store's scope, whose payload is a two-field object naming the value's type:
///
/// ```json
/// {"type": "bool",         "value": true}
/// {"type": "int",          "value": 7}
/// {"type": "double",       "value": 7.0}
/// {"type": "String",       "value": "7"}
/// {"type": "List<String>", "value": ["a", "b"]}
/// ```
///
/// ## Why the type is written down and not inferred
///
/// [PreferencesApi] is typed across those five, and `'7'` and `7` are two
/// different preferences — the guard `Preferences._sameStoredValue` states
/// ("Types are compared too, not just contents"). The tag is what relocates
/// that guard into the row. It also rescues the one case JSON alone cannot:
/// [samePayload] compares with `DeepCollectionEquality`, for which `1 == 1.0`,
/// so writing `int 1` over a stored `double 1.0` would look like no change at
/// all, be skipped, and leave [getInt] returning a `double` that throws at the
/// call site. `{"type":"int"}` and `{"type":"double"}` are not structurally
/// equal, so the write happens.
///
/// The five strings are exactly the ones `Preferences.loadFromPostgres`
/// switches on, so moving the `flutter_preferences` rows into `config_item` is
/// a copy rather than a translation.
///
/// ## Why a write can be no write at all
///
/// Every setter reads the stored payload first and returns without touching
/// anything when [samePayload] says the configuration is unchanged. This is
/// not an optimisation, it is what makes the change log finite:
/// `Preferences.syncToLocalCache` copies the whole in-memory cache — including
/// a 530 kB `key_mappings` and a 145 kB `page_editor_data` — into this store on
/// every startup and every database reconnect. Without the skip, one network
/// blip would append about 1.4 MB of change rows in which nothing happened.
/// The dedupe lives here, in the row writer, rather than in that one caller,
/// so it holds for every caller. See `01-RESEARCH.md` C-1.
///
/// ## Scope, and what Phase 2 must undo
///
/// Every row is written at this store's [scope], which in the app is
/// `station:<hostname>` — no exceptions, no per-key routing. Some of those rows
/// nevertheless hold *shared* data cached locally: `syncToLocalCache` copies
/// `key_mappings`, `page_editor_data` and `alarm_man_config` down from
/// Postgres, and `PageManager.load()` reads `page_editor_data` back out before
/// `runApp`. That is correct for Phase 1 and it is the literal reading of the
/// scope decision.
///
/// **Phase 2 re-homes those mirrored keys to `scope='shared'` and deletes the
/// station-scoped copy.** Written down because without it Phase 2 ends up with
/// two copies of `key_mappings` in one local file under two scopes, each
/// looking authoritative. See `01-RESEARCH.md` C-5.
///
/// ## Attribution, and the audit trail this is not part of
///
/// Every change row says `who: 'anonymous'`, `role_name: ''`. That is a
/// statement of fact rather than a gap to be filled later: [PreferencesApi]
/// carries no session, deliberately, because the session itself is stored
/// through this store — a check in front of it would need a session to read the
/// session. An unattributed row is fine; an unattributed row that looks
/// attributed is not.
///
/// **These rows are local-only.** A station-scoped change gets a
/// `config_change` row in this database and reaches nothing else — in
/// particular it never reaches the central `audit_entry`. Forwarding it would
/// need a store-and-forward queue for the hours a station spends unable to
/// reach Postgres, and this milestone declines to build one. Said out loud
/// because "the same audit trail" would otherwise read as a promise the design
/// does not keep.
class SqlitePreferences implements PreferencesApi {
  /// Reads and writes preference rows in [_db] at [scope].
  ///
  /// Plain by design: the singleton lives in the app's factory, not here, so a
  /// test can construct as many of these over one database as it likes.
  SqlitePreferences(this._db, {required this.scope});

  final AppDatabase _db;

  /// Which store owns every row this instance reads and writes. Rows at any
  /// other scope are invisible to it and untouched by [clear] — which is what
  /// makes a database restored from another machine's backup inert rather than
  /// adopted.
  final ConfigScope scope;

  /// The wire strings for the five types [PreferencesApi] carries.
  ///
  /// Pointers at `config/preference_payload.dart`, which owns them, because
  /// the shared store writes the same bytes into the same column and two
  /// definitions would be two answers to what is on disk.
  static const String _boolType = kPrefBoolType;
  static const String _intType = kPrefIntType;
  static const String _doubleType = kPrefDoubleType;
  static const String _stringType = kPrefStringType;
  static const String _stringListType = kPrefStringListType;

  /// The hostname change rows are stamped with. A store at [ConfigScope.shared]
  /// has no station to name; Phase 1 never constructs one.
  String get _station => scope.station ?? '';

  // ---------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------

  @override
  Future<bool?> getBool(String key) async => (await _read(key)) as bool?;

  @override
  Future<int?> getInt(String key) async => (await _read(key)) as int?;

  @override
  Future<double?> getDouble(String key) async => (await _read(key)) as double?;

  @override
  Future<String?> getString(String key) async => (await _read(key)) as String?;

  @override
  Future<List<String>?> getStringList(String key) async =>
      (await _read(key)) as List<String>?;

  @override
  Future<bool> containsKey(String key) async => (await _row(key)) != null;

  @override
  Future<Set<String>> getKeys({Set<String>? allowList}) async {
    final rows = await _rows(allowList: allowList);
    return {
      for (final row in rows)
        if (!_isInternal(row.id) && _decode(row.payload) != null) row.id,
    };
  }

  @override
  Future<Map<String, Object?>> getAll({Set<String>? allowList}) async {
    final all = <String, Object?>{};
    for (final row in await _rows(allowList: allowList)) {
      if (_isInternal(row.id)) continue;
      final value = _decode(row.payload);
      // `PreferencesApi.getAll` "ignores any entries of types which are
      // incompatible", and `ConfigKind.byWireName` is nullable rather than
      // throwing for the same reason: a row an older station cannot read must
      // cost that one row, never the whole read.
      if (value == null) continue;
      all[row.id] = value;
    }
    return all;
  }

  // ---------------------------------------------------------------------
  // Writes
  // ---------------------------------------------------------------------

  @override
  Future<void> setBool(String key, bool value) => _set(key, _boolType, value);

  @override
  Future<void> setInt(String key, int value) => _set(key, _intType, value);

  @override
  Future<void> setDouble(String key, double value) =>
      _set(key, _doubleType, value);

  @override
  Future<void> setString(String key, String value) =>
      _set(key, _stringType, value);

  @override
  Future<void> setStringList(String key, List<String> value) =>
      _set(key, _stringListType, value);

  @override
  Future<void> remove(String key) async {
    await _db.transaction(() async {
      final existing = await _row(key);
      // Removing what was never there is not a change, and a change log full
      // of deletions of nothing is a log nobody reads.
      if (existing == null) return;
      await _deleteRow(existing.id);
      await _log(
        at: DateTime.now(),
        actionId: newActionId(),
        before: _itemOf(existing),
        after: null,
      );
    });
  }

  /// Removes every preference at this scope, or only those named in
  /// [allowList].
  ///
  /// **[allowList] is a removal list, not a keep-list** — the same reading as
  /// `InMemoryPreferences.clear` and `SharedPreferencesAsyncWindows.clear`.
  /// Inverted, this wipes the store.
  ///
  /// Rows at any other scope, and rows of any other kind, are never touched.
  /// The whole batch shares one `action_id`, so a clear of nine keys reads as
  /// one action rather than nine unrelated ones.
  ///
  /// **The store's own internal rows survive a clear** — the import marker
  /// above all. [PreferencesApi.clear] documents removing "all preferences",
  /// and the marker is not one: it is bookkeeping, invisible to [getKeys] and
  /// [getAll], and nothing that reads a preference can see it. Taking it would
  /// mean the next boot re-imports a `shared_preferences` file that is by then
  /// months stale, over local edits made since — silent data loss from an
  /// operation whose whole point was to *remove* data. A caller that genuinely
  /// wants the import to run again names the marker to [remove]; that is a
  /// deliberate act, and clearing is not.
  @override
  Future<void> clear({Set<String>? allowList}) async {
    await _db.transaction(() async {
      final rows = (await _rows(allowList: allowList))
          .where((row) => !_isInternal(row.id))
          .toList(growable: false);
      if (rows.isEmpty) return;
      final actionId = newActionId();
      final at = DateTime.now();
      for (final row in rows) {
        await _deleteRow(row.id);
        await _log(
          at: at,
          actionId: actionId,
          before: _itemOf(row),
          after: null,
        );
      }
    });
  }

  // ---------------------------------------------------------------------
  // The one-shot import
  // ---------------------------------------------------------------------

  /// Copies a legacy `shared_preferences` store into this one, once, and
  /// records that it has done so. Returns whether it imported.
  ///
  /// Everything lands in **one transaction under one `action_id`**: every
  /// typed row, every change row, and the marker row [markerId] last. Either
  /// the station has imported or it has not — there is no half-imported state
  /// to reason about after a power cut mid-boot.
  ///
  /// ## Why a marker row and not a file, or a per-key insert-if-absent
  ///
  /// If a row with id [markerId] already exists at this [scope], this returns
  /// false having written nothing. `INSERT … ON CONFLICT DO NOTHING` per key
  /// would not be enough on its own: a key the operator legitimately *deleted*
  /// after the import would come back on the next boot, over and over. The flag
  /// has to be about the import, not about the keys.
  ///
  /// A row rather than a file on disk, so a database restored from a backup
  /// carries the flag along with the data it describes. It is `kind`
  /// `'preference'` with an underscore-prefixed id, which is what keeps it out
  /// of [getKeys], [getAll] and [clear].
  ///
  /// ## What is skipped
  ///
  /// [PreferencesApi] carries five types. A value of any other runtime type —
  /// a `List<int>`, a null — is skipped with a log line and the rest of the
  /// import proceeds: one unreadable legacy entry must cost that entry, never
  /// the startup page. Lists are accepted as `List<dynamic>` when every element
  /// is a `String`, because the raw-file fallback the app reads with decodes
  /// JSON and JSON has no typed lists.
  ///
  /// A key whose stored value already matches writes nothing at all — the same
  /// dedupe every setter runs, so re-importing an already-correct store costs
  /// one row, the marker.
  Future<bool> importAll(
    Map<String, Object?> values, {
    required String markerId,
  }) =>
      _db.transaction(() async {
        if (await _row(markerId) != null) return false;
        final at = DateTime.now();
        final actionId = newActionId();
        for (final entry in values.entries) {
          final tagged = _tag(entry.value);
          if (tagged == null) {
            _logger.w('Import skipped "${entry.key}": '
                '${entry.value.runtimeType} is not a preference type');
            continue;
          }
          await _writeRow(
            key: entry.key,
            type: tagged.type,
            value: tagged.value,
            at: at,
            actionId: actionId,
          );
        }
        // Last, and inside the same transaction: a marker written before the
        // rows would, on a crash between the two, leave a station that believes
        // it has imported and has not.
        await _writeRow(
          key: markerId,
          type: _stringType,
          value: at.toIso8601String(),
          at: at,
          actionId: actionId,
        );
        return true;
      });

  /// The type tag and the value to store for [value], or null when
  /// [PreferencesApi] cannot carry its type.
  static ({String type, Object value})? _tag(Object? value) {
    final type = preferenceTypeOf(value);
    if (type == null) return null;
    if (value is List) {
      // Cast now, so the payload is a list of strings whatever the source's
      // static type was.
      return (
        type: type,
        value: value.cast<String>().toList(growable: false),
      );
    }
    return (type: type, value: value!);
  }

  // ---------------------------------------------------------------------
  // The row writer
  // ---------------------------------------------------------------------

  /// Stores [value] under [key] with the tag [type], or does nothing at all if
  /// that is already what is stored.
  ///
  /// One transaction per call: the item row and its change row are one write or
  /// neither, because a change row describing a write that did not land is
  /// worse than no history.
  Future<void> _set(String key, String type, Object value) async {
    await _db.transaction(() => _writeRow(
          key: key,
          type: type,
          value: value,
          at: DateTime.now(),
          actionId: newActionId(),
        ));
  }

  /// Writes one typed row and the change row describing it, or writes nothing
  /// at all when the stored payload already says the same thing. Returns
  /// whether anything was written.
  ///
  /// [at] and [actionId] are the caller's rather than minted here, because
  /// [importAll] writes a whole legacy store as **one** action: a change log in
  /// which one import reads as forty unrelated actions is a log nobody can
  /// undo.
  ///
  /// **Not a transaction on its own** — every caller wraps it, because a change
  /// row describing a write that did not land is worse than no history.
  Future<bool> _writeRow({
    required String key,
    required String type,
    required Object value,
    required DateTime at,
    required String actionId,
  }) async {
    final after = ConfigItem.of(
      kind: ConfigKind.preference,
      id: key,
      value: {'type': type, 'value': value},
      scope: scope,
    );
    final existing = await _row(key);
    // C-1. Structural, not textual: a payload written before the canonical
    // encoding existed must not read as an edit on sight.
    if (existing != null && samePayload(existing.payload, after.payload)) {
      return false;
    }
    if (existing == null) {
      await _db.into(_db.configItemTable).insert(
            ConfigItemTableCompanion.insert(
              kind: ConfigKind.preference.wireName,
              id: key,
              scope: scope.wireName,
              payload: after.payload,
              rev: const Value(1),
              updatedAt: at,
              updatedBy: _anonymous,
            ),
          );
    } else {
      await (_db.update(_db.configItemTable)
            ..where((t) => _identity(t, existing.id)))
          .write(ConfigItemTableCompanion(
        payload: Value(after.payload),
        rev: Value(existing.rev + 1),
        updatedAt: Value(at),
        updatedBy: const Value(_anonymous),
      ));
    }
    await _log(
      at: at,
      actionId: actionId,
      before: existing == null ? null : _itemOf(existing),
      after: after,
    );
    return true;
  }

  /// Appends one row to the local change log, unless the preference is one
  /// that carries no history.
  ///
  /// Built through [ConfigChange.of] rather than by hand: it is what guarantees
  /// each side is `ConfigItem.encodeEntity()` and therefore restorable.
  ///
  /// The exemption is asked here rather than by the caller, and it is not
  /// theoretical: `server_config_envelope` is PBKDF2+AES-256-GCM ciphertext
  /// and this is the store it lands in once it leaves `flutter_preferences`.
  /// `config_change` is never pruned, so a ciphertext written here would
  /// outlive every rotation of it. See `config/config_history_policy.dart`.
  Future<void> _log({
    required DateTime at,
    required String actionId,
    ConfigItem? before,
    ConfigItem? after,
  }) async {
    final change = ConfigChange.of(
      at: at,
      actionId: actionId,
      who: _anonymous,
      station: _station,
      roleName: _noRole,
      before: before,
      after: after,
    );
    if (historyExempt(change.kind, change.entityId)) return;
    await _db.into(_db.configChangeTable).insert(
          ConfigChangeTableCompanion.insert(
            at: change.at,
            actionId: change.actionId,
            who: change.who,
            station: change.station,
            roleName: change.roleName,
            kind: change.kind.wireName,
            entityId: change.entityId,
            scope: change.scope.wireName,
            op: change.op.wireName,
            oldValue: Value(change.oldValue),
            newValue: Value(change.newValue),
          ),
        );
  }

  Future<void> _deleteRow(String key) =>
      (_db.delete(_db.configItemTable)..where((t) => _identity(t, key))).go();

  // ---------------------------------------------------------------------
  // Queries
  // ---------------------------------------------------------------------

  /// This store's rows, or only those named in [allowList].
  ///
  /// An empty [allowList] short-circuits: `IN ()` is not valid SQL, and an
  /// allow-list of nothing selects nothing anyway.
  Future<List<ConfigItemRow>> _rows({Set<String>? allowList}) async {
    if (allowList != null && allowList.isEmpty) return const [];
    return (_db.select(_db.configItemTable)
          ..where((t) => _scopedPreferences(t, allowList)))
        .get();
  }

  Future<ConfigItemRow?> _row(String key) => (_db.select(_db.configItemTable)
        ..where((t) => _identity(t, key)))
      .getSingleOrNull();

  /// One row's primary key. [key] is bound, never interpolated (T-01-07).
  Expression<bool> _identity($ConfigItemTableTable t, String key) =>
      t.kind.equals(ConfigKind.preference.wireName) &
      t.id.equals(key) &
      t.scope.equals(scope.wireName);

  /// Every preference row at this scope, narrowed to [allowList] when given.
  /// The allow-list becomes an `IN` of bound placeholders (T-01-07).
  Expression<bool> _scopedPreferences(
      $ConfigItemTableTable t, Set<String>? allowList) {
    final scoped = t.kind.equals(ConfigKind.preference.wireName) &
        t.scope.equals(scope.wireName);
    return allowList == null
        ? scoped
        : scoped & t.id.isIn(allowList.toList(growable: false));
  }

  ConfigItem _itemOf(ConfigItemRow row) => ConfigItem(
        kind: ConfigKind.preference,
        id: row.id,
        scope: scope,
        parentId: row.parentId,
        sortIndex: row.sortIndex,
        payload: row.payload,
      );

  // ---------------------------------------------------------------------
  // Payload
  // ---------------------------------------------------------------------

  Future<Object?> _read(String key) async {
    final row = await _row(key);
    return row == null ? null : _decode(row.payload);
  }

  /// The Dart value [payload] holds, or null if it holds none this store
  /// recognises.
  ///
  /// Null covers three cases that all mean the same thing to a caller —
  /// the payload is not JSON, its tag is one this version does not know, or its
  /// value contradicts its tag. All three read as *absent*, so a row a local
  /// user edited by hand costs a default and never the boot. A tag this store
  /// *does* know but the caller did not ask for is a different matter: the cast
  /// in the getter throws a `TypeError`, which is the contract
  /// `InMemoryPreferences`' `as bool?` already has.
  static Object? _decode(String payload) =>
      decodePreferencePayload(payload);

  /// Whether [id] names one of the store's own rows rather than a preference.
  ///
  /// [importAll] records that it has run as a row of `kind='preference'` with
  /// an underscore-prefixed id, so that a restored backup carries the flag
  /// along with the data it describes. This filter is why that row never
  /// surfaces from [getKeys] or [getAll], is never removed by [clear], and is
  /// never copied anywhere as though it were a setting.
  ///
  /// [containsKey] and [remove] are deliberately *not* filtered: the import has
  /// to be able to ask whether it has run, and a caller that names the marker
  /// outright means it.
  static bool _isInternal(String id) => id.startsWith(_internalIdPrefix);
}

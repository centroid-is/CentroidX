/// The gateway's one writer of the plant's shared configuration.
///
/// ## The gap this closes
///
/// `BackendSharedPreferences` refuses all seven mutators by name, and that
/// refusal is the keystone of the relay's remaining feature gap: a panel
/// connected through a gateway cannot save a report definition, an alarm
/// title, a preference, a page layout or a key mapping, because every one of
/// those is a `config_item` row and the gateway would not write one.
///
/// It is a regression from #465 rather than an omission. Before it the
/// backend served `Preferences.create(db: db)` over the `flutter_preferences`
/// table and relayed writes landed there; #465 moved the plant's
/// configuration onto `config_item` rows and nothing on the backend followed.
/// There is no old code to restore.
///
/// ## One mechanism, because there is one write seam
///
/// Every write of every kind already funnels to [ConfigStore.writeItems] —
/// preferences through `SharedRowPreferences` and the guard, pages through
/// `PageManager`, key mappings through `saveKeyMappings`, undo through
/// `config_undo`. So the gateway needs exactly one writer, and this is it.
/// What varies per caller is attribution and grading, and both of those live
/// above this file.
///
/// ## The mirror is empty, and nothing here reads it
///
/// [ConfigStore] wants a local database because a station's mirror is how it
/// serves the plant's configuration with no network round trip. The gateway
/// has no such need — it holds the authoritative Postgres connection — and
/// must not acquire one, so the local half is [AppDatabase.ephemeral]: an
/// in-memory database that exists only to give the store's post-commit mirror
/// write somewhere to land.
///
/// That makes the store's snapshot permanently empty, which would be a
/// catastrophe for any caller that derived a replace set from it: `writeItems`
/// replaces within kinds, so a save derived from an empty snapshot is a save
/// that **deletes every shared row of those kinds**. Nothing here does that.
/// Every write reads the plant's current rows from Postgres first
/// ([ConfigStore.readRemoteShared]) and hands them over as both the base of
/// the replace set and as `derivedFrom`, which is what the diff and the
/// compare-and-swap are computed against. The empty mirror is then unable to
/// delete or resurrect anything: the worst it can do is a spurious
/// `ConfigConflict`, and it cannot do even that, because the revisions come
/// from the same read.
///
/// ## libsqlite3, and why a missing library must not stop the plant
///
/// Constructing the in-memory mirror dlopens libsqlite3. `docker/backend/
/// Dockerfile` installs `libsqlite3-0` for exactly this reason — but an image
/// built before that line, or a deployment pinned to an older tag, would
/// throw at startup and crash-loop under `restart: unless-stopped` with the
/// plant's acquisition down. So [create] returns **null** on any failure and
/// logs it: a gateway that cannot write configuration goes on serving values,
/// alarms and history, and refuses configuration writes by name exactly as it
/// did before this file existed. Degrading to "writes refused" is a feature;
/// degrading to "backend down" is not.
///
/// ## What this file does NOT decide
///
/// Not permission — the `AccessGroup` gate is the policy decorator's, as
/// everywhere in the relay. Not the audit row — the decorator writes it. Not
/// the action id — the decorator mints it and scopes the call through
/// `ActionScopedWrites`, so the `audit_entry` row and the `config_change`
/// rows for one save carry one id and can be joined. What this file owns is
/// the `config_change.station` and `who` columns, which come from the
/// verified identity and from nowhere a payload can reach (D-11).
library;

import 'dart:async';

import 'package:meta/meta.dart';
import 'package:logger/logger.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

import '../config/config_item.dart';
import '../config/config_store.dart';
import '../config/config_store_errors.dart';
import '../config/preference_payload.dart';
import '../database.dart';
import '../database_drift.dart';

/// Bookkeeping ids are `_`-prefixed and are not preferences.
///
/// A deliberate third copy of `shared_row_preferences.dart`'s and
/// `config_undo.dart`'s constant, for the reason the second one gives: these
/// are separate layers that must agree, and a shared constant would let one
/// of them change the others' behaviour by accident.
const String _internalIdPrefix = '_';

/// Preference ids no relayed caller may delete, whatever group it holds.
///
/// The gateway resolves the whole plant through `key_mappings`, nothing
/// restores it by reconnecting, and the damage does not surface until the
/// next restart — `policy_state_man.dart`'s `reservedPreferenceKeys` refuses
/// an unrestricted `clear` over it for those reasons and names them at
/// length. This is the same list enforced one layer down, where the write
/// actually lands, so a `remove` that slipped past the gate still cannot take
/// the row: a permission answers "may this session", and this answers "may
/// anyone, over a socket".
const Set<String> kRelayUndeletablePreferences = <String>{'key_mappings'};

/// The gateway's shared-configuration writer: one per composition.
///
/// Stateless with respect to identity. Who wrote a row and from which panel
/// is the caller's, passed per call, because one gateway writes on behalf of
/// every connected panel and a writer that held an identity would attribute
/// one panel's save to another.
final class BackendConfigWriter {
  BackendConfigWriter._({
    required ConfigStore store,
    required AppDatabase mirror,
    required Logger logger,
  })  : _store = store,
        _mirror = mirror,
        _logger = logger;

  /// Builds the writer over [remote], or answers null when it cannot.
  ///
  /// Null is a supported deployment and not an error to propagate — see the
  /// library header. The one failure seen in practice is a runtime image with
  /// no libsqlite3, which throws from the mirror's construction.
  ///
  /// [station] is the gateway's own hostname and is used for nothing but the
  /// store's own bookkeeping: every change row this writer lands carries the
  /// *panel's* station, passed per call.
  /// [mirrorFactory] exists so the degradation this method promises is a
  /// tested fact rather than a comment. The failure it stands in for —
  /// libsqlite3 missing from the runtime image — cannot be produced on a
  /// machine that has the library, and it is the one failure that would take
  /// the plant's acquisition down with it.
  static BackendConfigWriter? create({
    required Database remote,
    required String station,
    Logger? logger,
    @visibleForTesting AppDatabase Function()? mirrorFactory,
  }) {
    final log = logger ?? Logger();
    AppDatabase? mirror;
    try {
      mirror = (mirrorFactory ?? AppDatabase.ephemeral)();
      final store = ConfigStore(
        local: mirror,
        stationScope: ConfigScope.forStation(station),
        station: station,
        remote: remote,
        // No sync engine. Reconciling Postgres into a mirror nothing reads is
        // pure cost, and the five-minute sweep would hold a second long-lived
        // transaction against the plant's database for a copy this process
        // discards when it ends.
        startRemoteSync: false,
      );
      return BackendConfigWriter._(
        store: store,
        mirror: mirror,
        logger: log,
      );
    } on Object catch (error, stack) {
      log.e(
        'the relay gateway could not build its configuration writer, so it '
        'will refuse configuration writes by name and serve everything else '
        'normally. The usual cause is a runtime image without libsqlite3 '
        '(docker/backend/Dockerfile installs libsqlite3-0); the mirror this '
        'needs is in-memory and stores nothing, but constructing it loads '
        'that library.',
        error: error,
        stackTrace: stack,
      );
      // Best-effort: a half-built mirror still holds a native handle.
      unawaited(mirror?.close().catchError((Object _) {}));
      return null;
    }
  }

  final ConfigStore _store;
  final AppDatabase _mirror;
  final Logger _logger;

  /// The keys changed by writes made through this gateway.
  ///
  /// The store announces its own commits, so a preference one panel saves
  /// reaches every other panel on this gateway. A preference a **direct
  /// station** saves does not: hearing that would mean running the sync
  /// engine's change-log consumer here, which is the mirror this writer
  /// deliberately does not keep. Named rather than silently absent, because
  /// the difference is invisible from a panel.
  Stream<String> get preferenceKeysChanged => _store.keyMappingChanges
      .expand((diff) => [...diff.added, ...diff.changed, ...diff.removed])
      .where((item) => item.kind == ConfigKind.preference)
      .where((item) => !item.id.startsWith(_internalIdPrefix))
      .map((item) => item.id);

  /// Replaces one shared preference, leaving every other row of that kind
  /// exactly where it was.
  ///
  /// The replace set is the plant's current preference rows with [key]'s
  /// payload swapped in — read from Postgres immediately before the write,
  /// bookkeeping rows included. Leaving a bookkeeping row out of the set
  /// would delete it, and a station that then read a migrated plant as an
  /// unmigrated one would migrate it again.
  Future<void> setPreference(
    String key,
    String type,
    Object value, {
    required String who,
    required String roleName,
    required String station,
  }) async {
    final rows = await _preferenceRows();
    final item = ConfigItem.of(
      kind: ConfigKind.preference,
      id: key,
      value: preferencePayload(type, value),
    );
    await _write(
      wanted: [
        for (final row in rows)
          if (row.id != key) row,
        item,
      ],
      derivedFrom: rows,
      who: who,
      roleName: roleName,
      station: station,
    );
  }

  /// Replaces the plant's shared rows of [kinds] on behalf of a panel.
  ///
  /// The second door. Preferences are graded per key and have their own
  /// seven mutators; pages, assets and key mappings are edited as a whole
  /// set and are graded at one key each, which is the whole reason this is a
  /// separate member rather than a kind parameter on the first one.
  ///
  /// ## The compare-and-swap is the client's, carried as revisions
  ///
  /// [baseRevisions] is `"<kind>/<id>" -> rev` for every row of [kinds] the
  /// client read before it built [wanted]. It is handed to `writeItems` and
  /// compared **inside its transaction**, which refuses unless every row
  /// matches — same ids, same revisions, no more and no fewer.
  ///
  /// Without that check the gateway's fresh read would be the diff's base,
  /// and a row another panel added between the client's read and this write
  /// would be absent from [wanted] and therefore **deleted** — the lost write
  /// the compare-and-swap exists to refuse, reintroduced one layer above it.
  ///
  /// Throws [ConfigConflict] when they differ, which is the same answer a
  /// direct station gets and the one the editor already knows how to show.
  Future<ConfigWriteResult> writeConfigItems({
    required Set<ConfigKind> kinds,
    required List<ConfigItem> wanted,
    required Map<String, int> baseRevisions,
    required String who,
    required String roleName,
    required String station,
    String? reason,
  }) async {
    final stored = await _store.readRemoteShared(kinds);
    return _store.writeItems(
      kinds: kinds,
      wanted: wanted,
      actionId: currentWriteActionId() ?? newActionId(),
      who: who,
      roleName: roleName,
      station: station,
      reason: reason,
      derivedFrom: stored,
      // **Checked inside the transaction, not here.** This read is outside
      // `serialiseWrite` and outside any transaction, so another panel can
      // commit between it and the write — and the per-row guards `writeItems`
      // applies only cover rows this save moves. A row the caller holds
      // unchanged produces no statement, so a base checked here would pass
      // over a row somebody else had already deleted, and the caller would be
      // told it succeeded. Handing the revisions down makes the whole kind
      // set the compare-and-swap unit, which is what the wire's own contract
      // claims.
      baseRevisions: baseRevisions,
    );
  }

  /// Deletes one shared preference row.
  ///
  /// Refuses a reserved id by name whatever the caller holds
  /// ([kRelayUndeletablePreferences]), and ignores a bookkeeping id, which no
  /// caller can name a use for and which is not a preference.
  ///
  /// Removing a row that is not there writes nothing and is not an error: the
  /// caller asked for a state that already holds. It is still checked and
  /// recorded above this layer, because "delete this" is a decision whether or
  /// not it turned out to move a row.
  Future<void> removePreference(
    String key, {
    required String who,
    required String roleName,
    required String station,
  }) async {
    if (kRelayUndeletablePreferences.contains(key)) {
      throw UnsupportedError(
          'preferences.remove("$key") is refused at the gateway, for every '
          'session and every group. The whole plant is resolved through this '
          'row, reconnecting does not bring it back, and its loss does not '
          'show until the next restart — so a deletion that reached here by '
          'any path is a mistake rather than an instruction. Nothing was '
          'removed. Edit the row instead of deleting it.');
    }
    if (key.startsWith(_internalIdPrefix)) return;
    final rows = await _preferenceRows();
    if (!rows.any((row) => row.id == key)) return;
    await _write(
      wanted: [
        for (final row in rows)
          if (row.id != key) row,
      ],
      derivedFrom: rows,
      who: who,
      roleName: roleName,
      station: station,
    );
  }

  /// Deletes the shared preference rows [allowList] names.
  ///
  /// **[allowList] is a removal list, not a keep-list** — the same reading
  /// `SharedRowPreferences.clear` has, said here because inverting it wipes
  /// the plant's configuration. Required, not optional: the unrestricted form
  /// is refused at the policy layer and there is nothing for it to mean here.
  ///
  /// Bookkeeping and reserved ids survive whatever the list says. A clear
  /// naming a reserved id is not refused as a whole, unlike [removePreference]
  /// — the caller named a set rather than that row, and refusing the set
  /// would make a settings page emptying its own section fail over a key it
  /// never meant to include.
  Future<void> clearPreferences(
    Set<String> allowList, {
    required String who,
    required String roleName,
    required String station,
  }) async {
    final rows = await _preferenceRows();
    final doomed = {
      for (final row in rows)
        if (allowList.contains(row.id) &&
            !row.id.startsWith(_internalIdPrefix) &&
            !kRelayUndeletablePreferences.contains(row.id))
          row.id,
    };
    if (doomed.isEmpty) return;
    await _write(
      wanted: [
        for (final row in rows)
          if (!doomed.contains(row.id)) row,
      ],
      derivedFrom: rows,
      who: who,
      roleName: roleName,
      station: station,
    );
  }

  /// The plant's shared preference rows, straight from Postgres.
  Future<List<ConfigItem>> _preferenceRows() =>
      _store.readRemoteShared(const {ConfigKind.preference});

  Future<void> _write({
    required List<ConfigItem> wanted,
    required List<ConfigItem> derivedFrom,
    required String who,
    required String roleName,
    required String station,
  }) async {
    await _store.writeItems(
      kinds: const {ConfigKind.preference},
      wanted: wanted,
      actionId: currentWriteActionId() ?? newActionId(),
      who: who,
      roleName: roleName,
      station: station,
      derivedFrom: derivedFrom,
    );
  }

  /// Releases the mirror. The remote is the composition's and is left open.
  Future<void> close() async {
    try {
      await _store.close();
    } on Object catch (error) {
      _logger.w('the gateway config writer failed to close its store: $error');
    }
    await _mirror.close();
  }
}

/// The zone key the action id travels under.
///
/// A `Zone` rather than a field on the writer, because `json_rpc_2` dispatches
/// requests without awaiting between frames and this value must survive the
/// awaits a write makes — see `ActionScopedWrites`, which states the race a
/// field loses.
const Object _actionIdZoneKey = #centroidx.config.actionId;

/// The action id the current write is attributed to, or null outside one.
String? currentWriteActionId() => Zone.current[_actionIdZoneKey] as String?;

/// Runs [body] with [actionId] as the action every configuration change row
/// it lands is attributed to.
Future<T> runUnderWriteAction<T>(
        String actionId, Future<T> Function() body) =>
    runZoned(body, zoneValues: {_actionIdZoneKey: actionId});

/// The relay's preference family for one verified identity.
///
/// Reads are the composition's — they hold no identity and one instance is
/// correct for every session. Writes are this identity's, attributed to the
/// account the server verified and the station it resolved, never to anything
/// a frame contained.
///
/// [relay.ActionScopedWrites] is implemented rather than inherited: the policy
/// decorator type-tests for it and scopes each graded call, so the
/// `audit_entry` row it writes and the `config_change` rows this writer lands
/// carry one action id.
final class RelayIdentityPreferences
    implements relay.PreferencesApi, relay.ActionScopedWrites {
  RelayIdentityPreferences({
    required relay.PreferencesApi reads,
    required BackendConfigWriter? writer,
    required AccessSession Function() session,
    required String station,
  })  : _reads = reads,
        _writer = writer,
        _session = session,
        _station = station;

  final relay.PreferencesApi _reads;
  final BackendConfigWriter? _writer;
  final AccessSession Function() _session;
  final String _station;

  @override
  Future<T> underAction<T>(String actionId, Future<T> Function() write) =>
      runUnderWriteAction(actionId, write);

  BackendConfigWriter _require(String member) =>
      _writer ??
      (throw UnsupportedError(
          'preferences.$member cannot be served: this gateway has no '
          "configuration writer, so it cannot author the plant's shared "
          'settings. Nothing was written. The writer is built at composition '
          'and the one thing known to stop it is a runtime image without '
          'libsqlite3 — the backend log carries the reason it failed, once, '
          'at startup.'));

  String get _who => _session().user?.username ?? 'anonymous';
  String get _roleName => _session().roleName;

  /// `async` on purpose, here and on the three members below it. [_require]
  /// throws, and an expression body would make that a **synchronous** throw
  /// out of a `Future`-returning method — so a caller that held the future
  /// and awaited it later would never see it, and a caller that wrapped the
  /// call in `try` would see it in a different place from every other
  /// failure this family can produce. A refusal is an outcome of the call,
  /// and outcomes of a `Future` method belong in the future.
  Future<void> _set(String member, String key, String type, Object value) async =>
      _require(member).setPreference(key, type, value,
          who: _who, roleName: _roleName, station: _station);

  // ------------------------------------------------------------------ writes

  @override
  Future<void> setBool(String key, bool value) =>
      _set('setBool', key, kPrefBoolType, value);

  @override
  Future<void> setInt(String key, int value) =>
      _set('setInt', key, kPrefIntType, value);

  @override
  Future<void> setDouble(String key, double value) =>
      _set('setDouble', key, kPrefDoubleType, value);

  @override
  Future<void> setString(String key, String value) =>
      _set('setString', key, kPrefStringType, value);

  @override
  Future<void> setStringList(String key, List<String> value) =>
      _set('setStringList', key, kPrefStringListType, value);

  @override
  Future<void> remove(String key) async => _require('remove')
      .removePreference(key, who: _who, roleName: _roleName, station: _station);

  /// The unrestricted form is refused at the policy layer and cannot arrive
  /// here from the wire. It is refused again rather than interpreted, because
  /// a default that meant "everything" would be one frame from wiping the
  /// plant if the gate above ever moved.
  @override
  Future<void> clear({Set<String>? allowList}) async {
    final writer = _require('clear');
    if (allowList == null) {
      throw UnsupportedError(
          'preferences.clear with no allowList is not served by the gateway: '
          "it would remove every shared setting the plant has. Nothing was "
          'removed. Name the keys to clear in "allowList".');
    }
    return writer.clearPreferences(allowList,
        who: _who, roleName: _roleName, station: _station);
  }

  // ------------------------------------------------------------------- reads

  @override
  Future<Set<String>> getKeys({Set<String>? allowList}) =>
      _reads.getKeys(allowList: allowList);

  @override
  Future<Map<String, Object?>> getAll({Set<String>? allowList}) =>
      _reads.getAll(allowList: allowList);

  @override
  Future<bool?> getBool(String key) => _reads.getBool(key);

  @override
  Future<int?> getInt(String key) => _reads.getInt(key);

  @override
  Future<double?> getDouble(String key) => _reads.getDouble(key);

  @override
  Future<String?> getString(String key) => _reads.getString(key);

  @override
  Future<List<String>?> getStringList(String key) => _reads.getStringList(key);

  @override
  Future<bool> containsKey(String key) => _reads.containsKey(key);

  StreamController<String>? _merged;
  final List<StreamSubscription<String>> _sources = [];

  /// Both sources, one stream: whatever the composition's reads announce, and
  /// the keys this gateway's own writes moved. A key heard twice costs a
  /// coalescing listener nothing; a key heard never is a settings page that
  /// does not refresh.
  ///
  /// Listener-gated — nothing is subscribed until somebody listens and
  /// everything is released on cancel — so a session that never watches
  /// preferences holds no upstream subscription. An error on either source is
  /// swallowed rather than forwarded: a change nobody can name is lost, which
  /// is honest, and tearing down a session that is otherwise serving the
  /// plant over it is not.
  @override
  Stream<String> get onPreferencesChanged {
    final writer = _writer;
    if (writer == null) return _reads.onPreferencesChanged;
    return (_merged ??= StreamController<String>.broadcast(
      onListen: () {
        for (final source in [
          _reads.onPreferencesChanged,
          writer.preferenceKeysChanged,
        ]) {
          _sources.add(source.listen(
            (key) => _merged?.add(key),
            onError: (Object _) {},
          ));
        }
      },
      onCancel: () async {
        final open = [..._sources];
        _sources.clear();
        for (final subscription in open) {
          await subscription.cancel();
        }
      },
    ))
        .stream;
  }
}

/// The relay's configuration-row family for one verified identity.
///
/// Reads are the composition's — three of them, holding no identity, one
/// instance correct for every session. The write is this identity's, and its
/// `config_change` rows carry the account the server verified and the station
/// it resolved.
///
/// Sibling of [RelayIdentityPreferences] in every respect, including
/// `ActionScopedWrites`: the policy decorator mints the action id, so the
/// audit row it writes and the change rows this lands join.
final class RelayIdentityConfigItems
    implements relay.ConfigItemsApi, relay.ActionScopedWrites {
  RelayIdentityConfigItems({
    required relay.ConfigItemsApi reads,
    required BackendConfigWriter? writer,
    required AccessSession Function() session,
    required String station,
  })  : _reads = reads,
        _writer = writer,
        _session = session,
        _station = station;

  final relay.ConfigItemsApi _reads;
  final BackendConfigWriter? _writer;
  final AccessSession Function() _session;
  final String _station;

  @override
  Future<T> underAction<T>(String actionId, Future<T> Function() write) =>
      runUnderWriteAction(actionId, write);

  @override
  Future<List<relay.ConfigItemRecord>> items(String kind) =>
      _reads.items(kind);

  @override
  Future<relay.ConfigItemsFingerprint> fingerprint(List<String> kinds) =>
      _reads.fingerprint(kinds);

  @override
  Future<relay.ConfigItemsReplaceResult> replace(
      relay.ConfigItemsReplaceRequest request) async {
    final writer = _writer;
    if (writer == null) {
      throw UnsupportedError(
          'configItems.replace cannot be served: this gateway has no '
          "configuration writer, so it cannot author the plant's pages or "
          'key mappings. Nothing was written. The writer is built at '
          'composition and the one thing known to stop it is a runtime image '
          'without libsqlite3 — the backend log carries the reason it '
          'failed, once, at startup.');
    }
    // The kind set was already checked by the policy decorator, which derives
    // the grading key from it. Checked again here rather than trusted,
    // because this class is reachable from a composition that wired a
    // different gate, and a kind this method did not expect would be replaced
    // wholesale against a `wanted` list built for something else.
    final key = relay.configWriteKeyFor(request.kinds);
    if (key == null) {
      throw ArgumentError.value(
          (request.kinds.toList()..sort()).join(', '),
          'kinds',
          'is not a set this family writes. It writes exactly '
              '${relay.configWriteKeyByKindSet.keys.join(' and ')}; a '
              'preference is graded under its own key and has its own door.');
    }
    final kinds = <ConfigKind>{};
    for (final name in request.kinds) {
      final kind = ConfigKind.byWireName(name);
      if (kind == null) {
        throw ArgumentError.value(name, 'kinds',
            'is not a configuration kind this build knows');
      }
      kinds.add(kind);
    }
    final session = _session();
    final result = await writer.writeConfigItems(
      kinds: kinds,
      wanted: [
        for (final row in request.wanted)
          ConfigItem(
            kind: ConfigKind.byWireName(row.kind) ??
                (throw ArgumentError.value(row.kind, 'wanted',
                    'holds a row of a kind this build does not know')),
            id: row.id,
            scope: ConfigScope.shared,
            parentId: row.parentId,
            sortIndex: row.sortIndex,
            payload: row.payload,
          ),
      ],
      baseRevisions: request.baseRevisions,
      who: session.user?.username ?? 'anonymous',
      roleName: session.roleName,
      station: _station,
      reason: request.reason,
    );
    return relay.ConfigItemsReplaceResult(
      added: result.diff.added.length,
      changed: result.diff.changed.length,
      removed: result.diff.removed.length,
      actionId: result.actionId,
    );
  }
}

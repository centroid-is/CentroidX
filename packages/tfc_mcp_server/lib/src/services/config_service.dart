import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:tfc_dart/core/config/config_item.dart'
    show ConfigItem, ConfigKind, ConfigScope;
import 'package:tfc_dart/core/config/key_mapping_codec.dart'
    show keyMappingBlobOf;
import 'package:tfc_dart/tfc_dart_core.dart'
    show
        ConfigInconsistency,
        McpDatabase,
        checkConfigConsistency,
        fuzzyFilter,
        pagesJsonOf,
        readSharedPageLayout,
        readSharedPreferencePayload;

import '../cache/ttl_cache.dart';
import 'plc_code_service.dart';
import 'sql_dialect.dart';

/// Service for reading system configuration from the database.
///
/// Provides methods to query pages, assets, key mappings, and alarm
/// definitions. All of it is stored as `config_item` rows: pages and their
/// assets as one row each, alarms as the `alarm_man_config` preference row,
/// key mappings as one row per key. The `flutter_preferences` blobs those
/// three used to live in are gone from this file — reading them after the
/// cutover would serve a frozen copy of the plant to an operator who cannot
/// tell it is frozen.
///
/// The `alarm` table is *not* one of the sources. It exists in the schema but
/// nothing writes it -- AlarmMan keeps every alarm in the alarm_man_config
/// preference -- so reading it returned an empty result on every deployment.
///
/// All list methods enforce a [limit] parameter to prevent context window
/// overflow when used by the AI copilot.
///
/// Implements [KeyMappingLookup] so it can be used by [PlcCodeService]
/// for OPC UA identifier correlation.
///
/// Accepts [McpDatabase] (not ServerDatabase) so it works with both
/// AppDatabase (Flutter in-process) and ServerDatabase (standalone binary).
/// [McpDatabase] is a `GeneratedDatabase`, which is all the readers in
/// `page_rows.dart` need: drift's generated table classes take their database
/// as a constructor argument, so `config_item` attaches to a schema that does
/// not declare it and the reads are ordinary builders. No raw SQL, and
/// therefore no `?`-versus-`$N` branch to keep in step with the two backends.
///
/// The one query still written as SQL is the key-mappings read, which goes
/// through [adaptSql] for that translation — see [_getKeyMappingsJson].
class ConfigService implements KeyMappingLookup {
  /// Creates a [ConfigService] backed by the given [McpDatabase].
  ConfigService(this._db) : _isPostgres = isPostgresDb(_db);

  final McpDatabase _db;

  /// Whether the database uses PostgreSQL dialect.
  final bool _isPostgres;

  /// Cache for preference JSON blobs (keyed by preference key).
  final _prefCache = TtlCache<String, Map<String, dynamic>?>(
    defaultTtl: Duration(minutes: 5),
    maxEntries: 50,
  );

  /// Cache for alarm definition listings (keyed by filter:limit).
  final _alarmDefCache = TtlCache<String, List<Map<String, dynamic>>>(
    defaultTtl: Duration(minutes: 5),
    maxEntries: 100,
  );

  /// Cache for individual alarm configs (keyed by alarm UID).
  final _alarmConfigCache = TtlCache<String, Map<String, dynamic>?>(
    defaultTtl: Duration(minutes: 5),
    maxEntries: 100,
  );

  /// Invalidate all config caches.
  void invalidateCache() {
    _prefCache.clear();
    _alarmDefCache.clear();
    _alarmConfigCache.clear();
  }

  /// Adapts SQL with `?` placeholders to `$N` for PostgreSQL.
  String _sql(String query) => adaptSql(query, isPostgres: _isPostgres);

  /// The shared preference row named [key], decoded.
  ///
  /// Results are cached with a 5-minute TTL to avoid repeated DB round-trips.
  ///
  /// Null when there is no such row. Until plan 04-11 migrates the
  /// preferences that is *every* key, and it is the correct degraded answer
  /// rather than an error: a standalone server can open a database no station
  /// has migrated yet, and a caller that treats null as "not configured" is
  /// right on both sides of the cutover. It is the same answer this service
  /// gave for a missing `flutter_preferences` key.
  Future<Map<String, dynamic>?> _preferenceJson(String key) async {
    try {
      return await _prefCache.getOrCompute(
          key, () => readSharedPreferencePayload(_db, key));
    } catch (_) {
      // `config_item` is created by tfc_dart's migration. A server pointed
      // at a database that has not run it must still answer — but the
      // failure is **not cached**: it used to be, and a connection reset
      // during one read then answered "no such preference" for the whole
      // five-minute TTL, which for `alarm_man_config` is a plant with no
      // alarms and for the key mappings an empty key universe handed to the
      // access-template tools. The cache holds answers, not outages.
      return null;
    }
  }

  /// The whole shared layout, in the shape `page_editor_data` held: one entry
  /// per page keyed by its path, each holding its own JSON with its `assets`
  /// list in place.
  ///
  /// **The shape is produced by `pagesJsonOf`, not assembled here.** The rule
  /// it encodes — an asset belongs to the page whose id is its `parent_id`,
  /// paint order is `sort_index`, a path-less page gets a slug — is the wire
  /// format, and the editor reassembles the same rows with the same function.
  /// A second reassembly in this package would be a second definition of that
  /// format, and the way two definitions diverge is quietly: this one answers
  /// `get_asset_detail`, so a subtly different one describes a plant that is
  /// not the plant.
  ///
  /// Empty while the migration has not run, for the same reason
  /// [_preferenceJson] is null then.
  Future<Map<String, dynamic>> _pagesJson() async {
    try {
      final cached = await _prefCache.getOrCompute('page_editor_data#rows',
          () async => pagesJsonOf(await readSharedPageLayout(_db)));
      return cached ?? const {};
    } catch (_) {
      // Not cached, for the reason [_preferenceJson] gives.
      return const {};
    }
  }

  /// The key mappings, from `config_item` rows.
  ///
  /// Shaped `{'nodes': {key: entry}}`, which is what the blob held, because
  /// that is [listKeyMappings]'s wire contract and the storage underneath it
  /// is not the caller's business.
  ///
  /// **The shape is produced by [keyMappingBlobOf], not assembled here.** A
  /// map built by hand would be a second definition of the blob, and the way
  /// two definitions diverge is quietly: this one feeds `access_template_tools`
  /// "the whole key universe", so a malformed or subtly different key set
  /// becomes access rules written against wiring that does not match the
  /// plant. Going through the codec also round-trips every payload through
  /// `KeyMappingEntry.fromJson`, which validates them for free.
  ///
  /// **Why this one is still raw SQL** when the pages read beside it is drift
  /// builders: not because it has to be. `readSharedKeyMappingItems` would do
  /// it, and `$ConfigItemTableTable` attaches to this service's
  /// [McpDatabase] exactly as it does in `page_rows.dart` — the schema
  /// argument this comment used to make was wrong. What keeps the query here
  /// is the import above it: `key_mapping_codec.dart` reaches
  /// `state_man.dart` and so links open62541 into this binary, which is
  /// deferred defect D-3, and `key_mapping_rows.dart` imports
  /// `database_drift.dart` and would pull the same library a second way.
  /// Moving the read without moving the codec would deepen D-3 rather than
  /// undo it, so both stay put until D-3 is fixed properly.
  ///
  /// A missing `config_item` reads as no mappings, not as an error: a
  /// standalone server can open a database tfc_dart has not migrated yet, and
  /// failing here would take out `list_key_mappings` and every access template
  /// tool built on it in order to report a table that is about to exist. The
  /// blob fallback that used to sit here is gone with the blob: once the rows
  /// exist the blob is a frozen copy, and an access template written against
  /// a key set that stopped being updated is a rule that does not cover the
  /// wiring it was meant to cover.
  Future<Map<String, dynamic>?> _getKeyMappingsJson() {
    return _prefCache.getOrCompute('key_mappings#rows', () async {
      final List<QueryRow> rows;
      try {
        rows = await _db.customSelect(
          _sql('SELECT id, payload FROM config_item '
              'WHERE kind = ? AND scope = ? ORDER BY id'),
          variables: [
            Variable.withString(ConfigKind.keyMapping.wireName),
            Variable.withString(ConfigScope.shared.wireName),
          ],
        ).get();
      } catch (_) {
        return null;
      }
      if (rows.isEmpty) return null;

      final items = [
        for (final row in rows)
          ConfigItem(
            kind: ConfigKind.keyMapping,
            id: row.read<String>('id'),
            payload: row.read<String>('payload'),
          ),
      ];
      return jsonDecode(keyMappingBlobOf(items)) as Map<String, dynamic>;
    });
  }

  /// Returns a summary list of pages from page_editor_data.
  ///
  /// Each entry contains `key` and `title` fields. Results are limited
  /// to [limit] entries (default 50).
  Future<List<Map<String, dynamic>>> listPages({int limit = 50}) async {
    final data = await _pagesJson();

    final pages = <Map<String, dynamic>>[];
    for (final entry in data.entries) {
      final page = entry.value as Map<String, dynamic>;
      pages.add({
        'key': page['key'] ?? entry.key,
        'title': page['title'] ?? entry.key,
      });
    }

    return pages.take(limit).toList();
  }

  /// Returns a summary list of assets from page_editor_data.
  ///
  /// Each page is treated as an asset. Each entry contains `key` and
  /// `title` fields. Results are limited to [limit] entries (default 50).
  Future<List<Map<String, dynamic>>> listAssets({int limit = 50}) async {
    final data = await _pagesJson();

    final assets = <Map<String, dynamic>>[];
    for (final entry in data.entries) {
      final page = entry.value as Map<String, dynamic>;
      assets.add({
        'key': page['key'] ?? entry.key,
        'title': page['title'] ?? entry.key,
      });
    }

    return assets.take(limit).toList();
  }

  /// Returns the full page configuration for the given [pageKey].
  ///
  /// Returns `null` if no page with the given key exists. This provides
  /// the detailed view in the progressive discovery pattern (Level 2).
  Future<Map<String, dynamic>?> getAssetDetail(String pageKey) async {
    final data = await _pagesJson();

    if (data.containsKey(pageKey)) {
      return data[pageKey] as Map<String, dynamic>;
    }
    return null;
  }

  /// Returns key-to-protocol-node mappings from the key_mappings preference.
  ///
  /// Handles OPC UA (`opcua_node`), Modbus (`modbus_node`), and M2400
  /// (`m2400_node`) entries. Each result always contains a `key` field and
  /// a `protocol` field indicating the source protocol. OPC UA entries
  /// additionally include `namespace` and `identifier`; Modbus entries
  /// include `register_type`, `address`, `data_type`, and `poll_group`;
  /// M2400 entries include `record_type` and optionally `field` and
  /// `server_alias`.
  ///
  /// A single key may appear multiple times if it has mappings for more
  /// than one protocol.
  ///
  /// Supports optional fuzzy [filter] on key names. Results are limited
  /// to [limit] entries (default 50).
  @override
  Future<List<Map<String, dynamic>>> listKeyMappings({
    String? filter,
    int limit = 50,
  }) async {
    final data = await _getKeyMappingsJson();
    if (data == null) return [];

    final nodes = data['nodes'] as Map<String, dynamic>?;
    if (nodes == null) return [];

    var mappings = <Map<String, dynamic>>[];
    for (final entry in nodes.entries) {
      final config = entry.value as Map<String, dynamic>;
      var hasMapping = false;

      // Bit mask/shift (applies to any protocol)
      final bitMask = config['bit_mask'] as int?;
      final bitShift = config['bit_shift'] as int?;

      // OPC UA
      final opcuaNode = config['opcua_node'] as Map<String, dynamic>?;
      if (opcuaNode != null) {
        hasMapping = true;
        final m = <String, dynamic>{
          'key': entry.key,
          'protocol': 'opcua',
          'namespace': opcuaNode['namespace'] as int,
          'identifier': opcuaNode['identifier'] as String,
        };
        if (opcuaNode['server_alias'] != null) {
          m['server_alias'] = opcuaNode['server_alias'];
        }
        if (bitMask != null) m['bit_mask'] = bitMask;
        if (bitShift != null) m['bit_shift'] = bitShift;
        mappings.add(m);
      }

      // Modbus
      final modbusNode = config['modbus_node'] as Map<String, dynamic>?;
      if (modbusNode != null) {
        hasMapping = true;
        final m = <String, dynamic>{
          'key': entry.key,
          'protocol': 'modbus',
          'register_type': modbusNode['register_type'] as String?,
          'address': modbusNode['address'] as int?,
          'data_type': modbusNode['data_type'] as String?,
          'poll_group': modbusNode['poll_group'] as String?,
        };
        if (modbusNode['server_alias'] != null) {
          m['server_alias'] = modbusNode['server_alias'];
        }
        mappings.add(m);
      }

      // M2400
      final m2400Node = config['m2400_node'] as Map<String, dynamic>?;
      if (m2400Node != null) {
        hasMapping = true;
        final m = <String, dynamic>{
          'key': entry.key,
          'protocol': 'm2400',
          'record_type': m2400Node['record_type'] as String?,
        };
        if (m2400Node['field'] != null) {
          m['field'] = m2400Node['field'];
        }
        if (m2400Node['server_alias'] != null) {
          m['server_alias'] = m2400Node['server_alias'];
        }
        mappings.add(m);
      }

      // Skip entries with no recognized protocol mapping
      if (!hasMapping) continue;
    }

    if (filter != null && filter.isNotEmpty) {
      mappings = fuzzyFilter(
        mappings,
        filter,
        [(m) => m['key'] as String],
      );
    }

    return mappings.take(limit).toList();
  }

  /// Pulls the alarm list out of a decoded `alarm_man_config` preference.
  ///
  /// That preference is what AlarmMan loads its config from and writes back
  /// to, so it is the only place the running alarms exist. Shape:
  /// `{"alarms": [{uid, key, title, description, rules: [...]}]}`.
  List<Map<String, dynamic>> _alarmsOf(Map<String, dynamic>? data) {
    final alarms = data?['alarms'];
    if (alarms is! List) return const [];
    return alarms.whereType<Map<String, dynamic>>().toList();
  }

  /// Returns alarm definition summaries.
  ///
  /// Each entry contains `uid`, `title`, and `description` fields.
  /// Supports optional fuzzy [filter] on title and description.
  /// Results are limited to [limit] entries (default 50).
  Future<List<Map<String, dynamic>>> listAlarmDefinitions({
    String? filter,
    int limit = 50,
  }) {
    final cacheKey = '${filter ?? ''}:$limit';
    return _alarmDefCache.getOrCompute(cacheKey, () async {
      final data = await _preferenceJson('alarm_man_config');

      var alarms = _alarmsOf(data)
          .map((a) => {
                'uid': a['uid'] as String? ?? '',
                'title': a['title'] as String? ?? '',
                'description': a['description'] as String? ?? '',
              })
          .toList();

      if (filter != null && filter.isNotEmpty) {
        alarms = fuzzyFilter(
          alarms,
          filter,
          [
            (a) => a['title'] as String,
            (a) => a['description'] as String,
          ],
        );
      }

      return alarms.take(limit).toList();
    });
  }

  /// Returns the full alarm configuration for the given [uid].
  ///
  /// Returns a map with `uid`, `key`, `title`, `description`, and `rules`
  /// (a List in AlarmRule.toJson() shape). Returns `null` if no alarm with
  /// the given UID exists.
  ///
  /// Pass [refresh] to bypass the 5-minute TTL and re-read the row from the
  /// database. `update_alarm` merges the fields it was *not* given over this
  /// map, so whatever it reads here is written back verbatim -- a cached copy
  /// from before the last accepted edit silently reverts every field the
  /// caller omitted. The cache is worth keeping for the read-only tools that
  /// only display an alarm; it is not worth one round trip on the path that
  /// decides what survives a write. [invalidateCache] exists but nothing
  /// calls it, so without this the window is the full five minutes.
  Future<Map<String, dynamic>?> getAlarmConfig(String uid,
      {bool refresh = false}) {
    if (refresh) {
      // Both layers: the per-uid projection is computed from the shared
      // `alarm_man_config` blob, so dropping only the projection would
      // recompute it from the same stale blob.
      _alarmConfigCache.invalidate(uid);
      _prefCache.invalidate('alarm_man_config');
    }
    return _alarmConfigCache.getOrCompute(uid, () async {
      final data = await _preferenceJson('alarm_man_config');
      final alarm =
          _alarmsOf(data).where((a) => a['uid'] == uid).firstOrNull;
      if (alarm == null) return null;

      return {
        'uid': uid,
        'key': alarm['key'] as String?,
        'title': alarm['title'] as String? ?? '',
        'description': alarm['description'] as String? ?? '',
        'rules': alarm['rules'] is List ? alarm['rules'] as List : const [],
        // Where the alarm sits in the alarm tree. Projected because an
        // update proposal rebuilds the alarm from this map -- leaving these
        // out would quietly move the alarm back to the root the first time
        // anyone edited its title.
        'group': alarm['group'] is List
            ? (alarm['group'] as List).whereType<String>().toList()
            : const <String>[],
        'bindToGroup': alarm['bindToGroup'] as bool? ?? false,
        // Same argument as the group: an omitted field is written back by
        // the next update, and a missing countsAsStop means true.
        'countsAsStop': alarm['countsAsStop'] as bool? ?? true,
      };
    });
  }

  /// Returns the page assets that name [uid] in their `alarm_uids` list.
  ///
  /// Alarm beacons ([AlarmVisibilityConfig]) bind to alarms by uid. Deleting
  /// an alarm a beacon watches leaves the beacon bound to nothing -- it stays
  /// on the page and never lights again -- so a delete has to be able to say
  /// what it would orphan before the operator agrees to it.
  ///
  /// Each entry has `page` (the page_editor_data key) and, when the asset
  /// carries one, `asset` (its type name) and `label` (its caption).
  ///
  /// An asset with an *empty* `alarm_uids` watches every alarm rather than a
  /// named one, so it is not reported: nothing about it breaks when one alarm
  /// goes away.
  Future<List<Map<String, dynamic>>> findAlarmReferences(String uid) async {
    final data = await _pagesJson();

    final refs = <Map<String, dynamic>>[];

    // Walked rather than indexed: assets nest (groups hold children), and a
    // reference one level down orphans a beacon just as thoroughly.
    void visit(Object? node, String pageKey) {
      if (node is List) {
        for (final child in node) {
          visit(child, pageKey);
        }
        return;
      }
      if (node is! Map<String, dynamic>) return;

      final uids = node['alarm_uids'];
      if (uids is List && uids.contains(uid)) {
        refs.add({
          'page': pageKey,
          if (node['asset_name'] is String) 'asset': node['asset_name'],
          if (node['text'] is String) 'label': node['text'],
        });
      }

      for (final value in node.values) {
        visit(value, pageKey);
      }
    }

    for (final entry in data.entries) {
      visit(entry.value, entry.key);
    }

    return refs;
  }

  /// Every way this database's configuration contradicts its own history.
  ///
  /// SC-6's production arm. The same function CI runs against a throwaway
  /// Postgres, pointed at whatever database this server was opened on — which
  /// is the whole point of it existing here: the corruptions it looks for (a
  /// row written without a change row, a `parent_id` orphaned by a rename)
  /// happen on a live plant over months, and a check that only ever ran in CI
  /// would be proving the invariant over rows the test had just written
  /// itself.
  ///
  /// **Errors are not swallowed here**, unlike every other read in this
  /// class. Those answer "nothing configured" when `config_item` is missing,
  /// because a standalone server can open a database tfc_dart has not
  /// migrated yet and taking out `list_pages` to report a table that is about
  /// to exist helps nobody. A *check* cannot do that: "I read no rows" and
  /// "the rows are consistent" are the same empty list, and a tool that
  /// reported the first as the second would be worse than no tool at all. The
  /// caller catches and says which one it is.
  Future<List<ConfigInconsistency>> checkConsistency() =>
      checkConfigConsistency(_db);
}

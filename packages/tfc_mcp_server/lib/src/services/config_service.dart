import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:tfc_dart/core/config/config_item.dart'
    show ConfigItem, ConfigKind, ConfigScope;
import 'package:tfc_dart/core/config/key_mapping_codec.dart'
    show keyMappingBlobOf;
import 'package:tfc_dart/tfc_dart_core.dart' show McpDatabase, fuzzyFilter;

import '../cache/ttl_cache.dart';
import 'plc_code_service.dart';
import 'sql_dialect.dart';

/// Service for reading system configuration from the database.
///
/// Provides methods to query pages, assets, key mappings, and alarm
/// definitions. All of it is stored as JSON blobs in the flutter_preferences
/// table: page_editor_data, key_mappings and alarm_man_config.
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
/// Shared tables (flutter_preferences, alarm) are queried via raw SQL since
/// AppDatabase and ServerDatabase define different row classes for the same
/// physical tables.
///
/// SQL queries use [adaptSql] to translate `?` placeholders to `$N` when
/// running against PostgreSQL, since drift's `customSelect` passes raw SQL
/// verbatim to the database engine without placeholder translation.
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

  /// Reads a JSON preference value from the flutter_preferences table.
  ///
  /// Results are cached with a 5-minute TTL to avoid repeated DB round-trips.
  /// ConfigService queries via raw SQL ([customSelect]), completely bypassing
  /// the Flutter InMemoryPreferences layer, so this cache is valuable in both
  /// in-process and subprocess modes.
  ///
  /// Returns the decoded JSON value, or `null` if the key does not exist
  /// or the value is null/empty.
  ///
  /// Uses raw SQL via [customSelect] because flutter_preferences is a shared
  /// table with different row classes in AppDatabase vs ServerDatabase.
  Future<Map<String, dynamic>?> _getPreferenceJson(String key) {
    return _prefCache.getOrCompute(key, () async {
      final rows = await _db.customSelect(
        _sql('SELECT value FROM flutter_preferences WHERE key = ?'),
        variables: [Variable.withString(key)],
      ).get();
      if (rows.isEmpty) return null;
      final value = rows.first.readNullable<String>('value');
      if (value == null || value.isEmpty) return null;
      return jsonDecode(value) as Map<String, dynamic>;
    });
  }

  /// The key mappings, from `config_item` rows when there are any and from
  /// the legacy `flutter_preferences.key_mappings` blob until then.
  ///
  /// Shaped exactly like [_getPreferenceJson]'s result for that key —
  /// `{'nodes': {key: entry}}` — so [listKeyMappings] does not care which side
  /// it came from.
  ///
  /// **The shape is produced by [keyMappingBlobOf], not assembled here.** A
  /// map built by hand would be a second definition of the blob, and the way
  /// two definitions diverge is quietly: this one feeds `access_template_tools`
  /// "the whole key universe", so a malformed or subtly different key set
  /// becomes access rules written against wiring that does not match the
  /// plant. Going through the codec also round-trips every payload through
  /// `KeyMappingEntry.fromJson`, which validates them for free.
  ///
  /// **Why raw SQL rather than the drift builder** `readSharedKeyMappingItems`
  /// uses: this service holds an [McpDatabase], which is `ServerDatabase` in
  /// the standalone binary, and `config_item` is not in that schema — the same
  /// arrangement `flutter_preferences` has. Every query in this file is raw
  /// SQL through [_sql] for that reason, and this one follows it. The codec
  /// import is a value-layer import and not a drift-table one, so it does not
  /// cross that boundary.
  ///
  /// A missing `config_item` is the fallback case too, not an error: a
  /// standalone server can open a database tfc_dart has not migrated yet, and
  /// failing here would take out `list_key_mappings` and every access template
  /// tool built on it in order to report a table that is about to exist.
  ///
  /// The fallback retires itself the moment one row exists, and it is deleted
  /// with the blob in Phase 4.
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
        return _getPreferenceJson('key_mappings');
      }
      if (rows.isEmpty) return _getPreferenceJson('key_mappings');

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
    final data = await _getPreferenceJson('page_editor_data');
    if (data == null) return [];

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
    final data = await _getPreferenceJson('page_editor_data');
    if (data == null) return [];

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
    final data = await _getPreferenceJson('page_editor_data');
    if (data == null) return null;

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
      final data = await _getPreferenceJson('alarm_man_config');

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
      final data = await _getPreferenceJson('alarm_man_config');
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
    final data = await _getPreferenceJson('page_editor_data');
    if (data == null) return const [];

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
}

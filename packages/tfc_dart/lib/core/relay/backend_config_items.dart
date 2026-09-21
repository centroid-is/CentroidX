/// The backend's read path onto the plant's `config_item` rows, for the relay.
///
/// The fifth access family (`ConfigItemsApi`, in the protocol package — its
/// library doc holds the why). This is the row reader behind it: shared rows
/// of one kind at a time, straight off the table through the same helpers
/// `bin/main.dart` and `BackendSharedPreferences` already read with, so a
/// browser reassembles exactly the rows a station's mirror would have held.
///
/// ## Not a `ConfigStore`
///
/// For the reason `backend_shared_preferences.dart` gives: a store needs a
/// device-local mirror, a session, an audit sink and a station name, and the
/// backend has none of those and must not grow them. A read-only family
/// needs a database and a query.
///
/// ## Reads only
///
/// No write, and the interface has none to implement. The boundary is stated
/// in the protocol's library doc; nothing here softens it.
///
/// ## Bounded, and refused by name past the bound
///
/// One kind per call keeps the largest family on the measured plant (~400 KB
/// of key mappings) well inside the gateway's 1 MiB frame. A plant whose one
/// family outgrows [maxBytes] is refused with a `ResultTooLarge` that names
/// the limit and what was measured — never let through to be reported as a
/// backpressure disconnect, the misread `result_too_large.dart` exists to
/// prevent.
library;

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

import '../config/config_item.dart';
import '../config/key_mapping_rows.dart';
import '../database_drift.dart' show AppDatabase;

/// The most payload one `configItems.items` answer may carry.
///
/// Below the gateway's `maxFrameBytes` (1 MiB) with room for the JSON
/// envelope around each row; above the largest family the plant this was
/// measured on holds by a factor of two.
const int defaultMaxConfigItemBytes = 768 * 1024;

/// [relay.ConfigItemsApi] over the backend's `config_item` table.
final class BackendConfigItems implements relay.ConfigItemsApi {
  BackendConfigItems({
    required AppDatabase? database,
    int maxBytes = defaultMaxConfigItemBytes,
  })  : _db = database,
        _maxBytes = maxBytes;

  final AppDatabase? _db;
  final int _maxBytes;

  AppDatabase _require(String member) {
    final db = _db;
    if (db == null) {
      throw StateError(
          'BackendConfigItems.$member has no database to read: the plant\'s '
          'configuration rows live in Postgres, and this backend was composed '
          'without one. A browser served an empty page set would show a '
          'plant with no pages, which is not what an unreachable database '
          'means.');
    }
    return db;
  }

  static ConfigKind _kindOf(String wireName) {
    final kind = ConfigKind.byWireName(wireName);
    if (kind == null || !relay.configItemKinds.contains(wireName)) {
      throw ArgumentError.value(wireName, 'kind',
          'not a configuration kind this backend serves; one of '
              '${relay.configItemKinds.join(', ')}');
    }
    return kind;
  }

  @override
  Future<List<relay.ConfigItemRecord>> items(String kind) async {
    final items = await readSharedConfigItemsOfKind(_require('items'), _kindOf(kind));
    var bytes = 0;
    final records = <relay.ConfigItemRecord>[];
    for (final item in items) {
      bytes += item.payload.length + item.id.length;
      records.add(relay.ConfigItemRecord(
        kind: item.kind.wireName,
        id: item.id,
        parentId: item.parentId,
        sortIndex: item.sortIndex,
        payload: item.payload,
        rev: item.rev,
      ));
    }
    if (bytes > _maxBytes) {
      throw relay.ResultTooLarge.bytes(
        limit: _maxBytes,
        measured: bytes,
        suggestion: 'the "$kind" rows alone exceed one answer; this family '
            'has outgrown the relay\'s per-kind ceiling and needs a paged '
            'read, which does not exist yet',
      );
    }
    return records;
  }

  @override
  Future<relay.ConfigItemsFingerprint> fingerprint(List<String> kinds) async {
    final wanted = {for (final kind in kinds) _kindOf(kind)};
    final fp = await readSharedConfigFingerprint(_require('fingerprint'), wanted);
    return relay.ConfigItemsFingerprint(count: fp.count, revSum: fp.revSum);
  }

  /// Refused here, and served by the per-identity family instead.
  ///
  /// This object is **composition-wide** — one instance for every session on
  /// the gateway — which is right for three reads that attribute nothing and
  /// wrong for a write. Every `config_change` row a write lands carries
  /// `who`, `role_name` and `station` from the verified identity, and a
  /// composition-wide writer would either stamp the gateway's own hostname on
  /// all of them or hold a mutable "current session" that two concurrent
  /// frames would swap under each other.
  ///
  /// So the write is `RelayIdentityConfigItems`', minted per station at
  /// `hello`, and this refusal is the fail-closed fallback for a composition
  /// that wired no writer — the same shape as
  /// `BackendSharedPreferences`' refusals behind the preferences door.
  @override
  Future<relay.ConfigItemsReplaceResult> replace(
          relay.ConfigItemsReplaceRequest request) async =>
      throw UnsupportedError(
          'BackendConfigItems.replace is not served: this object is shared by '
          'every session on the gateway and holds no identity, so a write '
          "through it could not say who made it. The plant's rows are "
          'written by the per-identity family minted at hello. Reaching this '
          'means the gateway was composed without a configuration writer — '
          'the backend log carries the reason it failed, once, at startup.');
}

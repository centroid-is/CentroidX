/// `key_mappings` as [ConfigItem]s, and back.
///
/// The live SVN value of `flutter_preferences.key_mappings` was 530 287 bytes
/// on 2026-08-11 and has grown since. Every save of it rewrites the whole
/// string to Postgres, writes it again to the device-local cache, and lands
/// **both** the before- and after-image in one `audit_entry` row — over a
/// megabyte, out of which nobody can tell which key changed. Its size is also
/// the reason that table was watched through a *key*-payload `pg_notify`
/// trigger rather than a row-payload one: a row payload would have exceeded
/// the 8000-byte cap and errored the very statement that saves it. Both the
/// watcher and the trigger-installing helper retired in 04-12 with the table
/// they served.
///
/// One item per key fixes all of that at once, and the payload stays exactly
/// what `KeyMappingEntry.toJson()` already produces.
///
/// ## This is a codec, not a store
///
/// Nothing here touches a database. Keeping the conversion pure is what lets
/// `key_mapping_codec_test.dart` prove the migration against the real plant
/// blob — `blob -> items -> blob` must come back structurally identical — with
/// no Postgres in the loop. That round trip is the safety net for the cutover;
/// everything else in this work can be redone, but a migration that quietly
/// drops a key cannot.
library;

import 'dart:convert';

import '../state_man.dart' show KeyMappingEntry, KeyMappings;
import 'config_item.dart';

/// The preference key the blob lives under today, and the id of the
/// compatibility row that replaces it.
const String kKeyMappingsPrefKey = 'key_mappings';

/// [mappings] as one item per key, ordered by key.
///
/// The order is canonical rather than incidental: items come back from the
/// database in whatever order the query gives, so producing them sorted here
/// means `itemsOf(mappingsOf(items))` is the same list, and a save can be
/// diffed against what is stored without the ordering alone reporting a
/// change.
///
/// [ConfigItem.sortIndex] is deliberately left null. `KeyMappings.nodes` is a
/// map — a set of keys, not a sequence — so nothing about the configuration
/// depends on their order, and storing one would invent a fact the source does
/// not have and then require every writer to maintain it.
List<ConfigItem> keyMappingItems(
  KeyMappings mappings, {
  ConfigScope scope = ConfigScope.shared,
}) {
  final keys = mappings.nodes.keys.toList()..sort();
  return [
    for (final key in keys)
      ConfigItem.of(
        kind: ConfigKind.keyMapping,
        id: key,
        value: mappings.nodes[key]!.toJson(),
        scope: scope,
      ),
  ];
}

/// [items] reassembled into the in-memory shape the app already uses.
///
/// Items of another kind are ignored rather than rejected: a caller handing
/// over a whole snapshot and asking for the key mappings out of it is the
/// normal case, not a mistake.
///
/// A later item wins for a repeated key. The table's primary key forbids the
/// duplicate, but a hand-built list does not, and silently holding two entries
/// for one key would be a subscription pointed at whichever the map happened
/// to keep.
KeyMappings keyMappingsOf(Iterable<ConfigItem> items) => KeyMappings(nodes: {
      for (final item in items)
        if (item.kind == ConfigKind.keyMapping)
          item.id: KeyMappingEntry.fromJson(item.decode()),
    });

/// The blob `flutter_preferences.key_mappings` holds, parsed into items.
///
/// This is the migration's read side and the compatibility view's write side.
/// Throws [FormatException] if the string is not the expected shape — a
/// migration that silently produced an empty configuration from an
/// unrecognised blob would look like it had succeeded.
List<ConfigItem> keyMappingItemsFromBlob(
  String blob, {
  ConfigScope scope = ConfigScope.shared,
}) {
  final decoded = jsonDecode(blob);
  if (decoded is! Map<String, dynamic>) {
    throw FormatException(
        'key_mappings must decode to a JSON object, got ${decoded.runtimeType}');
  }
  return keyMappingItems(KeyMappings.fromJson(decoded), scope: scope);
}

/// [items] re-encoded as the blob, for the compatibility view that keeps
/// `tfc_mcp_server`, `bin/page_geometry.dart` and the `tools/svn_*.py` scripts
/// working across the cutover.
///
/// Canonically encoded, so a station that regenerates the blob from unchanged
/// items produces the same bytes as the one that generated it before — which
/// is what stops the compatibility row from thrashing.
String keyMappingBlobOf(Iterable<ConfigItem> items) =>
    canonicalJson(keyMappingsOf(items).toJson());

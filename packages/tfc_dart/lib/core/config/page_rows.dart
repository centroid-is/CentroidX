/// Reading pages and their assets out of `config_item`, for the processes that
/// are not the Flutter app — and the reassembly they share with the app.
///
/// ## Why this file is not `page_codec.dart`
///
/// `page_codec.dart` lives in the Flutter app and imports `AssetPage` and
/// `Asset`, so it cannot be reached from a `dart compile exe` binary. But the
/// *rule* it encodes — an asset belongs to the page whose id is its
/// `parentId`, paint order is `sortIndex`, and the pages map is keyed by the
/// path inside the payload — is not a Flutter fact. It is the wire format, and
/// the MCP server has to agree with the editor about it or the two describe
/// different plants.
///
/// So the rule lives here, in JSON, and `page_codec.dart`'s `pagesOf` is now
/// this function plus `AssetPage.fromJson`. One definition, reachable from
/// both sides — which is the point of the exercise: the alternative on offer
/// was a second hand-rolled reassembly inside `tfc_mcp_server`, and two
/// definitions of a wire format diverge quietly.
///
/// ## FFI-free, and pinned as such
///
/// This file is exported from `tfc_dart_core.dart`, the barrel that exists so
/// `dart compile exe` does not have to link open62541. Everything it imports
/// is therefore pure Dart: drift's core, and `config_item.dart` /
/// `config_item_table.dart`, which are themselves FFI-free by construction.
/// `page_rows_test.dart` walks the transitive import graph and fails if that
/// ever stops being true — a source-text check on this one file would not have
/// caught the way D-3 arrived, which was one import deep.
///
/// ## Why [GeneratedDatabase] and not `AppDatabase`
///
/// Same reason as `key_mapping_rows.dart`: `config_item` is one physical table
/// with more than one Dart schema over it — `AppDatabase` declares it,
/// `ServerDatabase` in `tfc_mcp_server` does not — and both open the same
/// Postgres. Drift's generated table classes take their database as a
/// constructor argument, so the accessor attaches to whatever
/// [GeneratedDatabase] is handed over and the read is written once. Ordinary
/// drift builders from there: no raw SQL, and therefore no `?`-versus-`$1`
/// branch to keep in step with the two backends.
///
/// ## Nothing here writes
///
/// Reads and only reads. The write path is `config_store.dart`'s, where the
/// compare-and-swap on `rev` and the change log live.
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import 'config_item.dart';
import 'config_item_table.dart';
import 'preference_payload.dart' show decodePreferencePayload;

/// The JSON field holding a page's assets — the field the rows replace, and
/// the field [pagesJsonOf] puts back.
const String _assetsField = 'assets';

/// The JSON field holding a page's menu entry, and with it the path the pages
/// map is keyed by.
const String _menuItemField = 'menu_item';

/// The shared `page` rows, ordered by id.
///
/// Empty until the blob → rows migration has run, which is a state and not a
/// failure: a standalone MCP server can open a database no station has
/// migrated yet. An empty list means "no rows", and every caller here answers
/// with an empty layout rather than an error, because reporting a table that
/// is about to exist would take out `list_pages` for everyone.
Future<List<ConfigItem>> readSharedPageItems(GeneratedDatabase db) =>
    _readShared(db, ConfigKind.page);

/// The shared `asset` rows, ordered by id.
///
/// Ordered by id and *not* by `sort_index`, because paint order is applied in
/// [pagesJsonOf] where the tie-break on a null or duplicated index lives. A
/// second ordering rule in the query would be a second answer to the same
/// question.
///
/// [parentId] narrows to one page's assets. Null reads every page's, which is
/// what rebuilding the whole layout wants.
Future<List<ConfigItem>> readSharedAssetItems(
  GeneratedDatabase db, {
  String? parentId,
}) =>
    _readShared(db, ConfigKind.asset, parentId: parentId);

/// The whole shared layout — pages and their assets — as [ConfigItem]s.
///
/// Two queries rather than one `kind IN (...)`, so each comes back ordered by
/// its own key and neither read has to sort a mixed result.
Future<List<ConfigItem>> readSharedPageLayout(GeneratedDatabase db) async {
  final pages = await readSharedPageItems(db);
  if (pages.isEmpty) return const [];
  final assets = await readSharedAssetItems(db);
  return [...pages, ...assets];
}

/// The payload of the shared `preference` row named [key], decoded.
///
/// Null when there is no such row — which is every row until plan 04-11
/// migrates the preferences, and is the same answer a caller got from a
/// missing `flutter_preferences` key. A reader that treats null as "not
/// configured" is therefore correct across the cutover in both directions.
///
/// **Every preference row is a typed envelope**, `{"type": "String", "value":
/// "<the document>"}` — `preference_payload.dart`'s shape, written by
/// `SharedRowPreferences` and by the migration alike — so the value is lifted
/// out of the envelope first, through the same decoder every other reader
/// uses, and *then* decoded as the JSON document it is. Reading the envelope
/// itself as the document is the mistake this used to make: `alarm_man_config`
/// came back as `{type, value}`, `['alarms']` was null, and the MCP server
/// reported a plant with no alarms.
///
/// A payload that is not an envelope — a bare JSON object, as a hand-written
/// row or a fixture might hold, or a JSON document held as a string — is
/// accepted as the document directly, so a row written before the envelope
/// existed still reads.
///
/// Anything that is not a JSON object once decoded reads as null: a scalar
/// preference is not a config document, and returning one would push the type
/// error into a caller that was asking for a map.
Future<Map<String, dynamic>?> readSharedPreferencePayload(
  GeneratedDatabase db,
  String key,
) async {
  final table = _configItems(db);
  final row = await (db.select(table)
        ..where((t) =>
            t.kind.equals(ConfigKind.preference.wireName) &
            t.scope.equals(ConfigScope.shared.wireName) &
            t.id.equals(key))
        ..limit(1))
      .getSingleOrNull();
  if (row == null) return null;

  Object? decoded;
  try {
    decoded = jsonDecode(row.payload);
    if (decoded is Map &&
        decoded.containsKey('type') &&
        decoded.containsKey('value')) {
      // The envelope. Its `value` is the preference — for a config document,
      // the document's JSON text.
      decoded = decodePreferencePayload(row.payload);
    }
    if (decoded is String) decoded = jsonDecode(decoded);
  } on FormatException {
    return null;
  }
  return decoded is Map<String, dynamic> ? decoded : null;
}

/// [items] reassembled into the pages map, as JSON.
///
/// The shape `page_editor_data` held: one entry per page, keyed by the page's
/// path, whose value is the page's own JSON with its `assets` list back in
/// place. Callers that used to `jsonDecode` the blob get the same object.
///
/// Assets attach to the page whose **id** is their [ConfigItem.parentId] and
/// are ordered by [ConfigItem.sortIndex] — paint order is configuration, so
/// losing it changes what is drawn on top of what. An asset whose parent is
/// not among [items] is dropped rather than attached somewhere arbitrary; a
/// page with no assets is still a page and gets an empty list, because an
/// empty page is a real thing (`/baader` and `/diagnostics` are section
/// headers with none).
///
/// A page whose payload path is empty gets a slug fallback derived from its
/// id, written back into its menu item: without it two path-less pages would
/// both land on `''` and one would silently overwrite the other.
///
/// Items of other kinds are ignored — handing over a whole snapshot and asking
/// for the pages out of it is the normal case, not a mistake.
Map<String, Map<String, dynamic>> pagesJsonOf(Iterable<ConfigItem> items) {
  final pageItems = <String, ConfigItem>{};
  final assetsByPage = <String, List<ConfigItem>>{};

  for (final item in items) {
    switch (item.kind) {
      case ConfigKind.page:
        pageItems[item.id] = item;
      case ConfigKind.asset:
        final parent = item.parentId;
        if (parent != null) {
          (assetsByPage[parent] ??= <ConfigItem>[]).add(item);
        }
      case ConfigKind.keyMapping:
      case ConfigKind.preference:
      // A page's images are rows beside its assets, not part of the page
      // object this builds: an asset names the image it draws by id.
      case ConfigKind.pageImage:
        break;
    }
  }

  final pages = <String, Map<String, dynamic>>{};
  for (final entry in pageItems.entries) {
    final assets = assetsByPage[entry.key] ?? const <ConfigItem>[];
    final ordered = [...assets]..sort(bySortIndexThenId);
    final json = Map<String, dynamic>.from(entry.value.decode());
    json[_assetsField] = [for (final item in ordered) item.decode()];

    final menuItem = json[_menuItemField];
    final path = menuItem is Map ? menuItem['path'] as String? : null;
    final key = (path != null && path.isNotEmpty)
        ? path
        : fallbackPagePathFor(entry.key);
    if (path == null || path.isEmpty) {
      // The page has to agree with the map about where it lives, or the next
      // save keys it somewhere else again.
      json[_menuItemField] = {
        if (menuItem is Map) ...menuItem.cast<String, dynamic>(),
        'path': key,
      };
    }
    pages[key] = json;
  }
  return pages;
}

/// Paint order, with the id as the tiebreak.
///
/// `sort()` is not stable and a null [ConfigItem.sortIndex] would otherwise
/// float wherever the sort left it, so two reads of one page could paint its
/// assets in two different orders. Nulls sort last, and equal indices — which
/// the schema permits and a botched write could produce — fall back to the id
/// so the answer is at least the same every time.
int bySortIndexThenId(ConfigItem a, ConfigItem b) {
  final ai = a.sortIndex, bi = b.sortIndex;
  if (ai != bi) {
    if (ai == null) return 1;
    if (bi == null) return -1;
    return ai.compareTo(bi);
  }
  return a.id.compareTo(b.id);
}

/// The path a page with no path of its own lives at.
///
/// `PageManager.fallbackPathFor` in the app delegates here rather than keeping
/// its own copy: the fallback decides the *key of the pages map*, so an app
/// and an MCP server that slugified differently would disagree about which
/// page is which for exactly the pages nobody named.
String fallbackPagePathFor(String key) => '/${_slugify(key)}';

/// Lowercase, punctuation dropped, whitespace hyphenated.
String _slugify(String text) => text
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9\s]'), '')
    .replaceAll(RegExp(r'\s+'), '-');

/// Shared rows of one [kind], ordered by id.
Future<List<ConfigItem>> _readShared(
  GeneratedDatabase db,
  ConfigKind kind, {
  String? parentId,
}) async {
  final table = _configItems(db);
  final rows = await (db.select(table)
        ..where((t) {
          final match = t.kind.equals(kind.wireName) &
              t.scope.equals(ConfigScope.shared.wireName);
          return parentId == null
              ? match
              : match & t.parentId.equals(parentId);
        })
        ..orderBy([(t) => OrderingTerm.asc(t.id)]))
      .get();
  return rows.map((row) => _itemOf(row, kind)).toList(growable: false);
}

/// `config_item` attached to [db].
///
/// The FFI-free accessor from `config_item_table.dart`, not `AppDatabase`'s —
/// see that file's header. Both are generated from the one declaration and
/// address the one physical table.
$ConfigItemTableTable _configItems(GeneratedDatabase db) =>
    $ConfigItemTableTable(db);

/// One row as the value type the rest of the code uses.
///
/// [kind] and `scope` are what the query filtered on, so re-parsing the
/// columns would only introduce a way for the two to disagree.
ConfigItem _itemOf(ConfigItemRow row, ConfigKind kind) => ConfigItem(
      kind: kind,
      id: row.id,
      scope: ConfigScope.shared,
      parentId: row.parentId,
      sortIndex: row.sortIndex,
      payload: row.payload,
      rev: row.rev,
      updatedAt: row.updatedAt,
      updatedBy: row.updatedBy,
    );

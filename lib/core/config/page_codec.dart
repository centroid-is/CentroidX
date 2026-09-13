/// `page_editor_data` as [ConfigItem]s, and back.
///
/// The blob is one JSON object keyed by page path, each page holding its menu
/// item, its flags and its whole asset list. Saving it rewrites all of it: on
/// the 2026-08-11 production value that is 145 kB to Postgres, 145 kB again to
/// the device-local cache, and **both** the before- and after-image into one
/// `audit_entry` row — 290 kB out of which nobody can tell which asset moved.
/// Two stations editing two different pages is a last-writer-wins race over
/// the entire layout.
///
/// Split, a page becomes one [ConfigKind.page] item plus one
/// [ConfigKind.asset] item per top-level asset, and a save writes the assets
/// that actually moved.
///
/// ## Top-level assets only
///
/// A composite asset nests its children *inside its own JSON* as typed fields
/// — `BeckhoffCX5010Config.subdevices`, and everything reached through
/// `Asset.childAssets`. They stay there. They are not independently editable,
/// they have no identity of their own outside their parent, and lifting them
/// into rows would mean rewriting every composite config class and its
/// generated serialization for granularity nobody edits at.
///
/// ## This is a codec, not a store
///
/// Nothing here touches a database — see `key_mapping_codec.dart` for why that
/// matters: it is what lets `page_codec_test.dart` prove the migration against
/// the real plant blob with no Postgres in the loop.
///
/// ## Where order lives
///
/// Asset items carry a [ConfigItem.sortIndex], because paint order is the
/// asset list's order and nothing else records it. Page items carry
/// `sortIndex: null` on purpose: a page's place in the navigation tree is
/// `navigation_priority` *inside its payload*, which is also what the
/// compatibility blob's readers go by. Two records of one order would be two
/// records that can disagree.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_store_errors.dart'
    show ConfigConflict;
import 'package:tfc_dart/core/config/page_rows.dart'
    show bySortIndexThenId, pagesJsonOf;

import '../../page_creator/assets/common.dart' show Asset;
import '../../page_creator/page.dart' show AssetPage, PageManager;

/// The preference key the blob lives under today.
const String kPageEditorPrefKey = PageManager.storageKey;

/// The JSON field holding a page's assets, which the page item does not carry
/// because each asset is an item of its own.
const String _assetsField = 'assets';

/// The JSON field holding a page's menu entry — and with it the path the
/// pages map is keyed by, which is data inside the payload now that the row
/// is named by [AssetPage.id].
const String _menuItemField = 'menu_item';

/// A **migration-time** id for an asset that has never had one.
///
/// `Asset.id` is null until something links to the asset (`common.dart:156`),
/// so most of the plant's assets arrive at the migration with no identity at
/// all — and several SVN stations share one Postgres and boot at once, so more
/// than one of them may reach the migration.
///
/// Deriving the id from the page path, the asset's position and its content
/// makes the migration **idempotent**: the same blob yields the same ids on
/// every station, so a re-run writes nothing and no "already migrated" flag is
/// needed. The index is in the hash because two identical assets on one page
/// are legitimate — a row of identical drives — and would otherwise collide.
///
/// **This is not the concurrency mechanism, and must not be mistaken for one.**
/// Convergence only holds for identical inputs; two stations migrating from
/// *divergent* copies (one from Postgres, one from a stale local cache) hash to
/// different ids and produce silent duplicates that no primary key will flag.
/// What actually closes that race is reading the blob and writing the rows in
/// one transaction under a Postgres advisory lock. The hash earns re-run
/// idempotency and a testable migration; it does not earn safety.
///
/// **Migration only — never a save.** Deriving an id for an asset created in
/// the editor would be actively harmful: two people each adding, say, a lamp at
/// the same index of the same page would derive the *same* id, and their two
/// assets would collapse into one row — the exact failure rows exist to end.
/// New assets get a random id from `Asset.ensureId()`, which is what
/// [pageItems] uses unless told otherwise.
///
/// 24 hex characters, matching `newAssetId()`'s shape, so nothing downstream
/// can tell a migrated id from a minted one.
String derivedAssetId(String pagePath, int index, String payload) {
  final digest = sha256.convert(utf8.encode('$pagePath $index $payload'));
  return digest.toString().substring(0, 24);
}

/// A **migration-time** id for a page, derived from its path.
///
/// Pages have no id in the stored blob at all — they are keyed by path, and
/// the path is edited — so every page arrives at the migration needing one.
/// Deriving it from the path makes the migration idempotent for the same
/// reasons [derivedAssetId] does: several SVN stations share one Postgres and
/// boot at once, and each must compute the same id from the same blob or the
/// plant's layout is written twice.
///
/// **Migration only — never a save**, and the caution is sharper here than it
/// is for assets. A path is a *short* string that two people would plausibly
/// choose independently: two editors each adding a page at `/roe2` would
/// derive the same id and collapse into one row. [pageItems] mints a random
/// id through `AssetPage.ensureId()` unless [pageItemsFromBlob] tells it
/// otherwise.
///
/// 24 hex characters, matching `newAssetId()`'s shape, so nothing downstream
/// can tell a page's migrated id from a minted one — or from an asset's.
String derivedPageId(String path) =>
    sha256.convert(utf8.encode(path)).toString().substring(0, 24);

/// [pages] as items: one per page, one per top-level asset.
///
/// Pages come first and then their assets, both ordered by path, so
/// `pageItems` of the same layout is always the same list and a diff against
/// what is stored reports only real edits.
///
/// **Mutates the pages and the assets that have no id**, assigning one. That
/// is unavoidable — the id has to end up on the object as well as in the row,
/// or the next save mints a second one — and it is why this takes the live
/// [AssetPage]s rather than a copy. For a page it is what makes the id
/// survive the editor's undo stack, which is encoded page JSON: see
/// [AssetPage.id].
///
/// A page item is named by [AssetPage.id] and an asset item's
/// [ConfigItem.parentId] is that same id, **not the page's path**. A rename is
/// then one changed page payload and no asset rows at all; path-keyed it
/// would be a delete, an insert and an update per asset, with the page's
/// history cut in two at every rename.
///
/// [deriveIds] picks *which* id an id-less page or asset gets, and only the
/// migration may set it. False, the default, mints a random one through
/// `ensureId()`: that is right for every save, because two editors each
/// adding an asset at the same index of the same page must get two rows.
/// True derives it from the content — see [derivedAssetId] and
/// [derivedPageId] for why that is right exactly once and wrong every other
/// time.
List<ConfigItem> pageItems(
  Map<String, AssetPage> pages, {
  ConfigScope scope = ConfigScope.shared,
  bool deriveIds = false,
}) {
  final paths = pages.keys.toList()..sort();
  final items = <ConfigItem>[];

  for (final path in paths) {
    final page = pages[path]!;
    page.id ??= deriveIds ? derivedPageId(path) : page.ensureId();
    items.add(ConfigItem.of(
      kind: ConfigKind.page,
      id: page.id!,
      value: pageFieldsOf(page),
      scope: scope,
    ));
  }

  for (final path in paths) {
    final page = pages[path]!;
    final assets = page.assets;
    for (var index = 0; index < assets.length; index++) {
      final asset = assets[index];
      asset.id ??= deriveIds
          ? derivedAssetId(path, index, canonicalJson(asset.toJson()))
          : asset.ensureId();
      items.add(ConfigItem.of(
        kind: ConfigKind.asset,
        id: asset.id!,
        value: asset.toJson(),
        scope: scope,
        // The page's id, not its path: the asset must not need rewriting
        // because somebody renamed the page it sits on.
        parentId: page.id,
        sortIndex: index,
      ));
    }
  }

  return items;
}

/// Copies onto [pages] the identities the stored rows already carry, so a
/// save from a blob fallback does not mint a second set.
///
/// ## The day this exists for
///
/// Page rows cannot pre-exist the migration that mints them, so on cutover day
/// every station loads its layout from the `page_editor_data` blob before its
/// mirror holds a single row — and the pages it holds have no id at all. The
/// rows arrive minutes later at the reconcile. Without this, the first Ctrl+S
/// runs [pageItems] over those id-less pages, mints ~410 fresh random ids,
/// diffs them against the migration's derived-id rows and writes ~410 removes
/// plus ~410 adds. That save **commits cleanly** — no rev moved, so no
/// conflict arm fires and nothing downstream reports anything — and every
/// identity the migration minted is severed. The next station does it again.
///
/// `providers/page_manager.dart` closes the same window from the read side, by
/// re-loading off the rows when the first diff carrying pages arrives. This is
/// the other half: the session that was already open, saving.
///
/// ## Copied, never derived
///
/// Adoption only ever assigns an id that is **already on a stored row**. It
/// must never call [derivedPageId] or [derivedAssetId]: deriving an id at save
/// time is the collision this codec warns about twice — two editors each
/// adding an identical asset at the same index of the same page compute the
/// *same* id and collapse into one row. Those two functions are the
/// migration's, and stay the migration's.
///
/// ## What is matched, and what is left alone
///
/// Nothing happens unless some page in [pages] has no id **and** [stored]
/// holds page rows: this is the rollout-day repair, not a general re-pairing
/// pass. A page that already carries an id is the steady state, and its assets
/// are not touched — otherwise an operator who deletes one asset and adds
/// another would have the new one silently take the deleted one's row.
///
/// For a page with no id:
///
/// 1. it adopts the id of the stored page row whose payload `menu_item.path`
///    is the key it lives under;
/// 2. each of its id-less assets adopts a stored row of that page whose
///    payload is byte-identical once the `id` field is set aside, position
///    breaking the tie — a row of genuinely identical drives is legitimate and
///    payload equality cannot tell those apart;
/// 3. whatever is left over on both sides is paired positionally;
/// 4. anything still unmatched keeps its null id, and [pageItems] mints a
///    random one — which is exactly right for an asset the rows have never
///    seen.
void adoptRowIdentities(
    Map<String, AssetPage> pages, Iterable<ConfigItem> stored) {
  final storedPages = <ConfigItem>[];
  final storedAssets = <String, List<ConfigItem>>{};
  for (final item in stored) {
    switch (item.kind) {
      case ConfigKind.page:
        storedPages.add(item);
      case ConfigKind.asset:
        final parent = item.parentId;
        if (parent != null) {
          (storedAssets[parent] ??= <ConfigItem>[]).add(item);
        }
      case ConfigKind.keyMapping:
      case ConfigKind.preference:
      // A page's images are rows beside its assets, not part of the page
      // object this codec builds: an asset names the image it draws by id.
      case ConfigKind.pageImage:
        break;
    }
  }
  if (storedPages.isEmpty) return;
  if (!pages.values.any((page) => page.id == null)) return;

  // An id another page in memory already holds is not available to adopt:
  // two pages on one row is one page, whichever way round it happened.
  final claimedPages = {
    for (final page in pages.values)
      if (page.id != null) page.id!,
  };
  final byPath = <String, List<ConfigItem>>{};
  for (final item in storedPages) {
    if (claimedPages.contains(item.id)) continue;
    final menuItem = item.decode()[_menuItemField];
    final path = menuItem is Map ? menuItem['path'] as String? : null;
    final key = (path != null && path.isNotEmpty)
        ? path
        : PageManager.fallbackPathFor(item.id);
    (byPath[key] ??= <ConfigItem>[]).add(item);
  }

  for (final entry in pages.entries) {
    final page = entry.value;
    if (page.id != null) continue;
    final candidates = byPath[entry.key];
    if (candidates == null || candidates.isEmpty) continue;
    final row = candidates.removeAt(0);
    page.id = row.id;
    _adoptAssetIdentities(page, storedAssets[row.id] ?? const <ConfigItem>[]);
  }
}

/// The asset half of [adoptRowIdentities], for one page that just adopted its
/// own row.
void _adoptAssetIdentities(AssetPage page, List<ConfigItem> rows) {
  // Paint order, so "position" means the same thing on both sides.
  final ordered = [...rows]..sort(bySortIndexThenId);
  final taken = List<bool>.filled(ordered.length, false);
  for (var i = 0; i < ordered.length; i++) {
    if (page.assets.any((asset) => asset.id == ordered[i].id)) taken[i] = true;
  }
  final payloads = [
    for (final row in ordered) _identityBlindPayload(row.decode()),
  ];

  // Pass 1: the same asset, byte for byte. Position only breaks ties between
  // rows that are already indistinguishable.
  final unmatched = <int>[];
  for (var index = 0; index < page.assets.length; index++) {
    final asset = page.assets[index];
    if (asset.id != null) continue;
    final wanted = _identityBlindPayload(asset.toJson());
    var pick = -1;
    for (var i = 0; i < ordered.length; i++) {
      if (taken[i] || payloads[i] != wanted) continue;
      if (i == index) {
        pick = i;
        break;
      }
      if (pick < 0) pick = i;
    }
    if (pick < 0) {
      unmatched.add(index);
      continue;
    }
    taken[pick] = true;
    asset.id = ordered[pick].id;
  }

  // Pass 2: whatever is left, in position order. An asset edited between the
  // migration and this save no longer matches its own row's payload, and
  // pairing it back onto that row is what keeps its history in one piece.
  var next = 0;
  for (final index in unmatched) {
    while (next < ordered.length && taken[next]) {
      next++;
    }
    if (next >= ordered.length) return; // Pass 3: minted by `pageItems`.
    taken[next] = true;
    page.assets[index].id = ordered[next].id;
  }
}

/// [payload] with its `id` set aside, canonically encoded.
///
/// The stored row's payload carries the id the migration put on it; the
/// in-memory asset that *is* that row has none yet. Comparing them with the id
/// in place would find nothing equal and send every asset down the positional
/// pass.
String _identityBlindPayload(Map<String, dynamic> payload) => canonicalJson({
      for (final entry in payload.entries)
        if (entry.key != 'id') entry.key: entry.value,
    });

/// A page's own JSON, without its assets.
///
/// Carries [AssetPage.id], so the page item's payload names the same row the
/// item does and a blob re-encoded from items keeps its ids.
///
/// Built from `AssetPage.toJson()` with the asset list removed rather than
/// field by field: a field added to [AssetPage] then lands here automatically
/// instead of being silently dropped on the next migration, which is the
/// failure `AssetPage.copyWith`'s doc comment already warns about for the
/// hand-rolled rebuilds elsewhere in the editor.
Map<String, dynamic> pageFieldsOf(AssetPage page) {
  final json = page.toJson();
  json.remove(_assetsField);
  return json;
}

/// [items] reassembled into the map the app already uses.
///
/// The reassembly itself is `page_rows.dart`'s [pagesJsonOf] — which page an
/// asset belongs to, what order its assets paint in, what key a path-less page
/// lands under. That rule is the wire format and not a Flutter fact, and the
/// MCP server has to reach the same answer from the same rows or the two
/// describe different plants; so it lives in `tfc_dart`, reachable from a
/// `dart compile exe` binary, and this function is that plus
/// [AssetPage.fromJson].
///
/// The map is keyed by the **path in the payload**, not by the item id, so
/// every navigation reader — the route table, the menu, `pagesOf`'s callers
/// looking a page up by where it lives — is untouched by pages having ids at
/// all.
Map<String, AssetPage> pagesOf(Iterable<ConfigItem> items) => {
      for (final entry in pagesJsonOf(items).entries)
        entry.key: AssetPage.fromJson(entry.value),
    };

/// The blob `flutter_preferences.page_editor_data` holds, parsed into items.
///
/// Throws [FormatException] if the string is not the expected shape — a
/// migration that silently produced an empty layout from an unrecognised blob
/// would look like it had succeeded, and the station would come up on the
/// hardcoded default page.
/// [deriveIds] defaults to true here and nowhere else: reading the blob *is*
/// the migration, and it is the one moment at which content-derived ids are
/// correct. Pass false to parse a blob without minting stable ids — what the
/// compatibility view's read side wants.
List<ConfigItem> pageItemsFromBlob(
  String blob, {
  ConfigScope scope = ConfigScope.shared,
  bool deriveIds = true,
}) {
  final decoded = jsonDecode(blob);
  if (decoded is! Map<String, dynamic>) {
    throw FormatException('page_editor_data must decode to a JSON object, '
        'got ${decoded.runtimeType}');
  }
  return pageItems(PageManager.pagesFromJson(blob),
      scope: scope, deriveIds: deriveIds);
}

/// [items] re-encoded as the blob, for the compatibility view that keeps
/// `tfc_mcp_server`, `bin/page_geometry.dart` and the `tools/svn_*.py` scripts
/// working across the cutover.
String pageBlobOf(Iterable<ConfigItem> items) => canonicalJson({
      for (final entry in pagesOf(items).entries) entry.key: entry.value.toJson(),
    });

/// Every asset in [pages], top-level only, in the order [pageItems] emits.
///
/// Exposed for the migration's own reporting: "3 pages, 196 assets" is the
/// line an operator needs to see before agreeing to it.
Iterable<Asset> topLevelAssets(Map<String, AssetPage> pages) sync* {
  final paths = pages.keys.toList()..sort();
  for (final path in paths) {
    yield* pages[path]!.assets;
  }
}


// ---------------------------------------------------------------------------
// The save-time merge
// ---------------------------------------------------------------------------

/// Reconciles the layout an editor is about to save with what the plant holds
/// **now**, so that a save is a replace of what this editor was shown and not
/// of the whole plant.
///
/// `ConfigStore.writeItems` replaces within kinds: every stored page and asset
/// absent from [wanted] is deleted, and every present one is written over.
/// An editor hands over the layout it loaded when it was opened, and it can
/// have been open for an hour. Without this, a page another station added
/// in that hour was deleted — cleanly, because this station's snapshot had
/// already reconciled the row, so the compare-and-swap matched — and an edit
/// another station made to a page this operator never touched was overwritten
/// with the copy from an hour ago. The per-row CAS protects the window since
/// the last sync; it says nothing about the window since the editor opened.
/// This is what says something about it.
///
/// [baseline] is what the editor was shown: the store's page and asset items
/// at the moment it loaded. The merge is decided **per page**, pages being
/// the unit an operator edits, with a page's assets as part of it:
///
///   * A stored page the baseline never held — added elsewhere since — is
///     **kept**, as stored, unless the editor holds the same id (which can
///     only mean an adoption or a genuine collision): identical content is
///     nothing to write, different content is a [ConfigConflict].
///   * A stored page that has **moved** since the baseline — its row or any
///     asset on it at a different revision, or an asset added or removed — is
///     kept as stored when the editor left the page exactly as loaded, and is
///     a [ConfigConflict] when the operator changed it too, or deleted it.
///   * A baseline page the store no longer holds — deleted elsewhere since —
///     is dropped when the editor left it as loaded, and is a [ConfigConflict]
///     when the operator edited it.
///   * Everything else is the editor's to decide, as before.
///
/// A null [baseline] is an editor opened on a fallback layout — the blob, or
/// the built-in default — with no row identities to compare against. Its
/// pages win where the ids coincide (that is the rollout-day adoption), and
/// every stored page it does not hold is kept: a station on the blob must not
/// erase the plant's rows on its first save.
///
/// Two pages may not share a path. `pagesJsonOf` keys the layout by path, so
/// a second page at the same path is invisible everywhere and deleted by the
/// next save. The merge is the one place both sides are in hand, so it is
/// where that is refused — as a [ConfigConflict] naming the path.
///
/// Pure: reads only, no store, no clock. `sortIndex` on a kept stored page's
/// assets is its stored key, which `assignSortKeys` reads as an ordinal within
/// that page alone — monotonic, so the run is kept and nothing is rewritten.
List<ConfigItem> mergeForSave({
  required List<ConfigItem> wanted,
  required List<ConfigItem> stored,
  required List<ConfigItem>? baseline,
}) {
  final wantedPages = _groupByPage(wanted);
  final storedPages = _groupByPage(stored);
  final basePages = baseline == null ? null : _groupByPage(baseline);

  // What is emitted, by page id. Starts as the editor's layout.
  final keep = <String, _PageGroup>{...wantedPages};

  for (final entry in storedPages.entries) {
    final id = entry.key;
    final theirs = entry.value;
    final ours = wantedPages[id];

    if (basePages == null) {
      // A fallback layout: keep what the editor never saw, let it win where
      // the ids coincide (adoption).
      if (ours == null) keep[id] = theirs;
      continue;
    }

    final base = basePages[id];
    if (base == null) {
      // Added elsewhere since this editor loaded.
      if (ours == null) {
        keep[id] = theirs;
        continue;
      }
      if (_fingerprint(ours) == _fingerprint(theirs)) continue;
      throw ConfigConflict.created(id);
    }

    if (_moved(theirs, base)) {
      final expected = base.page?.rev ?? 0;
      if (ours == null) {
        // Deleted here, changed there.
        throw ConfigConflict(id, expectedRev: expected);
      }
      if (_fingerprint(ours) == _fingerprint(base)) {
        // Untouched here: theirs is the newer truth.
        keep[id] = theirs;
        continue;
      }
      throw ConfigConflict(id, expectedRev: expected);
    }
    // Unmoved: the editor decides, and already has.
  }

  if (basePages != null) {
    for (final entry in basePages.entries) {
      final id = entry.key;
      if (storedPages.containsKey(id)) continue;
      final ours = wantedPages[id];
      if (ours == null) continue; // Deleted on both sides.
      if (_fingerprint(ours) == _fingerprint(entry.value)) {
        // Deleted elsewhere, untouched here: their delete stands.
        keep.remove(id);
        continue;
      }
      throw ConfigConflict(id, expectedRev: entry.value.page?.rev ?? 0);
    }
  }

  final owners = <String, String>{};
  for (final group in keep.values) {
    final page = group.page;
    if (page == null) continue;
    final path = _pathOf(page);
    if (path == null) continue;
    final other = owners[path];
    if (other != null && other != page.id) throw ConfigConflict.created(path);
    owners[path] = page.id;
  }

  return [
    for (final group in keep.values)
      if (group.page case final page?) page,
    for (final group in keep.values) ...group.assets,
  ];
}

/// Carries the identities a save minted or adopted back onto the pages an
/// editor is still holding.
///
/// The editor saves a **JSON copy** of its pages (`PageManager.copyPages`),
/// and it is the copy that `pageItems` stamps ids onto. Without this the
/// editor's own pages never learn them: an asset added in this session is
/// minted a fresh id on every save, so each save deletes the row the last one
/// inserted and inserts another, and the asset's history is cut at every
/// Ctrl+S. Matched by path and by position, which is exact — the copy is a
/// structural clone of [into] — and only ever fills an id that is missing.
void adoptIdentitiesFrom(
    Map<String, AssetPage> from, Map<String, AssetPage> into) {
  for (final entry in into.entries) {
    final saved = from[entry.key];
    if (saved == null) continue;
    final page = entry.value;
    page.id ??= saved.id;
    if (saved.assets.length != page.assets.length) continue;
    for (var i = 0; i < page.assets.length; i++) {
      page.assets[i].id ??= saved.assets[i].id;
    }
  }
}

class _PageGroup {
  ConfigItem? page;
  final List<ConfigItem> assets = [];
}

Map<String, _PageGroup> _groupByPage(Iterable<ConfigItem> items) {
  final groups = <String, _PageGroup>{};
  for (final item in items) {
    switch (item.kind) {
      case ConfigKind.page:
        (groups[item.id] ??= _PageGroup()).page = item;
      case ConfigKind.asset:
        final parent = item.parentId;
        if (parent != null) (groups[parent] ??= _PageGroup()).assets.add(item);
      case ConfigKind.keyMapping:
      case ConfigKind.preference:
      case ConfigKind.pageImage:
        break;
    }
  }
  return groups;
}

/// Whether [stored] is at different revisions from [base], or holds a
/// different set of assets — anything another station committed since.
bool _moved(_PageGroup stored, _PageGroup base) {
  if (stored.page?.rev != base.page?.rev) return true;
  final baseRevs = {for (final asset in base.assets) asset.id: asset.rev};
  if (baseRevs.length != stored.assets.length) return true;
  for (final asset in stored.assets) {
    if (baseRevs[asset.id] != asset.rev) return true;
  }
  return false;
}

/// The page's content — its own payload and its assets in paint order, each
/// by id and payload. Position is compared by order and not by key, because
/// an editor's items carry ordinals where stored rows carry gapped keys.
String _fingerprint(_PageGroup group) {
  final ordered = [...group.assets]..sort(bySortIndexThenId);
  return canonicalJson({
    'page': group.page == null ? null : jsonDecode(group.page!.payload),
    'assets': [
      for (final asset in ordered)
        {'id': asset.id, 'payload': jsonDecode(asset.payload)},
    ],
  });
}

String? _pathOf(ConfigItem page) {
  final menuItem = page.decode()[_menuItemField];
  final path = menuItem is Map ? menuItem['path'] : null;
  return path is String && path.isNotEmpty ? path : null;
}

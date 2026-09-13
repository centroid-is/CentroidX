import 'dart:convert';

import 'package:json_annotation/json_annotation.dart';
import 'package:flutter/material.dart';
import 'package:tfc/widgets/panes/standard_dialog.dart';
import 'assets/common.dart';
import 'assets/registry.dart';
import '../models/menu_item.dart';
import 'package:tfc_dart/core/fuzzy_match.dart';
import 'package:logger/logger.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/page_rows.dart' show fallbackPagePathFor;
import 'package:tfc_dart/core/config/config_store.dart';
import 'package:tfc_dart/core/config/preference_payload.dart'
    show decodePreferencePayload;
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc/converter/icon.dart';
import '../core/config/page_codec.dart';

part 'page.g.dart';

@JsonSerializable()
class AssetPage {
  @JsonKey(name: 'menu_item')
  final MenuItem menuItem;
  @AssetListConverter()
  final List<Asset> assets;
  @JsonKey(name: 'mirroring_disabled')
  bool mirroringDisabled;

  /// Whether the runtime page view refuses to zoom and pan, so operators see
  /// the whole page exactly as laid out. It stays on the canvas; the page
  /// editor's canvas still zooms, because placing assets needs it.
  ///
  /// Defaults to false, including for page data written before this existed.
  @JsonKey(name: 'zoom_pan_disabled', defaultValue: false)
  bool zoomPanDisabled;
  @JsonKey(name: 'navigation_priority')
  int? navigationPriority;

  /// Whether operators can reach this page.
  ///
  /// An unpublished page is a draft: it stays in the editor, keeps its assets
  /// and its path, and is fully editable — but [PageManager.getRootMenuItems]
  /// leaves it out, so it appears in neither the navigation menu nor the route
  /// table. That is what lets a page be built over several shifts on the live
  /// HMI without operators finding a half-finished screen.
  ///
  /// Unpublishing a section hides everything under it: the section is the only
  /// way to those pages in the menu, so a published child of a draft section
  /// would be unreachable anyway.
  ///
  /// Defaults to true, including for page data written before this existed.
  @JsonKey(name: 'published', defaultValue: true)
  bool published;

  /// A stable handle for this page that survives a rename.
  ///
  /// The page map is keyed by path and paths are edited
  /// (`page_editor.dart`'s `_updatePathInChildren` exists because renames
  /// happen); a path-keyed row loses the page's history at every rename and
  /// restamps `parent_id` on every asset on it. This id is the row's
  /// identity; the path stays in [menuItem] as data.
  ///
  /// **It has to be a serialized field.** The editor snapshots its undo
  /// history as encoded page JSON and saves through [PageManager.copyPages],
  /// which is `jsonEncode` -> [PageManager.pagesFromJson]. Anything held
  /// beside the object rather than inside it is gone at the first Ctrl+Z.
  ///
  /// Null until minted, and `includeIfNull: false` keeps the change additive
  /// — a page saved before ids existed round-trips without the key at all.
  /// See [Asset.id], which works exactly this way for the same reasons.
  @JsonKey(name: 'id', includeIfNull: false)
  String? id;

  AssetPage(
      {required this.menuItem,
      required this.assets,
      required this.mirroringDisabled,
      this.zoomPanDisabled = false,
      this.navigationPriority,
      this.published = true,
      this.id});

  /// This page's [id], minting one if it has none yet.
  ///
  /// Mints through [newAssetId] rather than a UUID package for the reason
  /// that function's doc gives; a page id and an asset id are deliberately
  /// indistinguishable in shape.
  String ensureId() => id ??= newAssetId();

  /// A copy with individual fields replaced.
  ///
  /// Rebuilding an [AssetPage] field by field is the pattern all over the
  /// editor and it silently drops whatever field was added last; go through
  /// here instead.
  AssetPage copyWith({
    MenuItem? menuItem,
    List<Asset>? assets,
    bool? mirroringDisabled,
    bool? zoomPanDisabled,
    int? navigationPriority,
    bool? published,
    String? id,
  }) {
    return AssetPage(
      menuItem: menuItem ?? this.menuItem,
      assets: assets ?? this.assets,
      mirroringDisabled: mirroringDisabled ?? this.mirroringDisabled,
      zoomPanDisabled: zoomPanDisabled ?? this.zoomPanDisabled,
      navigationPriority: navigationPriority ?? this.navigationPriority,
      published: published ?? this.published,
      id: id ?? this.id,
    );
  }

  factory AssetPage.fromJson(Map<String, dynamic> json) =>
      _$AssetPageFromJson(json);
  Map<String, dynamic> toJson() => _$AssetPageToJson(this);
}

class AssetListConverter implements JsonConverter<List<Asset>, List<dynamic>> {
  const AssetListConverter();

  @override
  List<Asset> fromJson(List<dynamic> json) {
    return AssetRegistry.parse({'assets': json});
  }

  @override
  List<dynamic> toJson(List<Asset> assets) {
    return assets.map((asset) => asset.toJson()).toList();
  }
}

/// Off the happy path only: a mirror that would not read, a blob that would
/// not parse. Nothing here logs per read.
final Logger _logger = Logger();

/// Where the pages [PageManager] currently holds came from.
///
/// The distinction this exists to make is **"empty" versus "not yet loaded"**.
/// A manager whose [PageManager.pages] is empty may be a station whose layout
/// really is empty, or one whose [PageManager.load] has not run — and the
/// re-load trigger in `providers/page_manager.dart` has to tell them apart or
/// it silently never fires, which looks exactly like a window that never
/// opened.
enum PageSource {
  /// [PageManager.load] has not run on this manager. Every construction
  /// starts here, including the 64 in `test/`.
  notLoaded,

  /// Rows from the local mirror, through [pagesOf]. The steady state after
  /// the migration.
  rows,

  /// The device-local `page_editor_data` blob, read **read-only**. What a
  /// station serves between boot and the reconcile that brings it rows.
  blob,

  /// The built-in default layout, held in memory and persisted nowhere.
  builtInDefault,
}

class PageManager {
  static const String storageKey = 'page_editor_data';
  static const String orderStorageKey = 'page_editor_top_level_order';
  Map<String, AssetPage> pages;
  final PreferencesApi prefs;

  /// Paths of the app's top-level navigation destinations, in the order the
  /// operator arranged them in the Pages dialog.
  ///
  /// [AssetPage.navigationPriority] only orders our own pages against each
  /// other; the app also registers destinations of its own (Alarm View,
  /// Advanced, ...) whose position is otherwise fixed by registration order.
  /// This list covers both kinds so built-ins can be reordered too. Empty
  /// means "never arranged" — [sortTopLevel] then leaves the registration
  /// order alone.
  List<String> topLevelOrder = [];

  /// The local mirror [load] reads pages from, or null for the blob-only
  /// behaviour every construction had before rows existed.
  ///
  /// **Reads only, by convention, and the convention is the whole defence.**
  /// This is the raw [ConfigStore], not the guarded one: it has an ungated
  /// `writeItems` on it. The same [PageManager] instance is what
  /// `page_editor.dart` calls [save] through, and that write is a person
  /// editing pages — it must stay gated, and treating this field as a write
  /// path would unlock the editor for everybody. The save (03-06) goes
  /// through `GuardedConfigStore`; nothing in this class writes here.
  ///
  /// This replaces the separate bootstrap preferences handle, which existed
  /// to route [load]'s seed write away from the guarded object. That seed is
  /// deleted: a station with
  /// no stored layout wrote the built-in default at boot with nobody signed
  /// in, against a `configure` key, unawaited — so on a guarded store it was a
  /// denial prompt on every cold boot rather than a failed load. Its only
  /// purpose, that a virgin station has a Home page, is served by the
  /// in-memory default below; the first real Save persists it, gated and
  /// audited, by a person.
  final ConfigStore? store;

  /// The one route a page save takes to the shared rows, or null for the
  /// legacy blob write.
  ///
  /// Bound by `providers/page_manager.dart` to **`GuardedConfigStore.write`**
  /// over `{page, asset}`, checked and audited as `page_editor_data` — never
  /// to [store], which is the raw object and has an ungated `writeItems` on
  /// it. Editing pages is a person changing the plant's mimic and is exactly
  /// what `configure` is for, so the check is not optional and the binding is
  /// the only thing that supplies it. A [PageManager] built without one — the
  /// pre-`runApp` manager, and legacy tests — keeps today's blob write and
  /// therefore cannot reach a shared row at all.
  final Future<ConfigWriteResult> Function(List<ConfigItem> wanted,
      {String? reason})? writeItems;

  /// The page and asset rows [pages] were loaded from, as they stood then —
  /// what a save is a save *over*.
  ///
  /// Set by [load] when the rows were the source, null when they were not.
  /// [save] hands it to `mergeForSave` so that a page another station added,
  /// changed or deleted since this layout was loaded is kept, adopted or
  /// refused rather than silently replaced with the copy from an hour ago.
  /// The editor carries its own copy across the manager rebuilds a save
  /// triggers, and re-reads it after every successful save and reload.
  List<ConfigItem>? baselineItems;

  /// Where the pages in memory came from — see [PageSource].
  PageSource get source => _source;
  PageSource _source = PageSource.notLoaded;

  /// Whether [load] fell back off the rows: the blob, or the built-in default.
  ///
  /// The re-load trigger in `providers/page_manager.dart` reads this. It is a
  /// named, tested property rather than an inference from `pages.isEmpty`
  /// because the two differ exactly where it matters: on rollout day a station
  /// serving a full blob has a hundred pages and no row identities at all.
  bool get servingFallback =>
      _source == PageSource.blob || _source == PageSource.builtInDefault;

  PageManager({
    required this.pages,
    required this.prefs,
    this.store,
    this.writeItems,
  });

  /// Fills [pages] and [topLevelOrder] from the best source this station has.
  ///
  /// Order, and each step is a fallback from the one above:
  ///
  /// 1. **Rows** from [store]'s local mirror. No Postgres and no network — the
  ///    snapshot is already in memory by the time this runs.
  /// 2. **The `page_editor_data` blob** in [prefs], parsed by today's code
  ///    path. **Read-only.** Nothing is written back and no id is minted: an
  ///    asset id is derived from its content, so a station one save behind
  ///    would derive different ids for everything after the divergence point
  ///    and mint permanent ghost rows on the plant's mimic that no reconcile
  ///    has any reason to delete. The rows arrive at the next reconcile; the
  ///    blob stays where it is as rollback insurance.
  /// 3. **The built-in default layout**, in memory. Persisted nowhere — see
  ///    [store] for the seed write that used to be here and why it is gone.
  ///
  /// [topLevelOrder] is a **shared** preference row since 04-11, and is read
  /// from [store]'s mirror first: the pre-`runApp` manager is built over the
  /// device-local store, which never held the shared row — so without this
  /// read the menu came up in registration order on every restart, whatever
  /// the operator had arranged. [prefs] is the fallback, for a manager with
  /// no store and for the one-shot import of the old local copy.
  ///
  /// It does not throw. A mirror that will not read and a blob that will not
  /// parse are both logged and fallen through, because a panel that comes up
  /// degraded beats one that does not come up.
  Future<void> load() async {
    final orderJson =
        _storedTopLevelOrderJson() ?? await prefs.getString(orderStorageKey);
    if (orderJson != null) {
      try {
        topLevelOrder = (jsonDecode(orderJson) as List).cast<String>();
      } catch (_) {
        topLevelOrder = [];
      }
    }
    final defaultPages = {
      '/': AssetPage(
        menuItem: const MenuItem(label: 'Home', path: '/', icon: Icons.home),
        assets: [],
        mirroringDisabled: false,
      ),
    };

    if (_loadFromRows()) return;
    baselineItems = null;

    final jsonString = await prefs.getString(storageKey);
    if (jsonString != null) {
      try {
        fromJson(jsonString);
        if (pages.isEmpty) {
          pages = defaultPages;
          _source = PageSource.builtInDefault;
        } else {
          _source = PageSource.blob;
        }
      } catch (e) {
        _logger.e('The stored page layout could not be parsed; this station '
            'comes up on the built-in default pages and persists nothing: $e');
        pages = defaultPages;
        _source = PageSource.builtInDefault;
      }
      return;
    }

    // A station that has never stored a layout. In memory only: the seed write
    // that used to follow this line is deleted.
    fromJson(_builtInLayoutJson);
    _source = PageSource.builtInDefault;
  }

  /// Serves [pages] out of [store]'s mirror, or answers false so [load] falls
  /// through to the blob.
  ///
  /// False on all three of: no store, a store holding no page or asset rows,
  /// and rows that reassemble into no pages at all. The last is not the same
  /// as "the mirror is empty" and is treated the same way on purpose — pages
  /// that could not be rebuilt are pages this station cannot serve.
  bool _loadFromRows() {
    final store = this.store;
    if (store == null) return false;
    try {
      final items = store.itemsOf(const {ConfigKind.page, ConfigKind.asset});
      if (items.isEmpty) return false;
      final fromRows = pagesOf(items);
      if (fromRows.isEmpty) return false;
      pages = fromRows;
      baselineItems = items;
      _source = PageSource.rows;
      return true;
    } catch (e) {
      _logger.e('The mirrored page rows could not be read; this station falls '
          'back to its stored layout: $e');
      return false;
    }
  }

  /// The shared `page_editor_top_level_order` row out of [store]'s mirror, or
  /// null when there is no store, no row, or a row this build cannot read.
  String? _storedTopLevelOrderJson() {
    final store = this.store;
    if (store == null) return null;
    try {
      for (final item in store.itemsOf(const {ConfigKind.preference})) {
        if (item.id != orderStorageKey) continue;
        final value = decodePreferencePayload(item.payload);
        return value is String ? value : null;
      }
    } catch (e) {
      _logger.w('The stored menu order could not be read; falling back to '
          'the device-local copy: $e');
    }
    return null;
  }

  /// The layout a station that has never stored one comes up on.
  ///
  /// Held here rather than written anywhere. It was the *seed*: [load] used to
  /// persist it at boot with nobody signed in, which on the guarded store is a
  /// denial. Nothing writes it now — the first Save by a person does, through
  /// the gate.
  static const String _builtInLayoutJson = r'''
        {
          "Home": {
            "menu_item": {
              "label": "Home",
              "path": "/",
              "icon": "home",
              "children": []
            },
            "assets": [
              {
                "asset_name": "ButtonConfig",
                "coordinates": {
                  "x": 0.3062472475044039,
                  "y": 0.13612415997912186,
                  "angle": null
                },
                "size": {
                  "width": 0.03,
                  "height": 0.03
                },
                "text": "A button",
                "textPos": "right",
                "key": "Button preview",
                "feedback": null,
                "icon": null,
                "outward_color": {"role": "primary"},
                "inward_color": {"role": "secondary"},
                "button_type": "circle",
                "is_toggle": false
              },
              {
                "asset_name": "LEDConfig",
                "coordinates": {
                  "x": 0.3060637477980035,
                  "y": 0.23322812683499702,
                  "angle": null
                },
                "size": {
                  "width": 0.03,
                  "height": 0.03
                },
                "text": "A light",
                "textPos": "right",
                "key": "Led preview",
                "on_color": {"role": "green"},
                "off_color": {"role": "grey"},
                "led_type": "circle"
              },
              {
                "asset_name": "BeckhoffCX5010Config",
                "coordinates": {
                  "x": 0.5455216896652962,
                  "y": 0.602119625497488,
                  "angle": null
                },
                "size": {
                  "width": 0.5,
                  "height": 0.5
                },
                "text": null,
                "textPos": null,
                "subdevices": [
                  {
                    "asset_name": "BeckhoffEL1008Config",
                    "coordinates": {
                      "x": 0.0,
                      "y": 0.0,
                      "angle": null
                    },
                    "size": {
                      "width": 0.03,
                      "height": 0.03
                    },
                    "text": null,
                    "textPos": null,
                    "nameOrId": "1",
                    "descriptionsKey": null,
                    "rawStateKey": null,
                    "processedStateKey": null,
                    "forceValuesKey": null,
                    "onFiltersKey": null,
                    "offFiltersKey": null
                  },
                  {
                    "asset_name": "BeckhoffEL2008Config",
                    "coordinates": {
                      "x": 0.0,
                      "y": 0.0,
                      "angle": null
                    },
                    "size": {
                      "width": 0.03,
                      "height": 0.03
                    },
                    "text": null,
                    "textPos": null,
                    "nameOrId": "1",
                    "descriptionsKey": null,
                    "rawStateKey": null,
                    "forceValuesKey": null
                  }
                ]
              }
            ],
            "mirroring_disabled": false,
            "navigation_priority": 0
          }
        }
      ''';

  /// Persists [pages] and [topLevelOrder] — rows when [writeItems] is bound,
  /// the `page_editor_data` blob when it is not.
  ///
  /// Returns what the write actually did, or null on the legacy blob path.
  /// The caller must treat a return as the only evidence of success and an
  /// exception as the only evidence of failure: `ConfigStoreOfflineException`,
  /// `ConfigConflict` and `AccessDenied` all propagate unwrapped, and the
  /// editor's three arms are those three types. A green snackbar over a write
  /// that reached nothing is C-11, and it is what this shape prevents.
  ///
  /// **[topLevelOrder] is written after the rows.** It is a shared row of its
  /// own, in its own transaction, and a page write can be refused — offline,
  /// a lost compare-and-swap, a merge conflict. Written first, a refused save
  /// left every station's menu in an order describing a layout that never
  /// landed. Written after, a refused save leaves nothing changed, and a menu
  /// order that fails after the rows landed is a cosmetic complaint rather
  /// than the wrong plant on the screen. The empty-order guard is unchanged.
  ///
  /// The items handed over are **merged** against what the store holds now,
  /// with [baselineItems] as what this layout was loaded from — see
  /// `mergeForSave`. That is what turns "replace within kinds" into "replace
  /// what this editor was shown", and it is what refuses, as a
  /// `ConfigConflict`, a page that moved on another station while it was also
  /// edited here.
  ///
  /// The blob is **not** dual-written on the rows path. Two records of one
  /// layout are two records that can disagree, and the blob's readers go
  /// through the compatibility view instead.
  Future<ConfigWriteResult?> save({String? reason}) async {
    final writeItems = this.writeItems;
    if (writeItems == null) {
      await prefs.setString(storageKey, toJson());
      await _saveTopLevelOrder();
      return null;
    }

    _adoptStoredIdentities();
    var items = pageItems(pages);
    final store = this.store;
    if (store != null) {
      items = mergeForSave(
        wanted: items,
        stored: store.itemsOf(const {ConfigKind.page, ConfigKind.asset}),
        baseline: baselineItems,
      );
    }
    final result = await writeItems(items, reason: reason);
    await _saveTopLevelOrder();
    return result;
  }

  /// An empty order is never worth writing: it only arises on a manager that
  /// was constructed without load(), and writing it would wipe an order some
  /// other session already stored.
  Future<void> _saveTopLevelOrder() async {
    if (topLevelOrder.isEmpty) return;
    await prefs.setString(orderStorageKey, jsonEncode(topLevelOrder));
  }

  /// Rollout day, at the save: takes the ids off the rows before building the
  /// items, so a layout loaded from the blob does not mint a second set of
  /// identities over the ones the migration just wrote.
  ///
  /// See [adoptRowIdentities] for what it matches and why it copies rather
  /// than derives. A no-op in every other state, including a store this
  /// station cannot read: the fallback there is a save that mints, which is
  /// the behaviour without this and no worse for having tried.
  void _adoptStoredIdentities() {
    final store = this.store;
    if (store == null) return;
    try {
      adoptRowIdentities(
          pages, store.itemsOf(const {ConfigKind.page, ConfigKind.asset}));
    } catch (e) {
      _logger.e('The stored page identities could not be read before saving; '
          'this save mints ids for any page that has none: $e');
    }
  }

  /// Reorders [items] in place to match [topLevelOrder].
  ///
  /// Meant for the app's fully registered top-level menu list, after every
  /// destination — pages and built-ins alike — has been added. Items the
  /// stored order does not know (a page created since, a destination added in
  /// an app update) keep their relative registration order at the end.
  void sortTopLevel(List<MenuItem> items) {
    if (topLevelOrder.isEmpty) return;
    final rank = <String, int>{
      for (var i = 0; i < topLevelOrder.length; i++) topLevelOrder[i]: i,
    };
    final decorated = [
      for (var i = 0; i < items.length; i++)
        (
          item: items[i],
          rank: rank[items[i].path] ?? topLevelOrder.length + i,
          tie: i,
        ),
    ];
    // sort() is not stable; the original index breaks ties deterministically.
    decorated.sort((a, b) => a.rank != b.rank
        ? a.rank.compareTo(b.rank)
        : a.tie.compareTo(b.tie));
    items
      ..clear()
      ..addAll(decorated.map((d) => d.item));
  }

  String toJson() {
    // Key by path (the unique identifier)
    return jsonEncode(pages.map((path, page) => MapEntry(path, page.toJson())));
  }

  void fromJson(String jsonString) {
    pages = PageManager.pagesFromJson(jsonString);
  }

  PageManager copyWith({
    Map<String, AssetPage>? otherPages,
  }) {
    final manager = PageManager(
      pages: otherPages ?? pages,
      prefs: prefs,
      // Carried, or the copy would silently drop back to blob-only behaviour
      // — the field-by-field rebuild trap [AssetPage.copyWith] documents,
      // one level up.
      store: store,
      // Same reason, and sharper: a copy that dropped this would write the
      // blob instead of the rows and nothing would say so.
      writeItems: writeItems,
    );
    final json = manager.toJson();
    manager.fromJson(json);
    manager._source = _source;
    manager.baselineItems = baselineItems;
    return manager;
  }

  static Map<String, AssetPage> copyPages(Map<String, AssetPage> otherPages) {
    final json = jsonEncode(
        otherPages.map((name, page) => MapEntry(name, page.toJson())));
    return pagesFromJson(json);
  }

  /// Returns fully resolved root menu items with children looked up
  /// from the flat map so nested sections have their actual children.
  ///
  /// Unpublished pages are left out entirely — see [AssetPage.published]. This
  /// is the single gate: the app builds both the navigation menu and the route
  /// table from what this returns, so a draft page is neither listed nor
  /// addressable until it is published.
  List<MenuItem> getRootMenuItems() {
    final childPaths = <String>{};
    for (final entry in pages.entries) {
      collectChildPaths(entry.value.menuItem.children, childPaths, entry.key);
    }
    final rootPaths = pages.keys
        .where((path) => !childPaths.contains(path))
        .where((path) => pages[path]?.published ?? true)
        .toList();
    rootPaths.sort((a, b) => (pages[a]?.navigationPriority ?? 0)
        .compareTo(pages[b]?.navigationPriority ?? 0));
    return rootPaths.map((path) => _resolveMenuItem(path)).toList();
  }

  /// Recursively resolves a page's MenuItem by looking up each child
  /// from the flat map to get its current children list.
  MenuItem _resolveMenuItem(String pagePath) {
    final page = pages[pagePath]!;
    final resolvedChildren = <MenuItem>[];
    for (final child in page.menuItem.children) {
      final childPath = child.path ?? '';
      // Don't recurse into self-references
      if (childPath == pagePath) {
        resolvedChildren.add(child);
        continue;
      }
      // Resolve from the flat map if the child exists there
      final childPage = pages[childPath];
      if (childPage != null) {
        // A draft child drops out of the menu, and its own subtree with it.
        if (!childPage.published) continue;
        resolvedChildren.add(_resolveMenuItem(childPath));
        continue;
      }
      // A child that is not one of our pages belongs to whoever registered it
      // (the app's own routes); publishing does not apply to those.
      resolvedChildren.add(child);
    }
    return page.menuItem.copyWith(children: resolvedChildren);
  }

  static void collectChildPaths(
      List<MenuItem> items, Set<String> paths, String excludeKey) {
    for (final item in items) {
      final itemPath = item.path ?? '';
      if (itemPath.isNotEmpty && itemPath != excludeKey) {
        paths.add(itemPath);
      }
      collectChildPaths(item.children, paths, excludeKey);
    }
  }

  /// Sentinel priority that sorts after every real sibling index, used to park
  /// a just-moved page at the end of its new level before renumbering.
  static const int _lastPriority = 1 << 30;

  static AssetPage _copyPage(
    AssetPage page, {
    MenuItem? menuItem,
    int? navigationPriority,
  }) {
    return page.copyWith(
      menuItem: menuItem,
      navigationPriority: navigationPriority,
    );
  }

  /// Whether [candidate] sits anywhere beneath [ancestor] in the page tree.
  ///
  /// Used to refuse a move that would drop a section inside itself, which
  /// would detach the whole subtree from the roots and make it unreachable.
  static bool isDescendantOf(
    Map<String, AssetPage> pages, {
    required String ancestor,
    required String candidate,
  }) {
    final seen = <String>{ancestor};
    final queue = <String>[ancestor];
    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      for (final child in pages[current]?.menuItem.children ?? const []) {
        final path = child.path;
        // A section may list itself as a child — that self-reference is the
        // section's own landing page, not a step down the tree.
        if (path == null || path.isEmpty || path == current) continue;
        if (path == candidate) return true;
        if (seen.add(path)) queue.add(path);
      }
    }
    return false;
  }

  /// Moves [pagePath] out of whatever section holds it and appends it to
  /// [newParentPath] — or to the top level when that is null.
  ///
  /// Nesting lives in the `children` lists, not in the paths: routes are
  /// registered flat, keyed by path, so a moved page keeps its address and
  /// every link, bookmark and asset that points at it stays valid.
  ///
  /// Returns a new map; [pages] and the pages inside it are not modified. The
  /// move is refused — the input is returned unchanged — when the page is
  /// unknown, the destination is unknown or is not a section, or the
  /// destination sits inside the page being moved.
  static Map<String, AssetPage> movePage(
    Map<String, AssetPage> pages, {
    required String pagePath,
    required String? newParentPath,
  }) {
    final moved = pages[pagePath];
    if (moved == null) return pages;
    if (newParentPath != null) {
      final target = pages[newParentPath];
      if (target == null || newParentPath == pagePath) return pages;
      if (!target.menuItem.isNavigationSection) return pages;
      if (isDescendantOf(pages, ancestor: pagePath, candidate: newParentPath)) {
        return pages;
      }
    }

    final result = Map<String, AssetPage>.from(pages);

    // Detach from its current home. Every children list is swept rather than
    // just the known parent's, so a page that was accidentally listed twice
    // ends up in exactly one place afterwards. The page's own entry is skipped
    // so a section keeps its self-referencing landing page.
    for (final entry in pages.entries) {
      if (entry.key == pagePath) continue;
      final pruned = _withoutPath(entry.value.menuItem.children, pagePath);
      if (pruned == null) continue;
      result[entry.key] = _copyPage(
        entry.value,
        menuItem: entry.value.menuItem.copyWith(children: pruned),
      );
    }

    if (newParentPath != null) {
      final parent = result[newParentPath]!;
      result[newParentPath] = _copyPage(
        parent,
        menuItem: parent.menuItem.copyWith(
          children: [...parent.menuItem.children, moved.menuItem],
        ),
      );
    }
    // Land last among the new siblings; _renumber turns this into an index.
    result[pagePath] =
        _copyPage(result[pagePath]!, navigationPriority: _lastPriority);

    return _renumber(result);
  }

  /// Drops every [MenuItem] pointing at [path], at any depth. Returns null
  /// when nothing matched, so callers can skip rebuilding untouched pages.
  static List<MenuItem>? _withoutPath(List<MenuItem> children, String path) {
    var changed = false;
    final result = <MenuItem>[];
    for (final child in children) {
      if (child.path == path) {
        changed = true;
        continue;
      }
      final pruned = _withoutPath(child.children, path);
      if (pruned != null) {
        changed = true;
        result.add(child.copyWith(children: pruned));
      } else {
        result.add(child);
      }
    }
    return changed ? result : null;
  }

  /// Rewrites every [AssetPage.navigationPriority] from the tree structure, so
  /// each level is numbered 0..n-1 with no gaps or duplicates after a move.
  ///
  /// **Dense on purpose**, unlike the gapped `sort_index` the asset rows use.
  /// Renumbering rewrites every sibling, so one move dirties several pages —
  /// but there are nine of them and the worst move touches about five, while
  /// `navigation_priority` lives *inside* the page payload that
  /// `tfc_mcp_server` and the `tools/svn_*.py` scripts read. Gapping it would
  /// change that compatibility blob for a saving no page count here can feel.
  /// Revisit if pages ever number in the hundreds.
  static Map<String, AssetPage> _renumber(Map<String, AssetPage> pages) {
    final result = Map<String, AssetPage>.from(pages);

    for (final entry in pages.entries) {
      final children = entry.value.menuItem.children;
      for (var i = 0; i < children.length; i++) {
        final path = children[i].path;
        // Self-references order with the section itself, not against it.
        if (path == null || path == entry.key) continue;
        final child = result[path];
        if (child == null) continue;
        result[path] = _copyPage(child, navigationPriority: i);
      }
    }

    final childPaths = <String>{};
    for (final entry in result.entries) {
      collectChildPaths(entry.value.menuItem.children, childPaths, entry.key);
    }
    final insertionOrder = result.keys.toList();
    final roots =
        insertionOrder.where((path) => !childPaths.contains(path)).toList();
    roots.sort((a, b) {
      final pa = result[a]!.navigationPriority ?? _lastPriority;
      final pb = result[b]!.navigationPriority ?? _lastPriority;
      // Ties keep map order: sort() is not stable, and equal priorities are
      // common in data written before priorities existed.
      return pa != pb
          ? pa.compareTo(pb)
          : insertionOrder.indexOf(a).compareTo(insertionOrder.indexOf(b));
    });
    for (var i = 0; i < roots.length; i++) {
      result[roots[i]] = _copyPage(result[roots[i]]!, navigationPriority: i);
    }

    return result;
  }

  /// A path for a page whose payload has none, derived from whatever key it
  /// arrived under.
  ///
  /// Two path-less pages would otherwise both key on `''` and one would
  /// silently overwrite the other. Public because `page_codec.dart`'s
  /// `pagesOf` reassembles the same map from rows and has to reach the same
  /// key for the same page — one implementation, not two that can drift.
  ///
  /// Delegates to `page_rows.dart` rather than slugifying here, because the
  /// same fallback now decides the key on the other side of the wire too: the
  /// MCP server reassembles the pages map out of `config_item` rows without
  /// Flutter, and an app and a server that slugified differently would
  /// disagree about which page is which for exactly the pages nobody named.
  static String fallbackPathFor(String key) => fallbackPagePathFor(key);

  /// Decodes an encoded page map — the inverse of [toJson]. Public because
  /// the editor keeps its undo history as encoded strings (cheap to snapshot)
  /// and only pays for this decode when an undo actually fires.
  static Map<String, AssetPage> pagesFromJson(String jsonString) {
    final json = jsonDecode(jsonString) as Map<String, dynamic>;
    final result = <String, AssetPage>{};
    for (final entry in json.entries) {
      final page = AssetPage.fromJson(entry.value as Map<String, dynamic>);
      final path = page.menuItem.path;
      // Use the path from menu_item as the key.
      // For backward compat: if path is empty (old sections), generate one.
      final key = (path != null && path.isNotEmpty)
          ? path
          : fallbackPathFor(entry.key);
      // If the page had an empty path, update the menuItem with the generated path
      if (path == null || path.isEmpty) {
        result[key] = page.copyWith(menuItem: page.menuItem.copyWith(path: key));
      } else {
        result[key] = page;
      }
    }
    return result;
  }
}

class CreatePageWidget extends StatefulWidget {
  final AssetPage? initialPage;

  /// Applies the edit. Returns false when the caller refused it — a path that
  /// is already taken, say — which keeps this dialog open with the operator's
  /// text still in it instead of closing over a change that never landed.
  final bool Function(AssetPage) onSave;
  final bool isSection;
  final String basePath;

  /// What else changing the address costs, in the caller's words — e.g. that
  /// this station's startup page points at the page being renamed. Shown
  /// under the address checkbox once it is ticked.
  final String? addressChangeNote;

  /// Whether the address may be moved at all. False where the caller cannot
  /// carry the move through — a section's own landing page is keyed by the
  /// section's address, so changing one without the other only detaches it.
  final bool allowAddressChange;

  const CreatePageWidget({
    super.key,
    this.initialPage,
    required this.onSave,
    this.isSection = false,
    this.basePath = '',
    this.addressChangeNote,
    this.allowAddressChange = true,
  });

  @override
  State<CreatePageWidget> createState() => _CreatePageWidgetState();
}

class _CreatePageWidgetState extends State<CreatePageWidget> {
  late TextEditingController _labelController;
  late IconData _selectedIcon;
  late bool _mirroringDisabled;
  late bool _zoomPanDisabled;
  late bool _published;

  /// Whether an existing page's address should follow its new name.
  ///
  /// Off by default: the address is what links, bookmarks and the station's
  /// startup setting point at, so renaming for readability must not quietly
  /// move the page out from under them. Ignored when creating, where there is
  /// no old address to keep.
  bool _changeAddress = false;

  @override
  void initState() {
    super.initState();
    _labelController =
        TextEditingController(text: widget.initialPage?.menuItem.label ?? '');
    _labelController.addListener(_onLabelChanged);
    _selectedIcon = widget.initialPage?.menuItem.icon ??
        (widget.isSection ? Icons.folder : Icons.pageview);
    _mirroringDisabled = widget.initialPage?.mirroringDisabled ?? false;
    _zoomPanDisabled = widget.initialPage?.zoomPanDisabled ?? false;
    _published = widget.initialPage?.published ?? true;
  }

  /// The address this page already has, or null when it is being created.
  String? get _existingPath => widget.initialPage?.menuItem.path;

  /// Redraws the address preview as the name is typed.
  void _onLabelChanged() {
    if (_existingPath == null) return;
    setState(() {});
  }

  /// The address [label] would produce, ignoring whether it is being applied.
  String _slugPath(String label) {
    final slug = label
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s]'), '')
        .replaceAll(RegExp(r'\s+'), '-');
    final base = widget.basePath;
    return slug.isEmpty ? '$base/' : '$base/$slug';
  }

  /// The address to save: the derived one when creating or when the operator
  /// asked for it, and otherwise the address the page already had.
  String _buildPath(String label) {
    final existing = _existingPath;
    if (existing != null && !_changeAddress) return existing;
    return _slugPath(label);
  }

  @override
  void dispose() {
    _labelController.removeListener(_onLabelChanged);
    _labelController.dispose();
    super.dispose();
  }

  void _showIconPicker() {
    // Pre-build icon name pairs for searching
    final iconEntries = iconList.map((icon) {
      final name = IconDataConverter.getIconName(icon);
      return (icon: icon, name: name);
    }).toList();

    showDialog(
      context: context,
      builder: (context) {
        return _IconPickerDialog(
          iconEntries: iconEntries,
          onSelected: (icon) {
            setState(() {
              _selectedIcon = icon;
            });
            Navigator.pop(context);
          },
        );
      },
    );
  }

  /// The page's address, and — when editing — the opt-in to move it.
  ///
  /// A page being created has no address worth showing: it is derived from
  /// the name and nothing points at it yet.
  Widget _buildAddressSection(BuildContext context) {
    final existing = _existingPath;
    if (existing == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    if (!widget.allowAddressChange) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Address', style: theme.textTheme.labelMedium),
            Text(existing,
                key: const ValueKey('page-address-preview'),
                style: theme.textTheme.bodyMedium),
          ],
        ),
      );
    }

    final proposed = _slugPath(_labelController.text.trim());
    final wouldMove = _changeAddress && proposed != existing;

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Address', style: theme.textTheme.labelMedium),
          Text(
            _changeAddress ? proposed : existing,
            key: const ValueKey('page-address-preview'),
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
              color: wouldMove ? theme.colorScheme.error : null,
            ),
          ),
          CheckboxListTile(
            key: const ValueKey('page-address-change'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
            value: _changeAddress,
            onChanged: (value) =>
                setState(() => _changeAddress = value ?? false),
            title: const Text('Also update the address'),
            subtitle: Text(
              _changeAddress
                  ? _addressWarning(existing, proposed)
                  : 'Renaming leaves the address alone, so links and this '
                      'station\'s startup setting keep working.',
            ),
          ),
        ],
      ),
    );
  }

  /// What ticking the address box actually does, spelled out.
  String _addressWarning(String existing, String proposed) {
    if (proposed == existing) {
      return 'This name gives the same address, so nothing moves.';
    }
    final note = widget.addressChangeNote;
    return 'Moves $existing to $proposed. Anything pointing at the old '
        'address stops working.${note == null ? '' : ' $note'}';
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _labelController,
            decoration: InputDecoration(
                labelText: widget.isSection ? 'Section Name' : 'Page Name'),
          ),
          _buildAddressSection(context),
          const SizedBox(height: 16),
          Row(
            children: [
              const Text('Icon: '),
              Icon(_selectedIcon),
              IconButton(
                icon: const Icon(Icons.edit),
                onPressed: _showIconPicker,
              ),
            ],
          ),
          if (!widget.isSection) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                const Text('Mirroring Disabled: '),
                Switch(
                    value: _mirroringDisabled,
                    onChanged: (value) {
                      setState(() {
                        _mirroringDisabled = value;
                      });
                    }),
              ],
            ),
            Row(
              children: [
                const Text('Zoom and Pan Disabled: '),
                Switch(
                    key: const ValueKey('page-zoom-pan-disabled'),
                    value: _zoomPanDisabled,
                    onChanged: (value) {
                      setState(() {
                        _zoomPanDisabled = value;
                      });
                    }),
              ],
            ),
          ],
          const SizedBox(height: 16),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Published'),
            subtitle: Text(
              _published
                  ? (widget.isSection
                      ? 'Operators see this section in the menu.'
                      : 'Operators can navigate to this page.')
                  : 'Draft — hidden from the menu and not reachable by route. '
                      '${widget.isSection ? 'Everything inside it is hidden too. ' : ''}'
                      'It stays here in the editor.',
            ),
            value: _published,
            onChanged: (value) => setState(() => _published = value),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () {
                  final label = _labelController.text.trim();
                  if (label.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Name cannot be empty')),
                    );
                    return;
                  }
                  final menuItem = MenuItem(
                    label: label,
                    path: _buildPath(label),
                    icon: _selectedIcon,
                    // Preserve existing children from the tree structure
                    children: widget.initialPage?.menuItem.children ?? const [],
                    // Persist section-ness so an empty section stays a
                    // section instead of collapsing back into a page.
                    isSection: widget.isSection ||
                        (widget.initialPage?.menuItem.isSection ?? false),
                  );
                  final page = AssetPage(
                    menuItem: menuItem,
                    assets: widget.initialPage?.assets ?? [],
                    // The row's identity, or the settings edit turns into a delete and a
                    // re-insert that restamps every asset on the page — the field-by-field
                    // rebuild trap [AssetPage.copyWith]'s doc names.
                    id: widget.initialPage?.id,
                    mirroringDisabled: _mirroringDisabled,
                    zoomPanDisabled: _zoomPanDisabled,
                    navigationPriority: widget.initialPage?.navigationPriority,
                    published: _published,
                  );
                  // Closing on a refused edit used to throw the operator's
                  // typing away behind a SnackBar they never got to act on.
                  if (!widget.onSave(page)) return;
                  Navigator.pop(context);
                },
                child: Text(widget.initialPage != null ? 'Update' : 'Create'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

typedef _IconEntry = ({IconData icon, String name});

class _IconPickerDialog extends StatefulWidget {
  final List<_IconEntry> iconEntries;
  final ValueChanged<IconData> onSelected;

  const _IconPickerDialog({
    required this.iconEntries,
    required this.onSelected,
  });

  @override
  State<_IconPickerDialog> createState() => _IconPickerDialogState();
}

class _IconPickerDialogState extends State<_IconPickerDialog> {
  final _searchController = TextEditingController();
  List<_IconEntry> _filtered = [];

  @override
  void initState() {
    super.initState();
    _filtered = widget.iconEntries;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    setState(() {
      _filtered = fuzzyFilter(widget.iconEntries, query,
          [(entry) => entry.name.replaceAll('_', ' ')]);
    });
  }

  @override
  Widget build(BuildContext context) {
    return StandardDialogFrame(
      title: 'Select icon',
      icon: Icons.emoji_symbols,
      width: 400,
      child: SizedBox(
        width: 350,
        height: 450,
        child: Column(
          children: [
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search icons...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          _onSearchChanged('');
                        },
                      )
                    : null,
                isDense: true,
              ),
              onChanged: _onSearchChanged,
              autofocus: true,
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _filtered.isEmpty
                  ? const Center(child: Text('No icons found'))
                  : GridView.builder(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 5,
                        childAspectRatio: 0.8,
                      ),
                      itemCount: _filtered.length,
                      itemBuilder: (context, index) {
                        final entry = _filtered[index];
                        final displayName = entry.name.replaceAll('_', ' ');
                        return Tooltip(
                          message: displayName,
                          child: InkWell(
                            onTap: () => widget.onSelected(entry.icon),
                            borderRadius: BorderRadius.circular(8),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(entry.icon, size: 28),
                                const SizedBox(height: 2),
                                Text(
                                  displayName,
                                  style: const TextStyle(fontSize: 9),
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

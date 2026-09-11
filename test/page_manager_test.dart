import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/page.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:tfc/core/config/page_codec.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_store.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/preferences.dart';

/// Minimal in-memory implementation of PreferencesApi for tests.
class FakePreferences implements PreferencesApi {
  final Map<String, Object> _store = {};

  /// Every key this store was asked to write, in order.
  ///
  /// The blob fallback is read-only by construction and this is how that is
  /// asserted rather than assumed: a re-home would show up here as a
  /// `page_editor_data` entry, and the deleted seed write would too.
  final List<String> writes = [];

  @override
  Future<String?> getString(String key) async => _store[key] as String?;
  @override
  Future<void> setString(String key, String value) async {
    writes.add(key);
    _store[key] = value;
  }
  @override
  Future<Set<String>> getKeys({Set<String>? allowList}) async =>
      _store.keys.toSet();
  @override
  Future<Map<String, Object?>> getAll({Set<String>? allowList}) async =>
      Map.from(_store);
  @override
  Future<bool?> getBool(String key) async => _store[key] as bool?;
  @override
  Future<int?> getInt(String key) async => _store[key] as int?;
  @override
  Future<double?> getDouble(String key) async => _store[key] as double?;
  @override
  Future<List<String>?> getStringList(String key) async =>
      _store[key] as List<String>?;
  @override
  Future<bool> containsKey(String key) async => _store.containsKey(key);
  @override
  Future<void> setBool(String key, bool value) async {
    writes.add(key);
    _store[key] = value;
  }
  @override
  Future<void> setInt(String key, int value) async {
    writes.add(key);
    _store[key] = value;
  }
  @override
  Future<void> setDouble(String key, double value) async {
    writes.add(key);
    _store[key] = value;
  }
  @override
  Future<void> setStringList(String key, List<String> value) async {
    writes.add(key);
    _store[key] = value;
  }
  @override
  Future<void> remove(String key) async => _store.remove(key);
  @override
  Future<void> clear({Set<String>? allowList}) async {
    if (allowList == null) {
      _store.clear();
    } else {
      _store.removeWhere((k, _) => allowList.contains(k));
    }
  }
}

// ── Helpers ──────────────────────────────────────────────────────────────────

AssetPage _page(String label, String path,
    {List<MenuItem> children = const [], int? priority}) {
  return AssetPage(
    menuItem: MenuItem(
      label: label,
      path: path,
      icon: Icons.pageview,
      children: children,
    ),
    assets: [],
    mirroringDisabled: false,
    navigationPriority: priority,
  );
}

MenuItem _menuRef(String label, String path) {
  return MenuItem(label: label, path: path, icon: Icons.pageview);
}

/// A raw [ConfigStore] over two in-memory databases, with [pages] already in
/// its mirror.
///
/// The remote is only there because a write has to go somewhere: `writeItems`
/// refuses offline. Once the rows are in, `load()` reads them out of the
/// snapshot with nothing attached — which is the point of SC-5.
Future<ConfigStore> _storeHolding(Map<String, AssetPage> pages,
    {bool attachRemote = false}) async {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final local = AppDatabase.inMemoryForTest();
  final remote = AppDatabase.inMemoryForTest();
  addTearDown(local.close);
  addTearDown(remote.close);

  final store = ConfigStore(
    local: local,
    stationScope: ConfigScope.forStation('test-station'),
    station: 'test-station',
  );
  addTearDown(store.close);
  await store.open();
  // A save needs somewhere to write, and `writeItems` refuses offline —
  // that is the only reason the stand-in remote is ever attached here.
  if (attachRemote) store.attachRemoteDatabase(remote, startSync: false);
  if (pages.isNotEmpty) {
    if (!attachRemote) store.attachRemoteDatabase(remote, startSync: false);
    await store.writeItems(
      kinds: const {ConfigKind.page, ConfigKind.asset},
      wanted: pageItems(pages),
      actionId: 'test-seed',
      who: 'test',
      roleName: 'system',
    );
  }
  return store;
}

PageManager _manager({Map<String, AssetPage>? pages}) {
  return PageManager(
    pages: pages ?? {},
    prefs: FakePreferences(),
  );
}

// ── Tests ────────────────────────────────────────────────────────────────────

void main() {
  group('PageManager keying by path', () {
    test('pages are keyed by path, not label', () {
      final mgr = _manager(pages: {
        '/': _page('Home', '/'),
        '/settings': _page('Settings', '/settings'),
      });

      expect(mgr.pages.containsKey('/'), isTrue);
      expect(mgr.pages.containsKey('/settings'), isTrue);
      expect(mgr.pages['/']!.menuItem.label, 'Home');
    });

    test('same label under different sections produces distinct keys', () {
      // This is the exact bug scenario: two pages named "roe" in different sections
      final mgr = _manager(pages: {
        '/section-a': _page('Section A', '/section-a', children: [
          _menuRef('roe', '/section-a/roe'),
        ]),
        '/section-a/roe': _page('roe', '/section-a/roe'),
        '/section-b': _page('Section B', '/section-b', children: [
          _menuRef('roe', '/section-b/roe'),
        ]),
        '/section-b/roe': _page('roe', '/section-b/roe'),
      });

      expect(mgr.pages.length, 4);
      expect(mgr.pages.containsKey('/section-a/roe'), isTrue);
      expect(mgr.pages.containsKey('/section-b/roe'), isTrue);
      // Both pages exist independently
      expect(mgr.pages['/section-a/roe']!.menuItem.label, 'roe');
      expect(mgr.pages['/section-b/roe']!.menuItem.label, 'roe');
    });
  });

  group('toJson / fromJson round-trip', () {
    test('single page survives round-trip', () {
      final mgr = _manager(pages: {
        '/': _page('Home', '/'),
      });
      final json = mgr.toJson();
      mgr.fromJson(json);

      expect(mgr.pages.length, 1);
      expect(mgr.pages.containsKey('/'), isTrue);
      expect(mgr.pages['/']!.menuItem.label, 'Home');
      expect(mgr.pages['/']!.menuItem.path, '/');
    });

    test('multiple pages with same label survive round-trip', () {
      final mgr = _manager(pages: {
        '/section-a/roe': _page('roe', '/section-a/roe'),
        '/section-b/roe': _page('roe', '/section-b/roe'),
      });
      final json = mgr.toJson();
      mgr.fromJson(json);

      expect(mgr.pages.length, 2);
      expect(mgr.pages.containsKey('/section-a/roe'), isTrue);
      expect(mgr.pages.containsKey('/section-b/roe'), isTrue);
    });

    test('section with children survives round-trip', () {
      final mgr = _manager(pages: {
        '/diagnostics': _page('Diagnostics', '/diagnostics', children: [
          _menuRef('IOs', '/diagnostics/ios'),
          _menuRef('Motors', '/diagnostics/motors'),
        ]),
        '/diagnostics/ios': _page('IOs', '/diagnostics/ios'),
        '/diagnostics/motors': _page('Motors', '/diagnostics/motors'),
      });
      final json = mgr.toJson();
      mgr.fromJson(json);

      expect(mgr.pages.length, 3);
      final section = mgr.pages['/diagnostics']!;
      expect(section.menuItem.children.length, 2);
      expect(section.menuItem.children[0].path, '/diagnostics/ios');
      expect(section.menuItem.children[1].path, '/diagnostics/motors');
    });

    test('toJson uses path as JSON key', () {
      final mgr = _manager(pages: {
        '/my-page': _page('My Page', '/my-page'),
      });
      final decoded = jsonDecode(mgr.toJson()) as Map<String, dynamic>;
      expect(decoded.containsKey('/my-page'), isTrue);
    });
  });

  group('backward compatibility (_fromJson)', () {
    test('old format with label keys and path in menu_item', () {
      // Old format: JSON key is the label, but menu_item.path exists
      final oldJson = jsonEncode({
        'Home': {
          'menu_item': {
            'label': 'Home',
            'path': '/',
            'icon': 'home',
            'children': [],
          },
          'assets': [],
          'mirroring_disabled': false,
          'navigation_priority': 0,
        },
        'Settings': {
          'menu_item': {
            'label': 'Settings',
            'path': '/settings',
            'icon': 'settings',
            'children': [],
          },
          'assets': [],
          'mirroring_disabled': false,
        },
      });

      final mgr = _manager();
      mgr.fromJson(oldJson);

      // Should be keyed by path from menu_item, not the JSON key
      expect(mgr.pages.containsKey('/'), isTrue);
      expect(mgr.pages.containsKey('/settings'), isTrue);
      expect(mgr.pages.containsKey('Home'), isFalse);
      expect(mgr.pages.containsKey('Settings'), isFalse);
    });

    test('old section with empty path gets a generated path', () {
      final oldJson = jsonEncode({
        'Diagnostics': {
          'menu_item': {
            'label': 'Diagnostics',
            'path': '',
            'icon': 'folder',
            'children': [],
          },
          'assets': [],
          'mirroring_disabled': false,
        },
      });

      final mgr = _manager();
      mgr.fromJson(oldJson);

      // Should generate /diagnostics from the JSON key "Diagnostics"
      expect(mgr.pages.containsKey('/diagnostics'), isTrue);
      expect(mgr.pages['/diagnostics']!.menuItem.label, 'Diagnostics');
      // The menu_item path should be updated too
      expect(mgr.pages['/diagnostics']!.menuItem.path, '/diagnostics');
    });

    test('old section with null path gets a generated path', () {
      final oldJson = jsonEncode({
        'My Section': {
          'menu_item': {
            'label': 'My Section',
            'icon': 'folder',
            'children': [],
          },
          'assets': [],
          'mirroring_disabled': false,
        },
      });

      final mgr = _manager();
      mgr.fromJson(oldJson);

      expect(mgr.pages.containsKey('/my-section'), isTrue);
      expect(mgr.pages['/my-section']!.menuItem.path, '/my-section');
    });
  });

  group('getRootMenuItems', () {
    test('returns only root pages (not referenced as children)', () {
      final mgr = _manager(pages: {
        '/': _page('Home', '/', priority: 0),
        '/diagnostics': _page('Diagnostics', '/diagnostics',
            children: [_menuRef('IOs', '/diagnostics/ios')], priority: 1),
        '/diagnostics/ios': _page('IOs', '/diagnostics/ios', priority: 0),
      });

      final roots = mgr.getRootMenuItems();
      expect(roots.length, 2);
      expect(roots[0].label, 'Home');
      expect(roots[1].label, 'Diagnostics');
    });

    test('root items are sorted by navigation priority', () {
      final mgr = _manager(pages: {
        '/b': _page('B', '/b', priority: 2),
        '/a': _page('A', '/a', priority: 0),
        '/c': _page('C', '/c', priority: 1),
      });

      final roots = mgr.getRootMenuItems();
      expect(roots.map((r) => r.label).toList(), ['A', 'C', 'B']);
    });

    test('children are resolved from the flat map', () {
      final mgr = _manager(pages: {
        '/section': _page('Section', '/section', children: [
          _menuRef('Page A', '/section/a'),
          _menuRef('Page B', '/section/b'),
        ]),
        '/section/a': _page('Page A', '/section/a', children: [
          _menuRef('Sub', '/section/a/sub'),
        ]),
        '/section/b': _page('Page B', '/section/b'),
        '/section/a/sub': _page('Sub', '/section/a/sub'),
      });

      final roots = mgr.getRootMenuItems();
      expect(roots.length, 1);
      final section = roots[0];
      expect(section.children.length, 2);
      // Page A should have its sub-child resolved
      final pageA = section.children[0];
      expect(pageA.children.length, 1);
      expect(pageA.children[0].label, 'Sub');
    });
  });

  group('copyPages', () {
    test('produces a deep copy', () {
      final original = {
        '/': _page('Home', '/'),
        '/foo': _page('Foo', '/foo'),
      };
      final copy = PageManager.copyPages(original);

      expect(copy.length, 2);
      expect(copy.containsKey('/'), isTrue);
      expect(copy.containsKey('/foo'), isTrue);
      // Verify it's a different map instance
      expect(identical(copy, original), isFalse);
    });

    test('copy preserves children references', () {
      final original = {
        '/section': _page('Section', '/section', children: [
          _menuRef('Child', '/section/child'),
        ]),
        '/section/child': _page('Child', '/section/child'),
      };
      final copy = PageManager.copyPages(original);

      expect(copy['/section']!.menuItem.children.length, 1);
      expect(copy['/section']!.menuItem.children[0].path, '/section/child');
    });
  });

  group('collectChildPaths', () {
    test('collects paths from flat children list', () {
      final children = [
        _menuRef('A', '/a'),
        _menuRef('B', '/b'),
      ];
      final paths = <String>{};
      PageManager.collectChildPaths(children, paths, '/parent');
      expect(paths, {'/a', '/b'});
    });

    test('excludes self-references', () {
      final children = [
        _menuRef('Self', '/parent'),
        _menuRef('Other', '/other'),
      ];
      final paths = <String>{};
      PageManager.collectChildPaths(children, paths, '/parent');
      expect(paths, {'/other'});
    });

    test('collects nested children recursively', () {
      final children = [
        MenuItem(
          label: 'Parent',
          path: '/a',
          icon: Icons.pageview,
          children: [_menuRef('Nested', '/a/nested')],
        ),
      ];
      final paths = <String>{};
      PageManager.collectChildPaths(children, paths, '/root');
      expect(paths, {'/a', '/a/nested'});
    });
  });

  group('save and load', () {
    test('save then load preserves pages keyed by path', () async {
      final prefs = FakePreferences();
      final mgr = PageManager(
        pages: {
          '/': _page('Home', '/'),
          '/settings': _page('Settings', '/settings'),
        },
        prefs: prefs,
      );
      await mgr.save();

      final mgr2 = PageManager(pages: {}, prefs: prefs);
      await mgr2.load();

      expect(mgr2.pages.length, 2);
      expect(mgr2.pages.containsKey('/'), isTrue);
      expect(mgr2.pages.containsKey('/settings'), isTrue);
      expect(mgr2.pages['/']!.menuItem.label, 'Home');
    });

    test('load with no data creates default Home page at /', () async {
      final prefs = FakePreferences();
      final mgr = PageManager(pages: {}, prefs: prefs);
      await mgr.load();

      expect(mgr.pages.containsKey('/'), isTrue);
      expect(mgr.pages['/']!.menuItem.label, 'Home');
    });

    test('duplicate labels in different sections survive save/load cycle',
        () async {
      final prefs = FakePreferences();
      final mgr = PageManager(
        pages: {
          '/section-a': _page('Section A', '/section-a', children: [
            _menuRef('roe', '/section-a/roe'),
          ]),
          '/section-a/roe': _page('roe', '/section-a/roe'),
          '/section-b': _page('Section B', '/section-b', children: [
            _menuRef('roe', '/section-b/roe'),
          ]),
          '/section-b/roe': _page('roe', '/section-b/roe'),
        },
        prefs: prefs,
      );
      await mgr.save();

      final mgr2 = PageManager(pages: {}, prefs: prefs);
      await mgr2.load();

      expect(mgr2.pages.length, 4);
      expect(mgr2.pages.containsKey('/section-a/roe'), isTrue);
      expect(mgr2.pages.containsKey('/section-b/roe'), isTrue);
      expect(mgr2.pages['/section-a/roe']!.menuItem.label, 'roe');
      expect(mgr2.pages['/section-b/roe']!.menuItem.label, 'roe');
    });
  });

  group('editing scenarios', () {
    test('renaming a page changes its path key', () {
      // Simulate what happens when a user renames a page:
      // 1. Remove old key
      // 2. Insert with new path key
      final mgr = _manager(pages: {
        '/diagnostics': _page('Diagnostics', '/diagnostics', children: [
          _menuRef('IOs', '/diagnostics/ios'),
        ]),
        '/diagnostics/ios': _page('IOs', '/diagnostics/ios'),
      });

      // Simulate rename: IOs -> Inputs/Outputs (path: /diagnostics/inputs-outputs)
      final oldPage = mgr.pages.remove('/diagnostics/ios')!;
      final renamedPage = AssetPage(
        menuItem: MenuItem(
          label: 'Inputs/Outputs',
          path: '/diagnostics/inputs-outputs',
          icon: oldPage.menuItem.icon,
        ),
        assets: oldPage.assets,
        mirroringDisabled: oldPage.mirroringDisabled,
        navigationPriority: oldPage.navigationPriority,
      );
      mgr.pages['/diagnostics/inputs-outputs'] = renamedPage;

      expect(mgr.pages.containsKey('/diagnostics/ios'), isFalse);
      expect(mgr.pages.containsKey('/diagnostics/inputs-outputs'), isTrue);
      expect(mgr.pages['/diagnostics/inputs-outputs']!.menuItem.label,
          'Inputs/Outputs');
    });

    test('renaming does not affect other pages', () {
      final mgr = _manager(pages: {
        '/': _page('Home', '/'),
        '/settings': _page('Settings', '/settings'),
        '/about': _page('About', '/about'),
      });

      // Rename settings -> preferences
      mgr.pages.remove('/settings');
      mgr.pages['/preferences'] = _page('Preferences', '/preferences');

      expect(mgr.pages.length, 3);
      expect(mgr.pages.containsKey('/'), isTrue);
      expect(mgr.pages['/']!.menuItem.label, 'Home');
      expect(mgr.pages.containsKey('/about'), isTrue);
      expect(mgr.pages['/about']!.menuItem.label, 'About');
      expect(mgr.pages.containsKey('/preferences'), isTrue);
    });

    test('renaming page in section A does not affect page in section B', () {
      final mgr = _manager(pages: {
        '/section-a/roe': _page('roe', '/section-a/roe'),
        '/section-b/roe': _page('roe', '/section-b/roe'),
      });

      // Rename section-a's roe to "fish-roe"
      mgr.pages.remove('/section-a/roe');
      mgr.pages['/section-a/fish-roe'] = _page('fish roe', '/section-a/fish-roe');

      expect(mgr.pages.length, 2);
      // Section B's roe is untouched
      expect(mgr.pages.containsKey('/section-b/roe'), isTrue);
      expect(mgr.pages['/section-b/roe']!.menuItem.label, 'roe');
      // Section A's renamed page exists
      expect(mgr.pages.containsKey('/section-a/fish-roe'), isTrue);
    });
  });

  group('movePage', () {
    AssetPage section(String label, String path,
        {List<MenuItem> children = const [], int? priority}) {
      return AssetPage(
        menuItem: MenuItem(
          label: label,
          path: path,
          icon: Icons.folder,
          children: children,
          isSection: true,
        ),
        assets: [],
        mirroringDisabled: false,
        navigationPriority: priority,
      );
    }

    /// Paths of the direct children of [path], in render order.
    List<String> childrenOf(Map<String, AssetPage> pages, String path) =>
        pages[path]!.menuItem.children.map((c) => c.path!).toList();

    Map<String, AssetPage> twoSections() => {
          '/a': section('A', '/a', priority: 0, children: [
            _menuRef('One', '/a/one'),
            _menuRef('Two', '/a/two'),
          ]),
          '/a/one': _page('One', '/a/one', priority: 0),
          '/a/two': _page('Two', '/a/two', priority: 1),
          '/b': section('B', '/b', priority: 1),
        };

    test('moves a page from one section to another', () {
      final moved = PageManager.movePage(twoSections(),
          pagePath: '/a/one', newParentPath: '/b');

      expect(childrenOf(moved, '/a'), ['/a/two']);
      expect(childrenOf(moved, '/b'), ['/a/one']);
      // The page keeps its address, so links to it stay valid.
      expect(moved['/a/one']!.menuItem.path, '/a/one');
      expect(moved.length, 4);
    });

    test('the moved page lands last among its new siblings', () {
      var pages = PageManager.movePage(twoSections(),
          pagePath: '/a/one', newParentPath: '/b');
      pages = PageManager.movePage(pages,
          pagePath: '/a/two', newParentPath: '/b');

      expect(childrenOf(pages, '/b'), ['/a/one', '/a/two']);
      expect(pages['/a/one']!.navigationPriority, 0);
      expect(pages['/a/two']!.navigationPriority, 1);
    });

    test('siblings left behind are renumbered without gaps', () {
      final pages = {
        '/a': section('A', '/a', priority: 0, children: [
          _menuRef('One', '/a/one'),
          _menuRef('Two', '/a/two'),
          _menuRef('Three', '/a/three'),
        ]),
        '/a/one': _page('One', '/a/one', priority: 0),
        '/a/two': _page('Two', '/a/two', priority: 1),
        '/a/three': _page('Three', '/a/three', priority: 2),
        '/b': section('B', '/b', priority: 1),
      };

      final moved =
          PageManager.movePage(pages, pagePath: '/a/one', newParentPath: '/b');

      expect(moved['/a/two']!.navigationPriority, 0);
      expect(moved['/a/three']!.navigationPriority, 1);
    });

    test('moving to the top level makes the page a root, listed last', () {
      final moved = PageManager.movePage(twoSections(),
          pagePath: '/a/one', newParentPath: null);

      final mgr = _manager(pages: moved);
      expect(mgr.getRootMenuItems().map((r) => r.label).toList(),
          ['A', 'B', 'One']);
      expect(childrenOf(moved, '/a'), ['/a/two']);
    });

    test('a section moves with its whole subtree', () {
      final pages = {
        '/a': section('A', '/a', priority: 0, children: [
          _menuRef('Sub', '/a/sub'),
        ]),
        '/a/sub': section('Sub', '/a/sub', children: [
          _menuRef('Leaf', '/a/sub/leaf'),
        ]),
        '/a/sub/leaf': _page('Leaf', '/a/sub/leaf'),
        '/b': section('B', '/b', priority: 1),
      };

      final moved =
          PageManager.movePage(pages, pagePath: '/a/sub', newParentPath: '/b');

      expect(childrenOf(moved, '/a'), isEmpty);
      expect(childrenOf(moved, '/b'), ['/a/sub']);
      expect(childrenOf(moved, '/a/sub'), ['/a/sub/leaf']);

      final roots = _manager(pages: moved).getRootMenuItems();
      expect(roots.map((r) => r.label).toList(), ['A', 'B']);
      expect(roots[1].children.single.children.single.label, 'Leaf');
    });

    test('refuses to move a section into its own subtree', () {
      final pages = {
        '/a': section('A', '/a', children: [_menuRef('Sub', '/a/sub')]),
        '/a/sub': section('Sub', '/a/sub'),
      };

      expect(
        PageManager.movePage(pages, pagePath: '/a', newParentPath: '/a/sub'),
        same(pages),
      );
      expect(
        PageManager.movePage(pages, pagePath: '/a', newParentPath: '/a'),
        same(pages),
      );
    });

    test('refuses a destination that is a page, not a section', () {
      final pages = twoSections();
      expect(
        PageManager.movePage(pages, pagePath: '/a/two', newParentPath: '/a/one'),
        same(pages),
      );
    });

    test('refuses an unknown page or destination', () {
      final pages = twoSections();
      expect(
        PageManager.movePage(pages, pagePath: '/nope', newParentPath: '/b'),
        same(pages),
      );
      expect(
        PageManager.movePage(pages, pagePath: '/a/one', newParentPath: '/nope'),
        same(pages),
      );
    });

    test('leaves the input map and its pages untouched', () {
      final pages = twoSections();
      PageManager.movePage(pages, pagePath: '/a/one', newParentPath: '/b');

      expect(childrenOf(pages, '/a'), ['/a/one', '/a/two']);
      expect(childrenOf(pages, '/b'), isEmpty);
      expect(pages['/a/one']!.navigationPriority, 0);
    });

    test('keeps a section self-reference when the section itself moves', () {
      // The "IOs under Diagnostics" shape: the section lists itself as a child
      // so it has a landing page of its own.
      final pages = {
        '/a': section('A', '/a', children: [_menuRef('Diag', '/diag')]),
        '/diag': section('Diagnostics', '/diag', children: [
          _menuRef('IOs', '/diag'),
        ]),
        '/b': section('B', '/b'),
      };

      final moved =
          PageManager.movePage(pages, pagePath: '/diag', newParentPath: '/b');

      expect(childrenOf(moved, '/a'), isEmpty);
      expect(childrenOf(moved, '/b'), ['/diag']);
      expect(childrenOf(moved, '/diag'), ['/diag'],
          reason: 'the self-reference is the page itself, not a parent link');
    });

    test('a page listed under two sections ends up in exactly one', () {
      final pages = {
        '/a': section('A', '/a', children: [_menuRef('One', '/one')]),
        '/b': section('B', '/b', children: [_menuRef('One', '/one')]),
        '/c': section('C', '/c'),
        '/one': _page('One', '/one'),
      };

      final moved =
          PageManager.movePage(pages, pagePath: '/one', newParentPath: '/c');

      expect(childrenOf(moved, '/a'), isEmpty);
      expect(childrenOf(moved, '/b'), isEmpty);
      expect(childrenOf(moved, '/c'), ['/one']);
    });

    test('survives a round trip through JSON', () {
      final moved = PageManager.movePage(twoSections(),
          pagePath: '/a/one', newParentPath: '/b');

      final reloaded = _manager(pages: PageManager.copyPages(moved));
      final roots = reloaded.getRootMenuItems();
      expect(roots.map((r) => r.label).toList(), ['A', 'B']);
      expect(roots[0].children.single.label, 'Two');
      expect(roots[1].children.single.label, 'One');
    });
  });

  group('top-level order', () {
    List<MenuItem> registered() => [
          _menuRef('Home', '/'),
          _menuRef('Alarm View', '/alarm-view'),
          _menuRef('Line', '/line'),
          _menuRef('Advanced', '/advanced'),
        ];

    test('sortTopLevel leaves the registration order alone when never set',
        () {
      final mgr = _manager();
      final items = registered();

      mgr.sortTopLevel(items);

      expect(items.map((i) => i.path).toList(),
          ['/', '/alarm-view', '/line', '/advanced']);
    });

    test('sortTopLevel reorders built-ins and pages alike', () {
      final mgr = _manager()
        ..topLevelOrder = ['/line', '/', '/advanced', '/alarm-view'];
      final items = registered();

      mgr.sortTopLevel(items);

      expect(items.map((i) => i.path).toList(),
          ['/line', '/', '/advanced', '/alarm-view']);
    });

    test('items unknown to the stored order land last, in registration order',
        () {
      final mgr = _manager()..topLevelOrder = ['/alarm-view', '/'];
      final items = registered();

      mgr.sortTopLevel(items);

      expect(items.map((i) => i.path).toList(),
          ['/alarm-view', '/', '/line', '/advanced']);
    });

    test('the order survives save and load', () async {
      final prefs = FakePreferences();
      final mgr = PageManager(pages: {'/': _page('Home', '/')}, prefs: prefs)
        ..topLevelOrder = ['/alarm-view', '/', '/advanced'];
      await mgr.save();

      final mgr2 = PageManager(pages: {}, prefs: prefs);
      await mgr2.load();

      expect(mgr2.topLevelOrder, ['/alarm-view', '/', '/advanced']);
    });

    test('saving without an order does not wipe a stored one', () async {
      final prefs = FakePreferences();
      final mgr = PageManager(pages: {'/': _page('Home', '/')}, prefs: prefs)
        ..topLevelOrder = ['/alarm-view', '/'];
      await mgr.save();

      // A manager that never loaded — its empty order means "unknown", not
      // "reset to registration order".
      final blank = PageManager(pages: {'/': _page('Home', '/')}, prefs: prefs);
      await blank.save();

      final mgr2 = PageManager(pages: {}, prefs: prefs);
      await mgr2.load();
      expect(mgr2.topLevelOrder, ['/alarm-view', '/']);
    });

    test('garbage in the stored order is dropped, not fatal', () async {
      final prefs = FakePreferences();
      await prefs.setString(PageManager.orderStorageKey, 'not json');
      final mgr = PageManager(pages: {}, prefs: prefs);
      await mgr.load();

      expect(mgr.topLevelOrder, isEmpty);
    });
  });

  group('load over the local mirror', () {
    test('rows in the mirror are what the station comes up on', () async {
      final store = await _storeHolding({
        '/': _page('Home', '/'),
        '/roe': _page('Roe', '/roe'),
      });
      // A blob that says something else entirely. Rows win, and this is never
      // read for pages.
      final prefs = FakePreferences();
      await prefs.setString(
          PageManager.storageKey,
          jsonEncode({
            '/stale': _page('Stale', '/stale').toJson(),
          }));
      prefs.writes.clear();

      final mgr = PageManager(pages: {}, prefs: prefs, store: store);
      await mgr.load();

      expect(mgr.pages.keys, containsAll(<String>['/', '/roe']));
      expect(mgr.pages.containsKey('/stale'), isFalse);
      expect(mgr.source, PageSource.rows);
      expect(mgr.servingFallback, isFalse);
      expect(prefs.writes, isEmpty);
    });

    test('no page rows and a blob present: the blob is served, READ-ONLY',
        () async {
      // Rollout day. The mirror is open and holds nothing of these kinds —
      // rows cannot pre-exist the migration that mints them.
      final store = await _storeHolding({});
      final prefs = FakePreferences();
      await prefs.setString(
          PageManager.storageKey,
          jsonEncode({
            '/': _page('Home', '/').toJson(),
            '/roe': _page('Roe', '/roe').toJson(),
          }));
      prefs.writes.clear();

      final mgr = PageManager(pages: {}, prefs: prefs, store: store);
      await mgr.load();

      expect(mgr.pages.keys, containsAll(<String>['/', '/roe']));
      expect(mgr.source, PageSource.blob);
      expect(mgr.servingFallback, isTrue);

      // T-03-11: not one row, not one preference. A re-home here would derive
      // content ids from a possibly-stale cache and mint permanent ghost rows
      // on the plant's mimic that no reconcile has a reason to delete.
      expect(prefs.writes, isEmpty,
          reason: 'the blob fallback must write nothing back');
      expect(
          store.itemsOf(const {ConfigKind.page, ConfigKind.asset}), isEmpty,
          reason: 'the fallback must not re-home the blob into rows');
    });

    test('asset rows whose page is gone are not a layout: the blob still wins',
        () async {
      final store = await _storeHolding({});
      final prefs = FakePreferences();
      await prefs.setString(PageManager.storageKey,
          jsonEncode({'/': _page('Home', '/').toJson()}));

      final mgr = PageManager(pages: {}, prefs: prefs, store: store);
      await mgr.load();

      // Rows that reassemble into no pages are treated as no rows. "Could not
      // be rebuilt" and "empty" are the same answer here on purpose; what must
      // never happen is a station coming up blank.
      expect(mgr.pages.containsKey('/'), isTrue);
      expect(mgr.source, PageSource.blob);
    });

    test('a virgin station: the built-in default, in memory, written nowhere',
        () async {
      final store = await _storeHolding({});
      final prefs = FakePreferences();

      final mgr = PageManager(pages: {}, prefs: prefs, store: store);
      await mgr.load();

      expect(mgr.pages.containsKey('/'), isTrue);
      expect(mgr.pages['/']!.menuItem.label, 'Home');
      expect(mgr.source, PageSource.builtInDefault);
      expect(mgr.servingFallback, isTrue);
      // T-03-10: the seed is deleted. This used to be an unawaited write of
      // the plant layout at boot with nobody signed in.
      expect(prefs.writes, isEmpty);
      expect(await prefs.getString(PageManager.storageKey), isNull);
      expect(store.itemsOf(const {ConfigKind.page, ConfigKind.asset}), isEmpty);
    });

    test('a store-less manager is the legacy path, minus the seed', () async {
      final prefs = FakePreferences();
      final mgr = PageManager(pages: {}, prefs: prefs);
      await mgr.load();

      expect(mgr.pages.containsKey('/'), isTrue);
      expect(mgr.source, PageSource.builtInDefault);
      expect(prefs.writes, isEmpty,
          reason: 'the boot seed write is gone; the first Save by a person '
              'is what persists a layout');
      expect(await prefs.getString(PageManager.storageKey), isNull);
    });

    test('the source starts at notLoaded, which is not "empty"', () {
      // The distinction the re-load trigger depends on. A manager that has
      // not loaded is not a manager serving a fallback, or the trigger fires
      // on a manager nobody has asked to load yet.
      final mgr = _manager();
      expect(mgr.source, PageSource.notLoaded);
      expect(mgr.servingFallback, isFalse);
    });

    test('rows arriving after a fallback load are picked up by re-loading',
        () async {
      // The rollout-day window, at the manager level: the same instance, told
      // to load again once its mirror has rows, comes up on them.
      final store = await _storeHolding({});
      final prefs = FakePreferences();
      await prefs.setString(PageManager.storageKey,
          jsonEncode({'/': _page('Home', '/').toJson()}));

      final mgr = PageManager(pages: {}, prefs: prefs, store: store);
      await mgr.load();
      expect(mgr.servingFallback, isTrue);

      store.attachRemoteDatabase(AppDatabase.inMemoryForTest(),
          startSync: false);
      await store.writeItems(
        kinds: const {ConfigKind.page, ConfigKind.asset},
        wanted: pageItems({'/plant': _page('Plant', '/plant')}),
        actionId: 'reconcile',
        who: 'test',
        roleName: 'system',
      );

      await mgr.load();

      expect(mgr.source, PageSource.rows);
      expect(mgr.servingFallback, isFalse);
      expect(mgr.pages.containsKey('/plant'), isTrue);
    });

    test('the store survives copyWith', () async {
      // page.dart's hand-rebuild trap: a copy that dropped the store would
      // silently fall back to blob-only behaviour.
      final store = await _storeHolding({'/': _page('Home', '/')});
      final mgr = PageManager(pages: {}, prefs: FakePreferences(), store: store)
        ..pages = {'/': _page('Home', '/')};

      expect(mgr.copyWith().store, same(store));
    });

    test('topLevelOrder still comes from preferences when rows are served',
        () async {
      final store = await _storeHolding({'/': _page('Home', '/')});
      final prefs = FakePreferences();
      await prefs.setString(
          PageManager.orderStorageKey, jsonEncode(['/alarm-view', '/']));

      final mgr = PageManager(pages: {}, prefs: prefs, store: store);
      await mgr.load();

      expect(mgr.source, PageSource.rows);
      expect(mgr.topLevelOrder, ['/alarm-view', '/']);
    });
  });

  group('save over the rows', () {
    /// A manager whose reads and whose writes both go to [store] — what the
    /// provider builds. The write is the raw `writeItems` here; in the app it
    /// is the guarded one, and the difference is the access check, not the
    /// shape.
    PageManager _managerOn(
      ConfigStore store,
      Map<String, AssetPage> pages,
      FakePreferences prefs, {
      void Function()? onWrite,
    }) {
      return PageManager(
        pages: pages,
        prefs: prefs,
        store: store,
        writeItems: (wanted, {reason}) {
          onWrite?.call();
          return store.writeItems(
            kinds: const {ConfigKind.page, ConfigKind.asset},
            wanted: wanted,
            actionId: 'test-save',
            who: 'test',
            roleName: 'configure',
            reason: reason,
          );
        },
      );
    }

    test('the rows are written and the page blob is not', () async {
      final store = await _storeHolding({}, attachRemote: true);
      final prefs = FakePreferences();
      final mgr = _managerOn(store, {'/': _page('Home', '/')}, prefs);

      final result = await mgr.save();

      expect(result, isNotNull);
      expect(result!.diff.added, hasLength(1));
      expect(store.itemsOf(const {ConfigKind.page}), hasLength(1));
      expect(prefs.writes, isNot(contains(PageManager.storageKey)),
          reason: 'the blob is not dual-written: two records of one layout '
              'are two records that can disagree');
      expect(await prefs.getString(PageManager.storageKey), isNull);
    });

    test('the top-level order lands after the rows do', () async {
      // The order is a shared row in its own transaction, and the page write
      // can be refused — offline, a lost compare-and-swap, a merge conflict.
      // Written first, a refused save left every station's menu describing a
      // layout that never landed; written after, a refused save leaves
      // nothing changed.
      final store = await _storeHolding({}, attachRemote: true);
      final prefs = FakePreferences();
      String? orderAtWriteTime;
      final mgr = _managerOn(
        store,
        {'/': _page('Home', '/')},
        prefs,
        onWrite: () => orderAtWriteTime = prefs._store[
            PageManager.orderStorageKey] as String?,
      )..topLevelOrder = ['/', '/roe'];

      await mgr.save();

      expect(orderAtWriteTime, isNull,
          reason: 'the rows go first; the order follows a write that landed');
      expect(jsonDecode((await prefs.getString(PageManager.orderStorageKey))!),
          ['/', '/roe']);
    });

    test('an empty order is still never written', () async {
      final store = await _storeHolding({}, attachRemote: true);
      final prefs = FakePreferences();
      final mgr = _managerOn(store, {'/': _page('Home', '/')}, prefs);

      await mgr.save();

      expect(prefs.writes, isNot(contains(PageManager.orderStorageKey)));
    });

    test('a store-less manager still writes the blob, unchanged', () async {
      final prefs = FakePreferences();
      final mgr = PageManager(pages: {'/': _page('Home', '/')}, prefs: prefs);

      final result = await mgr.save();

      expect(result, isNull);
      expect(prefs.writes, contains(PageManager.storageKey));
    });
  });

  group('rollout day: the save adopts the identities on the rows', () {
    // The bad path, and the half of the fix that lives at the save. On cutover
    // day the manager loaded the blob before the migration wrote a row, so it
    // holds the whole plant with no identity at all. Minting fresh ids over
    // that is ~205 removes and ~205 adds that commit cleanly — no rev moved,
    // so no conflict arm fires — and every identity the migration minted is
    // gone. 03-04 closes the window at the reconcile; this closes it at Save.

    /// The blob the plant is on, and the rows the migration made from it.
    const blob = '''
{
  "/": {
    "menu_item": {"label": "Home", "path": "/", "icon": "home", "children": []},
    "assets": [
      {
        "asset_name": "LEDConfig",
        "coordinates": {"x": 0.1, "y": 0.1, "angle": null},
        "size": {"width": 0.03, "height": 0.03},
        "text": "Run", "textPos": "right", "key": "CN04.Run",
        "on_color": {"role": "green"}, "off_color": {"role": "grey"},
        "led_type": "circle"
      },
      {
        "asset_name": "LEDConfig",
        "coordinates": {"x": 0.2, "y": 0.1, "angle": null},
        "size": {"width": 0.03, "height": 0.03},
        "text": "Run", "textPos": "right", "key": "CN04.Run",
        "on_color": {"role": "green"}, "off_color": {"role": "grey"},
        "led_type": "circle"
      }
    ],
    "mirroring_disabled": false,
    "navigation_priority": 0
  },
  "/roe": {
    "menu_item": {"label": "Roe", "path": "/roe", "icon": "egg",
                  "children": []},
    "assets": [
      {
        "asset_name": "LEDConfig",
        "coordinates": {"x": 0.5, "y": 0.5, "angle": null},
        "size": {"width": 0.03, "height": 0.03},
        "text": "Fault", "textPos": "right", "key": "CN09.Fault",
        "on_color": {"role": "red"}, "off_color": {"role": "grey"},
        "led_type": "circle"
      }
    ],
    "mirroring_disabled": false,
    "navigation_priority": 1
  }
}
''';

    /// A store holding the rows `pageItemsFromBlob(deriveIds: true)` makes —
    /// literally what 03-03's migration writes — and a manager holding the
    /// SAME blob string as the fallback load left it: id-less.
    Future<({ConfigStore store, PageManager manager})> rolloutDay() async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      final local = AppDatabase.inMemoryForTest();
      final remote = AppDatabase.inMemoryForTest();
      addTearDown(local.close);
      addTearDown(remote.close);
      final store = ConfigStore(
        local: local,
        stationScope: ConfigScope.forStation('test-station'),
        station: 'test-station',
      );
      addTearDown(store.close);
      await store.open();
      store.attachRemoteDatabase(remote, startSync: false);
      await store.writeItems(
        kinds: const {ConfigKind.page, ConfigKind.asset},
        wanted: pageItemsFromBlob(blob),
        actionId: 'migration',
        who: 'migration',
        roleName: 'system',
      );

      final prefs = FakePreferences();
      await prefs.setString(PageManager.storageKey, blob);
      final manager = PageManager(
        pages: {},
        prefs: prefs,
        store: store,
        writeItems: (wanted, {reason}) => store.writeItems(
          kinds: const {ConfigKind.page, ConfigKind.asset},
          wanted: wanted,
          actionId: 'operator-save',
          who: 'operator',
          roleName: 'configure',
          reason: reason,
        ),
      );
      // The fallback load, exactly as it happened at boot: the rows are
      // hidden from it, because on cutover day they did not exist yet.
      manager.fromJson(blob);
      return (store: store, manager: manager);
    }

    test('rollout: id-less fallback pages adopt migrated row identities',
        () async {
      final w = await rolloutDay();
      final before = w.store.itemsOf(const {ConfigKind.page, ConfigKind.asset});
      expect(before, hasLength(5), reason: '2 pages + 3 assets');
      expect(w.manager.pages.values.every((p) => p.id == null), isTrue,
          reason: 'the premise: a blob load mints nothing');

      final result = await w.manager.save();

      expect(result!.diff.added, isEmpty);
      expect(result.diff.changed, isEmpty);
      expect(result.diff.removed, isEmpty,
          reason: 'this is the ~410-row remove+add that severs every '
              'identity the migration minted');
      // And no row moved behind the diff either.
      final after = w.store.itemsOf(const {ConfigKind.page, ConfigKind.asset});
      expect(
          {for (final item in after) item.id: item.rev},
          {for (final item in before) item.id: item.rev});
    });

    test('rollout: one nudged asset writes exactly one changed row', () async {
      final w = await rolloutDay();
      final before = w.store.itemsOf(const {ConfigKind.page, ConfigKind.asset});
      w.manager.pages['/']!.assets.first.coordinates.x = 0.42;

      final result = await w.manager.save();

      expect(result!.diff.changed, hasLength(1));
      expect(result.diff.changed.single.kind, ConfigKind.asset);
      expect(result.diff.added, isEmpty);
      expect(result.diff.removed, isEmpty);
      // The row it changed is one the migration wrote, not a new one.
      expect({for (final item in before) item.id},
          contains(result.diff.changed.single.id));
    });
  });

  group('isDescendantOf', () {
    final pages = {
      '/a': _page('A', '/a', children: [_menuRef('Sub', '/a/sub')]),
      '/a/sub': _page('Sub', '/a/sub', children: [
        _menuRef('Leaf', '/a/sub/leaf'),
      ]),
      '/a/sub/leaf': _page('Leaf', '/a/sub/leaf'),
      '/b': _page('B', '/b'),
    };

    test('finds direct and indirect descendants', () {
      expect(
          PageManager.isDescendantOf(pages,
              ancestor: '/a', candidate: '/a/sub'),
          isTrue);
      expect(
          PageManager.isDescendantOf(pages,
              ancestor: '/a', candidate: '/a/sub/leaf'),
          isTrue);
    });

    test('is false for unrelated pages and for the ancestor itself', () {
      expect(
          PageManager.isDescendantOf(pages, ancestor: '/a', candidate: '/b'),
          isFalse);
      expect(
          PageManager.isDescendantOf(pages, ancestor: '/a', candidate: '/a'),
          isFalse);
      expect(
          PageManager.isDescendantOf(pages,
              ancestor: '/a/sub', candidate: '/a'),
          isFalse);
    });

    test('terminates on a cycle in the stored children', () {
      final cyclic = {
        '/x': _page('X', '/x', children: [_menuRef('Y', '/y')]),
        '/y': _page('Y', '/y', children: [_menuRef('X', '/x')]),
      };
      expect(
          PageManager.isDescendantOf(cyclic, ancestor: '/x', candidate: '/z'),
          isFalse);
    });
  });
}

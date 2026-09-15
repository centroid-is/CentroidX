/// Regression tests for the Pages dialog — the page editor's tree organizer.
///
/// The organizer is the one screen that can quietly destroy a plant's
/// navigation: it deletes pages, moves them between sections, and renames
/// them, all against `_temporaryPages` with nothing but Ctrl+Z behind it.
/// Each test here pins one way it used to do that without saying so — a
/// rename that moved the page's address out from under every link to it, a
/// delete that left this station booting at a route that no longer existed, a
/// stored children list that took the whole editor down with a duplicate-key
/// assertion.
library;

import 'package:beamer/beamer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc_dart/core/preferences.dart';

import 'package:tfc/core/startup_url.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/page_creator/assets/common.dart' show Asset;
import 'package:tfc/page_creator/page.dart';
import 'package:tfc/pages/page_editor.dart';
import 'package:tfc/providers/alarm.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/page_manager.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/widgets/panes/standard_dialog.dart';

/// Minimal in-memory [PreferencesApi]. Used twice over: once for the pages
/// themselves, and once as this station's device-local store, which is where
/// the startup URL lives.
class _FakePreferences implements PreferencesApi {
  final Map<String, Object> store = {};

  @override
  Future<String?> getString(String key) async => store[key] as String?;
  @override
  Future<void> setString(String key, String value) async => store[key] = value;
  @override
  Future<Set<String>> getKeys({Set<String>? allowList}) async =>
      store.keys.toSet();
  @override
  Future<Map<String, Object?>> getAll({Set<String>? allowList}) async =>
      Map.from(store);
  @override
  Future<bool?> getBool(String key) async => store[key] as bool?;
  @override
  Future<int?> getInt(String key) async => store[key] as int?;
  @override
  Future<double?> getDouble(String key) async => store[key] as double?;
  @override
  Future<List<String>?> getStringList(String key) async =>
      store[key] as List<String>?;
  @override
  Future<bool> containsKey(String key) async => store.containsKey(key);
  @override
  Future<void> setBool(String key, bool value) async => store[key] = value;
  @override
  Future<void> setInt(String key, int value) async => store[key] = value;
  @override
  Future<void> setDouble(String key, double value) async => store[key] = value;
  @override
  Future<void> setStringList(String key, List<String> value) async =>
      store[key] = value;
  @override
  Future<void> remove(String key) async => store.remove(key);
  @override
  Future<void> clear({Set<String>? allowList}) async => store.clear();
}

AssetPage _page(
  String label,
  String path, {
  List<MenuItem> children = const [],
  bool isSection = false,
  int? priority,
  List<Asset> assets = const [],
}) {
  return AssetPage(
    menuItem: MenuItem(
      label: label,
      path: path,
      icon: isSection ? Icons.folder : Icons.pageview,
      children: children,
      isSection: isSection,
    ),
    assets: assets,
    mirroringDisabled: false,
    navigationPriority: priority,
  );
}

MenuItem _ref(String label, String path) =>
    MenuItem(label: label, path: path, icon: Icons.pageview);

class _EditorLocation extends BeamLocation<BeamState> {
  _EditorLocation()
      : super(RouteInformation(uri: Uri.parse('/advanced/page-editor')));
  @override
  List<BeamPage> buildPages(BuildContext context, BeamState state) => const [
        BeamPage(key: ValueKey('page-editor'), child: PageEditor()),
      ];
  @override
  List<Pattern> get pathPatterns => ['/advanced/page-editor'];
}

Widget _buildEditor(PageManager manager, PreferencesApi localPrefs) {
  final routerDelegate = BeamerDelegate(
    locationBuilder: (routeInformation, _) => _EditorLocation(),
  );
  return ProviderScope(
    overrides: [
      pageManagerProvider.overrideWith((ref) async => manager),
      // The startup page is device-local, not shared with the other stations
      // on the same database, so it has its own store to assert against.
      localPreferencesProvider.overrideWithValue(localPrefs),
      databaseProvider.overrideWith((ref) async => null),
      alarmManProvider
          .overrideWith((ref) => throw StateError('No AlarmMan in tests')),
    ],
    child: BeamerProvider(
      routerDelegate: routerDelegate,
      child: MaterialApp.router(
        routerDelegate: routerDelegate,
        routeInformationParser: BeamerParser(),
      ),
    ),
  );
}

Future<void> _openPagesDialog(WidgetTester tester) async {
  await tester.tap(find.text('Home').first);
  await tester.pumpAndSettle();
  expect(find.text('Pages'), findsOneWidget);
}

Finder _treeNode(String label) => find.ancestor(
      of: find.text(label),
      matching: find.byType(ListTile),
    );

/// Opens the edit form for the row labelled [label].
Future<void> _openEditor(WidgetTester tester, String label) async {
  await tester.tap(find.descendant(
      of: _treeNode(label), matching: find.byIcon(Icons.edit)));
  await tester.pumpAndSettle();
}

/// Types [name] into the open edit form's name field.
Future<void> _typeName(WidgetTester tester, String name) async {
  await tester.enterText(find.byType(TextField).first, name);
  await tester.pumpAndSettle();
}

/// Closes the Pages dialog and presses Save, so the manager — not just the
/// editor's scratch copy — holds the result.
Future<void> _closeAndSave(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Close'));
  await tester.pumpAndSettle();
  if (find.byType(SnackBar).evaluate().isNotEmpty) {
    await tester.pumpAndSettle(const Duration(seconds: 5));
  }
  await tester.tap(find.byIcon(Icons.save));
  await tester.pumpAndSettle();
}

/// Opens the destination picker for [label] and returns the picker's dialog,
/// so its rows can be told apart from the tree rows behind it.
Future<Finder> _openMoveDialog(WidgetTester tester, String label) async {
  await tester.tap(find.descendant(
      of: _treeNode(label),
      matching: find.byIcon(Icons.drive_file_move_outline)));
  await tester.pumpAndSettle();
  final dialog = find.ancestor(
    of: find.text('Move "$label"'),
    matching: find.byType(StandardDialogFrame),
  );
  expect(dialog, findsOneWidget);
  return dialog;
}

/// The picker row for section [label].
Finder _destination(Finder dialog, String label) => find.descendant(
      of: dialog,
      matching: find.widgetWithText(ListTile, label),
    );

/// The text of the confirm dialog currently on screen.
String _confirmMessage(WidgetTester tester) {
  return find
      .byType(Text)
      .evaluate()
      .map((e) => (e.widget as Text).data ?? '')
      .firstWhere((t) => t.startsWith('Delete "'), orElse: () => '');
}

void main() {
  late _FakePreferences localPrefs;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    localPrefs = _FakePreferences();
    final registry = RouteRegistry();
    registry.menuItems.clear();
    registry.addMenuItem(
        const MenuItem(label: 'Home', path: '/', icon: Icons.home));
    registry.addMenuItem(const MenuItem(
        label: 'Advanced',
        path: '/advanced',
        icon: Icons.settings,
        isSection: true));
  });

  void sized(WidgetTester tester) {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  group('renaming a page', () {
    PageManager manager() => PageManager(prefs: _FakePreferences(), pages: {
          '/': _page('Home', '/', priority: 0),
          '/weigher': _page('Weigher', '/weigher', priority: 1),
        });

    testWidgets('keeps the address, so links to it keep working',
        (tester) async {
      sized(tester);
      final mgr = manager();
      await tester.pumpWidget(_buildEditor(mgr, localPrefs));
      await tester.pumpAndSettle();
      await _openPagesDialog(tester);

      await _openEditor(tester, 'Weigher');
      await _typeName(tester, 'Scale');
      await tester.tap(find.text('Update'));
      await tester.pumpAndSettle();
      await _closeAndSave(tester);

      // The label changed; the address the plant links to did not.
      expect(mgr.pages.containsKey('/weigher'), isTrue,
          reason: 'renaming must not move the page');
      expect(mgr.pages.containsKey('/scale'), isFalse);
      expect(mgr.pages['/weigher']!.menuItem.label, 'Scale');
    });

    testWidgets('moves the address only when explicitly asked', (tester) async {
      sized(tester);
      final mgr = manager();
      await tester.pumpWidget(_buildEditor(mgr, localPrefs));
      await tester.pumpAndSettle();
      await _openPagesDialog(tester);

      await _openEditor(tester, 'Weigher');
      await _typeName(tester, 'Scale');
      await tester.tap(find.byKey(const ValueKey('page-address-change')));
      await tester.pumpAndSettle();

      // The form says where it is about to go before it goes there.
      expect(find.text('/scale'), findsOneWidget);
      expect(
        find.textContaining('Moves /weigher to /scale'),
        findsOneWidget,
        reason: 'the cost of moving the address must be spelled out',
      );

      await tester.tap(find.text('Update'));
      await tester.pumpAndSettle();
      await _closeAndSave(tester);

      expect(mgr.pages.containsKey('/scale'), isTrue);
      expect(mgr.pages.containsKey('/weigher'), isFalse);
    });

    testWidgets("takes this station's startup page with it", (tester) async {
      sized(tester);
      await localPrefs.setString(startupUrlPrefsKey, '/weigher');
      final mgr = manager();
      await tester.pumpWidget(_buildEditor(mgr, localPrefs));
      await tester.pumpAndSettle();
      await _openPagesDialog(tester);

      await _openEditor(tester, 'Weigher');
      await _typeName(tester, 'Scale');
      await tester.tap(find.byKey(const ValueKey('page-address-change')));
      await tester.pumpAndSettle();
      // The warning names the startup page, because it is about to move.
      expect(find.textContaining("startup page points here"), findsOneWidget);

      await tester.tap(find.text('Update'));
      await tester.pumpAndSettle();

      expect(await readStartupUrl(localPrefs), '/scale',
          reason: 'a moved page must take the startup setting with it, or '
              'the station boots onto a route that no longer resolves');
    });

    testWidgets('a refused address keeps the form open with the typing in it',
        (tester) async {
      sized(tester);
      final mgr = PageManager(prefs: _FakePreferences(), pages: {
        '/': _page('Home', '/', priority: 0),
        '/weigher': _page('Weigher', '/weigher', priority: 1),
        '/scale': _page('Scale', '/scale', priority: 2),
      });
      await tester.pumpWidget(_buildEditor(mgr, localPrefs));
      await tester.pumpAndSettle();
      await _openPagesDialog(tester);

      await _openEditor(tester, 'Weigher');
      await _typeName(tester, 'Scale');
      await tester.tap(find.byKey(const ValueKey('page-address-change')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Update'));
      await tester.pumpAndSettle();

      expect(find.text('Update'), findsOneWidget,
          reason: 'the form must stay open when the edit was refused');
      expect(find.byType(TextField).evaluate().isNotEmpty, isTrue);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'Scale',
        reason: 'closing over a refused edit threw the operator\'s typing away',
      );
      expect(mgr.pages['/weigher']!.menuItem.label, 'Weigher');
    });
  });

  group('deleting', () {
    testWidgets('a section says how many pages are inside and where they go',
        (tester) async {
      sized(tester);
      final mgr = PageManager(prefs: _FakePreferences(), pages: {
        '/': _page('Home', '/', priority: 0),
        '/packing': _page('Packing', '/packing',
            isSection: true,
            priority: 1,
            children: [_ref('Weigher', '/packing/weigher')]),
        '/packing/weigher':
            _page('Weigher', '/packing/weigher', priority: 0),
      });
      await tester.pumpWidget(_buildEditor(mgr, localPrefs));
      await tester.pumpAndSettle();
      await _openPagesDialog(tester);

      await tester.tap(find.descendant(
          of: _treeNode('Packing'), matching: find.byIcon(Icons.delete)));
      await tester.pumpAndSettle();

      final message = _confirmMessage(tester);
      expect(message, contains('holds 1 page'));
      expect(message, contains('move to the top level'));
      expect(message, contains('Undo'));
    });

    testWidgets('resets the startup page when it was the one deleted',
        (tester) async {
      sized(tester);
      await localPrefs.setString(startupUrlPrefsKey, '/weigher');
      final mgr = PageManager(prefs: _FakePreferences(), pages: {
        '/': _page('Home', '/', priority: 0),
        '/weigher': _page('Weigher', '/weigher', priority: 1),
      });
      await tester.pumpWidget(_buildEditor(mgr, localPrefs));
      await tester.pumpAndSettle();
      await _openPagesDialog(tester);

      await tester.tap(find.descendant(
          of: _treeNode('Weigher'), matching: find.byIcon(Icons.delete)));
      await tester.pumpAndSettle();
      expect(_confirmMessage(tester), contains('This station starts on this'));

      await tester.tap(find.text('Delete').last);
      await tester.pumpAndSettle();

      expect(await readStartupUrl(localPrefs), startupUrlDefault,
          reason: 'a deleted startup page must not stay in the setting');
    });

    testWidgets("a section's landing page names that row, not its parent",
        (tester) async {
      sized(tester);
      final mgr = PageManager(prefs: _FakePreferences(), pages: {
        '/': _page('Home', '/', priority: 0),
        '/diag': _page('Diagnostics', '/diag',
            isSection: true, priority: 1, children: [_ref('IOs', '/diag')]),
      });
      await tester.pumpWidget(_buildEditor(mgr, localPrefs));
      await tester.pumpAndSettle();
      await _openPagesDialog(tester);

      await tester.tap(find
          .descendant(of: _treeNode('IOs'), matching: find.byIcon(Icons.delete))
          .first);
      await tester.pumpAndSettle();

      final message = _confirmMessage(tester);
      expect(message, startsWith('Delete "IOs"?'),
          reason: 'the confirm used to name the parent section instead');
      expect(message, contains('the whole section goes with it'));
    });
  });

  testWidgets("a section's landing page is not offered an address change",
      (tester) async {
    sized(tester);
    final mgr = PageManager(prefs: _FakePreferences(), pages: {
      '/': _page('Home', '/', priority: 0),
      '/diag': _page('Diagnostics', '/diag',
          isSection: true, priority: 1, children: [_ref('IOs', '/diag')]),
    });
    await tester.pumpWidget(_buildEditor(mgr, localPrefs));
    await tester.pumpAndSettle();
    await _openPagesDialog(tester);

    await tester.tap(find
        .descendant(of: _treeNode('IOs'), matching: find.byIcon(Icons.edit))
        .first);
    await tester.pumpAndSettle();

    // The row is keyed by the section's own address; moving one without the
    // other would leave the section with a child pointing at nothing.
    expect(find.byKey(const ValueKey('page-address-preview')), findsOneWidget);
    expect(find.byKey(const ValueKey('page-address-change')), findsNothing);
  });

  group('a children list the tree cannot follow', () {
    testWidgets('two entries with no address render instead of crashing',
        (tester) async {
      sized(tester);
      final mgr = PageManager(prefs: _FakePreferences(), pages: {
        '/': _page('Home', '/', priority: 0),
        '/sec': _page('Sec', '/sec', isSection: true, priority: 1, children: [
          const MenuItem(label: 'Ghost A', icon: Icons.pageview),
          const MenuItem(label: 'Ghost B', icon: Icons.pageview),
        ]),
      });
      await tester.pumpWidget(_buildEditor(mgr, localPrefs));
      await tester.pumpAndSettle();
      await _openPagesDialog(tester);

      // Two keyless placeholders in one ReorderableListView used to trip the
      // duplicate-key assertion and take the editor down.
      expect(tester.takeException(), isNull);
      expect(find.text('Ghost A'), findsOneWidget);
      expect(find.text('Ghost B'), findsOneWidget);
      expect(find.textContaining('points nowhere'), findsNWidgets(2));
    });

    testWidgets('an entry naming a missing page can be removed',
        (tester) async {
      sized(tester);
      final mgr = PageManager(prefs: _FakePreferences(), pages: {
        '/': _page('Home', '/', priority: 0),
        '/sec': _page('Sec', '/sec',
            isSection: true,
            priority: 1,
            children: [_ref('Gone', '/sec/gone')]),
      });
      await tester.pumpWidget(_buildEditor(mgr, localPrefs));
      await tester.pumpAndSettle();
      await _openPagesDialog(tester);

      expect(find.textContaining('nothing lives at /sec/gone'), findsOneWidget);

      await tester.tap(find.descendant(
          of: _treeNode('Gone'), matching: find.byIcon(Icons.delete)));
      await tester.pumpAndSettle();

      expect(find.text('Gone'), findsNothing);
      await _closeAndSave(tester);
      expect(mgr.pages['/sec']!.menuItem.children, isEmpty);
    });

    testWidgets('two sections naming each other stay reachable',
        (tester) async {
      sized(tester);
      final mgr = PageManager(prefs: _FakePreferences(), pages: {
        '/': _page('Home', '/', priority: 0),
        '/a': _page('Alpha', '/a',
            isSection: true, priority: 1, children: [_ref('Beta', '/b')]),
        '/b': _page('Beta', '/b',
            isSection: true, priority: 2, children: [_ref('Alpha', '/a')]),
      });
      await tester.pumpWidget(_buildEditor(mgr, localPrefs));
      await tester.pumpAndSettle();
      await _openPagesDialog(tester);

      expect(tester.takeException(), isNull);
      // Neither is anybody's root, so both used to vanish from the dialog
      // entirely — present in the save, invisible to the operator.
      expect(find.text('Alpha'), findsWidgets);
      expect(find.text('Beta'), findsWidgets);
      // The cycle is drawn once and labelled, not chased down the stack.
      expect(find.textContaining('shown higher up the tree'), findsWidgets);
    });
  });

  group('the nesting limit', () {
    testWidgets('counts the levels the moved section brings with it',
        (tester) async {
      sized(tester);
      final mgr = PageManager(prefs: _FakePreferences(), pages: {
        '/': _page('Home', '/', priority: 0),
        // Two levels of section below "Tall".
        '/tall': _page('Tall', '/tall',
            isSection: true, priority: 1, children: [_ref('Mid', '/tall/mid')]),
        '/tall/mid': _page('Mid', '/tall/mid',
            isSection: true,
            priority: 0,
            children: [_ref('Leaf', '/tall/leaf')]),
        '/tall/leaf': _page('Leaf', '/tall/leaf', priority: 0),
        // A destination two levels down.
        '/d1': _page('D1', '/d1',
            isSection: true, priority: 2, children: [_ref('D2', '/d2')]),
        '/d2': _page('D2', '/d2', isSection: true, priority: 0),
      });
      await tester.pumpWidget(_buildEditor(mgr, localPrefs));
      await tester.pumpAndSettle();
      await _openPagesDialog(tester);

      final dialog = await _openMoveDialog(tester, 'Tall');

      // Dropping a two-deep section under D2 would put Leaf at level five —
      // past where the dialog will even offer an Add button.
      expect(
        tester.widget<ListTile>(_destination(dialog, 'D2')).enabled,
        isFalse,
        reason: 'the limit must account for the height of what is moving',
      );
      expect(find.text('Too deep for what you are moving'), findsWidgets);
    });

    testWidgets('still allows a plain page as deep as it always could',
        (tester) async {
      sized(tester);
      final mgr = PageManager(prefs: _FakePreferences(), pages: {
        '/': _page('Home', '/', priority: 0),
        '/loose': _page('Loose', '/loose', priority: 1),
        '/d1': _page('D1', '/d1',
            isSection: true, priority: 2, children: [_ref('D2', '/d2')]),
        '/d2': _page('D2', '/d2', isSection: true, priority: 0),
      });
      await tester.pumpWidget(_buildEditor(mgr, localPrefs));
      await tester.pumpAndSettle();
      await _openPagesDialog(tester);

      final dialog = await _openMoveDialog(tester, 'Loose');

      expect(
        tester.widget<ListTile>(_destination(dialog, 'D2')).enabled,
        isTrue,
        reason: 'a leaf brings no levels with it, so nothing changed for it',
      );
    });
  });
}

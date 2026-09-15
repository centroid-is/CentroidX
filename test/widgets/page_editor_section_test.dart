/// Regression tests for empty sections in the page editor.
///
/// Sections used to be inferred from "has children", so a freshly created
/// section rendered as a page: no "add child" button, and tapping it selected
/// it for editing. There was no way to put the first page under it.
///
/// `MenuItem.isSection` now records the intent, and the tree keys off
/// [MenuItem.isNavigationSection] so an empty section stays a section.
///
/// To update goldens:
///   flutter test --run-skipped test/widgets/page_editor_section_test.dart \
///     --update-goldens
///
/// `goldens/page_editor_empty_section.before-fix.png` is the same dialog
/// rendered by the pre-fix code, kept for comparison. Nothing asserts against
/// it, so `--update-goldens` leaves it alone.
@Tags(['golden'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:beamer/beamer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc_dart/core/preferences.dart';

import 'package:tfc/models/menu_item.dart';
import 'package:tfc/page_creator/page.dart';
import 'package:tfc/pages/page_editor.dart';
import 'package:tfc/providers/alarm.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/page_manager.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/widgets/panes/standard_dialog.dart';
import '../helpers/test_helpers.dart' show useInMemoryDeviceLocalPreferences;

/// Minimal in-memory [PreferencesApi] so the editor can load and save.
class _FakePreferences implements PreferencesApi {
  final Map<String, Object> _store = {};

  @override
  Future<String?> getString(String key) async => _store[key] as String?;
  @override
  Future<void> setString(String key, String value) async => _store[key] = value;
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
  Future<void> setBool(String key, bool value) async => _store[key] = value;
  @override
  Future<void> setInt(String key, int value) async => _store[key] = value;
  @override
  Future<void> setDouble(String key, double value) async => _store[key] = value;
  @override
  Future<void> setStringList(String key, List<String> value) async =>
      _store[key] = value;
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

PageManager _managerWithHome() {
  return PageManager(
    prefs: _FakePreferences(),
    pages: {
      '/': AssetPage(
        menuItem: const MenuItem(label: 'Home', path: '/', icon: Icons.home),
        assets: [],
        mirroringDisabled: false,
        navigationPriority: 0,
      ),
    },
  );
}

/// The editor lives inside [BaseScaffold], which reads the current Beamer
/// location during build, so it needs a router above it.
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

Widget _buildEditor(PageManager manager) {
  final routerDelegate = BeamerDelegate(
    locationBuilder: (routeInformation, _) => _EditorLocation(),
  );
  return ProviderScope(
    overrides: [
      pageManagerProvider.overrideWith((ref) async => manager),
      // Keep the editor off the database / PLC / alarm stack: BaseScaffold
      // only needs these to decide between the clock and the alarm banner.
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

/// Opens the "Pages" dialog from the page selector in the editor toolbar.
Future<void> _openPagesDialog(WidgetTester tester) async {
  await tester.tap(find.text('Home').first);
  await tester.pumpAndSettle();
  expect(find.text('Pages'), findsOneWidget);
}

/// Drives the Add Section / Add Page dialog: types [name] and confirms.
Future<void> _fillCreateDialog(WidgetTester tester, String name) async {
  await tester.enterText(find.byType(TextField).last, name);
  await tester.pump();
  await tester.tap(find.widgetWithText(ElevatedButton, 'Create'));
  await tester.pumpAndSettle();
}

/// The tree node for [label] inside the Pages dialog.
Finder _treeNode(String label) => find.ancestor(
      of: find.text(label),
      matching: find.byType(ListTile),
    );

/// Loads the real icon font so goldens show icons instead of tofu boxes.
/// Best effort: the goldens are only generated locally, so a missing SDK font
/// must not fail the suite.
Future<void> _loadMaterialIcons() async {
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot == null) return;
  final font = File(
      '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (!font.existsSync()) return;
  final loader = FontLoader('MaterialIcons')
    ..addFont(Future.value(ByteData.view(font.readAsBytesSync().buffer)));
  await loader.load();
}

void main() {
  setUpAll(_loadMaterialIcons);

  setUp(() {
    useInMemoryDeviceLocalPreferences();
    // The asset canvas constructs SharedPreferencesAsync directly.
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();

    // BaseScaffold renders a NavigationBar from the registry, which asserts on
    // fewer than two destinations.
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

  group('empty sections in the page editor', () {
    testWidgets('a newly created section renders as a section, not a page',
        (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_buildEditor(_managerWithHome()));
      await tester.pumpAndSettle();
      await _openPagesDialog(tester);

      await tester.tap(find.widgetWithText(TextButton, 'Section'));
      await tester.pumpAndSettle();
      expect(find.text('Add section'), findsOneWidget);
      await _fillCreateDialog(tester, 'Diagnostics');

      // The section is labelled as one...
      expect(_treeNode('Diagnostics'), findsOneWidget);
      expect(
        find.descendant(
          of: _treeNode('Diagnostics'),
          matching: find.text('Section'),
        ),
        findsOneWidget,
        reason: 'an empty section must still be marked as a section',
      );

      // ...and offers the add-child button that pages do not have.
      expect(
        find.descendant(
          of: _treeNode('Diagnostics'),
          matching: find.byType(PopupMenuButton<String>),
        ),
        findsOneWidget,
        reason: 'an empty section must accept child pages',
      );

      await expectLater(
        find.byType(StandardDialogFrame),
        matchesGoldenFile('goldens/page_editor_empty_section.png'),
      );
    });

    testWidgets('a page can be added under an empty section', (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final manager = _managerWithHome();
      await tester.pumpWidget(_buildEditor(manager));
      await tester.pumpAndSettle();
      await _openPagesDialog(tester);

      await tester.tap(find.widgetWithText(TextButton, 'Section'));
      await tester.pumpAndSettle();
      await _fillCreateDialog(tester, 'Diagnostics');

      // Add a page under the (still empty) section.
      await tester.tap(find.descendant(
        of: _treeNode('Diagnostics'),
        matching: find.byType(PopupMenuButton<String>),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add Page'));
      await tester.pumpAndSettle();
      await _fillCreateDialog(tester, 'IOs');

      expect(_treeNode('IOs'), findsOneWidget);

      await expectLater(
        find.byType(StandardDialogFrame),
        matchesGoldenFile('goldens/page_editor_page_under_section.png'),
      );
    });

    testWidgets('a plain page is not treated as a section', (tester) async {
      // The dialog sizes itself off the screen; the default 800x600 test
      // surface is smaller than any panel this ships on.
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_buildEditor(_managerWithHome()));
      await tester.pumpAndSettle();
      await _openPagesDialog(tester);

      await tester.tap(find.widgetWithText(TextButton, 'Page'));
      await tester.pumpAndSettle();
      expect(find.text('Add page'), findsOneWidget);
      await _fillCreateDialog(tester, 'Overview');

      expect(
        find.descendant(
          of: _treeNode('Overview'),
          matching: find.byType(PopupMenuButton<String>),
        ),
        findsNothing,
      );
    });
  });
}

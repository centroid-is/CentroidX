/// Golden images of the page editor's Pages organizer, for design review.
///
/// The organizer's hardening is mostly words on screen — what a rename will
/// do to the address, what a delete takes with it, what a children list the
/// tree cannot follow looks like — so the images are the review. Each frame
/// is one of those moments.
///
/// To update: flutter test test/pages/page_organizer_golden_test.dart --update-goldens --run-skipped
@Tags(['golden'])
library;

import 'dart:io';

import 'package:beamer/beamer.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc_dart/core/preferences.dart';

import 'package:tfc/core/startup_url.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/page_creator/page.dart';
import 'package:tfc/pages/page_editor.dart';
import 'package:tfc/providers/alarm.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/page_manager.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/route_registry.dart';
import '../helpers/golden_platform.dart';

/// Room for the dialog at its natural 590px plus the editor behind it.
const Size _viewport = Size(1100, 900);

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
}) {
  return AssetPage(
    menuItem: MenuItem(
      label: label,
      path: path,
      icon: isSection ? Icons.folder : Icons.pageview,
      children: children,
      isSection: isSection,
    ),
    assets: [],
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

/// Registers text and icon fonts so the goldens are readable rather than a
/// field of Ahem blocks. Best effort: goldens are generated locally, so a
/// font that cannot be found must not fail the suite.
Future<void> _loadFonts() async {
  Future<void> load(String family, String path) async {
    final file = File(path);
    if (!file.existsSync()) return;
    await (FontLoader(family)
          ..addFont(Future.value(ByteData.view(file.readAsBytesSync().buffer))))
        .load();
  }

  await load('Roboto', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');
  // Not every Material codepoint is in the cached icon font this test loads —
  // a page's own icon lands on the fallback glyph. The subject of these
  // goldens is the wording and the red rows, so it is left alone.
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    await load('MaterialIcons',
        '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  }
}

Future<void> _pump(WidgetTester tester, PageManager manager,
    PreferencesApi localPrefs) async {
  await tester.binding.setSurfaceSize(_viewport);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(_buildEditor(manager, localPrefs));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Home').first);
  await tester.pumpAndSettle();
}

Future<void> _expectGolden(WidgetTester tester, String name) =>
    expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name'));

/// The moment every golden here is taken at.
///
/// `BaseScaffold` puts a ticking clock in the header, so a golden of anything
/// hosted by it renders a different string every run and never matches its
/// committed PNG. Pinning the clock leaves the pixels under review as the
/// only thing the comparison can disagree about.
final Clock _goldenClock = Clock.fixed(DateTime(2026, 1, 1, 12));

/// [testWidgets] with the header clock frozen at [_goldenClock]. The whole
/// body runs inside the clock zone, so the rebuilds the header's one-second
/// stream schedules read the pinned time too.
void _testGolden(String description, WidgetTesterCallback callback) {
  testWidgets(
    description,
    (tester) => withClock(_goldenClock, () => callback(tester)),
  );
}

Finder _treeNode(String label) => find.ancestor(
      of: find.text(label),
      matching: find.byType(ListTile),
    );

void main() {
  setUpAll(_loadFonts);

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
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

  group('the Pages organizer',
      skip: goldenSkip, () {
    _testGolden('renaming shows the address it is keeping', (tester) async {
      final localPrefs = _FakePreferences();
      await localPrefs.setString(startupUrlPrefsKey, '/packing/weigher');
      await _pump(
        tester,
        PageManager(prefs: _FakePreferences(), pages: {
          '/': _page('Home', '/', priority: 0),
          '/packing': _page('Packing', '/packing',
              isSection: true,
              priority: 1,
              children: [_ref('Weigher', '/packing/weigher')]),
          '/packing/weigher':
              _page('Weigher', '/packing/weigher', priority: 0),
        }),
        localPrefs,
      );

      await tester.tap(find.descendant(
          of: _treeNode('Weigher'), matching: find.byIcon(Icons.edit)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Scale');
      await tester.pumpAndSettle();

      await _expectGolden(tester, 'page_organizer_rename_keeps_address.png');
    });

    _testGolden('ticking the address box spells out what moves',
        (tester) async {
      final localPrefs = _FakePreferences();
      await localPrefs.setString(startupUrlPrefsKey, '/packing/weigher');
      await _pump(
        tester,
        PageManager(prefs: _FakePreferences(), pages: {
          '/': _page('Home', '/', priority: 0),
          '/packing': _page('Packing', '/packing',
              isSection: true,
              priority: 1,
              children: [_ref('Weigher', '/packing/weigher')]),
          '/packing/weigher':
              _page('Weigher', '/packing/weigher', priority: 0),
        }),
        localPrefs,
      );

      await tester.tap(find.descendant(
          of: _treeNode('Weigher'), matching: find.byIcon(Icons.edit)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Scale');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('page-address-change')));
      await tester.pumpAndSettle();

      await _expectGolden(tester, 'page_organizer_rename_moves_address.png');
    });

    _testGolden('deleting a section names what is inside it', (tester) async {
      final localPrefs = _FakePreferences();
      await localPrefs.setString(startupUrlPrefsKey, '/packing');
      await _pump(
        tester,
        PageManager(prefs: _FakePreferences(), pages: {
          '/': _page('Home', '/', priority: 0),
          '/packing': _page('Packing', '/packing', isSection: true, priority: 1,
              children: [
                _ref('Weigher', '/packing/weigher'),
                _ref('Labeller', '/packing/labeller'),
              ]),
          '/packing/weigher':
              _page('Weigher', '/packing/weigher', priority: 0),
          '/packing/labeller':
              _page('Labeller', '/packing/labeller', priority: 1),
        }),
        localPrefs,
      );

      await tester.tap(find.descendant(
          of: _treeNode('Packing'), matching: find.byIcon(Icons.delete)));
      await tester.pumpAndSettle();

      await _expectGolden(tester, 'page_organizer_delete_section.png');
    });

    _testGolden('entries the tree cannot follow are shown, not swallowed',
        (tester) async {
      await _pump(
        tester,
        PageManager(prefs: _FakePreferences(), pages: {
          '/': _page('Home', '/', priority: 0),
          '/packing': _page('Packing', '/packing', isSection: true, priority: 1,
              children: [
                _ref('Weigher', '/packing/weigher'),
                // Stored data the tree cannot follow: no address at all, and
                // an address nothing lives at.
                const MenuItem(label: 'Old link', icon: Icons.pageview),
                _ref('Labeller', '/packing/labeller'),
              ]),
          '/packing/weigher':
              _page('Weigher', '/packing/weigher', priority: 0),
        }),
        _FakePreferences(),
      );

      await _expectGolden(tester, 'page_organizer_broken_entries.png');
    });
  });
}

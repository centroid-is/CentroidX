/// Shared scaffolding for end-to-end page editor tests.
///
/// The editor is pumpable, but only with a fair amount of setup: it sits
/// inside `BaseScaffold`, which reads the current Beamer location and the
/// route registry during build, and it loads and saves through a
/// [PreferencesApi]. Anything that drives the real editor needs all of it, so
/// it lives here rather than being copied per test file.
///
/// The save-and-read-back path is the useful part: [FakeEditorPreferences] is
/// what the editor persists into, so a test can assert on the JSON an operator
/// would actually get back on reload rather than on widget positions.
library;

import 'dart:convert';
import 'dart:io' show Platform;

import 'package:beamer/beamer.dart';
import 'package:clock/clock.dart';
import 'package:flutter/gestures.dart'
    show kDoubleTapMinTime, kDoubleTapTimeout, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meta/meta.dart' show isTest;
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';

import 'package:tfc/models/menu_item.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/drawn_box.dart';
import 'package:tfc/page_creator/assets/image_store.dart';
import 'package:tfc/page_creator/page.dart';
import 'package:tfc/providers/page_images.dart';
import 'package:tfc/pages/page_editor.dart';
import 'package:tfc/pages/page_view.dart';
import 'package:tfc/providers/alarm.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc_dart/core/database.dart' show DatabaseConfig;
import 'package:tfc/providers/page_manager.dart';
import 'package:tfc/route_registry.dart';

import 'package:tfc/core/config/page_codec.dart' show pagesOf;
import 'package:tfc_dart/core/access/guarded_config_store.dart'
    show GuardedConfigStore;
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_store.dart' show ConfigStore;

import 'test_helpers.dart'
    show
        FakeSecureStorage,
        createTestConfigStore,
        kConfiguringTestSession,
        useInMemoryDeviceLocalPreferences;

/// Minimal in-memory [PreferencesApi] so the editor can load and save.
/// Doubles as the read-back channel for [saveAndReadBack].
class FakeEditorPreferences implements PreferencesApi {
  final Map<String, Object> _store = {};

  /// The rows the editor saves into, once [editorManagerWith] has built one.
  ///
  /// It sits on the preferences fake rather than being threaded through
  /// sixteen test files because that is what [readBackHomeAssets] is handed —
  /// the read-back channel moved from the blob to the rows and its signature
  /// did not have to.
  ConfigStore? configStore;

  /// The guard over [configStore], which is what a page image is written
  /// through since 04-09 — image blobs are `kind='page_image'` rows now, not
  /// preferences, so they no longer live in [_store] at all.
  GuardedConfigStore? guardedStore;

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

/// A box at ([x], [y]). Deliberately non-square, so orientation is visible in
/// the persisted extents and not just the coordinates.
DrawnBoxConfig editorBox(double x, double y, {double? angle}) {
  return DrawnBoxConfig.preview()
    ..coordinates = Coordinates(x: x, y: y, angle: angle)
    ..size = const RelativeSize(width: 0.12, height: 0.06);
}

/// A one-page manager holding [assets], saving through a store of its own.
///
/// Two in-memory SQLite databases — a mirror and a stand-in for Postgres,
/// attached through `attachRemoteDatabase`, no Docker — behind a permissive
/// [GuardedConfigStore]. `kConfiguringTestSession` is what makes the save land:
/// the default session is an anonymous operator, which the guard refuses, and
/// an editor test asserting on a read-back is by definition standing somebody
/// at the panel who may configure.
///
/// [prefs] is still where image blobs and the top-level order go, and is what
/// [readBackHomeAssets] is handed — it carries the store on it.
Future<PageManager> editorManagerWith(
    List<Asset> assets, FakeEditorPreferences prefs) async {
  final guarded =
      await createTestConfigStore(session: kConfiguringTestSession);
  prefs.configStore = guarded.inner;
  prefs.guardedStore = guarded;
  return PageManager(
    prefs: prefs,
    store: guarded.inner,
    pages: {
      '/': AssetPage(
        menuItem: const MenuItem(label: 'Home', path: '/', icon: Icons.home),
        assets: assets,
        mirroringDisabled: true,
        navigationPriority: 0,
      ),
    },
    writeItems: (wanted, {reason}) => guarded.write(
      wanted,
      kinds: const {ConfigKind.page, ConfigKind.asset},
      checkKind: ConfigKind.page,
      reason: reason,
    ),
  );
}

/// The image store for [prefs]: the guard over the very rows the manager
/// built beside it saves pages into.
///
/// Falls back to a store of its own when [prefs] never went through
/// [editorManagerWith] — the editor collects orphaned images on every save,
/// and a provider that threw there would leave that path silently untested.
/// Idempotent: the store it makes is remembered on [prefs], so seeding blobs
/// before the editor is built and reading them back afterwards go to one
/// place.
Future<PageImageStore> imageStoreOf(FakeEditorPreferences prefs) async =>
    PageImageStore(prefs.guardedStore ??=
        await createTestConfigStore(session: kConfiguringTestSession));

/// A [PageImageStore] over a row store of its own, for the tests that only
/// need somewhere to put bytes.
Future<PageImageStore> testImageStore() async => PageImageStore(
    await createTestConfigStore(session: kConfiguringTestSession));

/// The editor lives inside `BaseScaffold`, which reads the current Beamer
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

/// The moment every golden is taken at.
///
/// `BaseScaffold` puts a ticking clock in the header, so a golden of anything
/// hosted by it re-renders a different string every run and never matches its
/// committed PNG. [testGoldenWidgets] pins the clock to this instant so the
/// only thing a golden can disagree about is the pixels under review.
final Clock goldenClock = Clock.fixed(DateTime(2026, 1, 1, 12));

/// [testWidgets] with the header clock frozen at [goldenClock].
///
/// The whole body runs inside the clock zone, so every build the test drives —
/// including the rebuilds the header's one-second stream schedules — reads the
/// pinned time rather than the wall clock.
@isTest
void testGoldenWidgets(String description, WidgetTesterCallback callback) {
  testWidgets(
    description,
    (tester) => withClock(goldenClock, () => callback(tester)),
  );
}

/// The real [PageEditor], wired up enough to pump.
///
/// [theme] is only worth passing for goldens, where the point is to review the
/// editor as the plant sees it; behaviour tests leave it null and get the
/// Material default.
Widget buildEditorUnderTest(PageManager manager, {ThemeData? theme}) {
  final routerDelegate = BeamerDelegate(
    locationBuilder: (routeInformation, _) => _EditorLocation(),
  );
  return ProviderScope(
    overrides: [
      pageManagerProvider.overrideWith((ref) async => manager),
      // Image blobs go where the pages go — the same `ConfigStore` the
      // manager saves rows into — so saveAndReadBack-style tests see pages
      // and their image bytes in one place.
      pageImageStoreProvider.overrideWith((ref) async {
        final prefs = manager.prefs;
        return prefs is FakeEditorPreferences
            ? imageStoreOf(prefs)
            : testImageStore();
      }),
      // Keep the editor off the database / PLC / alarm stack: BaseScaffold
      // only needs these to decide between the clock and the alarm banner.
      databaseProvider.overrideWith((ref) async => null),
      alarmManProvider
          .overrideWith((ref) => throw StateError('No AlarmMan in tests')),
    ],
    child: BeamerProvider(
      routerDelegate: routerDelegate,
      child: MaterialApp.router(
        theme: theme,
        routerDelegate: routerDelegate,
        routeInformationParser: BeamerParser(),
      ),
    ),
  );
}

/// Per-test setup the editor needs before it will pump.
void setUpEditorEnvironment() {
  // The asset canvas reads the device-local store, which sits on this
  // platform instance. Still required after 03-11 moved the construction into
  // `createDeviceLocalPreferences()`: checked by removing this line, which
  // fails every editor test with "Bad state: The SharedPreferencesAsyncPlatform
  // instance must be set."
  SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.empty();

  // And the store the factory answers, which since v1.2 plan 01-05 is the
  // SQLite one `main()` opens before `runApp` rather than a wrapper over the
  // platform instance above. Both are needed: the canvas reaches the factory
  // through `localPreferencesProvider`, and the legacy platform instance is
  // still what `Preferences` and the import path read.
  useInMemoryDeviceLocalPreferences();

  // IO-module configs kick off stateManProvider, which builds the real
  // Preferences and asks for SecureStorage. Linux and macOS fall back to
  // AwsSecureStorage, but Windows throws unless main() has registered an
  // instance — so without this the exception lands asynchronously in
  // whichever test is running, on Windows only.
  SecureStorage.setInstance(FakeSecureStorage());
  Preferences.clearSecretCache();
  DatabaseConfig.clearPrefsCache();

  // BaseScaffold renders a NavigationBar from the registry, which asserts on
  // fewer than two destinations.
  final registry = RouteRegistry();
  registry.menuItems.clear();
  registry
      .addMenuItem(const MenuItem(label: 'Home', path: '/', icon: Icons.home));
  // A section, as in the app (there it always has children): the Pages
  // dialog offers no startup toggle on rows that group instead of routing.
  registry.addMenuItem(const MenuItem(
      label: 'Advanced',
      path: '/advanced',
      icon: Icons.settings,
      isSection: true));
}

/// Pumps the editor with [assets] on the home page, at 1400x1000 unless
/// [size] says otherwise — the goldens use a real 1080p panel instead.
Future<FakeEditorPreferences> pumpEditorWith(
  WidgetTester tester,
  List<Asset> assets, {
  Size size = const Size(1400, 1000),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final prefs = FakeEditorPreferences();
  await tester.pumpWidget(
      buildEditorUnderTest(await editorManagerWith(assets, prefs)));
  await tester.pumpAndSettle();
  return prefs;
}

/// A point at relative ([fx], [fy]) within the rendered canvas.
Offset onCanvas(WidgetTester tester, double fx, double fy) {
  final r = tester.getRect(find.byType(AssetStack));
  return Offset(r.left + r.width * fx, r.top + r.height * fy);
}

/// The canvas's width / height, recovered from the live layout.
double canvasAspect(WidgetTester tester) {
  final r = tester.getRect(find.byType(AssetStack));
  return r.width / r.height;
}

/// Rubber-bands from ([x1], [y1]) to ([x2], [y2]) in canvas-relative units.
///
/// No mode to enter first: the editor rubber-bands on any drag that starts on
/// empty canvas. With [addToSelection] the modifier is held, which toggles
/// the boxed assets into or out of the existing selection instead of
/// replacing it — the drag-shaped twin of [tapAsset]'s flag.
Future<void> marquee(
  WidgetTester tester,
  double x1,
  double y1,
  double x2,
  double y2, {
  bool addToSelection = false,
}) async {
  if (addToSelection) await tester.sendKeyDownEvent(editorModifier);
  final gesture = await tester.startGesture(onCanvas(tester, x1, y1));
  await tester.pump();
  // Two moves: the first crosses the slop, the second lands on the corner.
  await gesture.moveTo(onCanvas(tester, (x1 + x2) / 2, (y1 + y2) / 2));
  await tester.pump();
  await gesture.moveTo(onCanvas(tester, x2, y2));
  await tester.pump();
  await gesture.up();
  if (addToSelection) await tester.sendKeyUpEvent(editorModifier);
  await tester.pumpAndSettle();
}

/// Opens the canvas context menu over the asset at relative ([fx], [fy]) and
/// taps the entry labelled [label].
Future<void> chooseFromAssetMenu(
    WidgetTester tester, double fx, double fy, String label) async {
  await tester.tapAt(onCanvas(tester, fx, fy), buttons: kSecondaryButton);
  await tester.pumpAndSettle();
  expect(find.text(label), findsOneWidget,
      reason: 'the context menu should offer "$label"');
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

/// The multi-select / shortcut modifier, which the editor picks from
/// `Platform` — Cmd on macOS, Ctrl elsewhere — so the test has to match.
LogicalKeyboardKey get editorModifier => Platform.isMacOS
    ? LogicalKeyboardKey.metaLeft
    : LogicalKeyboardKey.controlLeft;

/// Presses the editor's undo shortcut.
Future<void> pressUndo(WidgetTester tester) async {
  await tester.sendKeyDownEvent(editorModifier);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.keyZ);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.keyZ);
  await tester.sendKeyUpEvent(editorModifier);
  await tester.pumpAndSettle();
}

/// Taps [key] on the canvas, optionally with Shift held.
Future<void> pressEditorKey(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.pumpAndSettle();
}

/// Rotates the selection a quarter turn from the keyboard.
Future<void> pressRotate(WidgetTester tester,
        {bool counterClockwise = false}) =>
    pressEditorKey(tester, LogicalKeyboardKey.keyR, shift: counterClockwise);

/// Clicks the asset at relative ([fx], [fy]) to select it. With
/// [addToSelection] the modifier is held, which toggles it into or out of the
/// existing selection instead of replacing it.
Future<void> tapAsset(
  WidgetTester tester,
  double fx,
  double fy, {
  bool addToSelection = false,
}) async {
  if (addToSelection) await tester.sendKeyDownEvent(editorModifier);
  await tester.tapAt(onCanvas(tester, fx, fy));
  // The editor also listens for double taps, so a single tap only lands once
  // the double-tap window has passed with no second tap in it. The modifier
  // has to stay down until then — the editor reads it when the tap lands, and
  // an operator holds it through the click anyway.
  await tester.pump(kDoubleTapTimeout);
  if (addToSelection) await tester.sendKeyUpEvent(editorModifier);
  await tester.pumpAndSettle();
}

/// Double-clicks the asset at relative ([fx], [fy]), the pointer-first way of
/// opening its config pane.
Future<void> doubleTapAsset(WidgetTester tester, double fx, double fy) async {
  final where = onCanvas(tester, fx, fy);
  await tester.tapAt(where);
  // A real double click has daylight between its taps; anything faster is
  // discarded as a bounce (kDoubleTapMinTime), anything slower is two taps.
  await tester.pump(kDoubleTapMinTime);
  await tester.tapAt(where);
  await tester.pumpAndSettle();
}

/// How many assets the editor currently has selected, counted off the
/// selection borders the canvas paints. `AssetStack` wraps exactly the
/// selected assets in a bordered container, so this reads the same state the
/// operator sees.
int selectedCount(WidgetTester tester) {
  return find
      .descendant(
        of: find.byType(AssetStack),
        matching: find.byKey(selectionBorderKey),
      )
      .evaluate()
      .length;
}

/// Saves via the save FAB, then returns the persisted assets of the home
/// page in page order.
Future<List<Map<String, dynamic>>> saveAndReadBack(
    WidgetTester tester, FakeEditorPreferences prefs) async {
  await tester.tap(find.byIcon(Icons.save));
  await tester.pumpAndSettle();
  final saved = readBackHomeAssets(prefs);
  if (saved == null) {
    fail('no saved page found in preferences: ${prefs._store.keys}');
  }
  return saved;
}

/// The persisted assets of the home page, or null when nothing has been
/// saved yet. The read-back half of [saveAndReadBack], for tests that save
/// some other way than the FAB (e.g. Ctrl/Cmd+S).
List<Map<String, dynamic>>? readBackHomeAssets(FakeEditorPreferences prefs) {
  // The rows, when the manager under test has a store — which since v1.2
  // phase 3 is every editor test. One row per top-level asset, reassembled by
  // the codec so paint order comes back off `sort_index` exactly as the app
  // reads it, and re-encoded so the shape is the JSON these call sites always
  // got rather than live objects.
  final store = prefs.configStore;
  if (store != null) {
    final items = store.itemsOf(const {ConfigKind.page, ConfigKind.asset});
    if (items.isEmpty) return null; // Nothing saved yet.
    final home = pagesOf(items)['/'];
    if (home == null) return null;
    final encoded = jsonDecode(jsonEncode(home.toJson()['assets']));
    return (encoded as List).cast<Map<String, dynamic>>();
  }

  // The blob, for a manager built without a store. The manager writes the
  // whole page map under a single key; find the entry that parses as one and
  // contains our page.
  for (final value in prefs._store.values) {
    if (value is! String) continue;
    final Object? decoded;
    try {
      decoded = jsonDecode(value);
    } on FormatException {
      continue; // e.g. a base64 image blob
    }
    if (decoded is! Map<String, dynamic>) continue;
    final page = decoded['/'];
    if (page is Map<String, dynamic> && page['assets'] is List) {
      return (page['assets'] as List).cast<Map<String, dynamic>>();
    }
  }
  return null;
}

/// The `coordinates` block of a persisted asset.
Map<String, dynamic> coordsOf(Map<String, dynamic> asset) =>
    asset['coordinates'] as Map<String, dynamic>;

/// The persisted x of each asset, in page order.
List<double> savedXs(List<Map<String, dynamic>> saved) =>
    [for (final a in saved) coordsOf(a)['x'] as double];

/// The persisted y of each asset, in page order.
List<double> savedYs(List<Map<String, dynamic>> saved) =>
    [for (final a in saved) coordsOf(a)['y'] as double];

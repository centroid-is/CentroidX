/// Golden images of server reordering, for design review and PR descriptions.
///
/// Each golden frames the OPC-UA section of the server config page: the list
/// as the operator finds it, a card mid-drag, where it lands, and the
/// single-server case that deliberately shows no handle at all.
///
/// To update: flutter test test/pages/server_config_reorder_golden_test.dart --update-goldens
@Tags(['golden'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../helpers/test_helpers.dart';
import '../helpers/themed_golden_host.dart';

/// Wide enough for the section header to stay on one row (the header collapses
/// below 500px), tall enough for three cards and the save button.
const Size _viewport = Size(860, 520);

StateManConfig _servers(int count) => StateManConfig(
      opcua: [
        OpcUAConfig()
          ..endpoint = 'opc.tcp://10.104.29.11:4840'
          ..serverAlias = 'st101',
        OpcUAConfig()
          ..endpoint = 'opc.tcp://10.104.29.12:4840'
          ..serverAlias = 'st201',
        OpcUAConfig()
          ..endpoint = 'opc.tcp://10.104.29.13:4840'
          ..serverAlias = 'st301',
      ].take(count).toList(),
    );

/// Pumps the page and scrolls it so the OPC-UA section header sits just below
/// the top edge — computed from the rendered header rather than hardcoded, so
/// the framing survives changes to the database card above it.
Future<void> _pumpSection(WidgetTester tester, StateManConfig config) async {
  await tester.binding.setSurfaceSize(_viewport);
  // 1:1 pixels — these goldens are for reading, not for pixel archaeology.
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await pumpAndLoad(tester, buildTestableServerConfig(stateManConfig: config));

  final page = tester.state<ScrollableState>(find.byType(Scrollable).first);
  final headerY = tester.getTopLeft(find.text('OPC-UA Servers')).dy;
  page.position.jumpTo(page.position.pixels + headerY - 12);
  await settle(tester);
}

Future<void> _expectGolden(WidgetTester tester, String name) =>
    expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name'));

// ---------------------------------------------------------------------------
// Fonts
// ---------------------------------------------------------------------------

/// Registers text and icon fonts so the goldens are readable.
///
/// `test/pages` has no `flutter_test_config.dart` of its own, and the test
/// environment registers neither MaterialIcons nor Font Awesome — without
/// this every label is an Ahem block and every icon a tofu box, which for a
/// golden whose subject *is* an icon would be useless. Best effort
/// throughout: goldens are generated locally, so a font that cannot be found
/// must not fail the suite.
Future<void> _loadFonts() async {
  Future<void> load(String family, String path) async {
    final file = File(path);
    if (!file.existsSync()) return;
    await (FontLoader(family)
          ..addFont(Future.value(ByteData.view(file.readAsBytesSync().buffer))))
        .load();
  }

  // Material's default family, so ordinary labels render — and the same
  // face under the name the station themes ask for, so the themed dark
  // golden is text rather than Ahem boxes.
  await load('Roboto', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');
  await load('roboto-mono', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');

  // The drag handle itself is a Material icon.
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    await load('MaterialIcons',
        '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  }

  // Every card and section header carries a Font Awesome glyph, and the save
  // button's floppy disk comes from the regular face rather than the solid
  // one. Fonts a package declares are namespaced by package at runtime,
  // hence the prefix.
  final faRoot = _packageRoot('font_awesome_flutter');
  if (faRoot != null) {
    await load('packages/font_awesome_flutter/FontAwesomeSolid',
        '$faRoot/lib/fonts/Font-Awesome-7-Free-Solid-900.otf');
    await load('packages/font_awesome_flutter/FontAwesomeRegular',
        '$faRoot/lib/fonts/Font-Awesome-7-Free-Regular-400.otf');
  }
}

/// Filesystem root of [package], read out of the pub package config, so the
/// pub-cache version in the path never has to be hardcoded.
String? _packageRoot(String package) {
  final config = File('.dart_tool/package_config.json');
  if (!config.existsSync()) return null;
  final packages = (jsonDecode(config.readAsStringSync())
      as Map<String, dynamic>)['packages'] as List<dynamic>;
  for (final entry in packages.cast<Map<String, dynamic>>()) {
    if (entry['name'] == package) {
      return Uri.parse(entry['rootUri'] as String).toFilePath();
    }
  }
  return null;
}

void main() {
  setUpAll(_loadFonts);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    SecureStorage.setInstance(FakeSecureStorage());

    // The import/export card at the bottom of the page asks package_info_plus
    // for the app version. Ordinary widget tests never notice that the plugin
    // is missing — the call is still pending when the test ends. Capturing a
    // golden runs real async work, which lets it complete and throw, so the
    // channel has to answer here.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/package_info'),
      (call) async => <String, dynamic>{
        'appName': 'tfc-hmi',
        'packageName': 'is.centroid.tfc',
        'version': '1.0.0',
        'buildNumber': '1',
      },
    );
  });

  testWidgets('before — three servers, each with a grab handle',
      (tester) async {
    await _pumpSection(tester, _servers(3));
    await _expectGolden(tester, 'server_reorder_before.png');
  });

  testWidgets('during — st301 lifted out and dragged over st101',
      (tester) async {
    await _pumpSection(tester, _servers(3));

    // Grab the third card by its handle and drag it up past the other two.
    // The handle is the only grab point: pressing anywhere else on a card
    // still hits the fields and buttons it is covered in.
    final handle = find.byIcon(Icons.drag_indicator).at(2);
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveBy(const Offset(0, -140));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -20));
    await tester.pumpAndSettle();

    await _expectGolden(tester, 'server_reorder_during.png');

    await gesture.up();
    await tester.pumpAndSettle();
  });

  // The unsaved state no longer shows inside this frame: the one save
  // button for the whole document sits at the bottom of the page (phase 2
  // of quick/20260908-unify-config-ui), below this section framing.
  testWidgets('after — st301 is now first', (tester) async {
    await _pumpSection(tester, _servers(3));

    // Drop it where the previous golden was carrying it. Driving the handle
    // rather than the list's `onReorder` keeps this off an API the framework
    // has already deprecated once.
    final handles = find.byIcon(Icons.drag_indicator);
    final gesture = await tester.startGesture(tester.getCenter(handles.at(2)));
    await gesture.moveBy(const Offset(0, -12));
    await tester.pump(const Duration(milliseconds: 20));
    final travel = tester.getCenter(handles.at(0)).dy -
        tester.getCenter(handles.at(2)).dy +
        12;
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(Offset(0, travel / 4));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    await _expectGolden(tester, 'server_reorder_after.png');
  });

  testWidgets('single server — nothing to reorder, so no handle',
      (tester) async {
    await _pumpSection(tester, _servers(1));
    await _expectGolden(tester, 'server_reorder_single.png');
  });

  testWidgets('dark scheme — the list under the real station dark theme',
      (tester) async {
    // The bare-MaterialApp goldens above render the fallback light scheme;
    // this arm pins the extracted editor under the themed dark scheme so a
    // colour regression visible only on dark stations cannot hide.
    await tester.binding.setSurfaceSize(_viewport);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await pumpAndLoad(
        tester,
        buildTestableServerConfig(
            stateManConfig: _servers(3),
            theme: themedGoldenTheme(dark: true)));

    final page = tester.state<ScrollableState>(find.byType(Scrollable).first);
    final headerY = tester.getTopLeft(find.text('OPC-UA Servers')).dy;
    page.position.jumpTo(page.position.pixels + headerY - 12);
    await settle(tester);

    await _expectGolden(tester, 'server_reorder_dark.png');
  });
}

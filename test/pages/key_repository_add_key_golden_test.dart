/// Golden images of adding a key to a large repository, for design review
/// and PR descriptions.
///
/// Two frames: the repository as the operator finds it, and the moment after
/// Add Key — the new card lands expanded at the *top* of the list, where
/// revealing it costs one jump instead of building every card down to the
/// bottom (which froze the page for ~10 s with thousands of keys).
///
/// To update: flutter test test/pages/key_repository_add_key_golden_test.dart --update-goldens --run-skipped
@Tags(['golden'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../helpers/test_helpers.dart';

/// Wide enough for the header to stay on one row (it collapses below 500px),
/// tall enough to show the new card and a few of the existing ones.
const Size _viewport = Size(860, 620);

KeyMappings _manyKeys() => KeyMappings(nodes: {
      for (var i = 0; i < 2000; i++)
        'AREA${(i ~/ 100) + 1}.DEV${(i % 100) + 1}.SUB${i + 1}':
            KeyMappingEntry(
          opcuaNode: OpcUANodeConfig(namespace: 4, identifier: 'GVL.Tag$i')
            ..serverAlias = 'main_server',
        ),
    });

Future<void> _pumpRepository(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(_viewport);
  // 1:1 pixels — these goldens are for reading, not for pixel archaeology.
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(buildTestableKeyRepository(
    keyMappings: _manyKeys(),
    stateManConfig: sampleStateManConfig(),
  ));
  await tester.pumpAndSettle();
}

Future<void> _expectGolden(WidgetTester tester, String name) =>
    expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name'));

// ---------------------------------------------------------------------------
// Fonts — same best-effort loading as server_config_reorder_golden_test.dart;
// `test/pages` has no flutter_test_config.dart, so without this every label
// is an Ahem block and every icon a tofu box.
// ---------------------------------------------------------------------------

Future<void> _loadFonts() async {
  Future<void> load(String family, String path) async {
    final file = File(path);
    if (!file.existsSync()) return;
    await (FontLoader(family)
          ..addFont(Future.value(ByteData.view(file.readAsBytesSync().buffer))))
        .load();
  }

  await load('Roboto', 'lib/fonts/dejavu-sans/DejaVuSans.ttf');

  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    await load('MaterialIcons',
        '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  }

  final faRoot = _packageRoot('font_awesome_flutter');
  if (faRoot != null) {
    await load('packages/font_awesome_flutter/FontAwesomeSolid',
        '$faRoot/lib/fonts/Font-Awesome-7-Free-Solid-900.otf');
    await load('packages/font_awesome_flutter/FontAwesomeRegular',
        '$faRoot/lib/fonts/Font-Awesome-7-Free-Regular-400.otf');
  }
}

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

  testWidgets('before — two thousand keys, list at the top', (tester) async {
    await _pumpRepository(tester);
    await _expectGolden(tester, 'add_key_before.png');
  });

  testWidgets('after — new key expanded at the top of the list',
      (tester) async {
    await _pumpRepository(tester);

    await tester.tap(find.text('Add Key'));
    await tester.pumpAndSettle();

    await _expectGolden(tester, 'add_key_after.png');
  });
}

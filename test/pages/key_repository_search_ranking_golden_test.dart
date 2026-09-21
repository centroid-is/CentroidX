/// Golden image of key-repository search results ordered by match quality,
/// for design review and PR descriptions.
///
/// The keys are inserted worst-match-first, so the frame only looks right
/// because ranking reordered them: the exact hit "temp" on top, then the
/// word-boundary hits by position, then the scattered-subsequence hit last.
///
/// To update: flutter test test/pages/key_repository_search_ranking_golden_test.dart --update-goldens --run-skipped
@Tags(['golden'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../helpers/test_helpers.dart';

/// Wide enough for the header to stay on one row (it collapses below 500px).
const Size _viewport = Size(860, 620);

KeyMappings _keys() {
  KeyMappingEntry entry(String identifier) => KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(namespace: 4, identifier: identifier)
          ..serverAlias = 'main_server',
      );
  return KeyMappings(nodes: {
    'CN12.thermal.probe': entry('GVL.ThermalProbe'),
    'CN01.gate.open': entry('GVL.GateOpen'),
    'CN02.conveyor.temperature': entry('GVL.ConveyorTemp'),
    'temp': entry('GVL.Temp'),
    'CN05.motor.temp': entry('GVL.MotorTemp'),
  });
}

// ---------------------------------------------------------------------------
// Fonts — same best-effort loading as key_repository_add_key_golden_test.dart;
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

  testWidgets('searching "temp" ranks exact > word-start > subsequence',
      (tester) async {
    await tester.binding.setSurfaceSize(_viewport);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(buildTestableKeyRepository(
      keyMappings: _keys(),
      stateManConfig: sampleStateManConfig(),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextField, 'Search keys...'), 'temp');
    await tester.pumpAndSettle();

    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/search_ranking_temp.png'));
  });
}

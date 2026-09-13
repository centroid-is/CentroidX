/// Golden image of the Update Channel preferences section, for design review.
///
/// Renders the card twice — once with Stable selected, once with Latest — so
/// the review can check that the two states read clearly and the warning tone
/// of the Latest subtitle ("no release testing") is visible.
///
/// To update: flutter test test/widgets/update_section_golden_test.dart --update-goldens --run-skipped
@Tags(['golden'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/update_channel.dart';
import 'package:tfc/widgets/preferences.dart';
import '../helpers/golden_platform.dart';

const Size _surface = Size(700, 620);

/// Resolves a package's root directory from the pub package config, so the
/// font paths below survive a dependency bump.
String? _packageRoot(String package) {
  final file = File('.dart_tool/package_config.json');
  if (!file.existsSync()) return null;
  final config = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  for (final entry
      in (config['packages'] as List).cast<Map<String, dynamic>>()) {
    if (entry['name'] != package) continue;
    return Uri.parse(entry['rootUri'] as String).toFilePath();
  }
  return null;
}

Future<void> _loadFont(String family, String path) async {
  final bytes = File(path).readAsBytesSync();
  await (FontLoader(family)..addFont(Future.value(ByteData.view(bytes.buffer))))
      .load();
}

void main() {
  // The section leads with a FontAwesome icon and radio buttons from the
  // Material icon font; without registering both the capture shows tofu.
  setUpAll(() async {
    final faRoot = _packageRoot('font_awesome_flutter');
    final faFonts = faRoot == null
        ? const <File>[]
        : (Directory('$faRoot/lib/fonts')..existsSync())
            .listSync()
            .whereType<File>()
            .toList();
    for (final font in faFonts) {
      final name = font.path.toLowerCase();
      final family = name.contains('brands')
          ? 'FontAwesomeBrands'
          : name.contains('solid')
              ? 'FontAwesomeSolid'
              : name.contains('regular')
                  ? 'FontAwesomeRegular'
                  : null;
      if (family == null) continue;
      await _loadFont('packages/font_awesome_flutter/$family', font.path);
    }

    final flutterRoot = Platform.environment['FLUTTER_ROOT'];
    for (final candidate in <String>[
      if (flutterRoot != null)
        '$flutterRoot/bin/cache/artifacts/material_fonts/'
            'MaterialIcons-Regular.otf',
      '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/'
          'MaterialIcons-Regular.otf',
    ]) {
      if (File(candidate).existsSync()) {
        await _loadFont('MaterialIcons', candidate);
        break;
      }
    }
  });

  group('update channel section golden',
      skip: goldenSkip, () {
    testWidgets('stable and latest selections', (tester) async {
      await tester.binding.setSurfaceSize(_surface);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              UpdateSection(
                readChannel: () async => updateChannelStable,
                writeChannel: (_) async {},
              ),
              const SizedBox(height: 16),
              UpdateSection(
                readChannel: () async => updateChannelLatest,
                writeChannel: (_) async {},
              ),
            ],
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/update_section_channels.png'),
      );
    });
  });
}

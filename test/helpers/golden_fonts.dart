/// Real fonts for golden tests, so frames render readable text and actual
/// glyphs instead of Ahem blocks and empty icon boxes.
///
/// `test/widgets/flutter_test_config.dart` already registers roboto-mono as
/// `Roboto` for everything beneath it, but not the icon fonts, and tests
/// elsewhere under `test/` get no font at all. Call [loadGoldenFonts] from a
/// `setUpAll` in any golden test that shows icons.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

Future<void> _load(String family, String path) async {
  final file = File(path);
  // Missing artifacts must not fail the suite — the frame just falls back to
  // boxes for that family, which is obvious on sight.
  if (!file.existsSync()) return;
  await (FontLoader(family)
        ..addFont(Future.value(ByteData.view(file.readAsBytesSync().buffer))))
      .load();
}

/// Resolves a package's root from the generated package config.
String? packageRoot(String package) {
  final config = File('.dart_tool/package_config.json');
  if (!config.existsSync()) return null;
  final match = RegExp('"name"\\s*:\\s*"$package"\\s*,\\s*"rootUri"\\s*:\\s*"([^"]+)"')
      .firstMatch(config.readAsStringSync());
  if (match == null) return null;
  var uri = match.group(1)!;
  if (uri.startsWith('file://')) return Uri.parse(uri).toFilePath();
  // Relative to .dart_tool/.
  return File('.dart_tool/$uri').absolute.path;
}

/// Registers the text and icon fonts golden frames need.
///
/// **One TTF, two family names, and the second one is not redundant.** The
/// station themes ask for the family `roboto-mono` by name
/// (`lib/theme.dart:349`), and nothing was ever registered under that spelling
/// — so a golden that builds the real theme and applies
/// `textTheme.apply(fontFamily: 'roboto-mono')` rendered Ahem boxes, because
/// the only registration was under `Roboto`.
/// `test/page_creator/assets/festo_vtug_golden_test.dart:44-47` survives that
/// by loading the same file twice under both names; this is that line, moved
/// somewhere every themed golden gets it.
Future<void> loadGoldenFonts() async {
  await _load('Roboto', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');
  // Under the app's own themes `fontFamily` is 'roboto-mono', not 'Roboto', so
  // a themed frame that registers only the latter renders every string as Ahem
  // boxes. Registering both is what `base_scaffold_appbar_golden_test.dart`
  // does with its private loader; this is the same two lines, in the shared
  // helper, so the next themed golden does not have to rediscover it.
  await _load('roboto-mono', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');

  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    await _load('MaterialIcons',
        '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  }

  final faRoot = packageRoot('font_awesome_flutter');
  if (faRoot != null) {
    await _load('packages/font_awesome_flutter/FontAwesomeSolid',
        '$faRoot/lib/fonts/Font-Awesome-7-Free-Solid-900.otf');
    await _load('packages/font_awesome_flutter/FontAwesomeRegular',
        '$faRoot/lib/fonts/Font-Awesome-7-Free-Regular-400.otf');
    // Brands is a separate face, and the Linux penguin on the About page is
    // in it — without this the identity card renders a blank tofu box where
    // the distro logo should be.
    await _load('packages/font_awesome_flutter/FontAwesomeBrands',
        '$faRoot/lib/fonts/Font-Awesome-7-Brands-Regular-400.otf');
  }
}

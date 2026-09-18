/// The typeface the theme names is the typeface every build ships.
///
/// The theme asked for `roboto-mono` and nothing declared it, so every build
/// drew its platform's fallback instead: DejaVu Sans on a station, the
/// Windows default on Windows, Roboto in a browser. Only the goldens used
/// RobotoMono, because `test/helpers/golden_fonts.dart` loads it by hand. This
/// file holds the app's pubspec and the theme to the same family, and the
/// declared assets to files that exist.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/theme.dart' show kAppFontFamily;

/// The `fonts:` entries of the app's pubspec, as family -> asset paths.
///
/// Read as text rather than as YAML: this package has no YAML parser, and the
/// shape is fixed (`- family:` followed by its `- asset:` lines).
Map<String, List<String>> _declaredFonts(String pubspec) {
  final families = <String, List<String>>{};
  List<String>? current;
  for (final line in pubspec.split('\n')) {
    final family = RegExp(r'^\s*- family:\s*(\S+)\s*$').firstMatch(line);
    if (family != null) {
      current = families[family.group(1)!] = <String>[];
      continue;
    }
    final asset = RegExp(r'^\s*- asset:\s*(\S+)\s*$').firstMatch(line);
    if (asset != null) current?.add(asset.group(1)!);
  }
  return families;
}

void main() {
  final pubspec = File('centroid-hmi/pubspec.yaml').readAsStringSync();
  final fonts = _declaredFonts(pubspec);

  test('the app bundles the family the theme names', () {
    expect(fonts.keys, contains(kAppFontFamily),
        reason: 'a theme family no build declares is drawn in whatever the '
            'platform falls back to, a different font on every platform');
  });

  test('every declared asset of that family is a file in the tfc package', () {
    final assets = fonts[kAppFontFamily] ?? const <String>[];
    expect(assets, isNotEmpty);
    for (final asset in assets) {
      // `packages/tfc/<path>` is `lib/<path>` of this package.
      expect(asset, startsWith('packages/tfc/'));
      final file = File('lib/${asset.substring('packages/tfc/'.length)}');
      expect(file.existsSync(), isTrue,
          reason: '$asset is declared but ${file.path} is not there, and a '
              'missing font asset fails the build');
    }
    expect(assets.where((a) => a.endsWith('-Regular.ttf')), hasLength(1),
        reason: 'the regular face carries every weight the others do not');
  });
}

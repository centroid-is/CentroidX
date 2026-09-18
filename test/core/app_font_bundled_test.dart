/// The typeface the theme names is the typeface every build ships.
///
/// Until #585 the theme asked for a family nothing declared, so every build
/// drew its platform's fallback instead: DejaVu Sans on a station, the Windows
/// default on Windows, Roboto in a browser. This file holds the app's pubspec
/// and the theme to the same family, and the declared assets to files that
/// exist.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/theme.dart' show kAppFontFamily;

/// A `- asset:` line of the app's pubspec, and its `weight:` if it has one.
typedef _FontAsset = ({String path, int? weight});

/// The `fonts:` entries of the app's pubspec, as family -> assets.
///
/// Read as text rather than as YAML: this package has no YAML parser, and the
/// shape is fixed (`- family:` followed by its `- asset:` lines, each with an
/// optional `weight:` on the line after).
Map<String, List<_FontAsset>> _declaredFonts(String pubspec) {
  final families = <String, List<_FontAsset>>{};
  List<_FontAsset>? current;
  for (final line in pubspec.split('\n')) {
    final family = RegExp(r'^\s*- family:\s*(\S+)\s*$').firstMatch(line);
    if (family != null) {
      current = families[family.group(1)!] = <_FontAsset>[];
      continue;
    }
    final asset = RegExp(r'^\s*- asset:\s*(\S+)\s*$').firstMatch(line);
    if (asset != null) {
      current?.add((path: asset.group(1)!, weight: null));
      continue;
    }
    final weight = RegExp(r'^\s*weight:\s*(\d+)\s*$').firstMatch(line);
    if (weight != null && current != null && current.isNotEmpty) {
      current.last = (path: current.last.path, weight: int.parse(weight.group(1)!));
    }
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
    final assets = fonts[kAppFontFamily] ?? const <_FontAsset>[];
    expect(assets, isNotEmpty);
    for (final (:path, weight: _) in assets) {
      // `packages/tfc/<path>` is `lib/<path>` of this package.
      expect(path, startsWith('packages/tfc/'));
      final file = File('lib/${path.substring('packages/tfc/'.length)}');
      expect(file.existsSync(), isTrue,
          reason: '$path is declared but ${file.path} is not there, and a '
              'missing font asset fails the build');
    }
    expect(assets.where((a) => a.weight == null), hasLength(1),
        reason: 'the one face without a weight is the regular face, which '
            'carries every weight the others do not');
  });
}

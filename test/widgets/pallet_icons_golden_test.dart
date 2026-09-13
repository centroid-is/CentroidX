import 'dart:io' show File, Platform;
import 'dart:typed_data' show ByteData;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/converter/icon.dart';
import '../helpers/golden_platform.dart';

const _iconsKey = Key('pallet_icons');

/// Renders the custom pallet glyphs at the sizes they are actually used at in
/// the HMI, so a regression in the TfcIcons font (a shifted code point, a
/// dropped glyph, a re-generated font) shows up as a golden diff rather than as
/// a silent tofu box on a live page.
Widget buildIconSheet() {
  const sizes = <double>[96, 48, 24];
  return MaterialApp(
    home: Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      body: Center(
        child: RepaintBoundary(
          key: _iconsKey,
          child: Container(
            color: const Color(0xFF1A1A2E),
            padding: const EdgeInsets.all(12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                for (final icon in [pallet_top, pallet_stack])
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final size in sizes)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Icon(icon, size: size, color: Colors.white),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  // Name round-trip is font-independent, so it runs everywhere.
  group('pallet icon registration', () {
    test('round-trips through the JSON converter', () {
      const converter = IconDataConverter();
      for (final name in ['pallet_top', 'pallet_stack', 'pallet']) {
        final icon = converter.fromJson(name);
        expect(icon, isNot(Icons.help), reason: '$name is not registered');
        expect(converter.toJson(icon), name);
      }
    });

    test('custom pallet glyphs come from TfcIcons', () {
      for (final icon in [pallet_top, pallet_stack]) {
        expect(icon.fontFamily, 'TfcIcons');
        expect(icon.fontPackage, 'tfc');
      }
    });

    test('are offered in the icon picker', () {
      expect(iconList, contains(pallet_top));
      expect(iconList, contains(pallet_stack));
    });
  });

  group('pallet icon golden tests',
      skip: goldenSkip, () {
    // The test environment does not register fonts declared in pubspec.yaml,
    // so without this the icons render as tofu boxes and the golden would
    // happily lock in a missing glyph. TfcIcons.ttf lives in the repo, so
    // unlike MaterialIcons there is no SDK path to guess at.
    setUpAll(() async {
      final bytes = File('assets/fonts/TfcIcons.ttf').readAsBytesSync();
      // `fontPackage: 'tfc'` makes Flutter resolve the family through the
      // package-qualified name; register the bare name too so a future
      // unqualified IconData keeps working.
      for (final family in ['packages/tfc/TfcIcons', 'TfcIcons']) {
        await (FontLoader(family)
              ..addFont(Future.value(ByteData.view(bytes.buffer))))
            .load();
      }
    });

    testWidgets('pallet_top and pallet_stack render from the icon font',
        (tester) async {
      await tester.pumpWidget(buildIconSheet());
      await expectLater(
        find.byKey(_iconsKey),
        matchesGoldenFile('goldens/pallet_icons.png'),
      );
    });
  });
}

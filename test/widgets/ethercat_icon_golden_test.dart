import 'dart:io' show File;
import 'dart:typed_data' show ByteData;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/converter/icon.dart';
import '../helpers/golden_platform.dart';

const _iconsKey = Key('ethercat_icon');

/// Renders the EtherCAT glyph at the sizes the HMI uses it at, so a shifted
/// code point or a re-generated TfcIcons font shows up as a golden diff rather
/// than as a tofu box on a live page.
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
                for (final size in sizes)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Icon(ethercaticon, size: size, color: Colors.white),
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
  group('ethercat icon registration', () {
    test('round-trips through the JSON converter', () {
      const converter = IconDataConverter();
      final icon = converter.fromJson('ethercat');
      expect(icon, ethercaticon);
      expect(converter.toJson(icon), 'ethercat');
    });

    test('comes from TfcIcons', () {
      expect(ethercaticon.fontFamily, 'TfcIcons');
      expect(ethercaticon.fontPackage, 'tfc');
    });

    test('is offered in the icon picker', () {
      expect(iconList, contains(ethercaticon));
    });
  });

  group('ethercat icon golden tests', skip: goldenSkip, () {
    // The test environment does not register fonts declared in pubspec.yaml,
    // so without this the icon renders as a tofu box and the golden would
    // happily lock in a missing glyph.
    setUpAll(() async {
      final bytes = File('assets/fonts/TfcIcons.ttf').readAsBytesSync();
      for (final family in ['packages/tfc/TfcIcons', 'TfcIcons']) {
        await (FontLoader(family)
              ..addFont(Future.value(ByteData.view(bytes.buffer))))
            .load();
      }
    });

    testWidgets('ethercat renders from the icon font', (tester) async {
      await tester.pumpWidget(buildIconSheet());
      await expectLater(
        find.byKey(_iconsKey),
        matchesGoldenFile('goldens/ethercat_icon.png'),
      );
    });
  });
}

/// Goldens for the air cabinet asset under both app themes.
///
/// The cabinet used to be drawn with baked light-theme colors — a
/// `Colors.grey[200]` body, a `Colors.black26` border, white "off" LEDs — so
/// on the dark page it was a bright card sitting on a dark background. These
/// two images are the pair that shows it: the same asset, the same size, one
/// per scheme, and they must not look alike.
///
/// Hosted the way `AssetStack` hosts it: a fixed box centered on a canvas
/// painted in the scheme's own surface color, so the contrast between the
/// cabinet and the page it sits on is part of the picture.
///
/// To update: flutter test test/page_creator/assets/aircab_golden_test.dart --update-goldens
library;

import 'dart:io' show File, Platform;
import 'dart:typed_data' show ByteData;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:tfc/page_creator/assets/aircab.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/theme.dart' show solarized;
import '../../helpers/golden_platform.dart';

const _boundaryKey = Key('aircab_golden');

const _pressureKey = 'ST101.AIR01.PRESSURE';
const _softStartKey = 'ST101.AIR01.SOFTSTART';

AirCabConfig _config() => AirCabConfig(
      label: 'Air cabinet',
      pressureKey: _pressureKey,
      softStartKey: _softStartKey,
      buttonKey: '',
    );

/// The keys are bound and streaming, so the LEDs paint their *off* color
/// rather than `LEDPainter`'s "no value yet" marker. Off is the state the
/// asset spends its life in, and the one that used to be a white dot.
List<Override> _lit({required bool pressure, required bool softStart}) => [
      keyStreamProvider(_pressureKey)
          .overrideWith((ref) => Stream.value(DynamicValue(value: pressure))),
      keyStreamProvider(_softStartKey)
          .overrideWith((ref) => Stream.value(DynamicValue(value: softStart))),
    ];

Future<void> _pumpCabinet(
  WidgetTester tester,
  ThemeData theme, {
  bool pressure = false,
  bool softStart = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: _lit(pressure: pressure, softStart: softStart),
      child: MaterialApp(
        key: ValueKey(theme.brightness),
        theme: theme,
        home: Scaffold(
          backgroundColor: theme.colorScheme.surface,
          body: Center(
            child: RepaintBoundary(
              key: _boundaryKey,
              child: ColoredBox(
                color: theme.colorScheme.surface,
                // 2:1, not a square: the cabinet fills the box it is given
                // (no AspectRatio wrapper any more), and it takes about
                // twice the width for "Pressure" and "Soft start" to render
                // beside their lamps without ellipsizing — which is how the
                // asset is meant to be laid out on a page.
                child: SizedBox(
                  width: 440,
                  height: 240,
                  child: Center(
                    child: SizedBox(
                      width: 400,
                      height: 200,
                      child: AirCab(config: _config()),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  final (light, dark) = solarized();

  // `test/flutter_test_config.dart` registers no font, and the cabinet is
  // mostly text and icons — without these the goldens are Ahem blocks and no
  // one can tell by eye whether they are right.
  setUpAll(() async {
    Future<void> loadFont(String family, String path) async {
      final bytes = File(path).readAsBytesSync();
      await (FontLoader(family)
            ..addFont(Future.value(ByteData.view(bytes.buffer))))
          .load();
    }

    await loadFont('Roboto', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');
    await loadFont(
        'roboto-mono', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');

    final flutterRoot = Platform.environment['FLUTTER_ROOT'];
    for (final candidate in <String>[
      if (flutterRoot != null)
        '$flutterRoot/bin/cache/artifacts/material_fonts/'
            'MaterialIcons-Regular.otf',
      '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/'
          'MaterialIcons-Regular.otf',
    ]) {
      if (File(candidate).existsSync()) {
        await loadFont('MaterialIcons', candidate);
        break;
      }
    }
  });

  group('Air cabinet goldens',
      skip: goldenSkip, () {
    testWidgets('dark scheme, both LEDs off', (tester) async {
      await _pumpCabinet(tester, dark);
      await expectLater(
        find.byKey(_boundaryKey),
        matchesGoldenFile('goldens/aircab/dark.png'),
      );
    });

    testWidgets('light scheme, both LEDs off', (tester) async {
      await _pumpCabinet(tester, light);
      await expectLater(
        find.byKey(_boundaryKey),
        matchesGoldenFile('goldens/aircab/light.png'),
      );
    });

    testWidgets('dark scheme, air up and soft start done', (tester) async {
      await _pumpCabinet(tester, dark, pressure: true, softStart: true);
      await expectLater(
        find.byKey(_boundaryKey),
        matchesGoldenFile('goldens/aircab/dark_lit.png'),
      );
    });
  });
}

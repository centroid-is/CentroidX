/// Golden images of the image asset itself, one per aspect of its rendering
/// contract: each supported format through its real codec path, the
/// placeholder and broken states an operator can meet, and the fit / rotation
/// / opacity knobs.
///
/// All rasters are the same 48x32 quadrant fixture (red/gold over blue/green,
/// white diagonal), so a format that decodes wrong, flips, or letterboxes
/// differently is visible at a glance — and the SVG draws the same pattern,
/// so raster and vector renders should look alike.
///
/// To update: flutter test test/page_creator/assets/image_golden_test.dart --update-goldens
library;

import 'dart:io' show File, Platform;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/image.dart';
import 'package:tfc/page_creator/assets/image_store.dart';
import 'package:tfc/providers/page_images.dart';

import '../../helpers/golden_tolerance.dart';
import '../../helpers/image_fixtures.dart';
import '../../helpers/page_editor_harness.dart';
import '../../helpers/golden_platform.dart';

const _boundaryKey = Key('image_asset_golden');

/// Pumps [child] against the dark canvas the other asset goldens use, wired
/// to [store], and lets the engine finish decoding before capture.
Future<void> _pump(
  WidgetTester tester,
  PageImageStore store,
  Widget child, {
  Size size = const Size(200, 200),
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [pageImageStoreProvider.overrideWith((ref) async => store)],
      child: MaterialApp(
        home: Scaffold(
          backgroundColor: const Color(0xFF1A1A2E),
          body: Center(
            child: RepaintBoundary(
              key: _boundaryKey,
              // The background sits inside the boundary so the capture shows
              // the same dark canvas the operator screens use.
              child: ColoredBox(
                color: const Color(0xFF1A1A2E),
                child: SizedBox(
                  width: size.width,
                  height: size.height,
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  // Raster decode and SVG parsing both run through real async engine work.
  await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)));
  await tester.pumpAndSettle();
}

/// Goldens whose pixels come from a font or the SVG rasteriser drift more
/// across Flutter versions than the CustomPaint drawings the suite-wide
/// 0.01% tolerance was sized for: the icon glyphs moved 0.03–0.04% and the
/// SVG's antialiased diagonal 1.0% between Flutter 3.41 and 3.44, with no
/// change to the widget. A real regression on a 200x200 capture — a wrong
/// colour, a missing quadrant, a dropped glyph — shifts tens of percent, so
/// these still fail loudly.
const double _glyphTolerance = 0.005;
const double _vectorTolerance = 0.02;

Future<void> _expectGolden(WidgetTester tester, String name,
    {double? tolerance}) async {
  final previous = goldenFileComparator;
  if (tolerance != null && previous is LocalFileComparator) {
    goldenFileComparator = TolerantGoldenComparator(
      previous.basedir.resolve('image_golden_test.dart'),
      tolerance: tolerance,
    );
  }
  try {
    await expectLater(
      find.byKey(_boundaryKey),
      matchesGoldenFile('goldens/image/$name.png'),
    );
  } finally {
    goldenFileComparator = previous;
  }
}

void main() {
  group('Image asset golden tests',
      skip: goldenSkip, () {
    // Same font wiring as page_editor_golden_test.dart: without a real text
    // font the fit labels render as Ahem blocks, and without MaterialIcons
    // the placeholder/broken glyphs are boxes.
    setUpAll(() async {
      Future<void> loadFont(String family, String path) async {
        final bytes = File(path).readAsBytesSync();
        await (FontLoader(family)
              ..addFont(Future.value(ByteData.view(bytes.buffer))))
            .load();
      }

      await loadFont(
          'Roboto', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');

      final flutterRoot = Platform.environment['FLUTTER_ROOT'] ??
          (Platform.resolvedExecutable.contains('flutter')
              ? null
              : File(Platform.resolvedExecutable).parent.path);
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

    late PageImageStore store;

    setUp(() async => store = await testImageStore());

    Future<ImageConfig> assetWith(List<int> bytes) async {
      final id = await store.save(Uint8List.fromList(bytes));
      return ImageConfig(imageId: id);
    }

    testWidgets('placeholder before an image is chosen', (tester) async {
      final config = ImageConfig();
      await _pump(tester, store, Builder(builder: config.build));
      await _expectGolden(tester, 'placeholder', tolerance: _glyphTolerance);
    });

    testWidgets('broken glyph for a dangling id', (tester) async {
      final config = ImageConfig(imageId: 'feedfeedfeedfeedfeedfeed');
      await _pump(tester, store, Builder(builder: config.build));
      await _expectGolden(tester, 'missing_bytes', tolerance: _glyphTolerance);
    });

    for (final (name, bytes) in [
      ('png', fixturePngBytes),
      ('jpeg', fixtureJpegBytes),
      ('bmp', fixtureBmpBytes),
      ('svg', fixtureSvgBytes),
    ]) {
      testWidgets('$name renders the quadrant fixture, contained',
          (tester) async {
        final config = await assetWith(bytes);
        await _pump(tester, store, Builder(builder: config.build));
        await _expectGolden(tester, name,
            tolerance: name == 'svg' ? _vectorTolerance : null);
      });
    }

    testWidgets('the BoxFit options against a non-matching box',
        (tester) async {
      final id = await store.save(fixturePngBytes);
      // A 3:2 image in 1:1 cells: contain letterboxes, cover crops, fill
      // distorts, the rest do what their names say.
      final fits = [
        BoxFit.contain,
        BoxFit.cover,
        BoxFit.fill,
        BoxFit.fitWidth,
        BoxFit.fitHeight,
        BoxFit.none,
      ];
      await _pump(
        tester,
        store,
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final fit in fits)
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 96,
                    height: 96,
                    decoration:
                        BoxDecoration(border: Border.all(color: Colors.white38)),
                    child: Builder(
                        builder: ImageConfig(imageId: id, fit: fit).build),
                  ),
                  Text(fit.name,
                      style:
                          const TextStyle(color: Colors.white, fontSize: 10)),
                ],
              ),
          ],
        ),
        size: const Size(340, 260),
      );
      await _expectGolden(tester, 'fit_matrix');
    });

    testWidgets('rotation happens inside the asset, like other assets',
        (tester) async {
      final config = await assetWith(fixturePngBytes)
        ..coordinates = Coordinates(x: 0.5, y: 0.5, angle: 45);
      await _pump(tester, store, Builder(builder: config.build));
      await _expectGolden(tester, 'rotated_45');
    });

    testWidgets('half opacity lets the canvas show through', (tester) async {
      final config = await assetWith(fixturePngBytes)
        ..opacity = 0.5;
      await _pump(
        tester,
        store,
        Container(
          color: Colors.teal,
          child: Builder(builder: config.build),
        ),
      );
      await _expectGolden(tester, 'opacity_50');
    });

    testWidgets('the palette tile: preview build at thumbnail size',
        (tester) async {
      // What _PaletteItem renders for the asset before it has an image.
      final config = ImageConfig.preview();
      await _pump(
        tester,
        store,
        FittedBox(
          fit: BoxFit.contain,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: 80,
            height: 80,
            child: Builder(builder: config.build),
          ),
        ),
        size: const Size(80, 80),
      );
      await _expectGolden(tester, 'palette_tile', tolerance: _glyphTolerance);
    });
  });
}

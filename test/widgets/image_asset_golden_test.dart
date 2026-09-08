/// Golden images of the image asset inside the real page editor, for design
/// review of the feature as an operator meets it.
///
/// Three surfaces:
///
///   * **The canvas.** A PNG with a label, an SVG, and a rotated
///     half-transparent BMP — the same 48x32 quadrant fixture in every
///     format, so codec differences would show side by side.
///   * **The config pane.** Preview, source name, choose/paste buttons, fit
///     dropdown, opacity slider and the shared label/size/position fields,
///     all inside the 520 px pane.
///   * **The palette.** The Image tile among the other assets, filtered by
///     search, showing the placeholder thumbnail a fresh drop gets.
///
/// To update: flutter test test/widgets/image_asset_golden_test.dart --update-goldens
@Tags(['golden'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tfc/models/menu_item.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/image.dart';
import 'package:tfc/page_creator/page.dart';
import 'package:tfc/theme.dart';

import '../helpers/golden_tolerance.dart';
import '../helpers/image_fixtures.dart';
import '../helpers/page_editor_harness.dart';

/// A 1080p operator panel, like the other editor goldens.
const Size _screen = Size(1920, 1080);

Future<FakeEditorPreferences> _pumpEditorWithImages(
  WidgetTester tester, {
  required ThemeData theme,
}) async {
  tester.view.physicalSize = _screen;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  // Blobs live beside the pages, on rows in the same store the manager saves
  // into, so seed them through the guard that manager was built with.
  final prefs = FakeEditorPreferences();
  final store = await imageStoreOf(prefs);
  final pngId = await store.save(fixturePngBytes);
  final svgId = await store.save(fixtureSvgBytes);
  final bmpId = await store.save(fixtureBmpBytes);

  final assets = <Asset>[
    ImageConfig(imageId: pngId, sourceName: 'multivac.png', naturalAspect: 1.5)
      ..coordinates = Coordinates(x: 0.28, y: 0.33)
      ..size = const RelativeSize(width: 0.16, height: 0.19)
      ..text = 'Multivac'
      ..textPos = TextPos.below,
    ImageConfig(imageId: svgId, sourceName: 'line-diagram.svg')
      ..coordinates = Coordinates(x: 0.60, y: 0.33)
      ..size = const RelativeSize(width: 0.16, height: 0.19),
    ImageConfig(
        imageId: bmpId, sourceName: 'legacy-scan.bmp', opacity: 0.5)
      ..coordinates = Coordinates(x: 0.44, y: 0.70, angle: 30)
      ..size = const RelativeSize(width: 0.14, height: 0.17),
  ];

  final manager = PageManager(
    prefs: prefs,
    pages: {
      '/': AssetPage(
        menuItem:
            const MenuItem(label: 'Packing', path: '/', icon: Icons.home),
        assets: assets,
        mirroringDisabled: true,
        navigationPriority: 0,
      ),
    },
  );

  await tester.pumpWidget(buildEditorUnderTest(manager, theme: theme));
  await tester.pumpAndSettle();
  // Let the engine finish decoding the rasters before capture.
  await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)));
  await tester.pumpAndSettle();
  return prefs;
}

void main() {
  // Looser than the 0.01% default, because this file is the one golden set
  // that decodes real image bytes -- a PNG, an SVG and a rotated translucent
  // BMP -- and those land a couple of hundred pixels differently depending on
  // when the decode finishes relative to the frame. Run alone it matched
  // exactly; run inside the full suite it came in at 264px, 0.0001 of the
  // frame, right on the default threshold. A real regression here moves whole
  // images, not a rotated edge.
  useTolerantGoldenComparator(tolerance: 0.0005);

  final (light, dark) = solarized();

  // Same font wiring as page_editor_golden_test.dart — without it the labels
  // and icons render as Ahem blocks.
  setUpAll(() async {
    Future<void> loadFont(String family, String path) async {
      final bytes = File(path).readAsBytesSync();
      await (FontLoader(family)
            ..addFont(Future.value(ByteData.view(bytes.buffer))))
          .load();
    }

    await loadFont(
        'roboto-mono', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');

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

  setUp(setUpEditorEnvironment);

  // testGoldenWidgets, not testWidgets: these capture the whole MaterialApp,
  // app bar included, and the bar carries a live clock. Under plain
  // testWidgets it renders the wall-clock time, so the committed PNG only ever
  // matched by staying under the 0.01% tolerance -- which it stopped doing
  // once the clock grew. The harness pins the clock so the pixels under review
  // are the only thing the comparison can disagree about.

  testGoldenWidgets('canvas with PNG, SVG and a rotated translucent BMP',
      (tester) async {
    await _pumpEditorWithImages(tester, theme: dark);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/image_assets_canvas_dark.png'),
    );
  });

  testGoldenWidgets('config pane on the labelled PNG', (tester) async {
    await _pumpEditorWithImages(tester, theme: dark);
    await chooseFromAssetMenu(tester, 0.28, 0.33, 'Edit');
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/image_config_pane_dark.png'),
    );
  });

  testGoldenWidgets('config pane — light', (tester) async {
    await _pumpEditorWithImages(tester, theme: light);
    await chooseFromAssetMenu(tester, 0.28, 0.33, 'Edit');
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/image_config_pane_light.png'),
    );
  });

  testGoldenWidgets('palette filtered to the Image tile', (tester) async {
    await _pumpEditorWithImages(tester, theme: dark);
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'image');
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/image_palette_dark.png'),
    );
  });
}

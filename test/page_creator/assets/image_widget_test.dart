/// How the image asset renders: right codec per format, placeholder and
/// broken states, and the fit / opacity / rotation knobs actually reaching
/// the widget tree. Pixel output is covered by image_golden_test.dart.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/image.dart';
import 'package:tfc/page_creator/assets/image_store.dart';
import 'package:tfc/providers/page_images.dart';

import '../../helpers/image_fixtures.dart';
import '../../helpers/page_editor_harness.dart';

/// Pumps the asset's [Asset.build] inside a provider scope wired to [store].
Future<void> pumpAsset(
  WidgetTester tester,
  ImageConfig config,
  PageImageStore store,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        pageImageStoreProvider.overrideWith((ref) async => store),
      ],
      child: MaterialApp(
        home: Center(
          child: SizedBox(
            width: 240,
            height: 160,
            child: Builder(builder: config.build),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  late PageImageStore store;

  setUp(() async => store = await testImageStore());

  testWidgets('renders a placeholder glyph before an image is chosen',
      (tester) async {
    await pumpAsset(tester, ImageConfig(), store);
    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('renders rasters with Image.memory, honouring the fit',
      (tester) async {
    for (final bytes in [fixturePngBytes, fixtureJpegBytes, fixtureBmpBytes]) {
      final id = await store.save(bytes);
      await pumpAsset(
          tester, ImageConfig(imageId: id, fit: BoxFit.cover), store);
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.fit, BoxFit.cover);
      expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
    }
  });

  testWidgets('renders SVG with SvgPicture, not Image', (tester) async {
    final id = await store.save(fixtureSvgBytes);
    await pumpAsset(tester, ImageConfig(imageId: id), store);
    expect(find.byType(SvgPicture), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('a dangling id (garbage-collected blob) shows the broken glyph',
      (tester) async {
    await pumpAsset(tester, ImageConfig(imageId: 'feedfeedfeedfeedfeedfeed'),
        store);
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
  });

  testWidgets('rotation and opacity wrap the image', (tester) async {
    final id = await store.save(fixturePngBytes);
    final config = ImageConfig(imageId: id, opacity: 0.5)
      ..coordinates = Coordinates(x: 0.5, y: 0.5, angle: 90);
    await pumpAsset(tester, config, store);

    expect(find.byType(LayoutRotatedBox), findsOneWidget);
    final opacity = tester.widget<Opacity>(find.byType(Opacity));
    expect(opacity.opacity, 0.5);
    // The rotated 48x32-shaped content sits inside a LayoutRotatedBox that
    // expands to the rotated bounding box.
    final rotated =
        tester.widget<LayoutRotatedBox>(find.byType(LayoutRotatedBox));
    expect(rotated.angle, closeTo(3.14159 / 2, 0.001));
  });

  testWidgets('full opacity adds no Opacity layer', (tester) async {
    final id = await store.save(fixturePngBytes);
    await pumpAsset(tester, ImageConfig(imageId: id), store);
    expect(find.byType(Opacity), findsNothing);
  });
}

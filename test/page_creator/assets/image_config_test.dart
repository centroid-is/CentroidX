/// The image asset's non-visual contract: format sniffing, the content-hash
/// blob store, ingest validation, and JSON round-tripping through the
/// registry. Rendering is covered by image_widget_test.dart and the goldens.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/image.dart';
import 'package:tfc/page_creator/assets/image_store.dart';
import 'package:tfc/page_creator/assets/registry.dart';

import '../../helpers/image_fixtures.dart';
import '../../helpers/page_editor_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('sniffImageFormat', () {
    test('identifies the supported formats by magic numbers', () {
      expect(sniffImageFormat(fixturePngBytes), PageImageFormat.png);
      expect(sniffImageFormat(fixtureJpegBytes), PageImageFormat.jpeg);
      expect(sniffImageFormat(fixtureBmpBytes), PageImageFormat.bmp);
      expect(sniffImageFormat(fixtureSvgBytes), PageImageFormat.svg);
    });

    test('accepts SVG with an XML prolog and a UTF-8 BOM', () {
      final prolog = utf8.encode('<?xml version="1.0"?>\n$fixtureSvgText');
      expect(sniffImageFormat(Uint8List.fromList(prolog)), PageImageFormat.svg);

      final bom = [0xEF, 0xBB, 0xBF, ...utf8.encode(fixtureSvgText)];
      expect(sniffImageFormat(Uint8List.fromList(bom)), PageImageFormat.svg);
    });

    test('rejects everything else', () {
      expect(sniffImageFormat(Uint8List.fromList(utf8.encode('hello'))), null);
      expect(sniffImageFormat(Uint8List.fromList([1, 2, 3])), null);
      expect(sniffImageFormat(Uint8List(0)), null);
      // XML that is not SVG.
      expect(
          sniffImageFormat(
              Uint8List.fromList(utf8.encode('<?xml version="1.0"?><a/>'))),
          null);
      // Binary garbage that is not valid UTF-8 either.
      expect(sniffImageFormat(Uint8List.fromList([0xC3, 0x28, 0x00, 0x00])),
          null);
    });
  });

  // The store's own put/get/garbage-collection contract moved to
  // `test/page_creator/image_store_test.dart` when 04-09 put image blobs on
  // `kind='page_image'` rows. What stays here is the one member that is a
  // pure function over page JSON and touches no store at all.
  group('PageImageStore.referencedImageIds', () {
    test('referencedImageIds finds ids anywhere in a page tree', () {
      final asset = ImageConfig()..imageId = 'aaa111';
      final tree = {
        '/': {
          'assets': [
            asset.toJson(),
            {'asset_name': 'ButtonConfig', 'text': 'no image here'},
          ],
        },
        '/other': {
          'assets': [
            (ImageConfig()..imageId = 'bbb222').toJson(),
          ],
        },
      };
      expect(PageImageStore.referencedImageIds(tree), {'aaa111', 'bbb222'});
      expect(PageImageStore.referencedImageIds({'x': 1}), isEmpty);
      expect(PageImageStore.referencedImageIds(null), isEmpty);
    });
  });

  group('ingestPageImage', () {
    late PageImageStore store;

    setUp(() async => store = await testImageStore());

    test('measures and stores each raster format', () async {
      for (final bytes in [fixturePngBytes, fixtureJpegBytes, fixtureBmpBytes]) {
        final ingest = await ingestPageImage(store, bytes);
        expect(ingest.aspectRatio, closeTo(48 / 32, 0.001),
            reason: 'fixtures are 48x32');
        expect(await store.load(ingest.id), bytes);
      }
    });

    test('reads SVG aspect from the viewBox', () async {
      final ingest = await ingestPageImage(store, fixtureSvgBytes);
      expect(ingest.format, PageImageFormat.svg);
      expect(ingest.aspectRatio, closeTo(1.5, 0.001));
    });

    test('rejects unsupported bytes without storing them', () async {
      final garbage = Uint8List.fromList(utf8.encode('plain text'));
      await expectLater(ingestPageImage(store, garbage),
          throwsA(isA<PageImageFormatException>()));
      expect(await store.storedIds(), isEmpty);
    });

    test('rejects a PNG header with a rotten body', () async {
      final rotten = Uint8List.fromList(
          [...fixturePngBytes.sublist(0, 16), 1, 2, 3, 4, 5]);
      await expectLater(ingestPageImage(store, rotten),
          throwsA(isA<PageImageFormatException>()));
      expect(await store.storedIds(), isEmpty);
    });
  });

  group('svgAspectRatio', () {
    test('prefers the viewBox, falls back to width/height, else null', () {
      expect(svgAspectRatio('<svg viewBox="0 0 100 50"/>'), 2.0);
      expect(svgAspectRatio('<svg width="30px" height="10px"/>'), 3.0);
      expect(svgAspectRatio('<svg viewBox="0 0 0 0" width="30" height="10"/>'),
          3.0);
      expect(svgAspectRatio('<svg/>'), null);
    });
  });

  group('ImageConfig JSON', () {
    test('round-trips through the registry', () {
      final config = ImageConfig(
        imageId: 'cafe01',
        sourceName: 'logo.png',
        naturalAspect: 1.5,
        fit: BoxFit.cover,
        opacity: 0.5,
      )
        ..text = 'Plant logo'
        ..textPos = TextPos.below
        ..coordinates = Coordinates(x: 0.25, y: 0.75, angle: 90);

      final parsed = AssetRegistry.parse(
        jsonDecode(jsonEncode({
          'assets': [config.toJson()]
        })) as Map<String, dynamic>,
      );
      expect(parsed, hasLength(1));
      final back = parsed.single as ImageConfig;
      expect(back.imageId, 'cafe01');
      expect(back.sourceName, 'logo.png');
      expect(back.naturalAspect, 1.5);
      expect(back.fit, BoxFit.cover);
      expect(back.opacity, 0.5);
      expect(back.text, 'Plant logo');
      expect(back.coordinates.angle, 90);
    });

    test('defaults: no image, contain, fully opaque, no PLC keys', () {
      final fresh = AssetRegistry.createDefaultAssetByName('ImageConfig');
      expect(fresh, isA<ImageConfig>());
      final config = fresh as ImageConfig;
      expect(config.imageId, null);
      expect(config.fit, BoxFit.contain);
      expect(config.opacity, 1.0);
      expect(config.size.width, 0.15);
      expect(config.allKeys, isEmpty,
          reason: 'image_id must not read as a PLC tag key');
    });

    test('parses minimal JSON the way pages persist it', () {
      final parsed = AssetRegistry.parse({
        'assets': [
          {
            'asset_name': 'ImageConfig',
            'coordinates': {'x': 0.5, 'y': 0.5},
            'size': {'width': 0.2, 'height': 0.1},
          }
        ]
      });
      final config = parsed.single as ImageConfig;
      expect(config.imageId, null);
      expect(config.fit, BoxFit.contain);
    });
  });
}

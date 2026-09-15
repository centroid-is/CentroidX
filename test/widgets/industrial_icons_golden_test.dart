import 'dart:io' show File;
import 'dart:typed_data' show ByteData;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/converter/icon.dart';
import 'package:tfc/widgets/icon_picker.dart';

import '../helpers/golden_platform.dart';

const _sheetKey = Key('industrial_icons');

/// The sizes an icon actually gets used at on a page and in a menu. A glyph
/// that resolves at 96 and turns to mush at 24 is a bug, and only a golden at
/// both sizes catches it.
const _sizes = <double>[72, 36, 22];

Widget buildIconSheet() {
  return MaterialApp(
    home: Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      body: Center(
        child: RepaintBoundary(
          key: _sheetKey,
          child: Container(
            color: const Color(0xFF1A1A2E),
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final row in _rows(industrialIcons.values.toList(), 7))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        for (final icon in row)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                for (final size in _sizes)
                                  Icon(icon, size: size, color: Colors.white),
                              ],
                            ),
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

List<List<T>> _rows<T>(List<T> items, int perRow) => [
      for (var i = 0; i < items.length; i += perRow)
        items.sublist(i, i + perRow > items.length ? items.length : i + perRow),
    ];

void main() {
  // Registration is font-independent, so it runs everywhere.
  group('industrial icon registration', () {
    test('every glyph round-trips through the JSON converter', () {
      const converter = IconDataConverter();
      for (final entry in industrialIcons.entries) {
        final icon = converter.fromJson(entry.key);
        expect(icon, entry.value, reason: '${entry.key} did not resolve');
        expect(converter.toJson(icon), entry.key,
            reason: '${entry.key} did not serialise back to its own name');
      }
    });

    test('all come from TfcIcons at distinct code points', () {
      final seen = <int>{};
      for (final entry in industrialIcons.entries) {
        expect(entry.value.fontFamily, 'TfcIcons', reason: entry.key);
        expect(entry.value.fontPackage, 'tfc', reason: entry.key);
        expect(seen.add(entry.value.codePoint), isTrue,
            reason: '${entry.key} reuses U+${entry.value.codePoint.toRadixString(16)}');
      }
    });

    test('do not collide with the Fontello glyphs already in the font', () {
      // U+E800..U+E808 are in saved pages. Reassigning one would silently
      // change the artwork on a live mimic.
      for (final entry in industrialIcons.entries) {
        expect(entry.value.codePoint, greaterThanOrEqualTo(0xe809),
            reason: entry.key);
      }
      for (final legacy in [
        baadericon,
        warehouse_open,
        warehouse_open1,
        warehouse_open2,
        warehouse_closed,
        pallet_top,
        pallet_stack,
        ethercaticon,
      ]) {
        expect(industrialIconNames.containsKey(legacy), isFalse);
      }
    });

    test('are all offered in the icon picker', () {
      for (final entry in industrialIcons.entries) {
        expect(iconList, contains(entry.value), reason: entry.key);
      }
    });

    test('every group member exists, and every glyph is in a group', () {
      final grouped = industrialIconGroups.values.expand((g) => g).toList();
      expect(grouped.toSet(), industrialIcons.keys.toSet());
      expect(grouped.length, grouped.toSet().length,
          reason: 'a glyph is listed in two groups');
    });

    test('the picker offers each group as its own section', () {
      final labels = [for (final section in iconPickerSections) section.$1];
      for (final group in industrialIconGroups.keys) {
        expect(labels, contains(group));
      }
    });

    test('the names people would search for are the names that are there', () {
      for (final name in [
        'motor',
        'vfd',
        'pump',
        'sensor_proximity',
        'io_module',
        'e_stop',
        'load_cell',
      ]) {
        expect(industrialIcons.containsKey(name), isTrue, reason: name);
      }
    });
  });

  group('industrial icon golden tests', skip: goldenSkip, () {
    // The test environment does not register fonts declared in pubspec.yaml,
    // so without this every glyph renders as a tofu box and the golden would
    // happily lock in a missing font.
    setUpAll(() async {
      final bytes = File('assets/fonts/TfcIcons.ttf').readAsBytesSync();
      for (final family in ['packages/tfc/TfcIcons', 'TfcIcons']) {
        await (FontLoader(family)
              ..addFont(Future.value(ByteData.view(bytes.buffer))))
            .load();
      }
    });

    testWidgets('all render from the icon font', (tester) async {
      tester.view.physicalSize = const Size(1700, 1100);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(buildIconSheet());
      await expectLater(
        find.byKey(_sheetKey),
        matchesGoldenFile('goldens/industrial_icons.png'),
      );
    });
  });
}

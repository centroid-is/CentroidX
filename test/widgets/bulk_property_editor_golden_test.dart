/// How the multi-select property pane looks: the agreeing case, the
/// disagreeing case, and what is left of a pane when the selection is a mix
/// of asset kinds.
///
/// The disagreeing case is the one worth an image. Every row type has its own
/// way of saying "these assets do not agree" — an italic hint in a text box,
/// a tristate checkbox, a dropdown showing no value, a hatched swatch — and
/// they have to read as the same statement down the column, or the pane looks
/// like four unrelated controls that happen to be empty.
library;

import 'dart:io' show File, Platform;
import 'dart:typed_data' show ByteData;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/converter/color_converter.dart' show AssetColor;
import 'package:tfc/page_creator/assets/analog_box.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/led.dart';
import 'package:tfc/page_creator/assets/schneider.dart';
import 'package:tfc/theme.dart' show solarized;
import 'package:tfc/widgets/bulk_property_editor.dart';
import 'package:tfc/widgets/panes/side_pane.dart' show SidePane;
import '../helpers/golden_platform.dart';

const Key _paneKey = Key('bulk_property_pane_golden');

SchneiderATV320Config _drive({
  double? fontSize,
  String? label,
  double width = .08,
  double height = .12,
  double x = .2,
  double y = .3,
}) =>
    SchneiderATV320Config(label: label, labelFontSize: fontSize)
      ..size = RelativeSize(width: width, height: height)
      ..coordinates = Coordinates(x: x, y: y);

/// Pumps the pane at [height], having first grown the test surface to fit it.
///
/// The default 800x600 surface clips a pane long enough to show every row
/// type, and a clipped golden reviews only the top of what changed.
Future<void> _pumpPane(
  WidgetTester tester, {
  required List<Asset> selection,
  required String title,
  String? subtitle,
  required double height,
  bool dark = false,
}) async {
  tester.view
    ..physicalSize = Size(420, height + 40)
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_buildPane(
    selection: selection,
    title: title,
    subtitle: subtitle,
    height: height,
    dark: dark,
  ));
  await tester.pumpAndSettle();
}

/// The pane at the width the editor opens it to, in the app's real Solarized
/// theme — the colours an operator actually sees, not Flutter's defaults.
Widget _buildPane({
  required List<Asset> selection,
  required String title,
  String? subtitle,
  required double height,
  bool dark = false,
}) {
  final (light, darkTheme) = solarized();
  final theme = dark ? darkTheme : light;
  return MaterialApp(
    theme: theme,
    home: Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: Center(
        child: RepaintBoundary(
          key: _paneKey,
          child: SizedBox(
            width: 360,
            height: height,
            // The Material the real pane shell wraps every pane in — without
            // it the body renders on the default white and a dark-station
            // golden reviews a page that never ships.
            child: Material(
              color: theme.colorScheme.surface,
              child: SidePane(
                title: title,
                subtitle: subtitle,
                icon: Icons.tune,
                scrollable: false,
                child: BulkPropertyEditor(
                  selection: selection,
                  onBeforeChange: () {},
                  onChanged: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Real glyphs, not the placeholder block font. Same pattern as
/// alarm_visibility_golden_test.
Future<void> _loadFonts() async {
  Future<void> load(String family, String path) async {
    final file = File(path);
    if (!file.existsSync()) return;
    await (FontLoader(family)
          ..addFont(Future.value(ByteData.view(file.readAsBytesSync().buffer))))
        .load();
  }

  // The Solarized theme sets fontFamily 'roboto-mono'; register the file under
  // the default family too so unthemed text matches.
  await load('Roboto', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');
  await load('roboto-mono', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');

  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    await load('MaterialIcons',
        '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  }
}

void main() {
  setUpAll(_loadFonts);

  group('Bulk property pane goldens',
      skip: goldenSkip, () {
    testWidgets('four drives that agree on everything', (tester) async {
      await _pumpPane(tester,
        selection: [
          for (var i = 0; i < 4; i++) _drive(fontSize: 12, label: 'M1'),
        ],
        title: '4 assets',
        subtitle: 'Schneider ATV320 ×4',
        height: 640,
      );
      await expectLater(
        find.byKey(_paneKey),
        matchesGoldenFile('goldens/bulk_properties_uniform.png'),
      );
    });

    testWidgets('four drives that disagree about almost everything',
        (tester) async {
      // Same width and label position across all four, everything else
      // different — so the image shows agreement and disagreement side by
      // side rather than a column of empty boxes.
      await _pumpPane(tester,
        selection: [
          _drive(fontSize: 12, label: 'M1', x: .1, y: .2),
          _drive(fontSize: 18, label: 'M2', x: .4, y: .2),
          _drive(label: 'M3', x: .7, y: .2, height: .2),
          _drive(fontSize: 9, x: .9, y: .2),
        ],
        title: '4 assets',
        subtitle: 'Schneider ATV320 ×4',
        height: 640,
      );
      await expectLater(
        find.byKey(_paneKey),
        matchesGoldenFile('goldens/bulk_properties_mixed.png'),
      );
    });

    testWidgets('every row type disagreeing at once', (tester) async {
      // The analog box is the asset that carries one of each: numbers, text,
      // checkboxes and a stack of colour swatches. This is the image that
      // says whether "Multiple values" reads consistently across all of them.
      await _pumpPane(tester,
        selection: [
          AnalogBoxConfig(
            analogKey: 'a',
            minValue: 0,
            maxValue: 100,
            units: 'bar',
            vertical: true,
            fillColor: const Color(0xFF6EC1E4),
          ),
          AnalogBoxConfig(
            analogKey: 'b',
            minValue: -50,
            maxValue: 250,
            units: 'kg',
            vertical: false,
            fillColor: const Color(0xFFB58900),
          ),
        ],
        title: '2 assets',
        subtitle: 'Analog Box ×2',
        height: 1120,
      );
      await expectLater(
        find.byKey(_paneKey),
        matchesGoldenFile('goldens/bulk_properties_every_row_type.png'),
      );
    });

    testWidgets('a mixed-kind selection keeps only the shared rows',
        (tester) async {
      await _pumpPane(tester,
        selection: [
          _drive(fontSize: 12),
          LEDConfig(key: 'a', onColor: AssetColor.green)
            ..size = const RelativeSize(width: .03, height: .03),
        ],
        title: '2 assets',
        subtitle: 'Schneider ATV320, LED',
        height: 500,
      );
      await expectLater(
        find.byKey(_paneKey),
        matchesGoldenFile('goldens/bulk_properties_mixed_kinds.png'),
      );
    });

    testWidgets('disagreement reads the same on a dark station',
        (tester) async {
      await _pumpPane(tester,
        selection: [
          _drive(fontSize: 12, label: 'M1', x: .1),
          _drive(fontSize: 18, label: 'M2', x: .4),
        ],
        title: '2 assets',
        subtitle: 'Schneider ATV320 ×2',
        height: 640,
        dark: true,
      );
      await expectLater(
        find.byKey(_paneKey),
        matchesGoldenFile('goldens/bulk_properties_mixed_dark.png'),
      );
    });
  });
}

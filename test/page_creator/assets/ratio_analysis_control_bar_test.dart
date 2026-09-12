import 'dart:async' show Completer;
import 'dart:io' show File, Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/ratio_number.dart';
import 'package:tfc/providers/database.dart' show databaseProvider;
import 'package:tfc_dart/core/database.dart' show Database;
import '../../helpers/golden_platform.dart';

/// The accept/reject window's control bar.
///
/// It used to be a `Stack`: the chart/table toggle was painted centred ON TOP
/// of the row holding the interval picker and the refresh button. That reads
/// fine at 640px and collides the moment the floating dialog is dragged
/// narrower — and the dialog can be dragged down to 320px, where the toggle
/// sat squarely over the interval picker.
void main() {
  Widget wrap(Widget child, {required double width}) {
    return ProviderScope(
      overrides: [
        // The view fetches on mount; parking the database leaves it on the
        // seeded (empty) queues, which is all a layout test needs.
        databaseProvider.overrideWith((ref) => Completer<Database?>().future),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(width: width, height: 400, child: child),
          ),
        ),
      ),
    );
  }

  RatioNumberConfig configWith(List<int> presets) => RatioNumberConfig(
        key1: 'accepted',
        key2: 'rejected',
        key1Label: 'accepted',
        key2Label: 'rejected',
        sinceMinutes: const Duration(minutes: 30),
        intervalPresets: presets,
      );

  /// Every interval chip's rect, in the coordinate space of the test.
  List<Rect> chipRects(WidgetTester tester) => tester
      .widgetList<ChoiceChip>(find.byType(ChoiceChip))
      .map((chip) => tester.getRect(find.byWidget(chip)))
      .toList();

  // The dialog's own floor: `_FloatingDialogShellState._minSize` is 320x240,
  // so this is the narrowest the control bar ever has to survive.
  for (final width in const [320.0, 480.0, 640.0]) {
    testWidgets('the chart/table toggle never lands on the interval picker '
        'at ${width.toInt()}px', (tester) async {
      await tester.pumpWidget(wrap(
        RatioAnalysisView(
          config: configWith(const [1, 5, 10, 30, 60, 240]),
          key1Queue: const [],
          key2Queue: const [],
        ),
        width: width,
      ));
      await tester.pump();

      final toggle = tester.getRect(find.byType(ToggleButtons));
      expect(chipRects(tester), isNotEmpty);
      for (final chip in chipRects(tester)) {
        expect(chip.overlaps(toggle), isFalse,
            reason: 'Interval chip $chip sits under the chart/table toggle '
                '$toggle at ${width}px wide.');
      }
    });
  }

  testWidgets('the control bar fits its width instead of overflowing it',
      (tester) async {
    await tester.pumpWidget(wrap(
      RatioAnalysisView(
        config: configWith(const [1, 5, 10, 30, 60, 240]),
        key1Queue: const [],
        key2Queue: const [],
      ),
      width: 320,
    ));
    await tester.pump();

    // A RenderFlex overflow is reported as a framework error, which the test
    // harness would surface here.
    expect(tester.takeException(), isNull);
    for (final chip in chipRects(tester)) {
      expect(chip.right, lessThanOrEqualTo(tester.getRect(find.byType(RatioAnalysisView)).right + 0.5),
          reason: 'Chip $chip runs past the right edge of the dialog.');
    }
  });

  testWidgets('the picker offers every configured interval and marks the '
      'active one', (tester) async {
    await tester.pumpWidget(wrap(
      RatioAnalysisView(
        config: configWith(const [1, 5, 10, 30, 60, 240]),
        key1Queue: const [],
        key2Queue: const [],
        initialInterval: const Duration(minutes: 30),
      ),
      width: 640,
    ));
    await tester.pump();

    expect(find.byType(ChoiceChip), findsNWidgets(6));
    // 30 minutes is on the ladder and is what the view opened on — before
    // this it was the RatioNumber default ([1, 5, 10, 60, 240]) and a
    // 30-minute readout opened its chart with nothing selected.
    final selected = tester
        .widgetList<ChoiceChip>(find.byType(ChoiceChip))
        .where((c) => c.selected)
        .toList();
    expect(selected, hasLength(1));
    expect((selected.single.label as Text).data, '30m');
  });

  testWidgets('a single interval draws no picker at all', (tester) async {
    await tester.pumpWidget(wrap(
      RatioAnalysisView(
        config: configWith(const [30]),
        key1Queue: const [],
        key2Queue: const [],
      ),
      width: 640,
    ));
    await tester.pump();

    expect(find.byType(ChoiceChip), findsNothing);
  });

  // A golden at the narrowest the dialog can be dragged, which is where the
  // old centred Stack put the chart/table toggle on top of the interval
  // picker. Rendering it is the only way to see that the bar reflows rather
  // than collides.
  testWidgets('narrow control bar golden', (tester) async {
    final data = File('lib/fonts/roboto-mono/RobotoMono-Regular.ttf')
        .readAsBytesSync()
        .buffer
        .asByteData();
    await (FontLoader('Roboto')..addFont(Future.value(data))).load();
    final flutterRoot = Platform.environment['FLUTTER_ROOT'];
    final iconFont = File('$flutterRoot/bin/cache/artifacts/material_fonts/'
        'MaterialIcons-Regular.otf');
    if (flutterRoot != null && iconFont.existsSync()) {
      await (FontLoader('MaterialIcons')
            ..addFont(Future.value(iconFont.readAsBytesSync().buffer.asByteData())))
          .load();
    }

    tester.view.physicalSize = const Size(340, 200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWith((ref) => Completer<Database?>().future),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Colors.white,
          body: RepaintBoundary(
            key: const Key('ratio_control_bar'),
            child: SizedBox(
              width: 320,
              height: 180,
              // The bar only; the chart below it is a separate concern and
              // would churn this golden on every plotting tweak.
              child: Align(
                alignment: Alignment.topLeft,
                child: RatioAnalysisView(
                  config: configWith(const [1, 5, 10, 30, 60, 240]),
                  key1Queue: const [],
                  key2Queue: const [],
                  initialInterval: const Duration(minutes: 30),
                ),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();

    await expectLater(
      find.byKey(const Key('ratio_control_bar')),
      matchesGoldenFile('goldens/ratio_analysis_control_bar_narrow.png'),
    );
  }, tags: ['golden'], skip: goldenSkipFlag);
}

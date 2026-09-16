// The two things this file pins down, both of which are only visible as
// pixels:
//
//   1. the pane trend preview drawn against a pinned y-axis beside the same
//      samples auto-scaled;
//   2. an analog box whose name titles its pane but is kept off the mimic,
//      beside the same box with its caption painted.
//
// Both tiles chart the same samples, which sit in a narrow band. Left: the
// asset's `GraphAssetConfig` pins the axis to 0–100, so the trace reads as a
// level — low, and steady. Right: nothing pinned, so the plot scales to the
// data and the same steady signal fills the tile as if it were swinging. A
// row of boxes is comparable only in the left shape, and until this change
// the pane preview could only draw the right one.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tfc/page_creator/assets/analog_box.dart';
import 'package:tfc/page_creator/assets/common.dart'
    show Coordinates, RelativeSize, TextPos;
import 'package:tfc/pages/page_view.dart' show AssetStack;
import 'package:tfc/widgets/graph.dart' show GraphAxisConfig;
import 'package:tfc/widgets/panes/pane_chrome.dart'
    show PaneGraphTile, PaneSection, kPaneTrendTileHeight, kPaneTrendDialogSize;
import 'package:tfc_dart/core/collector.dart' show Collector;
import 'package:tfc_dart/core/database.dart' show TimeseriesData;

import '../../helpers/golden_fonts.dart';
import '../../helpers/golden_platform.dart';
import '../../helpers/test_helpers.dart' show useInMemoryDeviceLocalPreferences;

const _key = Key('analog_box_trend_axis_golden');
const _nameKey = Key('analog_box_name_visibility_golden');

/// A buffer level wandering inside a few percent — the signal that looks
/// dramatic auto-scaled and calm against a pinned scale.
const List<double> _samples = [
  41.2,
  41.6,
  42.4,
  43.1,
  42.8,
  42.1,
  41.5,
  41.9,
  42.6,
  43.4,
  43.9,
  43.2,
  42.5,
  42.0,
  42.3,
  42.7,
];

/// A fixed window, so the chart never prints the wall clock into the image.
final DateTime _t0 = DateTime.utc(2026, 1, 1, 8);
const Duration _step = Duration(seconds: 20);
final DateTimeRange _window = DateTimeRange(
  start: _t0,
  end: _t0.add(_step * (_samples.length - 1)),
);

/// `Collector` is concrete and reaches for a `StateMan` and a `Database`,
/// neither of which a golden should need: the chart takes its collector as a
/// constructor argument, so faking the one method it calls is enough.
class _FakeCollector extends Fake implements Collector {
  @override
  Stream<List<TimeseriesData<dynamic>>> collectStream(String key,
          {Duration since = const Duration(days: 1)}) =>
      Stream.value([
        for (var i = 0; i < _samples.length; i++)
          TimeseriesData<dynamic>(_samples[i], _t0.add(_step * i)),
      ]);
}

/// One tile built the way the pane builds it — the shared trend height, the
/// series named in the header, the shared dialog size — with only the chart
/// swapped for a collector-free one on a fixed window.
Widget _tile(String label, GraphAxisConfig? yAxis) => Expanded(
      child: PaneSection(
        title: label,
        child: PaneGraphTile(
          label: 'Level',
          height: kPaneTrendTileHeight,
          preview: AnalogBoxTrendGraph(
            collector: _FakeCollector(),
            keyName: 'some.key',
            seriesLabel: 'Level',
            units: '%',
            showButtons: false,
            compact: true,
            yAxis: yAxis,
            xRange: _window,
          ),
          expandedTitle: 'Tank level — trend',
          expandedSize: kPaneTrendDialogSize,
          expandedBuilder: (_) => const SizedBox.shrink(),
        ),
      ),
    );

void main() {
  group('the pane trend preview honours the configured y-axis',
      skip: goldenSkip, () {
    setUpAll(loadGoldenFonts);

    testWidgets('pinned beside auto-scaled, same samples', (tester) async {
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.white,
            body: Center(
              child: RepaintBoundary(
                key: _key,
                child: SizedBox(
                  width: 760,
                  height: 180,
                  child: Material(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _tile(
                          'Pinned 0 – 100',
                          const GraphAxisConfig(unit: '%', min: 0, max: 100),
                        ),
                        _tile('Auto', const GraphAxisConfig(unit: '%')),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byKey(_key),
        matchesGoldenFile('goldens/analog_box_trend_axis.png'),
      );
    });
  });

  group('the name can title the pane without captioning the mimic',
      skip: goldenSkip, () {
    setUpAll(loadGoldenFonts);
    // `AssetStack` reads the device-local config store for its mirroring
    // preference; without this it throws before a pixel is drawn.
    setUp(useInMemoryDeviceLocalPreferences);

    testWidgets('captioned beside bare, same name', (tester) async {
      AnalogBoxConfig box({required double x, required bool showName}) =>
          AnalogBoxConfig(
            analogKey: '',
            units: '%',
            showName: showName,
          )
            ..text = 'Tank level'
            ..textPos = TextPos.below
            ..coordinates = Coordinates(x: x, y: 0.42)
            ..size = const RelativeSize(width: 0.14, height: 0.5);

      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.white,
            body: Center(
              child: RepaintBoundary(
                key: _nameKey,
                child: SizedBox(
                  width: 420,
                  height: 240,
                  child: LayoutBuilder(
                    builder: (context, constraints) => AssetStack(
                      assets: [
                        box(x: 0.3, showName: true),
                        box(x: 0.7, showName: false),
                      ],
                      constraints: constraints,
                      selectedAssets: const {},
                      mirroringDisabled: true,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byKey(_nameKey),
        matchesGoldenFile('goldens/analog_box_name_visibility.png'),
      );
    });
  });
}

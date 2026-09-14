// The frames an operator sees when a trend opens: the loading frame, the
// dissolve, then the chart.
//
// A number on the mimic with a trend behind it opens a floating window whose
// body is a `GraphAsset`, and the history query behind it is a real database
// round trip. So the loading frame is on screen long enough to be read, and
// whatever it shows has to be shaped like the chart that replaces it. It used
// not to be: four gridlines ran the full width and height of the window, and
// the chart landed with its plot 88px further in, a legend column taking 160
// off the right and a time row 30 off the bottom. Every line moved.
//
// These goldens are a pair on purpose. The loading one is only right in so far
// as it matches the loaded one beside it, so they are meant to be looked at
// together -- and the geometry test below states the match as numbers, because
// two PNGs that drifted apart by four pixels look identical in review.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/widgets/graph.dart';

import '../helpers/golden_fonts.dart';
import '../helpers/golden_platform.dart';

// A fixed window rather than the `xSpan` the real dialog uses: `xSpan` is
// resolved against `DateTime.now()` both for the x scale and for the slice the
// plot draws, which would put the tick labels somewhere new on every run. The
// frame geometry -- which is what these are about -- is the same either way.
final _start = DateTime.utc(2026, 1, 1, 11);
final _end = DateTime.utc(2026, 1, 1, 12);

const _series = 'Motor frequency';

Graph _chart(Brightness brightness, {required bool compact}) => Graph(
      config: GraphConfig(
        type: GraphType.timeseries,
        xAxis: GraphAxisConfig(
          unit: '',
          min: _start.millisecondsSinceEpoch.toDouble(),
          max: _end.millisecondsSinceEpoch.toDouble(),
        ),
        yAxis: GraphAxisConfig(unit: compact ? '' : 'Hz'),
        legend: !compact,
      ),
      data: [],
      showButtons: !compact,
      seriesLabels: const [_series],
      // The plot's own ground comes from the chart theme, not from the Material
      // theme around it; without this a dark frame draws a white plot.
      chartTheme: brightness == Brightness.dark
          ? darkChartTheme(
              padding: compact ? kCompactChartPaddingSingleAxis : kChartPadding)
          : lightChartTheme(
              padding: compact ? kCompactChartPaddingSingleAxis : kChartPadding),
      redraw: () {},
    );

List<Map<String, dynamic>> _points() => [
      for (var i = 0; i <= 60; i++)
        {
          'x': _start
              .add(Duration(minutes: i))
              .millisecondsSinceEpoch
              .toDouble(),
          'y': 48.0 + (i % 7) * 0.3,
          's': _series,
        }
    ];

Widget _frame(Brightness brightness, Widget Function(BuildContext) build) =>
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: brightness),
      home: Scaffold(
        body: RepaintBoundary(
          key: const Key('chart'),
          child: Builder(
            // The boundary captures only what is painted inside it, so a dark
            // frame with no ground of its own comes out on transparent --
            // white -- which no screen shows.
            builder: (context) => ColoredBox(
              color: Theme.of(context).colorScheme.surface,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Builder(builder: build),
              ),
            ),
          ),
        ),
      ),
    );

/// Holds a [Graph] and rebuilds on its `redraw`, the way every real caller
/// does. Needed for the dissolve: the transition only runs if the tree is
/// rebuilt when the data lands.
class _Host extends StatefulWidget {
  const _Host({required this.build});
  final Widget Function(BuildContext) build;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  @override
  Widget build(BuildContext context) => Builder(builder: widget.build);
}

/// Where the plot's left and bottom axis lines are in the rendered frame.
///
/// Read back off the pixels rather than off either side's arithmetic: the
/// point of the pair is that two independent bits of code -- our loading frame
/// and cristalyse's painter -- put the axes in the same place, and only the
/// pixels can say whether they did.
Future<({int left, int bottom})> _axes(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('chart')));
  // `toImage` hands back a future the rasteriser completes, and inside a
  // widget test nothing turns that crank unless `runAsync` does -- await it
  // directly and the test simply stops.
  final shot = await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final size = (width: image.width, height: image.height);
    image.dispose();
    return (pixels: Uint8List.view(data!.buffer), size: size);
  });
  final pixels = shot!.pixels;
  final width = shot.size.width;
  final height = shot.size.height;

  // The axis lines are the darkest thing on a light frame -- gridlines are
  // drawn at a quarter of their alpha, and the tick labels are lighter still
  // and never run the length of an axis.
  bool dark(int x, int y) {
    final i = (y * width + x) * 4;
    return (pixels[i] + pixels[i + 1] + pixels[i + 2]) / 3 < 170;
  }

  var bestColumn = 0, bestColumnCount = 0;
  for (var x = 0; x < width; x++) {
    var count = 0;
    for (var y = 0; y < height; y++) {
      if (dark(x, y)) count++;
    }
    if (count > bestColumnCount) {
      bestColumnCount = count;
      bestColumn = x;
    }
  }
  var bestRow = 0, bestRowCount = 0;
  for (var y = 0; y < height; y++) {
    var count = 0;
    for (var x = 0; x < width; x++) {
      if (dark(x, y)) count++;
    }
    if (count > bestRowCount) {
      bestRowCount = count;
      bestRow = y;
    }
  }
  return (left: bestColumn, bottom: bestRow);
}

void main() {
  setUpAll(loadGoldenFonts);

  // The one that matters, and the one a pair of PNGs cannot state: the loading
  // frame draws the plot where the chart is about to draw it. Not tagged
  // `golden`, so it runs on every platform rather than only where the goldens
  // do -- it is measuring geometry, and the gutters come from font metrics
  // that travel.
  testWidgets('the loading frame puts the axes where the chart will',
      (tester) async {
    tester.view.physicalSize = const Size(820, 520);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final loading = _chart(Brightness.light, compact: false);
    await tester.pumpWidget(_frame(Brightness.light, loading.build));
    await tester.pump();
    final before = await _axes(tester);

    final loaded = _chart(Brightness.light, compact: false);
    loaded.addAll(_points());
    await tester.pumpWidget(_frame(Brightness.light, loaded.build));
    await tester.pumpAndSettle();
    final after = await _axes(tester);

    // Within a couple of pixels: the gutter is sized from a representative
    // tick ("88.8 Hz"), and the real ticks are only the same width to the
    // nearest glyph. A regression -- cristalyse changing its spacing, or the
    // sample drifting from the shape a tick really has -- moves this by tens.
    expect(after.left, closeTo(before.left, 3));
    expect(after.bottom, closeTo(before.bottom, 3));
  });

  for (final brightness in Brightness.values) {
    testWidgets('trend loading frame — ${brightness.name}', (tester) async {
      tester.view.physicalSize = const Size(820, 520);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final graph = _chart(brightness, compact: false);
      await tester.pumpWidget(_frame(brightness, graph.build));
      // The progress hairline is indeterminate and never settles; one fixed
      // step into it keeps the capture repeatable.
      await tester.pump(const Duration(milliseconds: 300));

      await expectLater(
        find.byKey(const Key('chart')),
        matchesGoldenFile('goldens/chart_loading_${brightness.name}.png'),
      );
    }, tags: ['golden'], skip: goldenSkipFlag);

    testWidgets('trend loaded frame — ${brightness.name}', (tester) async {
      tester.view.physicalSize = const Size(820, 520);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final graph = _chart(brightness, compact: false);
      // Settled before the first frame: `Graph` is not a widget, so its
      // `redraw` callback is what would rebuild the tree, and there is no
      // element to mark dirty until `pumpWidget` has run.
      graph.addAll(_points());
      await tester.pumpWidget(_frame(brightness, graph.build));
      await tester.pumpAndSettle();

      await expectLater(
        find.byKey(const Key('chart')),
        matchesGoldenFile('goldens/chart_loaded_${brightness.name}.png'),
      );
    }, tags: ['golden'], skip: goldenSkipFlag);
  }

  // The pane tile: no legend, no button row, and gutters sized for bare ticks.
  // Its own pair because the loading frame sizes the plot from the labels the
  // axis will print, and a compact tile prints much shorter ones.
  testWidgets('compact trend loading frame', (tester) async {
    tester.view.physicalSize = const Size(320, 100);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final graph = _chart(Brightness.light, compact: true);
    await tester.pumpWidget(_frame(Brightness.light, graph.build));
    await tester.pump();

    await expectLater(
      find.byKey(const Key('chart')),
      matchesGoldenFile('goldens/chart_compact_loading.png'),
    );
  }, tags: ['golden'], skip: goldenSkipFlag);

  testWidgets('compact trend loaded frame', (tester) async {
    tester.view.physicalSize = const Size(320, 100);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final graph = _chart(Brightness.light, compact: true);
    graph.addAll(_points());
    await tester.pumpWidget(_frame(Brightness.light, graph.build));
    await tester.pumpAndSettle();

    await expectLater(
      find.byKey(const Key('chart')),
      matchesGoldenFile('goldens/chart_compact_loaded.png'),
    );
  }, tags: ['golden'], skip: goldenSkipFlag);

  // Halfway through the dissolve. The frame and the chart are both on screen at
  // half strength, which is the whole point: the few pixels the loading frame
  // cannot predict -- the exact tick label widths -- arrive as a fade rather
  // than a jump.
  testWidgets('trend mid-dissolve', (tester) async {
    tester.view.physicalSize = const Size(820, 520);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late void Function() rebuild;
    final graph = _chart(Brightness.light, compact: false);
    await tester.pumpWidget(_frame(
      Brightness.light,
      (context) => _Host(build: (inner) {
        rebuild = () =>
            (inner as Element).markNeedsBuild(); // redraw, from the outside
        return graph.build(inner);
      }),
    ));
    await tester.pump();

    graph.addAll(_points());
    rebuild();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 110));

    await expectLater(
      find.byKey(const Key('chart')),
      matchesGoldenFile('goldens/chart_mid_dissolve.png'),
    );

    // Let the controller finish so the test does not end mid-animation.
    await tester.pumpAndSettle();
  }, tags: ['golden'], skip: goldenSkipFlag);
}

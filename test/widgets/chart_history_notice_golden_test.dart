// What a trend looks like when its history will not load but its feed works.
//
// The old answer was the error panel: an icon and a paragraph in place of the
// plot, which is where a chart that has nothing coming belongs -- and where a
// chart that is subscribed and drawing does not. The new one keeps the plot
// and puts one line underneath it, in the slot the "No data from ... to ..."
// footer already used, so it costs nothing in the tree once a point arrives.
//
// Both frames are drawn empty on purpose: the notice is only ever visible
// while the plot is, and the moment the first live point lands it goes.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/graph.dart' show describeTrendFetchError;
import 'package:tfc/widgets/graph.dart';

import '../helpers/golden_fonts.dart';
import '../helpers/golden_platform.dart';

Graph _chart(Brightness brightness) => Graph(
      config: GraphConfig(
        type: GraphType.timeseries,
        xAxis: const GraphAxisConfig(unit: ''),
        yAxis: const GraphAxisConfig(unit: 'units/min'),
        xSpan: const Duration(minutes: 60),
      ),
      data: [],
      // The plot's own ground comes from the chart theme, not from the
      // Material theme around it; without this a dark frame draws a white
      // plot, which is a fixture nobody ships.
      chartTheme: brightness == Brightness.dark
          ? darkChartTheme()
          : lightChartTheme(),
      redraw: () {},
    );

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

void main() {
  setUpAll(loadGoldenFonts);

  for (final brightness in Brightness.values) {
    testWidgets('chart with a history notice — ${brightness.name}',
        (tester) async {
      tester.view.physicalSize = const Size(640, 340);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final graph = _chart(brightness);
      // Settled before the first frame: `Graph` is not a widget, so its
      // `redraw` callback is what would rebuild the tree, and there is no
      // element to mark dirty until `pumpWidget` has run. The real path draws
      // the (empty) history before it says anything, so the frame under the
      // notice is the plot, not the loading skeleton.
      graph.addAll(const []);
      graph.showNotice(
          'No stored history for line1/rate. Charting values as they arrive.');
      await tester.pumpWidget(_frame(brightness, graph.build));
      await tester.pump();

      await expectLater(
        find.byKey(const Key('chart')),
        matchesGoldenFile('goldens/chart_notice_${brightness.name}.png'),
      );
    }, tags: ['golden'], skip: goldenSkipFlag);
  }

  // The other half of the rule: a chart with nothing coming still gets the
  // panel, so "no history but live" and "dead" do not look alike.
  testWidgets('chart with no feed at all keeps the error panel',
      (tester) async {
    tester.view.physicalSize = const Size(640, 340);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final graph = _chart(Brightness.light);
    graph.addAll(const []);
    graph.showError(describeTrendFetchError(
      'line1/rate',
      Exception('Severity.error 42P01: relation "line1/rate" does not exist'),
    ));
    await tester.pumpWidget(_frame(Brightness.light, graph.build));
    await tester.pump();

    await expectLater(
      find.byKey(const Key('chart')),
      matchesGoldenFile('goldens/chart_dead_key.png'),
    );
  }, tags: ['golden'], skip: goldenSkipFlag);
}

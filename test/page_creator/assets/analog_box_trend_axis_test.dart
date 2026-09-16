// The analog box's pane trend is drawn twice: a small preview in the pane and
// the full chart behind a tap. The page author pins the y-axis on the asset's
// `GraphAssetConfig` so a row of boxes can be read against one scale — and
// only the expanded chart honoured it, because the preview was built from
// loose fields that never included the axis.
//
// Contract under test:
//   - the tile hands the preview the SAME `GraphAxisConfig` object the
//     expanded chart reads, so "pinned or auto" is decided in one place;
//   - a pinned bound wins, end by end;
//   - an unset bound keeps the auto-scaled range exactly as before, so an
//     asset that pins nothing draws as it always did;
//   - the expanded chart is untouched in either case.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tfc/page_creator/assets/analog_box.dart';
import 'package:tfc/page_creator/assets/graph.dart';
import 'package:tfc/widgets/graph.dart';

AnalogBoxConfig _config({GraphAxisConfig? yAxis}) => AnalogBoxConfig(
      analogKey: 'some.key',
      units: 'l',
      graphConfig: GraphAssetConfig(
        graphType: GraphType.timeseries,
        primarySeries: [GraphSeriesConfig(key: 'some.key', label: 'Level')],
        yAxis: yAxis,
      ),
    )..text = 'Tank level';

void main() {
  group('analogBoxTrendYRange', () {
    const auto = (min: 3.5, max: 4.6);

    test('no axis at all auto-scales', () {
      expect(analogBoxTrendYRange(null, auto), auto);
    });

    test('an axis with neither bound set auto-scales', () {
      expect(
        analogBoxTrendYRange(const GraphAxisConfig(unit: ''), auto),
        auto,
        reason: 'an unpinned axis must not change a single drawn pixel',
      );
    });

    test('both bounds pinned win', () {
      expect(
        analogBoxTrendYRange(
            const GraphAxisConfig(unit: '', min: 0, max: 100), auto),
        (min: 0.0, max: 100.0),
      );
    });

    test('one bound pinned leaves the other auto', () {
      // "Start at zero, find your own ceiling" is the common case, so the two
      // ends are resolved separately rather than all-or-nothing.
      expect(
        analogBoxTrendYRange(const GraphAxisConfig(unit: '', min: 0), auto),
        (min: 0.0, max: auto.max),
      );
      expect(
        analogBoxTrendYRange(const GraphAxisConfig(unit: '', max: 100), auto),
        (min: auto.min, max: 100.0),
      );
    });

    test('a pinned zero is a pin, not an absence', () {
      // `?? ` on a double: 0.0 is a value. A `min: 0` read as "unset" is the
      // bug this test exists to catch.
      expect(
        analogBoxTrendYRange(const GraphAxisConfig(unit: '', min: 0, max: 0),
            (min: 8.0, max: 9.0)),
        (min: 0.0, max: 0.0),
      );
    });
  });

  group('the pane trend tile', () {
    test('no graph config → no tile', () {
      expect(
          analogBoxTrendTile(AnalogBoxConfig(analogKey: 'some.key')), isNull);
    });

    test('the preview gets the configured axis, not a copy of its numbers', () {
      final config =
          _config(yAxis: const GraphAxisConfig(unit: 'l', min: 0, max: 100));
      final tile = analogBoxTrendTile(config)!;
      final preview = tile.preview as AnalogBoxTrendGraphLoader;

      expect(
        identical(preview.yAxis, config.graphConfig!.yAxis),
        isTrue,
        reason: 'one object decides the scale for both charts',
      );
      expect(preview.yAxis!.min, 0);
      expect(preview.yAxis!.max, 100);
    });

    test('an unpinned axis still reaches the preview, saying nothing', () {
      final config = _config();
      final preview =
          analogBoxTrendTile(config)!.preview as AnalogBoxTrendGraphLoader;
      expect(preview.yAxis, isNotNull);
      expect(preview.yAxis!.min, isNull);
      expect(preview.yAxis!.max, isNull);
    });

    testWidgets('the expanded chart is still the whole GraphAssetConfig',
        (tester) async {
      for (final axis in <GraphAxisConfig?>[
        null,
        const GraphAxisConfig(unit: 'l', min: 0, max: 100),
      ]) {
        final config = _config(yAxis: axis);
        final tile = analogBoxTrendTile(config)!;
        // Built, not mounted: `GraphAsset` reaches for a database and a
        // collector, and what is under test is which config it is handed.
        late Widget expanded;
        await tester.pumpWidget(MaterialApp(
          home: Builder(builder: (context) {
            expanded = tile.expandedBuilder(context);
            return const SizedBox.shrink();
          }),
        ));
        expect(
          identical((expanded as GraphAsset).config, config.graphConfig),
          isTrue,
          reason: 'the expanded chart already honoured the axis; leave it',
        );
        expect(tile.expandedTitle, 'Tank level — trend');
      }
    });

    test('the preview keeps the rest of its wiring', () {
      // The axis is additive: every other argument the preview was built with
      // has to survive it.
      final preview =
          analogBoxTrendTile(_config())!.preview as AnalogBoxTrendGraphLoader;
      expect(preview.keyName, 'some.key');
      expect(preview.seriesLabel, 'Level');
      expect(preview.units, 'l');
      expect(preview.showButtons, isFalse);
      expect(preview.compact, isTrue);
      expect(preview.xSpan, const Duration(minutes: 5));
    });
  });
}

/// Station docks on a rails conveyor, as the operator sees them.
///
/// The stations stand where the SVN empty-pallet wagon's do — the positions
/// and sides are ST301's `A250_wagon`, so the spacing and the crowding at the
/// reference end are real. The names are invented: a golden is a published
/// image.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/conveyor.dart';
import 'package:tfc/page_creator/assets/wagon_station.dart';
import 'package:tfc/page_creator/assets/wagon_station_docks.dart';
import 'package:tfc/providers/collector.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/theme.dart';
import 'package:tfc/widgets/panes/side_pane.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../../helpers/golden_fonts.dart';
import '../../helpers/golden_platform.dart';
import '../../helpers/wagon_fixtures.dart';

const _frameKey = Key('wagon_stations_golden');
const _railLength = 10380.0;

/// One of each state, the wagon docked at the delivering one.
List<DynamicValue> _plantStations() => [
      station('Magazine', position: 4960, ready: true),
      station('Line 1',
          position: 10380, type: 1, loc: 1, interlock: true, order: true),
      station('Line 2', position: 6620, type: 1, loc: 1, order: true),
      station('Line 3', position: 0, type: 1, loc: 1),
      station('Stacker',
          position: 800,
          type: 1,
          atStation: true,
          outfeed: true,
          ready: true,
          order: true),
    ];

List<WagonStation> _decoded(List<DynamicValue> items) =>
    wagonStationsFromValue(stationArray(items));

Widget _rails(ThemeData theme) {
  Widget rail(String caption, Size size, ConveyorPainter Function(BuildContext) painter) =>
      Builder(
        builder: (context) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(caption, style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            SizedBox.fromSize(
              size: size,
              child: CustomPaint(size: size, painter: painter(context)),
            ),
            const SizedBox(height: 16),
          ],
        ),
      );

  ConveyorPainter wagon(BuildContext context,
          {required List<WagonStation> stations,
          double position = 800 / _railLength,
          bool reverse = false,
          ConveyorStyle style = ConveyorStyle.roller,
          Size size = const Size(900, 170)}) =>
      ConveyorPainter(
        color: HmiStateColors.of(context).green,
        batches: const {},
        angle: 0,
        style: style,
        paintSize: size,
        onRails: true,
        railInk: theme.colorScheme.onSurface,
        wagonPosition: position,
        wagonFraction: 0.12,
        chassisColor: HmiStateColors.of(context).green,
        reverseDirection: reverse,
        stations: stations,
        stationRailLength: _railLength,
        dockPalette: WagonDockPalette.of(context),
      );

  return MaterialApp(
    theme: theme,
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      body: Center(
        child: RepaintBoundary(
          key: _frameKey,
          child: Container(
            color: theme.colorScheme.surface,
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                rail(
                  'docked at Stacker (delivering) · Line 1 blocked · Line 2 '
                  'asking · Magazine ready · Line 3 idle',
                  const Size(900, 170),
                  (c) => wagon(c, stations: _decoded(_plantStations())),
                ),
                rail(
                  'belt reversed: front and behind swap edges; wagon drawn '
                  'off by slip, the sensor bar still marks Stacker',
                  const Size(900, 170),
                  (c) => wagon(c,
                      stations: _decoded(_plantStations()),
                      position: 0.62,
                      reverse: true,
                      style: ConveyorStyle.box),
                ),
                rail(
                  'bound, nothing arrived yet: the track keeps its band',
                  const Size(900, 110),
                  (c) => wagon(c,
                      stations: const [],
                      position: 0.5,
                      size: const Size(900, 110)),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _RailStateMan extends Fake implements StateMan {
  _RailStateMan(this.values);

  final Map<String, DynamicValue> values;

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async {
    final v = values[key];
    return v == null ? const Stream<DynamicValue>.empty() : Stream.value(v);
  }

  @override
  String resolveKey(String key) => key;
}

void main() {
  group('wagon station docks golden', skip: goldenSkip, () {
    setUpAll(loadGoldenFonts);

    final themes = <String, ThemeData>{
      'light': solarized().$1,
      'dark': solarized().$2,
    };
    for (final entry in themes.entries) {
      testWidgets('rails with station docks, ${entry.key}', (tester) async {
        tester.view.physicalSize = const Size(1000, 640);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(_rails(entry.value));
        await expectLater(
          find.byKey(_frameKey),
          matchesGoldenFile('goldens/conveyor_wagon_stations_${entry.key}.png'),
        );
      });
    }

    testWidgets('tapping a dock opens its station pane', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      addTearDown(() => closeSidePane(immediate: true));

      const stationsKey = 'EPW01.stations';
      const positionKey = 'EPW01.WA01.p_stat_rPosition_percentage';
      final config = ConveyorConfig(
        onRails: true,
        stationsKey: stationsKey,
        positionKey: positionKey,
        wagonLength: 0.12,
      )..size = const RelativeSize(width: 1.0, height: 1.0);
      final theme = solarized().$1;

      await tester.pumpWidget(ProviderScope(
        overrides: [
          collectorProvider.overrideWith((ref) async => null),
          stateManProvider.overrideWith((ref) async => _RailStateMan({
                stationsKey: stationArray(_plantStations()),
                positionKey: DynamicValue(value: 800 / _railLength * 100),
              })),
        ],
        child: MaterialApp(
          theme: theme,
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            body: Align(
              alignment: const Alignment(-0.9, -0.8),
              child: SizedBox(
                  width: 820, height: 170, child: Conveyor(config)),
            ),
          ),
        ),
      ));
      for (var i = 0; i < 3; i++) {
        await tester.pump();
      }

      final painter = tester
          .widget<CustomPaint>(find
              .descendant(
                  of: find.byType(Conveyor), matching: find.byType(CustomPaint))
              .first)
          .painter! as ConveyorPainter;
      final line1 = painter
          .docks(painter.paintSize!)
          .firstWhere((d) => d.station.name == 'Line 1');
      await tester.tapAt(
          tester.getTopLeft(find.byType(Conveyor)) + line1.body.center);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/conveyor_wagon_station_pane.png'),
      );
    });
  });
}

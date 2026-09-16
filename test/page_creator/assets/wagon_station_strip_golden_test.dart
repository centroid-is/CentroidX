/// Goldens for the pallet-wagon station strip.
///
/// Three things the widget test cannot see: that the cells line up as a strip
/// rather than a stack, that only `Blocked` is loud, and that the whole thing
/// still reads in the dark theme — this repo ships both and an asset that
/// only works in one is half an asset.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/wagon_station.dart';
import 'package:tfc/page_creator/assets/wagon_station_strip.dart';
import 'package:tfc/theme.dart';

import '../../helpers/golden_fonts.dart';
import '../../helpers/golden_platform.dart';
import '../../helpers/golden_tolerance.dart';

const _key = Key('wagon_station_strip');

Widget frame(
  Widget child, {
  double width = 860,
  double height = 140,
  bool dark = false,
}) {
  final (light, darkTheme) = solarized();
  return MaterialApp(
    theme: dark ? darkTheme : light,
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      body: Center(
        child: RepaintBoundary(
          key: _key,
          child: SizedBox(width: width, height: height, child: child),
        ),
      ),
    ),
  );
}

/// One station per derived state, plus the wagon parked at the blocked one —
/// so a single image carries the whole ladder.
List<WagonStation> everyState() => const [
      WagonStation(
        index: 1,
        name: 'Infeed',
        role: WagonStationRole.source,
        side: WagonStationSide.inFront,
        position: 0,
        enabled: true,
      ),
      WagonStation(
        index: 2,
        name: 'Line A',
        role: WagonStationRole.source,
        side: WagonStationSide.behind,
        position: 2400,
        enabled: true,
        order: true,
      ),
      WagonStation(
        index: 3,
        name: 'Line B',
        role: WagonStationRole.source,
        side: WagonStationSide.behind,
        position: 5200,
        enabled: true,
        order: true,
        ready: true,
      ),
      WagonStation(
        index: 4,
        name: 'Buffer',
        role: WagonStationRole.destination,
        side: WagonStationSide.inFront,
        position: 8600,
        enabled: true,
        outfeed: true,
      ),
      WagonStation(
        index: 5,
        name: 'Store',
        role: WagonStationRole.destination,
        side: WagonStationSide.behind,
        position: 11800,
        enabled: true,
        atStation: true,
        waitingForInterlock: true,
      ),
    ];

void main() {
  useTolerantGoldenComparator();

  group('wagon station strip', skip: goldenSkip, () {
    testWidgets('one cell per derived state, the wagon at the blocked one',
        (tester) async {
      await loadGoldenFonts();
      await tester.pumpWidget(frame(WagonStationStripView(
        stations: everyState(),
        title: 'Wagon stations',
        wagonState: 'Waiting for interlock',
      )));
      await tester.pumpAndSettle();
      await expectLater(find.byKey(_key),
          matchesGoldenFile('goldens/wagon_station_strip_states.png'));
    });

    testWidgets('the same strip in the dark theme', (tester) async {
      await loadGoldenFonts();
      await tester.pumpWidget(frame(
        WagonStationStripView(
          stations: everyState(),
          title: 'Wagon stations',
          wagonState: 'Waiting for interlock',
        ),
        dark: true,
      ));
      await tester.pumpAndSettle();
      await expectLater(find.byKey(_key),
          matchesGoldenFile('goldens/wagon_station_strip_dark.png'));
    });

    testWidgets('array key alone: no header chip, no positions',
        (tester) async {
      await loadGoldenFonts();
      await tester.pumpWidget(frame(WagonStationStripView(
        stations: everyState(),
        showPositions: false,
      )));
      await tester.pumpAndSettle();
      await expectLater(find.byKey(_key),
          matchesGoldenFile('goldens/wagon_station_strip_bare.png'));
    });

    testWidgets('unbound: the sample the palette tile shows', (tester) async {
      await loadGoldenFonts();
      await tester.pumpWidget(frame(
        WagonStationStripView(
          stations: sampleWagonStations(),
          wagonState: 'Sample',
          caption: 'Bind the station array in the editor',
        ),
        width: 320,
        height: 90,
      ));
      await tester.pumpAndSettle();
      await expectLater(find.byKey(_key),
          matchesGoldenFile('goldens/wagon_station_strip_sample.png'));
    });
  });
}

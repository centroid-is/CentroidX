/// Station docks on a rails conveyor: where they stand, what the box gives
/// them, and what a tap on one opens.
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
import 'package:tfc/widgets/panes/side_pane.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../../helpers/wagon_fixtures.dart';

const _size = Size(600, 160);

WagonStation _s(String name, double position,
        {WagonStationSide side = WagonStationSide.inFront,
        WagonStationRole role = WagonStationRole.source,
        int index = 1}) =>
    WagonStation(
        index: index,
        name: name,
        role: role,
        side: side,
        position: position,
        enabled: true);

ConveyorPainter _painter({
  List<WagonStation>? stations,
  double railLength = 10000,
  double? wagonPosition,
  bool reverse = false,
  bool across = true,
}) =>
    ConveyorPainter(
      color: Colors.grey,
      batches: const {},
      angle: 0,
      paintSize: _size,
      onRails: true,
      wagonPosition: wagonPosition,
      reverseDirection: reverse,
      wagonBeltAcross: across,
      stations: stations,
      stationRailLength: railLength,
    );

void main() {
  group('placement', () {
    test('a wagon parked at a station sits on its dock', () {
      // The contract the whole feature rests on: dock and wagon are placed by
      // the same fraction through the same function.
      final stations = [
        _s('A', 0),
        _s('B', 2500, side: WagonStationSide.behind),
        _s('C', 7300),
        _s('D', 10000, side: WagonStationSide.behind),
      ];
      final docks = _painter(stations: stations).docks(_size);
      expect(docks, hasLength(4));
      for (final dock in docks) {
        final parked = _painter(
                stations: stations,
                wagonPosition: dock.station.position / 10000)
            .beltRect(_size);
        expect(dock.body.center.dx, closeTo(parked.center.dx, 1e-6),
            reason: dock.station.name);
      }
    });

    test('front stations take the edge the rollers run towards', () {
      final stations = [
        _s('Front', 2000),
        _s('Behind', 8000, side: WagonStationSide.behind),
      ];
      WagonDockEdge edgeOf(ConveyorPainter p, String name) =>
          p.docks(_size).firstWhere((d) => d.station.name == name).edge;

      final forward = _painter(stations: stations);
      expect(edgeOf(forward, 'Front'), WagonDockEdge.bottom);
      expect(edgeOf(forward, 'Behind'), WagonDockEdge.top);

      final reversed = _painter(stations: stations, reverse: true);
      expect(edgeOf(reversed, 'Front'), WagonDockEdge.top);
      expect(edgeOf(reversed, 'Behind'), WagonDockEdge.bottom);
    });

    test('docks touch the track band and names sit beyond them', () {
      final docks = _painter(stations: [
        _s('Top', 3000, side: WagonStationSide.behind),
        _s('Bottom', 6000),
      ]).docks(_size);
      final rail = WagonDockGeometry.railBand(_size);
      final top = docks.firstWhere((d) => d.edge == WagonDockEdge.top);
      final bottom = docks.firstWhere((d) => d.edge == WagonDockEdge.bottom);
      expect(top.body.bottom, closeTo(rail.top, 1e-6));
      expect(top.label.bottom, lessThanOrEqualTo(top.body.top + 1e-6));
      expect(bottom.body.top, closeTo(rail.bottom, 1e-6));
      expect(bottom.label.top, greaterThanOrEqualTo(bottom.body.bottom - 1e-6));
      for (final d in docks) {
        expect((Offset.zero & _size).intersect(d.label), d.label,
            reason: 'names stay inside the box');
      }
    });

    test('close neighbours on one side shrink rather than overlap', () {
      final docks = _painter(stations: [
        _s('A', 4000),
        _s('B', 4400),
        _s('Other side', 4200, side: WagonStationSide.behind),
      ]).docks(_size);
      final a = docks.firstWhere((d) => d.station.name == 'A');
      final b = docks.firstWhere((d) => d.station.name == 'B');
      final other = docks.firstWhere((d) => d.station.name == 'Other side');
      expect(a.body.overlaps(b.body), isFalse);
      expect(a.label.overlaps(b.label), isFalse);
      // Alone on its side, the third keeps the belt's full width.
      final lane = _painter(stations: [_s('X', 0)]).beltRect(_size).width;
      expect(other.body.width, closeTo(lane, 1e-6));
    });
  });

  group('the box', () {
    test('without a stations key the track keeps the whole box', () {
      final belt = _painter().beltRect(_size);
      expect(belt.top, 0);
      expect(belt.height, _size.height);
    });

    test('bound stations reserve the bands even with nothing to draw', () {
      // A stream that has not answered, or an array with nothing
      // commissioned, must not make the track jump between two heights.
      final empty = _painter(stations: const []);
      final full = _painter(stations: [_s('A', 5000)]);
      expect(empty.beltRect(_size), full.beltRect(_size));
      final rail = WagonDockGeometry.railBand(_size);
      expect(empty.beltRect(_size).top, rail.top);
      expect(empty.beltRect(_size).bottom, rail.bottom);
      expect(empty.docks(_size), isEmpty);
    });

    test('dock bodies are part of the hit shape, names are not', () {
      final painter = _painter(
          stations: [_s('A', 0), _s('B', 10000, side: WagonStationSide.behind)],
          wagonPosition: 0.5);
      for (final dock in painter.docks(_size)) {
        expect(painter.hitTest(dock.body.center), isTrue);
        expect(painter.hitTest(dock.label.center), isFalse);
      }
      // The bare track between them stays inert.
      expect(painter.hitTest(Offset(_size.width * 0.25, _size.height * 0.4)),
          isFalse);
    });

    test('the rail tap band follows the track into its narrowed strip', () {
      // The traverse drive answers on the painted rails. With docks bound the
      // rails are painted in the middle band, so the tap band must be
      // measured there too, or it reaches out over the docks.
      final docked = _painter(stations: [_s('A', 0)]);
      final rail = WagonDockGeometry.railBand(_size);
      final band = docked.railBandRect(_size)!;
      final bare = ConveyorPainter(
              color: Colors.grey,
              batches: const {},
              angle: 0,
              paintSize: rail.size,
              onRails: true)
          .railBandRect(rail.size)!;
      expect(band, bare.shift(rail.topLeft));
      for (final dock in docked.docks(_size)) {
        expect(band.overlaps(dock.body), isFalse);
      }
    });

    test('stationsKey round-trips through JSON', () {
      final config = ConveyorConfig(
          onRails: true, stationsKey: 'EPW01.stations');
      expect(ConveyorConfig.fromJson(config.toJson()).stationsKey,
          'EPW01.stations');
      expect(config.allKeys, contains('EPW01.stations'));
      // Pages saved before the field existed.
      expect(ConveyorConfig.fromJson(ConveyorConfig().toJson()..remove('stationsKey'))
          .stationsKey, isNull);
    });

    test('the wagon name and lock help round-trip, and the name falls back',
        () {
      final config = ConveyorConfig(
          onRails: true,
          wagonName: 'Pallet wagon',
          stationLockHelp: 'The other wagon is usually at the station.');
      final back = ConveyorConfig.fromJson(config.toJson());
      expect(back.wagonName, 'Pallet wagon');
      expect(back.stationLockHelp, 'The other wagon is usually at the station.');
      expect(back.wagonDisplayName, 'Pallet wagon');

      final labelled = ConveyorConfig(onRails: true)..text = 'Wagon 2';
      expect(labelled.wagonDisplayName, 'Wagon 2');
      expect(ConveyorConfig(onRails: true, wagonName: '  ').wagonDisplayName,
          'the wagon');
    });
  });

  group('on the page', () {
    const stationsKey = 'EPW01.stations';
    const motorKey = 'EPW01.WA01.motor';

    Future<void> pumpRail(WidgetTester tester, DynamicValue array) async {
      final config = ConveyorConfig(
        onRails: true,
        stationsKey: stationsKey,
        wagonMotorKey: motorKey,
        positionKey: 'EPW01.WA01.p_stat_rPosition_percentage',
      )..size = const RelativeSize(width: 1.0, height: 1.0);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          collectorProvider.overrideWith((ref) async => null),
          stateManProvider.overrideWith((ref) async => _RailStateMan({
                stationsKey: array,
                'EPW01.WA01.p_stat_rPosition_percentage':
                    DynamicValue(value: 50.0),
              })),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                  width: _size.width,
                  height: _size.height,
                  child: Conveyor(config)),
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump();
      await tester.pump();
    }

    /// Where [name]'s dock is on screen, from the painter actually drawn.
    Offset dockCentre(WidgetTester tester, String name) {
      final paint = tester.widget<CustomPaint>(find
          .descendant(
              of: find.byType(Conveyor), matching: find.byType(CustomPaint))
          .first);
      final painter = paint.painter! as ConveyorPainter;
      final dock = painter
          .docks(painter.paintSize!)
          .firstWhere((d) => d.station.name == name);
      final box = tester.getTopLeft(find.byType(Conveyor));
      return box + dock.body.center;
    }

    testWidgets('tapping a dock opens that station\'s pane, live',
        (tester) async {
      await pumpRail(
          tester,
          stationArray([
            station('Magazine', position: 4960, ready: true),
            station('Line 1', position: 10380, type: 1, loc: 1, order: true),
          ]));

      await tester.tapAt(dockCentre(tester, 'Line 1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(SidePane), findsOneWidget);
      expect(find.text('Wagon station'), findsOneWidget);
      expect(find.text('Needs pallet'), findsOneWidget);
      // The sentence sees the whole row, not just the tapped station.
      expect(find.text('Line 1 needs a pallet. Magazine has one ready.'),
          findsOneWidget);
      expect(find.text('Takes pallets from the wagon'), findsOneWidget);
      expect(find.text('10.4 m'), findsOneWidget);

      // The raw signals are folded shut until asked for.
      expect(find.text('Needs a pallet'), findsNothing);
      await tester.ensureVisible(find.text('Advanced'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Advanced'));
      await tester.pumpAndSettle();
      expect(find.text('Needs a pallet'), findsOneWidget);
    });

    testWidgets('each stop signal gets its own explanation', (tester) async {
      await pumpRail(
          tester,
          stationArray([
            station('Magazine', position: 4960),
            station('Line 1',
                position: 10380,
                type: 1,
                loc: 1,
                order: true,
                interlock: true,
                waitingForInterlock: true),
          ]));

      await tester.tapAt(dockCentre(tester, 'Line 1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Wagon waiting'), findsOneWidget);
      expect(find.text('The wagon is waiting for Line 1'), findsOneWidget);
      expect(find.text('Line 1 is keeping the wagon out'), findsOneWidget);
    });

    testWidgets('with stations bound, the rail still opens the traverse drive',
        (tester) async {
      await pumpRail(tester, stationArray([station('Magazine', position: 0)]));
      final paint = tester.widget<CustomPaint>(find
          .descendant(
              of: find.byType(Conveyor), matching: find.byType(CustomPaint))
          .first);
      final painter = paint.painter! as ConveyorPainter;
      final size = painter.paintSize!;
      final rail = painter.railBandRect(size)!;
      // Far along the track from the wagon parked mid-rail, and away from
      // every dock.
      final onRail = Offset(size.width * 0.9, rail.center.dy);
      expect(painter.wagonRect(size).contains(onRail), isFalse);

      await tester.tapAt(tester.getTopLeft(find.byType(Conveyor)) + onRail);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(SidePane), findsOneWidget);
      expect(find.text('Wagon drive'), findsOneWidget);
    });
  });
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

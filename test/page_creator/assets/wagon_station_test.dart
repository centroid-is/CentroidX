/// Decoding `FB_Wagon`'s `ARRAY [1..10] OF ST_WagonStation`: which entries are
/// stations, what each is doing, and where along the rail it stands.
///
/// Values are always pushed as a whole array, never a field at a time — the
/// array is one OPC UA node and that is the only shape the HMI ever sees.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:tfc/page_creator/assets/wagon_station.dart';
import 'package:tfc/page_creator/assets/wagon_station_docks.dart';

import '../../helpers/wagon_fixtures.dart';

void main() {
  group('which entries are stations', () {
    test('skips entries that are disabled or have no name', () {
      final row = wagonStationsFromValue(stationArray([
        station('Infeed', position: 0),
        uncommissionedStation(),
        uncommissionedStation(name: 'Old buffer'),
        station('', position: 500),
        station('Store', position: 4000),
      ]));
      expect([for (final s in row) s.name], ['Infeed', 'Store']);
    });

    test('orders by position, not by array index, and keeps the slot', () {
      final row = wagonStationsFromValue(stationArray([
        station('Far', position: 9000),
        station('Near', position: 100),
        station('Middle', position: 4000),
      ]));
      expect([for (final s in row) s.name], ['Near', 'Middle', 'Far']);
      expect([for (final s in row) s.index], [2, 3, 1]);
    });

    test('stations sharing a position keep the array\'s own order', () {
      final row = wagonStationsFromValue(stationArray([
        station('Behind', position: 2400, loc: 1),
        station('Front', position: 2400),
      ]));
      expect([for (final s in row) s.name], ['Behind', 'Front']);
    });

    test('a value that is not an array decodes to nothing', () {
      expect(wagonStationsFromValue(DynamicValue(value: 7)), isEmpty);
      expect(wagonStationsFromValue(null), isEmpty);
    });
  });

  group('the derived state, first match wins', () {
    WagonStationState stateOf(DynamicValue only) =>
        wagonStationsFromValue(stationArray([only])).single.state;

    test('an interlock is blocked, whatever else is set', () {
      expect(
          stateOf(station('A',
              interlock: true, outfeed: true, ready: true, order: true)),
          WagonStationState.blocked);
    });

    test('waiting on an interlock is blocked too', () {
      expect(
          stateOf(
              station('A', waitingForInterlock: true, outfeed: true, ready: true)),
          WagonStationState.blocked);
    });

    test('outfeed beats ready and asking', () {
      expect(stateOf(station('A', outfeed: true, ready: true, order: true)),
          WagonStationState.delivering);
    });

    test('ready beats asking', () {
      expect(stateOf(station('A', ready: true, order: true)),
          WagonStationState.ready);
    });

    test('asking on its own is asking', () {
      expect(stateOf(station('A', order: true)), WagonStationState.asking);
    });

    test('the completion flags alone are idle', () {
      // Carried for the pane, deliberately not on the ladder: a delivered
      // pallet is not something the station is waiting on.
      expect(
          stateOf(station('A', deliveryComplete: true, outfeedComplete: true)),
          WagonStationState.idle);
    });
  });

  group('where along the rail', () {
    test('the rail length is FB_Wagon\'s: furthest ENABLED entry, name or not',
        () {
      // FB_Wagon takes MAX(p_stat_rPosition) over xEnabled entries and never
      // looks at the name. A nameless enabled slot is not drawn, but it still
      // stretches the scale the wagon's percentage is measured against.
      final array = stationArray([
        station('Magazine', position: 4960),
        station('', position: 12000),
        station('Line 1', position: 10380),
        uncommissionedStation(), // disabled at 9999: ignored
      ]);
      expect(wagonRailLength(array), 12000);
    });

    test('the SVN empty-pallet rail puts stations where the wagon parks', () {
      // Positions from ST301 A250_wagon (EPW01), names invented.
      final array = stationArray([
        station('A', position: 4960),
        station('B', position: 10380),
        station('C', position: 6620),
        station('D', position: 0),
        station('E', position: 800),
      ]);
      final length = wagonRailLength(array);
      final fractions = {
        for (final s in wagonStationsFromValue(array))
          s.name: s.railFraction(length)
      };
      expect(fractions['D'], 0);
      expect(fractions['B'], 1);
      expect(fractions['A'], closeTo(4960 / 10380, 1e-9));
    });

    test('nothing enabled, or garbage positions, lands at the reference end',
        () {
      expect(wagonRailLength(stationArray([uncommissionedStation()])), 0);
      expect(wagonRailLength(null), 0);
      const s = WagonStation(
          index: 1,
          name: 'A',
          role: WagonStationRole.source,
          side: WagonStationSide.inFront,
          position: 500);
      expect(s.railFraction(0), 0);
      expect(s.railFraction(double.nan), 0);
      expect(s.railFraction(250), 1, reason: 'clamped, never off the rail');
    });
  });

  group('decoding', () {
    test('an enum published as its name still lands on the right member', () {
      final row = wagonStationsFromValue(stationArray([
        station('A', rawType: 'destination', rawLoc: 'behind'),
        station('B', rawType: 'ET_WagonStationType.destination',
            rawLoc: 'ET_WagonLocation.behind', position: 1),
      ]));
      for (final s in row) {
        expect(s.role, WagonStationRole.destination);
        expect(s.side, WagonStationSide.behind);
      }
    });

    test('a struct missing members degrades instead of throwing', () {
      final partial = DynamicValue(value: {
        WagonStationFields.name: DynamicValue(value: 'A'),
        WagonStationFields.enabled: DynamicValue(value: true),
      });
      final row = wagonStationsFromValue(stationArray([partial]));
      expect(row.single.state, WagonStationState.idle);
      expect(row.single.positionLabel, '0 mm');
    });

    test('two decodes of the same array are equal', () {
      // The painter repaints on inequality; a stream re-sending an unchanged
      // array must not count as a change.
      DynamicValue array() => stationArray([station('A', order: true)]);
      expect(wagonStationsFromValue(array()),
          orderedEquals(wagonStationsFromValue(array())));
    });
  });

  group('handshake wording', () {
    List<String> labels(WagonStationRole role) => [
          for (final bit in wagonStationHandshake(WagonStation(
              index: 1,
              name: 'A',
              role: role,
              side: WagonStationSide.inFront,
              position: 0)))
            bit.label
        ];

    test('a source and a destination read their members in their own words',
        () {
      expect(labels(WagonStationRole.source),
          containsAll(['Has a pallet to send', 'Pallet taken onto the wagon']));
      expect(labels(WagonStationRole.destination),
          containsAll(['Needs a pallet', 'Has the pallet']));
    });

    test('neither role shows the completion flag only the other sets', () {
      expect(labels(WagonStationRole.source), isNot(contains('Has the pallet')));
      expect(labels(WagonStationRole.destination),
          isNot(contains('Pallet taken onto the wagon')));
    });
  });
}

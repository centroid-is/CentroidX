/// The pallet-wagon station strip: what it draws, what it refuses to draw,
/// and in what order.
///
/// The asset reads ONE key — the wagon's `ARRAY [1..10] OF ST_WagonStation` —
/// and an optional second one for the wagon's state string. Everything below
/// goes through that contract: values are pushed as a whole array, never a
/// field at a time.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:rxdart/rxdart.dart';
import 'package:tfc/page_creator/assets/wagon_station.dart';
import 'package:tfc/page_creator/assets/wagon_station_strip.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../../helpers/wagon_fixtures.dart';

void main() {
  Widget wrap(Widget child, _FakeStateMan sm,
          {double width = 900, double height = 150}) =>
      ProviderScope(
        overrides: [stateManProvider.overrideWith((_) async => sm)],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(width: width, height: height, child: child),
            ),
          ),
        ),
      );

  /// Pumps until the async `stateManProvider` has resolved and the first
  /// array has arrived. Two frames is enough; a third costs nothing.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
  }

  /// The tooltip messages of the cells actually on screen, left to right.
  List<String> cellTooltips(WidgetTester tester) {
    final tooltips = tester
        .widgetList<Tooltip>(find.byType(Tooltip))
        .where((t) => (t.message ?? '').contains('#'))
        .toList();
    return [for (final t in tooltips) t.message!];
  }

  group('what the strip draws', () {
    testWidgets('skips entries that are disabled or have no name',
        (tester) async {
      final sm = _FakeStateMan()
        ..push(
            'stations',
            stationArray([
              station('Infeed', position: 0),
              // Named, but the plant never turned it on.
              station('Ghost', enabled: false, position: 1000),
              // Enabled, but never named: still the array's tail.
              station('', position: 2000),
              station('Buffer', position: 3000),
              // The rest of the ten slots, holding stale flags.
              for (var i = 0; i < 6; i++) uncommissionedStation(),
            ]));

      await tester.pumpWidget(wrap(
        WagonStationStrip(
            config: WagonStationStripConfig(stationsKey: 'stations')),
        sm,
      ));
      await settle(tester);

      expect(find.text('Infeed'), findsOneWidget);
      expect(find.text('Buffer'), findsOneWidget);
      expect(find.text('Ghost'), findsNothing);
      expect(cellTooltips(tester), hasLength(2));
    });

    testWidgets('orders the cells by position, not by array index',
        (tester) async {
      final sm = _FakeStateMan()
        ..push(
            'stations',
            stationArray([
              station('Third', position: 8600),
              station('First', position: 0),
              station('Second', position: 2400),
            ]));

      await tester.pumpWidget(wrap(
        WagonStationStrip(
            config: WagonStationStripConfig(stationsKey: 'stations')),
        sm,
      ));
      await settle(tester);

      double x(String name) => tester.getTopLeft(find.text(name)).dx;
      expect(x('First'), lessThan(x('Second')));
      expect(x('Second'), lessThan(x('Third')));
    });

    testWidgets('prints each cell\'s position in mm', (tester) async {
      final sm = _FakeStateMan()
        ..push('stations',
            stationArray([station('Infeed', position: 2449.6)]));

      await tester.pumpWidget(wrap(
        WagonStationStrip(
            config: WagonStationStripConfig(stationsKey: 'stations')),
        sm,
      ));
      await settle(tester);

      expect(find.text('2450 mm'), findsOneWidget);
    });

    testWidgets('showPositions off drops the mm line', (tester) async {
      final sm = _FakeStateMan()
        ..push('stations',
            stationArray([station('Infeed', position: 2450)]));

      await tester.pumpWidget(wrap(
        WagonStationStrip(
          config: WagonStationStripConfig(
              stationsKey: 'stations', showPositions: false),
        ),
        sm,
      ));
      await settle(tester);

      expect(find.text('Infeed'), findsOneWidget);
      expect(find.text('2450 mm'), findsNothing);
    });

    testWidgets('says so when nothing in the array is commissioned',
        (tester) async {
      final sm = _FakeStateMan()
        ..push('stations',
            stationArray([for (var i = 0; i < 10; i++) uncommissionedStation()]));

      await tester.pumpWidget(wrap(
        WagonStationStrip(
            config: WagonStationStripConfig(stationsKey: 'stations')),
        sm,
      ));
      await settle(tester);

      expect(find.textContaining('No station'), findsOneWidget);
      expect(cellTooltips(tester), isEmpty);
    });
  });

  group('the derived state, first match wins', () {
    /// Renders one station built with [flags] and returns the word on its
    /// chip.
    Future<String> stateWordFor(
      WidgetTester tester,
      DynamicValue only,
    ) async {
      final sm = _FakeStateMan()..push('stations', stationArray([only]));
      await tester.pumpWidget(wrap(
        WagonStationStrip(
            config: WagonStationStripConfig(stationsKey: 'stations')),
        sm,
      ));
      await settle(tester);
      for (final state in WagonStationState.values) {
        if (find.text(state.label).evaluate().isNotEmpty) return state.label;
      }
      return '(none)';
    }

    testWidgets('an interlock is blocked, whatever else is set',
        (tester) async {
      expect(
        await stateWordFor(
            tester,
            station('A',
                interlock: true, outfeed: true, ready: true, order: true)),
        'Blocked',
      );
    });

    testWidgets('waiting on an interlock is blocked too', (tester) async {
      expect(
        await stateWordFor(
            tester,
            station('A',
                waitingForInterlock: true, outfeed: true, ready: true)),
        'Blocked',
      );
    });

    testWidgets('outfeed beats ready and asking', (tester) async {
      expect(
        await stateWordFor(
            tester, station('A', outfeed: true, ready: true, order: true)),
        'Delivering',
      );
    });

    testWidgets('ready beats asking', (tester) async {
      expect(
        await stateWordFor(tester, station('A', ready: true, order: true)),
        'Ready',
      );
    });

    testWidgets('asking on its own is asking', (tester) async {
      expect(await stateWordFor(tester, station('A', order: true)), 'Asking');
    });

    testWidgets('none of the flags is idle', (tester) async {
      // The two completion flags are carried but deliberately not part of the
      // ladder: a delivered pallet is not a state the wagon is in.
      expect(
        await stateWordFor(tester,
            station('A', deliveryComplete: true, outfeedComplete: true)),
        'Idle',
      );
    });
  });

  group('the wagon itself', () {
    testWidgets('marks the cell the wagon is standing at', (tester) async {
      final sm = _FakeStateMan()
        ..push(
            'stations',
            stationArray([
              station('First', position: 0),
              station('Second', position: 2400, atStation: true),
              station('Third', position: 5200),
            ]));

      await tester.pumpWidget(wrap(
        WagonStationStrip(
            config: WagonStationStripConfig(stationsKey: 'stations')),
        sm,
      ));
      await settle(tester);

      expect(find.byIcon(Icons.my_location), findsOneWidget);
      final marked = cellTooltips(tester)
          .where((m) => m.contains('The wagon is at this station'))
          .toList();
      expect(marked, hasLength(1));
      expect(marked.single, startsWith('Second'));
    });

    testWidgets('renders with only the array key bound', (tester) async {
      final sm = _FakeStateMan()
        ..push('stations', stationArray([station('Infeed', ready: true)]));

      await tester.pumpWidget(wrap(
        WagonStationStrip(
          // No wagonStateKey: the optional half of the budget is unspent.
          config: WagonStationStripConfig(stationsKey: 'stations'),
        ),
        sm,
      ));
      await settle(tester);

      expect(find.text('Infeed'), findsOneWidget);
      expect(find.text('Ready'), findsOneWidget);
      expect(find.byIcon(Icons.local_shipping_outlined), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows the wagon state string when the second key is bound',
        (tester) async {
      final sm = _FakeStateMan()
        ..push('stations', stationArray([station('Infeed')]))
        ..push('wagon', DynamicValue(value: 'Travelling to station'));

      await tester.pumpWidget(wrap(
        WagonStationStrip(
          config: WagonStationStripConfig(
              stationsKey: 'stations', wagonStateKey: 'wagon'),
        ),
        sm,
      ));
      await settle(tester);

      expect(find.text('Travelling to station'), findsOneWidget);
      expect(find.byIcon(Icons.local_shipping_outlined), findsOneWidget);
    });

    testWidgets('an empty wagon state string draws no chip', (tester) async {
      final sm = _FakeStateMan()
        ..push('stations', stationArray([station('Infeed')]))
        ..push('wagon', DynamicValue(value: '   '));

      await tester.pumpWidget(wrap(
        WagonStationStrip(
          config: WagonStationStripConfig(
              stationsKey: 'stations', wagonStateKey: 'wagon'),
        ),
        sm,
      ));
      await settle(tester);

      expect(find.byIcon(Icons.local_shipping_outlined), findsNothing);
      expect(find.text('Infeed'), findsOneWidget);
    });
  });

  group('the key contract', () {
    test('an unbound strip subscribes to nothing', () {
      expect(WagonStationStripConfig().allKeys, isEmpty);
    });

    test('a bound strip costs one key, or two with the wagon state', () {
      expect(WagonStationStripConfig(stationsKey: 'stations').allKeys,
          ['stations']);
      expect(
        WagonStationStripConfig(stationsKey: 'stations', wagonStateKey: 'wagon')
            .allKeys,
        ['stations', 'wagon'],
      );
      // An empty string is what the key picker leaves behind when somebody
      // clears the field; it is not a key.
      expect(
        WagonStationStripConfig(stationsKey: 'stations', wagonStateKey: '')
            .allKeys,
        ['stations'],
      );
    });

    test('round-trips through JSON with and without the optional key', () {
      final bare = WagonStationStripConfig(stationsKey: 'stations');
      final bareJson = bare.toJson();
      expect(bareJson.containsKey('wagonStateKey'), isFalse,
          reason: 'an asset that never had one must serialise without it');
      final backBare = WagonStationStripConfig.fromJson(bareJson);
      expect(backBare.stationsKey, 'stations');
      expect(backBare.wagonStateKey, isNull);
      expect(backBare.showPositions, isTrue);

      final full = WagonStationStripConfig(
        stationsKey: 'stations',
        wagonStateKey: 'wagon',
        showPositions: false,
      );
      final backFull = WagonStationStripConfig.fromJson(full.toJson());
      expect(backFull.wagonStateKey, 'wagon');
      expect(backFull.showPositions, isFalse);
    });

    test('a page saved before this asset existed still parses', () {
      // Neither member present: the strip has to come back unbound rather
      // than throwing its way out of AssetRegistry.parse.
      final json = WagonStationStripConfig().toJson()..remove('stationsKey');
      expect(WagonStationStripConfig.fromJson(json).stationsKey, '');
    });
  });

  group('decoding', () {
    test('an enum published as its name still lands on the right member', () {
      final row = wagonStationsFromValue(stationArray([
        station('A', rawType: 'eDestination', rawLoc: 'eBehind'),
      ]));
      expect(row.single.role, WagonStationRole.destination);
      expect(row.single.side, WagonStationSide.behind);
    });

    test('a value that is not an array decodes to nothing', () {
      expect(wagonStationsFromValue(DynamicValue(value: 7)), isEmpty);
      expect(wagonStationsFromValue(null), isEmpty);
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

    test('stations sharing a position keep the array\'s own order', () {
      final row = wagonStationsFromValue(stationArray([
        station('Behind', position: 2400, loc: 1),
        station('Front', position: 2400),
      ]));
      expect([for (final s in row) s.name], ['Behind', 'Front']);
      expect([for (final s in row) s.index], [1, 2]);
    });
  });
}

/// Minimal stand-in for [StateMan]: values pushed synchronously by key.
class _FakeStateMan implements StateMan {
  final Map<String, BehaviorSubject<DynamicValue>> _streams = {};

  void push(String key, DynamicValue value) =>
      _streams.putIfAbsent(key, BehaviorSubject<DynamicValue>.new).add(value);

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async =>
      _streams.putIfAbsent(key, BehaviorSubject<DynamicValue>.new).stream;

  @override
  String resolveKey(String key) => key;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      '_FakeStateMan: ${invocation.memberName} not implemented in test scope');
}

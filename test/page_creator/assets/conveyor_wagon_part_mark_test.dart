// A wagon has four things an operator can tap and four panes behind them.
// The ring has to say which one they got.
//
// BUG: only the stations had a subject of their own. The belt drive, the
// traverse drive and both safety edges all opened their panes from the
// conveyor's own context, so the plant view traced the conveyor's published
// hit shape for every one of them — and that shape was the carriage *plus*
// every station dock beside the rail. Whichever piece was tapped, the whole
// installation lit up, and the mark stopped saying anything at all.
//
// FIX: each piece is its own `AssetPart`, laid out as an empty box over the
// rectangle it is painted in, publishing that rectangle as the shape to ring.
// Tap the traverse drive and the rails are marked; tap the belt and the
// carriage is; tap a bumper and it is that bumper. The docks come out of the
// conveyor's own shape with them — `ConveyorPainter.hitTest` still accepts
// them, so nothing about which pane opens changes.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/conveyor.dart';
import 'package:tfc/pages/page_view.dart';
import 'package:tfc/providers/collector.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/widgets/hit_boundary.dart';
import 'package:tfc/widgets/panes/side_pane.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../../helpers/test_helpers.dart' show useInMemoryDeviceLocalPreferences;
import '../../helpers/wagon_fixtures.dart';

const _beltKey = 'line1.wagon1.belt';
const _motorKey = 'line1.wagon1.traverse';
const _leftKey = 'line1.wagon1.edgeLeft';
const _rightKey = 'line1.wagon1.edgeRight';
const _positionKey = 'line1.wagon1.position';
const _stationsKey = 'line1.wagon1.stations';

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
  setUp(() {
    useInMemoryDeviceLocalPreferences();
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  tearDown(() => closeSidePane(immediate: true));

  /// What the ring encloses, in screen coordinates.
  Rect markBounds(WidgetTester tester) {
    final paint = tester.widget<CustomPaint>(find.byKey(openPaneMarkKey));
    final origin = tester.getTopLeft(find.byKey(openPaneMarkKey));
    var rect = Rect.fromLTRB(double.infinity, double.infinity,
        double.negativeInfinity, double.negativeInfinity);
    for (final ring in (paint.painter! as HitBoundaryPainter).contours) {
      for (final local in ring) {
        final p = local + origin;
        rect = Rect.fromLTRB(math.min(rect.left, p.dx), math.min(rect.top, p.dy),
            math.max(rect.right, p.dx), math.max(rect.bottom, p.dy));
      }
    }
    return rect;
  }

  /// A frame for the pane, one past the post-frame trace, and the fade. Not
  /// `pumpAndSettle`: the ring's dashes crawl for as long as it is up.
  ///
  /// Whatever the pane's own body needed is not this test's subject — a drive
  /// pane handed a plain bool where it wants an `FB_ATV320` throws while it
  /// builds, and it has tests of its own. This is about which region routed
  /// the tap and what the plant view ringed for it.
  Future<void> pumpMarked(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 400));
    while (tester.takeException() != null) {}
  }

  /// Pumps one wagon on a canvas and hands back its painter and the canvas
  /// offset its geometry is measured from.
  Future<({ConveyorPainter painter, Offset origin, Size size})> pumpWagon(
    WidgetTester tester, {
    DynamicValue? stations,
  }) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final config = ConveyorConfig(
      key: _beltKey,
      onRails: true,
      wagonMotorKey: _motorKey,
      safetyLeftKey: _leftKey,
      safetyRightKey: _rightKey,
      positionKey: _positionKey,
      stationsKey: stations == null ? null : _stationsKey,
      wagonLength: 0.12,
    )
      // Left half of the page, clear of the pane docked on the right.
      ..coordinates = Coordinates(x: 0.3, y: 0.4)
      ..size = const RelativeSize(width: 0.5, height: 0.3);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        collectorProvider.overrideWith((ref) async => null),
        stateManProvider.overrideWith((ref) async => _RailStateMan({
              _beltKey: DynamicValue(value: true),
              _motorKey: DynamicValue(value: true),
              _leftKey: DynamicValue(value: false),
              _rightKey: DynamicValue(value: false),
              _positionKey: DynamicValue(value: 50.0),
              if (stations != null) _stationsKey: stations,
            })),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: LayoutBuilder(
            builder: (context, constraints) => AssetStack(
              assets: [config],
              constraints: constraints,
              selectedAssets: const {},
              mirroringDisabled: true,
              absorb: false,
            ),
          ),
        ),
      ),
    ));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }

    final paintFinder = find
        .descendant(
            of: find.byType(Conveyor), matching: find.byType(CustomPaint))
        .first;
    final painter =
        tester.widget<CustomPaint>(paintFinder).painter! as ConveyorPainter;
    return (
      painter: painter,
      origin: tester.getTopLeft(paintFinder),
      size: painter.paintSize!,
    );
  }

  final air = HitBoundaryStyle.selection.standoff;

  /// Asserts the ring is [rect] (in the painter's own coordinates, shifted by
  /// [origin]) stood off by the style's clearance, and nothing wider.
  void expectRinged(WidgetTester tester, Rect rect, Offset origin,
      {required String reason}) {
    final want = rect.shift(origin).inflate(air);
    final got = markBounds(tester);
    expect(got.left, closeTo(want.left, 2), reason: reason);
    expect(got.top, closeTo(want.top, 2), reason: reason);
    expect(got.right, closeTo(want.right, 2), reason: reason);
    expect(got.bottom, closeTo(want.bottom, 2), reason: reason);
  }

  testWidgets('the traverse drive is ringed on the rails, not on the wagon',
      (tester) async {
    final wagon = await pumpWagon(tester);
    final rail = wagon.painter.railBandRect(wagon.size)!;
    final carriage = wagon.painter.wagonRect(wagon.size);

    // Bare rail, clear of the carriage: the traverse drive's own target.
    final probe = Offset(carriage.right + 20, rail.center.dy);
    expect(wagon.size.contains(probe) && !carriage.contains(probe), isTrue,
        reason: 'test setup: the probe must be on bare rail');

    await tester.tapAt(wagon.origin + probe);
    await pumpMarked(tester);
    expect(isSidePaneOpen(), isTrue);
    expectRinged(tester, rail, wagon.origin,
        reason: 'the drive that moves the wagon along the rails is marked on '
            'the rails — it used to be marked on the carriage, which is what '
            'the belt drive beside it already claimed');

    // And the rails are a great deal wider than the wagon that rides them,
    // so the two marks cannot be confused for one another.
    expect(rail.width, greaterThan(carriage.width * 2));
    expect(rail.height, lessThan(carriage.height));
  });

  testWidgets('the belt drive is ringed on the carriage', (tester) async {
    final wagon = await pumpWagon(tester);
    final carriage = wagon.painter.wagonRect(wagon.size);

    await tester.tapAt(wagon.origin + wagon.painter.beltRect(wagon.size).center);
    await pumpMarked(tester);
    expect(isSidePaneOpen(), isTrue);
    expectRinged(tester, carriage, wagon.origin,
        reason: 'the belt is on the wagon, so the wagon is what is marked');
  });

  testWidgets('a safety edge is ringed on its own bumper', (tester) async {
    final wagon = await pumpWagon(tester);
    final left = wagon.painter.safetyEdgeRect(wagon.size, left: true)!;
    final right = wagon.painter.safetyEdgeRect(wagon.size, left: false)!;

    await tester.tapAt(wagon.origin + left.center);
    await pumpMarked(tester);
    expect(isSidePaneOpen(), isTrue);
    expectRinged(tester, left, wagon.origin,
        reason: 'the edge that was tapped, not the carriage it is bolted to');

    // The other bumper: the pane swaps and the ring crosses the wagon with it.
    await tester.tapAt(wagon.origin + right.center);
    await pumpMarked(tester);
    expectRinged(tester, right, wagon.origin,
        reason: 'the two edges are different devices and read differently');
  });

  testWidgets('the belt drive on a wagon with stations rings the carriage '
      'alone', (tester) async {
    final wagon = await pumpWagon(
      tester,
      stations: stationArray([
        station('Infeed', position: 0),
        station('Outfeed A', position: 5000, type: 1, loc: 1),
        station('Outfeed B', position: 10000, type: 1),
      ]),
    );
    final docks = wagon.painter.docks(wagon.size);
    expect(docks, hasLength(3));
    final carriage = wagon.painter.wagonRect(wagon.size);

    await tester.tapAt(wagon.origin + wagon.painter.beltRect(wagon.size).center);
    await pumpMarked(tester);
    expect(isSidePaneOpen(), isTrue);
    expectRinged(tester, carriage, wagon.origin,
        reason: 'the conveyor published the docks as part of its own shape, '
            'so opening the belt drive outlined every station on the rail');

    // Explicitly: the ring is a short carriage, not the row of docks. It
    // used to reach from the first dock to the last, because the conveyor
    // published all of them as its own shape.
    final ring = markBounds(tester);
    final row = docks
        .map((d) => d.body.shift(wagon.origin))
        .reduce((a, b) => a.expandToInclude(b));
    expect(ring.width, lessThan(row.width / 2),
        reason: 'the mark spanned the whole run of stations');
    for (final dock in docks) {
      expect(ring.contains(dock.body.shift(wagon.origin).center), isFalse,
          reason: '${dock.station.name} is a pane of its own, not part of '
              "the belt drive's");
    }
  });

  testWidgets('a dock still opens its own pane with the docks out of the '
      'conveyor\'s shape', (tester) async {
    // The docks left `hitShape`, so `hitTest` had to take them instead — if
    // it did not, the gesture detector never sees the tap and a station
    // becomes unreachable.
    final wagon = await pumpWagon(
      tester,
      stations: stationArray([
        station('Infeed', position: 0),
        station('Outfeed A', position: 5000, type: 1, loc: 1),
      ]),
    );
    final dock = wagon.painter
        .docks(wagon.size)
        .firstWhere((d) => d.station.name == 'Outfeed A');

    expect(wagon.painter.hitTest(dock.body.center), isTrue,
        reason: 'a dock has to get past the hit test or the tap never lands');

    await tester.tapAt(wagon.origin + dock.body.center);
    await pumpMarked(tester);
    expect(isSidePaneOpen(), isTrue);
    expectRinged(tester, dock.body, wagon.origin,
        reason: 'the tapped dock, exactly as before');
  });
}

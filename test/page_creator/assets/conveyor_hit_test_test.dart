import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc/page_creator/assets/conveyor.dart';
import 'package:tfc/page_creator/assets/conveyor_gate.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;

// A conveyor's tap target must be the painted belt, not its bounding box.
//
// BUG: a turned conveyor occupies a fraction of its box (an L-belt in a
// square box is mostly empty), yet tapping anywhere in the box opened the
// details pane. Two layers conspired: ConveyorPainter inherited the default
// CustomPainter.hitTest (the full box), and _RenderLayoutRotatedBox claimed
// the whole child rect regardless of the child's own hit-test verdict, so
// even a precise painter would have been overruled.

/// The corner of [box] farthest from the sampled centerline — the deadest
/// spot of the bounding box for an off-belt probe.
Offset _deadCorner(ConveyorPathGeometry g, Size box) {
  final corners = [
    Offset.zero,
    Offset(box.width, 0),
    Offset(0, box.height),
    Offset(box.width, box.height),
  ];
  var best = corners.first;
  var bestDist = -1.0;
  for (final corner in corners) {
    var minDist = double.infinity;
    for (var i = 0; i <= 100; i++) {
      final d = (g.tangentAt(i / 100).position - corner).distance;
      if (d < minDist) minDist = d;
    }
    if (minDist > bestDist) {
      bestDist = minDist;
      best = corner;
    }
  }
  // The probe is only meaningful if the corner clearly misses the belt.
  expect(bestDist, greaterThan(g.beltWidth),
      reason: 'test setup: expected an empty corner well off the belt');
  return best;
}

class _FakeStateMan extends Fake implements StateMan {
  @override
  Future<Stream<DynamicValue>> subscribe(String key) async {
    return Stream<DynamicValue>.value(DynamicValue());
  }
}

Widget _wrap(ConveyorConfig config, Size boxSize) {
  return ProviderScope(
    overrides: [
      stateManProvider.overrideWith((ref) async => _FakeStateMan()),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: boxSize.width,
            height: boxSize.height,
            child: Conveyor(config),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('ConveyorPainter.hitTest', () {
    test('turned belt hits on the belt and misses the empty box corner', () {
      const box = Size(400, 400);
      final g = ConveyorPathGeometry.build(
        [ConveyorTurnEntry(position: 0.5, angle: 90, radius: 1.5)],
        box,
        thicknessFactor: 0.4,
      )!;
      final painter = ConveyorPainter(
        color: Colors.green,
        batches: const {},
        angle: 0,
        geometry: g,
        paintSize: box,
      );

      for (final f in [0.05, 0.25, 0.5, 0.75, 0.95]) {
        expect(painter.hitTest(g.tangentAt(f).position), isTrue,
            reason: 'centerline point at fraction $f must be tappable');
      }
      expect(painter.hitTest(_deadCorner(g, box)), isFalse,
          reason: 'empty corner of the bounding box must not be tappable');
    });

    test('explicit straight band hits only the centred band', () {
      const box = Size(400, 100);
      final painter = ConveyorPainter(
        color: Colors.green,
        batches: const {},
        angle: 0,
        straightBeltWidth: 40,
        paintSize: box,
      );

      // Band spans y = 30..70.
      expect(painter.hitTest(const Offset(200, 50)), isTrue);
      expect(painter.hitTest(const Offset(200, 31)), isTrue);
      expect(painter.hitTest(const Offset(200, 69)), isTrue);
      expect(painter.hitTest(const Offset(200, 10)), isFalse);
      expect(painter.hitTest(const Offset(200, 90)), isFalse);
    });

    test('belt filling the whole box keeps the whole box tappable', () {
      final painter = ConveyorPainter(
        color: Colors.green,
        batches: const {},
        angle: 0,
        paintSize: const Size(400, 100),
      );
      expect(painter.hitTest(const Offset(1, 1)), isTrue);
      expect(painter.hitTest(const Offset(399, 99)), isTrue);
    });
  });

  group('Conveyor widget tap target', () {
    // The test window is 800x600 logical pixels; a RelativeSize of half the
    // screen keeps the painter's resolved size equal to the SizedBox the
    // widget actually lays out in, as the page does with its asset rects.
    const boxSize = Size(400, 300);
    const relSize = RelativeSize(width: 0.5, height: 0.5);

    /// Whether a hit test at [global] reaches the conveyor's GestureDetector.
    Future<bool> hitsDetector(WidgetTester tester, Offset global) async {
      final detector = find.descendant(
        of: find.byType(Conveyor),
        matching: find.byType(GestureDetector),
      );
      expect(detector, findsOneWidget,
          reason: 'main key must be configured so the tap handler mounts');
      final detectorRenderObject = tester.renderObject(detector);
      final result = tester.hitTestOnBinding(global);
      return result.path.any((entry) => entry.target == detectorRenderObject);
    }

    testWidgets('turned conveyor: belt taps register, box-corner taps do not',
        (tester) async {
      final turns = [ConveyorTurnEntry(position: 0.5, angle: 90, radius: 1.5)];
      final config = ConveyorConfig(key: 'AREA01.CN01', turns: turns)
        ..size = relSize;

      await tester.pumpWidget(_wrap(config, boxSize));
      // Let the StateMan future resolve and the stream deliver a snapshot,
      // so the GestureDetector branch renders.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Same geometry the widget builds for itself.
      final g = ConveyorPathGeometry.build(
        turns,
        boxSize,
        thicknessFactor: config.effectiveBeltThickness,
      )!;
      final topLeft = tester.getTopLeft(find.byType(Conveyor));

      final onBelt = topLeft + g.tangentAt(0.5).position;
      expect(await hitsDetector(tester, onBelt), isTrue,
          reason: 'tap on the painted belt must reach the tap handler');

      // Nudge the dead corner 1px inwards so the probe stays inside the box.
      final corner = _deadCorner(g, boxSize);
      final inward = Offset(
        corner.dx == 0 ? 1 : -1,
        corner.dy == 0 ? 1 : -1,
      );
      final offBelt = topLeft + corner + inward;
      expect(await hitsDetector(tester, offBelt), isFalse,
          reason: 'tap on the empty bounding box must not reach the handler');
    });

    testWidgets('child gate riding the conveyor still receives its own taps',
        (tester) async {
      // An interactive gate mounts its own GestureDetector; a tap on the gate
      // must reach it even though the gate hangs off the belt, where the
      // conveyor painter itself reports a miss.
      final config = ConveyorConfig(
        key: 'AREA01.CN01',
        turns: [ConveyorTurnEntry(position: 0.5, angle: 90, radius: 1.5)],
        beltThickness: 0.2,
        gates: [
          ChildGateEntry(
            position: 0.25,
            side: GateSide.right,
            gate: ConveyorGateConfig(
              gateVariant: GateVariant.pusher,
              forceOpenKey: 'AREA01.CN01.GATE.forceOpen',
            ),
          ),
        ],
      )..size = relSize;

      await tester.pumpWidget(_wrap(config, boxSize));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final gateDetector = find.descendant(
        of: find.byType(ConveyorGate),
        matching: find.byType(GestureDetector),
      );
      expect(gateDetector, findsOneWidget,
          reason: 'a gate with a force key must mount its tap handler');
      final gateRenderObject = tester.renderObject(gateDetector);

      final probe = tester.getCenter(find.byType(ConveyorGate));
      final conveyorRect = tester.getRect(find.byType(Conveyor));
      expect(conveyorRect.contains(probe), isTrue,
          reason: 'test setup: gate centre must lie inside the conveyor box');

      final result = tester.hitTestOnBinding(probe);
      expect(
          result.path.any((entry) => entry.target == gateRenderObject), isTrue,
          reason: 'tap on a child gate must reach the gate\'s own handler');
    });

    testWidgets('straight conveyor keeps its whole box tappable',
        (tester) async {
      final config = ConveyorConfig(key: 'AREA01.CN01')..size = relSize;

      await tester.pumpWidget(_wrap(config, boxSize));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final topLeft = tester.getTopLeft(find.byType(Conveyor));
      expect(await hitsDetector(tester, topLeft + const Offset(2, 2)), isTrue,
          reason: 'a straight belt fills its box, so the box is the belt');
      expect(
          await hitsDetector(
              tester, topLeft + Offset(boxSize.width - 2, boxSize.height - 2)),
          isTrue);
    });
  });
}

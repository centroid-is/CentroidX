
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/conveyor.dart';
import 'package:tfc/page_creator/assets/conveyor_gate.dart';
import '../../helpers/golden_platform.dart';

const _key = Key('conveyor_turn_test');

/// Paints a [ConveyorPainter] directly so goldens can drive geometry, color
/// and batches without PLC streams.
Widget buildPainterScenario({
  required Size canvasSize,
  List<ConveyorTurnEntry> turns = const [],
  Map<String, Batch> batches = const {},
  Color color = Colors.green,
  bool showFrequency = false,
  double? frequency,
  // The turned-belt default: what ConveyorConfig.effectiveBeltThickness
  // resolves to when nothing is configured.
  double thickness = 0.4,
}) {
  final geometry = ConveyorPathGeometry.build(turns, canvasSize,
      thicknessFactor: thickness);
  return MaterialApp(
    home: Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      body: Center(
        child: RepaintBoundary(
          key: _key,
          child: SizedBox(
            width: canvasSize.width,
            height: canvasSize.height,
            child: CustomPaint(
              size: canvasSize,
              painter: ConveyorPainter(
                color: color,
                batches: batches,
                angle: 0,
                showFrequency: showFrequency,
                frequency: frequency,
                geometry: geometry,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('Conveyor turn golden tests',
      skip: goldenSkip, () {
    testWidgets('straight conveyor unchanged (regression)', (tester) async {
      await tester.pumpWidget(buildPainterScenario(
        canvasSize: const Size(400, 60),
        batches: {
          '0': Batch(start: 0.3, end: 0.45, color: Colors.white),
        },
      ));
      await expectLater(
        find.byKey(_key),
        matchesGoldenFile('goldens/conveyor_straight_regression.png'),
      );
    });

    testWidgets('single 45 degree turn at 30 percent', (tester) async {
      await tester.pumpWidget(buildPainterScenario(
        canvasSize: const Size(400, 120),
        turns: [ConveyorTurnEntry(position: 0.3, angle: 45, radius: 1.5)],
      ));
      await expectLater(
        find.byKey(_key),
        matchesGoldenFile('goldens/conveyor_turn_45_at_30.png'),
      );
    });

    testWidgets('90 degree turn with batches crossing the bend',
        (tester) async {
      await tester.pumpWidget(buildPainterScenario(
        canvasSize: const Size(400, 200),
        turns: [ConveyorTurnEntry(position: 0.4, angle: 90, radius: 1.5)],
        thickness: 0.3,
        batches: {
          '0': Batch(start: 0.15, end: 0.3, color: Colors.white),
          // This batch spans the arc — must bend with the belt.
          '1': Batch(start: 0.45, end: 0.6, color: Colors.yellow),
          '2': Batch(start: 0.75, end: 0.9, color: Colors.white),
        },
      ));
      await expectLater(
        find.byKey(_key),
        matchesGoldenFile('goldens/conveyor_turn_90_batches.png'),
      );
    });

    testWidgets('thin L-shape via belt thickness factor', (tester) async {
      // The motivating case for beltThickness: an L-shaped conveyor in a
      // square-ish box with a thin belt.
      await tester.pumpWidget(buildPainterScenario(
        canvasSize: const Size(300, 300),
        turns: [ConveyorTurnEntry(position: 0.5, angle: 90, radius: 1.5)],
        thickness: 0.15,
        batches: {
          '0': Batch(start: 0.2, end: 0.3, color: Colors.white),
          '1': Batch(start: 0.7, end: 0.8, color: Colors.white),
        },
      ));
      await expectLater(
        find.byKey(_key),
        matchesGoldenFile('goldens/conveyor_thin_l_shape.png'),
      );
    });

    testWidgets('s-curve with batch on second bend', (tester) async {
      await tester.pumpWidget(buildPainterScenario(
        canvasSize: const Size(400, 160),
        turns: [
          ConveyorTurnEntry(position: 0.25, angle: 60, radius: 1.5),
          ConveyorTurnEntry(position: 0.6, angle: -60, radius: 1.5),
        ],
        thickness: 0.35,
        batches: {
          '0': Batch(start: 0.6, end: 0.75, color: Colors.white),
        },
      ));
      await expectLater(
        find.byKey(_key),
        matchesGoldenFile('goldens/conveyor_s_curve.png'),
      );
    });

    testWidgets('u-shape with two 90 degree turns', (tester) async {
      await tester.pumpWidget(buildPainterScenario(
        canvasSize: const Size(300, 250),
        turns: [
          ConveyorTurnEntry(position: 0.3, angle: 90, radius: 1.0),
          ConveyorTurnEntry(position: 0.6, angle: 90, radius: 1.0),
        ],
        thickness: 0.25,
      ));
      await expectLater(
        find.byKey(_key),
        matchesGoldenFile('goldens/conveyor_u_shape.png'),
      );
    });

    testWidgets('negative angle turns upward', (tester) async {
      await tester.pumpWidget(buildPainterScenario(
        canvasSize: const Size(400, 120),
        turns: [ConveyorTurnEntry(position: 0.5, angle: -45, radius: 2.0)],
        color: Colors.grey,
      ));
      await expectLater(
        find.byKey(_key),
        matchesGoldenFile('goldens/conveyor_turn_negative_45.png'),
      );
    });

    testWidgets('frequency text centered on turned belt', (tester) async {
      // Note: golden tests render text with the blocky Ahem test font, so
      // "42.5" appears as solid boxes — this verifies centered placement,
      // not glyph rendering.
      await tester.pumpWidget(buildPainterScenario(
        canvasSize: const Size(400, 140),
        turns: [ConveyorTurnEntry(position: 0.35, angle: 50, radius: 1.5)],
        thickness: 0.5,
        showFrequency: true,
        frequency: 42.5,
      ));
      await expectLater(
        find.byKey(_key),
        matchesGoldenFile('goldens/conveyor_turn_frequency.png'),
      );
    });

    testWidgets('full widget: turned preview conveyor with gates',
        (tester) async {
      // Exercises the real Conveyor widget path (preview mode): turned belt
      // plus child gates placed along the curved centerline.
      final config = ConveyorConfig.preview()
        ..size = const RelativeSize(width: 0.5, height: 0.25)
        ..beltThickness = 0.4
        ..turns.add(ConveyorTurnEntry(position: 0.45, angle: 60, radius: 1.5))
        ..gates.addAll([
          ChildGateEntry(
            position: 0.25,
            side: GateSide.left,
            gate: ConveyorGateConfig(),
          ),
          ChildGateEntry(
            position: 0.75,
            side: GateSide.right,
            gate: ConveyorGateConfig(),
          ),
        ]);

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              backgroundColor: const Color(0xFF1A1A2E),
              body: Center(
                child: RepaintBoundary(
                  key: _key,
                  child: SizedBox(
                    // Room for gate overhang around the 400x150 conveyor.
                    width: 560,
                    height: 320,
                    child: Center(child: Conveyor(config)),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await expectLater(
        find.byKey(_key),
        matchesGoldenFile('goldens/conveyor_turn_with_gates.png'),
      );
    });
  });
}

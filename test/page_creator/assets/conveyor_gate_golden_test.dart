import 'dart:math' show pi;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/conveyor_gate.dart';
import 'package:tfc/page_creator/assets/conveyor_gate_painter.dart';
import '../../helpers/golden_platform.dart';

const _gateKey = Key('gate_test');

/// Wraps a gate painter in a minimal widget tree for golden testing.
///
/// Dispatches to the correct painter based on [variant]:
/// - [GateVariant.pneumatic]: PneumaticDiverterPainter (uses [openAngle])
/// - [GateVariant.slider]: SliderGatePainter
/// - [GateVariant.pusher]: PusherGatePainter
Widget buildGateWidget({
  GateVariant variant = GateVariant.pneumatic,
  double progress = 0.0,
  Color color = Colors.green,
  double openAngle = 45.0,
  GateSide side = GateSide.left,
}) {
  final progressNotifier = ValueNotifier(progress);
  final CustomPainter painter;
  switch (variant) {
    case GateVariant.pneumatic:
      painter = PneumaticDiverterPainter(
        progress: progressNotifier,
        stateColor: color,
        openAngleDegrees: openAngle,
        side: side,
      );
    case GateVariant.slider:
      painter = SliderGatePainter(
        progress: progressNotifier,
        stateColor: color,
        side: side,
      );
    case GateVariant.pusher:
      painter = PusherGatePainter(
        progress: progressNotifier,
        stateColor: color,
        side: side,
      );
  }

  return MaterialApp(
    home: Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      body: Center(
        child: RepaintBoundary(
          key: _gateKey,
          child: SizedBox(
            width: 200,
            height: 200,
            child: CustomPaint(painter: painter),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('ConveyorGate golden tests',
      skip: goldenSkip, () {
    // ── Pneumatic diverter (existing) ──

    testWidgets('gate closed', (tester) async {
      await tester.pumpWidget(
          buildGateWidget(progress: 0.0, color: Colors.white));
      await expectLater(
        find.byKey(_gateKey),
        matchesGoldenFile('goldens/conveyor_gate_closed.png'),
      );
    });

    testWidgets('gate open', (tester) async {
      await tester.pumpWidget(
          buildGateWidget(progress: 1.0, color: Colors.green));
      await expectLater(
        find.byKey(_gateKey),
        matchesGoldenFile('goldens/conveyor_gate_open.png'),
      );
    });

    testWidgets('gate right side', (tester) async {
      await tester.pumpWidget(buildGateWidget(
        progress: 1.0,
        color: Colors.green,
        side: GateSide.right,
      ));
      await expectLater(
        find.byKey(_gateKey),
        matchesGoldenFile('goldens/conveyor_gate_right_open.png'),
      );
    });

    // ── Slider gate ──

    testWidgets('slider closed', (tester) async {
      await tester.pumpWidget(buildGateWidget(
        variant: GateVariant.slider,
        progress: 0.0,
        color: Colors.white,
      ));
      await expectLater(
        find.byKey(_gateKey),
        matchesGoldenFile('goldens/conveyor_gate_slider_closed.png'),
      );
    });

    testWidgets('slider open', (tester) async {
      await tester.pumpWidget(buildGateWidget(
        variant: GateVariant.slider,
        progress: 1.0,
        color: Colors.green,
      ));
      await expectLater(
        find.byKey(_gateKey),
        matchesGoldenFile('goldens/conveyor_gate_slider_open.png'),
      );
    });

    // ── Pusher gate ──

    testWidgets('pusher closed', (tester) async {
      await tester.pumpWidget(buildGateWidget(
        variant: GateVariant.pusher,
        progress: 0.0,
        color: Colors.white,
      ));
      await expectLater(
        find.byKey(_gateKey),
        matchesGoldenFile('goldens/conveyor_gate_pusher_closed.png'),
      );
    });

    testWidgets('pusher open', (tester) async {
      await tester.pumpWidget(buildGateWidget(
        variant: GateVariant.pusher,
        progress: 1.0,
        color: Colors.green,
      ));
      await expectLater(
        find.byKey(_gateKey),
        matchesGoldenFile('goldens/conveyor_gate_pusher_open.png'),
      );
    });

    // ── Child gate on conveyor placement ──

    testWidgets('child gate on conveyor — top and bottom', (tester) async {
      // Simulates _positionedChildGate with a taller conveyor (realistic app proportions)
      // to verify gate placement relative to conveyor borders.
      const conveyorW = 400.0;
      const conveyorH = 120.0; // realistic: user's conveyor is tall
      final gateSize = conveyorH; // same formula as production code
      final progressNotifier = ValueNotifier(0.0); // closed

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          backgroundColor: const Color(0xFF1A1A2E),
          body: Center(
            child: RepaintBoundary(
              key: _gateKey,
              child: SizedBox(
                width: conveyorW,
                height: conveyorH + gateSize * 2, // room for overflow
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // Center the conveyor vertically in the test area
                    Positioned(
                      left: 0,
                      top: gateSize, // offset so top gate overflow is visible
                      width: conveyorW,
                      height: conveyorH,
                      child: CustomPaint(
                        size: const Size(conveyorW, conveyorH),
                        painter: _SimpleConveyorPainter(),
                      ),
                    ),
                    // Top gate (GateSide.left) at position 0.3 — rotated +90° (clockwise)
                    Positioned(
                      left: 0.3 * conveyorW - gateSize / 2,
                      top: gateSize + (-gateSize * 0.5), // conveyor offset + 50/50 on border
                      width: gateSize,
                      height: gateSize,
                      child: Transform.rotate(
                        angle: pi / 2,
                        child: CustomPaint(
                          painter: SliderGatePainter(
                            progress: progressNotifier,
                            stateColor: Colors.white,
                            side: GateSide.left,
                          ),
                        ),
                      ),
                    ),
                    // Bottom gate (GateSide.right) at position 0.7 — rotated +90° (clockwise)
                    Positioned(
                      left: 0.7 * conveyorW - gateSize / 2,
                      top: gateSize + (conveyorH - gateSize * 0.5), // conveyor offset + 50/50 on border
                      width: gateSize,
                      height: gateSize,
                      child: Transform.rotate(
                        angle: pi / 2,
                        child: CustomPaint(
                          painter: SliderGatePainter(
                            progress: progressNotifier,
                            stateColor: Colors.white,
                            side: GateSide.right,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ));

      await expectLater(
        find.byKey(_gateKey),
        matchesGoldenFile('goldens/conveyor_child_gate_placement.png'),
      );
    });
  });
}

/// Minimal conveyor painter for golden tests — just a filled rounded rect
/// with black border, matching _ConveyorPainter's visual output.
class _SimpleConveyorPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final borderRadius = Radius.circular(size.shortestSide * 0.2);
    final rrect = RRect.fromRectAndRadius(rect, borderRadius);
    canvas.drawRRect(rrect, Paint()..color = const Color(0xFF4CAF50));
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

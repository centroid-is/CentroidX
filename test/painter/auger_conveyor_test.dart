
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/auger_conveyor_painter.dart';
import '../helpers/golden_platform.dart';

const _augerKey = Key('auger_test_widget');

/// Wraps the auger painter in a minimal widget tree for testing.
Widget buildAugerTestWidget({
  Color stateColor = Colors.grey,
  double phaseOffset = 0.0,
  bool showAuger = true,
  int pitchCount = 6,
  AugerOpenEnd? openEnd = AugerOpenEnd.right,
  double width = 600,
  double height = 120,
}) {
  return MaterialApp(
    home: Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      body: Center(
        child: RepaintBoundary(
          key: _augerKey,
          child: SizedBox(
            width: width,
            height: height,
            child: CustomPaint(
              painter: AugerConveyorPainter(
                stateColor: stateColor,
                phaseNotifier: ValueNotifier(phaseOffset),
                showAuger: showAuger,
                pitchCount: pitchCount,
                openEnd: openEnd,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('AugerConveyorPainter', () {
    // ── Unit tests for painter properties ──

    test('shouldRepaint returns true when stateColor changes', () {
      final n = ValueNotifier(0.0);
      final a = AugerConveyorPainter(stateColor: Colors.green, phaseNotifier: n);
      final b = AugerConveyorPainter(stateColor: Colors.red, phaseNotifier: n);
      expect(a.shouldRepaint(b), isTrue);
    });

    test('shouldRepaint returns false when nothing changes', () {
      final n = ValueNotifier(0.0);
      final a = AugerConveyorPainter(stateColor: Colors.grey, phaseNotifier: n);
      final b = AugerConveyorPainter(stateColor: Colors.grey, phaseNotifier: n);
      expect(a.shouldRepaint(b), isFalse);
    });

    test('shouldRepaint returns true when showAuger changes', () {
      final n = ValueNotifier(0.0);
      final a = AugerConveyorPainter(stateColor: Colors.grey, phaseNotifier: n, showAuger: true);
      final b = AugerConveyorPainter(stateColor: Colors.grey, phaseNotifier: n, showAuger: false);
      expect(a.shouldRepaint(b), isTrue);
    });

    test('shouldRepaint returns true when openEnd changes', () {
      final n = ValueNotifier(0.0);
      final a = AugerConveyorPainter(stateColor: Colors.grey, phaseNotifier: n, openEnd: AugerOpenEnd.left);
      final b = AugerConveyorPainter(stateColor: Colors.grey, phaseNotifier: n, openEnd: AugerOpenEnd.right);
      expect(a.shouldRepaint(b), isTrue);
    });

    // ── Widget rendering tests ──

    testWidgets('renders without errors at default size', (tester) async {
      await tester.pumpWidget(buildAugerTestWidget());
      expect(find.byKey(_augerKey), findsOneWidget);
    });

    testWidgets('renders in flat mode when showAuger is false',
        (tester) async {
      await tester.pumpWidget(buildAugerTestWidget(showAuger: false));
      expect(find.byKey(_augerKey), findsOneWidget);
    });

    testWidgets('renders with different state colors', (tester) async {
      for (final color in [
        Colors.green,
        Colors.blue,
        Colors.yellow,
        Colors.grey,
        Colors.red
      ]) {
        await tester.pumpWidget(buildAugerTestWidget(stateColor: color));
        expect(find.byKey(_augerKey), findsOneWidget);
      }
    });

    testWidgets('renders at small sizes without errors', (tester) async {
      await tester.pumpWidget(buildAugerTestWidget(width: 60, height: 15));
      expect(find.byKey(_augerKey), findsOneWidget);
    });

    testWidgets('renders with various phase offsets', (tester) async {
      for (final phase in [0.0, 0.5, 1.0, 3.14, 6.28]) {
        await tester.pumpWidget(buildAugerTestWidget(phaseOffset: phase));
        expect(find.byKey(_augerKey), findsOneWidget);
      }
    });

    testWidgets('renders with different pitch counts', (tester) async {
      for (final count in [2, 4, 6, 10]) {
        await tester.pumpWidget(buildAugerTestWidget(pitchCount: count));
        expect(find.byKey(_augerKey), findsOneWidget);
      }
    });

    testWidgets('renders with all open end variants', (tester) async {
      for (final end in [AugerOpenEnd.left, AugerOpenEnd.right, null]) {
        await tester.pumpWidget(buildAugerTestWidget(openEnd: end));
        expect(find.byKey(_augerKey), findsOneWidget);
      }
    });

    // ── Golden file tests ──
    // Golden images were generated on macOS; pixel output differs on other
    // platforms due to font rendering and Skia backend differences.
    group('golden file tests', skip: goldenSkip, () {
      testWidgets('golden: default grey stopped auger', (tester) async {
        await tester.pumpWidget(buildAugerTestWidget());
        await expectLater(
          find.byKey(_augerKey),
          matchesGoldenFile('goldens/auger_grey_stopped.png'),
        );
      });

      testWidgets('golden: green running auger', (tester) async {
        await tester.pumpWidget(buildAugerTestWidget(
          stateColor: Colors.green,
          phaseOffset: 0.8,
        ));
        await expectLater(
          find.byKey(_augerKey),
          matchesGoldenFile('goldens/auger_green_running.png'),
        );
      });

      testWidgets('golden: red fault auger', (tester) async {
        await tester.pumpWidget(buildAugerTestWidget(
          stateColor: Colors.red,
          phaseOffset: 2.0,
        ));
        await expectLater(
          find.byKey(_augerKey),
          matchesGoldenFile('goldens/auger_red_fault.png'),
        );
      });

      testWidgets('golden: blue clean auger', (tester) async {
        await tester.pumpWidget(buildAugerTestWidget(
          stateColor: Colors.blue,
          phaseOffset: 1.5,
        ));
        await expectLater(
          find.byKey(_augerKey),
          matchesGoldenFile('goldens/auger_blue_clean.png'),
        );
      });

      testWidgets('golden: yellow manual auger', (tester) async {
        await tester.pumpWidget(buildAugerTestWidget(
          stateColor: Colors.yellow,
          phaseOffset: 1.0,
        ));
        await expectLater(
          find.byKey(_augerKey),
          matchesGoldenFile('goldens/auger_yellow_manual.png'),
        );
      });

      testWidgets('golden: flat conveyor (no auger)', (tester) async {
        await tester.pumpWidget(buildAugerTestWidget(showAuger: false));
        await expectLater(
          find.byKey(_augerKey),
          matchesGoldenFile('goldens/auger_flat_mode.png'),
        );
      });

      testWidgets('golden: rotation phase 0', (tester) async {
        await tester.pumpWidget(buildAugerTestWidget(
          stateColor: Colors.green,
          phaseOffset: 0.0,
        ));
        await expectLater(
          find.byKey(_augerKey),
          matchesGoldenFile('goldens/auger_phase_0.png'),
        );
      });

      testWidgets('golden: rotation phase quarter', (tester) async {
        await tester.pumpWidget(buildAugerTestWidget(
          stateColor: Colors.green,
          phaseOffset: 1.57,
        ));
        await expectLater(
          find.byKey(_augerKey),
          matchesGoldenFile('goldens/auger_phase_quarter.png'),
        );
      });

      testWidgets('golden: rotation phase half', (tester) async {
        await tester.pumpWidget(buildAugerTestWidget(
          stateColor: Colors.green,
          phaseOffset: 3.14,
        ));
        await expectLater(
          find.byKey(_augerKey),
          matchesGoldenFile('goldens/auger_phase_half.png'),
        );
      });

      testWidgets('golden: rotation phase three quarter', (tester) async {
        await tester.pumpWidget(buildAugerTestWidget(
          stateColor: Colors.green,
          phaseOffset: 4.71,
        ));
        await expectLater(
          find.byKey(_augerKey),
          matchesGoldenFile('goldens/auger_phase_three_quarter.png'),
        );
      });

      // ── Open end golden tests ──

      testWidgets('golden: open end right', (tester) async {
        await tester.pumpWidget(buildAugerTestWidget(
          stateColor: Colors.green,
          phaseOffset: 0.8,
          openEnd: AugerOpenEnd.right,
        ));
        await expectLater(
          find.byKey(_augerKey),
          matchesGoldenFile('goldens/auger_open_right.png'),
        );
      });

      testWidgets('golden: open end left', (tester) async {
        await tester.pumpWidget(buildAugerTestWidget(
          stateColor: Colors.green,
          phaseOffset: 0.8,
          openEnd: AugerOpenEnd.left,
        ));
        await expectLater(
          find.byKey(_augerKey),
          matchesGoldenFile('goldens/auger_open_left.png'),
        );
      });

      testWidgets('golden: no open end', (tester) async {
        await tester.pumpWidget(buildAugerTestWidget(
          stateColor: Colors.green,
          phaseOffset: 0.8,
          openEnd: null,
        ));
        await expectLater(
          find.byKey(_augerKey),
          matchesGoldenFile('goldens/auger_open_none.png'),
        );
      });
    });

  });
}

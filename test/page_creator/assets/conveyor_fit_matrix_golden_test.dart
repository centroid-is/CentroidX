
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/conveyor.dart';
import '../../helpers/golden_platform.dart';

const _key = Key('conveyor_fit_matrix');

/// One cell of the matrix: the asset's bounding box drawn as a blue outline,
/// with the belt painted inside it. The point of the golden is the
/// relationship between the two — a belt that shrinks away from its box is a
/// failure even when the belt itself looks fine.
Widget _cell({
  required String label,
  required Size box,
  List<ConveyorTurnEntry> turns = const [],
  double? thickness,
  double? beltWidthOverride,
  double? straightBeltWidth,
}) {
  // Mirror what the asset renders with, so the matrix exercises the real
  // default rather than a value only the test knows about.
  final factor = thickness ??
      ConveyorConfig(turns: turns).effectiveBeltThickness;
  final geometry = ConveyorPathGeometry.build(turns, box,
      thicknessFactor: factor, beltWidthOverride: beltWidthOverride);
  return Padding(
    padding: const EdgeInsets.all(8),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                color: Colors.white70, fontSize: 10, fontFamily: 'Roboto')),
        const SizedBox(height: 2),
        Container(
          width: box.width,
          height: box.height,
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFF3DA9FC), width: 1),
          ),
          child: CustomPaint(
            size: box,
            painter: ConveyorPainter(
              color: Colors.green,
              batches: {
                '0': Batch(start: 0.10, end: 0.25, color: Colors.white),
                '1': Batch(start: 0.45, end: 0.60, color: Colors.yellow),
                '2': Batch(start: 0.80, end: 0.95, color: Colors.white),
              },
              angle: 0,
              showFrequency: false,
              frequency: null,
              geometry: geometry,
              straightBeltWidth: straightBeltWidth,
            ),
          ),
        ),
      ],
    ),
  );
}

Widget _matrix(List<Widget> cells) => MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF1A1A2E),
        body: RepaintBoundary(
          key: _key,
          child: Wrap(children: cells),
        ),
      ),
    );

void main() {
  group('Conveyor fit matrix',
      skip: goldenSkip, () {
    testWidgets('turns across box aspect ratios', (tester) async {
      tester.view.physicalSize = const Size(1500, 1100);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const boxes = <String, Size>{
        'wide 400x60': Size(400, 60),
        'wide 400x120': Size(400, 120),
        'square 220x220': Size(220, 220),
        'tall 120x300': Size(120, 300),
      };
      final turnSets = <String, List<ConveyorTurnEntry>>{
        'straight': const [],
        '30deg@0.3': [ConveyorTurnEntry(position: 0.3, angle: 30, radius: 1.5)],
        '90deg@0.5': [ConveyorTurnEntry(position: 0.5, angle: 90, radius: 1.5)],
        's-curve': [
          ConveyorTurnEntry(position: 0.25, angle: 60, radius: 1.5),
          ConveyorTurnEntry(position: 0.6, angle: -60, radius: 1.5),
        ],
      };

      final cells = <Widget>[];
      for (final b in boxes.entries) {
        for (final t in turnSets.entries) {
          cells.add(_cell(
            label: '${b.key} | ${t.key}',
            box: b.value,
            turns: t.value,
          ));
        }
      }

      await tester.pumpWidget(_matrix(cells));
      await expectLater(
        find.byKey(_key),
        matchesGoldenFile('goldens/conveyor_fit_matrix.png'),
      );
    });

    // Reference geometry from a CAD drawing: a belt that runs out along the
    // top, flares outward, U-turns, and returns along the bottom. It enters
    // heading right and leaves heading left, so the sweeps must total 180.
    // The drawing is symmetric about the horizontal axis, which pins both the
    // flare/loop split (-30 + 120 + 120 - 30 = 180) and the positions, which
    // mirror about 0.5 so the entry and exit runs come out equal.
    List<ConveyorTurnEntry> uTurn({double loopRadius = 1.2}) => [
          ConveyorTurnEntry(position: 0.15, angle: -30, radius: 1.0),
          ConveyorTurnEntry(position: 0.35, angle: 120, radius: loopRadius),
          ConveyorTurnEntry(position: 0.65, angle: 120, radius: loopRadius),
          ConveyorTurnEntry(position: 0.85, angle: -30, radius: 1.0),
        ];

    testWidgets('flared u-turn return loop (CAD reference)', (tester) async {
      tester.view.physicalSize = const Size(1500, 1500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final cells = <Widget>[];
      for (final box in const [
        Size(400, 400),
        Size(400, 300),
        Size(300, 400),
      ]) {
        for (final thickness in [0.3, 0.15]) {
          cells.add(_cell(
            label: '${box.width.toInt()}x${box.height.toInt()} | thk $thickness',
            box: box,
            turns: uTurn(),
            thickness: thickness,
          ));
        }
      }
      // Loop radius sweep on a square box.
      for (final r in [0.8, 1.5, 2.5]) {
        cells.add(_cell(
          label: 'radius $r',
          box: const Size(400, 400),
          turns: uTurn(loopRadius: r),
          thickness: 0.15,
        ));
      }

      await tester.pumpWidget(_matrix(cells));
      await expectLater(
        find.byKey(_key),
        matchesGoldenFile('goldens/conveyor_u_turn_flared.png'),
      );
    });

    testWidgets('same belt width, straight vs turned', (tester) async {
      // The point of the screen-relative width: set both to the same number
      // and the belts match, whatever their boxes or turns do.
      tester.view.physicalSize = const Size(1500, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const beltWidth = 30.0;
      final cells = <Widget>[
        _cell(
            label: 'straight, box 400x160',
            box: const Size(400, 160),
            straightBeltWidth: beltWidth),
        _cell(
            label: '45deg, box 400x160',
            box: const Size(400, 160),
            turns: [ConveyorTurnEntry(position: 0.4, angle: 45, radius: 1.5)],
            beltWidthOverride: beltWidth),
        _cell(
            label: '90deg, box 400x220',
            box: const Size(400, 220),
            turns: [ConveyorTurnEntry(position: 0.5, angle: 90, radius: 1.5)],
            beltWidthOverride: beltWidth),
        _cell(
            label: 'u-turn, box 400x300',
            box: const Size(400, 300),
            turns: uTurn(loopRadius: 2.5),
            beltWidthOverride: beltWidth),
        _cell(
            label: 'straight, taller box 400x260',
            box: const Size(400, 260),
            straightBeltWidth: beltWidth),
      ];

      await tester.pumpWidget(_matrix(cells));
      await expectLater(
        find.byKey(_key),
        matchesGoldenFile('goldens/conveyor_belt_width_match.png'),
      );
    });

    testWidgets('explicit belt width survives the box being resized',
        (tester) async {
      // An explicit width is in screen units, so it has to paint the same
      // belt whatever the box does — including boxes too short to hold it,
      // where the belt now spills over the box edge instead of thinning.
      tester.view.physicalSize = const Size(1500, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const beltWidth = 40.0;
      final cells = <Widget>[];
      for (final height in [200.0, 120.0, 60.0, 30.0]) {
        cells.add(_cell(
            label: 'straight, box 360x${height.toInt()}',
            box: Size(360, height),
            straightBeltWidth: beltWidth));
        cells.add(_cell(
            label: '45deg, box 360x${height.toInt()}',
            box: Size(360, height),
            turns: [ConveyorTurnEntry(position: 0.4, angle: 45, radius: 1.5)],
            beltWidthOverride: beltWidth));
      }

      await tester.pumpWidget(_matrix(cells));
      await expectLater(
        find.byKey(_key),
        matchesGoldenFile('goldens/conveyor_belt_width_box_sweep.png'),
      );
    });

    testWidgets('thickness factor sweep on a wide box', (tester) async {
      tester.view.physicalSize = const Size(1500, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final cells = <Widget>[];
      for (final thickness in [1.0, 0.6, 0.3, 0.15]) {
        for (final angle in [30.0, 45.0, 90.0]) {
          cells.add(_cell(
            label: 'thk $thickness | ${angle.toInt()}deg',
            box: const Size(400, 100),
            turns: [
              ConveyorTurnEntry(position: 0.4, angle: angle, radius: 1.5)
            ],
            thickness: thickness,
          ));
        }
      }

      await tester.pumpWidget(_matrix(cells));
      await expectLater(
        find.byKey(_key),
        matchesGoldenFile('goldens/conveyor_fit_thickness.png'),
      );
    });
  });
}

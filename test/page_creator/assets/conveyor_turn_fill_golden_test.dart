// The turned belt against its own bounding box, at every window shape.
//
// `conveyor_turn_fill_test.dart` measures this in numbers; this is the same
// claim as a picture, because the numbers are only a proxy for what the
// operator complains about — a belt adrift in its box, and a different belt
// after a resize.
//
// Every cell draws the asset's bounding box as a blue outline with the belt
// painted inside it. The box is what the page editor selects and what the
// operator positions; a belt that does not fill it, or does not sit in the
// middle of it, is the failure, however good the belt looks on its own.
//
// The shape is the plant's return-loop belt: a U-turn of four fillets whose
// sweeps total 180, so it leaves heading back the way it came. The box and
// belt width are taken as fractions of the canvas, which is how a page
// stores them, so each cell is what that one configured belt looks like on
// that one screen.


import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/conveyor.dart';
import '../../helpers/golden_platform.dart';

const _key = Key('conveyor_turn_fill');

/// The reference belt, as a page stores it: fractions of the canvas.
const _relW = 0.1, _relH = 0.095, _relBelt = 0.025;

List<ConveyorTurnEntry> _uTurn() => [
      ConveyorTurnEntry(position: 0.15, angle: -30, radius: 1.2),
      ConveyorTurnEntry(position: 0.3, angle: 120, radius: 1.2),
      ConveyorTurnEntry(position: 0.7, angle: 120, radius: 1.2),
      ConveyorTurnEntry(position: 0.75, angle: -30, radius: 1.0),
    ];

/// One cell: the bounding box in blue, the belt painted inside it.
Widget _cell(String label, Size canvas) {
  final box = Size(_relW * canvas.width, _relH * canvas.height);
  final belt = _relBelt * canvas.height;
  final geometry =
      ConveyorPathGeometry.build(_uTurn(), box, beltWidthOverride: belt);
  return Padding(
    padding: const EdgeInsets.all(10),
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
              batches: const {},
              angle: 0,
              showFrequency: false,
              frequency: null,
              geometry: geometry,
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
  group('Conveyor turn fill',
      skip: goldenSkip, () {
    testWidgets('the same belt across window shapes', (tester) async {
      // Desktop, ultrawide, 4:3, square and portrait. The belt should read as
      // the same belt in all of them, filling its box in each.
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const canvases = <Size>[
        Size(1920, 1080),
        Size(2560, 1080),
        Size(3440, 1440),
        Size(1280, 1024),
        Size(1024, 768),
        Size(1024, 1400),
        Size(800, 1280),
        Size(1440, 1440),
      ];

      await tester.pumpWidget(_matrix([
        for (final c in canvases)
          _cell('${c.width.toInt()}x${c.height.toInt()}', c),
      ]));
      await expectLater(
        find.byKey(_key),
        matchesGoldenFile('goldens/conveyor_turn_fill_aspects.png'),
      );
    });

    testWidgets('the same window shape at five sizes', (tester) async {
      // All five are 16:9, so they configure the same box proportions and
      // the same belt-to-box ratio: the cells must differ only in scale.
      // 1600x900 used to come out a visibly different shape from the rest.
      tester.view.physicalSize = const Size(1400, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const canvases = <Size>[
        Size(960, 540),
        Size(1366, 768),
        Size(1600, 900),
        Size(1920, 1080),
        Size(3840, 2160),
      ];

      await tester.pumpWidget(_matrix([
        for (final c in canvases)
          _cell('${c.width.toInt()}x${c.height.toInt()}', c),
      ]));
      await expectLater(
        find.byKey(_key),
        matchesGoldenFile('goldens/conveyor_turn_fill_scales.png'),
      );
    });
  });
}

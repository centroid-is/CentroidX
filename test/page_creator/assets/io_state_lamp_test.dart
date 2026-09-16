import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/painter/beckhoff/io8.dart' show IOState;
import 'package:tfc/page_creator/assets/io_pane.dart';
import 'package:tfc/page_creator/assets/led.dart';
import 'package:tfc/theme.dart';

/// A lit digital channel is green whichever way the wire runs — the same
/// green EL9222 draws for "supplying load". Direction is the lamp's shape
/// (round in, square out), not its colour: yellow is manual mode in this
/// app, and an energised output is not manual.
void main() {
  Future<LEDPainter> lampPainter(
    WidgetTester tester, {
    required IOState state,
    required bool isOutput,
  }) async {
    final (light, _) = solarized();
    await tester.pumpWidget(MaterialApp(
      theme: light,
      home: Center(child: IoStateLamp(state: state, isOutput: isOutput)),
    ));
    return tester
        .widgetList<CustomPaint>(find.descendant(
          of: find.byType(IoStateLamp),
          matching: find.byType(CustomPaint),
        ))
        .map((p) => p.painter)
        .whereType<LEDPainter>()
        .single;
  }

  Color green(WidgetTester tester) =>
      HmiStateColors.of(tester.element(find.byType(IoStateLamp))).green;

  testWidgets('a high input is green and round', (tester) async {
    final painter =
        await lampPainter(tester, state: IOState.high, isOutput: false);
    expect(painter.color, green(tester));
    expect(painter.ledType, LEDType.circle);
  });

  testWidgets('a high output is the same green, and square', (tester) async {
    final painter =
        await lampPainter(tester, state: IOState.high, isOutput: true);
    expect(painter.color, green(tester));
    expect(painter.ledType, LEDType.square);
  });

  testWidgets('forced stays orange on an output', (tester) async {
    final painter =
        await lampPainter(tester, state: IOState.forcedHigh, isOutput: true);
    expect(painter.color, Colors.orange);
  });
}

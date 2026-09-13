import 'dart:io' show File, Platform;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show ByteData, FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/painter/schneider/atv320.dart';
import '../helpers/golden_platform.dart';

/// The painter draws the inline label in 'Courier', which flutter_test will
/// not resolve from the system — it would fall back to Ahem, whose glyphs are
/// featureless 1em squares, so the label goldens would show white blocks and
/// verify nothing about the text. Serve the bundled Roboto Mono under that
/// family name: it is monospace with the same 0.6em advance as Courier, so
/// the goldens also reflect how much label really fits across the body.
Future<void> _loadCourier() async {
  final bytes =
      await File('lib/fonts/roboto-mono/RobotoMono-Regular.ttf').readAsBytes();
  await (FontLoader('Courier')
        ..addFont(Future.value(ByteData.sublistView(bytes))))
      .load();
}

/// Records drawParagraph calls so the label-line layout can be asserted
/// without goldens (which only run on macOS).
class _ParagraphRecordingCanvas implements Canvas {
  final List<ui.Paragraph> paragraphs = [];
  final List<Offset> offsets = [];

  @override
  void drawParagraph(ui.Paragraph paragraph, Offset offset) {
    paragraphs.add(paragraph);
    offsets.add(offset);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(_loadCourier);

  group('ATV320 7-segment golden tests', skip: goldenSkip, () {
    Widget buildDisplay(
      String displayText, {
      String topLabel = '',
      double labelFontSize = ATV320.defaultLabelFontSize,
    }) {
      return MaterialApp(
        home: Scaffold(
          backgroundColor: const Color(0xFF2A2F2A),
          body: Center(
            child: SizedBox(
              width: 200,
              height: 600,
              child: ATV320Widget(
                name: 'ATV320',
                displayText: displayText,
                topLabel: topLabel,
                labelFontSize: labelFontSize,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('sto display', (tester) async {
      await tester.pumpWidget(buildDisplay('sto'));
      await expectLater(
        find.byType(ATV320Widget),
        matchesGoldenFile('goldens/atv320_sto.png'),
      );
    });

    testWidgets('STO uppercase display', (tester) async {
      await tester.pumpWidget(buildDisplay('STO'));
      await expectLater(
        find.byType(ATV320Widget),
        matchesGoldenFile('goldens/atv320_sto_upper.png'),
      );
    });

    testWidgets('cnf display', (tester) async {
      await tester.pumpWidget(buildDisplay('cnf'));
      await expectLater(
        find.byType(ATV320Widget),
        matchesGoldenFile('goldens/atv320_cnf.png'),
      );
    });

    testWidgets('CNF uppercase display', (tester) async {
      await tester.pumpWidget(buildDisplay('CNF'));
      await expectLater(
        find.byType(ATV320Widget),
        matchesGoldenFile('goldens/atv320_cnf_upper.png'),
      );
    });

    testWidgets('frequency display with decimal', (tester) async {
      await tester.pumpWidget(buildDisplay('50.0'));
      await expectLater(
        find.byType(ATV320Widget),
        matchesGoldenFile('goldens/atv320_freq.png'),
      );
    });

    testWidgets('display with top label', (tester) async {
      await tester.pumpWidget(buildDisplay('sto', topLabel: 'Line 1 Return'));
      await expectLater(
        find.byType(ATV320Widget),
        matchesGoldenFile('goldens/atv320_sto_label.png'),
      );
    });

    testWidgets('top label broken onto two lines with a newline',
        (tester) async {
      await tester.pumpWidget(buildDisplay('sto', topLabel: 'CN01\nFD01'));
      await expectLater(
        find.byType(ATV320Widget),
        matchesGoldenFile('goldens/atv320_sto_label_newline.png'),
      );
    });

    testWidgets('top label at a smaller configured size', (tester) async {
      await tester.pumpWidget(buildDisplay(
        'sto',
        topLabel: 'CN01\nFD01',
        labelFontSize: 12,
      ));
      await expectLater(
        find.byType(ATV320Widget),
        matchesGoldenFile('goldens/atv320_label_small.png'),
      );
    });

    testWidgets('top label at a larger configured size', (tester) async {
      await tester.pumpWidget(buildDisplay(
        'sto',
        topLabel: 'CN01\nFD01',
        labelFontSize: 32,
      ));
      await expectLater(
        find.byType(ATV320Widget),
        matchesGoldenFile('goldens/atv320_label_large.png'),
      );
    });

    testWidgets('single-line label at the maximum size clears the screen',
        (tester) async {
      await tester.pumpWidget(buildDisplay(
        'sto',
        topLabel: 'CN01',
        labelFontSize: ATV320.maxLabelFontSize,
      ));
      await expectLater(
        find.byType(ATV320Widget),
        matchesGoldenFile('goldens/atv320_label_max.png'),
      );
    });
  });

  group('ATV320.splitTopLabel', () {
    test('label without newline is unchanged (single line)', () {
      expect(ATV320.splitTopLabel('CN01.FD01'), ['CN01.FD01']);
    });

    test('single word longer than 14 chars still truncates with ellipsis',
        () {
      expect(
        ATV320.splitTopLabel('ABCDEFGHIJKLMNOP'),
        ['ABCDEFGHIJKLMN...'],
      );
    });

    test('space heuristic without newline is unchanged (two lines)', () {
      expect(
        ATV320.splitTopLabel('Line 1 Return'),
        ['Line 1 Return'],
      );
      expect(
        ATV320.splitTopLabel('Conveyor Drive Cabinet North'),
        ['Conveyor Drive', 'Cabinet North'],
      );
    });

    test('explicit newline splits into two stacked lines', () {
      expect(ATV320.splitTopLabel('CN01\nFD01'), ['CN01', 'FD01']);
    });

    test('explicit newline takes precedence over the space heuristic', () {
      expect(
        ATV320.splitTopLabel('CN01 north\nFD01 south'),
        ['CN01 north', 'FD01 south'],
      );
    });

    test('more than two explicit lines are capped with ellipsis on line 2',
        () {
      expect(ATV320.splitTopLabel('A\nB\nC'), ['A', 'B...']);
      expect(
        ATV320.splitTopLabel('CN01\nFD01 long tail line\nFD02'),
        ['CN01', 'FD01 long t...'],
      );
    });

    test('trailing newline alone does not create a second line', () {
      expect(ATV320.splitTopLabel('CN01\n'), ['CN01']);
      expect(ATV320.splitTopLabel('CN01\n\n'), ['CN01']);
    });

    test('a stray newline does not cost a multi-word label its second line',
        () {
      // The Label field is multiline now, so an operator editing an existing
      // label can easily leave a trailing newline behind. That must not
      // collapse the space heuristic into one truncated line.
      expect(
        ATV320.splitTopLabel('Conveyor Drive Cabinet North\n'),
        ATV320.splitTopLabel('Conveyor Drive Cabinet North'),
      );
      expect(
        ATV320.splitTopLabel('\nConveyor Drive Cabinet North'),
        ['Conveyor Drive', 'Cabinet North'],
      );
    });

    test('a label of nothing but newlines draws no lines', () {
      expect(ATV320.splitTopLabel('\n'), isEmpty);
      expect(ATV320.splitTopLabel('  \n \n'), isEmpty);
    });

    test('a first word wider than the line is still drawn, truncated', () {
      // Both lines come out empty in the space heuristic when word one does
      // not fit; the drive must not end up unlabelled.
      expect(
        ATV320.splitTopLabel('ABCDEFGHIJKLMNOP QRS'),
        ['ABCDEFGHIJKLMN...'],
      );
    });

    test('blank explicit lines are dropped', () {
      expect(ATV320.splitTopLabel('CN01\n\nFD01'), ['CN01', 'FD01']);
    });

    test('explicit lines longer than 14 chars are clipped', () {
      expect(
        ATV320.splitTopLabel('ABCDEFGHIJKLMNOP\nFD01'),
        ['ABCDEFGHIJKLMN...', 'FD01'],
      );
    });
  });

  group('ATV320.labelCharsPerLine', () {
    test('reproduces the historical budget at the default size', () {
      expect(
        ATV320.labelCharsPerLine(ATV320.defaultLabelFontSize),
        ATV320.maxLabelCharsPerLine,
      );
    });

    test('a bigger label fits fewer characters across the body', () {
      expect(ATV320.labelCharsPerLine(40), lessThan(ATV320.labelCharsPerLine(20)));
      expect(ATV320.labelCharsPerLine(20), lessThan(ATV320.labelCharsPerLine(10)));
    });

    test('never drops below room for a word plus its ellipsis', () {
      // Well past the configurable ceiling, so the "..." truncation below
      // cannot run off the end of the string.
      expect(ATV320.labelCharsPerLine(500), greaterThanOrEqualTo(4));
      expect(ATV320.splitTopLabel('CN01.FD01', fontSize: 500), isNotEmpty);
    });
  });

  group('ATV320.splitTopLabel honours the label size', () {
    test('a label that fits at the default size truncates when enlarged', () {
      // 13 characters: inside the 14-char budget at size 20, over it at 32.
      const label = 'CN01.FD01.LMP';
      expect(ATV320.splitTopLabel(label), [label]);
      expect(
        ATV320.splitTopLabel(label, fontSize: 32).single,
        endsWith('...'),
      );
    });

    test('a shrunken label fits what the default size would have truncated',
        () {
      const label = 'CN01.FD01.LAMP.A';
      expect(ATV320.splitTopLabel(label), ['CN01.FD01.LAMP...']);
      expect(ATV320.splitTopLabel(label, fontSize: 10), [label]);
    });

    test('the space heuristic packs more words per line when shrunk', () {
      expect(
        ATV320.splitTopLabel('Conveyor Drive Cabinet North'),
        ['Conveyor Drive', 'Cabinet North'],
      );
      expect(
        ATV320.splitTopLabel('Conveyor Drive Cabinet North', fontSize: 10),
        ['Conveyor Drive Cabinet North'],
      );
    });
  });

  group('ATV320 label painting', () {
    // Painter design space: 96 dpi over mm, before the fit-to-box transform.
    const double pxPerMm = 96.0 / 25.4;
    const Size size = Size(200, 600);

    _ParagraphRecordingCanvas paintWithLabel(String topLabel) {
      final canvas = _ParagraphRecordingCanvas();
      ATV320(name: 'ATV320', displayText: 'sto', topLabel: topLabel)
          .paint(canvas, size);
      return canvas;
    }

    // The painter always draws one paragraph for the ESC button; label
    // lines come on top of that.
    late final int baseParagraphs = paintWithLabel('').paragraphs.length;

    test('label with explicit newline paints two stacked lines', () {
      final canvas = paintWithLabel('CN01\nFD01');
      expect(canvas.paragraphs.length, baseParagraphs + 2);

      // Line 1 at 8mm from the top of the drive, line 2 at 15mm.
      final labelOffsets = canvas.offsets.take(2).toList();
      expect(labelOffsets[0].dy, moreOrLessEquals(8.0 * pxPerMm));
      expect(labelOffsets[1].dy, moreOrLessEquals(15.0 * pxPerMm));
    });

    test('label without newline paints a single line at 8mm', () {
      final canvas = paintWithLabel('CN01.FD01');
      expect(canvas.paragraphs.length, baseParagraphs + 1);
      expect(canvas.offsets.first.dy, moreOrLessEquals(8.0 * pxPerMm));
    });

    test('more than two explicit lines still paint only two', () {
      final canvas = paintWithLabel('CN01\nFD01\nFD02\nFD03');
      expect(canvas.paragraphs.length, baseParagraphs + 2);
    });

    _ParagraphRecordingCanvas paintWithSize(String topLabel, double fontSize) {
      final canvas = _ParagraphRecordingCanvas();
      ATV320(
        name: 'ATV320',
        displayText: 'sto',
        topLabel: topLabel,
        labelFontSize: fontSize,
      ).paint(canvas, size);
      return canvas;
    }

    test('the gap between the two lines scales with the label size', () {
      // Doubling the size doubles the 7mm gap, so an enlarged label does not
      // stack line two on top of line one.
      final canvas = paintWithSize('CN01\nFD01', 40);
      final labelOffsets = canvas.offsets.take(2).toList();
      expect(labelOffsets[0].dy, moreOrLessEquals(8.0 * pxPerMm));
      expect(labelOffsets[1].dy, moreOrLessEquals((8.0 + 14.0) * pxPerMm));
    });

    test('line one stays anchored at 8mm whatever the size', () {
      for (final fontSize in [
        ATV320.minLabelFontSize,
        ATV320.defaultLabelFontSize,
        ATV320.maxLabelFontSize,
      ]) {
        expect(
          paintWithSize('CN01', fontSize).offsets.first.dy,
          moreOrLessEquals(8.0 * pxPerMm),
          reason: 'at size $fontSize',
        );
      }
    });

    test('a larger label paints taller, wider text', () {
      final small = paintWithSize('CN01', 10).paragraphs.first;
      final large = paintWithSize('CN01', 30).paragraphs.first;
      expect(large.height, greaterThan(small.height));
      expect(large.longestLine, greaterThan(small.longestLine));
    });

    test('two lines at the maximum size still clear the LCD screen', () {
      // The screen starts 35.5mm down the body; the label must not run into
      // it, which is what caps the configurable size.
      final canvas = paintWithSize('CN01\nFD01', ATV320.maxLabelFontSize);
      final line2Bottom =
          canvas.offsets[1].dy + canvas.paragraphs[1].height;
      expect(line2Bottom, lessThan(35.5 * pxPerMm));
    });

  });

  group('ATV320 label width budget', () {
    // Containment cannot be asserted in pixels here: 'Courier' does not
    // resolve under flutter_test, so text lays out in Ahem's 1em-per-glyph
    // metrics rather than Courier's 0.6em. Assert the character budget the
    // painter actually sizes against instead.
    const double bodyWidthMm = 45.0;
    const double courierAdvanceEm = 0.6;

    test('a word-split label never exceeds the budget for its size', () {
      for (final fontSize in [
        ATV320.minLabelFontSize,
        ATV320.defaultLabelFontSize,
        ATV320.maxLabelFontSize,
      ]) {
        final budget = ATV320.labelCharsPerLine(fontSize);
        final lines = ATV320.splitTopLabel(
          'CONVEYOR DRIVE NORTH SIDE',
          fontSize: fontSize,
        );
        for (final line in lines) {
          // '...' marks a truncation the painter appends past the budget;
          // measure the label content it kept.
          final content =
              line.endsWith('...') ? line.substring(0, line.length - 3) : line;
          expect(
            content.length,
            lessThanOrEqualTo(budget),
            reason: 'line "$line" overruns the $budget-char budget '
                'at size $fontSize',
          );
        }
      }
    });

    test('the budget corresponds to the physical width of the drive body', () {
      for (final fontSize in [10.0, 20.0, 32.0, 40.0]) {
        final widthMm = ATV320.labelCharsPerLine(fontSize) *
            fontSize *
            courierAdvanceEm /
            (96.0 / 25.4);
        expect(widthMm, lessThanOrEqualTo(bodyWidthMm),
            reason: 'budget is wider than the body at size $fontSize');
      }
    });
  });
}

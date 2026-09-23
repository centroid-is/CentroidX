import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../beckhoff/hardware.dart' show paintRj45;

/// The drive body's design box, in millimetres.
///
/// [ATV320] fits this into whatever box it is given, so it is also the frame
/// [kAtv320PortAFace] and [kAtv320PortBFace] are fractions of.
const Size kAtv320DesignMm = Size(45.0, 215.0);

/// Where the EtherCAT option card's A socket — the one captioned "In" — is
/// drawn, as a fraction of [kAtv320DesignMm].
///
/// At the foot of the drive, which is where the option card's RJ45s are on the
/// hardware: a cable to an ATV320 comes up from underneath it, not across its
/// face.
///
/// Shared with `kAtv320Ports` rather than written down twice: a cable that
/// lands somewhere other than the socket on the drawing is the whole bug this
/// pair of constants exists to prevent.
const Offset kAtv320PortAFace = Offset(0.30, 0.92);

/// Where the option card's B socket — captioned "Out" — is drawn. See
/// [kAtv320PortAFace].
const Offset kAtv320PortBFace = Offset(0.70, 0.92);

/// Side of an option-card socket, in the drive's millimetres.
const double kAtv320SocketMm = 15.0;

/// Cap height of the In/Out caption above a socket, in the drive's
/// millimetres.
const double kAtv320LetterMm = 7.0;

/// Clearance between a caption and the socket below it, in millimetres.
const double kAtv320CaptionGapMm = 1.0;

class ATV320 extends CustomPainter {
  final double widthMm = kAtv320DesignMm.width;
  final double heightMm = kAtv320DesignMm.height;
  static const schneiderGreen = Color(0xFF009639);
  static const schneiderLogoGreen = Color(0xFF009E4D);
  static const atvBodyGrey = Color(0xFF383E42);

  final String name;
  final String displayText; // Add this field
  final String topLabel; // Add this field for the top label

  /// Point size of the inline label, in the painter's design space (mm at
  /// 96 dpi), so it is independent of how large the drive is drawn on screen.
  final double labelFontSize;
  final Color fillColor = atvBodyGrey;

  /// Draw the EtherCAT option card's two RJ45s, captioned A and B.
  ///
  /// Off by default, and deliberately not assumed: the sockets are on the
  /// VW3A3601 card, and a drive fitted with Modbus or nothing at all has a
  /// blank face there. The asset turns it on for a drive bound to a subdevice,
  /// which is the page saying the card is fitted.
  final bool showEtherCatPorts;

  ATV320({
    required this.name,
    this.displayText = 'ATV3',
    this.topLabel = '',
    this.labelFontSize = defaultLabelFontSize,
    this.showEtherCatPorts = false,
  }); // Add topLabel parameter

  /// Point size the inline label has always been drawn at, and the size the
  /// line budget and line spacing below are calibrated against.
  static const double defaultLabelFontSize = 20.0;

  /// Range the label size may be configured over. The floor keeps the label
  /// legible; the ceiling is where two stacked lines still clear the LCD
  /// screen, which starts 35.5mm down the body — line two lands at
  /// 8mm + 7mm x (size / 20) and is about 1.32em tall.
  static const double minLabelFontSize = 8.0;
  static const double maxLabelFontSize = 36.0;

  /// Maximum characters drawn per inline-label line at
  /// [defaultLabelFontSize]. See [labelCharsPerLine] for other sizes.
  static const int maxLabelCharsPerLine = 14;

  /// How many characters of label fit across the 45mm-wide drive body at
  /// [fontSize].
  ///
  /// Courier advances 0.6em per character, so the budget is simply how many
  /// of those fit the body width — which reproduces [maxLabelCharsPerLine] at
  /// [defaultLabelFontSize]. Without this the label would spill past the body
  /// as soon as the size was raised.
  static int labelCharsPerLine(double fontSize) {
    const double bodyWidthPx = 45.0 * (96.0 / 25.4);
    final int chars = (bodyWidthPx / (fontSize * 0.6)).floor();
    // Below four there is no room for a word plus its "..." ellipsis.
    return math.max(4, chars);
  }

  /// Splits [topLabel] into the (at most two) lines drawn on the drive body.
  ///
  /// Two or more non-blank lines separated by "\n" are honoured verbatim, so
  /// the operator can render "CN01\nFD01" as "CN01" over "FD01". More than two
  /// are capped at two, with an ellipsis on the second. Anything that does not
  /// yield two lines that way — including a label carrying only a stray or
  /// trailing newline — falls back to the historical behaviour: split on
  /// spaces into at most two lines of [labelCharsPerLine] characters,
  /// truncating with "..." on overflow.
  @visibleForTesting
  static List<String> splitTopLabel(
    String topLabel, {
    double fontSize = defaultLabelFontSize,
  }) {
    final int maxCharsPerLine = labelCharsPerLine(fontSize);

    String clip(String line) => line.length > maxCharsPerLine
        ? '${line.substring(0, maxCharsPerLine)}...'
        : line;

    // Truncate so that line + "..." still fits within the line budget.
    String ellipsise(String line) => line.length > maxCharsPerLine - 3
        ? '${line.substring(0, maxCharsPerLine - 3)}...'
        : '$line...';

    // Explicit newlines take precedence over the space-splitting heuristic.
    final explicitLines = topLabel
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    if (explicitLines.length > 1) {
      return [
        clip(explicitLines.first),
        // Capped at two lines: ellipsis on the second says more was dropped.
        explicitLines.length > 2
            ? ellipsise(explicitLines[1])
            : clip(explicitLines[1]),
      ];
    }

    // Only one line survived, so there is no operator line break to honour.
    // A trailing newline left behind by the multiline Label field must not
    // cost a multi-word label its second line, so run the heuristic on that
    // surviving line rather than on the raw label.
    final label = topLabel.contains('\n')
        ? (explicitLines.isEmpty ? '' : explicitLines.first)
        : topLabel;
    if (label.isEmpty) return const [];

    final words = label.trim().split(' ');
    if (words.length > 1) {
      // Split into 2 lines with character limit
      String line1 = '';
      String line2 = '';
      bool hasMoreWords = false; // Flag to track if there are more words

      for (final word in words) {
        if (line1.length + word.length + 1 <= maxCharsPerLine &&
            line2.isEmpty) {
          line1 += (line1.isEmpty ? '' : ' ') + word;
        } else if (line2.length + word.length + 1 <= maxCharsPerLine) {
          line2 += (line2.isEmpty ? '' : ' ') + word;
        } else {
          // Both lines are full, but we still have more words
          hasMoreWords = true;
          break;
        }
      }

      // Add "..." to lines that are truncated
      if (hasMoreWords && line2.isNotEmpty) {
        line2 = ellipsise(line2);
      }

      // A first word wider than the line budget leaves both lines empty; draw
      // it truncated rather than leaving the drive unlabelled.
      if (line1.isEmpty) return [clip(words.first)];

      return [line1, if (line2.isNotEmpty) line2];
    }

    // Single line - truncate if too long (kept untrimmed, as before).
    return [clip(label)];
  }

// Segment order: [top, top-right, bottom-right, bottom, bottom-left, top-left, middle]
  static const Map<String, List<bool>> sevenSegmentMap = {
    // Numbers
    '0': [true, true, true, true, true, true, false],
    '1': [false, true, true, false, false, false, false],
    '2': [true, true, false, true, true, false, true],
    '3': [true, true, true, true, false, false, true],
    '4': [false, true, true, false, false, true, true],
    '5': [true, false, true, true, false, true, true],
    '6': [true, false, true, true, true, true, true],
    '7': [true, true, true, false, false, false, false],
    '8': [true, true, true, true, true, true, true],
    '9': [true, true, true, true, false, true, true],

    // Symbols
    '-': [false, false, false, false, false, false, true],
    ' ': [false, false, false, false, false, false, false],

    // Uppercase letters that make sense on 7-seg
    'A': [true, true, true, false, true, true, true],
    'C': [true, false, false, true, true, true, false],
    'E': [true, false, false, true, true, true, true],
    'F': [true, false, false, false, true, true, true],
    'H': [false, true, true, false, true, true, true],
    'I': [false, true, true, false, false, false, false], // like "1"
    'J': [false, true, true, true, false, false, false],
    'L': [false, false, false, true, true, true, false],
    'O': [true, true, true, true, true, true, false], // same shape as "0"
    'P': [true, true, false, false, true, true, true],
    'S': [true, false, true, true, false, true, true],
    'U': [false, true, true, true, true, true, false],
    'Y': [false, true, true, true, false, true, true],
    'Z': [true, true, false, true, true, false, true],

    // Lowercase letters that make sense on 7-seg
    'a': [true, true, true, true, true, false, true],
    'b': [false, false, true, true, true, true, true],
    'c': [false, false, false, true, true, false, true],
    'd': [false, true, true, true, true, false, true],
    'e': [true, false, false, true, true, true, true],
    'f': [true, false, false, false, true, true, true],
    'h': [false, false, true, false, true, true, true],
    'i': [false, false, true, false, false, false, false],
    'j': [false, true, true, true, false, false, false],
    'l': [false, false, false, true, true, true, false],
    'n': [false, false, true, false, true, false, true],
    'o': [false, false, true, true, true, false, true],
    'p': [true, true, false, false, true, true, true],
    'q': [true, true, true, true, false, true, true],
    'r': [false, false, false, false, true, false, true],
    't': [false, false, false, true, true, true, true],
    'u': [false, false, true, true, true, false, false],
    'y': [false, true, true, true, false, true, true],
  };

  // Draw a single 7-segment character
  void _drawSevenSegment(
    Canvas canvas,
    String char,
    double x,
    double y,
    double width,
    double height,
  ) {
    final segments = sevenSegmentMap[char] ??
        sevenSegmentMap[char.toLowerCase()] ??
        sevenSegmentMap[char.toUpperCase()] ??
        sevenSegmentMap[' ']!;

    final segmentPaint = Paint()
      ..color = const Color(0xFF00FF00) // Green segments
      ..style = PaintingStyle.fill;

    final double segmentWidth = width * 0.1; // 10% of character width
    final double segmentHeight = height * 0.08; // 8% of character height
    final double horizontalSegmentWidth = width * 0.6; // 60% of character width
    final double verticalSegmentHeight =
        height * 0.4; // 40% of character height

    // Segment positions (7-segment layout):
    //    0
    //  5   1
    //    6
    //  4   2
    //    3

    // Top horizontal (0)
    if (segments[0]) {
      final rect = Rect.fromLTWH(
        x + (width - horizontalSegmentWidth) / 2,
        y,
        horizontalSegmentWidth,
        segmentHeight,
      );
      canvas.drawRect(rect, segmentPaint);
    }

    // Top right vertical (1)
    if (segments[1]) {
      final rect = Rect.fromLTWH(
        x + width - segmentWidth,
        y + segmentHeight,
        segmentWidth,
        verticalSegmentHeight,
      );
      canvas.drawRect(rect, segmentPaint);
    }

    // Bottom right vertical (2)
    if (segments[2]) {
      final rect = Rect.fromLTWH(
        x + width - segmentWidth,
        y + segmentHeight + verticalSegmentHeight + segmentHeight,
        segmentWidth,
        verticalSegmentHeight,
      );
      canvas.drawRect(rect, segmentPaint);
    }

    // Bottom horizontal (3)
    if (segments[3]) {
      final rect = Rect.fromLTWH(
        x + (width - horizontalSegmentWidth) / 2,
        y + height - segmentHeight,
        horizontalSegmentWidth,
        segmentHeight,
      );
      canvas.drawRect(rect, segmentPaint);
    }

    // Bottom left vertical (4)
    if (segments[4]) {
      final rect = Rect.fromLTWH(
        x,
        y + segmentHeight + verticalSegmentHeight + segmentHeight,
        segmentWidth,
        verticalSegmentHeight,
      );
      canvas.drawRect(rect, segmentPaint);
    }

    // Top left vertical (5)
    if (segments[5]) {
      final rect = Rect.fromLTWH(
        x,
        y + segmentHeight,
        segmentWidth,
        verticalSegmentHeight,
      );
      canvas.drawRect(rect, segmentPaint);
    }

    // Middle horizontal (6)
    if (segments[6]) {
      final rect = Rect.fromLTWH(
        x + (width - horizontalSegmentWidth) / 2,
        y + (height - segmentHeight) / 2,
        horizontalSegmentWidth,
        segmentHeight,
      );
      canvas.drawRect(rect, segmentPaint);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Base "design" pixels from mm (keeps all your geometry in a consistent design space).
    const double pxPerMm = 96.0 / 25.4;
    final double designW = widthMm * pxPerMm;
    final double designH = heightMm * pxPerMm;

    // Global fit-to-box transform
    final double gScale = math.min(size.width / designW, size.height / designH);
    final double dx = (size.width - designW * gScale) / 2.0;
    final double dy = (size.height - designH * gScale) / 2.0;

    canvas.save();
    canvas.translate(dx, dy);
    canvas.scale(gScale);

    // Strokes that remain ~1px visually
    final stroke = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0 / gScale;

    final backgroundFill = Paint()
      ..style = PaintingStyle.fill
      ..color = fillColor;

    // Design-space origin now at (0,0)
    const double left = 0.0;
    const double top = 0.0;
    final double widthPixels = designW;
    final double heightPixels = designH;

    // Add a small radius for rounded corners (about 2mm)
    final double radius = 2.0 * pxPerMm;

    // Create a path with rounded corners and curved top edge
    final path = Path();

    // Start from bottom-left (with rounded corner)
    path.moveTo(left + radius, top + heightPixels);

    // Draw bottom edge
    path.lineTo(left + widthPixels - radius, top + heightPixels);

    // Draw bottom-right rounded corner
    path.arcToPoint(
      Offset(left + widthPixels, top + heightPixels - radius),
      radius: Radius.circular(radius),
      clockwise: false,
    );

    // Draw right edge
    path.lineTo(left + widthPixels, top + radius);

    // Draw top-right rounded corner
    path.arcToPoint(
      Offset(left + widthPixels - radius, top),
      radius: Radius.circular(radius),
      clockwise: false,
    );

    // Draw curved top edge (slight curve down in the middle)
    final double curveDepth = -4.0 * pxPerMm;
    path.quadraticBezierTo(
      left + widthPixels / 2, // control point x (middle)
      top + curveDepth, // control point y (curved down)
      left + radius, // end point x (left edge + radius)
      top, // end point y (top)
    );

    // Draw top-left rounded corner
    path.arcToPoint(
      Offset(left, top + radius),
      radius: Radius.circular(radius),
      clockwise: false,
    );

    // Draw left edge
    path.lineTo(left, top + heightPixels - radius);

    // Draw bottom-left rounded corner
    path.arcToPoint(
      Offset(left + radius, top + heightPixels),
      radius: Radius.circular(radius),
      clockwise: false,
    );

    // Close the path
    path.close();

    // Draw the filled shape
    canvas.drawPath(path, backgroundFill);
    canvas.drawPath(path, stroke);

    // Add customizable label on top of the device
    if (topLabel.isNotEmpty) {
      final lines = splitTopLabel(topLabel, fontSize: labelFontSize);

      // 7mm apart at the default size; the gap tracks the size so raising it
      // does not stack the two lines on top of each other.
      final double lineGapMm = 7.0 * (labelFontSize / defaultLabelFontSize);

      for (int i = 0; i < lines.length; i++) {
        final linePainter = TextPainter(
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.center,
          text: TextSpan(
            text: lines[i],
            style: TextStyle(
              color: Colors.white,
              fontSize: labelFontSize,
              fontWeight: FontWeight.bold,
              fontFamily: 'Courier', // Monospace font
            ),
          ),
        );
        linePainter.layout();

        // Line 1 sits 8mm from the top of the drive, line 2 a gap below it.
        final double lineY = top + ((8.0 + (i == 0 ? 0.0 : lineGapMm)) * pxPerMm);
        final double lineX =
            left + (widthPixels / 2.0) - (linePainter.width / 2.0);
        linePainter.paint(canvas, Offset(lineX, lineY));
      }
    }

    // Add old-fashioned LCD screen
    final double screenWidth = 40.0 * pxPerMm; // 40mm wide
    final double screenHeight = 25.0 * pxPerMm; // 25mm tall
    final double screenTop = top +
        (48.0 * pxPerMm) -
        (screenHeight / 2.0); // 48mm from top, centered
    final double screenLeft = left +
        (widthPixels / 2.0) -
        (screenWidth / 2.0); // centered horizontally

    // LCD screen background (dark green/black typical of old LCDs)
    final lcdBackground = Paint()
      ..color = const Color(0xFF1A2F1A)
      ..style = PaintingStyle.fill;

    final lcdRect = Rect.fromLTWH(
      screenLeft,
      screenTop,
      screenWidth,
      screenHeight,
    );
    canvas.drawRect(lcdRect, lcdBackground);
    canvas.drawRect(lcdRect, stroke);

    // Draw 7-segment characters
    final int maxChars = 4;
    final double charWidth = screenWidth / maxChars;
    final double charHeight =
        screenHeight * 0.8; // Use 80% of screen height for characters
    final double charY = screenTop + (screenHeight - charHeight) / 2;

    // Add spacing between characters
    const double spacing = 4.0 * pxPerMm; // 4mm spacing between characters
    final double totalSpacing =
        spacing * (maxChars - 1); // Total spacing for all gaps
    final double availableWidth = screenWidth - totalSpacing;
    final double adjustedCharWidth = availableWidth / maxChars;

    // Find decimal point position and remove it from text
    int? decimalIndex;
    String textWithoutDot = displayText;
    if (displayText.contains('.')) {
      decimalIndex = displayText.indexOf('.');
      textWithoutDot = displayText.replaceAll('.', '');
    }

    // Take only first 4 characters (excluding the dot), pad with spaces if needed
    final String displayChars =
        textWithoutDot.padLeft(maxChars, ' ').substring(0, maxChars);

    // Draw characters from right to left for right alignment
    for (int i = 0; i < maxChars; i++) {
      final double charX = screenLeft + i * (adjustedCharWidth + spacing);
      _drawSevenSegment(
        canvas,
        displayChars[i],
        charX,
        charY,
        adjustedCharWidth,
        charHeight,
      );
    }

    // Draw decimal point at the correct position if it exists
    if (decimalIndex != null) {
      final dotPaint = Paint()
        ..color = const Color(0xFF00FF00) // Green dot
        ..style = PaintingStyle.fill;

      const double dotRadius = 1.0 * pxPerMm; // 1mm radius

      // Calculate dot position based on the actual decimal index
      // Adjust for the fact that we're showing maxChars characters
      final int adjustedIndex = decimalIndex.clamp(0, maxChars - 1);
      final double dotX = screenLeft +
          adjustedIndex * (adjustedCharWidth + spacing) +
          adjustedCharWidth +
          (spacing / 2); // Between characters

      final double dotY = screenTop +
          screenHeight -
          (4.0 * pxPerMm); // Positioned near bottom of screen

      canvas.drawCircle(Offset(dotX, dotY), dotRadius, dotPaint);
    }

    // Add circular ESC button on the right side, 5mm from edge
    final double buttonRadius = 4.0 * pxPerMm; // 4mm radius
    final double buttonCenterX = left +
        widthPixels -
        (3.0 * pxPerMm) -
        buttonRadius; // 5mm from right edge
    final double buttonCenterY =
        screenTop + screenHeight + (8.0 * pxPerMm); // 8mm below screen

    // Button background (slightly darker than device body)
    final buttonPaint = Paint()
      ..color = const Color(0xFF2A2F2A)
      ..style = PaintingStyle.fill;

    // Draw circular button
    final buttonCircle = Rect.fromCircle(
      center: Offset(buttonCenterX, buttonCenterY),
      radius: buttonRadius,
    );
    canvas.drawCircle(
      Offset(buttonCenterX, buttonCenterY),
      buttonRadius,
      buttonPaint,
    );
    canvas.drawCircle(
      Offset(buttonCenterX, buttonCenterY),
      buttonRadius,
      stroke,
    );

    // Add "ESC" text on the button
    final escTextPainter = TextPainter(
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
      text: const TextSpan(
        text: 'ESC',
        style: TextStyle(
          color: Colors.white,
          fontSize: 10.0,
          fontWeight: FontWeight.bold,
          fontFamily: 'Roboto',
        ),
      ),
    );
    escTextPainter.layout();

    final double escTextX = buttonCenterX - (escTextPainter.width / 2.0);
    final double escTextY = buttonCenterY - (escTextPainter.height / 2.0);
    escTextPainter.paint(canvas, Offset(escTextX, escTextY));

    // Add green LED above the screen on the left side (inside the device)
    final double ledRadius = 1.5 * pxPerMm; // 3mm diameter = 1.5mm radius
    final double ledCenterX =
        screenLeft + (3.0 * pxPerMm); // 8mm from left edge of screen
    final double ledCenterY = screenTop - (3.0 * pxPerMm); // 3mm above screen

    // LED background (bright green)
    final ledPaint = Paint()
      ..color = const Color(0xFF00FF00) // Bright green LED
      ..style = PaintingStyle.fill;

    // Draw LED circle
    canvas.drawCircle(Offset(ledCenterX, ledCenterY), ledRadius, ledPaint);
    canvas.drawCircle(Offset(ledCenterX, ledCenterY), ledRadius, stroke);

    // Add scroll wheel below the screen, centered
    final double wheelRadius = 12.0 * pxPerMm; // 20mm diameter = 10mm radius
    final double wheelCenterX =
        screenLeft + (screenWidth / 2.0); // Centered with screen
    final double wheelCenterY =
        screenTop + screenHeight + (20.0 * pxPerMm); // 25mm below screen

    // Wheel background (slightly darker than device body)
    final wheelPaint = Paint()
      ..color = schneiderGreen
      ..style = PaintingStyle.fill;

    // Draw main wheel circle
    canvas.drawCircle(
      Offset(wheelCenterX, wheelCenterY),
      wheelRadius,
      wheelPaint,
    );
    canvas.drawCircle(Offset(wheelCenterX, wheelCenterY), wheelRadius, stroke);

    // Draw 16 ticks around the wheel circumference
    final tickPaint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0 / gScale;

    final double tickLength = 2.0 * pxPerMm; // 2mm long ticks
    final double tickWidth = 0.5 * pxPerMm; // 0.5mm wide ticks

    for (int i = 0; i < 16; i++) {
      final double angle =
          (i * 2 * math.pi) / 16; // Evenly spaced around circle

      // Calculate tick start and end points
      final double tickStartX =
          wheelCenterX + (wheelRadius - tickLength) * math.cos(angle);
      final double tickStartY =
          wheelCenterY + (wheelRadius - tickLength) * math.sin(angle);
      final double tickEndX = wheelCenterX + wheelRadius * math.cos(angle);
      final double tickEndY = wheelCenterY + wheelRadius * math.sin(angle);

      // Draw tick line
      canvas.drawLine(
        Offset(tickStartX, tickStartY),
        Offset(tickEndX, tickEndY),
        tickPaint,
      );
    }

    // --- The EtherCAT option card's two RJ45s ---
    //
    // A bare ATV320 has no network sockets at all: they arrive on the
    // VW3A3601 card, which is why these are drawn only for a drive the page
    // has bound to a subdevice. The positions are [kAtv320PortAFace] and
    // [kAtv320PortBFace], the same fractions `kAtv320Ports` plugs a cable
    // into, so the socket an electrician sees is the socket the cable ends
    // on.
    if (showEtherCatPorts) {
      void socket(Offset face, String caption) {
        final double cx = left + widthPixels * face.dx;
        final double cy = top + heightPixels * face.dy;
        final double side = kAtv320SocketMm * pxPerMm;

        // Turned a quarter clockwise: the option card's sockets lie on their
        // side, so the cable leaves the drive sideways rather than straight
        // down out of the bottom edge.
        canvas.save();
        canvas.translate(cx, cy);
        canvas.rotate(math.pi / 2);
        paintRj45(
          canvas,
          Rect.fromCenter(center: Offset.zero, width: side, height: side),
          strokeScale: 1.0 / gScale,
        );
        canvas.restore();

        // "In" and "Out" rather than the PLC's A and B: the caption is read by
        // whoever is holding the cable, and in/out is what the chain means to
        // them. The letters are still the port ids the subdevice pane and the
        // CRC counters use, and `kAtv320Ports` keeps them.
        //
        // Above the socket, not below it, because the sockets sit at the foot
        // of the drive where the real ones are — a caption under them would be
        // hanging off the bottom edge of the body.
        final tp = TextPainter(
          text: TextSpan(
            text: caption,
            style: TextStyle(
              color: Colors.white,
              fontSize: kAtv320LetterMm * pxPerMm,
              fontWeight: FontWeight.bold,
              // Named, as the inline label is: a null family renders as the
              // test font's featureless boxes under `flutter test`, and a
              // golden of boxes pins nothing about which socket is which.
              fontFamily: 'Courier',
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(
          canvas,
          Offset(
            cx - tp.width / 2,
            cy - side / 2 - kAtv320CaptionGapMm * pxPerMm - tp.height,
          ),
        );
      }

      socket(kAtv320PortAFace, 'In');
      socket(kAtv320PortBFace, 'Out');
    }

    // Done
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant ATV320 old) {
    return name != old.name ||
        displayText != old.displayText ||
        topLabel != old.topLabel ||
        labelFontSize != old.labelFontSize ||
        showEtherCatPorts != old.showEtherCatPorts ||
        fillColor != old.fillColor;
  }
}

class ATV320Widget extends StatelessWidget {
  final String name;
  final String displayText; // Add this field
  final String topLabel; // Add this field

  /// Point size of the inline label. See [ATV320.labelFontSize].
  final double labelFontSize;

  /// Draw the option card's A and B sockets. See [ATV320.showEtherCatPorts].
  final bool showEtherCatPorts;

  const ATV320Widget({
    super.key,
    required this.name,
    this.displayText = 'ATV3',
    this.topLabel = '',
    this.labelFontSize = ATV320.defaultLabelFontSize,
    this.showEtherCatPorts = false,
  }); // Add topLabel parameter

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Handle infinite height by providing a reasonable default
        final height =
            constraints.maxHeight.isInfinite ? 400.0 : constraints.maxHeight;
        final width =
            constraints.maxWidth.isInfinite ? 200.0 : constraints.maxWidth;

        return SizedBox(
          width: width,
          height: height,
          child: CustomPaint(
            painter: ATV320(
              name: name,
              displayText: displayText,
              topLabel: topLabel,
              labelFontSize: labelFontSize,
              showEtherCatPorts: showEtherCatPorts,
            ),
          ),
        );
      },
    );
  }
}

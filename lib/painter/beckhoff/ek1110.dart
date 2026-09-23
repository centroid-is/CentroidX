/// Beckhoff EK1110 — the EtherCAT extension that ends a terminal block and
/// carries the bus on to the next one over RJ45.
///
/// Drawn at the same 1:6 aspect as [IO8Widget] so it lines up with the EL
/// terminals it sits beside in a rack row. The face carries what a 12 mm
/// extension actually has: two link LEDs, one RJ45, and the model name down
/// the bottom.
library;

import 'package:flutter/material.dart';

import 'ek1100.dart' show EthernetPortPainter;
import 'hardware.dart';
import 'io8.dart' show bodyColor, ioLabelColor, ledOffColor;

/// Whether the extension's outgoing segment is up, as far as the mimic knows.
///
/// The PLC publishes no process data for an EK1110 — nothing in the EtherCAT
/// GVL so much as names one — so this is [EK1110Link.unknown] on this plant
/// and the lamps stay dark. The parameter exists so a station that does link
/// the port status has somewhere to put it, rather than a lamp that lies.
enum EK1110Link { unknown, down, up }

/// The RJ45's width as a fraction of the terminal's, and how far down the face
/// its top edge sits. The painter draws with these; [kEk1110X1Face] is where
/// they put the socket's centre.
const double ek1110PortWidthFraction = 0.78;
const double ek1110PortTopFraction = 0.16;

/// Centre of the X1 socket, as a fraction of the terminal's 1:6 glyph.
///
/// Shared with `kEk1110Ports` rather than written down twice: a cable that
/// ends on the middle of the right-hand edge instead of on the RJ45 is the
/// bug this constant exists to prevent. The socket is square, so its height
/// on the face is [ek1110PortWidthFraction] of the *width* — a sixth of the
/// height — which is why the y here divides by six.
const Offset kEk1110X1Face = Offset(
  0.5,
  ek1110PortTopFraction + ek1110PortWidthFraction / 6 / 2,
);

class EK1110Painter extends CustomPainter {
  EK1110Painter({
    this.name = 'EK1110',
    this.markerLabel = '',
    this.link = EK1110Link.unknown,
    this.housingColor = bodyColor,
  });

  /// Printed above `BECKHOFF` at the foot of the terminal.
  final String name;

  /// The extension's configured name or id, worn as a marker tag on the
  /// terminal-marker band — the same tag an EL terminal beside it wears, at
  /// the same height, so a rack row reads as one row.
  ///
  /// Empty draws nothing and leaves the lamps where they were, so an unnamed
  /// EK1110 is the drawing it always was.
  final String markerLabel;

  final EK1110Link link;
  final Color housingColor;

  @override
  void paint(Canvas canvas, Size size) {
    final strokeWidth = size.width * 0.03;
    final stroke = Paint()
      ..color = Colors.grey.shade700
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;

    // Body — same rounded shell and cream as an EL terminal, so a rack reads
    // as one row of hardware rather than a drawing per part.
    final fillRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Radius.circular(size.width * 0.06),
    );
    canvas.drawRRect(
        fillRect, housingPaint(fillRect.outerRect, housingColor));
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, size.width - strokeWidth, size.height - strokeWidth),
        Radius.circular(size.width * 0.06),
      ),
      stroke,
    );

    final pad = size.width * 0.05;

    // The marker tag, when there is one, takes the band an EL terminal gives
    // it and the lamps drop below — the same order as an EL: markers on top,
    // then the lamp block.
    // Matches [IO8Painter]: the band is the height the marker strip is on the
    // hardware, named or not, so a rack row lines up across every device.
    final labelH = size.height * 0.06;
    final markerH = labelH;
    double lampTop = pad;
    if (markerLabel.isNotEmpty) {
      final rect = Rect.fromLTWH(pad, pad, size.width - pad * 2, markerH);
      paintMarkerTag(
        canvas,
        rect,
        markerLabel,
        color: ioLabelColor,
        strokeWidth: strokeWidth,
        minFontSize: labelH * 0.34,
      );
      lampTop = rect.bottom + pad * 0.6;
    }

    // Link lamps, side by side where the EL terminals put theirs.
    final lampH = size.height * 0.035;
    final lampW = (size.width - pad * 3) / 2;
    for (int i = 0; i < 2; i++) {
      final rect =
          Rect.fromLTWH(pad + i * (lampW + pad), lampTop, lampW, lampH);
      paintLed(
        canvas,
        RRect.fromRectAndRadius(rect, Radius.circular(lampH * 0.25)),
        color: _lampColor,
        lit: link == EK1110Link.up,
        strokeWidth: strokeWidth,
        border: stroke,
      );
    }

    // The RJ45, centred on the upper third — where it sits on the real part,
    // and where [kEk1110X1Face] plugs a cable in.
    final portSize = size.width * ek1110PortWidthFraction;
    final portLeft = (size.width - portSize) / 2;
    final portTop = size.height * ek1110PortTopFraction;
    canvas.save();
    canvas.translate(portLeft, portTop);
    canvas.scale(portSize / 100.0);
    EthernetPortPainter(strokeColor: Colors.black, strokeWidth: 1.0)
        .paint(canvas, const Size(100, 100));
    canvas.restore();

    // Bottom labels, laid out like [IO8Painter] so the type name sits at the
    // same height across a rack.
    final beckhoffH = size.height * 0.02;
    final nameH = size.height * 0.03;
    final beckhoffY = size.height - pad * 1.2 - beckhoffH;
    final nameY = beckhoffY - nameH + 1;

    void label(String text, double top, double height) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: Colors.black,
            fontSize: height,
            fontWeight: FontWeight.bold,
            // Named, as ek1100.dart names it: a null family renders as the
            // test font's boxes under `flutter test`, and a golden of boxes
            // pins nothing about a label.
            fontFamily: 'Roboto',
          ),
        ),
        textAlign: TextAlign.left,
        textDirection: TextDirection.ltr,
      )..layout(minWidth: size.width - pad * 2, maxWidth: size.width - pad * 2);
      tp.paint(canvas, Offset(pad, top + (height - tp.height) / 2));
    }

    label(name, nameY, nameH);
    label('BECKHOFF', beckhoffY, beckhoffH);
  }

  Color get _lampColor => switch (link) {
        EK1110Link.up => const Color(0xFF6CA545),
        EK1110Link.down => ledOffColor,
        EK1110Link.unknown => const Color(0xFF5C6462),
      };

  @override
  bool shouldRepaint(covariant EK1110Painter old) =>
      old.name != name ||
      old.markerLabel != markerLabel ||
      old.link != link ||
      old.housingColor != housingColor;
}

/// [EK1110Painter] at the 1:6 aspect a rack row expects.
class EK1110Widget extends StatelessWidget {
  const EK1110Widget({
    super.key,
    this.name = 'EK1110',
    this.markerLabel = '',
    this.link = EK1110Link.unknown,
    this.height = 300,
  });

  final String name;
  final String markerLabel;
  final EK1110Link link;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: height / 6,
      height: height,
      child: CustomPaint(
        painter: EK1110Painter(
          name: name,
          markerLabel: markerLabel,
          link: link,
        ),
      ),
    );
  }
}

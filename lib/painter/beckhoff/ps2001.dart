/// Beckhoff PS2001-2410 — the 1-phase 24 V DC / 10 A supply that feeds each
/// station's 24 V rail. ST301 alone has seven of them.
///
/// Unlike most of the infrastructure on these pages this one talks: the PLC
/// publishes an `ST_PS2001_2410` per unit (`SVNCoreComponents/ECT/
/// ST_PS2001_2410.TcDUT`) carrying DC OK, warning, error, input undervoltage
/// and the measured output volts and amps. So the face is driven, not drawn.
///
/// Geometry follows the PS2001-2410-1001 documentation, section "Front side
/// and operating elements": a 48 x 124 x 127 mm housing carrying the DC-OK
/// lamp, the output-voltage potentiometer and the EtherCAT X1 IN / X2 OUT
/// sockets.
///
/// The wiring is deliberately left off. The real front also has the mains
/// input (N, L, PE) at the top and the DC output (2 x +, 3 x -) at the foot,
/// and drawing them added five terminal blocks of detail that answer a
/// question nobody asks a mimic — an electrician landing a wire is standing
/// at the cabinet with the unit in front of them, not reading a screen. What
/// is left is what the page is for: the model, the tag, and the two lamps.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'ek1100.dart' show EthernetPortPainter;
import 'hardware.dart';
import 'io8.dart' show bodyColor, ledOffColor;

/// The front face in mm — the housing is 48 wide by 124 high.
const Size ps2001FaceMm = Size(48, 124);

/// Side of the two RJ45 sockets, in face millimetres.
const double ps2001SocketMm = 16;

/// Top-left of the X1 IN socket on the face, in millimetres.
const Offset ps2001X1Mm = Offset(6, 84);

/// Top-left of the X2 OUT socket on the face, in millimetres.
const Offset ps2001X2Mm = Offset(26, 84);

/// Centre of [at] as a fraction of [ps2001FaceMm] — where a cable plugs in.
///
/// Derived from the same millimetres the painter draws the socket at, so the
/// two cannot drift: a cable that lands beside the socket rather than on it is
/// exactly the mistake this shares its numbers to prevent.
Offset ps2001SocketFace(Offset at) => Offset(
      (at.dx + ps2001SocketMm / 2) / ps2001FaceMm.width,
      (at.dy + ps2001SocketMm / 2) / ps2001FaceMm.height,
    );

/// What the supply is doing, worst first. The order is the severity order:
/// [Ps2001FaceState.values] is compared on `index` when something needs the
/// worse of two.
enum Ps2001FaceState {
  /// The unit reports an error — overload hiccup, short circuit, or a
  /// thermal shutdown.
  faulted,

  /// The mains input is below the valid operating range. The output may
  /// still be up, but not for long.
  undervoltage,

  /// A non-critical condition: high temperature or high load. Still
  /// supplying.
  warning,

  /// Output voltage inside tolerance and nothing else flagged.
  healthy,

  /// DC OK is low with no warning or error — the rail is down but the unit
  /// is not complaining, which is what a supply looks like switched off.
  down,

  /// Nothing published yet, or no key configured.
  unknown,
}

class PS2001Painter extends CustomPainter {
  PS2001Painter({
    this.name = 'PS2001',
    this.state = Ps2001FaceState.unknown,
    this.dcOk,
    this.housingColor = bodyColor,
  });

  /// Printed under the wordmark. A page with seven of these wants the tag,
  /// not the model — `ST301.T1`.
  final String name;

  final Ps2001FaceState state;

  /// `p_stat_DC_OK` as the unit last reported it, or null when nothing has
  /// arrived. Carried separately from [state] because the two are genuinely
  /// independent: a supply can be flagging high temperature while its output
  /// is still inside tolerance, and collapsing that into one headline would
  /// put out a lamp that is really lit on the cabinet door.
  final bool? dcOk;

  final Color housingColor;

  @override
  void paint(Canvas canvas, Size size) {
    const design = ps2001FaceMm;
    final scale = math.min(
      size.width / design.width,
      size.height / design.height,
    );
    canvas.save();
    canvas.translate(
      (size.width - design.width * scale) / 2,
      (size.height - design.height * scale) / 2,
    );
    canvas.scale(scale);

    final stroke = Paint()
      ..color = Colors.grey.shade700
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.4;

    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, design.width, design.height),
      const Radius.circular(1.5),
    );
    paintHousing(canvas, body, color: housingColor, strokeWidth: 0.4);

    void text(
      String value,
      Offset at, {
      required double fontSize,
      Color color = Colors.black,
      double? width,
      TextAlign align = TextAlign.left,
    }) {
      final tp = TextPainter(
        text: TextSpan(
          text: value,
          style: TextStyle(
            color: color,
            fontSize: fontSize,
            fontWeight: FontWeight.bold,
            // Named, as ek1100.dart names it: a null family renders as the
            // test font's boxes under `flutter test`, and a golden of boxes
            // pins nothing about a label.
            fontFamily: 'Roboto',
          ),
        ),
        textAlign: align,
        textDirection: TextDirection.ltr,
      )..layout(minWidth: width ?? 0, maxWidth: width ?? double.infinity);
      tp.paint(canvas, at);
    }

    // Three groups spread down the 124 mm face — identity, lamps, ports —
    // rather than crowded under the top edge where the mains terminals used
    // to hold them.

    // --- Wordmark ---
    text('BECKHOFF', const Offset(4, 18),
        fontSize: 5, color: const Color(0xFFE30613));
    text(name, const Offset(4, 25), fontSize: 4);

    // --- (D) DC-OK LED, and the mimic's own fault lamp beside it ---
    void lamp(Offset at, String label, Color color, {required bool lit}) {
      final rect = Rect.fromLTWH(at.dx, at.dy, 5, 3.2);
      paintLed(
        canvas,
        RRect.fromRectAndRadius(rect, const Radius.circular(0.6)),
        color: color,
        lit: lit,
        strokeWidth: 0.4,
        border: stroke,
      );
      text(label, Offset(at.dx + 6.2, at.dy - 0.4), fontSize: 3.2);
    }

    lamp(const Offset(4, 52), 'DC OK', _dcOkColor, lit: dcOk == true);
    lamp(
      const Offset(4, 60),
      'FAULT',
      _faultColor,
      lit: state == Ps2001FaceState.faulted ||
          state == Ps2001FaceState.undervoltage ||
          state == Ps2001FaceState.warning,
    );

    // --- (C) Output voltage potentiometer, factory set to 24.1 V ---
    // A trimmer sunk into the front, with the slot cut into its head — the
    // flat disc with a line across it read as a minus sign rather than a
    // screwdriver adjustment.
    const potCentre = Offset(38, 57);
    const potBounds = Rect.fromLTRB(32.5, 51.5, 43.5, 62.5);
    canvas.drawCircle(
      potCentre,
      5.5,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF9A9A9A), Color(0xFFE2E2E2)],
        ).createShader(potBounds),
    );
    canvas.drawCircle(potCentre, 5.5, stroke);
    canvas.drawCircle(
      potCentre,
      4.0,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF0EFEA), Color(0xFFB8B6AE)],
        ).createShader(potBounds),
    );
    canvas.drawCircle(potCentre, 4.0, stroke);
    canvas.drawRect(
      Rect.fromCenter(center: potCentre, width: 6.4, height: 1.1),
      Paint()..color = const Color(0xFF3A3A3A),
    );

    // --- (E)/(F) EtherCAT X1 IN and X2 OUT ---
    void port(Offset at, String label) {
      const socket = ps2001SocketMm;
      canvas.save();
      canvas.translate(at.dx, at.dy);
      canvas.scale(socket / 100.0);
      EthernetPortPainter(strokeColor: Colors.black, strokeWidth: 1.0)
          .paint(canvas, const Size(100, 100));
      canvas.restore();
      text(
        label,
        Offset(at.dx - 2, at.dy + socket),
        fontSize: 3.2,
        width: socket + 4,
        align: TextAlign.center,
      );
    }

    port(ps2001X1Mm, 'X1 IN');
    port(ps2001X2Mm, 'X2 OUT');

    canvas.restore();
  }

  /// The DC-OK lamp is the one an electrician looks at first, so it shows
  /// exactly what the lamp on the housing shows and nothing more: lit while
  /// the output is above the DC OK threshold, dark below it, and a flat grey
  /// while nothing has been published.
  Color get _dcOkColor => switch (dcOk) {
        true => const Color(0xFF6CA545),
        false => ledOffColor,
        null => const Color(0xFF5C6462),
      };

  /// The mimic's own addition, in the place the real housing puts its
  /// EtherCAT RUN lamp.
  ///
  /// Substituted rather than reproduced because the PLC publishes no EtherCAT
  /// state for this unit, and a lamp captioned RUN that is really showing
  /// something else is worse than no lamp. What the struct does carry is why
  /// an electrician would walk over here: a supply in hiccup mode, running
  /// hot, or fed by a sagging mains.
  /// Dark unless the unit is complaining. A lamp captioned FAULT that glows
  /// green on a healthy supply is the kind of thing an electrician learns to
  /// stop reading; amber for "still supplying but complaining", red for
  /// "stopped", and nothing at all the rest of the time.
  Color get _faultColor => switch (state) {
        Ps2001FaceState.faulted => Colors.red,
        Ps2001FaceState.undervoltage ||
        Ps2001FaceState.warning =>
          const Color(0xFFE0A800),
        Ps2001FaceState.healthy || Ps2001FaceState.down => ledOffColor,
        Ps2001FaceState.unknown => const Color(0xFF5C6462),
      };

  @override
  bool shouldRepaint(covariant PS2001Painter old) =>
      old.name != name ||
      old.state != state ||
      old.dcOk != dcOk ||
      old.housingColor != housingColor;
}

/// [PS2001Painter] at the housing's own aspect.
class PS2001Widget extends StatelessWidget {
  const PS2001Widget({
    super.key,
    this.name = 'PS2001',
    this.state = Ps2001FaceState.unknown,
    this.dcOk,
    this.height = 300,
  });

  final String name;
  final Ps2001FaceState state;
  final bool? dcOk;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: height * ps2001FaceMm.width / ps2001FaceMm.height,
      height: height,
      child: CustomPaint(
        painter: PS2001Painter(name: name, state: state, dcOk: dcOk),
      ),
    );
  }
}

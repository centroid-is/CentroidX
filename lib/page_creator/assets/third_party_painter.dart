import 'dart:math' show pi;

import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// Third-party equipment painters — one CustomPainter per equipment kind.
//
// Each paints a SIMPLIFIED PLAN VIEW (looking straight down) of a machine we
// do not control, drawn from the manufacturer's own photos and spec sheets so
// an operator recognises which box on the line they are looking at. They are
// hand-authored in normalised unit coordinates rather than exported from CAD
// (contrast `widgets/baader.dart`, a real DXF export) — we have no drawings
// for third-party gear.
//
// Sources for the geometry, per kind:
//   Multivac      R 245 spec sheet + machine photo — 5437 x 1002 mm,
//                 320 mm nominal web width, 280 mm max forming width,
//                 ~330 mm cross-cut zone, 800 mm discharge belt.
//   SpeedBatcher  Jón's sketch of the station as actually built on this line
//                 (buffers, infeed flat + step-up conveyors, two
//                 checkweighers) — NOT the Marel brochure, whose batcher head
//                 is a guarded cube with nothing visible from above.
//   Box erector   generic RSC erector (Eastey ERX-15 class) — 2395 x 2083 mm,
//                 side-loading blank magazine, 8-cup vacuum pick, flap
//                 folders, bottom centre-seal tape head, side-belt discharge.
//   Strapping     Afak SL-15-3 with StrapX heads — 2665 x 1815 mm, three
//                 arches in series over one belt, three coil dispensers on a
//                 rear gantry, ~530 mm boxes at 15/min.
//   Palletiser    Optimar drawing 10-N1230-1, "Foundation Requirements for
//                 Robots Ph-1 / Robotic Palletizing Stations for white boxes"
//                 (abuana, 28/04/2026, 1:50 on A2). A FOUNDATION drawing, so
//                 the floor plan is exact and nothing above knee height is on
//                 it: stations on a 3500 mm pitch (robot centres 5210 / 8710 /
//                 12210), ~3.9 m pallet lane each, Ø1800 pad carrying a Ø1250
//                 base plate on a Ø1110 bolt circle, 8 x M20 chemical anchors,
//                 2250 kg per robot and double-door cabinets. The drawing's
//                 transfer rail and pallet magazine are not drawn — they are
//                 hall-wide and sit outside the guarding this asset shows.
//
// Painters are PURE — primitives in, pixels out. ZERO subscriptions, ZERO
// Riverpod, ZERO state. Same contract as `sensor_painter.dart`.
//
// Every painter draws the SAME dotted boundary box (the "not our scope of
// supply" marker, and the tap-target hint) and then its own machine glyph
// inside [thirdPartyMachineArea]. The run-status LED is NOT painted here — it
// is a real `LEDPainter` composited over the top-left header strip by the
// widget in `third_party.dart`, so it looks identical to every other LED on
// the page.
//
// Detail is drawn at the configured stroke width, NOT scaled with the asset,
// so a small asset degrades into a legible silhouette rather than a grey
// smudge. These layouts reward being placed at their true aspect ratio — see
// `ThirdPartyEquipmentKind.aspectRatio` in `third_party.dart`.
// ---------------------------------------------------------------------------

/// Dotted-boundary "on" segment length (absolute pixels).
const double kBoundaryDashOnPx = 5.0;

/// Dotted-boundary "off" segment length (absolute pixels).
const double kBoundaryDashOffPx = 4.0;

/// Corner radius of the dotted boundary box (x shortestSide).
const double kBoundaryRadiusFraction = 0.06;

/// Opacity applied to the machine colour when drawing the dotted boundary, so
/// the boundary reads as chrome rather than as part of the machine.
const double kBoundaryAlpha = 0.55;

/// Opacity for secondary detail (rollers, flights, chains, cavity grids) so
/// the machine's primary silhouette still dominates at a glance.
const double kDetailAlpha = 0.65;

/// Run-status LED diameter (x shortestSide), clamped to a legible range.
const double kLedDiameterFraction = 0.18;

/// Gap between the dotted boundary and the LED (x shortestSide).
const double kLedInsetFraction = 0.05;

/// Boundary inset from the asset rect (x shortestSide). Keeps the dashes fully
/// inside the layout box so they are not clipped by a tight parent.
const double kBoundaryInsetFraction = 0.03;

/// Padding between the dotted boundary and the machine glyph (x shortestSide).
const double kMachinePadFraction = 0.05;

/// Diameter of the run-status LED for an asset of [size].
double thirdPartyLedDiameter(Size size) =>
    (size.shortestSide * kLedDiameterFraction).clamp(8.0, 26.0);

/// Offset of the LED from the top-left corner of the dotted boundary.
double thirdPartyLedInset(Size size) => size.shortestSide * kLedInsetFraction;

/// The dotted boundary rect for an asset of [size].
Rect thirdPartyBoundaryRect(Size size) {
  final inset = size.shortestSide * kBoundaryInsetFraction;
  return Rect.fromLTRB(inset, inset, size.width - inset, size.height - inset);
}

/// The rect the machine glyph is drawn into.
///
/// The top edge is pushed down by a header strip tall enough to clear the
/// run-status LED, so the LED never lands on top of the machine drawing no
/// matter which kind is selected.
Rect thirdPartyMachineArea(Size size) {
  final boundary = thirdPartyBoundaryRect(size);
  final pad = size.shortestSide * kMachinePadFraction;
  final header = thirdPartyLedInset(size) * 2 + thirdPartyLedDiameter(size);
  final rect = Rect.fromLTRB(
    boundary.left + pad,
    boundary.top + header,
    boundary.right - pad,
    boundary.bottom - pad,
  );
  // Degenerate guard: a very small asset rect can invert the header push.
  if (rect.width <= 0 || rect.height <= 0) return boundary;
  return rect;
}

// ---------------------------------------------------------------------------
// Unit-space helper
// ---------------------------------------------------------------------------

/// Maps normalised `0..1` machine coordinates onto a device-pixel [Rect].
///
/// Machine layouts are authored in unit space — `x` runs along the machine in
/// the direction of product flow (left to right for every kind here), `y` runs
/// across its depth, rear at `0` — so they read the same at any asset size.
///
/// Mapping happens here rather than via `canvas.scale` on purpose: a
/// non-uniform `scale` stretches stroke widths differently on the two axes,
/// and these machines are drawn in wide, non-square boxes.
class UnitSpace {
  const UnitSpace(this.area);

  /// Device-pixel rect that unit `(0,0)..(1,1)` maps onto.
  final Rect area;

  double get shortest => area.shortestSide;

  Offset p(double ux, double uy) =>
      Offset(area.left + ux * area.width, area.top + uy * area.height);

  Rect r(double ul, double ut, double ur, double ub) =>
      Rect.fromPoints(p(ul, ut), p(ur, ub));

  RRect rr(double ul, double ut, double ur, double ub, double radius) =>
      RRect.fromRectAndRadius(
          r(ul, ut, ur, ub), Radius.circular(shortest * radius));

  /// Radius in device pixels from a fraction of the shortest side, so circles
  /// stay circular in a stretched box.
  double rad(double f) => shortest * f;
}

// ---------------------------------------------------------------------------
// Base painter — dotted boundary + per-kind machine glyph
// ---------------------------------------------------------------------------

/// Shared base for the third-party equipment glyphs.
///
/// Subclasses implement [paintMachine] only; the dotted boundary is painted
/// here so every kind carries the same "third-party, tap me" affordance.
abstract class ThirdPartyMachinePainter extends CustomPainter {
  const ThirdPartyMachinePainter({
    required this.color,
    required this.strokeWidth,
    this.mirrorX = false,
    this.mirrorY = false,
  });

  /// Outline colour of the machine drawing. The dotted boundary and the
  /// secondary detail are drawn in the same colour at reduced opacity.
  final Color color;

  /// Outline stroke width in logical pixels.
  final double strokeWidth;

  /// Flip the machine drawing left-to-right.
  ///
  /// Every kind here is CHIRAL — the Multivac's film unwind is at one end, the
  /// palletiser's robot stands on one side of its lane, the strapper's cabinet
  /// is at the discharge end. A hall that runs the other way needs the glyph
  /// to run the other way too, and rotating 180° is not the same thing: that
  /// turns the machine upside down as well, which puts a cabinet at the front
  /// and a discharge at the back.
  ///
  /// Applied to the machine glyph ONLY. The dotted boundary is symmetric so it
  /// makes no difference, and the run LED is composited by the widget, not
  /// painted here, so it stays in the corner an operator looks for it in.
  final bool mirrorX;

  /// Flip the machine drawing front-to-back. See [mirrorX].
  final bool mirrorY;

  /// Draws the machine glyph in unit space [u].
  ///
  /// [stroke] is the primary outline paint; [detail] is the same colour at
  /// [kDetailAlpha] and a thinner width, for rollers, chains and grids.
  void paintMachine(Canvas canvas, UnitSpace u, Paint stroke, Paint detail);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    _paintBoundary(canvas, size);

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;

    final detail = Paint()
      ..color = color.withValues(alpha: kDetailAlpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth * 0.6
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;

    final area = thirdPartyMachineArea(size);
    final flipped = mirrorX || mirrorY;
    if (flipped) {
      // Flip about the machine area's own centre, so a mirrored glyph still
      // fills the same rect rather than sliding out of the boundary.
      canvas.save();
      canvas.translate(area.center.dx, area.center.dy);
      canvas.scale(mirrorX ? -1.0 : 1.0, mirrorY ? -1.0 : 1.0);
      canvas.translate(-area.center.dx, -area.center.dy);
    }
    paintMachine(canvas, UnitSpace(area), stroke, detail);
    if (flipped) canvas.restore();
  }

  void _paintBoundary(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: kBoundaryAlpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    final rrect = RRect.fromRectAndRadius(
      thirdPartyBoundaryRect(size),
      Radius.circular(size.shortestSide * kBoundaryRadiusFraction),
    );
    _drawDashedPath(canvas, Path()..addRRect(rrect), paint);
  }

  @override
  bool shouldRepaint(covariant ThirdPartyMachinePainter oldDelegate) =>
      oldDelegate.runtimeType != runtimeType ||
      oldDelegate.color != color ||
      oldDelegate.strokeWidth != strokeWidth ||
      oldDelegate.mirrorX != mirrorX ||
      oldDelegate.mirrorY != mirrorY;
}

/// Walks [path] with a `PathMetric` and emits alternating on/off segments.
///
/// Works for any path — the boundary is a rounded rect, so a per-edge line
/// dasher would drop the corner arcs.
void _drawDashedPath(Canvas canvas, Path path, Paint paint) {
  for (final metric in path.computeMetrics()) {
    double distance = 0;
    bool on = true;
    while (distance < metric.length) {
      final len = on ? kBoundaryDashOnPx : kBoundaryDashOffPx;
      final next = (distance + len).clamp(0.0, metric.length);
      if (on) {
        canvas.drawPath(metric.extractPath(distance, next), paint);
      }
      distance = next;
      on = !on;
    }
  }
}

// ---------------------------------------------------------------------------
// Shared plan-view idioms
// ---------------------------------------------------------------------------

/// `count` evenly spaced ticks ACROSS the flow direction — plan-view shorthand
/// for conveyor rollers, chain links, belt flights, or a stack of blanks.
void _crossTicks(
  Canvas canvas,
  UnitSpace u,
  Paint paint, {
  required double ul,
  required double ur,
  required double ut,
  required double ub,
  required int count,
}) {
  if (count <= 0) return;
  final step = (ur - ul) / (count + 1);
  for (int i = 1; i <= count; i++) {
    final x = ul + step * i;
    canvas.drawLine(u.p(x, ut), u.p(x, ub), paint);
  }
}

/// `count` evenly spaced ticks ALONG the flow direction — the transverse
/// counterpart of [_crossTicks], for machines drawn portrait (rollers and
/// cleats on a lane running up the page).
void _lengthwiseTicks(
  Canvas canvas,
  UnitSpace u,
  Paint paint, {
  required double ul,
  required double ur,
  required double ut,
  required double ub,
  required int count,
}) {
  if (count <= 0) return;
  final step = (ub - ut) / (count + 1);
  for (int i = 1; i <= count; i++) {
    final y = ut + step * i;
    canvas.drawLine(u.p(ul, y), u.p(ur, y), paint);
  }
}

/// Three flow chevrons down a lane, pointing up or down the page.
///
/// Drawn at full stroke: on a machine with two parallel lanes running in
/// OPPOSITE directions, direction is the one thing the boxes cannot tell you.
void _chevrons(
  Canvas canvas,
  UnitSpace u,
  Paint paint, {
  required double cx,
  required double top,
  required double bottom,
  required bool pointingDown,
  int count = 3,
}) {
  const halfWidth = 0.055;
  final span = bottom - top;
  final height = span / (count * 1.8);
  for (int i = 0; i < count; i++) {
    final base = top + span * (i + 0.5) / count - height / 2;
    final tip = pointingDown ? base + height : base;
    final tail = pointingDown ? base : base + height;
    final path = Path()
      ..moveTo(u.p(cx - halfWidth, tail).dx, u.p(cx - halfWidth, tail).dy)
      ..lineTo(u.p(cx, tip).dx, u.p(cx, tip).dy)
      ..lineTo(u.p(cx + halfWidth, tail).dx, u.p(cx + halfWidth, tail).dy);
    canvas.drawPath(path, paint);
  }
}

/// Fraction of a cell [_cavityGrid] leaves as a gap between cells — the web
/// between thermoforming cavities, and the air between cases on a pallet.
///
/// Shared rather than local so a painter that has to line something up with a
/// cell (the case the palletiser is setting down) computes the same rect the
/// grid drew.
const double kCavityGapFraction = 0.22;

/// A `rows x cols` grid of small rounded cells — plan-view shorthand for the
/// cavities in a thermoforming tool, or for a layer of cases on a pallet.
void _cavityGrid(
  Canvas canvas,
  UnitSpace u,
  Paint paint, {
  required double ul,
  required double ut,
  required double ur,
  required double ub,
  required int rows,
  required int cols,
}) {
  const gap = kCavityGapFraction;
  final cellW = (ur - ul) / cols;
  final cellH = (ub - ut) / rows;
  for (int row = 0; row < rows; row++) {
    for (int col = 0; col < cols; col++) {
      final l = ul + cellW * (col + gap / 2);
      final t = ut + cellH * (row + gap / 2);
      canvas.drawRRect(
        u.rr(l, t, l + cellW * (1 - gap), t + cellH * (1 - gap), 0.015),
        paint,
      );
    }
  }
}

/// A film reel whose axis runs ACROSS the machine.
///
/// Seen from directly above, such a reel is a rectangle (the roll's
/// cylindrical face), not a circle — the giveaway is the mandrel shaft poking
/// out past both flanges, which is what this draws.
void _transverseReel(
  Canvas canvas,
  UnitSpace u,
  Paint stroke,
  Paint detail, {
  required double cx,
  required double cy,
  required double halfLen,
  required double halfWidth,
}) {
  canvas.drawRect(
      u.r(cx - halfLen, cy - halfWidth, cx + halfLen, cy + halfWidth), stroke);
  // Mandrel shaft, protruding past both flanges.
  canvas.drawLine(
      u.p(cx, cy - halfWidth * 1.4), u.p(cx, cy + halfWidth * 1.4), detail);
  // Flange edges.
  canvas.drawLine(u.p(cx - halfLen * 0.55, cy - halfWidth),
      u.p(cx - halfLen * 0.55, cy + halfWidth), detail);
  canvas.drawLine(u.p(cx + halfLen * 0.55, cy - halfWidth),
      u.p(cx + halfLen * 0.55, cy + halfWidth), detail);
}

// ---------------------------------------------------------------------------
// Multivac — R 245 class thermoforming packaging machine
// ---------------------------------------------------------------------------

/// Plan view of a Multivac thermoformer, product flowing left to right.
///
/// Station order follows the R-series web path: lower film unwind, forming
/// station, loading area (the long open stretch where product is placed into
/// the formed pockets), upper film unwind, sealing station, cross cutter,
/// longitudinal rotary knives, discharge belt. The two transport chains run
/// the full length down either side of the web.
///
/// True footprint is ~5437 x 1002 mm — a very long, narrow machine. Place the
/// asset near that aspect ratio or the stations bunch up.
class MultivacPainter extends ThirdPartyMachinePainter {
  const MultivacPainter({
    required super.color,
    required super.strokeWidth,
    super.mirrorX,
    super.mirrorY,
  });

  @override
  void paintMachine(Canvas canvas, UnitSpace u, Paint stroke, Paint detail) {
    // Main frame, from the unwind end to the start of the discharge belt.
    canvas.drawRRect(u.rr(0.0, 0.14, 0.88, 0.86, 0.03), stroke);

    // Transport chains — two rails carrying the web the whole length. They run
    // just inside the tool footprints and just outside the cavities, which is
    // where they sit on the real machine (they grip the web edges).
    canvas.drawLine(u.p(0.10, 0.245), u.p(0.86, 0.245), detail);
    canvas.drawLine(u.p(0.10, 0.755), u.p(0.86, 0.755), detail);

    // Lower film unwind at the infeed end.
    _transverseReel(canvas, u, stroke, detail,
        cx: 0.05, cy: 0.50, halfLen: 0.035, halfWidth: 0.24);

    // Forming station tool and its cavities.
    canvas.drawRect(u.r(0.13, 0.18, 0.29, 0.82), stroke);
    _cavityGrid(canvas, u, detail,
        ul: 0.145, ut: 0.30, ur: 0.275, ub: 0.70, rows: 2, cols: 2);

    // Loading area — formed pockets travelling open through the long stretch
    // where product is placed. Same cavity pitch as the forming tool.
    _cavityGrid(canvas, u, detail,
        ul: 0.31, ut: 0.30, ur: 0.55, ub: 0.70, rows: 2, cols: 4);

    // Upper film unwind, mounted at the rear just ahead of the sealing
    // station, with its feed line down onto the web.
    _transverseReel(canvas, u, stroke, detail,
        cx: 0.50, cy: 0.05, halfLen: 0.03, halfWidth: 0.045);
    canvas.drawLine(u.p(0.53, 0.05), u.p(0.60, 0.18), detail);

    // Sealing station tool and the sealed packs under it.
    canvas.drawRect(u.r(0.58, 0.18, 0.72, 0.82), stroke);
    _cavityGrid(canvas, u, detail,
        ul: 0.593, ut: 0.30, ur: 0.707, ub: 0.70, rows: 2, cols: 2);

    // Cross cutter — a narrow band across the full web width.
    canvas.drawRect(u.r(0.755, 0.16, 0.80, 0.84), stroke);

    // Longitudinal rotary knives, slitting the web between the pack lanes and
    // trimming both edges. They sit in the short run between the cross cutter
    // and the discharge, at full stroke — crossing them over the cross-cutter
    // band just reads as a smudge.
    for (final y in [0.30, 0.50, 0.70]) {
      canvas.drawLine(u.p(0.81, y), u.p(0.87, y), stroke);
    }

    // Discharge belt with rollers.
    canvas.drawRect(u.r(0.88, 0.30, 1.0, 0.70), stroke);
    _crossTicks(canvas, u, detail,
        ul: 0.88, ur: 1.0, ut: 0.30, ub: 0.70, count: 3);

    // Control cabinet along the rear, beside the sealing station, with the
    // signal light column on its corner.
    canvas.drawRect(u.r(0.58, 0.0, 0.76, 0.13), stroke);
    canvas.drawCircle(u.p(0.79, 0.06), u.rad(0.035), detail);
  }
}

// ---------------------------------------------------------------------------
// SpeedBatcher station
// ---------------------------------------------------------------------------

/// Plan view of the SpeedBatcher station as it is actually built on this line.
///
/// Drawn from Jón's sketch of the real installation, NOT from a Marel
/// brochure. The published SpeedBatcher literature shows the batcher head on
/// its own — a cube on legs whose weigh hoppers and selection bins are all
/// under the guarding and invisible from above. What an operator looking down
/// at this station actually sees is the conveyor-and-checkweigher layout
/// below, so that is what gets drawn.
///
/// This one is PORTRAIT: product runs up the page, not left to right.
///
///   flow:  infeed flat conveyor (left lane, running DOWN)
///            -> buffers across the infeed end
///            -> drop onto the step-up conveyor (right lane, running UP)
///            -> checkweigher 1
///            -> checkweigher 2
///
/// So the product path is a U-turn: down the left lane, across the buffers,
/// back up the right lane. The chevrons carry that — without them the two
/// parallel lanes read as two independent lines.
///
/// There is also a buffer between the step-up drop and checkweigher 1 on the
/// real machine. It is left out of the drawing: as a full-width band it read
/// as a third checkweigher and crowded the two that matter.
///
/// The two conveyor lanes are drawn as light beds rather than full-stroke
/// machinery on purpose: they are the intended home for live `ConveyorConfig`
/// children driven by the real drive frequencies. Drop a conveyor asset on a
/// lane and it sits in its bed; leave it empty and the bed still reads as a
/// conveyor.
class SpeedBatcherPainter extends ThirdPartyMachinePainter {
  const SpeedBatcherPainter({
    required super.color,
    required super.strokeWidth,
    super.mirrorX,
    super.mirrorY,
  });

  /// Buffer cells across the infeed end (2 columns x 2 rows in the sketch).
  static const int bufferColumns = 2;
  static const int bufferRows = 2;

  /// Unit rect of the infeed flat conveyor lane — where a live Conveyor child
  /// is meant to sit. Exposed so the editor can offer a one-tap "drop a
  /// conveyor on this lane" without duplicating the geometry.
  static const Rect infeedLane = Rect.fromLTRB(0.02, 0.41, 0.47, 0.82);

  /// Unit rect of the step-up conveyor lane.
  static const Rect stepUpLane = Rect.fromLTRB(0.53, 0.41, 0.98, 0.82);

  /// Unit frame of checkweigher 1 (the first one product reaches).
  ///
  /// The checkweighers are the stations this drawing exists for — the live
  /// belts, the readouts — so they get the vertical room, taken from the two
  /// lanes, which stay comfortably taller than they are wide. Even seams
  /// (0.02) between the bands and down to the lanes: a checkweigher belt is
  /// as wide as the lane feeding it, and any dead strip here read as a
  /// missing piece of machine.
  static const Rect checkweigher1Frame = Rect.fromLTRB(0.02, 0.22, 0.98, 0.39);

  /// Unit frame of checkweigher 2 (the last station before discharge).
  static const Rect checkweigher2Frame = Rect.fromLTRB(0.02, 0.03, 0.98, 0.20);

  /// The weigh belt inside a checkweigher frame.
  ///
  /// The FULL frame, edge to edge: a checkweigher is a conveyor with a load
  /// cell under it, not a box with a belt floating in the middle — a margin
  /// here read as the belt being narrower than its own station. This is the
  /// rect a live Conveyor child fills; kept as the one seam between the
  /// painter, the scaffold and the tests.
  static Rect deckOf(Rect frame) => frame;

  /// Horizontal half-extent of `ConveyorPainter`'s direction arrow, as a
  /// fraction of the belt width.
  ///
  /// The arrow is centred on the belt and its shaft is 40% of the belt width
  /// (`conveyor.dart:_drawDirectionArrow`), so it owns the middle 0.3..0.7.
  /// The readouts have to clear that or they land on top of it.
  static const double arrowHalfExtent = 0.20;

  /// Centre of the accept-rate readout — on the belt, left of the arrow.
  ///
  /// Pushed out to 13% rather than sitting nearer the middle so a
  /// 0.22-wide slot still clears the arrow tail at 0.30.
  static Offset acceptAnchorOf(Rect frame) => Offset(
        deckOf(frame).left + deckOf(frame).width * 0.13,
        frame.center.dy,
      );

  /// Centre of the weight readout — on the belt, right of the arrow. This is
  /// the live weight of whatever is on the belt right now.
  static Offset weightAnchorOf(Rect frame) => Offset(
        deckOf(frame).left + deckOf(frame).width * 0.87,
        frame.center.dy,
      );

  @override
  void paintMachine(Canvas canvas, UnitSpace u, Paint stroke, Paint detail) {
    // Station frame.
    canvas.drawRRect(u.rr(0.0, 0.0, 1.0, 1.0, 0.03), stroke);

    // -- Checkweighers, discharge end first --
    _checkweigher(canvas, u, stroke, detail, checkweigher2Frame);
    _checkweigher(canvas, u, stroke, detail, checkweigher1Frame);

    // The buffer between the step-up drop and checkweigher 1 is deliberately
    // NOT drawn. It is really there on the machine, but as a full-width band
    // it read as a third checkweigher and crowded the two that matter.
    //
    // -- Conveyor lanes --
    // Light beds; a live Conveyor child lands on top of these.
    canvas.drawRect(
        u.r(infeedLane.left, infeedLane.top, infeedLane.right,
            infeedLane.bottom),
        detail);
    canvas.drawRect(
        u.r(stepUpLane.left, stepUpLane.top, stepUpLane.right,
            stepUpLane.bottom),
        detail);

    // The step-up conveyor is cleated so product cannot roll back down the
    // incline — the rungs are what tells the two lanes apart from above.
    _lengthwiseTicks(canvas, u, detail,
        ul: stepUpLane.left,
        ur: stepUpLane.right,
        ut: stepUpLane.top,
        ub: stepUpLane.bottom,
        count: 7);

    // Flow chevrons: DOWN the infeed lane, UP the step-up lane. This is the
    // U-turn, and it is the one thing a reader cannot infer from the boxes.
    _chevrons(canvas, u, stroke,
        cx: infeedLane.center.dx, top: 0.44, bottom: 0.74, pointingDown: true);
    _chevrons(canvas, u, stroke,
        cx: stepUpLane.center.dx, top: 0.44, bottom: 0.74, pointingDown: false);

    // -- Buffers across the infeed end --
    const bufTop = 0.85;
    const bufBottom = 0.99;
    const bufLeft = 0.02;
    const bufRight = 0.98;
    canvas.drawRect(u.r(bufLeft, bufTop, bufRight, bufBottom), stroke);
    final colW = (bufRight - bufLeft) / bufferColumns;
    final rowH = (bufBottom - bufTop) / bufferRows;
    for (int c = 1; c < bufferColumns; c++) {
      canvas.drawLine(u.p(bufLeft + colW * c, bufTop),
          u.p(bufLeft + colW * c, bufBottom), stroke);
    }
    for (int r = 1; r < bufferRows; r++) {
      canvas.drawLine(u.p(bufLeft, bufTop + rowH * r),
          u.p(bufRight, bufTop + rowH * r), stroke);
    }

    // Adjustable feet at the four corners.
    for (final corner in const [
      Offset(0.03, 0.02),
      Offset(0.97, 0.02),
      Offset(0.03, 0.98),
      Offset(0.97, 0.98),
    ]) {
      canvas.drawCircle(u.p(corner.dx, corner.dy), u.rad(0.018), detail);
    }
  }

  /// One checkweigher: the station frame, which IS the belt bed.
  ///
  /// The belt is NOT drawn as machinery — a live bidirectional
  /// `ConveyorConfig` child fills the frame and animates off the real drive
  /// frequency; painting a belt underneath a real one reads as a double
  /// image. Same treatment as the two conveyor lanes. The deck now spans the
  /// whole frame (`deckOf`), so there is no separate bed rect to draw.
  ///
  /// Nothing is drawn on the belt itself: the middle belongs to the
  /// conveyor's run-direction arrow, and the readouts sit either side of it.
  void _checkweigher(
    Canvas canvas,
    UnitSpace u,
    Paint stroke,
    Paint detail,
    Rect frame,
  ) {
    canvas.drawRect(
        u.r(frame.left, frame.top, frame.right, frame.bottom), stroke);
  }
}

// ---------------------------------------------------------------------------
// Vodlari — fish aligning buffer
// ---------------------------------------------------------------------------

/// Plan view of the vodlari (Icelandic; a fish aligning buffer), fish flowing
/// left to right.
///
/// It buffers incoming fish and turns them so they leave in line: the fish is
/// caught in the nip between two belt runs, which rotate it into alignment
/// before it goes on. The belts are the machine — it is not a conveyor that
/// happens to have belts, the belts ARE how it works.
///
/// Drawn from the site CAD. What that drawing settles: the machine is close
/// to square, symmetric top to bottom, with a belt run either side of a
/// central lane, a drive unit on each belt, and a large drum across the
/// discharge end carrying a bearing housing at each end. Finer internals are
/// not resolvable from the screenshot, so they are not invented here.
class FishAlignerPainter extends ThirdPartyMachinePainter {
  const FishAlignerPainter({
    required super.color,
    required super.strokeWidth,
    super.mirrorX,
    super.mirrorY,
  });

  /// The two belt runs, either side of the lane the fish travels down.
  static const Rect upperBelt = Rect.fromLTRB(0.02, 0.06, 0.72, 0.34);
  static const Rect lowerBelt = Rect.fromLTRB(0.02, 0.66, 0.72, 0.94);

  /// The nip between them, where the fish is caught and turned.
  static const Rect lane = Rect.fromLTRB(0.02, 0.36, 0.72, 0.64);

  @override
  void paintMachine(Canvas canvas, UnitSpace u, Paint stroke, Paint detail) {
    // Machine frame.
    canvas.drawRRect(u.rr(0.0, 0.0, 1.0, 1.0, 0.03), stroke);

    // -- The two belt runs, with their rollers --
    for (final belt in [upperBelt, lowerBelt]) {
      canvas.drawRect(
          u.r(belt.left, belt.top, belt.right, belt.bottom), stroke);
      _crossTicks(canvas, u, detail,
          ul: belt.left,
          ur: belt.right,
          ut: belt.top,
          ub: belt.bottom,
          count: 7);
      // Drive unit on the belt: housing plus motor.
      final cy = belt.center.dy;
      canvas.drawRect(u.r(0.08, cy - 0.075, 0.26, cy + 0.075), stroke);
      canvas.drawCircle(u.p(0.125, cy), u.rad(0.032), detail);
    }

    // -- The lane between the belts --
    canvas.drawRect(u.r(lane.left, lane.top, lane.right, lane.bottom), detail);

    // Fish travel right along the lane...
    _chevronsAcross(canvas, u, stroke,
        cy: lane.center.dy, left: 0.10, right: 0.36, count: 2);
    // ...and are turned into line on the way. This glyph is the machine's
    // whole purpose, so it is drawn at full stroke.
    _rotationGlyph(canvas, u, stroke, cx: 0.52, cy: lane.center.dy);

    // -- Large drum across the discharge end, with a bearing housing at each
    //    end projecting clear of the frame.
    canvas.drawRect(u.r(0.76, 0.08, 0.94, 0.92), stroke);
    _lengthwiseTicks(canvas, u, detail,
        ul: 0.76, ur: 0.94, ut: 0.08, ub: 0.92, count: 5);
    canvas.drawRect(u.r(0.94, 0.12, 1.0, 0.22), detail);
    canvas.drawRect(u.r(0.94, 0.78, 1.0, 0.88), detail);
  }
}

/// Flow chevrons pointing RIGHT along a horizontal lane.
void _chevronsAcross(
  Canvas canvas,
  UnitSpace u,
  Paint paint, {
  required double cy,
  required double left,
  required double right,
  int count = 2,
}) {
  const halfHeight = 0.05;
  final span = right - left;
  final width = span / (count * 1.8);
  for (int i = 0; i < count; i++) {
    final base = left + span * (i + 0.5) / count - width / 2;
    final path = Path()
      ..moveTo(u.p(base, cy - halfHeight).dx, u.p(base, cy - halfHeight).dy)
      ..lineTo(u.p(base + width, cy).dx, u.p(base + width, cy).dy)
      ..lineTo(u.p(base, cy + halfHeight).dx, u.p(base, cy + halfHeight).dy);
    canvas.drawPath(path, paint);
  }
}

/// A three-quarter arc with an arrowhead — "the product is turned here".
void _rotationGlyph(
  Canvas canvas,
  UnitSpace u,
  Paint paint, {
  required double cx,
  required double cy,
}) {
  final centre = u.p(cx, cy);
  final r = u.rad(0.075);
  canvas.drawArc(
    Rect.fromCircle(center: centre, radius: r),
    -2.6,
    4.4,
    false,
    paint,
  );
  // Arrowhead on the open end of the arc.
  final tip = Offset(centre.dx + r * 0.72, centre.dy - r * 0.72);
  final head = Path()
    ..moveTo(tip.dx - r * 0.42, tip.dy - r * 0.10)
    ..lineTo(tip.dx, tip.dy)
    ..lineTo(tip.dx + r * 0.10, tip.dy + r * 0.42);
  canvas.drawPath(head, paint);
}

// ---------------------------------------------------------------------------
// Box erector
// ---------------------------------------------------------------------------

/// Plan view of the box erector, blanks flowing DOWN the page.
///
/// Drawn from the site CAD, which shows a tall, narrow machine — nothing like
/// the square side-loading erectors in the catalogues. The blank magazine
/// runs most of its length between two long guide rails, the forming station
/// sits in a wider bulge below it, and the erected case leaves at the bottom.
///
/// This one is PORTRAIT: at roughly 0.35 wide for its height, placing it in a
/// landscape box squashes the magazine into nothing.
///
/// TODO(product-name): the make/model is still unidentified. The layout now
/// comes from the site CAD rather than a generic catalogue machine, but the
/// nameplate is still needed for the label and for ordering spares.
class BoxErectorPainter extends ThirdPartyMachinePainter {
  const BoxErectorPainter({
    required super.color,
    required super.strokeWidth,
    super.mirrorX,
    super.mirrorY,
  });

  /// Flat blanks drawn in the magazine stack. Cosmetic — the real hopper holds
  /// a couple of hundred.
  static const int magazineBlanks = 12;

  /// The two long guide rails run nearly the whole machine, at these x.
  static const double railLeft = 0.24;
  static const double railRight = 0.76;
  static const double railHalfWidth = 0.06;

  @override
  void paintMachine(Canvas canvas, UnitSpace u, Paint stroke, Paint detail) {
    // Machine frame.
    canvas.drawRRect(u.rr(0.06, 0.02, 0.94, 0.98, 0.02), stroke);

    // -- Blank magazine: the stack of flat cases on edge, running down
    //    between two long guide rails. This is most of the machine.
    const magTop = 0.04;
    const magBottom = 0.40;
    for (final cx in [railLeft, railRight]) {
      canvas.drawRect(
          u.r(cx - railHalfWidth, magTop, cx + railHalfWidth, magBottom),
          stroke);
    }
    // The blanks themselves, seen edge-on between the rails.
    _lengthwiseTicks(canvas, u, detail,
        ul: railLeft + railHalfWidth,
        ur: railRight - railHalfWidth,
        ut: magTop,
        ub: magBottom,
        count: magazineBlanks);
    // Cross members tying the rails together.
    for (final y in [0.05, 0.12]) {
      canvas.drawLine(u.p(railLeft, y), u.p(railRight, y), detail);
    }

    // -- Forming station: the wider bulge, with a housing either side --
    const formTop = 0.40;
    const formBottom = 0.62;
    canvas.drawRect(u.r(0.06, formTop, 0.94, formBottom), stroke);
    canvas.drawRect(u.r(0.08, 0.45, 0.22, 0.58), detail);
    canvas.drawRect(u.r(0.78, 0.45, 0.92, 0.58), detail);
    // The case being squared, in the middle of the station.
    canvas.drawRRect(u.rr(0.38, 0.46, 0.62, 0.57, 0.015), stroke);

    // The rails continue past the forming station, carrying the case down.
    for (final cx in [railLeft, railRight]) {
      canvas.drawRect(
          u.r(cx - railHalfWidth * 0.7, formBottom, cx + railHalfWidth * 0.7,
              0.76),
          stroke);
    }

    // -- Flap folding / vacuum head: the rounded form the CAD shows low down,
    //    spanning most of the width.
    canvas.drawOval(u.r(0.14, 0.66, 0.86, 0.86), stroke);
    canvas.drawRect(u.r(0.36, 0.68, 0.64, 0.84), detail);

    // -- Outfeed across the bottom, where the erected case leaves --
    canvas.drawRect(u.r(0.06, 0.88, 0.94, 0.98), stroke);
    _crossTicks(canvas, u, detail,
        ul: 0.06, ur: 0.94, ut: 0.88, ub: 0.98, count: 3);
  }
}

// ---------------------------------------------------------------------------
// Afak SL-15-3 strapping line (StrapX heads)
// ---------------------------------------------------------------------------

/// Plan view of the strapping line, boxes flowing left to right.
///
/// This is a LINE, not a single machine: one conveyor runs the whole length
/// and [machines] discrete StrapX strappers stand on it, each strapping the
/// box once as it indexes through. Each strapper is its own unit — own frame,
/// own feet, own coil dispenser on its own bracket, own cabinet — which is
/// what the site CAD shows and what tells this apart from one machine with
/// several heads under a shared gantry.
///
/// The belt runs past both ends of the drawing, because the line continues
/// beyond the strappers.
///
/// The line gets longer as strappers are added, so the kind's aspect ratio
/// follows [machines] (see `ThirdPartyEquipmentKind.aspectRatio`). The drawing
/// itself always fills its box — leaving whitespace inside the dotted boundary
/// would read as a rendering bug — and the strappers spread to suit.
///
/// A 3-strapper line is ~2665 x 1815 mm, 15 boxes/min, ~530 mm boxes.
class StrappingLinePainter extends ThirdPartyMachinePainter {
  const StrappingLinePainter({
    required super.color,
    required super.strokeWidth,
    super.mirrorX,
    super.mirrorY,
    this.machines = maxMachines,
  }) : assert(machines >= 1 && machines <= maxMachines);

  /// Most strappers the line is built for.
  static const int maxMachines = 3;

  /// StrapX machines standing on the line.
  final int machines;

  /// Belt band, front to back. The line runs the full width of the drawing.
  static const double beltTop = 0.44;
  static const double beltBottom = 0.66;

  /// Span the strappers are distributed across. Stops short of the right edge
  /// so the line's control cabinet has somewhere to sit.
  static const double _zoneLeft = 0.03;
  static const double _zoneRight = 0.85;

  /// Unit x-centre of each strapper, spread evenly along the line.
  static List<double> machineCentresFor(int machines) {
    const span = _zoneRight - _zoneLeft;
    return [
      for (int i = 0; i < machines; i++)
        _zoneLeft + span * (i + 0.5) / machines,
    ];
  }

  /// Half-width of one strapper's footprint. Narrows as machines are added so
  /// three still stand clear of one another.
  static double halfWidthFor(int machines) {
    const span = _zoneRight - _zoneLeft;
    return (span / machines * 0.40).clamp(0.05, 0.15);
  }

  @override
  bool shouldRepaint(covariant ThirdPartyMachinePainter oldDelegate) =>
      super.shouldRepaint(oldDelegate) ||
      (oldDelegate is StrappingLinePainter &&
          oldDelegate.machines != machines);

  @override
  void paintMachine(Canvas canvas, UnitSpace u, Paint stroke, Paint detail) {
    // -- The line itself: one belt the full length, past both ends --
    canvas.drawRect(u.r(0.0, beltTop, 1.0, beltBottom), stroke);
    _crossTicks(canvas, u, detail,
        ul: 0.0, ur: 1.0, ut: beltTop, ub: beltBottom, count: 11);

    // Heavier end rollers where the line enters and leaves.
    for (final x in [0.012, 0.988]) {
      canvas.drawLine(u.p(x, beltTop), u.p(x, beltBottom), stroke);
    }

    final centres = machineCentresFor(machines);
    final half = halfWidthFor(machines);

    for (final cx in centres) {
      _strapper(canvas, u, stroke, detail, cx: cx, half: half);
    }

    // Pneumatic pushers that stop and hold the box at the first strapper,
    // riding just ahead of it rather than at a fixed spot that a one-strapper
    // line would put them past.
    final pusherX = (centres.first - half - 0.055).clamp(0.015, 0.90);
    canvas.drawRect(
        u.r(pusherX, beltBottom + 0.03, pusherX + 0.04, beltBottom + 0.09),
        detail);
    canvas.drawRect(
        u.r(pusherX, beltTop - 0.09, pusherX + 0.04, beltTop - 0.03), detail);

    // Line control cabinet at the discharge end, with the stack light.
    canvas.drawRect(u.r(0.89, 0.70, 1.0, 0.96), stroke);
    canvas.drawCircle(u.p(0.945, 0.76), u.rad(0.032), detail);
  }

  /// One StrapX strapper standing on the line.
  ///
  /// Frame around the whole unit with a foot at each corner, the arch
  /// straddling the belt, the coil dispenser on its bracket behind, and the
  /// unit's own cabinet in front.
  void _strapper(
    Canvas canvas,
    UnitSpace u,
    Paint stroke,
    Paint detail, {
    required double cx,
    required double half,
  }) {
    const frameTop = 0.17;
    const frameBottom = 0.95;

    // Unit frame.
    canvas.drawRect(u.r(cx - half, frameTop, cx + half, frameBottom), stroke);

    // Adjustable feet at the four corners.
    const foot = 0.016;
    for (final fx in [cx - half + foot, cx + half - foot]) {
      for (final fy in [frameTop + 0.03, frameBottom - 0.03]) {
        canvas.drawRect(
            u.r(fx - foot, fy - 0.014, fx + foot, fy + 0.014), detail);
      }
    }

    // StrapX arch straddling the belt: the crossbar spans the depth, with a
    // heavier footprint where each upright lands either side of the belt.
    final aw = half * 0.42;
    canvas.drawRect(u.r(cx - aw, 0.25, cx + aw, 0.85), stroke);
    canvas.drawRect(u.r(cx - aw, 0.25, cx + aw, beltTop), stroke);
    canvas.drawRect(u.r(cx - aw, beltBottom, cx + aw, 0.85), stroke);

    // Strap coil dispenser on its bracket behind the unit, with the strap
    // feed running down to the arch.
    canvas.drawCircle(u.p(cx, 0.08), u.rad(0.06), stroke);
    canvas.drawCircle(u.p(cx, 0.08), u.rad(0.02), detail);
    canvas.drawLine(u.p(cx, 0.135), u.p(cx, frameTop), detail);

    // This unit's cabinet, in front of the belt.
    canvas.drawRect(
        u.r(cx - half * 0.8, 0.87, cx + half * 0.8, frameBottom - 0.01),
        detail);
  }
}

// ---------------------------------------------------------------------------
// Optimar robotic palletising stations
// ---------------------------------------------------------------------------

/// Plan view of the Optimar palletising area, [stations] stations in a row.
///
/// Drawn from Optimar drawing 10-N1230-1, "Foundation Requirements for Robots
/// Ph-1 / Robotic Palletizing Stations for white boxes" (abuana, 28/04/2026,
/// 1:50 on A2) — the only drawing we have of this area, and a foundation
/// drawing rather than a GA, so it fixes the floor plan exactly and says
/// nothing about anything above knee height.
///
/// What the drawing settles, and what this therefore draws:
///
///  * The area is a ROW of identical stations, not one cell. Ph-1 is three of
///    them on a 3500 mm pitch (robot centres at 5210 / 8710 / 12210 off the
///    building datum).
///  * Each station is one PALLET LANE running front to back, about 3.9 m long,
///    with the robot standing BESIDE it — not at the head of it. The robot
///    reaches sideways across the lane, which is why the arm is drawn swung.
///  * The robot stands on a round foundation: a Ø1800 pad carrying a Ø1250
///    base plate on a Ø1110 bolt circle, 8 x M20 chemical anchors, 2250 kg
///    per robot (detail A on the drawing).
///  * A control cabinet with DOUBLE DOORS stands at the head of each station —
///    the drawing shows both door swings, which is what the cabinets are
///    recognised by from above.
///
/// What it does NOT settle: the make of the robot arm itself. The station is
/// Optimar's (the drawing's own notice block reads "Find us at optimar.no");
/// the arm on the pad is somebody else's 6-axis machine and the foundation
/// drawing never names it.
///
/// The area gets wider as stations are added, so the kind's aspect ratio
/// follows [stations] — the same arrangement the strapping line uses for its
/// head count. The drawing always fills its box.
class OptimarPalletiserPainter extends ThirdPartyMachinePainter {
  const OptimarPalletiserPainter({
    required super.color,
    required super.strokeWidth,
    super.mirrorX,
    super.mirrorY,
    this.stations = 2,
  }) : assert(stations >= 1 && stations <= maxStations);

  /// Stations Ph-1 is built for.
  static const int maxStations = 3;

  /// Palletising stations standing in the row.
  final int stations;

  /// The band the stations themselves occupy, front to back — effectively the
  /// whole box.
  ///
  /// The drawing also carries a transfer rail along the front of the row and a
  /// pallet magazine standing off it. Both are DELIBERATELY not drawn: they
  /// serve the whole hall rather than any one station, they sit OUTSIDE the
  /// guarding this asset is about, and at the sizes these boxes get placed at
  /// they cost a third of the height to say nothing an operator reads off a
  /// mimic. The stations get that height instead.
  static const double rowTop = 0.02;
  static const double rowBottom = 0.98;

  /// One station's pallet lane, as fractions of that station's own width.
  static const double laneLeft = 0.08;
  static const double laneRight = 0.46;

  /// Where the robot stands within its station: beside the lane, and BEHIND
  /// the position it works on, so the arm is drawn swung across the lane
  /// rather than reaching straight out sideways.
  ///
  /// The angle this produces is the same at every station count: a station is
  /// always one pitch wide on the page, so the run and the rise both scale
  /// with the box and their ratio does not move.
  static const double robotX = 0.72;
  static const double robotY = 0.71;

  /// Unit y the gripper is drawn at — clear of the stop between pallet
  /// positions, so the case reads as going onto the middle one rather than
  /// straddling two.
  static const double placementY = 0.49;

  /// Radius of the Ø1800 foundation pad, and of the Ø1250 base plate on it.
  ///
  /// Both are drawn as true circles off the shortest side rather than scaled
  /// per axis, so the pad stays round however wide the row gets. The 1250:1800
  /// ratio between them is the drawing's, and is what makes the pad read as a
  /// plate on a pad rather than as one thick ring.
  static const double padRadius = 0.150;
  static const double plateRadius = padRadius * 1250 / 1800;

  /// Unit x of station [i]'s left edge, and one station's width.
  static double stationWidthFor(int stations) => 1.0 / stations;
  static double stationLeftFor(int i, int stations) => i * stationWidthFor(stations);

  /// Unit x-centre of each station's robot, left to right.
  static List<double> robotCentresFor(int stations) {
    final w = stationWidthFor(stations);
    return [for (int i = 0; i < stations; i++) i * w + robotX * w];
  }

  /// Unit rect of station [i]'s pallet lane.
  static Rect laneRectFor(int i, int stations) {
    final w = stationWidthFor(stations);
    final sx = i * w;
    return Rect.fromLTRB(sx + laneLeft * w, 0.06, sx + laneRight * w, 0.93);
  }

  @override
  bool shouldRepaint(covariant ThirdPartyMachinePainter oldDelegate) =>
      super.shouldRepaint(oldDelegate) ||
      (oldDelegate is OptimarPalletiserPainter &&
          oldDelegate.stations != stations);

  @override
  void paintMachine(Canvas canvas, UnitSpace u, Paint stroke, Paint detail) {
    for (int i = 0; i < stations; i++) {
      _station(canvas, u, stroke, detail, index: i);
    }

    _fence(canvas, u, stroke, detail);
  }

  /// One station: its pallet lane, the robot beside it, and the cabinet at its
  /// head.
  void _station(
    Canvas canvas,
    UnitSpace u,
    Paint stroke,
    Paint detail, {
    required int index,
  }) {
    final w = stationWidthFor(stations);
    final sx = index * w;
    double lx(double f) => sx + f * w;

    // -- Pallet lane, running front to back --
    final lane = laneRectFor(index, stations);
    canvas.drawRect(u.r(lane.left, lane.top, lane.right, lane.bottom), stroke);
    // Chain slats across the lane. Lengthwise, not cross: the lane runs UP the
    // page, so its slats lie across it.
    _lengthwiseTicks(canvas, u, detail,
        ul: lane.left, ur: lane.right, ut: lane.top, ub: lane.bottom,
        count: 13);

    // Three pallet positions along the lane, divided by the stops between
    // them. The one at the back is built, the one under the robot is being
    // built, the one at the front has just come in empty.
    const splitA = 0.38;
    const splitB = 0.67;
    for (final y in const [splitA, splitB]) {
      canvas.drawLine(u.p(lane.left, y), u.p(lane.right, y), stroke);
    }
    // Back: built and waiting to go out.
    _palletOnLane(canvas, u, stroke, detail,
        lane: lane, top: lane.top + 0.02, bottom: splitA - 0.02, cases: 4);
    // Middle: the one the robot is working on.
    _palletOnLane(canvas, u, stroke, detail,
        lane: lane, top: splitA + 0.02, bottom: splitB - 0.02, cases: 0);
    // Front: just arrived, still empty.
    _palletOnLane(canvas, u, stroke, detail,
        lane: lane, top: splitB + 0.02, bottom: lane.bottom - 0.02, cases: 0);

    // -- Robot on its foundation --
    // Only the Ø1800 pad here; the Ø1250 base plate is drawn by [_arm], over
    // the shoulder casting, so the column reads as complete rather than as a
    // circle sliced by the arm's edge.
    final centre = u.p(lx(robotX), robotY);
    canvas.drawCircle(centre, u.rad(padRadius), detail);

    // It swings across the lane to the pallet it is building.
    final target = u.p(lane.center.dx, placementY);
    _arm(canvas, u, stroke, detail, from: centre, to: target);

    // -- Control cabinet at the head of the station, doors open to the front --
    _cabinet(canvas, u, stroke, detail,
        left: lx(0.56), top: 0.06, right: lx(0.94), bottom: 0.22);
  }

  /// A pallet standing at one position on the lane, with [cases] cases on it.
  ///
  /// [cases] of 0 draws the bare pallet — deck boards and nothing else, which
  /// is what an empty position looks like from above and what tells it from a
  /// built one at a glance.
  void _palletOnLane(
    Canvas canvas,
    UnitSpace u,
    Paint stroke,
    Paint detail, {
    required Rect lane,
    required double top,
    required double bottom,
    required int cases,
  }) {
    final inset = lane.width * 0.10;
    final l = lane.left + inset;
    final r = lane.right - inset;
    if (bottom - top <= 0.02) return;
    canvas.drawRect(u.r(l, top, r, bottom), stroke);
    if (cases <= 0) {
      // Bare deck.
      _lengthwiseTicks(canvas, u, detail,
          ul: l, ur: r, ut: top, ub: bottom, count: 3);
      return;
    }
    // A 2 x 2 case layer, which is what a 600 x 400 case makes of a
    // 1200 x 800 pallet.
    final padX = (r - l) * 0.06;
    final padY = (bottom - top) * 0.08;
    _cavityGrid(canvas, u, detail,
        ul: l + padX, ut: top + padY, ur: r - padX, ub: bottom - padY,
        rows: 2, cols: 2);
  }

  /// The arm, swung out from the pad and reaching across the lane.
  ///
  /// Seen from straight above a 6-axis arm projects onto a single line out of
  /// the base, because axes 2, 3 and 5 all pitch in the vertical plane it is
  /// swung into. What tells it from a gantry in plan is the run of joint hubs
  /// down that line and the gripper turned on the end of it.
  void _arm(
    Canvas canvas,
    UnitSpace u,
    Paint stroke,
    Paint detail, {
    required Offset from,
    required Offset to,
  }) {
    final span = to - from;
    if (span.distance == 0) return;
    final dir = span / span.distance;
    Offset at(double t) => from + span * t;

    // The shoulder casting runs BACK past the column, which is where the
    // counterweight sits on a palletiser and what stops the column reading as
    // a circle sliced by a straight edge.
    _armSegment(canvas, stroke, at(-0.16), at(0.34), u.rad(0.048));
    _armSegment(canvas, stroke, at(0.34), at(0.68), u.rad(0.033));

    // The column, over the shoulder, so the base reads as complete.
    canvas.drawCircle(from, u.rad(plateRadius), stroke);
    canvas.drawCircle(from, u.rad(0.018), detail); // axis 1
    canvas.drawCircle(at(0.34), u.rad(0.022), detail); // axes 2/3
    canvas.drawCircle(at(0.68), u.rad(0.015), detail); // wrist

    // -- The gripper: an open rectangular frame, turned by the wrist --
    //
    // Not a suction pad. The drawing shows a large open frame the width of the
    // lane, which is a clamp/layer gripper — it takes the case around its
    // sides, and drawing cups here would claim a tool the station does not
    // have.
    final head = at(0.96);
    _orientedBox(canvas, stroke, head, dir,
        halfLength: u.rad(0.058), halfWidth: u.rad(0.100));
    _orientedBox(canvas, detail, head, dir,
        halfLength: u.rad(0.036), halfWidth: u.rad(0.078));
  }

  /// A control cabinet with both door swings drawn.
  ///
  /// The swings are the point: from above a cabinet is an anonymous rectangle,
  /// and it is the pair of quarter-circle door arcs that names it — which is
  /// exactly how it is drawn on the Optimar drawing.
  void _cabinet(
    Canvas canvas,
    UnitSpace u,
    Paint stroke,
    Paint detail, {
    required double left,
    required double top,
    required double right,
    required double bottom,
  }) {
    canvas.drawRect(u.r(left, top, right, bottom), stroke);

    // Two doors hinged at the outer edges, both opening towards the front.
    // The left leaf swings from pointing right (closed) to pointing front;
    // the right leaf from pointing left. Both end up straight out the front,
    // which is why only the start angle differs.
    final leaf = (right - left) / 2;
    for (final (hinge, startAngle) in [
      (left, 0.0),
      (right, pi / 2),
    ]) {
      final centre = u.p(hinge, bottom);
      // Radius in device pixels off the leaf's own width, so the arc matches
      // the door it belongs to however wide the row gets.
      final radius = (u.p(hinge + leaf, bottom) - centre).dx.abs();
      canvas.drawArc(Rect.fromCircle(center: centre, radius: radius),
          startAngle, pi / 2, false, detail);
      // The open leaf itself.
      canvas.drawLine(
          centre, Offset(centre.dx, centre.dy + radius), detail);
    }
  }

  /// The guarding around the station row.
  ///
  /// Broken where things actually pass through: each pallet lane crosses the
  /// back. A post is drawn at every free end, which is what stops a broken
  /// perimeter reading as a fault.
  void _fence(Canvas canvas, UnitSpace u, Paint stroke, Paint detail) {
    final posts = <Offset>[];
    void run(double x1, double y1, double x2, double y2) {
      canvas.drawLine(u.p(x1, y1), u.p(x2, y2), stroke);
    }

    // Sides.
    run(0.0, rowTop, 0.0, rowBottom);
    run(1.0, rowTop, 1.0, rowBottom);

    // Back, broken by each lane.
    double x = 0.0;
    for (int i = 0; i < stations; i++) {
      final lane = laneRectFor(i, stations);
      if (lane.left > x) {
        run(x, rowTop, lane.left, rowTop);
        posts.add(u.p(lane.left, rowTop));
      }
      posts.add(u.p(lane.right, rowTop));
      x = lane.right;
    }
    if (x < 1.0) run(x, rowTop, 1.0, rowTop);

    // Front, unbroken.
    run(0.0, rowBottom, 1.0, rowBottom);

    // Divider between neighbouring stations, so the row reads as N cells
    // rather than one long room.
    for (int i = 1; i < stations; i++) {
      final sx = stationLeftFor(i, stations);
      run(sx, rowTop, sx, rowBottom);
    }

    final postHalf = u.rad(0.013);
    for (final p in posts) {
      canvas.drawRect(
          Rect.fromCenter(
              center: p, width: postHalf * 2, height: postHalf * 2),
          detail);
    }
  }
}

/// A rectangle running from [from] to [to] with [halfWidth] either side — one
/// arm segment seen from directly above.
///
/// Built as a path rather than a rotated `drawRect` so the stroke width stays
/// uniform: the machine areas are non-square, and `canvas.rotate` inside a
/// non-uniformly mapped space would thin the stroke on one axis.
void _armSegment(
    Canvas canvas, Paint paint, Offset from, Offset to, double halfWidth) {
  final along = to - from;
  if (along.distance == 0) return;
  final across = Offset(-along.dy, along.dx) / along.distance * halfWidth;
  canvas.drawPath(
      Path()
        ..moveTo((from + across).dx, (from + across).dy)
        ..lineTo((to + across).dx, (to + across).dy)
        ..lineTo((to - across).dx, (to - across).dy)
        ..lineTo((from - across).dx, (from - across).dy)
        ..close(),
      paint);
}

/// A box centred on [centre], its length along the unit vector [dir].
void _orientedBox(
  Canvas canvas,
  Paint paint,
  Offset centre,
  Offset dir, {
  required double halfLength,
  required double halfWidth,
}) {
  _armSegment(canvas, paint, centre - dir * halfLength,
      centre + dir * halfLength, halfWidth);
}

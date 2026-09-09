import 'dart:ui' show PathMetric, Tangent;

import 'package:flutter/material.dart';
import 'package:tfc/widgets/panes/standard_dialog.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc/providers/collector.dart';
import 'dart:math';
import 'package:tfc/widgets/number_slider.dart';
import 'package:rxdart/rxdart.dart';
import 'common.dart';
import 'dart:async';
import 'package:logger/logger.dart';
import '../../providers/state_man.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import '../../widgets/graph.dart';
import '../../widgets/hit_boundary.dart';
import '../../widgets/panes/pane_chrome.dart';
import '../../widgets/panes/side_pane.dart';
import '../../widgets/state_value_builder.dart';
import '../../widgets/panes/setpoint_field.dart';
import '../../widgets/tag_access_guard.dart';
import 'auger_conveyor_painter.dart';
import 'helper/atv320_diagnostics.dart';
import 'sensor.dart' show SensorConfig, SensorFbPane, SensorFbState;
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/collector.dart';
import '../../theme.dart';
import '../page.dart';
import 'conveyor_gate.dart';

part 'conveyor.g.dart';

/// Deserialize gates list with backward compatibility for old format.
///
/// Old format: gate config at root level with "asset_name" key.
/// New format: ChildGateEntry with "position", "side", and "gate" sub-object.
List<ChildGateEntry> _gatesFromJson(List<dynamic>? json) {
  if (json == null) return [];
  return json.map((item) {
    final map = item as Map<String, dynamic>;
    // Old format: gate config at root level with "asset_name" key
    if (map.containsKey('asset_name') && !map.containsKey('gate')) {
      final position = (map['position'] as num?)?.toDouble() ?? 0.5;
      final side = map['side'] != null
          ? GateSide.values.firstWhere(
              (e) => e.name == map['side'],
              orElse: () => GateSide.left,
            )
          : GateSide.left;
      return ChildGateEntry(
        position: position,
        side: side,
        gate: ConveyorGateConfig.fromJson(map),
      );
    }
    // New format: ChildGateEntry with "gate" sub-object
    return ChildGateEntry.fromJson(map);
  }).toList();
}

List<Map<String, dynamic>> _gatesToJson(List<ChildGateEntry> gates) =>
    gates.map((e) => e.toJson()).toList();

/// A bend in the conveyor belt.
///
/// The belt runs straight until [position] (fraction of the configured belt
/// length), then follows a circular arc of [radius] belt-widths sweeping
/// [angle] degrees, and continues straight in the new direction. Positive
/// angles turn towards the bottom of the screen, negative towards the top
/// (before the asset's own rotation is applied).
@JsonSerializable()
class ConveyorTurnEntry {
  /// Fractional position along the belt where the turn starts (0.0 = start).
  double position;

  /// Sweep of the turn in degrees. Positive = down/clockwise on screen.
  double angle;

  /// Turn radius expressed in belt widths (the conveyor's cross dimension).
  double radius;

  ConveyorTurnEntry({
    this.position = 0.5,
    this.angle = 45,
    this.radius = 1.5,
  });

  /// Where a freshly added turn should sit: the middle of the widest stretch
  /// of belt no turn occupies yet.
  ///
  /// Every new turn used to land on 0.5. A second one therefore shared the
  /// first one's corner, where each fillet is clamped to the zero-length
  /// straight between them and both bends paint as a single sharp corner —
  /// so adding a turn looked like nothing happened, and deleting either of
  /// them looked like the wrong one went.
  static double freePosition(List<ConveyorTurnEntry> existing) {
    if (existing.isEmpty) return 0.5;
    final taken = existing.map((t) => t.position.clamp(0.0, 1.0)).toList()
      ..sort();
    var widest = -1.0;
    var pick = 0.5;
    for (var i = 0; i <= taken.length; i++) {
      final lo = i == 0 ? 0.0 : taken[i - 1];
      final hi = i == taken.length ? 1.0 : taken[i];
      if (hi - lo > widest) {
        widest = hi - lo;
        pick = (lo + hi) / 2;
      }
    }
    return pick;
  }

  factory ConveyorTurnEntry.fromJson(Map<String, dynamic> json) =>
      _$ConveyorTurnEntryFromJson(json);
  Map<String, dynamic> toJson() => _$ConveyorTurnEntryToJson(this);
}

/// Centerline geometry of a conveyor with one or more [ConveyorTurnEntry]
/// bends, fitted into the asset's bounding box.
///
/// The centerline is built in "natural" units where the belt length equals the
/// box width and the belt width equals the box height (matching the straight
/// rendering), then uniformly scaled and centered so the whole belt stays
/// inside the box. Fractional belt positions (batches, gates) map onto the
/// path through its [PathMetric].
class ConveyorPathGeometry {
  final Path path;
  final double beltWidth;
  final double scale;

  /// Radius of the tightest bend the centerline actually turns through, in
  /// painted units — [double.infinity] for a belt whose corners all came out
  /// sharp, which no band can be bent around anyway.
  ///
  /// Kept from the fit rather than measured off the path: [bandOutline] needs
  /// it to know when a band is too wide for its own bend, and reading it back
  /// from samples of the path made that judgement a function of how densely
  /// the path happened to be sampled — which is to say, of how big the box
  /// was. The same belt then folded on one screen and not another.
  final double minTurnRadius;

  final PathMetric _metric;

  ConveyorPathGeometry._(
      this.path, this.beltWidth, this.scale, this.minTurnRadius, this._metric);

  double get length => _metric.length;

  /// Bounds of the ink this belt lays down, outline included.
  ///
  /// The one definition of "how much box does this belt take up". Neither
  /// [path]'s bounds nor [bandOutline]'s are that on their own: `getBounds`
  /// is a control-point estimate that overshoots a stretched skeleton badly,
  /// the border is stroked *on* the band's edge so half of it lies beyond,
  /// and a band too wide for its own bend is not drawn as a band at all.
  /// The fit places the belt by this, so anything checking where the belt
  /// ended up should read the same number rather than re-deriving it.
  Rect get inkBounds => _inkBounds(this);

  Tangent tangentAt(double fraction) =>
      _metric.getTangentForOffset(fraction.clamp(0.0, 1.0) * length) ??
      Tangent(Offset.zero, const Offset(1, 0));

  Path extractFraction(double from, double to) => _metric.extractPath(
      from.clamp(0.0, 1.0) * length, to.clamp(0.0, 1.0) * length);

  /// Outline of a band running along [from]..[to] of the belt: a rectangle
  /// [width] across with its four corners rounded by [radius], bent to follow
  /// the centerline.
  ///
  /// This is the shape a straight belt draws with a single `RRect` — for the
  /// belt itself and for every batch on it. Stroking the centerline instead
  /// cannot produce it: a stroke's cap is a half circle, and squaring one off
  /// against a bend leaves a wedge where the cap and the body meet at
  /// different angles.
  ///
  /// Null when the band is wider than its own bend can carry — the inner edge
  /// would reach past the centre of curvature and fold the outline into a bow
  /// tie. Callers fall back to stroking the centerline there, which is
  /// meaningless geometry either way but at least stays solid.
  Path? bandOutline(double from, double to,
      {required double width, required double radius}) {
    final start = from.clamp(0.0, 1.0) * length;
    final span = to.clamp(0.0, 1.0) * length - start;
    if (span <= 0 || width <= 0) return Path();
    // On the inside of a bend the edge cannot reach past the centre of
    // curvature without crossing the centerline, which folds the outline into
    // a bow tie. There is no honest band to draw at that point.
    //
    // Measured against the fit's own [minTurnRadius] rather than a curvature
    // read back off samples of the path. The sampled estimate depended on how
    // densely the path happened to be sampled, which was in absolute pixels,
    // so the same belt was judged foldable on one box and not on another — a
    // belt near the limit swapped between a band and a stroked centerline the
    // moment a side pane re-fitted the page under it. With the radius exact
    // and every length in the fit proportional, this verdict now depends on
    // the belt alone.
    //
    // A little short of the radius: an edge that merely grazes the centre of
    // curvature already leaves a cusp the border traces as a stray hair.
    final half = width / 2;
    if (half > 0.98 * minTurnRadius) return null;
    // Same clamping an RRect applies when the radii do not fit the rect.
    final r = max(min(min(radius, half), span / 2), 0.0);

    /// Half-width of a rounded rectangle [d] along from its nearer flat end.
    double halfWidthAt(double d) {
      if (r <= 0 || d >= r) return half;
      final k = r - d;
      return (half - r) + sqrt(max(r * r - k * k, 0));
    }

    // Dense through the two corners, and along the middle at a step set by
    // the band's own width — a twenty-fourth of it, which is the ~4px this
    // used to sample a full-page belt at. Relative rather than absolute so
    // the same belt is drawn out of the same polygon whatever its box.
    const cornerSteps = 12;
    final middleSteps = max(min((span / (width / 24)).ceil(), 2048), 2);
    final offsets = <double>{0, span};
    for (var i = 0; i <= cornerSteps; i++) {
      offsets.add(r * i / cornerSteps);
      offsets.add(span - r * i / cornerSteps);
    }
    for (var i = 0; i <= middleSteps; i++) {
      offsets.add(span * i / middleSteps);
    }

    final ordered = offsets.toList()..sort();
    final samples = <double>[];
    final tangents = <Tangent>[];
    for (final d in ordered) {
      final t = _metric.getTangentForOffset(start + d);
      if (t == null) continue;
      samples.add(d);
      tangents.add(t);
    }
    if (samples.length < 2) return Path();

    final left = <Offset>[];
    final right = <Offset>[];
    for (var i = 0; i < samples.length; i++) {
      final t = tangents[i];
      final normal = Offset(-t.vector.dy, t.vector.dx);
      final h = halfWidthAt(min(samples[i], span - samples[i]));
      left.add(t.position + normal * h);
      right.add(t.position - normal * h);
    }

    final outline = Path()..moveTo(left.first.dx, left.first.dy);
    for (final p in left.skip(1)) {
      outline.lineTo(p.dx, p.dy);
    }
    for (final p in right.reversed) {
      outline.lineTo(p.dx, p.dy);
    }
    return outline..close();
  }

  /// Whether a fill solve still resembles the configured belt.
  ///
  /// Stretching runs is the point of the solve, but a run crushed to nothing
  /// while its neighbours grow is the belt being folded into a different
  /// shape. A run may shrink, but not more than a factor of four below the
  /// uniform rescale.
  static bool _keepsProportions(List<double> before, List<double> after) {
    final totalBefore = before.fold<double>(0, (a, b) => a + b);
    final totalAfter = after.fold<double>(0, (a, b) => a + b);
    if (totalBefore <= 0 || totalAfter <= 0) return false;
    final g = totalAfter / totalBefore;
    for (var i = 0; i < before.length; i++) {
      if (before[i] <= 1e-9) continue; // was zero, allowed to stay zero
      if (after[i] < before[i] * g / 4) return false;
    }
    return true;
  }

  /// Whether stroking [path] at [beltWidth] would paint the belt over
  /// itself — two stretches far apart along the belt but closer across it
  /// than the belt is wide.
  ///
  /// A solve is free to move the runs, and nothing in the extents stops it
  /// from parking the exit run of a U-turn on top of its entry run: both
  /// bounds still match the box. Overlap is what makes that wrong, so test
  /// for it directly. Belts *configured* to self-overlap look the same
  /// before and after the solve and are the fallback's problem either way.
  static bool _selfOverlaps(Path path, double beltWidth) {
    final metrics = path.computeMetrics().toList();
    if (metrics.isEmpty) return false;
    final metric = metrics.first;
    const samples = 64;
    final pts = <Offset>[];
    for (var i = 0; i <= samples; i++) {
      final t = metric.getTangentForOffset(metric.length * i / samples);
      if (t == null) return false;
      pts.add(t.position);
    }
    final step = metric.length / samples;
    for (var i = 0; i < pts.length; i++) {
      for (var j = i + 1; j < pts.length; j++) {
        // Neighbours along the belt are close by construction; only count
        // stretches separated by enough arc length to be different runs.
        if ((j - i) * step <= 2 * beltWidth) continue;
        if ((pts[i] - pts[j]).distance < beltWidth * 0.9) return true;
      }
    }
    return false;
  }

  /// Clearance between the belt's ink and the box edge, as a fraction of the
  /// box's short side.
  ///
  /// Proportional rather than the flat 2px this used to be, and that is the
  /// whole point. Every other length the fit works in is relative — radii in
  /// belt widths, positions in box fractions, the accept tests and the fold
  /// test in ratios — so the belt it produces depends only on the *shape* of
  /// its box. One absolute length among them breaks that: it makes the box
  /// the belt is fitted into a slightly different shape at a different size,
  /// which is enough to flip a belt sitting near any of those tests from the
  /// box-filling solve to the uniform-fit fallback — from spanning its box to
  /// a fraction of it. The plant view re-fits the whole page to ~0.68x when a
  /// docked side pane opens over the tapped device, so the flip showed up as
  /// a conveyor squeezing itself the moment its pane appeared, and, being a
  /// threshold, only for some belts on some screens.
  ///
  /// The size is the old 2px, expressed against the box it was tuned on: a
  /// conveyor 270px down the short side, which is roughly what one fills on
  /// a plant page. Belts at that size are laid out exactly as before, bigger
  /// ones get proportionally more clearance and smaller ones less — down to
  /// less than the half-pixel of border that falls outside the band, on a
  /// box narrower than 135px, where that fraction of the outline crosses the
  /// box edge. Buying it back with a floor would put an absolute length back
  /// into the fit, and a hair of antialiased outline over the edge of a
  /// small asset is worth less than a belt that reshapes itself.
  static const _marginFraction = 2 / 270;

  /// How close the solved bounds must come to the box before the fill counts,
  /// as a fraction of the inner box's short side — half a pixel at the size
  /// this was measured at, and half a pixel's worth at every other size.
  static const _fillTolerance = 0.5 / 171.5;

  /// The clearance the fit keeps between the belt and the edge of a box of
  /// [size]. Public so a test can say what "the belt fills its box" means
  /// without copying the number out of here.
  static double marginFor(Size size) => size.shortestSide * _marginFraction;

  static ConveyorPathGeometry? build(
    List<ConveyorTurnEntry> turns,
    Size size, {
    double thicknessFactor = 1.0,
    double? beltWidthOverride,
  }) {
    if (turns.isEmpty || size.width <= 0 || size.height <= 0) return null;
    // Belt thickness relative to the box height. A bend needs a taller box to
    // fit, which would otherwise force a fat belt — the factor lets e.g. an
    // L-shaped conveyor in a square box keep a thin belt.
    //
    // A turned belt curves in both axes, so a thickness taken from the height
    // can exceed the *width* in a tall narrow box and spill out sideways no
    // matter how the centerline is fitted. Cap it against the short side so
    // the box invariant always holds; for the usual wide box this is a no-op.
    final margin = size.shortestSide * _marginFraction;
    // Across the box the belt has to leave room for the clearance *and* for
    // the half-border that falls outside the band, whichever is larger. This
    // is the one place a fixed number of pixels belongs: it only binds for a
    // belt already as wide as its box, where there is no shape left for it to
    // change, and it keeps that belt's outline off the box edge.
    final containable = max(
        size.shortestSide - 2 * max(margin, ConveyorPainter._borderWidth / 2),
        1.0);
    // An explicit belt width is given in screen units, so the same number has
    // to mean the same belt everywhere — resizing the box must not silently
    // change it. Only the box-relative thickness is, by definition, bounded
    // by the box.
    final double beltWidth;
    final double fitWidth;
    if (beltWidthOverride != null) {
      beltWidth = beltWidthOverride;
      // The fit insets the box by half the belt width so the belt lands
      // inside it. Once the belt is wider than the box that is unreachable,
      // and insetting anyway squeezes the centerline into a sliver — the
      // bend collapses into a blob. So hand the inset back as the overflow
      // grows: at the limit it is still the full belt (no jump), and by
      // twice the limit the bare centerline is fitted and the belt simply
      // spills over the box.
      final overflow = max(beltWidthOverride - containable, 0.0);
      fitWidth = max(min(beltWidthOverride, containable) - overflow, 0.0);
    } else {
      beltWidth =
          min(size.height * thicknessFactor.clamp(0.05, 1.0), containable);
      fitWidth = beltWidth;
    }
    final sorted = List<ConveyorTurnEntry>.of(turns)
      ..sort((a, b) => a.position.compareTo(b.position));

    // Turns are CAD fillets on a skeleton of straight runs: each keeps its
    // configured sweep, and its radius is truly `radius * beltWidth` on
    // screen. The straights are what flexes — they stretch or shrink so the
    // belt fills the bounding box, the way a conveyor is actually drawn into
    // a floor plan: the bend is fixed geometry, the runs absorb the space.
    //
    // The arc must not consume the positional budget. When it did, every
    // straight after a turn was only whatever was left over, so a symmetric
    // set of positions produced an asymmetric belt — the run into the first
    // turn kept its full length while the run out of the last one got the
    // remainder — and a large radius silently deleted straights entirely.
    final active = sorted.where((t) => t.angle != 0).toList();
    final sweeps = [
      for (final t in active)
        // tan blows up at a half turn, so stop just short of it.
        (t.angle.clamp(-179.5, 179.5)) * pi / 180
    ];
    final n = active.length;
    // Capped: a fillet radii beyond any box (hand-edited JSON, slider abuse)
    // only gets uniformly scaled down again, and taken literally it
    // overflows the seeding arithmetic into non-finite geometry.
    final radii = [
      for (final t in active)
        min(max(t.radius, 0.1) * beltWidth, size.longestSide * 1e3)
    ];

    final inset = fitWidth / 2 + margin;
    final inner = Size(
        max(size.width - 2 * inset, 1.0), max(size.height - 2 * inset, 1.0));
    // A box that is all belt: `inner` is a sliver held up by its own floor —
    // a 38px belt in a 40px-tall box leaves 1.4px of it. Both the per-axis
    // fit and the ink fit stand down there. Neither has anything to win: the
    // belt already covers its box, and the two axes disagree by orders of
    // magnitude, so either would squash a 90° turn flat rather than fill
    // anything, leaving a belt that is no longer the belt configured.
    final boxIsAllBelt = inner.width < size.width * _perAxisFloor ||
        inner.height < size.height * _perAxisFloor;

    // Straight runs between consecutive corners: seg[0] leads into the first
    // corner, seg[n] leaves the last one. Positions seed their proportions;
    // the fill solve rescales them per axis afterwards.
    //
    // A position points at the *center of the corner arc*, measured along
    // the belt — the arc is the bend the operator sees, so it is what the
    // slider must move. Seeded on the skeleton's corner points instead, the
    // run into a bend and the arc's own length pushed the visible corner
    // away from the configured number. The skeleton distances are the path
    // lengths with each fillet's tangent runs added back: a fillet replaces
    // 2*tangent of skeleton with its arc of belt.
    //
    // A radius can make a position physically unreachable — the arc's
    // center needs half the arc of belt before it, and neighbouring
    // fillets need their tangent runs — so such positions clamp to the
    // closest spot the fillet still fits at full radius, rather than
    // pinching the bend to honour a number nobody can see honoured.
    final naturalLength = inner.width;
    final tangentLen = [
      for (var i = 0; i < n; i++) radii[i] * tan(sweeps[i].abs() / 2)
    ];
    final arcLen = [for (var i = 0; i < n; i++) radii[i] * sweeps[i].abs()];
    // Each run's ideal skeleton length: the belt distance between the arc
    // centers it connects (box start and end count as centers of nothing),
    // with each adjacent fillet's tangent run added back and half its arc
    // taken out — a fillet replaces 2*tangent of skeleton with its arc of
    // belt. Written as differences of neighbouring positions, not a running
    // sum, so a clamp on one run cannot leak asymmetry into the others.
    final seg = <double>[];
    for (var i = 0; i <= n; i++) {
      final prevCenter = i == 0
          ? 0.0
          : active[i - 1].position.clamp(0.0, 1.0) * naturalLength;
      final nextCenter = i == n
          ? naturalLength
          : active[i].position.clamp(0.0, 1.0) * naturalLength;
      var ideal = nextCenter - prevCenter;
      if (i > 0) ideal += tangentLen[i - 1] - arcLen[i - 1] / 2;
      if (i < n) ideal += tangentLen[i] - arcLen[i] / 2;
      final minimum = (i > 0 ? tangentLen[i - 1] : 0.0) +
          (i < n ? tangentLen[i] : 0.0);
      seg.add(max(ideal, minimum));
    }

    var fillClamped = false;
    // Radius of the tightest bend the last [buildPath] actually drew, before
    // the final fit scale. Sharp corners are left out: they are not bends a
    // band can be carried around, and a belt clamped to one is drawn by the
    // fallback either way.
    var builtMinRadius = double.infinity;
    Path buildPath(List<double> seg) {
      fillClamped = false;
      builtMinRadius = double.infinity;
      // Tangent length each fillet eats out of the straights beside it —
      // shrink fillets that do not fit rather than dropping the straight:
      // first against each neighbouring run, then the pair sharing a run.
      final tangent = <double>[];
      for (var i = 0; i < n; i++) {
        tangent.add(radii[i] * tan(sweeps[i].abs() / 2));
      }
      final wanted = List<double>.of(tangent);
      for (var i = 0; i < n; i++) {
        tangent[i] = min(tangent[i], seg[i]);
        tangent[i] = min(tangent[i], seg[i + 1]);
      }
      for (var i = 1; i < n; i++) {
        final pair = tangent[i - 1] + tangent[i];
        if (pair > seg[i] && pair > 0) {
          final scale = seg[i] / pair;
          tangent[i - 1] *= scale;
          tangent[i] *= scale;
        }
      }
      for (var i = 0; i < n; i++) {
        if (tangent[i] < wanted[i] - 1e-6) fillClamped = true;
      }

      final path = Path()..moveTo(0, 0);
      var corner = Offset.zero;
      var heading = 0.0;
      for (var i = 0; i < n; i++) {
        final inDir = Offset(cos(heading), sin(heading));
        final c = corner + inDir * seg[i];
        final arcStart = c - inDir * tangent[i];
        path.lineTo(arcStart.dx, arcStart.dy);
        heading += sweeps[i];
        final outDir = Offset(cos(heading), sin(heading));
        final arcEnd = c + outDir * tangent[i];
        final effectiveRadius = tangent[i] / tan(sweeps[i].abs() / 2);
        if (tangent[i] > 0 && effectiveRadius.isFinite && effectiveRadius > 0) {
          builtMinRadius = min(builtMinRadius, effectiveRadius);
          path.arcToPoint(
            arcEnd,
            radius: Radius.circular(effectiveRadius),
            clockwise: sweeps[i] > 0,
          );
        } else {
          // No room to round the corner — keep it sharp rather than skip it.
          // A sharp corner carries no band around it at all, so it sets the
          // minimum to zero and [bandOutline] hands the belt to the stroke.
          builtMinRadius = 0;
          path.lineTo(arcEnd.dx, arcEnd.dy);
        }
        corner = c;
      }
      final tail = corner + Offset(cos(heading), sin(heading)) * seg[n];
      path.lineTo(tail.dx, tail.dy);
      return path;
    }

    // Fill solve: nudge each straight until the centerline's bounds match the
    // inner box on both axes. A run contributes to each axis by its heading,
    // so a horizontal run absorbs width, a vertical one height, a diagonal a
    // blend — and runs sharing a heading keep their relative proportions,
    // which is what the position sliders express. The arcs are fixed
    // geometry; when they alone exceed an axis no seg change can fix it, the
    // residual stays, and the uniform-fit fallback below takes over.
    Path? solved;
    if (n > 0) {
      // Work on a copy: if the box cannot be filled, the fallback must fit
      // the position-faithful skeleton, not whatever the failed solve left.
      final trial = List<double>.of(seg);
      final headings = <double>[0.0];
      for (final sweep in sweeps) {
        headings.add(headings.last + sweep);
      }
      final tolerance = inner.shortestSide * _fillTolerance;
      var path = buildPath(trial);
      for (var iter = 0; iter < 40; iter++) {
        final b = path.getBounds();
        // A fill only counts when every fillet kept its true radius. The
        // solve can always "fill" a too-small box by pinching corners sharp
        // and amputating runs — a belt that fits the box by no longer being
        // the belt that was configured. That case belongs to the fallback.
        if (!fillClamped &&
            (b.width - inner.width).abs() < tolerance &&
            (b.height - inner.height).abs() < tolerance &&
            _keepsProportions(seg, trial) &&
            !_selfOverlaps(path, beltWidth)) {
          solved = path;
          break;
        }
        final fx = b.width > 1e-6 ? inner.width / b.width : 1.0;
        final fy = b.height > 1e-6 ? inner.height / b.height : 1.0;
        for (var i = 0; i <= n; i++) {
          final wx = cos(headings[i]).abs();
          final wy = sin(headings[i]).abs();
          final f = (fx * wx + fy * wy) / (wx + wy);
          trial[i] = max(trial[i] * f, 0.0);
        }
        path = buildPath(trial);
      }
    }

    final Path fitted;
    final double fit;
    if (solved != null) {
      // Solved: the belt fills the box at true scale. The residual is under
      // [_fillTolerance]; squeeze it out rather than let the paint cross the
      // box.
      final bounds = solved.getBounds();
      final clamp = min(
          1.0,
          min(bounds.width > 1e-6 ? inner.width / bounds.width : 1.0,
              bounds.height > 1e-6 ? inner.height / bounds.height : 1.0));
      fit = clamp;
      // Centre on the box, not on the inset origin: a box thinner than the
      // belt clamps `inner` to a floor, and anchoring to the inset would
      // push the centerline off-centre and the paint over the box edge.
      final dx = size.width / 2 - bounds.center.dx * clamp;
      final dy = size.height / 2 - bounds.center.dy * clamp;
      fitted = solved.transform(Matrix4(
        clamp, 0, 0, 0, //
        0, clamp, 0, 0, //
        0, 0, 1, 0, //
        dx, dy, 0, 1,
      ).storage);
    } else {
      // Unfillable box: the solve could not span both axes while keeping
      // every fillet at true radius. Fit each axis on its own instead.
      //
      // This used to shrink the whole skeleton by `min(sx, sy)`, which kept
      // the bends circular. That guarantee was already gone by the time we
      // get here — a uniform shrink scales the radii down with everything
      // else, and the reference U-turn came out at 0.66 of its configured
      // radius on every screen. What it bought instead was a belt floating
      // in a third of its box, and a shape that moved with the window: 33%
      // of the box width at 16:9, 24% at 21:9, 57% in portrait.
      //
      // Fitting per axis gives up circular bends in this branch and gets
      // back the two properties that are actually visible: the belt fills
      // the box it was drawn into, and what is drawn depends only on that
      // box — so resizing the window scales the belt instead of reshaping
      // it. The stroke is applied after this transform, so the band keeps an
      // even width; it is the centerline that stretches.
      final path = buildPath(seg);
      final bounds = path.getBounds();
      final sx = bounds.width > 1e-6 ? inner.width / bounds.width : 1.0;
      final sy = bounds.height > 1e-6 ? inner.height / bounds.height : 1.0;
      var fx = sx.isFinite && sx > 0 ? sx : 1.0;
      var fy = sy.isFinite && sy > 0 ? sy : 1.0;
      // Shrink uniformly where the box is all belt, as this branch always
      // did — there is nothing to fit the axes to separately.
      if (boxIsAllBelt) fx = fy = min(fx, fy);
      // `scale` and the min-radius derived from it describe the belt as a
      // whole, so report the smaller axis: the tightest bend on screen is
      // bounded by the axis that shrank most.
      fit = min(fx, fy);
      final dx = size.width / 2 - bounds.center.dx * fx;
      final dy = size.height / 2 - bounds.center.dy * fy;
      final matrix = Matrix4(
        fx, 0, 0, 0, //
        0, fy, 0, 0, //
        0, 0, 1, 0, //
        dx, dy, 0, 1,
      );
      fitted = path.transform(matrix.storage);
    }
    // The fit scales the whole skeleton, bends included, so the tightest
    // bend on screen is the tightest one built times that scale.
    final minTurnRadius = builtMinRadius * fit;
    final metrics = fitted.computeMetrics().toList();
    if (metrics.isEmpty) return null;
    var geometry = ConveyorPathGeometry._(
        fitted, beltWidth, fit, minTurnRadius, metrics.first);

    // What the box has to hold is the ink, and the ink is not the centerline
    // plus a constant inset. The band extends beltWidth/2 sideways from the
    // centerline, so on the axis a run travels *along* it adds nothing — yet
    // the fit insets the box by beltWidth/2 on all four sides regardless. On
    // a U-turn, whose two ends both run vertically, that reservation is
    // simply left empty: the reference belt's ink came out at 68% of its box
    // height with 16% of the box blank above and below it.
    //
    // Fallback only. Where the solve succeeded every fillet is at its true
    // radius and the centerline already fills `inner` exactly; stretching it
    // to use up the leftover would trade the one guarantee the solve exists
    // to provide for a few percent of box.
    if (solved == null && !boxIsAllBelt) {
      geometry = _fillBoxWithInk(geometry, size, margin);
    }

    // Center the ink, not the centerline. The band extends beltWidth/2 past
    // the centerline on the outer side of every run but ends in a flat cap,
    // so around an L the ink is lopsided against the centerline's bounds —
    // centered on those, the belt visibly hugs one corner of its box.
    final ink = _inkBounds(geometry);
    // Per axis, and only while the ink fits: an over-wide belt spills over
    // the box by design, and dragging its centerline around to center the
    // spill would break the skeleton's own containment.
    final shift = Offset(
      ink.width <= size.width ? size.width / 2 - ink.center.dx : 0.0,
      ink.height <= size.height ? size.height / 2 - ink.center.dy : 0.0,
    );
    // Hostile configs (hand-edited JSON) can degenerate into non-finite
    // bounds; Path.shift asserts on NaN, and there is nothing to center.
    if (!shift.dx.isFinite || !shift.dy.isFinite) return geometry;
    // Proportional for the same reason [_marginFraction] is: nothing in the
    // fit may depend on how big the box happens to be.
    if (shift.distance < size.shortestSide * 1e-4) return geometry;
    final moved = geometry.path.shift(shift);
    final movedMetrics = moved.computeMetrics().toList();
    if (movedMetrics.isEmpty) return geometry;
    return ConveyorPathGeometry._(moved, geometry.beltWidth, geometry.scale,
        geometry.minTurnRadius, movedMetrics.first);
  }

  /// Ink of a belt as the painter draws it — outline included.
  ///
  /// The border counts. It is stroked *on* the band's edge, so half of its
  /// width is ink beyond the band, and it is the one length in the drawing
  /// that does not scale with the box. Leaving it out of the measurement is
  /// what let a fitted belt lay a hairline over the edge of its own box.
  static Rect _inkBounds(ConveyorPathGeometry g) {
    const border = ConveyorPainter._borderWidth;
    final band = g.bandOutline(0, 1,
        width: g.beltWidth,
        radius: g.beltWidth * ConveyorPainter._endRadiusFactor);
    if (band != null) return band.getBounds().inflate(border / 2);
    // Too wide for its own bend: the painter strokes the centerline instead,
    // at `beltWidth + 2 * border` and with round caps, so its ink reaches
    // half a belt plus a whole border out from the curve.
    return _curveBounds(g).inflate(g.beltWidth / 2 + border);
  }

  /// Tight bounds of the centerline, sampled off the path.
  ///
  /// Not `Path.getBounds`, which is a control-point estimate and only an
  /// upper one. On a skeleton this branch has stretched hard the two differ
  /// enormously — a U-turn in a 400px box reported a rect 90px taller than
  /// any ink in it — and a fit aimed at that shrinks the belt away from the
  /// box it is supposed to be filling.
  static Rect _curveBounds(ConveyorPathGeometry g) {
    const samples = 256;
    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    for (var i = 0; i <= samples; i++) {
      final p = g.tangentAt(i / samples).position;
      if (!p.dx.isFinite || !p.dy.isFinite) continue;
      if (p.dx < minX) minX = p.dx;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dy > maxY) maxY = p.dy;
    }
    if (!minX.isFinite || !minY.isFinite) return g.path.getBounds();
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  /// Passes of the ink fit. Each shrinks the remaining shortfall by roughly
  /// the fraction of the ink the band contributes, so the tail is geometric
  /// and short: six take a U-turn from 92%/68% of its box onto its clearance
  /// rect to within a thousandth, and gentler belts trip the convergence
  /// check after one or two.
  static const _inkFitPasses = 6;

  /// How much of the box the centerline's own rect has to be worth before
  /// the two axes are fitted separately. Below this the box is all belt.
  static const _perAxisFloor = 0.1;

  /// Stretch the centerline until the belt's *ink* fills [size], per axis.
  ///
  /// Solved by iteration rather than in closed form: the ink is the
  /// centerline offset sideways by half a belt, and that offset does not
  /// scale with the centerline, so scaling the centerline by k does not
  /// scale the ink by k. Each pass lands the ink closer to its box; see
  /// [_inkFitPasses] for how many it takes.
  static ConveyorPathGeometry _fillBoxWithInk(
      ConveyorPathGeometry g, Size size, double margin) {
    // Proportional, and only proportional. Everything the fit does has to be
    // a function of the box's *shape*, never of how many pixels it happens
    // to be: the moment an absolute clearance enters here it lands in
    // `scale` and `minTurnRadius` with it, and a belt near the fold
    // threshold starts swapping between a drawn band and a stroked
    // centerline as the window is resized — the very defect `minTurnRadius`
    // was made exact to kill. Aiming at a clearance that included the fixed
    // 2px border moved the fold ratio by 0.2% between sizes. The
    // half-border that falls outside the band is accounted for where it
    // belongs, in the `containable` cap on the belt's own width.
    final target = Size(max(size.width - 2 * margin, 0.0),
        max(size.height - 2 * margin, 0.0));
    // A belt wider than its own box cannot be made to fit by moving the
    // centerline — the band alone overflows. It spills by design, and
    // pulling the centerline in to make room for the spill only collapses
    // the bend into a blob.
    if (target.shortestSide <= g.beltWidth) return g;

    var current = g;
    var applied = 1.0;
    for (var pass = 0; pass < _inkFitPasses; pass++) {
      final ink = _inkBounds(current);
      if (!ink.width.isFinite ||
          !ink.height.isFinite ||
          ink.width <= 1e-6 ||
          ink.height <= 1e-6) {
        return current;
      }
      final gx = target.width / ink.width;
      final gy = target.height / ink.height;
      if (!gx.isFinite || !gy.isFinite || gx <= 0 || gy <= 0) return current;
      // Close enough that another pass would move the belt by less than a
      // pixel on any box anyone draws.
      if ((gx - 1).abs() < 1e-3 && (gy - 1).abs() < 1e-3) break;
      // Scale about the ink's centre and land that centre on the box's, so
      // the belt stays centered as it grows.
      final next = current.path.transform(Matrix4(
        gx, 0, 0, 0, //
        0, gy, 0, 0, //
        0, 0, 1, 0, //
        size.width / 2 - ink.center.dx * gx,
        size.height / 2 - ink.center.dy * gy,
        0,
        1,
      ).storage);
      final metrics = next.computeMetrics().toList();
      if (metrics.isEmpty) return current;
      applied *= min(gx, gy);
      // `scale` and the bend radius describe the belt as a whole, so they
      // track the axis that moved least: the tightest bend on screen is
      // bounded by the axis that grew the least.
      current = ConveyorPathGeometry._(next, current.beltWidth,
          g.scale * applied, g.minTurnRadius * applied, metrics.first);
    }
    return current;
  }
}

@JsonSerializable(explicitToJson: true)
class ConveyorColorPaletteConfig extends BaseAsset {
  @override
  String get displayName => 'Conveyor Palette';
  @override
  String get category => 'Visualization';

  ConveyorColorPaletteConfig();
  bool? preview = false;

  @override
  Widget build(BuildContext context) => ConveyorColorPalette(config: this);

  @override
  Widget configure(BuildContext context) {
    return Column(
      children: [
        SizeField(
          initialValue: size,
          onChanged: (size) => this.size = size,
        ),
        const SizedBox(height: 16),
        CoordinatesField(
          initialValue: coordinates,
          onChanged: (coordinates) => this.coordinates = coordinates,
          enableAngle: true,
        ),
      ],
    );
  }

  ConveyorColorPaletteConfig.preview() : preview = true;

  factory ConveyorColorPaletteConfig.fromJson(Map<String, dynamic> json) =>
      _$ConveyorColorPaletteConfigFromJson(json);
  Map<String, dynamic> toJson() => _$ConveyorColorPaletteConfigToJson(this);
}

/// How the belt itself is drawn. The logic around it — keys, drive-state
/// colours, batches, turns, gates, the operator pane — is identical for
/// every style; only the band's rendering differs.
enum ConveyorStyle {
  /// The classic solid band.
  box,

  /// A roller conveyor: rollers across the belt on a darker bed. The state
  /// colour moves onto the rollers, so the colour vocabulary is unchanged.
  roller,
}

/// How a conveyor's drive reads.
///
/// [running] is the boolean-driven equivalent of [auto]: the belt is moving,
/// and that is all the bit says. It is a separate value from [auto] so the
/// decode stays honest about where the answer came from, but both mean the
/// same thing on screen.
enum DriveState { fault, stopped, auto, manual, clean, running, unknown }

/// Reads a drive value, whether it is an `FB_ATV320` HMI struct or a plain
/// BOOL.
///
/// A struct is preferred and answers with its `p_stat_RunMode`. A plain bool
/// answers running/stopped. Anything else is [DriveState.unknown] rather than
/// a guess — reading a frequency or a string as "stopped" would paint a belt
/// grey that nobody has any information about.
DriveState readDriveState(DynamicValue? value) {
  if (value == null) return DriveState.unknown;
  try {
    final mode = value['p_stat_RunMode'];
    final name = mode.enumFields?[mode.asInt]?.name;
    switch (name) {
      case 'fault':
        return DriveState.fault;
      case 'stopped':
        return DriveState.stopped;
      case 'auto':
        return DriveState.auto;
      case 'manual':
        return DriveState.manual;
      case 'clean':
        return DriveState.clean;
    }
    return DriveState.unknown;
  } catch (_) {
    // Not a drive struct; fall through to the plain-bool reading.
  }
  if (value.value is bool) {
    return value.value as bool ? DriveState.running : DriveState.stopped;
  }
  return DriveState.unknown;
}

/// Whether [state] means the belt is moving.
bool driveStateIsMoving(DriveState state) =>
    state == DriveState.auto || state == DriveState.running;

/// Reads a safety-edge value, whether it is an `ST_Sensor_HMI` struct (an
/// FB_Sensor over OPC UA) or a plain BOOL.
///
/// A struct answers with its debounced output — and a faulted sensor also
/// reads as pressed: a safety edge whose sensor is broken must fail safe,
/// not quietly disarm. A plain bool answers with itself. Anything else is
/// not pressed — the edge only claims a press it can stand behind.
bool readSafetyEdge(DynamicValue? value) {
  if (value == null) return false;
  final fb = SensorFbState.tryParse(value);
  if (fb != null) return fb.output || fb.fault;
  if (value.value is bool) return value.value as bool;
  return false;
}

/// Maps a decoded [DriveState] onto the themed equipment-state colours —
/// the one vocabulary every conveyor-drawn drive answers in, belt and
/// wagon traverse motor alike.
Color driveStateColor(HmiStateColors states, DriveState state) {
  switch (state) {
    case DriveState.fault:
      return states.red;
    case DriveState.stopped:
      return states.grey;
    case DriveState.auto:
    // A boolean-driven drive looks the same as a struct-driven one in
    // auto. Giving it a colour of its own would say something about the
    // drive that the bit does not carry.
    case DriveState.running:
      return states.green;
    case DriveState.manual:
      return states.yellow;
    case DriveState.clean:
      return states.blue;
    case DriveState.unknown:
      return states.violet;
  }
}

class ConveyorColorPalette extends StatelessWidget {
  final ConveyorColorPaletteConfig config;
  const ConveyorColorPalette({required this.config});

  @override
  Widget build(BuildContext context) {
    // First, compute the exact width/height we want from config.size:
    final size = config.size.toSize(MediaQuery.of(context).size);
    final states = HmiStateColors.of(context);

    return SizedBox(
      width: size.width,
      height: size.height,
      child: Column(
        children: [
          // ─── Top "title" row ───
          const Expanded(
            flex: 1,
            child: AutoSizedText(
              'Conveyor colors',
              heightFraction: 0.6,
              shrinkOnly: true,
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),

          Expanded(
            flex: 5,
            child: Column(
              children: [
                _buildColorRow(states.green, 'Auto', textColor: states.onState),
                _buildColorRow(states.blue, 'Clean',
                    textColor: states.onState),
                _buildColorRow(states.yellow, 'Manual',
                    textColor: states.onState),
                _buildColorRow(states.grey, 'Stopped',
                    textColor: states.onState),
                _buildColorRow(states.red, 'Fault',
                    textColor: states.onState),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Helper that returns an Expanded widget wrapping a padded Container of a given color,
  /// with text that always fills/shrinks to fit that container.
  Widget _buildColorRow(Color background, String label,
      {required Color textColor}) {
    return Expanded(
      flex: 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
        child: Container(
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(4),
          ),
          // Sized for the row rather than scaled into it: see AutoSizedText.
          //
          // shrinkOnly because this is a legend, not a button face. Without
          // it the label fills its swatch, and a palette of five colours
          // reads as five giant captions -- which is what happened when the
          // FittedBox(scaleDown) here became a plain AutoSizedText.
          child: AutoSizedText(
            label,
            heightFraction: 0.6,
            shrinkOnly: true,
            style: TextStyle(
              color: textColor,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}

@JsonSerializable(explicitToJson: true)
class ConveyorConfig extends BaseAsset {
  @override
  String get displayName => 'Conveyor';
  @override
  String get category => 'Visualization';

  /// The belt is pure geometry and its turns are chiral: on a mirrored
  /// station a left bend must become a right bend, or the page shows a belt
  /// that does not exist on the floor. The frequency/exclamation overlays
  /// counter-mirror inside [ConveyorPainter], so no text flips with it.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  bool get mirrorsWithPage => true;

  String? key;
  String? batchesKey;
  String? frequencyKey;
  String? tripKey;

  /// Optional plain BOOL key: true while the belt is running.
  ///
  /// For belts that have no `FB_ATV320` HMI struct to bind [key] to — the
  /// ones driven over Modbus from the pallet system, for instance — a single
  /// "is running" bit is all the PLC offers. Consulted only when [key] yields
  /// nothing usable, so a drive struct always wins where there is one.
  String? runningKey;

  bool? simulateBatches;
  bool? bidirectional;
  bool? reverseDirection;
  bool? showFrequency;
  bool? showAuger;
  String? augerRpmKey;
  AugerOpenEnd? augerOpenEnd;

  /// Draws the belt as a wagon on rails: wheels and a rail under the band,
  /// for shuttle conveyors that travel on a track. Straight belts only — a
  /// turned belt has no single underside to put wheels on.
  bool? onRails;

  /// PLC key emitting the wagon's raw 0..100% position along the rail —
  /// same convention as the elevator's position key. 0% is the left end of
  /// the box (before the asset's own rotation/mirror). Only read while
  /// [railsActive]; without it the wagon parks mid-rail.
  String? positionKey;

  /// Drive key of the traverse motor — the one that moves the wagon along
  /// the rail, as opposed to [key] which runs the belt on it. Same
  /// `FB_ATV320` struct decode: its state colours the wagon's chassis, and
  /// tapping the chassis opens its pane, where the jog buttons drive the
  /// wagon down the track. Only read while [railsActive].
  String? wagonMotorKey;

  /// Lay the wagon's belt along the rails instead of across them. Default
  /// (null/false) is across — the classic transfer wagon handing off
  /// sideways; along suits a shuttle that conveys in its own travel
  /// direction.
  bool? beltAlongRails;

  /// Keys for the safety edges on the wagon's two moving sides — a plain
  /// BOOL (true = pressed) or an `FB_Sensor` HMI struct, decoded by
  /// [readSafetyEdge] (a faulted sensor reads as pressed — fail safe).
  /// Idle they draw nothing; tripped, the bumper on that side lights up in
  /// fault red. Only read while [railsActive]. Left/right are in the
  /// asset's own frame, before its rotation or the page mirror — the same
  /// convention the geometry uses.
  String? safetyLeftKey;
  String? safetyRightKey;

  /// The wagon's footprint along the rail run, as a fraction of the box
  /// width. The belt conveys across the rails, so this is the belt's width.
  /// Null falls back to [_defaultWagonLength].
  double? wagonLength;

  static const _defaultWagonLength = 0.25;

  @JsonKey(includeFromJson: false, includeToJson: false)
  double get effectiveWagonLength =>
      (wagonLength ?? _defaultWagonLength).clamp(0.05, 1.0);

  /// Which band renderer this asset paints with. Fixed per asset type — the
  /// roller variant overrides it — so it is not stored in the page JSON;
  /// `asset_name` already decides it.
  @JsonKey(includeFromJson: false, includeToJson: false)
  ConveyorStyle get style => ConveyorStyle.box;

  /// Whether the wagon undercarriage is actually drawn: [onRails] is set and
  /// nothing that replaces the straight band (turns, the auger renderer) is
  /// in effect.
  @JsonKey(includeFromJson: false, includeToJson: false)
  bool get railsActive =>
      (onRails ?? false) && turns.isEmpty && !(showAuger ?? false);

  @JsonKey(fromJson: _gatesFromJson, toJson: _gatesToJson)
  List<ChildGateEntry> gates;

  /// Bends along the belt; empty means a straight conveyor.
  List<ConveyorTurnEntry> turns;

  /// Belt thickness as a fraction of the box height (turned conveyors only).
  ///
  /// A bend needs a taller bounding box, which with the straight convention
  /// (belt thickness = box height) would force a fat belt.
  double? beltThickness;

  /// Thickness actually used for rendering.
  ///
  /// A straight belt keeps the old convention of filling the box height. A
  /// turned belt cannot: the bend needs vertical room *on top of* the belt
  /// thickness, and at 1.0 there is none left, so the belt degenerates into a
  /// blob. Defaulting turned belts to a fraction of the box keeps a freshly
  /// added turn usable without touching a second setting.
  double get effectiveBeltThickness =>
      beltThickness ?? (turns.isEmpty ? 1.0 : _defaultTurnedThickness);

  static const _defaultTurnedThickness = 0.4;

  /// Belt width as a fraction of the screen height — the same units as
  /// [size], so a straight belt set to 4% and a turned belt set to 4% paint
  /// the same width and line up on a page.
  ///
  /// Applies with or without turns. Null falls back to [beltThickness] /
  /// [effectiveBeltThickness], which are relative to the box instead.
  double? beltWidthRelative;

  /// Requested belt width in logical pixels, or null when the box-relative
  /// thickness should be used instead.
  double? requestedBeltWidth(Size screen) =>
      beltWidthRelative == null ? null : beltWidthRelative! * screen.height;

  /// The widest belt this asset's box can hold. A belt is a band across the
  /// box, and a turned belt curves in both axes, so a bend is bounded by the
  /// short side rather than the height.
  double maxBeltWidth(Size screen) {
    final box = size.toSize(screen);
    return max((turns.isEmpty ? box.height : box.shortestSide) - 4, 1.0);
  }

  /// Whether the requested belt width is wider than its box, so the belt
  /// paints over the box edge and the editor should say so.
  ///
  /// The width itself is still honoured — it is set in screen units, and a
  /// setting that quietly changed whenever the box was resized would not be
  /// worth having. Only selection and hit-testing stay on the box.
  bool beltWidthOverflows(Size screen) {
    final requested = requestedBeltWidth(screen);
    return requested != null && requested > maxBeltWidth(screen);
  }

  ConveyorConfig(
      {this.key,
      this.batchesKey,
      this.frequencyKey,
      this.tripKey,
      this.runningKey,
      this.simulateBatches,
      this.bidirectional,
      this.reverseDirection,
      this.showFrequency,
      this.showAuger,
      this.augerRpmKey,
      this.augerOpenEnd,
      this.onRails,
      this.positionKey,
      this.wagonMotorKey,
      this.beltAlongRails,
      this.safetyLeftKey,
      this.safetyRightKey,
      this.wagonLength,
      this.beltThickness,
      List<ChildGateEntry>? gates,
      List<ConveyorTurnEntry>? turns})
      : gates = gates != null ? List<ChildGateEntry>.of(gates) : [],
        turns = turns != null ? List<ConveyorTurnEntry>.of(turns) : [];

  static const previewStr = 'Conveyor Preview';

  ConveyorConfig.preview()
      : gates = [],
        turns = [],
        key = previewStr;

  @override
  Widget build(BuildContext context) => Conveyor(this);

  @override
  Widget configure(BuildContext context) {
    return SingleChildScrollView(
      child: Container(
        width: 300,
        padding: const EdgeInsets.all(16),
        child: _ConveyorConfigContent(config: this),
      ),
    );
  }

  factory ConveyorConfig.fromJson(Map<String, dynamic> json) =>
      _$ConveyorConfigFromJson(json);
  Map<String, dynamic> toJson() => _$ConveyorConfigToJson(this);
}

/// A conveyor drawn as rollers instead of a solid band.
///
/// Only the paint differs: every key binding, the drive-state colour
/// vocabulary, batches, turns, gates and the operator pane are
/// [ConveyorConfig]'s, inherited unchanged — so the two asset types stay in
/// step by construction rather than by parallel maintenance.
@JsonSerializable(explicitToJson: true)
class RollerConveyorConfig extends ConveyorConfig {
  @override
  String get displayName => 'Roller Conveyor';

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  List<String> get searchKeywords => const ['roller', 'rollers'];

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  ConveyorStyle get style => ConveyorStyle.roller;

  RollerConveyorConfig(
      {super.key,
      super.batchesKey,
      super.frequencyKey,
      super.tripKey,
      super.runningKey,
      super.simulateBatches,
      super.bidirectional,
      super.reverseDirection,
      super.showFrequency,
      super.showAuger,
      super.augerRpmKey,
      super.augerOpenEnd,
      super.onRails,
      super.positionKey,
      super.wagonMotorKey,
      super.beltAlongRails,
      super.safetyLeftKey,
      super.safetyRightKey,
      super.wagonLength,
      super.beltThickness,
      super.gates,
      super.turns});

  RollerConveyorConfig.preview() : super.preview();

  factory RollerConveyorConfig.fromJson(Map<String, dynamic> json) =>
      _$RollerConveyorConfigFromJson(json);
  @override
  Map<String, dynamic> toJson() => _$RollerConveyorConfigToJson(this);
}

class _ConveyorConfigContent extends StatefulWidget {
  final ConveyorConfig config;
  const _ConveyorConfigContent({required this.config});

  @override
  State<_ConveyorConfigContent> createState() => _ConveyorConfigContentState();
}

class _ConveyorConfigContentState extends State<_ConveyorConfigContent> {
  @override
  void initState() {
    super.initState();
    // Pages saved before turns were kept in belt order.
    _sortTurns();
    _pinBeltWidth();
  }

  /// Makes the belt width of a turned belt an explicit number.
  ///
  /// A turned belt has exactly one width knob — the screen-relative field.
  /// Configs from before that field existed carry a box-relative thickness
  /// instead, whose meaning shifts every time the box is resized; freeze
  /// what it currently resolves to so the panel always shows one number and
  /// the render never moves behind the user's back.
  void _pinBeltWidth() {
    if (widget.config.turns.isEmpty) return;
    widget.config.beltWidthRelative ??=
        widget.config.effectiveBeltThickness * widget.config.size.height;
  }

  /// Keeps [ConveyorConfig.turns] in the order the belt actually bends.
  ///
  /// [ConveyorPathGeometry.build] sorts by position, so the belt's first bend
  /// is the lowest position. The panel listed insertion order and numbered
  /// the cards from it, and "Add Turn" appends — so as soon as a turn was
  /// added after an earlier one had been dragged along the belt, "Turn 1" in
  /// the panel was some other bend, and its delete button took out a turn the
  /// user was not looking at.
  ///
  /// Sorting the list itself rather than a display copy keeps the card order
  /// stable while a position slider is being dragged; the reorder happens
  /// once the drag ends.
  void _sortTurns() {
    widget.config.turns.sort((a, b) => a.position.compareTo(b.position));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        KeyField(
          initialValue: widget.config.key,
          onChanged: (val) => setState(() => widget.config.key = val),
          label: 'Main key (optional)',
        ),
        const SizedBox(height: 8),
        KeyField(
          initialValue: widget.config.batchesKey,
          onChanged: (val) => setState(() => widget.config.batchesKey = val),
          label: 'Batches key',
        ),
        const SizedBox(height: 8),
        KeyField(
          initialValue: widget.config.frequencyKey,
          onChanged: (val) => setState(() => widget.config.frequencyKey = val),
          label: 'Frequency key',
        ),
        const SizedBox(height: 8),
        KeyField(
          initialValue: widget.config.tripKey,
          onChanged: (val) => setState(() => widget.config.tripKey = val),
          label: 'Trip key',
        ),
        const SizedBox(height: 8),
        KeyField(
          initialValue: widget.config.runningKey,
          onChanged: (val) => setState(() => widget.config.runningKey = val),
          label: 'Running key (plain true/false)',
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            const Text('Simulate batches:'),
            const SizedBox(width: 8),
            Checkbox(
                value: widget.config.simulateBatches ?? false,
                onChanged: (val) =>
                    setState(() => widget.config.simulateBatches = val)),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Text('Bidirectional:'),
            const SizedBox(width: 8),
            Checkbox(
                value: widget.config.bidirectional ?? false,
                onChanged: (val) =>
                    setState(() => widget.config.bidirectional = val)),
          ],
        ),
        if (widget.config.bidirectional ?? false) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('Reverse direction:'),
              const SizedBox(width: 8),
              Checkbox(
                  value: widget.config.reverseDirection ?? false,
                  onChanged: (val) =>
                      setState(() => widget.config.reverseDirection = val)),
            ],
          ),
        ],
        const SizedBox(height: 8),
        Row(
          children: [
            const Text('Show frequency:'),
            const SizedBox(width: 8),
            Checkbox(
                value: widget.config.showFrequency ?? false,
                onChanged: (val) =>
                    setState(() => widget.config.showFrequency = val)),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Text('On rails (wagon):'),
            const SizedBox(width: 8),
            Checkbox(
                value: widget.config.onRails ?? false,
                onChanged: (val) =>
                    setState(() => widget.config.onRails = val)),
          ],
        ),
        if ((widget.config.onRails ?? false) &&
            !widget.config.railsActive) ...[
          Text(
              'Rails are hidden while turns or the auger renderer are '
              'configured — a wagon is a straight belt.',
              style: Theme.of(context).textTheme.bodySmall),
        ],
        if (widget.config.onRails ?? false) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('Belt along rails:'),
              const SizedBox(width: 8),
              Checkbox(
                  value: widget.config.beltAlongRails ?? false,
                  onChanged: (val) =>
                      setState(() => widget.config.beltAlongRails = val)),
            ],
          ),
          const SizedBox(height: 8),
          KeyField(
            initialValue: widget.config.positionKey,
            onChanged: (val) =>
                setState(() => widget.config.positionKey = val),
            label: 'Wagon position key (0-100%)',
          ),
          const SizedBox(height: 8),
          KeyField(
            initialValue: widget.config.wagonMotorKey,
            onChanged: (val) =>
                setState(() => widget.config.wagonMotorKey = val),
            label: 'Wagon motor key (traverse drive)',
          ),
          const SizedBox(height: 8),
          KeyField(
            initialValue: widget.config.safetyLeftKey,
            onChanged: (val) =>
                setState(() => widget.config.safetyLeftKey = val),
            label: 'Safety edge key, left (BOOL or FB_Sensor)',
          ),
          const SizedBox(height: 8),
          KeyField(
            initialValue: widget.config.safetyRightKey,
            onChanged: (val) =>
                setState(() => widget.config.safetyRightKey = val),
            label: 'Safety edge key, right (BOOL or FB_Sensor)',
          ),
          const SizedBox(height: 8),
          NumberSlider(
            labelAbove: true,
            label: 'Wagon width along rails',
            min: 0.05,
            max: 1.0,
            divisions: 95,
            displayScale: 100,
            suffix: '% of box',
            value: widget.config.effectiveWagonLength,
            onChanged: (v) =>
                setState(() => widget.config.wagonLength = v),
          ),
        ],
        const SizedBox(height: 8),
        Row(
          children: [
            const Text('Auger conveyor:'),
            const SizedBox(width: 8),
            Checkbox(
                value: widget.config.showAuger ?? false,
                onChanged: (val) =>
                    setState(() => widget.config.showAuger = val)),
          ],
        ),
        if (widget.config.showAuger ?? false) ...[
          const SizedBox(height: 8),
          KeyField(
            initialValue: widget.config.augerRpmKey,
            onChanged: (val) => setState(() => widget.config.augerRpmKey = val),
            label: 'Output shaft RPM key',
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('Open end:'),
              const SizedBox(width: 8),
              DropdownButton<AugerOpenEnd?>(
                value: widget.config.augerOpenEnd,
                onChanged: (val) =>
                    setState(() => widget.config.augerOpenEnd = val),
                items: const [
                  DropdownMenuItem(
                      value: AugerOpenEnd.right, child: Text('Right')),
                  DropdownMenuItem(
                      value: AugerOpenEnd.left, child: Text('Left')),
                  DropdownMenuItem(value: null, child: Text('None')),
                ],
              ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        SizeField(
          initialValue: widget.config.size,
          onChanged: (size) => setState(() => widget.config.size = size),
          // The box runs along the belt, so its width is how long the
          // conveyor is and its height is how wide the belt sits.
          widthLabel: 'Length %',
          heightLabel: 'Width %',
        ),
        const SizedBox(height: 16),
        CoordinatesField(
          initialValue: widget.config.coordinates,
          onChanged: (c) => setState(() => widget.config.coordinates = c),
          enableAngle: true,
        ),
        const SizedBox(height: 16),
        const Divider(),
        Text('Gates', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: () {
            setState(() {
              widget.config.gates
                  .add(ChildGateEntry(gate: ConveyorGateConfig()));
            });
          },
          icon: const Icon(Icons.add),
          label: const Text('Add Gate'),
        ),
        const SizedBox(height: 8),
        if (widget.config.gates.isEmpty)
          Text('No gates configured',
              style: Theme.of(context).textTheme.bodyMedium)
        else
          ...widget.config.gates.asMap().entries.map((mapEntry) {
            final entry = mapEntry.value;
            return Card(
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header: variant name + edit/delete
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            entry.gate.gateVariant.name,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.edit, size: 20),
                          tooltip: 'Edit gate',
                          onPressed: () => showStandardDialog<void>(
                            context: context,
                            title: 'Edit gate',
                            icon: Icons.swap_horiz,
                            width: 360,
                            builder: (context) => SizedBox(
                              width: 300,
                              child: entry.gate.configure(context),
                            ),
                          ).then((_) => setState(() {})),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete, size: 20),
                          tooltip: 'Remove gate',
                          onPressed: () => setState(() {
                            widget.config.gates.removeAt(
                              widget.config.gates.indexOf(entry),
                            );
                          }),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    // Side toggle: Top (left) / Bottom (right)
                    Text('Conveyor Side',
                        style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 4),
                    SegmentedButton<GateSide>(
                      segments: const [
                        ButtonSegment(value: GateSide.left, label: Text('Top')),
                        ButtonSegment(
                            value: GateSide.right, label: Text('Bottom')),
                      ],
                      selected: {entry.side},
                      onSelectionChanged: (selection) {
                        setState(() => entry.side = selection.first);
                      },
                    ),
                    const SizedBox(height: 8),
                    // Position slider
                    NumberSlider(
                      labelAbove: true,
                      label: 'Belt Position',
                      min: 0.0,
                      max: 1.0,
                      divisions: 100,
                      displayScale: 100,
                      suffix: '%',
                      value: entry.position,
                      onChanged: (v) => setState(() => entry.position = v),
                    ),
                  ],
                ),
              ),
            );
          }),
        const SizedBox(height: 16),
        const Divider(),
        Text('Turns', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: () {
            setState(() {
              widget.config.turns.add(ConveyorTurnEntry(
                position: ConveyorTurnEntry.freePosition(widget.config.turns),
              ));
              _sortTurns();
              _pinBeltWidth();
            });
          },
          icon: const Icon(Icons.add),
          label: const Text('Add Turn'),
        ),
        const SizedBox(height: 8),
        _beltWidthField(context),
        const SizedBox(height: 8),
        if (widget.config.turns.isEmpty)
          Text('No turns configured — belt is straight',
              style: Theme.of(context).textTheme.bodyMedium)
        else ...[
          if (widget.config.showAuger ?? false)
            Text('Turns are ignored while "Auger conveyor" is enabled',
                style: Theme.of(context).textTheme.bodySmall),
          ...widget.config.turns.asMap().entries.map((mapEntry) {
            final entry = mapEntry.value;
            return Card(
              // Identity, not index: ending a position drag can reorder the
              // cards, and the element state has to follow its own turn.
              key: ObjectKey(entry),
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Turn ${mapEntry.key + 1}',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete, size: 20),
                          tooltip: 'Remove turn',
                          onPressed: () => setState(() {
                            widget.config.turns.remove(entry);
                          }),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    _turnValue(
                      context,
                      label: 'Belt position',
                      suffix: '%',
                      value: entry.position.clamp(0.0, 1.0) * 100,
                      min: 0,
                      max: 100,
                      divisions: 100,
                      decimals: 0,
                      onChanged: (v) =>
                          setState(() => entry.position = v / 100),
                      // Dragging a turn past a neighbour changes which bend
                      // it is; renumber once the drag is over rather than
                      // shuffling cards under the pointer.
                      onSettled: () => setState(_sortTurns),
                    ),
                    _turnValue(
                      context,
                      label: 'Angle (${entry.angle >= 0 ? 'down' : 'up'})',
                      suffix: '°',
                      value: entry.angle.clamp(-180.0, 180.0),
                      min: -180,
                      max: 180,
                      divisions: 72,
                      decimals: 0,
                      onChanged: (v) => setState(() => entry.angle = v),
                    ),
                    _turnValue(
                      context,
                      label: 'Radius (× belt width)',
                      suffix: '×',
                      value: entry.radius.clamp(0.5, 5.0),
                      min: 0.5,
                      max: 5.0,
                      divisions: 45,
                      decimals: 1,
                      onChanged: (v) => setState(() => entry.radius = v),
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ],
    );
  }

  /// One turn setting: a label, a box you can type an exact value into, and a
  /// slider for the same number.
  ///
  /// The slider alone could not express a value between its divisions, and
  /// reading a turn back off a slider is guesswork — the box is the one that
  /// says what the turn actually is.
  Widget _turnValue(
    BuildContext context, {
    required String label,
    required String suffix,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required int decimals,
    required ValueChanged<double> onChanged,
    VoidCallback? onSettled,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label, style: Theme.of(context).textTheme.bodySmall),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 78,
              child: _NumberBox(
                value: value,
                min: min,
                max: max,
                decimals: decimals,
                suffix: suffix,
                onChanged: onChanged,
                onSettled: onSettled,
              ),
            ),
          ],
        ),
        Slider(
          min: min,
          max: max,
          divisions: divisions,
          value: value.clamp(min, max),
          label: value.toStringAsFixed(decimals),
          onChanged: onChanged,
          onChangeEnd: onSettled == null ? null : (_) => onSettled(),
        ),
      ],
    );
  }

  /// Belt width in the same screen-relative percent as the Size fields, so a
  /// straight belt and a turned belt set to the same number match on a page.
  /// Empty falls back to the box-relative thickness.
  Widget _beltWidthField(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    final overflows = widget.config.beltWidthOverflows(screen);
    final maxPercent = widget.config.maxBeltWidth(screen) / screen.height * 100;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextFormField(
          initialValue: widget.config.beltWidthRelative == null
              ? ''
              : (widget.config.beltWidthRelative! * 100).toStringAsFixed(2),
          decoration: InputDecoration(
            labelText: 'Belt width (% of screen height)',
            hintText: 'Empty — belt fills the box',
            suffixText: '%',
            errorText: overflows
                ? 'Wider than the box (fits ${maxPercent.toStringAsFixed(2)}%) '
                    '— the belt is painted at the width you set and spills '
                    'over the box, which still owns selection and clicks.'
                : null,
          ),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (v) => setState(() {
            final parsed = double.tryParse(v.trim().replaceAll(',', '.'));
            widget.config.beltWidthRelative =
                parsed == null || parsed <= 0 ? null : parsed / 100;
          }),
        ),
      ],
    );
  }
}

/// A compact number box that stays in step with the slider beside it.
///
/// The value is pushed in from outside only while the box is not being
/// edited, so a keystroke is never overwritten mid-word, and what is typed is
/// clamped into the same range the slider covers.
class _NumberBox extends StatefulWidget {
  final double value;
  final double min;
  final double max;
  final int decimals;
  final String suffix;
  final ValueChanged<double> onChanged;
  final VoidCallback? onSettled;

  const _NumberBox({
    required this.value,
    required this.min,
    required this.max,
    required this.decimals,
    required this.suffix,
    required this.onChanged,
    this.onSettled,
  });

  @override
  State<_NumberBox> createState() => _NumberBoxState();
}

class _NumberBoxState extends State<_NumberBox> {
  late final TextEditingController _controller =
      TextEditingController(text: _format(widget.value));
  late final FocusNode _focus = FocusNode()..addListener(_onFocusChange);

  String _format(double v) => v.toStringAsFixed(widget.decimals);

  @override
  void didUpdateWidget(_NumberBox old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && _format(widget.value) != _controller.text) {
      _controller.text = _format(widget.value);
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (_focus.hasFocus) return;
    // Leaving the box tidies whatever was typed back into range, and settles
    // the value the same way letting go of the slider does.
    _controller.text = _format(widget.value);
    widget.onSettled?.call();
  }

  void _submit(String raw) {
    final parsed = double.tryParse(raw.trim().replaceAll(',', '.'));
    if (parsed == null) return;
    widget.onChanged(parsed.clamp(widget.min, widget.max));
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: _focus,
      textAlign: TextAlign.end,
      style: Theme.of(context).textTheme.bodySmall,
      decoration: InputDecoration(
        isDense: true,
        suffixText: widget.suffix,
        contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        border: const OutlineInputBorder(),
      ),
      keyboardType: TextInputType.numberWithOptions(
          decimal: widget.decimals > 0, signed: widget.min < 0),
      onChanged: _submit,
      onSubmitted: (v) {
        _submit(v);
        widget.onSettled?.call();
      },
    );
  }
}

/// Reports a repeating failure once instead of once per rebuild.
///
/// A `StreamBuilder`'s `builder` runs on every rebuild, not only when the
/// stream has something new to say, and a stream that has failed keeps
/// handing back the same error every time. Logging straight out of the
/// builder therefore writes a line per rebuild rather than a line per
/// failure.
///
/// The error still reaches the log the moment it happens, and again if it
/// changes or comes back after a recovery. It is the repetition that carries
/// no information.
class RepeatedErrorGate {
  String? _reported;
  bool _hasReported = false;

  /// Whether [error] is worth writing down: true the first time it is seen,
  /// and thereafter only when it differs from the last one reported.
  bool shouldReport(Object? error) {
    final seen = error?.toString();
    if (_hasReported && seen == _reported) return false;
    _hasReported = true;
    _reported = seen;
    return true;
  }

  /// Forget what was reported, so a failure that returns after the stream
  /// recovers is reported again rather than silently swallowed.
  void recovered() {
    _hasReported = false;
    _reported = null;
  }
}

class Conveyor extends ConsumerStatefulWidget {
  final ConveyorConfig config;
  const Conveyor(this.config, {Key? key}) : super(key: key);

  @override
  ConsumerState<Conveyor> createState() => _ConveyorState();
}

class _ConveyorState extends ConsumerState<Conveyor>
    with TickerProviderStateMixin {
  static final _log = Logger(
    printer: PrettyPrinter(
      methodCount: 0,
      errorMethodCount: 2,
      lineLength: 80,
      colors: true,
      printEmojis: false,
    ),
  );
  final Map<String, Batch> _batches = {};
  final RepeatedErrorGate _errorGate = RepeatedErrorGate();
  Stream<Map<String, DynamicValue>>? _cachedValues;
  int? _cachedValuesSignature;
  // periodic timer for batches
  Timer? _simulateBatchesTimer;

  // Auger animation — ValueNotifier repaints only the CustomPaint, no setState
  final ValueNotifier<double> _augerPhase = ValueNotifier(0.0);
  Timer? _augerAnimationTimer;
  double _augerRpm = 0.0;

  void _updateAugerAnimation(double rpm) {
    _augerRpm = rpm;
    if (rpm != 0 && _augerAnimationTimer == null) {
      _augerAnimationTimer =
          Timer.periodic(const Duration(milliseconds: 32), (_) {
        if (!mounted) {
          _augerAnimationTimer?.cancel();
          _augerAnimationTimer = null;
          return;
        }
        var phase = _augerPhase.value + _augerRpm / 60.0 * 2 * pi * 0.032;
        if (phase > 2 * pi) phase -= 2 * pi;
        if (phase < -2 * pi) phase += 2 * pi;
        _augerPhase.value = phase;
      });
    } else if (rpm == 0 && _augerAnimationTimer != null) {
      _augerAnimationTimer?.cancel();
      _augerAnimationTimer = null;
    }
  }

  @override
  void dispose() {
    // A docked pane outlives the route that opened it, so a page change must
    // not leave this conveyor's pane behind.
    for (final driveKey in _paneDriveKeys) {
      closeSidePane(id: _paneIdFor(driveKey), immediate: true);
    }
    _augerAnimationTimer?.cancel();
    _augerPhase.dispose();
    _simulateBatchesTimer?.cancel();
    super.dispose();
  }

  void _startSimulateBatchesTimer() {
    _simulateBatchesTimer ??=
        Timer.periodic(const Duration(milliseconds: 20), (timer) {
      if (_batches.isNotEmpty) {
        final batch = _batches.values.first;
        batch.start += 0.01;
        batch.end += 0.01;
        if (batch.start >= 1) {
          _batches.clear();
        }
      } else {
        // length 10 % of conveyor
        _batches['0'] = Batch(start: -0.1, end: 0, color: Colors.yellow);
      }
      if (mounted) {
        setState(() {});
      } else {
        _simulateBatchesTimer?.cancel();
      }
    });
  }

  void _stopSimulateBatchesTimer() {
    _simulateBatchesTimer?.cancel();
  }

  Color _getConveyorColor(HmiStateColors states,
      {DynamicValue? driveValue,
      DynamicValue? runningValue,
      DynamicValue? frequencyValue,
      DynamicValue? tripValue}) {
    try {
      // Trip is still checked first, below, so this only handles the shape of
      // the drive value itself.
      // Check trip condition first if trip key is provided
      if (tripValue != null) {
        try {
          final isTripped = tripValue.asBool;
          if (isTripped) {
            return states.red; // Trip condition overrides everything
          }
        } catch (_) {
          // If trip value can't be read as bool, continue with normal logic
        }
      }

      // Drive struct first where there is one; the running bit only answers
      // when the struct is absent or says nothing useful.
      var reading = readDriveState(driveValue);
      if (reading == DriveState.unknown && runningValue != null) {
        reading = readDriveState(runningValue);
      }
      if (reading != DriveState.unknown) {
        return driveStateColor(states, reading);
      }
      if (driveValue != null) return states.violet;

      // If we only have frequency and trip, use frequency-based logic
      if (frequencyValue != null) {
        try {
          final frequency = frequencyValue.asDouble;
          if (frequency != 0) {
            return states.green; // Running
          } else {
            return states.grey;
          }
        } catch (_) {
          return states.violet; // Error reading frequency
        }
      }

      return states.grey; // Default fallback
    } catch (_) {
      return states.violet;
    }
  }

  @override
  Widget build(BuildContext context) {
    final states = HmiStateColors.of(context);
    if (widget.config.key == ConveyorConfig.previewStr) {
      return _buildConveyorVisual(context, states.grey);
    }

    // The "Simulate batches" toggle is independent of any PLC stream — it
    // must drive the timer even when no keys are configured and even before
    // the first stream tick arrives. Evaluate it here, outside StreamBuilder.
    if (widget.config.simulateBatches ?? false) {
      _startSimulateBatchesTimer();
    } else {
      _stopSimulateBatchesTimer();
    }

    // Which keys this conveyor reads, and the label the builder finds each
    // one under.
    final bindings = <({String label, String key, bool optional})>[
      if (_bound(widget.config.key))
        (label: 'drive', key: widget.config.key!, optional: false),
      if (_bound(widget.config.batchesKey))
        (label: 'batches', key: widget.config.batchesKey!, optional: true),
      if (_bound(widget.config.frequencyKey))
        (label: 'frequency', key: widget.config.frequencyKey!, optional: true),
      if (_bound(widget.config.runningKey))
        (label: 'running', key: widget.config.runningKey!, optional: true),
      if (_bound(widget.config.tripKey))
        (label: 'trip', key: widget.config.tripKey!, optional: true),
      if (_bound(widget.config.augerRpmKey))
        (label: 'augerRpm', key: widget.config.augerRpmKey!, optional: true),
      if (widget.config.railsActive && _bound(widget.config.positionKey))
        (label: 'position', key: widget.config.positionKey!, optional: true),
      if (widget.config.railsActive && _bound(widget.config.wagonMotorKey))
        (label: 'wagonMotor', key: widget.config.wagonMotorKey!,
            optional: true),
      if (widget.config.railsActive && _bound(widget.config.safetyLeftKey))
        (label: 'safetyLeft', key: widget.config.safetyLeftKey!,
            optional: true),
      if (widget.config.railsActive && _bound(widget.config.safetyRightKey))
        (label: 'safetyRight', key: widget.config.safetyRightKey!,
            optional: true),
    ];

    // If no streams are configured, show error state
    if (bindings.isEmpty) {
      return _buildConveyorVisual(context, states.grey,
          showExclamation: true);
    }

    // One shared stream per key, held by [keyStreamProvider] rather than by
    // this widget: watching keeps them alive across a rebuild, and two
    // conveyors bound to the same drive read the same subscription.
    final sources = [
      for (final b in bindings)
        (binding: b, source: ref.watch(keyStreamProvider(b.key)))
    ];

    return StreamBuilder<Map<String, DynamicValue>>(
      stream: _valuesStream(sources),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          if (_errorGate.shouldReport(snapshot.error)) {
            _log.e(
              'Error fetching dynamic values, error: ${snapshot.error}',
            );
          }
          return _buildConveyorVisual(context, states.grey,
          showExclamation: true);
        }
        if (!snapshot.hasData) {
          return _buildConveyorVisual(context, states.grey,
          showExclamation: true);
        }
        _errorGate.recovered();

        final dynValue = snapshot.data!;
        final color = _getConveyorColor(
          states,
          driveValue: dynValue['drive'],
          runningValue: dynValue['running'],
          frequencyValue: dynValue['frequency'],
          tripValue: dynValue['trip'],
        );

        double? freq;
        // Try dedicated frequency key first
        if (dynValue['frequency'] != null) {
          try {
            freq = dynValue['frequency']!.asDouble;
          } catch (_) {}
        }
        // Fall back to p_stat_Frequency inside the main drive value
        if (freq == null && dynValue['drive'] != null) {
          try {
            freq = dynValue['drive']!['p_stat_Frequency'].asDouble;
          } catch (_) {}
        }

        // Update auger animation from RPM key, frequency, or default
        if (dynValue['augerRpm'] != null) {
          try {
            _updateAugerAnimation(dynValue['augerRpm']!.asDouble);
          } catch (_) {
            _updateAugerAnimation(0);
          }
        } else if (freq != null && freq != 0) {
          _updateAugerAnimation(freq);
        } else {
          _updateAugerAnimation(0);
        }

        // simulateBatches handled at top of build() — independent of streams.
        // When simulation is on, the periodic timer owns `_batches`. Skipping
        // _updateBatches here prevents an incoming snapshot (e.g. a configured
        // batchesKey emitting unoccupied slots) from clobbering the simulator
        // on every stream tick.
        if (!(widget.config.simulateBatches ?? false) &&
            dynValue['batches'] != null) {
          _updateBatches(dynValue['batches']!);
        }

        // Wagon position: raw 0..100% like the elevator's position key,
        // normalised to 0..1 along the rail. While the key is bound the box
        // is the rail run and the belt is a wagon on it — parked mid-rail
        // until the PLC answers, so a stream hiccup moves the wagon rather
        // than reshaping the asset between wagon and full-length belt.
        double? wagonPosition;
        if (widget.config.railsActive && _bound(widget.config.positionKey)) {
          wagonPosition = 0.5;
          final pos = dynValue['position'];
          if (pos != null) {
            try {
              wagonPosition = pos.asDouble.clamp(0.0, 100.0) / 100.0;
            } catch (_) {}
          }
        }

        // The traverse motor answers on the chassis, in the same colour
        // vocabulary as the belt. An unreadable value is violet — the same
        // "no information" the belt shows — not a guess.
        Color? chassisColor;
        if (widget.config.railsActive &&
            _bound(widget.config.wagonMotorKey)) {
          chassisColor =
              driveStateColor(states, readDriveState(dynValue['wagonMotor']));
        }

        final hasMainKey = _bound(widget.config.key);
        final hasMotorKey =
            widget.config.railsActive && _bound(widget.config.wagonMotorKey);
        // Every wagon binding is optional — an unbound edge or motor draws
        // nothing extra and its tap zone simply is not there.
        final leftEdgeKey =
            widget.config.railsActive && _bound(widget.config.safetyLeftKey)
                ? widget.config.safetyLeftKey
                : null;
        final rightEdgeKey =
            widget.config.railsActive && _bound(widget.config.safetyRightKey)
                ? widget.config.safetyRightKey
                : null;
        return _buildConveyorVisual(
          context,
          color,
          frequency: freq,
          wagonPosition: wagonPosition,
          chassisColor: chassisColor,
          safetyLeftActive: readSafetyEdge(dynValue['safetyLeft']),
          safetyRightActive: readSafetyEdge(dynValue['safetyRight']),
          onBeltTap: hasMainKey
              ? () => _showDrivePane(context, widget.config.key!,
                  subtitle: 'Conveyor', icon: Icons.conveyor_belt)
              : null,
          onMotorTap: hasMotorKey
              ? () => _showDrivePane(context, widget.config.wagonMotorKey!,
                  subtitle: 'Wagon drive', icon: Icons.swap_horiz)
              : null,
          onLeftEdgeTap: leftEdgeKey != null
              ? () => _showSafetyEdgePane(context, leftEdgeKey, side: 'left')
              : null,
          onRightEdgeTap: rightEdgeKey != null
              ? () =>
                  _showSafetyEdgePane(context, rightEdgeKey, side: 'right')
              : null,
        );
      },
    );
  }

  static bool _bound(String? key) => key != null && key.isNotEmpty;

  /// Everything this conveyor reads, combined — built once and kept until the
  /// set of keys changes.
  ///
  /// This used to be assembled inside `build`, which handed `StreamBuilder` a
  /// new stream object every time the widget rebuilt. A new object means
  /// cancel the old subscription and open a fresh one, and resizing a window
  /// rebuilds continuously — so every conveyor on the page dropped and re-made
  /// all of its subscriptions once a frame. Each cycle asks the PLC for a new
  /// set of monitored items and throws away the ones it made a frame ago;
  /// restarts StateMan's retry ladder from the top, so a key that should have
  /// backed off to one attempt every ten minutes never got past its fourth;
  /// and writes several framed log blocks per key per frame through a sink
  /// that flushes on every event. Measured while dragging a window edge: about
  /// 130 KiB of log a second, against nothing at all once the mouse stopped —
  /// and a window that could not keep up with the mouse.
  Stream<Map<String, DynamicValue>> _valuesStream(
      List<({({String label, String key, bool optional}) binding,
             Stream<DynamicValue> source})> sources) {
    // Keyed on the streams themselves. [keyStreamProvider] hands back the
    // same instance for the same key, so this changes only when the conveyor
    // is pointed at different keys or the connection behind them is replaced
    // — not once per frame, which is what it used to do.
    final signature =
        Object.hashAll([for (final s in sources) identityHashCode(s.source)]);
    final cached = _cachedValues;
    if (cached != null && signature == _cachedValuesSignature) return cached;

    final labels = [for (final s in sources) s.binding.label];
    final combined =
        CombineLatestStream<DynamicValue?, Map<String, DynamicValue>>(
      [
        for (final s in sources)
          s.binding.optional ? _optional(s.source) : s.source,
      ],
      (values) {
        final result = <String, DynamicValue>{};
        for (var i = 0; i < labels.length; i++) {
          // A null here is an optional stream that has failed or has not
          // reported yet. Leaving the label out entirely keeps the
          // downstream `dynValue['batches'] != null` checks honest.
          final value = values[i];
          if (value != null) result[labels[i]] = value;
        }
        return result;
      },
      // Shared with a replayed value, so that if the subscription ever is
      // re-listened the belt shows what it last knew instead of blanking.
    ).shareReplay(maxSize: 1);

    _cachedValuesSignature = signature;
    _cachedValues = combined;
    return combined;
  }

  /// Wraps a stream whose failure must not take the whole conveyor down.
  ///
  /// `key` (the drive) is what the asset actually *is*: if it fails, the
  /// conveyor genuinely has no state and rendering it grey is correct.
  /// Batches, frequency, trip and auger RPM are decoration on top of that.
  ///
  /// They used to be fatal anyway, because CombineLatestStream propagates
  /// an error from ANY input and the builder turns `snapshot.hasError`
  /// into the disconnected visual. Binding `batchesKey` to a node the PLC
  /// answered with BadDeviceFailure therefore greyed out every SPB
  /// conveyor on the home page -- while their drive keys were healthy and
  /// reading fine the whole time. Wet-area conveyors, which have no
  /// `batchesKey`, were unaffected, which is what gave the game away.
  ///
  /// There is a second, quieter half to the same bug: CombineLatest does
  /// not emit until EVERY input has produced a first value, so an optional
  /// stream that merely stays silent leaves `!snapshot.hasData` and blanks
  /// the asset just as effectively as an error does. Hence `startWith`.
  ///
  /// So: swallow the error to null, and seed a null up front. A dead
  /// optional stream now costs its own overlay and nothing else, and it
  /// starts working again by itself when the PLC serves that node.
  Stream<DynamicValue?> _optional(Stream<DynamicValue> source) => source
      .map<DynamicValue?>((value) => value)
      .transform(
        StreamTransformer<DynamicValue?, DynamicValue?>.fromHandlers(
          handleError: (error, stackTrace, sink) => sink.add(null),
        ),
      )
      .startWith(null);

  void _updateBatches(DynamicValue dynConveyor) {
    final conveyorLength = dynConveyor['p_stat_Length'].asDouble;
    const batchLength = 500; // todo variable mm
    var idx = 0;
    final batches = dynConveyor['p_stat_Batches'].asArray;
    for (final batchInfo in batches) {
      final occupied = batchInfo['xOccupied'].asBool;
      final backendOfBatch = batchInfo['position'].asDouble;
      final relativeStart = backendOfBatch / conveyorLength;
      final relativeEnd = (backendOfBatch + batchLength) / conveyorLength;
      if (occupied) {
        _batches[idx.toString()] =
            Batch(start: relativeStart, end: relativeEnd);
      } else {
        _batches.remove(idx.toString());
      }
      idx++;
    }
    if (mounted) {
      // setState(() {});
    }
  }

  Widget _buildConveyorVisual(
    BuildContext context,
    Color color, {
    bool? showExclamation,
    double? frequency,
    VoidCallback? onBeltTap,
    VoidCallback? onMotorTap,
    VoidCallback? onLeftEdgeTap,
    VoidCallback? onRightEdgeTap,
    double? wagonPosition,
    Color? chassisColor,
    bool safetyLeftActive = false,
    bool safetyRightActive = false,
  }) {
    // Layering, outer → inner:
    //   LayoutRotatedBox → GestureDetector → LayoutBuilder → CustomPaint
    //
    // The rotation must be the OUTERMOST of the three. Every render object
    // above it hit-tests against its own box, and that box is the belt's
    // *unrotated* rect — long and thin along x. A 90°-turned belt paints a
    // strip along y instead, so anything outside the rotation only saw the
    // square where the two rects cross: on a wet-area strapper conveyor
    // (0.05 × 0.03 of the canvas, turned 90°) that is the middle third of
    // the belt, and the proximity sensors sit on the same spot and take most
    // of what is left. Both the detector and the LayoutBuilder used to sit
    // out there. Inside, `LayoutRotatedBox.hitTest` hands them positions
    // already mapped into the unrotated frame, so the whole painted belt
    // answers. Same arrangement as `SensorState._buildPaint`.
    return LayoutRotatedBox(
      angle: (widget.config.coordinates.angle ?? 0.0) * pi / 180,
      child: LayoutBuilder(
        builder: (context, constraints) => _buildConveyorVisualSized(
            context, constraints, color,
            showExclamation: showExclamation,
            frequency: frequency,
            onBeltTap: onBeltTap,
            onMotorTap: onMotorTap,
            onLeftEdgeTap: onLeftEdgeTap,
            onRightEdgeTap: onRightEdgeTap,
            wagonPosition: wagonPosition,
            chassisColor: chassisColor,
            safetyLeftActive: safetyLeftActive,
            safetyRightActive: safetyRightActive),
      ),
    );
  }

  /// Wraps the drawn conveyor in its tap target(s), or leaves it alone when
  /// there is no pane to open.
  ///
  /// No `behavior:` on purpose — deferring to the child leaves
  /// [ConveyorPainter.hitTest] the final word, which is what keeps the empty
  /// corners of a turned belt's box (and the bare track beside a wagon)
  /// inert. Within the hit shape, the wagon answers by zone: a bumper's
  /// outer strip goes to its safety edge, the rest of the bumper to the
  /// traverse motor, the belt to the belt drive — and whatever is actually
  /// bound answers for the zones that are not.
  Widget _withTapTargets(
      Widget child, ConveyorPainter painter, Size size,
      {VoidCallback? onBeltTap,
      VoidCallback? onMotorTap,
      VoidCallback? onLeftEdgeTap,
      VoidCallback? onRightEdgeTap}) {
    if (onBeltTap == null &&
        onMotorTap == null &&
        onLeftEdgeTap == null &&
        onRightEdgeTap == null) {
      return child;
    }
    final beltArea = painter.beltRect(size);
    return GestureDetector(
      onTapUp: (details) {
        final p = details.localPosition;
        if (onLeftEdgeTap != null &&
            (painter.safetyEdgeRect(size, left: true)?.contains(p) ??
                false)) {
          onLeftEdgeTap();
          return;
        }
        if (onRightEdgeTap != null &&
            (painter.safetyEdgeRect(size, left: false)?.contains(p) ??
                false)) {
          onRightEdgeTap();
          return;
        }
        if (onMotorTap != null && !beltArea.contains(p)) {
          onMotorTap();
          return;
        }
        (onBeltTap ?? onMotorTap)?.call();
      },
      child: child,
    );
  }

  Widget _buildConveyorVisualSized(
    BuildContext context,
    BoxConstraints constraints,
    Color color, {
    bool? showExclamation,
    double? frequency,
    VoidCallback? onBeltTap,
    VoidCallback? onMotorTap,
    VoidCallback? onLeftEdgeTap,
    VoidCallback? onRightEdgeTap,
    double? wagonPosition,
    Color? chassisColor,
    bool safetyLeftActive = false,
    bool safetyRightActive = false,
  }) {
    // The geometry must be built for the box the belt is actually painted
    // into. `AssetStack` lays assets out with tight constraints from the page
    // canvas — the same rectangle the editor draws the selection box from —
    // and the canvas is never the window: the editor keeps panes and headers
    // around it, and every monitor slices it differently. A window-derived
    // size therefore painted the belt offset and rescaled against its own
    // box. The config-derived size only decides anything in unconstrained
    // hosts (previews, palettes), where it is what the CustomPaint below
    // would measure anyway — `constrain` reproduces that layout exactly.
    final requestedSize =
        widget.config.size.toSize(MediaQuery.of(context).size);
    final paintSize = constraints.constrain(requestedSize);

    if (widget.config.showAuger ?? false) {
      final auger = CustomPaint(
        size: paintSize,
        painter: AugerConveyorPainter(
          stateColor: color,
          phaseNotifier: _augerPhase,
          showAuger: !(showExclamation ?? false),
          openEnd: widget.config.augerOpenEnd,
        ),
      );
      // No wagon on an auger — the belt drive answers for all of it.
      return onBeltTap == null
          ? auger
          : GestureDetector(onTap: onBeltTap, child: auger);
    }

    // An explicit canvas-relative belt width wins over the box-relative
    // thickness, and applies whether or not the belt turns. The canvas the
    // fraction refers to is the one the asset's own `size` fractions are
    // resolved against; it is not in scope here, but the box is `size` times
    // the canvas by construction, so it is recovered from the box — using the
    // window instead made the belt fatten and thin as the window changed
    // while everything around it stayed put.
    final canvasHeight = widget.config.size.height > 1e-6
        ? paintSize.height / widget.config.size.height
        : MediaQuery.of(context).size.height;
    final beltWidth = widget.config.beltWidthRelative == null
        ? null
        : widget.config.beltWidthRelative! * canvasHeight;
    final geometry = ConveyorPathGeometry.build(
      widget.config.turns,
      paintSize,
      thicknessFactor: widget.config.effectiveBeltThickness,
      beltWidthOverride: beltWidth,
    );

    final mirror = AssetMirrorScope.of(context);
    final painter = ConveyorPainter(
      color: color,
      showExclamation: showExclamation ?? false,
      bidirectional: widget.config.bidirectional ?? false,
      reverseDirection: widget.config.reverseDirection ?? false,
      showFrequency: widget.config.showFrequency ?? false,
      frequency: frequency,
      batches: _batches,
      angle: widget.config.coordinates.angle ?? 0.0,
      geometry: geometry,
      mirrorX: mirror?.xMirror ?? false,
      mirrorY: mirror?.yMirror ?? false,
      straightBeltWidth: beltWidth,
      paintSize: paintSize,
      style: widget.config.style,
      onRails: widget.config.railsActive,
      railInk: Theme.of(context).colorScheme.onSurface,
      wagonPosition: wagonPosition,
      wagonFraction: widget.config.effectiveWagonLength,
      chassisColor: chassisColor,
      safetyLeftActive: safetyLeftActive,
      safetyRightActive: safetyRightActive,
      safetyColor: HmiStateColors.of(context).red,
      wagonBeltAcross: !(widget.config.beltAlongRails ?? false),
    );
    // The belt's own outline, published for the mark the plant view draws
    // while this conveyor's pane is open. Not a shape built to be drawn
    // around the belt — the very path `hitTest` answers from, so what is
    // outlined and what takes the tap cannot come apart. Resolved only if
    // something asks; `hasHitShape` answers whether there is one to ask for
    // without building it, and is exactly the condition under which
    // `hitShape()` is non-null. Belts with no closed outline — filling their
    // box, or painted as a fat stroke of the centreline — publish nothing and
    // are marked by their box.
    final Widget conveyorPaint = CustomPaint(size: paintSize, painter: painter);
    final belt = painter.hasHitShape
        ? AssetHitShape(shape: () => painter.hitShape()!, child: conveyorPaint)
        : conveyorPaint;

    final gateEntries = widget.config.gates;

    final Widget content;
    if (gateEntries.isEmpty) {
      content = belt;
    } else {
      content = SizedBox(
        width: paintSize.width,
        height: paintSize.height,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            belt,
            for (final entry in gateEntries)
              _positionedChildGate(entry, paintSize, geometry,
                  straightBeltWidth: beltWidth),
          ],
        ),
      );
    }

    return _withTapTargets(content, painter, paintSize,
        onBeltTap: onBeltTap,
        onMotorTap: onMotorTap,
        onLeftEdgeTap: onLeftEdgeTap,
        onRightEdgeTap: onRightEdgeTap);
  }

  Widget _positionedChildGate(
      ChildGateEntry entry, Size conveyorSize, ConveyorPathGeometry? geometry,
      {double? straightBeltWidth}) {
    // Cross-belt dimension: the turned belt carries its own width, a straight
    // belt is either an explicit band or the full box height.
    final beltHeight =
        geometry?.beltWidth ?? straightBeltWidth ?? conveyorSize.height;
    // A straight band is centred in the box, so gates hang off the band edge
    // rather than the box edge.
    final bandInset =
        geometry == null ? (conveyorSize.height - beltHeight) / 2 : 0.0;
    final gateSize = beltHeight; // square so flap spans belt width
    final xCenter = entry.position * conveyorSize.width;

    // Overhang: how far the gate extends outside the conveyor border.
    // Pusher uses pi/2 rotation so content spans full height — less overhang
    // keeps the actuator closer to the edge. Slider/pneumatic have centered
    // elements and need more overhang.
    final outsideOverhang = switch (entry.gate.gateVariant) {
      GateVariant.pusher => gateSize * 0.4,
      GateVariant.slider => gateSize * 0.57,
      GateVariant.pneumatic => gateSize * 0.6,
    };

    // Same rotation for both sides; bottom gates are mirrored, not rotated 180°.
    final rotation = switch (entry.gate.gateVariant) {
      GateVariant.slider => pi,
      GateVariant.pneumatic => entry.side == GateSide.left ? 0.0 : pi,
      GateVariant.pusher => pi / 2,
    };

    final isBottom = entry.side == GateSide.right;

    final child = SizedBox(
      width: gateSize,
      height: gateSize,
      child: Transform.flip(
        flipX: false,
        flipY: isBottom && entry.gate.gateVariant != GateVariant.pneumatic,
        child: Transform.rotate(
          angle: rotation,
          child: ConveyorGate(config: entry.gate),
        ),
      ),
    );

    if (geometry != null) {
      // Curved belt: place the gate along the centerline path, offset
      // perpendicular to the travel direction and rotated to follow it.
      final tangent = geometry.tangentAt(entry.position);
      final v = tangent.vector; // unit vector along travel, screen coords
      final leftNormal = Offset(v.dy, -v.dx); // "top" side of the belt
      final distFromCenter = beltHeight / 2 + outsideOverhang - gateSize / 2;
      final center = entry.side == GateSide.left
          ? tangent.position + leftNormal * distFromCenter
          : tangent.position - leftNormal * distFromCenter;
      return Positioned(
        left: center.dx - gateSize / 2,
        top: center.dy - gateSize / 2,
        width: gateSize,
        height: gateSize,
        child: Transform.rotate(
          angle: atan2(v.dy, v.dx),
          child: child,
        ),
      );
    }

    if (entry.side == GateSide.left) {
      return Positioned(
        left: xCenter - gateSize / 2,
        top: bandInset - outsideOverhang,
        width: gateSize,
        height: gateSize,
        child: child,
      );
    } else {
      // Measured from the box bottom, which with rails is not the band
      // bottom — the undercarriage sits between them.
      final bottomInset = conveyorSize.height - bandInset - beltHeight;
      return Positioned(
        left: xCenter - gateSize / 2,
        bottom: bottomInset - outsideOverhang,
        width: gateSize,
        height: gateSize,
        child: child,
      );
    }
  }

  /// Identity of one of this conveyor's docked panes — it can own two, one
  /// per drive (belt and wagon traverse motor). Tapping the same drive
  /// twice toggles its pane; tapping another device replaces it.
  String _paneIdFor(String driveKey) =>
      'conveyor:${identityHashCode(widget.config)}:$driveKey';

  /// Every key this conveyor may have opened a pane for.
  Iterable<String> get _paneDriveKeys => [
        widget.config.key,
        widget.config.wagonMotorKey,
        widget.config.safetyLeftKey,
        widget.config.safetyRightKey,
      ].whereType<String>().where((k) => k.isNotEmpty);

  /// Opens the pane for one of the wagon's safety edges. An `FB_Sensor`
  /// struct gets the sensor asset's own FB pane — same rows, same
  /// setpoints, one implementation — and a plain BOOL a minimal
  /// pressed/clear card.
  void _showSafetyEdgePane(BuildContext context, String edgeKey,
      {required String side}) {
    final title = 'Safety edge · $side';
    SidePane simple(PaneStatus status, String detail) => SidePane(
          title: title,
          subtitle: 'Wagon',
          icon: Icons.sensors,
          status: status,
          child: PaneBody(
            sections: [
              PaneBodySection.status(
                title: 'Signal',
                child: PaneDetailRow(label: 'Edge', value: detail),
              ),
            ],
          ),
        );
    showSidePane(
      context: context,
      id: _paneIdFor(edgeKey),
      builder: (paneContext) => StateManValueBuilder(
        keyName: edgeKey,
        waiting: (_) =>
            simple(const PaneStatus.unknown('Connecting'), 'connecting'),
        error: (_, error) =>
            simple(const PaneStatus.fault('Error'), error.toString()),
        builder: (context, stateMan, dynValue) {
          final fb = SensorFbState.tryParse(dynValue);
          if (fb == null) {
            final pressed = readSafetyEdge(dynValue);
            return simple(
                pressed
                    ? const PaneStatus.fault('Pressed')
                    : const PaneStatus.stopped('Clear'),
                pressed ? 'pressed' : 'clear');
          }
          // `Consumer` for the `ref` that `writeTag` needs, exactly as the
          // drive pane below does. The safety-edge pane arrived with the
          // wagon work after this milestone's write-path sweep had already
          // run, so its `onWrite` was the one remaining ungated `.write(` in
          // `lib/` — `kUncaughtAccessDeniedWriteSites` caught it at 1.
          return Consumer(
            builder: (context, ref, _) => SensorFbPane(
              config: SensorConfig(detectionKey: edgeKey, tag: title),
              state: fb,
              subtitleOverride: 'Safety edge · FB_Sensor',
              // Copy-on-write like every other pane here: clone, set one
              // member, write the whole struct back. The field goes on as the
              // **member**, so a template can require a different permission
              // for each one.
              onWrite: (field, value) {
                final messenger = ScaffoldMessenger.maybeOf(context);
                final newValue = DynamicValue.from(dynValue);
                newValue[field] = value;
                writeTag(ref, stateMan, edgeKey, newValue, member: field)
                    .catchError((Object e) {
                  messenger?.showSnackBar(
                    SnackBar(content: Text('Write to $edgeKey failed: $e')),
                  );
                  return false;
                });
              },
            ),
          );
        },
      ),
    );
  }

  /// Opens the operator pane for one of this conveyor's drives — the belt
  /// drive, or the wagon's traverse motor, which is the same `FB_ATV320`
  /// face: on the traverse motor the jog buttons drive the wagon down the
  /// track.
  ///
  /// Since Plan 260811 this is a non-modal [SidePane] rather than an
  /// `AlertDialog`. It matters more here than anywhere else: jogging a belt
  /// is a hand-on-button, eyes-on-the-belt operation, and the old dialog put
  /// a barrier over the very mimic the operator was watching.
  ///
  /// The layout follows the house rule — headline numbers as tiles, commands
  /// pinned in the footer, and the stats trend behind a [PaneGraphTile] so
  /// the pane itself stays inside one screen. Tapping the trend opens it in a
  /// free-floating dialog the operator can drag onto the plant view.
  ///
  /// The subscription lives in a `StreamBuilder` inside the pane body, so it
  /// is released when the pane closes — same lifetime contract as the dialog
  /// it replaces.
  void _showDrivePane(BuildContext context, String driveKey,
      {required String subtitle, required IconData icon}) {
    showSidePane(
      context: context,
      id: _paneIdFor(driveKey),
      // One subscription for the life of the pane: see StateManValueBuilder
      // for why the stream must not be built inline (tapping a setpoint field
      // rebuilt the pane, which re-subscribed and threw the keystrokes away).
      builder: (paneContext) => StateManValueBuilder(
        keyName: driveKey,
        waiting: (_) => SidePane(
          title: driveKey,
          subtitle: subtitle,
          icon: icon,
          status: const PaneStatus.unknown('Connecting'),
          child: const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
        error: (_, error) => SidePane(
          title: driveKey,
          subtitle: subtitle,
          icon: icon,
          status: const PaneStatus.fault('Error'),
          child: PaneSection(
            title: 'Subscription failed',
            child: SelectableText(error.toString()),
          ),
        ),
        // A `Consumer` rather than this State's own `ref`: the pane lives in
        // the overlay, not in this widget's subtree, so a rebuild of the
        // conveyor would not rebuild it. Watching from here is what makes a
        // sign-in take the lock off a setpoint field while the pane is open.
        builder: (context, stateMan, dynValue) => Consumer(
          builder: (context, ref, _) {

            /// Copy-on-write helper — every command follows the same shape:
            /// clone the current value, set one field, write the whole thing
            /// back. Preserved verbatim from the dialog this replaced.
            ///
            /// The field is passed on as the **member**, and that is the whole
            /// of spec §7b on this pane: one key carries `p_cmd_JogFwd` and
            /// `p_cfg_ManualFreq`, and a template says they need different
            /// permissions. Routing this through `writeTag` without the member
            /// would compile, pass a shallow test, and gate nothing.
            void write(String field, Object? value) {
              final newValue = DynamicValue.from(dynValue);
              newValue[field] = value;
              writeTag(ref, stateMan, driveKey, newValue, member: field);
            }

            /// Whether this session may write [member] of this drive.
            ///
            /// `stateMan` is passed rather than left to `stateManProvider`:
            /// the key may name a variable, and the handle in hand is the one
            /// the write is about to go through.
            ///
            /// [driveKey], not `widget.config.key` — a conveyor carries up to
            /// four drives (the belt, the wagon motor and the two safety
            /// scanners, see `_paneDriveKeys`) and this pane is opened for one
            /// of them. Gating on the conveyor's own key would consult the
            /// belt's template while the operator is looking at the wagon
            /// motor: the wrong answer, arrived at silently.
            bool allowed(String member) => tagWriteAllowed(
                  ref,
                  driveKey,
                  member: member,
                  stateMan: stateMan,
                );

            /// What a tap on a locked setpoint does: prompt, record, and write
            /// nothing. Never a disabled field — see `SetpointField.locked`.
            VoidCallback lockedTap(String member) => () => guardTagWrite(
                  ref,
                  driveKey,
                  member: member,
                  stateMan: stateMan,
                );

            final jogFwd = dynValue['p_stat_JogFwd'].asBool;
            final jogBwd = dynValue['p_stat_JogBwd'].asBool;
            final stopOnRelease = dynValue['p_stat_ManualStopOnRelease'].asBool;
            final frequency = dynValue['p_stat_Frequency'].asDouble;
            final runTime =
                formatRunTime(dynValue['p_stat_RunMinutes'].asInt);

            // `p_stat_State` and `p_stat_LastFault` are the PLC enums
            // `hmis_e` and `lft_e` — plain integers over OPC UA.
            final driveState =
                atv320DriveState(dynValue['p_stat_State'].asInt);
            final lastFault = atv320Fault(dynValue['p_stat_LastFault'].asInt);

            // The two words are not the same kind of thing. HMIS is what the
            // drive is doing *now*; LFT is a stored record that survives a
            // `Fault reset` and stays there while the belt runs perfectly
            // well. So the fault is only a live condition when the drive
            // itself is in a fault state — otherwise LFT is history, and
            // painting it red sends an electrician after nothing.
            //
            // Any fault-severity HMIS entry counts, not just FLT(23): FA and
            // EP are trips in their own right, and LOST(99) is substituted by
            // FB_ATV320 together with CNF, so the pair only makes sense read
            // as one. Keyed off the severity so a new fault state added to
            // `hmis_e` is covered without touching this.
            final faultIsLive = driveState.severity == Atv320Severity.fault;

            return SidePane(
              title: driveKey,
              subtitle: subtitle,
              icon: icon,
              // A faulted or safety-stopped drive outranks the frequency
              // reading: a belt sitting at 0 Hz because it tripped must not
              // present itself as a healthy 'Stopped'.
              status: faultIsLive
                  ? PaneStatus.fault(driveState.label)
                  : driveState.code == 30 // STO — safety, not a trip
                      ? PaneStatus.warning(driveState.label)
                      : (jogFwd || jogBwd)
                          ? const PaneStatus.running('Jogging')
                          : frequency.abs() > 0.01
                              ? const PaneStatus.running()
                              : const PaneStatus.stopped(),
              // One command in the footer: three buttons wrap onto two rows
              // in a 380px pane and the pinned bar stops reading as a bar.
              // 'Reset run hours' sits on the Status section instead, next to
              // the number it resets.
              actions: [
                PaneAction.destructive(
                  label: 'Fault reset',
                  icon: Icons.restart_alt,
                  onPressed: () => write('p_cmd_FaultReset', true),
                ),
              ],
              child: PaneBody(
                sections: [
                  // --- Live numbers ----------------------------------------
                  PaneBodySection.status(
                    trailing: TextButton(
                      onPressed: () => write('p_cmd_ResetRunHours', true),
                      child: const Text('Reset hours'),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        PaneTileRow(
                          children: [
                            PaneMetricTile(
                              label: 'Frequency',
                              value: frequency.toStringAsFixed(2),
                              unit: 'Hz',
                              icon: Icons.speed,
                            ),
                            PaneMetricTile(
                              label: 'Current',
                              value: dynValue['p_stat_Current']
                                  .asDouble
                                  .toStringAsFixed(2),
                              unit: 'A',
                              icon: Icons.bolt,
                            ),
                            PaneMetricTile(
                              label: 'Run hours',
                              value: runTime.value,
                              unit: runTime.unit,
                              icon: Icons.schedule,
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        // The drive's own two status words — in operator
                        // words first, with the name the drive itself uses in
                        // brackets. HMIS and LFT are what the keypad and
                        // NVE41295 call these parameters, so an electrician
                        // can still walk from the pane to the drive without
                        // translating, while an operator reads `Status` and
                        // `Last fault` without ever having seen the keypad;
                        // the value carries the keypad mnemonic and then says
                        // it in words, and the explanation behind the row
                        // says the rest.
                        PaneExplainRow(
                          label: 'Status (HMIS)',
                          value: '${driveState.mnemonic} · ${driveState.label}',
                          valueColor: _severityColor(context, driveState),
                          explanationBuilder: (context) =>
                              _Atv320Explainer(explanation: driveState),
                        ),
                        PaneExplainRow(
                          label: 'Last fault (LFT)',
                          value: '${lastFault.mnemonic} · ${lastFault.label}',
                          // Stored, not live: only tinted while the drive is
                          // actually in the fault. Otherwise the row is
                          // ordinary history and says so.
                          valueColor: faultIsLive
                              ? _severityColor(context, lastFault)
                              : null,
                          valueNote: faultIsLive || lastFault.isHealthy
                              ? null
                              : 'cleared',
                          // A live fault opens itself: the operator who just
                          // walked over to a stopped belt should not have to
                          // discover that the row is tappable.
                          initiallyExpanded:
                              !lastFault.isHealthy && faultIsLive,
                          explanationBuilder: (context) => _Atv320Explainer(
                            explanation: lastFault,
                            historical: !faultIsLive && !lastFault.isHealthy,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // --- Trend -----------------------------------------------
                  //
                  // A preview in the pane, the real chart in a floating
                  // dialog the operator can park next to the mimic.
                  PaneBodySection.trend(
                    child: conveyorTrendTile(keyName: driveKey),
                  ),

                  // --- Manual ----------------------------------------------
                  //
                  // `p_stat_ManualStopOnRelease` decides the gesture: when
                  // set, the belt runs only while the button is held (the
                  // press/release callbacks write true/false); when clear, a
                  // tap latches it. Both paths are unchanged from the dialog.
                  PaneBodySection.manual(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _JogButton(
                              icon: Icons.arrow_back,
                              label: 'Reverse',
                              active: jogBwd,
                              stopOnRelease: stopOnRelease,
                              onCommand: (v) => write('p_cmd_JogBwd', v),
                            ),
                            _JogButton(
                              icon: Icons.arrow_forward,
                              label: 'Forward',
                              active: jogFwd,
                              stopOnRelease: stopOnRelease,
                              onCommand: (v) => write('p_cmd_JogFwd', v),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        // Compact row rather than a SwitchListTile: the pane
                        // has one screen of height and this is a mode flag,
                        // not a headline. On = a tap latches the belt and it
                        // keeps running; off = it runs only while held —
                        // so the switch reads as the opposite of the PLC's
                        // stop-on-release flag.
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Jog continuous',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                            Switch(
                              value: !stopOnRelease,
                              onChanged: (_) =>
                                  write('p_cmd_ManualStopOnRelease', true),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        // The speed those buttons jog at — full width, under
                        // the controls it belongs to.
                        SetpointField<double>(
                            fieldKey: 'manual_freq_field',
                            label: 'Manual frequency',
                            text: dynValue['p_cfg_ManualFreq'].asDouble.toStringAsFixed(2),
                            current: dynValue['p_cfg_ManualFreq'].asDouble,
                            parse: double.tryParse,
                            suffix: 'Hz',
                            onSubmitted: (v) => write('p_cfg_ManualFreq', v),
                            locked: !allowed('p_cfg_ManualFreq'),
                            onLockedTap: lockedTap('p_cfg_ManualFreq'),
                          ),
                      ],
                    ),
                  ),

                  // --- Setpoints -------------------------------------------
                  //
                  // Inline, not behind a dialog: there are only two of them
                  // and an operator changing a frequency wants to see the
                  // belt while doing it. Manual frequency is not here — it
                  // belongs to hand control, so it sits beside the jog toggle.
                  //
                  // Committed on submit (Enter / focus-out), never per
                  // keystroke — a half-typed frequency must not reach the
                  // drive. Keys embed the current value so a field resets when
                  // the PLC reports a different one.
                  PaneBodySection.setpoints(
                    // Side by side — two short numbers read better as a pair
                    // than as a stack, and it costs one row instead of two.
                    child: Row(
                      // Top-aligned: a field showing a validation or helper
                      // line below it must not shove its neighbour down.
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: SetpointField<double>(
                            fieldKey: 'auto_freq_field',
                            label: 'Auto',
                            text: dynValue['p_cfg_AutoFreq'].asDouble.toStringAsFixed(2),
                            current: dynValue['p_cfg_AutoFreq'].asDouble,
                            parse: double.tryParse,
                            suffix: 'Hz',
                            onSubmitted: (v) => write('p_cfg_AutoFreq', v),
                            locked: !allowed('p_cfg_AutoFreq'),
                            onLockedTap: lockedTap('p_cfg_AutoFreq'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: SetpointField<double>(
                            fieldKey: 'cleaning_freq_field',
                            label: 'Cleaning',
                            text: dynValue['p_cfg_CleaningFreq'].asDouble.toStringAsFixed(2),
                            current: dynValue['p_cfg_CleaningFreq'].asDouble,
                            parse: double.tryParse,
                            suffix: 'Hz',
                            onSubmitted: (v) => write('p_cfg_CleaningFreq', v),
                            locked: !allowed('p_cfg_CleaningFreq'),
                            onLockedTap: lockedTap('p_cfg_CleaningFreq'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Formats the drive's accumulated run-time counter for a [PaneMetricTile].
///
/// The tile is fixed-width, so the string has to stay short at every
/// magnitude — a belt months past its last reset used to render `224:37`,
/// which no longer fit and ellipsised to `224:…`. Precision follows
/// magnitude instead: minutes while the counter is under an hour, hours and
/// minutes up to a day, and past that whole hours like the drive's own hour
/// meter — service intervals are quoted in whole hours, and at that scale
/// the minutes are noise.
({String value, String unit}) formatRunTime(int runMinutes) {
  if (runMinutes < 60) {
    return (value: '$runMinutes', unit: 'min');
  }
  if (runMinutes < 24 * 60) {
    final minutes = (runMinutes % 60).toString().padLeft(2, '0');
    return (value: '${runMinutes ~/ 60}:$minutes', unit: 'h:m');
  }
  return (value: '${runMinutes ~/ 60}', unit: 'h');
}

/// Maps a decoded drive value onto the themed equipment-state colors.
///
/// Healthy states are deliberately left untinted — colouring "Ready" green
/// would put as much ink on the normal case as on a trip.
Color? _severityColor(BuildContext context, Atv320Explanation e) {
  final colors = HmiStateColors.of(context);
  switch (e.severity) {
    case Atv320Severity.fault:
      return colors.red;
    case Atv320Severity.warning:
      return colors.yellow;
    case Atv320Severity.info:
    case Atv320Severity.ok:
      return null;
  }
}

/// The panel behind a drive-state or fault row: what the word means, whether
/// `Fault reset` can clear it, and what to actually do.
///
/// Wording comes from the ATV320 Programming Manual (NVE41295) — see
/// `helper/atv320_diagnostics.dart`. The mnemonic and code lead, so an
/// electrician can carry them straight to the drive keypad.
class _Atv320Explainer extends StatelessWidget {
  final Atv320Explanation explanation;

  /// True for a stored fault the drive is no longer in. Says so up front, so
  /// the remedy underneath reads as "if it comes back" rather than "now".
  final bool historical;

  const _Atv320Explainer({required this.explanation, this.historical = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.75),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text(
              explanation.mnemonic,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 6),
            Text('code ${explanation.code}', style: muted),
          ],
        ),
        if (historical) ...[
          const SizedBox(height: 6),
          Text(
            'Already cleared — the drive is not faulted now. This is the '
            'record of the last trip, kept until the next one replaces it.',
            style: muted,
          ),
        ],
        const SizedBox(height: 6),
        Text(explanation.meaning, style: theme.textTheme.bodySmall),
        if (explanation.clearing != null) ...[
          const SizedBox(height: 8),
          _ClearingNote(clearing: explanation.clearing!),
        ],
        if (explanation.remedy.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            explanation.documented ? 'WHAT TO DO' : 'NOT DOCUMENTED FOR ATV320',
            style: theme.textTheme.labelSmall?.copyWith(
              letterSpacing: 1.1,
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 4),
          for (final step in explanation.remedy)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('•  ', style: theme.textTheme.bodySmall),
                  Expanded(
                    child: Text(step, style: theme.textTheme.bodySmall),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

/// The one line an operator most wants from a fault: can I reset this myself?
class _ClearingNote extends StatelessWidget {
  final Atv320Clearing clearing;

  const _ClearingNote({required this.clearing});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = HmiStateColors.of(context);
    final (icon, text, color) = switch (clearing) {
      Atv320Clearing.selfClears => (
          Icons.autorenew,
          'Clears by itself once the cause is gone.',
          colors.green,
        ),
      Atv320Clearing.faultReset => (
          Icons.restart_alt,
          'Fix the cause, then Fault reset clears it.',
          colors.yellow,
        ),
      Atv320Clearing.powerCycle => (
          Icons.power_settings_new,
          'Fault reset will not clear this — the drive must be powered '
              'down and back up after the cause is fixed.',
          colors.red,
        ),
    };

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

/// One jog button — a large touch target with a label underneath.
///
/// [stopOnRelease] mirrors `p_stat_ManualStopOnRelease`: when true the
/// command follows the press state (true on press, false on release); when
/// false a tap writes a single latching `true`.
class _JogButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final bool stopOnRelease;
  final void Function(bool value) onCommand;

  const _JogButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.stopOnRelease,
    required this.onCommand,
  });

  @override
  Widget build(BuildContext context) {
    final color =
        active ? HmiStateColors.of(context).green : Theme.of(context).disabledColor;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        RawMaterialButton(
          shape: const CircleBorder(),
          padding: const EdgeInsets.all(8),
          constraints: const BoxConstraints(minWidth: 56, minHeight: 56),
          onHighlightChanged: (isPressed) {
            if (stopOnRelease) onCommand(isPressed);
          },
          onPressed: () {
            if (!stopOnRelease) onCommand(true);
          },
          child: Icon(icon, color: color, size: 36),
        ),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}


/// Resolves the [Collector] and hands it to [ConveyorStatsGraph].
///
/// Used for both the pane preview and the expanded floating chart, so the
/// two can never drift apart.
class _ConveyorStatsGraphLoader extends ConsumerWidget {
  final String keyName;
  final bool showButtons;
  final Duration xSpan;
  final bool compact;

  const _ConveyorStatsGraphLoader({
    required this.keyName,
    this.showButtons = true,
    this.xSpan = const Duration(minutes: 5),
    this.compact = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<Collector?>(
      future: ref.watch(collectorProvider.future),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return ConveyorStatsGraph(
          collector: snapshot.data,
          keyName: keyName,
          showButtons: showButtons,
          xSpan: xSpan,
          compact: compact,
        );
      },
    );
  }
}

class Batch {
  double start; // 0…1 (can be <0 while entering)
  double end; // 0…1 (can be >1 while exiting)
  Color color;

  Batch({required this.start, required this.end, this.color = Colors.white});
}

class ConveyorPainter extends CustomPainter {
  final Map<String, Batch> batches;
  final Color color;
  final bool showExclamation;
  final bool bidirectional;
  final bool reverseDirection;
  final bool showFrequency;
  final double? frequency;
  final double angle;
  final ConveyorPathGeometry? geometry;

  /// The page-wide mirror in effect around this asset (see
  /// [AssetMirrorScope]). The flip itself is applied by `AssetStack` as an
  /// outer `Transform`; the painter only needs the flags to counter-mirror
  /// the text it draws itself — the way [angle] is counter-rotated — so the
  /// frequency figure and the fault mark stay readable while the belt
  /// geometry mirrors.
  final bool mirrorX;
  final bool mirrorY;

  /// Explicit belt width for a *straight* belt, in logical pixels.
  ///
  /// Null keeps the original convention of filling the box height. Turned
  /// belts carry their width on [geometry] instead.
  final double? straightBeltWidth;

  /// The box the painter is laid out at. [hitTest] needs it to place the
  /// straight band inside the box; null keeps the whole box tappable.
  final Size? paintSize;

  /// Which band renderer to use — see [ConveyorStyle].
  final ConveyorStyle style;

  /// Draws a wagon undercarriage (wheels on a rail) under the belt, which
  /// then occupies only the box above it. Straight belts only; the caller
  /// gates this on [ConveyorConfig.railsActive].
  final bool onRails;

  /// Ink for the rail, sleepers and wheel rims. The belt's own border stays
  /// black in every theme because it outlines a filled band; the track is
  /// bare lines on the page background, so it has to take the theme's
  /// foreground or it disappears on a dark page.
  final Color railInk;

  /// Live wagon position along the rail, 0..1 (0 = left end of the box),
  /// or null for a wagon with no position binding — which spans the whole
  /// box like an ordinary belt. Only meaningful with [onRails].
  final double? wagonPosition;

  /// Length of a position-driven wagon as a fraction of the box width.
  final double wagonFraction;

  /// State colour of the wagon's traverse drive, painted on the chassis
  /// that peeks out past both ends of the belt. Null draws the chassis as
  /// neutral hardware — no motor bound, nothing to claim about it.
  final Color? chassisColor;

  /// Whether each of the wagon's safety edges is pressed. An idle edge
  /// draws nothing at all; a tripped one lights its bumper in [safetyColor].
  final bool safetyLeftActive;
  final bool safetyRightActive;

  /// Colour of a tripped safety edge — the theme's fault red, handed in by
  /// the widget because the painter has no theme access.
  final Color safetyColor;

  /// Whether the wagon's belt stands across the rails (the classic
  /// transfer wagon) or lies along them (a shuttle conveying in its own
  /// travel direction).
  final bool wagonBeltAcross;

  ConveyorPainter(
      {required this.color,
      this.showExclamation = false,
      this.bidirectional = false,
      this.reverseDirection = false,
      this.showFrequency = false,
      this.frequency,
      required this.batches,
      required this.angle,
      this.geometry,
      this.mirrorX = false,
      this.mirrorY = false,
      this.straightBeltWidth,
      this.paintSize,
      this.style = ConveyorStyle.box,
      this.onRails = false,
      this.railInk = Colors.black,
      this.wagonPosition,
      this.wagonFraction = 0.25,
      this.chassisColor,
      this.safetyLeftActive = false,
      this.safetyRightActive = false,
      this.safetyColor = const Color(0xFFD32F2F),
      this.wagonBeltAcross = true});

  /// Extra canvas rotation in effect while overlays draw — π/2 while the
  /// wagon's belt is painted in its rotated frame, zero otherwise. The
  /// overlay text counter-rotates by this on top of the asset's own angle,
  /// so a frequency figure on a wagon reads upright like everywhere else.
  double _overlayExtraRotation = 0;

  /// Undoes the outer mirror after the counter-rotation, so overlay text
  /// paints upright. The canvas at that point carries mirror ∘ rotate ∘
  /// counter-rotate = mirror alone, and a mirror is its own inverse.
  void _counterMirror(Canvas canvas) {
    if (mirrorX || mirrorY) {
      canvas.scale(mirrorX ? -1.0 : 1.0, mirrorY ? -1.0 : 1.0);
    }
  }

  /// Belt outline used by [hitTest], resolved once per painter instance —
  /// hit tests run on every pointer event, the outline never changes.
  Path? _hitOutline;
  bool _hitOutlineResolved = false;

  /// The belt itself, as a path, or null where it has no closed one.
  ///
  /// Two callers, one derivation: [hitTest] answers from this, and the plant
  /// view outlines it while the belt's pane is open (see [AssetHitShape]).
  /// The mark and the tap target are the same object rather than two
  /// descriptions of the same intention, so they cannot come apart.
  ///
  /// Null in the two cases with no closed belt outline to give: a straight
  /// belt with no configured width, which fills its box (the box is the
  /// belt), and a belt so wide for its bends that it is painted as a fat
  /// stroke of the centreline rather than as a band.
  /// Whether [hitShape] has a path to give, answered from the fields rather
  /// than by building one.
  ///
  /// The widget asks this on every build and builds the path on none of them:
  /// resolving a turned belt's outline costs about as much again as the
  /// geometry it comes from, and a page of belts rebuilds on every drag tick.
  bool get hasHitShape =>
      geometry != null ||
      (paintSize != null && (straightBeltWidth != null || onRails));

  Path? hitShape() {
    if (!_hitOutlineResolved) {
      _hitOutlineResolved = true;
      _hitOutline = _buildHitOutline();
    }
    return _hitOutline;
  }

  Path? _buildHitOutline() {
    final g = geometry;
    if (g == null) {
      final size = paintSize;
      if (size == null) return null;
      // A wagon is a band even without an explicit width: the belt is a
      // fraction of the box, and the tap target — chassis bumpers included —
      // has to ride along the rail with it. Only the empty track beside it
      // falls through.
      final band = straightBeltWidth ?? (onRails ? size.height : null);
      if (band == null) return null;
      final rect = onRails ? wagonRect(size) : beltRect(size);
      return Path()
        ..addRRect(RRect.fromRectAndRadius(
          rect,
          Radius.circular(rect.shortestSide * _endRadiusFactor),
        ));
    }
    return g.bandOutline(0, 1,
        width: g.beltWidth, radius: g.beltWidth * _endRadiusFactor);
  }

  /// Claim only the painted belt, not the whole box.
  ///
  /// A turned belt occupies a fraction of its bounding box, and a straight
  /// belt with an explicit width is a band centred in it. Taps on the empty
  /// remainder used to open the details pane anyway; letting them fall
  /// through keeps the dead space inert and lets assets behind it stay
  /// reachable.
  @override
  bool hitTest(Offset position) {
    final shape = hitShape();
    if (shape != null) return shape.contains(position);
    final g = geometry;
    // No explicit band: the belt fills the box, so the box is the belt.
    if (g == null) return true;
    // Over-wide belt: painted as a fat stroke of the centerline, so accept
    // anything within half the belt width (plus border) of it.
    const samples = 64;
    final reach = g.beltWidth / 2 + 2;
    for (var i = 0; i <= samples; i++) {
      if ((g.tangentAt(i / samples).position - position).distance <= reach) {
        return true;
      }
    }
    return false;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (geometry != null) {
      _paintTurnedBelt(canvas, size);
      return;
    }
    // Top view, like every other mimic asset: the box is the rail run, the
    // track spans all of it, and the wagon rides it with its belt turned
    // perpendicular — the wagon travels along the rails, the belt conveys
    // across them, which is what a transfer wagon is for. Nothing grows
    // the asset: the box the user drew still bounds all of the ink.
    final span = _beltSpan(size);
    if (onRails) {
      _paintTrack(canvas, size);
      _paintChassis(canvas, size, span);
      canvas.save();
      if (wagonBeltAcross) {
        // Rotate the belt's frame 90° so its band runs the box height at
        // the wagon's position: belt travel maps to screen-down.
        canvas.translate(span.x0 + span.width, 0);
        canvas.rotate(pi / 2);
        _overlayExtraRotation = pi / 2;
        _paintStraightBelt(canvas, Size(size.height, span.width));
        _overlayExtraRotation = 0;
      } else {
        // Along the rails: an ordinary horizontal band riding the chassis.
        final band = straightBeltWidth ?? size.height;
        canvas.translate(span.x0, (size.height - band) / 2);
        _paintStraightBelt(canvas, Size(span.width, band));
      }
      canvas.restore();
      return;
    }
    // An explicit belt width paints the belt as a band centred in the box
    // rather than filling it, so a straight belt can be set to the same width
    // as a turned one. Everything below is box-relative, so resizing the box
    // we hand it is enough — batches, arrows and text all follow. A band
    // wider than the box paints over the box edge rather than being trimmed
    // back to it: the width is set in screen units and must not move when the
    // box does.
    final band = straightBeltWidth;
    canvas.save();
    canvas.translate(span.x0, band == null ? 0 : (size.height - band) / 2);
    _paintStraightBelt(canvas, Size(span.width, band ?? size.height));
    canvas.restore();
  }

  /// Horizontal span the belt occupies inside the box: the whole box, or —
  /// on rails — the wagon's footprint along the track, slid by
  /// [wagonPosition] so 0 parks flush left and 1 flush right. A wagon with
  /// no position binding parks mid-rail. On rails the belt runs across the
  /// track, so this span is the belt's *width*: an explicit
  /// [straightBeltWidth] sets it, else [wagonFraction] of the box.
  ({double x0, double width}) _beltSpan(Size size) {
    if (!onRails) return (x0: 0.0, width: size.width);
    // An explicit belt width only shapes the footprint when the belt
    // stands across the rails; along them it is the band's cross
    // dimension, and the footprint is the wagon fraction either way.
    final w = (wagonBeltAcross ? straightBeltWidth : null) ??
        size.width * wagonFraction.clamp(0.05, 1.0);
    // Travel is inset by the chassis bumpers, so at 0% and 100% it is the
    // chassis that sits flush with the box edge — the box still bounds all
    // of the wagon's ink at every position.
    final overhang = _chassisOverhang(size, w);
    final travel = max(size.width - w - 2 * overhang, 0.0);
    final pos = (wagonPosition ?? 0.5).clamp(0.0, 1.0);
    return (x0: overhang + pos * travel, width: w);
  }

  /// The belt band's rectangle in the box — what a tap has to land on to
  /// mean the belt drive rather than the wagon motor. On rails the belt
  /// stands across the track: a vertical band the full box height.
  Rect beltRect(Size size) {
    final span = _beltSpan(size);
    if (onRails && wagonBeltAcross) {
      return Rect.fromLTWH(span.x0, 0, span.width, size.height);
    }
    final band = straightBeltWidth ?? size.height;
    return Rect.fromLTWH(
        span.x0, (size.height - band) / 2, span.width, band);
  }

  /// The whole wagon — belt plus chassis bumpers. This is the tap target
  /// and the pane-mark outline for a belt on rails.
  Rect wagonRect(Size size) {
    final belt = beltRect(size);
    if (!onRails) return belt;
    // Union, not an inflation of the belt: with the belt along the rails a
    // thin band can be shorter than the carriage under it.
    return belt.expandToInclude(_chassisRect(size));
  }

  /// The carriage frame's rectangle — shared by the chassis painter and the
  /// safety-edge tap zones so what is drawn and what answers a tap cannot
  /// come apart.
  Rect _chassisRect(Size size) {
    final span = _beltSpan(size);
    final overhang = _chassisOverhang(size, span.width);
    final chassisH = size.height * _chassisHeightFraction;
    return Rect.fromLTWH(span.x0 - overhang, (size.height - chassisH) / 2,
        span.width + 2 * overhang, chassisH);
  }

  /// The tap zone of one safety edge: the outer bumper strip of the
  /// carriage on that side — exactly the area a tripped edge lights up.
  /// Null off the rails.
  Rect? safetyEdgeRect(Size size, {required bool left}) {
    if (!onRails) return null;
    final chassis = _chassisRect(size);
    final overhang = _chassisOverhang(size, _beltSpan(size).width);
    return left
        ? Rect.fromLTWH(chassis.left, chassis.top, overhang, chassis.height)
        : Rect.fromLTWH(chassis.right - overhang, chassis.top, overhang,
            chassis.height);
  }

  /// Rounding of the belt's two ends, as a fraction of the belt width.
  ///
  /// Shared by both renderers so a belt keeps the same silhouette when a turn
  /// is added: the turned belt used to end in a stroke cap, which is a half
  /// circle — 0.5 of the belt width — and looked far blobbier than the
  /// straight belt beside it at the same width.
  static const _endRadiusFactor = 0.2;

  /// Width of the black outline around the belt, in logical pixels.
  ///
  /// A fixed width, so a small belt is outlined as heavily as a big one. The
  /// fit reads it because that ink has to land inside the asset's box like
  /// the rest of the belt, and it is the one length in the whole drawing that
  /// does not scale with the box.
  static const _borderWidth = 2.0;

  /// How far the wagon's chassis sticks out past the belt on each side,
  /// along the rails — the bumpers of the top view. Also the tap target for
  /// the wagon motor's pane, so it is capped against the rail run rather
  /// than allowed to swallow it.
  static double _chassisOverhang(Size size, double wagonWidth) =>
      min(wagonWidth * 0.35, size.width * 0.1);

  /// Roller spacing along the belt, as a fraction of the belt width. The
  /// bars take most of their pitch — real rollers sit nearly touching, and
  /// the thin dark gaps between them are what sells the texture.
  static const _rollerPitchFactor = 0.42;

  /// Fraction of the pitch each roller bar occupies; the rest is gap.
  static const _rollerBarFactor = 0.78;

  /// How far each roller stops short of the belt edge, as a fraction of the
  /// belt width — the strip left over reads as the conveyor's side frames.
  static const _rollerEndInset = 0.10;

  /// What the band is filled with before anything is drawn on it. The roller
  /// style moves the state colour onto the rollers, so its bed is the same
  /// colour darkened — the state stays legible at a glance either way.
  Color get _bandFillColor => style == ConveyorStyle.roller
      ? Color.lerp(color, Colors.black, 0.45)!
      : color;

  void _paintStraightBelt(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final borderRadius = Radius.circular(size.shortestSide * _endRadiusFactor);
    final rrect = RRect.fromRectAndRadius(rect, borderRadius);

    final paint = Paint()
      ..color = _bandFillColor
      ..style = PaintingStyle.fill;
    canvas.drawRRect(rrect, paint);

    if (style == ConveyorStyle.roller) {
      _paintStraightRollers(canvas, size, rrect);
    }

    final border = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = _borderWidth;
    canvas.drawRRect(rrect, border);

    // Draw exclamation mark if needed
    if (showExclamation) {
      _drawExclamation(canvas, size);
      return;
    }
    // 2) draw each batch segment as a plain box
    final paintBorder = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final batchHeight = size.height * 0.8;
    final batchRadius =
        Radius.circular(batchHeight * 0.2); // 20% of batch height

    for (final batch in batches.values) {
      final paintBatch = Paint()..color = batch.color;
      // clamp into [0..1] then to pixels
      final x0 = (batch.start.clamp(0.0, 1.0)) * size.width;
      final x1 = (batch.end.clamp(0.0, 1.0)) * size.width;
      final w = x1 - x0;
      if (w <= 0) continue; // not yet visible / already off

      final rect = Rect.fromLTWH(
        x0,
        (size.height - batchHeight) / 2,
        w,
        batchHeight,
      );
      final rrect = RRect.fromRectAndRadius(rect, batchRadius);

      // fill
      canvas.drawRRect(rrect, paintBatch);
      // border (optional)
      canvas.drawRRect(rrect, paintBorder);
    }

    _drawDirectionArrow(canvas, size);
    _drawFrequency(canvas, size);
  }

  /// One roller: a capsule shaded like a lit cylinder — light crest along
  /// the middle falling off to dark edges — so the belt reads as a row of
  /// metal rollers rather than painted stripes. The crest and the edges are
  /// lerps of the state colour itself, so the equipment-state vocabulary is
  /// untouched: a red roller is still unambiguously red.
  ///
  /// Drawn centred on the origin with its axis along y; the caller
  /// translates (and for turned belts rotates) the canvas into place.
  void _paintRollerBar(Canvas canvas, double bar, double length) {
    final rect = Rect.fromCenter(
        center: Offset.zero, width: bar, height: length + bar);
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(bar / 2));
    // A cylinder under a light that is somewhere, not everywhere: the
    // specular crest sits off-centre and the far side rolls away darker
    // than the near side. Symmetric shading is what made these read as
    // striped paint rather than steel.
    final highlight = Color.lerp(color, Colors.white, 0.55)!;
    final near = Color.lerp(color, Colors.black, 0.25)!;
    final far = Color.lerp(color, Colors.black, 0.45)!;
    canvas.drawRRect(
        rrect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [near, highlight, color, far],
            stops: const [0.0, 0.25, 0.6, 1.0],
          ).createShader(rect));
    // A hairline seats the roller into the bed — without it the gradient's
    // dark edge dissolves into the darkened fill next to it.
    canvas.drawRRect(
        rrect,
        Paint()
          ..color = Colors.black.withValues(alpha: 0.25)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);
  }

  /// Rollers across a straight belt, clipped to the band so the rounded ends
  /// stay clean, over the darkened bed [_paintStraightBelt] laid down.
  void _paintStraightRollers(Canvas canvas, Size size, RRect band) {
    final pitch = max(size.height * _rollerPitchFactor, 4.0);
    final bar = pitch * _rollerBarFactor;
    final len = size.height * (1 - 2 * _rollerEndInset) - bar;
    if (len <= 0) return;
    canvas.save();
    canvas.clipRRect(band);
    // Start half a pitch in so the first roller clears the rounded end, and
    // step from there — the last one may be clipped, which is fine: rollers
    // are a texture, not counted objects.
    for (var x = pitch / 2; x <= size.width - pitch / 4; x += pitch) {
      canvas.save();
      canvas.translate(x, size.height / 2);
      _paintRollerBar(canvas, bar, len);
      canvas.restore();
    }
    canvas.restore();
  }

  /// Rollers along a turned belt: same cylinders as the straight version,
  /// but each sits perpendicular to the centerline's travel at its station.
  void _paintTurnedRollers(
      Canvas canvas, ConveyorPathGeometry g, Path outline) {
    final w = g.beltWidth;
    final pitch = max(w * _rollerPitchFactor, 4.0);
    final bar = pitch * _rollerBarFactor;
    final len = w * (1 - 2 * _rollerEndInset) - bar;
    if (len <= 0) return;
    final length = g.length;
    if (length <= 0) return;
    canvas.save();
    canvas.clipPath(outline);
    for (var d = pitch / 2; d <= length - pitch / 4; d += pitch) {
      final t = g.tangentAt(d / length);
      canvas.save();
      canvas.translate(t.position.dx, t.position.dy);
      canvas.rotate(atan2(t.vector.dy, t.vector.dx));
      _paintRollerBar(canvas, bar, len);
      canvas.restore();
    }
    canvas.restore();
  }

  /// Fraction of the box height the wagon's carriage frame spans. The belt
  /// runs the full height; the carriage sits under its middle, wide enough
  /// to reach both rails and stick out as bumpers along them.
  static const _chassisHeightFraction = 0.45;

  /// The wagon's chassis: the carriage the belt is mounted on, riding the
  /// rails under the belt's middle and sticking out as bumpers on both
  /// sides along the track. Carries the traverse drive's state colour —
  /// the one part of the drawing that answers for the motor that moves
  /// the wagon, and the tap target for its pane.
  void _paintChassis(
      Canvas canvas, Size size, ({double x0, double width}) span) {
    final overhang = _chassisOverhang(size, span.width);
    if (overhang <= 0.5) return;
    final rect = _chassisRect(size);
    final chassisH = rect.height;
    final rrect =
        RRect.fromRectAndRadius(rect, Radius.circular(chassisH * 0.15));
    canvas.drawRRect(
        rrect, Paint()..color = chassisColor ?? Colors.grey.shade600);
    canvas.drawRRect(
        rrect,
        Paint()
          ..color = Colors.black
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);

    // Safety edges: nothing at all while idle — a tripped edge lights its
    // whole bumper with a glow around it, so a small mark still cannot be
    // missed. Saturated red is allowed here by the house rule: a pressed
    // safety edge is exactly the fault-class signal that may shout.
    void trippedEdge(bool leftSide) {
      final radius = Radius.circular(chassisH * 0.15);
      final strip = leftSide
          ? RRect.fromRectAndCorners(
              Rect.fromLTWH(rect.left, rect.top, overhang, chassisH),
              topLeft: radius,
              bottomLeft: radius)
          : RRect.fromRectAndCorners(
              Rect.fromLTWH(
                  rect.right - overhang, rect.top, overhang, chassisH),
              topRight: radius,
              bottomRight: radius);
      canvas.drawRRect(
          strip,
          Paint()
            ..color = safetyColor.withValues(alpha: 0.55)
            ..maskFilter =
                MaskFilter.blur(BlurStyle.normal, max(chassisH * 0.15, 2)));
      canvas.drawRRect(strip, Paint()..color = safetyColor);
      canvas.drawRRect(
          strip,
          Paint()
            ..color = Colors.black
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1);
    }

    if (safetyLeftActive) trippedEdge(true);
    if (safetyRightActive) trippedEdge(false);
  }

  /// The track seen from above: two plain rails running the full box
  /// width, under the wagon's carriage. No sleepers — two clean lines read
  /// as a track at mimic scale without turning into visual noise. Neutral
  /// ink — the track is floor, not equipment state, so it never takes a
  /// colour.
  void _paintTrack(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 2) return;
    final cy = size.height / 2;
    final chassisH = size.height * _chassisHeightFraction;
    // Gauge inside the carriage's reach, so the rails visibly carry it.
    final gauge = chassisH * 0.6;
    final rail = Paint()
      ..color = railInk
      ..style = PaintingStyle.stroke
      ..strokeWidth = max(chassisH * 0.07, 1.5);
    for (final y in [cy - gauge / 2, cy + gauge / 2]) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), rail);
    }
  }

  /// Fills a band along the centerline and outlines it with [border].
  ///
  /// A band too wide for its own bend has no outline to draw, so it falls
  /// back to stroking the centerline — the shape is meaningless at that point
  /// either way, but a solid blob reads as an over-wide belt where a folded
  /// outline reads as a rendering bug.
  void _paintBand(Canvas canvas, ConveyorPathGeometry g, double from, double to,
      {required double width,
      required double radius,
      required Color fill,
      required Paint border}) {
    final outline = g.bandOutline(from, to, width: width, radius: radius);
    if (outline != null) {
      canvas.drawPath(outline, Paint()..color = fill);
      canvas.drawPath(outline, border);
      return;
    }
    final centerline = g.extractFraction(from, to);
    canvas.drawPath(
      centerline,
      Paint()
        ..color = border.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = width + 2 * border.strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(
      centerline,
      Paint()
        ..color = fill
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  /// Path-based rendering used when the conveyor has turns configured.
  ///
  /// Belt and batches are both bands along the centerline, filled and then
  /// outlined — the same recipe [_paintStraightBelt] runs with an `RRect`,
  /// so a belt keeps its silhouette when a turn is added under it.
  void _paintTurnedBelt(Canvas canvas, Size size) {
    final g = geometry!;

    final border = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = _borderWidth;
    // The outline is resolved here rather than through [_paintBand] because
    // the rollers have to land between the fill and the border — and where
    // there is no outline (belt too wide for its bend) the stroked fallback
    // has no honest geometry to space rollers along, so it stays a plain
    // band in every style.
    final outline = g.bandOutline(0, 1,
        width: g.beltWidth, radius: g.beltWidth * _endRadiusFactor);
    if (outline != null) {
      canvas.drawPath(outline, Paint()..color = _bandFillColor);
      if (style == ConveyorStyle.roller) {
        _paintTurnedRollers(canvas, g, outline);
      }
      canvas.drawPath(outline, border);
    } else {
      _paintBand(canvas, g, 0, 1,
          width: g.beltWidth,
          radius: g.beltWidth * _endRadiusFactor,
          fill: _bandFillColor,
          border: border);
    }

    if (showExclamation) {
      _drawExclamation(canvas, size);
      return;
    }

    final batchWidth = g.beltWidth * 0.8;
    final batchRadius = batchWidth * _endRadiusFactor;
    final batchBorder = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    for (final batch in batches.values) {
      final start = batch.start.clamp(0.0, 1.0);
      final end = batch.end.clamp(0.0, 1.0);
      if (end <= start) continue; // not yet visible / already off
      _paintBand(canvas, g, start, end,
          width: batchWidth,
          radius: batchRadius,
          fill: batch.color,
          border: batchBorder);
    }

    _drawDirectionArrow(canvas, size);
    _drawFrequency(canvas, size);
  }

  /// Reference dimension for centered text: the belt width. For straight
  /// conveyors that is the box's short side; for turned conveyors the box is
  /// taller than the belt, so use the fitted belt width instead.
  double _textBasis(Size size) => geometry?.beltWidth ?? size.shortestSide;

  /// Anchor for centered overlays: box center for straight belts, the
  /// centerline midpoint for turned belts (the box center can be off-belt).
  Offset _overlayCenter(Size size) =>
      geometry?.tangentAt(0.5).position ??
      Offset(size.width / 2, size.height / 2);

  void _drawExclamation(Canvas canvas, Size size) {
    canvas.save();
    // Move origin to center of conveyor
    final center = _overlayCenter(size);
    canvas.translate(center.dx, center.dy);
    // Counter-rotate
    canvas.rotate(-angle * pi / 180 - _overlayExtraRotation);
    _counterMirror(canvas);
    // Draw exclamation mark centered at (0,0)
    final textPainter = TextPainter(
      text: TextSpan(
        text: '!',
        style: TextStyle(
          color: Colors.white,
          fontSize: _textBasis(size) * 0.7,
          fontWeight: FontWeight.bold,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    final offset = Offset(
      -textPainter.width / 2,
      -textPainter.height / 2,
    );
    textPainter.paint(canvas, offset);
    canvas.restore();
  }

  void _drawDirectionArrow(Canvas canvas, Size size) {
    // Draw direction arrow for bidirectional conveyors
    if (!bidirectional || frequency == null || frequency == 0) return;
    canvas.save();
    final center = _overlayCenter(size);
    canvas.translate(center.dx, center.dy);

    final arrowLength = size.width * 0.4;
    final arrowSize = _textBasis(size) * 0.25;
    final arrowPaint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Determine direction: positive frequency = right, unless reversed
    final pointsRight = (frequency! > 0) ^ reverseDirection;

    // Shaft
    canvas.drawLine(
      Offset(-arrowLength / 2, 0),
      Offset(arrowLength / 2, 0),
      arrowPaint,
    );

    // Single arrowhead in the running direction
    if (pointsRight) {
      final head = Path()
        ..moveTo(arrowLength / 2 - arrowSize, -arrowSize * 0.5)
        ..lineTo(arrowLength / 2, 0)
        ..lineTo(arrowLength / 2 - arrowSize, arrowSize * 0.5);
      canvas.drawPath(head, arrowPaint);
    } else {
      final head = Path()
        ..moveTo(-arrowLength / 2 + arrowSize, -arrowSize * 0.5)
        ..lineTo(-arrowLength / 2, 0)
        ..lineTo(-arrowLength / 2 + arrowSize, arrowSize * 0.5);
      canvas.drawPath(head, arrowPaint);
    }

    canvas.restore();
  }

  void _drawFrequency(Canvas canvas, Size size) {
    // Draw frequency number in center
    if (!showFrequency || frequency == null) return;
    canvas.save();
    final center = _overlayCenter(size);
    canvas.translate(center.dx, center.dy);
    canvas.rotate(-angle * pi / 180 - _overlayExtraRotation);
    _counterMirror(canvas);
    final textPainter = TextPainter(
      text: TextSpan(
        text: frequency!.toStringAsFixed(1),
        style: TextStyle(
          color: Colors.white,
          fontSize: _textBasis(size) * 0.5,
          fontWeight: FontWeight.bold,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      Offset(-textPainter.width / 2, -textPainter.height / 2),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant ConveyorPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.showExclamation != showExclamation ||
      oldDelegate.bidirectional != bidirectional ||
      oldDelegate.showFrequency != showFrequency ||
      oldDelegate.frequency != frequency ||
      oldDelegate.mirrorX != mirrorX ||
      oldDelegate.mirrorY != mirrorY ||
      oldDelegate.straightBeltWidth != straightBeltWidth ||
      oldDelegate.style != style ||
      oldDelegate.onRails != onRails ||
      oldDelegate.railInk != railInk ||
      oldDelegate.wagonPosition != wagonPosition ||
      oldDelegate.wagonFraction != wagonFraction ||
      oldDelegate.chassisColor != chassisColor ||
      oldDelegate.safetyLeftActive != safetyLeftActive ||
      oldDelegate.safetyRightActive != safetyRightActive ||
      oldDelegate.safetyColor != safetyColor ||
      oldDelegate.wagonBeltAcross != wagonBeltAcross ||
      // Geometry is rebuilt each frame when turns are configured, so curved
      // conveyors repaint on every rebuild (needed for batch animation).
      !identical(oldDelegate.geometry, geometry);
}

/// Series colours for the conveyor trend, fixed so the small preview in the
/// pane and the full chart in the floating dialog read as the same chart.
/// The legend carries the units, so the tile needs no caption repeating them.
const String kConveyorFreqSeries = 'Frequency (Hz)';
const String kConveyorCurrentSeries = 'Current (A)';

const Map<String, Color> conveyorTrendColors = {
  kConveyorFreqSeries: Colors.blue,
  kConveyorCurrentSeries: Colors.orange,
};

/// The conveyor drive pane's Trend tile -- the reference presentation every
/// other line trend on this HMI is measured against.
///
/// Extracted from `_showDrivePane` so there is one object a test can compare
/// against `boxErectorBpmTrendTile`; see the doc there for why the two are
/// pinned to each other rather than left to resemble each other by hand.
PaneGraphTile conveyorTrendTile({required String keyName}) => PaneGraphTile(
      // Two traces on two axes, so they do have to be named — but up here,
      // where naming them costs a text row instead of half the plot's width.
      legend: conveyorTrendColors,
      height: kPaneTrendTileHeight,
      preview: _ConveyorStatsGraphLoader(
        keyName: keyName,
        showButtons: false,
        compact: true,
        xSpan: const Duration(minutes: 5),
      ),
      expandedTitle: '$keyName — trend',
      expandedSize: kPaneTrendDialogSize,
      expandedBuilder: (context) => _ConveyorStatsGraphLoader(
        keyName: keyName,
        xSpan: const Duration(minutes: 30),
      ),
    );

class ConveyorStatsGraph extends ConsumerStatefulWidget {
  final Collector? collector;
  final String keyName;

  /// Pan/zoom/now buttons. Off in the pane preview, on in the floating chart.
  final bool showButtons;

  /// Visible window. The preview shows a short span so the line has shape;
  /// the expanded chart shows more history.
  final Duration xSpan;

  /// Drops the units from the tick labels. In the pane preview there is only
  /// ~20px of gutter, so "48.20 Hz" wraps to four lines and eats the plot —
  /// the tile caption names the units instead.
  final bool compact;

  const ConveyorStatsGraph({
    required this.collector,
    required this.keyName,
    this.showButtons = true,
    this.xSpan = const Duration(minutes: 5),
    this.compact = false,
    super.key,
  });

  @override
  ConsumerState<ConveyorStatsGraph> createState() => _ConveyorStatsGraphState();
}

class _ConveyorStatsGraphState extends ConsumerState<ConveyorStatsGraph> {
  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<TimeseriesData<dynamic>>>(
      stream: widget.collector
          ?.collectStream(widget.keyName, since: const Duration(hours: 2)),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const Center(child: Text('No data'));
        }

        final samples = snapshot.data!;
        final currentData = <List<double>>[];
        final freqData = <List<double>>[];

        // The collector hands over two hours of history but the plot only
        // shows the last [xSpan] of it, so both axes are scaled from the
        // samples inside that window. Scaling to all two hours is what made
        // the traces sit flat and then jump the moment an old extreme aged
        // out of the buffer — see [stableTrendRange].
        final windowStart = DateTime.now()
            .subtract(widget.xSpan)
            .millisecondsSinceEpoch
            .toDouble();
        double minFreq = double.infinity;
        double maxFreq = double.negativeInfinity;
        double maxCurrent = double.negativeInfinity;

        for (final sample in samples) {
          final v = sample.value;
          final current = v['p_stat_Current'] ?? 0.0;
          final freq = v['p_stat_Frequency'] ?? 0.0;
          final time = sample.time.millisecondsSinceEpoch.toDouble();

          currentData.add([time, current]);
          freqData.add([time, freq]);

          if (time < windowStart) continue;
          if (freq < minFreq) minFreq = freq;
          if (freq > maxFreq) maxFreq = freq;
          if (current > maxCurrent) maxCurrent = current;
        }
        // Nothing inside the window yet — a drive that has stopped
        // reporting. Frame the newest sample rather than an empty axis.
        if (minFreq > maxFreq && freqData.isNotEmpty) {
          minFreq = maxFreq = freqData.last[1];
          maxCurrent = currentData.last[1];
        }

        final freqRange = stableTrendRange(minFreq, maxFreq);
        // Current is framed from zero, not from its own minimum. Load tracks
        // speed, so scaling both axes to their own extremes maps the two
        // traces onto the same shape and the second one drawn simply hides
        // the first. Anchoring current at zero separates them — and zero is
        // the meaningful floor for a current reading anyway.
        final currentRange = stableTrendRange(0, maxCurrent, floor: 0);

        // Time along the bottom, frequency on the LEFT axis and current on
        // the RIGHT — frequency is what an operator reads first, so it gets
        // the axis the eye lands on.
        final graphConfig = GraphConfig(
          type: GraphType.timeseries,
          xAxis: GraphAxisConfig(unit: widget.compact ? '' : 'Time'),
          yAxis: GraphAxisConfig(
            unit: widget.compact ? '' : 'Hz',
            min: freqRange.min,
            max: freqRange.max,
          ),
          yAxis2: GraphAxisConfig(
            unit: widget.compact ? '' : 'A',
            min: currentRange.min,
            max: currentRange.max,
          ),
          xSpan: widget.xSpan,
          // The preview names both traces in its tile header instead — the
          // legend column costs it more width than the plot.
          legend: !widget.compact,
        );

        final List<Map<String, dynamic>> data = [];
        data.addAll(freqData
            .map((e) => {'x': e[0], 'y': e[1], 's': kConveyorFreqSeries}));
        data.addAll(currentData
            .map((e) => {'x': e[0], 'y2': e[1], 's': kConveyorCurrentSeries}));

        // The compact preview needs its own gutters: at 130px tall the
        // default padding lets tick labels print over the tile caption and
        // the time row. Same theme otherwise, so both charts still match.
        final theme = widget.compact
            ? (Theme.of(context).brightness == Brightness.dark
                ? darkChartTheme(padding: kCompactChartPadding)
                : lightChartTheme(padding: kCompactChartPadding))
            : ref.watch(chartThemeNotifierProvider);

        return Graph(
          config: graphConfig,
          data: data,
          showButtons: widget.showButtons,
          categoryColors: conveyorTrendColors,
          chartTheme: theme,
          redraw: () {},
        ).build(context);
      },
    );
  }
}

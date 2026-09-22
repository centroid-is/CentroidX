/// Geometry for assets that are a *run* rather than a box.
///
/// Every other asset on a page is a point and a size: `AssetStack` gives it a
/// rectangle and it paints inside. A cable is not that shape. It has two ends
/// that belong to other assets, however many corners the hall put in between,
/// and no meaningful width — so its position is not something an operator
/// types, it is something they draw.
///
/// The model here is the one the four editing benches converged on:
///
///  - **Ends are ports, not points.** A [LinkEnd] names the asset and the port
///    it plugs into. Move the terminal and the cable stays plugged in. An end
///    with no `assetId` falls back to a free page coordinate, which is what a
///    run to somewhere off-page (or to an asset since deleted) degrades to.
///
///  - **Corners are placed, never described.** A [LinkWaypoint] carries no
///    sweep and no per-corner radius. The conveyor's turn panel asks for three
///    numbers per bend, none of which are the thing you are looking at, and
///    all of which move each other; the whole point of this model is that the
///    equivalent numbers are *derived* from where the corner was dropped.
///
///  - **A corner stays where it was put.** By default it is a point on the
///    page ([LinkWaypoint.x], [LinkWaypoint.y]), so moving an end or a device
///    only stretches the segment next to it. Pinned to an asset instead, it
///    is a fixed offset from that asset's box — the truthful model for a run
///    that leaves a cabinet at a fixed point on a tray and only then heads for
///    the device.
///
///    Older pages stored corners in the run's own frame: a fraction
///    [LinkWaypoint.t] along the port-to-port axis and an offset
///    [LinkWaypoint.n] across it, in run lengths. That still resolves, but it
///    is not written any more. On a short cable `n` is several run lengths,
///    so a pixel of end movement swung every corner across the page;
///    [LinkRun.settleOnPage] turns those corners into page points without
///    moving them, and the editor calls it before any edit.
///
/// Everything stored is normalised to the 0..1 page space the rest of the
/// page_creator uses, so a page still scales to any screen. [LinkRun.resolve]
/// is the one place that converts to canvas pixels.
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Path, Radius, Rect, Size;

import 'package:json_annotation/json_annotation.dart';

part 'link_geometry.g.dart';

/// One end of a run.
///
/// [assetId] and [port] are the binding; [x] and [y] are the fallback, in
/// page-relative 0..1 coordinates. The fallback is not dead weight — it is
/// what the end resolves to when the bound asset is missing, and keeping the
/// last resolved position there means a cable whose terminal was deleted stays
/// where the operator drew it instead of collapsing to the origin.
@JsonSerializable()
class LinkEnd {
  /// The asset this end plugs into, or null for a free end.
  String? assetId;

  /// The port on that asset (`'X1'`, `'X2'`…), or null for its default.
  String? port;

  /// Page-relative fallback position, used when [assetId] resolves to nothing.
  double x;
  double y;

  LinkEnd({this.assetId, this.port, this.x = 0.5, this.y = 0.5});

  LinkEnd copy() => LinkEnd(assetId: assetId, port: port, x: x, y: y);

  factory LinkEnd.fromJson(Map<String, dynamic> json) =>
      _$LinkEndFromJson(json);
  Map<String, dynamic> toJson() => _$LinkEndToJson(this);
}

/// One corner of a run.
///
/// Exactly one of the three coordinate pairs is authoritative, and the others
/// are null. [pinnedTo] set means [dx]/[dy]; otherwise [x]/[y] set means a
/// page point; otherwise [t]/[n], the run frame older pages were saved in.
/// Nulling the inactive pairs rather than leaving stale values there is
/// deliberate: two live coordinate systems on one object is how a corner ends
/// up in two places at once, and a null is a reader's proof of which rule
/// holds this corner.
@JsonSerializable()
class LinkWaypoint {
  /// The asset this corner is nailed to, or null.
  String? pinnedTo;

  /// Fraction along the port-to-port axis, for a corner that follows the run.
  double? t;

  /// Offset across that axis, as a fraction of the run's length.
  double? n;

  /// Page-relative offset from the pinned asset's centre. Non-null iff
  /// [pinnedTo] is non-null.
  double? dx;
  double? dy;

  /// Page-relative position of a corner that stays where it was put.
  ///
  /// Left out of the JSON when null, so a page saved before corners could be
  /// page points round-trips exactly as it was.
  @JsonKey(includeIfNull: false)
  double? x;
  @JsonKey(includeIfNull: false)
  double? y;

  LinkWaypoint(
      {this.pinnedTo, this.t, this.n, this.dx, this.dy, this.x, this.y});

  /// A corner held in the frame of the run.
  LinkWaypoint.onRun(double t, double n) : this(t: t, n: n);

  /// A corner at a fixed page-relative point.
  LinkWaypoint.onPage(double x, double y) : this(x: x, y: y);

  /// A corner nailed to [assetId] at a fixed page-relative offset from its
  /// centre.
  LinkWaypoint.pinned(String assetId, double dx, double dy)
      : this(pinnedTo: assetId, dx: dx, dy: dy);

  bool get isPinned => pinnedTo != null;

  /// True for a corner that stays at a page point.
  bool get isOnPage => !isPinned && x != null && y != null;

  /// True for a corner that follows the run — the older, run-frame rule.
  bool get isOnRun => !isPinned && !isOnPage;

  LinkWaypoint copy() =>
      LinkWaypoint(pinnedTo: pinnedTo, t: t, n: n, dx: dx, dy: dy, x: x, y: y);

  factory LinkWaypoint.fromJson(Map<String, dynamic> json) =>
      _$LinkWaypointFromJson(json);
  Map<String, dynamic> toJson() => _$LinkWaypointToJson(this);
}

/// What holds a corner in place: the page, one asset, or the run.
class LinkCornerRule {
  const LinkCornerRule._(this.pinnedTo, this.followsRun);

  /// Stays at a page point. What every new corner gets.
  static const page = LinkCornerRule._(null, false);

  /// Follows the run, rotating and scaling with the line between the ends.
  static const run = LinkCornerRule._(null, true);

  /// A fixed offset from [assetId]'s box.
  const LinkCornerRule.pinned(String assetId) : this._(assetId, false);

  final String? pinnedTo;
  final bool followsRun;

  @override
  bool operator ==(Object other) =>
      other is LinkCornerRule &&
      other.pinnedTo == pinnedTo &&
      other.followsRun == followsRun;

  @override
  int get hashCode => Object.hash(pinnedTo, followsRun);
}

/// Where a run's ends and pinned corners get their positions.
///
/// Answers in **page-relative 0..1 space, unmirrored** — an asset's stored
/// `coordinates`, not the rectangle it was laid out into. Two reasons, and
/// both matter:
///
///  - **Mirroring.** `AssetStack` mirrors a page by flipping each asset's
///    coordinate (`1 - x`) and, for chiral glyphs, mirroring the glyph about
///    its own box centre — which composes to a true mirror about the page
///    centre. A run that resolved against *already mirrored* positions would
///    be mirrored a second time by that transform. Worse, mirroring reverses
///    handedness while [LinkRunFrame.across] is `along` turned a fixed
///    direction, so a corner's `n` would land on the wrong side of the run:
///    the bend would flip while the ends stayed put. Resolving canonically
///    and letting the stack mirror the finished glyph avoids both.
///
///  - **Layout order.** Reading stored coordinates means a run does not have
///    to wait for the assets it names to be laid out first.
///
/// Both methods answer null for an id nothing on the page carries, which is
/// the case that makes an end fall back to its own stored coordinate.
abstract class LinkAnchors {
  /// Page-relative position of a port on [assetId], or null if either the
  /// asset or the port is unknown.
  Offset? portPosition(String assetId, String? port);

  /// Page-relative point a corner pinned to [assetId] is an offset from —
  /// its box centre — or null if unknown.
  Offset? assetAnchor(String assetId);

  /// Nothing is anchored — every end falls back to its stored coordinate.
  static const LinkAnchors none = _NoAnchors();
}

class _NoAnchors implements LinkAnchors {
  const _NoAnchors();
  @override
  Offset? portPosition(String assetId, String? port) => null;
  @override
  Offset? assetAnchor(String assetId) => null;
}

/// The coordinate system a run's unpinned corners are measured in.
///
/// **Page-relative 0..1 space**, not pixels. A corner recorded here moves with
/// the equipment when the page is rendered at a different aspect ratio,
/// exactly as every asset's own coordinate does — measuring it in pixels
/// instead would let the cable drift off the ports it is plugged into the
/// moment the canvas stopped being the shape it was drawn on.
///
/// [along] runs from [start] to [end]; [across] is that turned a quarter turn.
/// Both are unit vectors, so a waypoint's `n` is in units of run length and a
/// shape keeps its proportions when the two devices move apart.
class LinkRunFrame {
  final Offset start;
  final Offset end;
  final Offset along;
  final Offset across;
  final double length;

  const LinkRunFrame._(
      this.start, this.end, this.along, this.across, this.length);

  factory LinkRunFrame(Offset start, Offset end) {
    final d = end - start;
    final l = d.distance;
    // A zero-length run still has to produce a usable basis: both ports on the
    // same point is a real state during a drag, and dividing by it would put
    // every corner at NaN and blank the asset until the pointer moved again.
    if (l < 1e-9) {
      return LinkRunFrame._(
          start, end, const Offset(1, 0), const Offset(0, 1), 0);
    }
    final u = Offset(d.dx / l, d.dy / l);
    return LinkRunFrame._(start, end, u, Offset(-u.dy, u.dx), l);
  }

  /// The page point a run-frame corner sits at.
  Offset place(double t, double n) =>
      start + along * (t * length) + across * (n * length);

  /// The inverse of [place] — where a dropped point sits in this frame.
  ///
  /// A zero-length run has no axis to measure against, so it reports the
  /// origin rather than a division by zero.
  ({double t, double n}) locate(Offset p) {
    if (length < 1e-9) return (t: 0, n: 0);
    final d = p - start;
    return (
      t: (d.dx * along.dx + d.dy * along.dy) / length,
      n: (d.dx * across.dx + d.dy * across.dy) / length,
    );
  }
}

/// A run, resolved against a canvas and its anchors.
///
/// [points] is the skeleton with both ends included, so `points[i + 1]` is
/// waypoint `i` and segment `i` is exactly where a new waypoint `i` would be
/// inserted. The editor's ghost handles and "add point here" both lean on that
/// alignment; breaking it silently inserts corners one place off.
class ResolvedLink {
  /// The skeleton in canvas pixels — what gets painted and hit-tested.
  final List<Offset> points;

  /// The same run's frame in page-relative space, which is where every
  /// editing operation does its arithmetic.
  final LinkRunFrame frame;

  /// The canvas these pixels are for.
  final Size canvas;

  /// Corner radius in canvas pixels, before per-corner clamping.
  ///
  /// Taken from the shortest side and applied *after* the skeleton is scaled,
  /// so a fillet is a circle on screen. Rounding in page space and scaling
  /// afterwards would turn every corner into an ellipse on any canvas that is
  /// not square.
  final double radius;

  ResolvedLink(this.points, this.frame, this.canvas, this.radius);

  /// The waypoints only — the skeleton without its two ends.
  Iterable<Offset> get corners => points.skip(1).take(points.length - 2);

  Path get centreline => roundedPolyline(points, radius);

  /// A closed ribbon [width] pixels across, centred on the run.
  ///
  /// This is what `AssetHitShape` wants: it flattens a path into closed rings
  /// and a bare centreline has none, so publishing the stroke would put no
  /// mark on the page at all. It is also the tap target — a cable painted six
  /// pixels wide is not something a gloved finger can hit, and the hit path
  /// has to be the same object the mark is traced from or the two drift.
  Path outline({required double width}) =>
      strokeOutline(centreline, width: width);

  /// Index of the segment [p] is nearest to, which is the waypoint index a
  /// corner dropped there should take.
  int nearestSegment(Offset p) {
    var best = 0;
    var bestD = double.infinity;
    for (var i = 0; i < points.length - 1; i++) {
      final d = _distanceToSegment(p, points[i], points[i + 1]);
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }

  /// Distance from [p] to the skeleton, in pixels.
  ///
  /// Measured against the straight skeleton rather than the filleted ink. A
  /// fillet only ever cuts the corner *inside* the skeleton, so this reports
  /// at most a corner's worth too little near a bend — it makes the run
  /// marginally easier to hit there, never harder, which is the direction a
  /// tap target should err in.
  double distanceTo(Offset p) {
    var best = double.infinity;
    for (var i = 0; i < points.length - 1; i++) {
      final d = _distanceToSegment(p, points[i], points[i + 1]);
      if (d < best) best = d;
    }
    return best;
  }
}

/// The stored shape of one run.
@JsonSerializable(explicitToJson: true)
class LinkRun {
  LinkEnd from;
  LinkEnd to;
  List<LinkWaypoint> waypoints;

  /// Corner radius as a fraction of the canvas's shortest side.
  ///
  /// One number for the whole run, not one per corner. Per-corner radius is
  /// the field that makes the conveyor's turn panel tiring, and a cable has no
  /// use for it: a run is pulled to one bend radius by the cable's own
  /// stiffness, not to a different one at every corner.
  double radius;

  LinkRun({
    LinkEnd? from,
    LinkEnd? to,
    List<LinkWaypoint>? waypoints,
    this.radius = 0.02,
  })  : from = from ?? LinkEnd(x: 0.3, y: 0.5),
        to = to ?? LinkEnd(x: 0.7, y: 0.5),
        waypoints = waypoints ?? <LinkWaypoint>[];

  factory LinkRun.fromJson(Map<String, dynamic> json) =>
      _$LinkRunFromJson(json);
  Map<String, dynamic> toJson() => _$LinkRunToJson(this);

  LinkRun copy() => LinkRun(
        from: from.copy(),
        to: to.copy(),
        waypoints: [for (final w in waypoints) w.copy()],
        radius: radius,
      );

  /// Resolves this run into canvas pixels.
  ///
  /// [anchors] answers where the bound assets are; anything it does not know
  /// falls back to the end's own stored coordinate.
  ResolvedLink resolve(Size canvas, LinkAnchors anchors) {
    final frame = frameIn(anchors);
    final pts = <Offset>[frame.start];
    for (final w in waypoints) {
      pts.add(_resolveWaypoint(w, frame, anchors));
    }
    pts.add(frame.end);
    return ResolvedLink(
      [for (final p in pts) _toPixels(p, canvas)],
      frame,
      canvas,
      radius * canvas.shortestSide,
    );
  }

  /// This run's frame in page-relative space.
  LinkRunFrame frameIn(LinkAnchors anchors) =>
      LinkRunFrame(_resolveEnd(from, anchors), _resolveEnd(to, anchors));

  static Offset _toPixels(Offset p, Size canvas) =>
      Offset(p.dx * canvas.width, p.dy * canvas.height);

  static Offset _toPage(Offset p, Size canvas) => Offset(
      canvas.width == 0 ? 0 : p.dx / canvas.width,
      canvas.height == 0 ? 0 : p.dy / canvas.height);

  static Offset _resolveEnd(LinkEnd e, LinkAnchors anchors) {
    final id = e.assetId;
    if (id != null) {
      final p = anchors.portPosition(id, e.port);
      if (p != null) return p;
    }
    return Offset(e.x, e.y);
  }

  static Offset _resolveWaypoint(
      LinkWaypoint w, LinkRunFrame frame, LinkAnchors anchors) {
    final pin = w.pinnedTo;
    if (pin != null) {
      final origin = anchors.assetAnchor(pin);
      // A pin whose asset is gone has nothing to be an offset from. Falling
      // back to the run frame keeps the corner on the cable instead of
      // dropping it at the page origin, which is the difference between a
      // page that looks slightly wrong and one that looks broken.
      if (origin != null) return origin + Offset(w.dx ?? 0, w.dy ?? 0);
    }
    final x = w.x, y = w.y;
    if (x != null && y != null) return Offset(x, y);
    return frame.place(w.t ?? 0.5, w.n ?? 0);
  }

  /// Re-expresses [index]'s corner under [rule] **without moving it on
  /// screen**.
  ///
  /// Re-anchoring is a change to the rule that holds a corner, not to where it
  /// is. A corner that jumps when you change what it follows teaches the
  /// operator that the setting is dangerous, and they stop using it.
  void repin(int index, LinkCornerRule rule, {required LinkAnchors anchors}) {
    final frame = frameIn(anchors);
    final at = _resolveWaypoint(waypoints[index], frame, anchors);
    waypoints[index] = _describe(at, rule, frame: frame, anchors: anchors);
  }

  /// Turns every corner that follows the run into a page point where it
  /// already is. Pinned corners and page corners are left alone.
  ///
  /// The editor calls this before any edit, so a legacy corner is converted
  /// the first time somebody touches the cable and never swings again, while
  /// a page nobody edits still saves exactly as it was loaded.
  ///
  /// Returns true if anything changed.
  bool settleOnPage(LinkAnchors anchors) {
    final frame = frameIn(anchors);
    var changed = false;
    for (var i = 0; i < waypoints.length; i++) {
      final w = waypoints[i];
      if (!w.isOnRun) continue;
      final at = _resolveWaypoint(w, frame, anchors);
      waypoints[i] = LinkWaypoint.onPage(at.dx, at.dy);
      changed = true;
    }
    return changed;
  }

  /// The rule currently holding [w].
  static LinkCornerRule ruleOf(LinkWaypoint w) {
    final pin = w.pinnedTo;
    if (pin != null) return LinkCornerRule.pinned(pin);
    return w.isOnPage ? LinkCornerRule.page : LinkCornerRule.run;
  }

  /// Describes the page-space point [at] under [rule].
  static LinkWaypoint _describe(
    Offset at,
    LinkCornerRule rule, {
    required LinkRunFrame frame,
    required LinkAnchors anchors,
  }) {
    final pin = rule.pinnedTo;
    if (pin != null) {
      final origin = anchors.assetAnchor(pin);
      if (origin != null) {
        final d = at - origin;
        return LinkWaypoint.pinned(pin, d.dx, d.dy);
      }
      // Nothing on the page to be an offset from: keep the corner where it is.
      return LinkWaypoint.onPage(at.dx, at.dy);
    }
    if (rule.followsRun) {
      final l = frame.locate(at);
      return LinkWaypoint.onRun(l.t, l.n);
    }
    return LinkWaypoint.onPage(at.dx, at.dy);
  }

  /// Moves the corner at [index] to the canvas point [at], keeping whatever
  /// rule already holds it.
  void moveWaypoint(
    int index,
    Offset at, {
    required Size canvas,
    required LinkAnchors anchors,
  }) {
    waypoints[index] = _describe(_toPage(at, canvas), ruleOf(waypoints[index]),
        frame: frameIn(anchors), anchors: anchors);
  }

  /// Inserts a corner at the canvas point [at], into whichever segment it is
  /// nearest. A fresh corner stays where it was put.
  int insertWaypoint(
    Offset at, {
    required Size canvas,
    required LinkAnchors anchors,
  }) {
    final resolved = resolve(canvas, anchors);
    final seg = resolved.nearestSegment(at);
    waypoints.insert(
        seg,
        _describe(_toPage(at, canvas), LinkCornerRule.page,
            frame: resolved.frame, anchors: anchors));
    return seg;
  }

  /// Moves the free ends and the page corners by ([dx], [dy]) page units.
  ///
  /// This is what dragging an unplugged cable does. Pinned corners and
  /// corners that follow the run move with whatever holds them.
  void translateFree(double dx, double dy) {
    for (final end in [from, to]) {
      end
        ..x += dx
        ..y += dy;
    }
    for (final w in waypoints) {
      if (!w.isOnPage) continue;
      w
        ..x = w.x! + dx
        ..y = w.y! + dy;
    }
  }

  /// Scales the free ends and the page corners about [centre], by [sx]
  /// across and [sy] down.
  void scaleFree(Offset centre, double sx, double sy) {
    Offset scale(Offset p) => Offset(centre.dx + (p.dx - centre.dx) * sx,
        centre.dy + (p.dy - centre.dy) * sy);
    for (final end in [from, to]) {
      final p = scale(Offset(end.x, end.y));
      end
        ..x = p.dx
        ..y = p.dy;
    }
    for (final w in waypoints) {
      if (!w.isOnPage) continue;
      final p = scale(Offset(w.x!, w.y!));
      w
        ..x = p.dx
        ..y = p.dy;
    }
  }

  /// The page-relative box the run occupies, so the asset can publish the
  /// centre and size `AssetStack` positions it by.
  ///
  /// [pad] is in page-relative units and wants to cover the stroke's half
  /// width: a rect measured on the centreline clips half the cable away at
  /// the extremes, and the end caps with it.
  Rect boundsIn(LinkAnchors anchors, {double pad = 0}) {
    final frame = frameIn(anchors);
    final pts = <Offset>[
      frame.start,
      for (final w in waypoints) _resolveWaypoint(w, frame, anchors),
      frame.end,
    ];
    var l = double.infinity, t = double.infinity;
    var r = -double.infinity, b = -double.infinity;
    for (final p in pts) {
      l = math.min(l, p.dx);
      t = math.min(t, p.dy);
      r = math.max(r, p.dx);
      b = math.max(b, p.dy);
    }
    return Rect.fromLTRB(l - pad, t - pad, r + pad, b + pad);
  }
}

/// A polyline with a CAD fillet at every interior vertex.
///
/// [radius] is the radius asked for; each corner takes as much of it as the
/// two segments meeting there can carry and no more. The clamp is the same one
/// `ConveyorPathGeometry` needs for the same reason: the tangent length a
/// fillet consumes is `r / tan(theta / 2)`, which runs away as a corner
/// straightens, so a radius that looks harmless on a long run will eat a short
/// segment whole and leave the run visibly shorter than the one drawn.
///
/// Halving each adjacent segment shares it between the two corners that meet
/// on it, so two tight bends in a row touch rather than overlap.
Path roundedPolyline(List<Offset> pts, double radius) {
  final path = Path();
  if (pts.isEmpty) return path;
  path.moveTo(pts.first.dx, pts.first.dy);
  if (pts.length < 3 || radius <= 0) {
    for (final p in pts.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    return path;
  }

  for (var i = 1; i < pts.length - 1; i++) {
    final p0 = pts[i - 1], p1 = pts[i], p2 = pts[i + 1];
    final v1 = p0 - p1, v2 = p2 - p1;
    final l1 = v1.distance, l2 = v2.distance;
    if (l1 < 1e-9 || l2 < 1e-9) continue;

    final u1 = Offset(v1.dx / l1, v1.dy / l1);
    final u2 = Offset(v2.dx / l2, v2.dy / l2);
    final dot = (u1.dx * u2.dx + u1.dy * u2.dy).clamp(-1.0, 1.0);
    final theta = math.acos(dot);

    // Straight through, or doubled back on itself: no arc to draw. Both would
    // divide by a tangent of zero or infinity.
    if (theta > math.pi - 1e-4 || theta < 1e-4) {
      path.lineTo(p1.dx, p1.dy);
      continue;
    }

    final half = math.tan(theta / 2);
    final tangent = math.min(radius / half, math.min(l1 / 2, l2 / 2));
    final actual = tangent * half;
    final a = p1 + u1 * tangent;
    final b = p1 + u2 * tangent;

    // Screen space is y-down, so a negative cross product is the clockwise
    // turn — which is the sweep direction Flutter calls "clockwise: true".
    final clockwise = (u1.dx * u2.dy - u1.dy * u2.dx) < 0;

    path.lineTo(a.dx, a.dy);
    path.arcToPoint(b,
        radius: Radius.circular(actual), clockwise: clockwise, largeArc: false);
  }
  path.lineTo(pts.last.dx, pts.last.dy);
  return path;
}

/// A closed ribbon [width] across, centred on [centreline].
///
/// Built by walking the path with `computeMetrics` and stepping out along each
/// sample's normal, the same way the conveyor builds a belt band. The step is
/// fine enough that the chord between two samples is indistinguishable from
/// the arc it replaces at any zoom a page is drawn at.
Path strokeOutline(Path centreline, {required double width, double step = 3}) {
  final half = width / 2;
  final left = <Offset>[];
  final right = <Offset>[];

  for (final metric in centreline.computeMetrics()) {
    if (metric.length <= 0) continue;
    // The end sample matters: stopping at the last whole step leaves the
    // ribbon short of the connector, and the tap target with it.
    for (var d = 0.0;; d += step) {
      final at = math.min(d, metric.length);
      final tan = metric.getTangentForOffset(at);
      if (tan != null) {
        final n = Offset(-tan.vector.dy, tan.vector.dx);
        left.add(tan.position + n * half);
        right.add(tan.position - n * half);
      }
      if (at >= metric.length) break;
    }
  }

  final path = Path();
  if (left.length < 2) return path;
  path.moveTo(left.first.dx, left.first.dy);
  for (final p in left.skip(1)) {
    path.lineTo(p.dx, p.dy);
  }
  for (final p in right.reversed) {
    path.lineTo(p.dx, p.dy);
  }
  path.close();
  return path;
}

double _distanceToSegment(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final l2 = ab.dx * ab.dx + ab.dy * ab.dy;
  if (l2 < 1e-12) return (p - a).distance;
  var t = ((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / l2;
  t = t.clamp(0.0, 1.0);
  return (p - (a + ab * t)).distance;
}

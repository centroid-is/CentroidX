import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/link_geometry.dart';

/// Anchors backed by a plain map, so a test can say exactly where a device is
/// without standing up a page. Positions are page-relative 0..1, canonical
/// (unmirrored) -- see [LinkAnchors].
class _FakeAnchors implements LinkAnchors {
  _FakeAnchors({Map<String, Rect>? boxes, Map<String, Offset>? ports})
      : boxes = boxes ?? {},
        ports = ports ?? {};

  final Map<String, Rect> boxes;

  /// Keyed `'assetId/port'`.
  final Map<String, Offset> ports;

  @override
  Offset? portPosition(String assetId, String? port) =>
      ports['$assetId/$port'] ?? boxes[assetId]?.centerRight;

  @override
  Offset? assetAnchor(String assetId) => boxes[assetId]?.center;
}

/// Samples a path into points, for asserting about ink rather than about the
/// call sequence that produced it.
List<Offset> _sample(Path p, {double step = 1}) {
  final out = <Offset>[];
  for (final m in p.computeMetrics()) {
    for (var d = 0.0; d < m.length; d += step) {
      final t = m.getTangentForOffset(d);
      if (t != null) out.add(t.position);
    }
    final t = m.getTangentForOffset(m.length);
    if (t != null) out.add(t.position);
  }
  return out;
}

double _pathLength(Path p) {
  var total = 0.0;
  for (final m in p.computeMetrics()) {
    total += m.length;
  }
  return total;
}

void main() {
  const canvas = Size(1000, 800);

  group('roundedPolyline', () {
    test('a two-point run is the straight line between them', () {
      final path = roundedPolyline([const Offset(10, 10), const Offset(90, 10)],
          20 /* radius, irrelevant with no corner */);
      expect(_pathLength(path), closeTo(80, 0.01));
    });

    test('zero radius leaves the corner sharp', () {
      final pts = [
        const Offset(0, 0),
        const Offset(100, 0),
        const Offset(100, 100)
      ];
      expect(_pathLength(roundedPolyline(pts, 0)), closeTo(200, 0.01));
    });

    test('a right-angle fillet shortens the run by the expected amount', () {
      // Two 100px legs meeting at 90 degrees with r = 20: each leg gives up
      // 20px of tangent, and the quarter arc that replaces the 40px removed is
      // 2*pi*20/4 long.
      final pts = [
        const Offset(0, 0),
        const Offset(100, 0),
        const Offset(100, 100)
      ];
      final expected = 200 - 40 + (math.pi * 20 / 2);
      expect(_pathLength(roundedPolyline(pts, 20)), closeTo(expected, 0.5));
    });

    test('the arc bulges towards the inside of the corner, not the outside',
        () {
      // The corner point itself must no longer be on the ink: a fillet cuts
      // the corner off. Drawing the arc the other way is the classic sweep-flag
      // bug and produces a loop that is easy to miss on a thin stroke.
      final pts = [
        const Offset(0, 0),
        const Offset(100, 0),
        const Offset(100, 100)
      ];
      final ink = _sample(roundedPolyline(pts, 20));
      final nearestToCorner =
          ink.map((p) => (p - const Offset(100, 0)).distance).reduce(math.min);
      // The arc's closest approach to a filleted right angle is r*(sqrt2 - 1).
      expect(nearestToCorner, closeTo(20 * (math.sqrt2 - 1), 0.6));
      // And every sample stays inside the leg box, so nothing overshoots.
      for (final p in ink) {
        expect(p.dx, lessThanOrEqualTo(100.01));
        expect(p.dy, greaterThanOrEqualTo(-0.01));
      }
    });

    test('turning the other way bulges the other way too', () {
      final up = _sample(roundedPolyline([
        const Offset(0, 0),
        const Offset(100, 0),
        const Offset(100, -100),
      ], 20));
      for (final p in up) {
        expect(p.dy, lessThanOrEqualTo(0.01));
      }
    });

    test('a radius too big for its segments is clamped, not honoured', () {
      // 10px legs cannot carry a 100px radius. Without the clamp the tangent
      // runs past both neighbours and the path folds back on itself.
      final pts = [
        const Offset(0, 0),
        const Offset(10, 0),
        const Offset(10, 10)
      ];
      final path = roundedPolyline(pts, 100);
      final ink = _sample(path, step: 0.5);
      for (final p in ink) {
        expect(p.dx, inInclusiveRange(-0.01, 10.01));
        expect(p.dy, inInclusiveRange(-0.01, 10.01));
      }
      // Still shorter than the sharp corner, so a fillet did happen.
      expect(_pathLength(path), lessThan(20));
    });

    test('two tight corners on one short segment do not overlap', () {
      // Each corner may take at most half the segment they share, so the run
      // stays monotonic along x instead of doubling back.
      final pts = [
        const Offset(0, 0),
        const Offset(40, 0),
        const Offset(60, 40),
        const Offset(100, 40),
      ];
      final ink = _sample(roundedPolyline(pts, 60), step: 0.5);
      for (var i = 1; i < ink.length; i++) {
        expect(ink[i].dx, greaterThanOrEqualTo(ink[i - 1].dx - 0.01),
            reason: 'run doubled back at sample $i');
      }
    });

    test('a collinear vertex is passed straight through', () {
      final pts = [
        const Offset(0, 0),
        const Offset(50, 0),
        const Offset(100, 0)
      ];
      expect(_pathLength(roundedPolyline(pts, 20)), closeTo(100, 0.01));
    });

    test('a duplicated vertex does not produce NaN', () {
      final pts = [
        const Offset(0, 0),
        const Offset(50, 0),
        const Offset(50, 0),
        const Offset(100, 0),
      ];
      final len = _pathLength(roundedPolyline(pts, 20));
      expect(len.isNaN, isFalse);
      expect(len, closeTo(100, 0.01));
    });
  });

  group('LinkRunFrame', () {
    test('place and locate are inverses', () {
      final f = LinkRunFrame(const Offset(100, 100), const Offset(300, 200));
      final p = f.place(0.4, -0.2);
      final back = f.locate(p);
      expect(back.t, closeTo(0.4, 1e-9));
      expect(back.n, closeTo(-0.2, 1e-9));
    });

    test('positive n is screen-down for a left-to-right run', () {
      // Pins the sign convention, not just its self-consistency. `place` and
      // `locate` share the basis, so every round-trip test passes just as
      // happily with `across` flipped -- and a flip mirrors the bend in every
      // cable already saved. This is the assertion that notices.
      final f = LinkRunFrame(const Offset(0, 100), const Offset(200, 100));
      expect(f.across, const Offset(0, 1));
      expect(f.place(0.5, 0.25).dy, greaterThan(100));
      expect(f.place(0.5, -0.25).dy, lessThan(100));
      // And the handedness holds when the run points elsewhere: across is
      // always along turned a quarter-turn clockwise on screen.
      final down = LinkRunFrame(const Offset(100, 0), const Offset(100, 200));
      expect(down.across.dx, closeTo(-1, 1e-9));
      expect(down.across.dy, closeTo(0, 1e-9));
    });

    test('a zero-length run degrades instead of producing NaN', () {
      final f = LinkRunFrame(const Offset(50, 50), const Offset(50, 50));
      final p = f.place(0.5, 0.5);
      expect(p.dx.isNaN, isFalse);
      expect(p.dy.isNaN, isFalse);
      expect(f.locate(const Offset(10, 10)).t, 0);
    });
  });

  group('LinkRun.resolve', () {
    test('an unbound end falls back to its stored page coordinate', () {
      final run = LinkRun(
        from: LinkEnd(x: 0.1, y: 0.5),
        to: LinkEnd(x: 0.9, y: 0.5),
      );
      final r = run.resolve(canvas, LinkAnchors.none);
      expect(r.points.first, const Offset(100, 400));
      expect(r.points.last, const Offset(900, 400));
    });

    test('a bound end takes the port position', () {
      final anchors = _FakeAnchors(ports: {'ek/X2': const Offset(0.2, 0.125)});
      final run = LinkRun(
        from: LinkEnd(assetId: 'ek', port: 'X2', x: 0.1, y: 0.5),
        to: LinkEnd(x: 0.9, y: 0.5),
      );
      expect(run.resolve(canvas, anchors).points.first, const Offset(200, 100));
    });

    test('an end bound to a missing asset falls back rather than vanishing',
        () {
      // A terminal deleted out from under a cable must leave the cable where
      // it was drawn, not collapse it to the canvas origin.
      final run = LinkRun(
        from: LinkEnd(assetId: 'gone', port: 'X2', x: 0.25, y: 0.25),
        to: LinkEnd(x: 0.9, y: 0.5),
      );
      expect(run.resolve(canvas, LinkAnchors.none).points.first,
          const Offset(250, 200));
    });

    test('points line up with waypoint indices', () {
      final run = LinkRun(
        from: LinkEnd(x: 0, y: 0),
        to: LinkEnd(x: 1, y: 0),
        waypoints: [LinkWaypoint.onRun(0.25, 0), LinkWaypoint.onRun(0.75, 0)],
      );
      final r = run.resolve(canvas, LinkAnchors.none);
      expect(r.points, hasLength(4));
      expect(r.points[1].dx, closeTo(250, 0.01));
      expect(r.points[2].dx, closeTo(750, 0.01));
      expect(r.corners, hasLength(2));
    });
  });

  group('waypoints follow what they are told to follow', () {
    LinkRun runWith(LinkWaypoint w) => LinkRun(
          from: LinkEnd(assetId: 'a', port: 'X2'),
          to: LinkEnd(assetId: 'b', port: 'X1'),
          waypoints: [w],
        );

    test('a run-frame corner rides both ends', () {
      final anchors = _FakeAnchors(ports: {
        'a/X2': const Offset(0.1, 0.125),
        'b/X1': const Offset(0.3, 0.125),
      });
      final run = runWith(LinkWaypoint.onRun(0.5, 0));
      expect(run.resolve(canvas, anchors).points[1],
          within(distance: 1e-6, from: const Offset(200, 100)));

      // Move the far end: the corner moves with the frame.
      anchors.ports['b/X1'] = const Offset(0.5, 0.125);
      expect(run.resolve(canvas, anchors).points[1],
          within(distance: 1e-6, from: const Offset(300, 100)));
    });

    test('a run-frame corner near one end mostly follows that end', () {
      // The blend is what makes the run frame the right default: a corner at
      // t = 0.1 belongs to the near device far more than to the far one.
      final anchors = _FakeAnchors(ports: {
        'a/X2': const Offset(0, 0),
        'b/X1': const Offset(1, 0),
      });
      final run = runWith(LinkWaypoint.onRun(0.1, 0));
      final before = run.resolve(canvas, anchors).points[1];

      anchors.ports['a/X2'] =
          const Offset(0, 0.125); // near end moves 100px down
      final afterNear = run.resolve(canvas, anchors).points[1];
      expect(afterNear.dy - before.dy, closeTo(90, 0.5));

      anchors.ports['a/X2'] = const Offset(0, 0);
      anchors.ports['b/X1'] = const Offset(1, 0.125); // far end moves instead
      final afterFar = run.resolve(canvas, anchors).points[1];
      expect(afterFar.dy - before.dy, closeTo(10, 0.5));
    });

    test('a pinned corner ignores the far end entirely', () {
      final anchors = _FakeAnchors(
        boxes: {'a': const Rect.fromLTWH(0.1, 0.125, 0.06, 0.05)},
        ports: {
          'a/X2': const Offset(0.16, 0.15),
          'b/X1': const Offset(0.5, 0.15),
        },
      );
      final run = runWith(LinkWaypoint.pinned('a', 0.25, 0.05));
      final before = run.resolve(canvas, anchors).points[1];

      anchors.ports['b/X1'] = const Offset(0.9, 0.875);
      expect(run.resolve(canvas, anchors).points[1],
          within(distance: 1e-6, from: before));
    });

    test('a pinned corner translates rigidly with its own asset', () {
      final anchors = _FakeAnchors(
        boxes: {'a': const Rect.fromLTWH(0.1, 0.125, 0.06, 0.05)},
        ports: {
          'a/X2': const Offset(0.16, 0.15),
          'b/X1': const Offset(0.5, 0.15),
        },
      );
      final run = runWith(LinkWaypoint.pinned('a', 0.1, 0.1));
      final before = run.resolve(canvas, anchors).points[1];

      anchors.boxes['a'] = const Rect.fromLTWH(0.14, 0.2125, 0.06, 0.05);
      anchors.ports['a/X2'] = const Offset(0.2, 0.2375);
      final after = run.resolve(canvas, anchors).points[1];
      expect(
          after - before, within(distance: 1e-6, from: const Offset(40, 70)));
    });

    test('a pin whose asset is gone falls back to the run frame', () {
      final anchors = _FakeAnchors(ports: {
        'a/X2': const Offset(0, 0),
        'b/X1': const Offset(0.4, 0),
      });
      final run = runWith(LinkWaypoint.pinned('deleted', 0.1, 0.1));
      final p = run.resolve(canvas, anchors).points[1];
      expect(p.dx.isNaN, isFalse);
      // Placed on the run, not at the canvas origin.
      expect(p.dx, inInclusiveRange(0, 400));
    });
  });

  group('editing', () {
    late _FakeAnchors anchors;
    late LinkRun run;

    setUp(() {
      anchors = _FakeAnchors(
        boxes: {
          'a': const Rect.fromLTWH(0, 0, 0.1, 0.0625),
          'b': const Rect.fromLTWH(0.6, 0, 0.1, 0.0625),
        },
        ports: {
          'a/X2': const Offset(0.1, 0),
          'b/X1': const Offset(0.6, 0),
        },
      );
      run = LinkRun(
        from: LinkEnd(assetId: 'a', port: 'X2'),
        to: LinkEnd(assetId: 'b', port: 'X1'),
      );
    });

    test('a new corner lands in the segment it was dropped nearest', () {
      run.waypoints.add(LinkWaypoint.onRun(0.5, 0.2));
      // Segment 1 runs from the corner to the far end; drop near its middle.
      final resolved = run.resolve(canvas, anchors);
      final target = (resolved.points[1] + resolved.points[2]) / 2;
      final at = run.insertWaypoint(target, canvas: canvas, anchors: anchors);
      expect(at, 1);
      expect(run.waypoints, hasLength(2));
      expect(
          run.resolve(canvas, anchors).points[2].dx, closeTo(target.dx, 0.5));
    });

    test('an inserted corner stays where it was put', () {
      run.insertWaypoint(const Offset(300, 40),
          canvas: canvas, anchors: anchors);
      final w = run.waypoints.single;
      expect(w.isOnPage, isTrue);
      expect(w.t, isNull);
      expect(w.n, isNull);
      expect(w.dx, isNull);
      expect(run.resolve(canvas, anchors).points[1],
          within(distance: 0.01, from: const Offset(300, 40)));
    });

    test('a page corner does not move when an end does', () {
      // The bug this model exists to fix: a corner held in the run's frame
      // swung with every pixel an end moved.
      final free = LinkRun(
        from: LinkEnd(x: 0.42, y: 0.93),
        to: LinkEnd(x: 0.44, y: 0.93),
      );
      free.insertWaypoint(const Offset(215, 480),
          canvas: canvas, anchors: anchors);
      final before = free.resolve(canvas, anchors).points[1];
      free.to
        ..x = 0.9
        ..y = 0.1;
      expect(free.resolve(canvas, anchors).points[1],
          within(distance: 0.01, from: before));
    });

    test('corners on a very short cable are stored as sane numbers', () {
      final short = LinkRun(
        from: LinkEnd(x: 0.42, y: 0.93),
        to: LinkEnd(x: 0.44, y: 0.93),
      );
      short.insertWaypoint(const Offset(300, 100),
          canvas: canvas, anchors: anchors);
      final w = short.waypoints.single;
      expect(w.x, closeTo(300 / canvas.width, 1e-9));
      expect(w.y, closeTo(100 / canvas.height, 1e-9));
    });

    test('settling a run-frame corner onto the page does not move it', () {
      run.waypoints
        ..add(LinkWaypoint.onRun(0.4, 0.15))
        ..add(LinkWaypoint.pinned('a', 0.2, 0.1));
      final before = run.resolve(canvas, anchors).points;

      expect(run.settleOnPage(anchors), isTrue);
      expect(run.waypoints[0].isOnPage, isTrue);
      expect(run.waypoints[0].t, isNull);
      expect(run.waypoints[0].n, isNull);
      expect(run.waypoints[1].pinnedTo, 'a',
          reason: 'a pinned corner keeps its pin');
      final after = run.resolve(canvas, anchors).points;
      for (var i = 0; i < before.length; i++) {
        expect(after[i], within(distance: 0.01, from: before[i]));
      }
      expect(run.settleOnPage(anchors), isFalse,
          reason: 'nothing left to settle the second time');
    });

    test('a page saved before page corners loads and saves unchanged', () {
      final json = {
        'pinnedTo': null,
        't': 0.4,
        'n': 0.15,
        'dx': null,
        'dy': null,
      };
      final w = LinkWaypoint.fromJson(json);
      expect(w.isOnRun, isTrue);
      expect(w.toJson(), json);
    });

    test('a page corner round-trips through JSON', () {
      final w = LinkWaypoint.fromJson(
          LinkWaypoint.onPage(0.25, 0.75).toJson());
      expect(w.isOnPage, isTrue);
      expect(w.x, 0.25);
      expect(w.y, 0.75);
    });

    test('moving a corner keeps whichever rule already held it', () {
      run.waypoints.add(LinkWaypoint.pinned('a', 0.2, 0.1));
      run.moveWaypoint(0, const Offset(250, 90),
          canvas: canvas, anchors: anchors);
      expect(run.waypoints.single.pinnedTo, 'a');
      expect(run.resolve(canvas, anchors).points[1],
          within(distance: 0.5, from: const Offset(250, 90)));
    });

    test('repinning does not move the corner on screen', () {
      run.waypoints.add(LinkWaypoint.onRun(0.4, 0.15));
      final before = run.resolve(canvas, anchors).points[1];

      run.repin(0, const LinkCornerRule.pinned('a'), anchors: anchors);
      expect(run.waypoints.single.pinnedTo, 'a');
      expect(run.resolve(canvas, anchors).points[1],
          within(distance: 0.01, from: before));

      run.repin(0, LinkCornerRule.page, anchors: anchors);
      expect(run.waypoints.single.isOnPage, isTrue);
      expect(run.resolve(canvas, anchors).points[1],
          within(distance: 0.01, from: before));

      run.repin(0, LinkCornerRule.run, anchors: anchors);
      expect(run.waypoints.single.isOnRun, isTrue);
      expect(run.resolve(canvas, anchors).points[1],
          within(distance: 0.01, from: before));
    });

    test('repinning nulls the coordinate pair it no longer uses', () {
      // Two live coordinate systems on one corner is how it ends up in two
      // places; the inactive pair has to actually be gone.
      run.waypoints.add(LinkWaypoint.onRun(0.4, 0.15));
      run.repin(0, const LinkCornerRule.pinned('a'), anchors: anchors);
      expect(run.waypoints.single.t, isNull);
      expect(run.waypoints.single.n, isNull);
      expect(run.waypoints.single.dx, isNotNull);

      run.repin(0, LinkCornerRule.page, anchors: anchors);
      expect(run.waypoints.single.dx, isNull);
      expect(run.waypoints.single.dy, isNull);
      expect(run.waypoints.single.t, isNull);
      expect(run.waypoints.single.x, isNotNull);

      run.repin(0, LinkCornerRule.run, anchors: anchors);
      expect(run.waypoints.single.x, isNull);
      expect(run.waypoints.single.y, isNull);
      expect(run.waypoints.single.t, isNotNull);
    });
  });

  group('aspect ratio', () {
    _FakeAnchors twoDevices() => _FakeAnchors(
          boxes: {'a': const Rect.fromLTWH(0.1, 0.2, 0.1, 0.06)},
          ports: {
            'a/X2': const Offset(0.2, 0.25),
            'b/X1': const Offset(0.8, 0.75),
          },
        );

    LinkRun bent() => LinkRun(
          from: LinkEnd(assetId: 'a', port: 'X2'),
          to: LinkEnd(assetId: 'b', port: 'X1'),
          waypoints: [LinkWaypoint.onRun(0.4, 0.25)],
        );

    test('the run scales with the canvas', () {
      // Halving both axes halves every coordinate: the drawing is the same
      // drawing, rendered smaller.
      final run = bent();
      final big = run.resolve(const Size(1000, 800), twoDevices()).points;
      final small = run.resolve(const Size(500, 400), twoDevices()).points;
      expect(big, hasLength(small.length));
      for (var i = 0; i < big.length; i++) {
        expect(small[i], within(distance: 1e-6, from: big[i] / 2));
      }
    });

    test('a corner keeps its place among the equipment when the aspect changes',
        () {
      // The devices are positioned in page fractions, so they squash with the
      // canvas. A corner measured in pixels would not, and the cable would
      // slide off the ports the moment the page was drawn on a different
      // shape of screen. Measured in page space it squashes with them.
      final run = bent();
      const wide = Size(1000, 400);
      const tall = Size(1000, 1000);

      Offset pageCorner(Size c) {
        final p = run.resolve(c, twoDevices()).points[1];
        return Offset(p.dx / c.width, p.dy / c.height);
      }

      expect(pageCorner(wide), within(distance: 1e-9, from: pageCorner(tall)));
    });

    test('the fillet is circular on screen, not squashed by the canvas', () {
      // The skeleton is scaled first and rounded afterwards. Rounding in page
      // space and scaling after would make every corner an ellipse on any
      // canvas that is not square.
      final run = bent()..radius = 0.05;
      const squashed = Size(1000, 250);
      final r = run.resolve(squashed, twoDevices());
      expect(r.radius, closeTo(0.05 * 250, 1e-9));
    });
  });

  group('mirroring', () {
    // `AssetStack` mirrors a page by flipping each asset's coordinate and then
    // mirroring a chiral glyph about its own box centre -- which composes to a
    // true mirror about the page centre. The run therefore resolves against
    // canonical positions and lets the stack do the flip.

    Offset mirrorX(Offset p) => Offset(1 - p.dx, p.dy);

    test('resolving against mirrored anchors puts the bend on the wrong side',
        () {
      // This is the trap, kept as a test so nobody "fixes" LinkAnchors to feed
      // it laid-out (already mirrored) rectangles. Mirroring reverses
      // handedness, but `across` is `along` turned a fixed direction, so the
      // ends would land correctly and the bend would flip across the run.
      final canonical = _FakeAnchors(ports: {
        'a/X2': const Offset(0.2, 0.5),
        'b/X1': const Offset(0.8, 0.5),
      });
      final mirrored = _FakeAnchors(ports: {
        'a/X2': mirrorX(const Offset(0.2, 0.5)),
        'b/X1': mirrorX(const Offset(0.8, 0.5)),
      });
      final run = LinkRun(
        from: LinkEnd(assetId: 'a', port: 'X2'),
        to: LinkEnd(assetId: 'b', port: 'X1'),
        waypoints: [LinkWaypoint.onRun(0.5, 0.2)],
      );

      final want = mirrorX(run.frameIn(canonical).place(0.5, 0.2));
      final got = run.frameIn(mirrored).place(0.5, 0.2);

      expect(got.dx, closeTo(want.dx, 1e-9), reason: 'ends mirror fine');
      // ...but the bend has crossed to the other side of the run.
      expect(got.dy, isNot(closeTo(want.dy, 1e-6)));
      expect(got.dy - 0.5, closeTo(-(want.dy - 0.5), 1e-9));
    });

    test('a run resolved canonically is independent of the page mirror', () {
      // The geometry never sees the mirror flags -- that is the whole point.
      // The stack mirrors the finished glyph, so chirality, `n` signs and
      // pinned offsets all come out right without the run knowing.
      final anchors = _FakeAnchors(
        boxes: {'a': const Rect.fromLTWH(0.1, 0.4, 0.1, 0.06)},
        ports: {
          'a/X2': const Offset(0.2, 0.43),
          'b/X1': const Offset(0.8, 0.5),
        },
      );
      final run = LinkRun(
        from: LinkEnd(assetId: 'a', port: 'X2'),
        to: LinkEnd(assetId: 'b', port: 'X1'),
        waypoints: [
          LinkWaypoint.onRun(0.4, 0.2),
          LinkWaypoint.pinned('a', 0.05, -0.03),
        ],
      );
      final once = run.resolve(canvas, anchors).points;
      final twice = run.resolve(canvas, anchors).points;
      expect(once, twice);

      // And every point is inside the canvas, so the mirror the stack applies
      // has a sane box to work in.
      final b = run.boundsIn(anchors, pad: 0.01);
      expect(b.left, greaterThan(-0.5));
      expect(b.right, lessThan(1.5));
    });
  });

  group('hit testing', () {
    test('distance is measured to the run, not to its bounding box', () {
      final run = LinkRun(
        from: LinkEnd(x: 0, y: 0),
        to: LinkEnd(x: 1, y: 1),
      );
      final r = run.resolve(canvas, LinkAnchors.none);
      // The far corner of the box is nowhere near the diagonal.
      expect(r.distanceTo(const Offset(1000, 0)), greaterThan(500));
      expect(r.distanceTo(const Offset(500, 400)), lessThan(1));
    });

    test('the outline is a closed ring around the run', () {
      final run = LinkRun(
        from: LinkEnd(x: 0.1, y: 0.5),
        to: LinkEnd(x: 0.9, y: 0.5),
      );
      final outline = run.resolve(canvas, LinkAnchors.none).outline(width: 24);

      // Closed, so AssetHitShape's ring walk finds it at all.
      expect(outline.computeMetrics().first.isClosed, isTrue);
      // Wide enough to be tappable off the centreline, and bounded.
      expect(outline.contains(const Offset(500, 400)), isTrue);
      expect(outline.contains(const Offset(500, 409)), isTrue);
      expect(outline.contains(const Offset(500, 430)), isFalse);
    });

    test('the outline follows a bend rather than cutting the corner', () {
      final run = LinkRun(
        from: LinkEnd(x: 0.1, y: 0.2),
        to: LinkEnd(x: 0.9, y: 0.8),
        waypoints: [LinkWaypoint.onRun(0.5, 0.3)],
      );
      final resolved = run.resolve(canvas, LinkAnchors.none);
      final outline = resolved.outline(width: 24);
      expect(outline.contains(resolved.points[1]), isTrue);
      // The straight line between the two ends is not on the cable here.
      final chord = (resolved.points.first + resolved.points.last) / 2;
      expect(outline.contains(chord), isFalse);
    });
  });

  group('bounds', () {
    test('covers every point of the run', () {
      final run = LinkRun(
        from: LinkEnd(x: 0.2, y: 0.5),
        to: LinkEnd(x: 0.8, y: 0.5),
        waypoints: [LinkWaypoint.onRun(0.5, -0.4)],
      );
      final b = run.boundsIn(LinkAnchors.none, pad: 0.01);
      for (final p in run.resolve(canvas, LinkAnchors.none).points) {
        final page = Offset(p.dx / canvas.width, p.dy / canvas.height);
        expect(b.contains(page), isTrue, reason: '$page outside $b');
      }
      // The padding is real, so the stroke's caps are inside the box too.
      expect(b.left, lessThan(0.2));
    });
  });

  group('serialization', () {
    test('round-trips through JSON', () {
      final run = LinkRun(
        from: LinkEnd(assetId: 'ek1100', port: 'X2', x: 0.1, y: 0.2),
        to: LinkEnd(assetId: 'ep2338', port: 'X1', x: 0.8, y: 0.7),
        waypoints: [
          LinkWaypoint.onRun(0.3, -0.1),
          LinkWaypoint.pinned('ek1100', 0.05, 0.02),
        ],
        radius: 0.03,
      );
      final back = LinkRun.fromJson(run.toJson());

      expect(back.from.assetId, 'ek1100');
      expect(back.from.port, 'X2');
      expect(back.to.assetId, 'ep2338');
      expect(back.radius, 0.03);
      expect(back.waypoints, hasLength(2));
      expect(back.waypoints[0].t, closeTo(0.3, 1e-9));
      expect(back.waypoints[0].pinnedTo, isNull);
      expect(back.waypoints[1].pinnedTo, 'ek1100');
      expect(back.waypoints[1].dx, closeTo(0.05, 1e-9));
      expect(back.waypoints[1].t, isNull);
    });

    test('a run stored before waypoints existed reads as a straight cable', () {
      final json = LinkRun().toJson()..remove('waypoints');
      expect(LinkRun.fromJson(json).waypoints, isEmpty);
    });

    test('copy does not share waypoints with the original', () {
      final run = LinkRun(waypoints: [LinkWaypoint.onRun(0.5, 0)]);
      final c = run.copy();
      c.waypoints.single.t = 0.9;
      c.waypoints.add(LinkWaypoint.onRun(0.2, 0));
      expect(run.waypoints, hasLength(1));
      expect(run.waypoints.single.t, 0.5);
    });
  });
}

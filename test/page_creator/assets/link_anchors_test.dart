import 'dart:ui';

import 'package:flutter/material.dart' show Widget;
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/beckhoff.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/ethercat_asset.dart';
import 'package:tfc/page_creator/assets/link_anchors.dart';
import 'package:tfc/page_creator/assets/registry.dart';
import 'package:tfc/page_creator/assets/link_geometry.dart';

/// A bare asset with a settable box, standing in for a terminal.
class _Box extends BaseAsset {
  _Box({double x = 0.5, double y = 0.5, double w = 0.1, double h = 0.05}) {
    coordinates = Coordinates(x: x, y: y);
    size = RelativeSize(width: w, height: h);
  }

  @override
  Widget build(context) => throw UnimplementedError();
  @override
  Widget configure(context) => throw UnimplementedError();
  @override
  Map<String, dynamic> toJson() => const {};
}

/// A terminal that declares its own sockets, both on one face.
class _TwoOnTheRight extends _Box implements NetworkPorted {
  _TwoOnTheRight({super.x, super.y, super.w, super.h});

  @override
  List<NetworkPort> get networkPorts => const [
        NetworkPort('X1', PortSide.right, at: 0.25),
        NetworkPort('X2', PortSide.right, at: 0.75),
      ];
}

/// A device whose socket is drawn in the middle of its face, on a glyph of a
/// fixed shape — a drive's option card, a power supply's two RJ45s.
class _SocketOnTheFace extends _Box implements NetworkPorted, NativelySized {
  _SocketOnTheFace({super.x, super.y, super.w, super.h, this.glyph});

  /// Null stands for a drawing that simply fills whatever box it is given.
  final Size? glyph;

  @override
  Size get nativeSize => glyph ?? Size.zero;

  @override
  List<NetworkPort> get networkPorts => const [
        NetworkPort('A', PortSide.left, at: 0.5, face: Offset(0.25, 0.8)),
      ];
}

void main() {
  const canvas = Size(1000, 500);

  group('ports', () {
    test('an asset that declares none still accepts a cable', () {
      // Otherwise a run could not be drawn until all 40-odd device assets had
      // been edited, which would have meant shipping nothing for a while.
      final box = _Box();
      expect(portsOf(box).map((p) => p.id), ['X1', 'X2']);
    });

    test('a declaring asset overrides the assumption', () {
      expect(portsOf(_TwoOnTheRight()).map((p) => p.id), ['X1', 'X2']);
      expect(portsOf(_TwoOnTheRight()).map((p) => p.side),
          [PortSide.right, PortSide.right]);
    });
  });

  group('EtherCAT ports', () {
    test('a legacy X2 on an EK1100 is its X2 OUT socket, C', () {
      // B on a coupler is the E-bus into its terminals; X2 OUT is where a
      // branch leaves, and that is C.
      expect(findPort(kEk1100Ports, 'X2')!.id, 'C');
      expect(findPort(kEk1100Ports, 'X1')!.id, 'A');
    });

    test('on a terminal X2 is B', () {
      expect(findPort(kEcTerminalPorts, 'X2')!.id, 'B');
    });

    test('an id is found before an alias, and nothing is not a port', () {
      expect(findPort(kEcSubDevicePorts, 'A')!.id, 'A');
      expect(findPort(kEcSubDevicePorts, 'Q'), isNull);
      expect(findPort(kEcSubDevicePorts, null), isNull);
    });

    test('an EtherCAT device offers its own ports', () {
      final t = AssetRegistry.defaultFactories[BeckhoffEL1008Config]!()
          as BeckhoffEL1008Config;
      expect(portsOf(t).map((p) => p.id), ['A', 'B']);
    });

    test('a cable drawn to X1 before binding stays where it was drawn', () {
      final t = (AssetRegistry.defaultFactories[BeckhoffEL1008Config]!()
          as BeckhoffEL1008Config)
        ..coordinates = Coordinates(x: 0.5, y: 0.5)
        ..size = const RelativeSize(width: 0.1, height: 0.06)
        ..ensureId();
      final anchors = PageLinkAnchors([t], canvas);
      expect(anchors.portPosition(t.id!, 'X1'),
          within(distance: 1e-9, from: const Offset(0.45, 0.5)));
      expect(anchors.portPosition(t.id!, 'X1'),
          anchors.portPosition(t.id!, 'A'));
    });
  });

  group('PageLinkAnchors', () {
    test('resolves a port onto the edge of the asset box', () {
      final box = _Box(x: 0.5, y: 0.5, w: 0.1, h: 0.06)..ensureId();
      final anchors = PageLinkAnchors([box], canvas);

      // Implicit X1 is the left face, X2 the right, both half way down.
      expect(anchors.portPosition(box.id!, 'X1'),
          within(distance: 1e-9, from: const Offset(0.45, 0.5)));
      expect(anchors.portPosition(box.id!, 'X2'),
          within(distance: 1e-9, from: const Offset(0.55, 0.5)));
    });

    test('honours a declared port position along its face', () {
      final t = _TwoOnTheRight(x: 0.5, y: 0.5, w: 0.1, h: 0.2)..ensureId();
      final anchors = PageLinkAnchors([t], canvas);
      expect(anchors.portPosition(t.id!, 'X1'),
          within(distance: 1e-9, from: const Offset(0.55, 0.45)));
      expect(anchors.portPosition(t.id!, 'X2'),
          within(distance: 1e-9, from: const Offset(0.55, 0.55)));
    });

    test('a socket drawn on the face is where the cable ends', () {
      // A 1:4 drawing in a square box: the fraction is a fraction of the
      // *drawing*, which is not the same point as a fraction of the box.
      final d = _SocketOnTheFace(
          x: 0.5, y: 0.5, w: 0.1, h: 0.2, glyph: const Size(100, 400))
        ..ensureId();
      final anchors = PageLinkAnchors([d], canvas);
      // canvas is 1000 x 500, so 0.1 x 0.2 is 100 x 100 px — but the glyph is
      // 1:4, so it is fitted 25 x 100 and centred, and the socket lands a
      // quarter across *that*, not across the box: 37.5 px of letterbox plus
      // 6.25 into the drawing, which is 0.49375 of the page.
      expect(anchors.portPosition(d.id!, 'A'),
          within(distance: 1e-9, from: const Offset(0.49375, 0.56)));
    });

    test('the letterbox is measured in pixels, not in page fractions', () {
      // Page space stretches x and y independently. A glyph fitted in
      // fractions would letterbox by the wrong amount on any canvas that is
      // not square, and the socket would drift off the drawing by that much.
      final square = _SocketOnTheFace(
          x: 0.5, y: 0.5, w: 0.1, h: 0.2, glyph: const Size(100, 100));
      square.ensureId();

      // 0.1 x 0.2 is 100 x 100 px on this canvas: a square box for a square
      // glyph, so nothing is letterboxed at all.
      final fitted = PageLinkAnchors([square], canvas)
          .portPosition(square.id!, 'A')!;
      expect(fitted, within(distance: 1e-9, from: const Offset(0.475, 0.56)));

      // On a square canvas the same box is 100 x 200 px, so the glyph is
      // letterboxed 50 px top and bottom and the socket rides up with it —
      // four fifths down the *drawing* is only 0.65 of the way down the box.
      final tall = PageLinkAnchors([square], const Size(1000, 1000))
          .portPosition(square.id!, 'A')!;
      expect(tall, within(distance: 1e-9, from: const Offset(0.475, 0.53)));
      expect(tall.dy, lessThan(fitted.dy));
    });

    test('a drawing that fills its box needs no fitting', () {
      // No glyph shape declared: the fraction is simply a fraction of the box,
      // which is what an asset drawn edge to edge wants.
      final d = _SocketOnTheFace(x: 0.5, y: 0.5, w: 0.1, h: 0.2)..ensureId();
      expect(PageLinkAnchors([d], canvas).portPosition(d.id!, 'A'),
          within(distance: 1e-9, from: const Offset(0.475, 0.56)));
    });

    test('an unknown asset answers null, so the end falls back', () {
      expect(
          PageLinkAnchors(const [], canvas).portPosition('nope', 'X1'), isNull);
      expect(PageLinkAnchors(const [], canvas).assetAnchor('nope'), isNull);
    });

    test('an unknown port lands on the box centre rather than nowhere', () {
      // A device whose glyph changed under a cable that was already drawn.
      final box = _Box(x: 0.4, y: 0.6)..ensureId();
      final anchors = PageLinkAnchors([box], canvas);
      expect(anchors.portPosition(box.id!, 'X9'),
          within(distance: 1e-9, from: const Offset(0.4, 0.6)));
      expect(anchors.portPosition(box.id!, null),
          within(distance: 1e-9, from: const Offset(0.4, 0.6)));
    });

    test('an asset with no id is not addressable', () {
      // Ids are minted on first reference; an asset nothing points at has
      // none, and must not be silently reachable under some other key.
      final box = _Box();
      expect(box.id, isNull);
      expect(PageLinkAnchors([box], canvas).assetFor('anything'), isNull);
    });

    test('a pinned corner anchors to the box centre', () {
      final box = _Box(x: 0.3, y: 0.7)..ensureId();
      expect(PageLinkAnchors([box], canvas).assetAnchor(box.id!),
          within(distance: 1e-9, from: const Offset(0.3, 0.7)));
    });
  });

  group('rotation', () {
    test('a port turns with its asset', () {
      // Square canvas keeps the arithmetic checkable by hand: a 90-degree turn
      // sends the right face to the bottom.
      const square = Size(600, 600);
      final box = _Box(x: 0.5, y: 0.5, w: 0.2, h: 0.2)..ensureId();
      box.coordinates = Coordinates(x: 0.5, y: 0.5, angle: 90);

      final at = PageLinkAnchors([box], square).portPosition(box.id!, 'X2')!;
      expect(at, within(distance: 1e-9, from: const Offset(0.5, 0.6)));
    });

    test('the turn happens in pixels, so a wide canvas does not shear it', () {
      // Rotating in page space would stretch the offset by the aspect ratio
      // and slide the port off the corner of the glyph it is drawn on. On a
      // 2:1 canvas a 90-degree turn of the right face must still land on the
      // face that is now the bottom: half the box height *in page units*.
      const wide = Size(1000, 500);
      final box = _Box(x: 0.5, y: 0.5, w: 0.2, h: 0.2)..ensureId();
      box.coordinates = Coordinates(x: 0.5, y: 0.5, angle: 90);

      final at = PageLinkAnchors([box], wide).portPosition(box.id!, 'X2')!;
      // Right face is +0.1 page-x = +100px. Turned 90 degrees that is +100px
      // in y, which on a 500px-tall canvas is +0.2 page-y.
      expect(at, within(distance: 1e-9, from: const Offset(0.5, 0.7)));
    });

    test('an unrotated asset is untouched by the rotation path', () {
      final box = _Box(x: 0.5, y: 0.5, w: 0.2, h: 0.2)..ensureId();
      expect(PageLinkAnchors([box], canvas).portPosition(box.id!, 'X2'),
          within(distance: 1e-12, from: const Offset(0.6, 0.5)));
    });
  });

  group('driving a run', () {
    test('a cable plugged into two devices lands on both ports', () {
      final a = _Box(x: 0.2, y: 0.5, w: 0.1, h: 0.05)..ensureId();
      final b = _Box(x: 0.8, y: 0.5, w: 0.1, h: 0.05)..ensureId();
      final anchors = PageLinkAnchors([a, b], canvas);

      final run = LinkRun(
        from: LinkEnd(assetId: a.id, port: 'X2'),
        to: LinkEnd(assetId: b.id, port: 'X1'),
      );
      final pts = run.resolve(canvas, anchors).points;
      expect(pts.first, within(distance: 1e-6, from: const Offset(250, 250)));
      expect(pts.last, within(distance: 1e-6, from: const Offset(750, 250)));
    });

    test('moving a device drags the cable end with it', () {
      final a = _Box(x: 0.2, y: 0.5)..ensureId();
      final b = _Box(x: 0.8, y: 0.5)..ensureId();
      final run = LinkRun(
        from: LinkEnd(assetId: a.id, port: 'X2'),
        to: LinkEnd(assetId: b.id, port: 'X1'),
      );

      final before =
          run.resolve(canvas, PageLinkAnchors([a, b], canvas)).points.first;
      a.coordinates = Coordinates(x: 0.3, y: 0.2);
      final after =
          run.resolve(canvas, PageLinkAnchors([a, b], canvas)).points.first;

      expect(after - before,
          within(distance: 1e-6, from: const Offset(100, -150)));
    });

    test('a deleted device leaves the cable where it was drawn', () {
      final a = _Box(x: 0.2, y: 0.5)..ensureId();
      final b = _Box(x: 0.8, y: 0.5)..ensureId();
      final run = LinkRun(
        from: LinkEnd(assetId: a.id, port: 'X2', x: 0.25, y: 0.5),
        to: LinkEnd(assetId: b.id, port: 'X1'),
      );
      // b is gone from the page; a remains.
      final pts = run.resolve(canvas, PageLinkAnchors([a], canvas)).points;
      expect(pts.last.dx.isNaN, isFalse);
      expect(pts.first, within(distance: 1e-6, from: const Offset(250, 250)));
    });
  });
}

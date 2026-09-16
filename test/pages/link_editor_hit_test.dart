import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/ethercat_link.dart';
import 'package:tfc/page_creator/assets/link_geometry.dart';
import 'package:tfc/pages/page_editor.dart';

class _Block extends BaseAsset {
  _Block({required double x, required double y}) {
    coordinates = Coordinates(x: x, y: y);
    size = const RelativeSize(width: 0.1, height: 0.08);
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
  @override
  Widget configure(BuildContext context) => const SizedBox.shrink();
  @override
  Map<String, dynamic> toJson() => const {};
}

void main() {
  const canvas = Size(1000, 800);

  /// A cable corner to corner, whose rectangle is nearly the whole canvas.
  ({EtherCatLinkConfig cable, List<Asset> page}) diagonalCable() {
    final a = _Block(x: 0.1, y: 0.1)..ensureId();
    final b = _Block(x: 0.9, y: 0.9)..ensureId();
    final cable = EtherCatLinkConfig(
      run: LinkRun(
        from: LinkEnd(assetId: a.id, port: 'X2'),
        to: LinkEnd(assetId: b.id, port: 'X1'),
      ),
    );
    return (cable: cable, page: [a, b, cable]);
  }

  group('editorHitTestAsset', () {
    test('a drag on the cable claims it', () {
      final s = diagonalCable();
      // Roughly the middle of the run.
      expect(
        editorHitTestAsset(
            pointer: const Offset(500, 400),
            asset: s.cable,
            assets: s.page,
            canvas: canvas),
        isTrue,
      );
    });

    test('a drag in the empty part of its rectangle does not', () {
      // This is the regression the shape gate exists for. Without it the
      // cable's box covers most of the canvas and a marquee could not be
      // started anywhere it crosses.
      final s = diagonalCable();
      for (final empty in const [Offset(850, 150), Offset(150, 650)]) {
        expect(
          editorHitTestAsset(
              pointer: empty, asset: s.cable, assets: s.page, canvas: canvas),
          isFalse,
          reason: '$empty is inside the box but nowhere near the cable',
        );
      }
    });

    test('a device under the cable is still reachable', () {
      // The point of the whole thing: a terminal that happens to sit inside
      // the cable's rectangle must still take the drag.
      final s = diagonalCable();
      final under = _Block(x: 0.8, y: 0.2)..ensureId();
      final page = [...s.page, under];

      final at = Offset(0.8 * canvas.width, 0.2 * canvas.height);
      expect(
        editorHitTestAsset(
            pointer: at, asset: s.cable, assets: page, canvas: canvas),
        isFalse,
      );
      expect(
        editorHitTestAsset(
            pointer: at, asset: under, assets: page, canvas: canvas),
        isTrue,
      );
    });

    test('an ordinary asset still answers for its whole box', () {
      // The gate is additive: everything that fills its rectangle keeps the
      // rectangle as its answer.
      final block = _Block(x: 0.5, y: 0.5)..ensureId();
      final page = <Asset>[block];
      // A corner of the box, well off centre.
      final corner = Offset(
        (0.5 + 0.049) * canvas.width,
        (0.5 + 0.039) * canvas.height,
      );
      expect(
        editorHitTestAsset(
            pointer: corner, asset: block, assets: page, canvas: canvas),
        isTrue,
      );
    });

    test('outside the box is a miss regardless of shape', () {
      final s = diagonalCable();
      expect(
        editorHitTestAsset(
            pointer: const Offset(5, 795),
            asset: s.cable,
            assets: s.page,
            canvas: canvas),
        isFalse,
      );
    });

    test('an unplugged cable answers along its line, like a plugged one', () {
      // Its points are its position now, so its box is the run's bounds and a
      // drag lands on the cable, not on a rectangle it used to be drawn in.
      final cable = EtherCatLinkConfig()
        ..coordinates = Coordinates(x: 0.5, y: 0.5);
      final page = <Asset>[cable];
      bool hits(Offset at) => editorHitTestAsset(
          pointer: at, asset: cable, assets: page, canvas: canvas);
      expect(hits(const Offset(500, 404)), isTrue);
      expect(hits(const Offset(440, 398)), isTrue);
      expect(hits(const Offset(500, 430)), isFalse,
          reason: 'inside the old 8% box, nowhere near the cable');
    });

    test('the target is wider than the ink', () {
      // A cable is the thinnest thing on the page; a gloved finger needs more
      // than its stroke to land on.
      final s = diagonalCable();
      final onLine = const Offset(500, 400);
      // ~7px off the centreline of a 6px stroke.
      final justOff = Offset(onLine.dx + 5, onLine.dy - 5);
      expect(
        editorHitTestAsset(
            pointer: justOff, asset: s.cable, assets: s.page, canvas: canvas),
        isTrue,
      );
    });
  });
}

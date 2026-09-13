import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/beckhoff.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/link_anchors.dart';

const _canvas = Size(1000, 500);

BeckhoffEK1100Config _rack(List<Asset> slices) => BeckhoffEK1100Config()
  ..nameOrId = 'ST107.A1.00'
  ..subdevices.addAll(slices)
  ..coordinates = Coordinates(x: 0.5, y: 0.5)
  ..size = const RelativeSize(width: 0.4, height: 0.1);

void main() {
  group('where a slice sits', () {
    test('the row is the head plus the slices, contained and centred', () {
      final a = BeckhoffEL1008Config(nameOrId: 'A1.01');
      final b = BeckhoffEL1008Config(nameOrId: 'A1.02');
      final rack = _rack([a, b]);

      // Head 440 wide, two slices at 1000/6, all at height 1000. The box is
      // 400x50 px, so the height decides the scale: 50/1000.
      const scale = 50 / 1000;
      const rowWidth = 440 + 2 * (1000 / 6);
      const left = 300 + (400 - rowWidth * scale) / 2;

      final boxA = rack.childBox(a, _canvas)!;
      expect(boxA.left * _canvas.width, closeTo(left + 440 * scale, 0.01));
      expect(boxA.width * _canvas.width, closeTo((1000 / 6) * scale, 0.01));
      expect(boxA.height * _canvas.height, closeTo(50, 0.01));

      final boxB = rack.childBox(b, _canvas)!;
      expect(boxB.left * _canvas.width,
          closeTo(boxA.right * _canvas.width, 0.01));
    });

    test('a wider part gets the room it draws at', () {
      final psu = BeckhoffPS2001Config(nameOrId: 'ST101.PSU');
      final term = BeckhoffEL1008Config(nameOrId: 'A1.02');
      final rack = _rack([psu, term]);
      final wide = rack.childBox(psu, _canvas)!;
      final narrow = rack.childBox(term, _canvas)!;
      expect(wide.width / narrow.width,
          closeTo((1000 * 48 / 124) / (1000 / 6), 0.001));
    });

    test('an asset that is not one of the slices has no box here', () {
      final rack = _rack([BeckhoffEL1008Config(nameOrId: 'A1.01')]);
      expect(rack.childBox(BeckhoffEL2008Config(nameOrId: 'x'), _canvas),
          isNull);
    });
  });

  group('anchors', () {
    test('a slice is found by id and placed by its rack', () {
      final slice = BeckhoffEL1008Config(nameOrId: 'A1.01')..ensureId();
      final rack = _rack([slice]);
      final anchors = PageLinkAnchors([rack], _canvas);

      expect(anchors.assetFor(slice.id!), same(slice));
      final port = anchors.portPosition(slice.id!, 'A')!;
      final box = rack.childBox(slice, _canvas)!;
      expect(port.dx, closeTo(box.left, 1e-9));
      expect(port.dy, closeTo(box.center.dy, 1e-9));
    });

    test('turning the rack carries its slices round with it', () {
      final slice = BeckhoffEL1008Config(nameOrId: 'A1.01')..ensureId();
      final rack = _rack([slice])
        ..coordinates = Coordinates(x: 0.5, y: 0.5, angle: 90);
      final anchors = PageLinkAnchors([rack], _canvas);
      final port = anchors.portPosition(slice.id!, 'A')!;

      // A port left of the rack centre is below it once the rack is turned a
      // quarter turn; the pivot is the rack, not the slice.
      expect(port.dx, closeTo(0.5, 1e-6));
      expect(port.dy, greaterThan(0.5));
    });

    test('a top-level asset is unaffected', () {
      final drive = BeckhoffEL1008Config(nameOrId: 'loose')
        ..coordinates = Coordinates(x: 0.25, y: 0.75)
        ..size = const RelativeSize(width: 0.1, height: 0.2)
        ..ensureId();
      final anchors = PageLinkAnchors([drive], _canvas);
      expect(anchors.assetAnchor(drive.id!), const Offset(0.25, 0.75));
      expect(anchors.portPosition(drive.id!, 'B')!.dx, closeTo(0.30, 1e-9));
    });
  });

  test('pasting a rack gives its slices fresh ids', () {
    // Until slices could be referenced this did not matter; now a cable can
    // name one, and two slices sharing an id makes that reference ambiguous.
    final slice = BeckhoffEL1008Config(nameOrId: 'A1.01');
    final rack = _rack([slice]);
    final oldRackId = rack.ensureId();
    final oldSliceId = slice.ensureId();

    reidentifyAssets([rack]);

    expect(rack.id, isNot(oldRackId));
    expect(slice.id, isNot(oldSliceId));
  });
}

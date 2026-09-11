import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/conveyor.dart';
import 'package:tfc/page_creator/assets/registry.dart';
import 'package:tfc/page_creator/assets/sensor.dart' show SensorFbFields;

void main() {
  group('RollerConveyorConfig', () {
    test('round-trips through the registry as its own asset type', () {
      final config = RollerConveyorConfig(key: 'AREA01.CNV01', onRails: true)
        ..coordinates = Coordinates(x: 0.1, y: 0.2)
        ..size = const RelativeSize(width: 0.2, height: 0.05);
      final json = config.toJson();
      expect(json['asset_name'], 'RollerConveyorConfig');

      final parsed = AssetRegistry.parse({'assets': [json]});
      expect(parsed, hasLength(1));
      final restored = parsed.single;
      expect(restored, isA<RollerConveyorConfig>());
      final roller = restored as RollerConveyorConfig;
      expect(roller.key, 'AREA01.CNV01');
      expect(roller.onRails, true);
      expect(roller.style, ConveyorStyle.roller);
    });

    test('shares the conveyor logic but paints as rollers', () {
      final roller = RollerConveyorConfig();
      final box = ConveyorConfig();
      expect(roller.style, ConveyorStyle.roller);
      expect(box.style, ConveyorStyle.box);
      expect(roller.displayName, 'Roller Conveyor');
      // The palette can create one.
      expect(AssetRegistry.createDefaultAssetByName('RollerConveyorConfig'),
          isA<RollerConveyorConfig>());
    });

    test('style stays out of the page JSON — asset_name already decides it',
        () {
      expect(RollerConveyorConfig().toJson().containsKey('style'), isFalse);
      expect(ConveyorConfig().toJson().containsKey('style'), isFalse);
    });
  });

  group('railsActive', () {
    test('follows onRails on a straight belt', () {
      expect(ConveyorConfig(onRails: true).railsActive, isTrue);
      expect(ConveyorConfig().railsActive, isFalse);
      expect(ConveyorConfig(onRails: false).railsActive, isFalse);
    });

    test('stands down for turned belts and the auger renderer', () {
      expect(
          ConveyorConfig(onRails: true, turns: [ConveyorTurnEntry()])
              .railsActive,
          isFalse);
      expect(ConveyorConfig(onRails: true, showAuger: true).railsActive,
          isFalse);
    });
  });

  group('ConveyorPainter with rails (top view)', () {
    const size = Size(240, 100);
    ConveyorPainter wagonAt(double? pos, {double? band}) => ConveyorPainter(
          color: Colors.grey,
          batches: const {},
          angle: 0,
          paintSize: size,
          onRails: true,
          wagonPosition: pos,
          wagonFraction: 0.4,
          straightBeltWidth: band,
        );

    test('a position-driven wagon slides along the rail, 0..1 flush to ends',
        () {
      final atStart = wagonAt(0).hitShape()!.getBounds();
      final atMid = wagonAt(0.5).hitShape()!.getBounds();
      final atEnd = wagonAt(1).hitShape()!.getBounds();
      // The hit shape is the wagon — belt plus chassis bumpers — and at the
      // extremes the bumper, not the belt, sits flush with the box edge.
      expect(atStart.left, closeTo(0, 0.01));
      expect(atMid.center.dx, closeTo(size.width / 2, 0.01));
      expect(atEnd.right, closeTo(size.width, 0.01));
      expect(atStart.width, greaterThan(size.width * 0.4));
      // The empty track beside the wagon does not take the tap.
      expect(wagonAt(0).hitTest(const Offset(200, 50)), isFalse);
      expect(wagonAt(0).hitTest(const Offset(40, 50)), isTrue);
      // The band stays vertically centred — the track runs behind it, not
      // below it.
      expect(atMid.center.dy, closeTo(size.height / 2, 0.01));
    });

    test('a wagon without a position binding parks mid-rail', () {
      final parked = wagonAt(null);
      expect(parked.hasHitShape, isTrue);
      final bounds = parked.hitShape()!.getBounds();
      expect(bounds.center.dx, closeTo(size.width / 2, 0.01));
      expect(parked.hitTest(const Offset(10, 50)), isFalse);
      expect(parked.hitTest(Offset(size.width / 2, 50)), isTrue);
    });

    test('chassis bumpers are wagon but not belt — the motor tap target', () {
      final painter = wagonAt(0.5);
      final belt = painter.beltRect(size);
      final wagon = painter.wagonRect(size);
      expect(wagon.left, lessThan(belt.left));
      expect(wagon.right, greaterThan(belt.right));
      final bumper = Offset((wagon.left + belt.left) / 2, size.height / 2);
      expect(belt.contains(bumper), isFalse);
      expect(wagon.contains(bumper), isTrue);
      expect(painter.hitTest(bumper), isTrue);
    });

    test('the belt stands across the track, full box height', () {
      final railed = wagonAt(0.5);
      final bounds = railed.hitShape()!.getBounds();
      expect(bounds.top, closeTo(0, 0.01));
      expect(bounds.height, closeTo(size.height, 0.01));
    });

    test('an explicit belt width sets the wagon footprint on rails', () {
      final railed = wagonAt(0.5, band: 40);
      final bounds = railed.hitShape()!.getBounds();
      expect(bounds.height, closeTo(size.height, 0.01));
      expect(bounds.center.dx, closeTo(size.width / 2, 0.01));
      // Footprint = belt width + a bumper each side (0.35 of the width).
      expect(bounds.width, closeTo(40 + 2 * 40 * 0.35, 0.01));
    });

    test('wagon keys round-trip through JSON', () {
      final config = ConveyorConfig(
          onRails: true,
          positionKey: 'AREA01.WAG01.position',
          wagonMotorKey: 'AREA01.WAG01.motor',
          beltAlongRails: true,
          safetyLeftKey: 'AREA01.WAG01.edgeL',
          safetyRightKey: 'AREA01.WAG01.edgeR',
          wagonLength: 0.3);
      final restored = ConveyorConfig.fromJson(config.toJson());
      expect(restored.positionKey, 'AREA01.WAG01.position');
      expect(restored.wagonMotorKey, 'AREA01.WAG01.motor');
      expect(restored.beltAlongRails, isTrue);
      expect(restored.safetyLeftKey, 'AREA01.WAG01.edgeL');
      expect(restored.safetyRightKey, 'AREA01.WAG01.edgeR');
      expect(restored.wagonLength, 0.3);
      expect(restored.effectiveWagonLength, 0.3);
      expect(ConveyorConfig().effectiveWagonLength, 0.25);
    });

    test('safety-edge tap zones are the bumper strips, not the belt', () {
      final painter = wagonAt(0.5);
      final leftZone = painter.safetyEdgeRect(size, left: true)!;
      final rightZone = painter.safetyEdgeRect(size, left: false)!;
      final belt = painter.beltRect(size);
      final wagon = painter.wagonRect(size);
      // Each zone sits on its own side of the belt, inside the wagon.
      expect(leftZone.right, lessThanOrEqualTo(belt.left + 0.01));
      expect(rightZone.left, greaterThanOrEqualTo(belt.right - 0.01));
      expect(wagon.contains(leftZone.center), isTrue);
      expect(wagon.contains(rightZone.center), isTrue);
      // Off the rails there is no edge to tap.
      final flat = ConveyorPainter(
          color: Colors.grey, batches: const {}, angle: 0, paintSize: size);
      expect(flat.safetyEdgeRect(size, left: true), isNull);
    });

    test('readSafetyEdge accepts a plain BOOL and an FB_Sensor struct', () {
      DynamicValue edge({required bool output, required bool fault}) =>
          DynamicValue.fromMap(LinkedHashMap<String, dynamic>.from({
            SensorFbFields.output: output,
            SensorFbFields.fault: fault,
          }));
      // FB_Sensor: the debounced output answers.
      expect(readSafetyEdge(edge(output: true, fault: false)), isTrue);
      expect(readSafetyEdge(edge(output: false, fault: false)), isFalse);
      // A faulted sensor fails safe — the edge shows pressed.
      expect(readSafetyEdge(edge(output: false, fault: true)), isTrue);
      // Plain BOOL answers with itself; anything else is not a press.
      expect(readSafetyEdge(DynamicValue(value: true)), isTrue);
      expect(readSafetyEdge(DynamicValue(value: false)), isFalse);
      expect(readSafetyEdge(null), isFalse);
      expect(readSafetyEdge(DynamicValue(value: 3.14)), isFalse);
    });

    test('a belt along the rails is a horizontal band on the chassis', () {
      const size = Size(240, 100);
      final along = ConveyorPainter(
        color: Colors.grey,
        batches: const {},
        angle: 0,
        paintSize: size,
        onRails: true,
        wagonPosition: 0.5,
        wagonFraction: 0.5,
        straightBeltWidth: 40,
        wagonBeltAcross: false,
      );
      final belt = along.beltRect(size);
      // Footprint from the wagon fraction (the explicit width is the band's
      // cross dimension here), band centred vertically.
      expect(belt.width, closeTo(size.width * 0.5, 0.01));
      expect(belt.height, closeTo(40, 0.01));
      expect(belt.center.dy, closeTo(size.height / 2, 0.01));
    });
  });
}

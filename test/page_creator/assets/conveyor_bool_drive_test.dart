// A conveyor should be drivable by a plain boolean, not only by an
// `FB_ATV320` HMI struct.
//
// `_getConveyorColor` read `driveValue['p_stat_RunMode']` unconditionally. On
// a plain BOOL that throws, the outer catch swallows it, and the belt paints
// violet — the "unknown" colour — no matter whether it is running or stopped.
//
// Not every belt on this plant is a VFD with an HMI struct. Several are driven
// over Modbus from the pallet system (`CVS02.CN29_RUN`, `CVS03.CN27_RUN` and
// friends are plain BOOLs), and a PLC-side "is running" bit is the natural
// binding for those.
//
// `SensorConfig` already set the precedent: prefer the struct, accept a plain
// bool, and decide by the shape of what arrives.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:tfc/page_creator/assets/conveyor.dart';

void main() {
  group('readDriveState', () {
    test('nothing bound reads as unknown', () {
      expect(readDriveState(null), DriveState.unknown);
    });

    test('a plain true is running', () {
      expect(readDriveState(DynamicValue(value: true)), DriveState.running);
    });

    test('a plain false is stopped', () {
      expect(readDriveState(DynamicValue(value: false)), DriveState.stopped);
    });

    test('a non-bool scalar is unknown, not silently stopped', () {
      // Guessing "stopped" from a string would paint a belt grey that nobody
      // has any information about.
      expect(readDriveState(DynamicValue(value: 'nonsense')),
          DriveState.unknown);
    });

    test('a numeric drive value is not mistaken for a bool', () {
      // A frequency accidentally bound to the drive key must not read as
      // running just because it is non-zero.
      expect(readDriveState(DynamicValue(value: 42)), DriveState.unknown);
    });
  });

  group('ConveyorConfig.runningKey', () {
    test('is absent unless set, so existing pages are untouched', () {
      expect(ConveyorConfig(key: 'CVS01.CN02.FD01').runningKey, isNull);
    });

    test('round-trips through json', () {
      final c = ConveyorConfig(key: null, runningKey: 'CVS02.CN29.Running');
      final back = ConveyorConfig.fromJson(
          jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>);
      expect(back.runningKey, 'CVS02.CN29.Running');
    });

    test('a page saved before the field existed still loads', () {
      final json = jsonDecode(jsonEncode(
          ConveyorConfig(key: 'CVS01.CN02.FD01').toJson()))
              as Map<String, dynamic>
        ..remove('runningKey');
      expect(ConveyorConfig.fromJson(json).runningKey, isNull);
    });
  });

  group('running is treated like auto', () {
    test('both are the states that mean the belt is moving', () {
      // The colour mapping keys off this: a boolean-driven belt should look
      // the same as a struct-driven one in auto, not get a colour of its own.
      expect(driveStateIsMoving(DriveState.running), isTrue);
      expect(driveStateIsMoving(DriveState.auto), isTrue);
      expect(driveStateIsMoving(DriveState.stopped), isFalse);
      expect(driveStateIsMoving(DriveState.fault), isFalse);
      expect(driveStateIsMoving(DriveState.unknown), isFalse);
    });
  });
}

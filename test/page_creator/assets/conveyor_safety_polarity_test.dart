// A wagon's safety edges are commonly wired **normally closed**: the signal
// is true while the edge is healthy and drops to false when the edge is
// pressed or the cable breaks.
//
// `readSafetyEdge` assumed true = pressed, so on such a wagon both bumpers
// painted fault red from the moment the page opened — which trains an
// operator to ignore the one indicator that must never be ignored.
//
// `ConveyorConfig.invertSafetyPolarity` flips the reading. What it must NOT
// flip is the fault term: `readSafetyEdge` answers `output || fault` so a
// broken sensor reads as pressed rather than quietly disarming, and
// `!(output || fault)` would turn that into "safe" — strictly worse than the
// bug being fixed. Only the output term inverts.
//
// The unit truth table lives in `roller_conveyor_test.dart`; these tests
// prove the flag actually reaches the painter, on both conveyor styles.

import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/conveyor.dart';
import 'package:tfc/page_creator/assets/sensor.dart' show SensorFbFields;
import 'package:tfc/providers/state_man.dart';
import 'package:tfc_dart/core/state_man.dart';

const _driveKey = 'line1.wagon1.drive';
const _leftKey = 'line1.wagon1.edgeLeft';
const _rightKey = 'line1.wagon1.edgeRight';

/// Answers the drive key with a running `FB_ATV320`-shaped value and each
/// edge key with whatever the test handed it.
class _EdgeStateMan extends Fake implements StateMan {
  _EdgeStateMan({required this.left, required this.right});

  final DynamicValue? left;
  final DynamicValue? right;

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async {
    if (key == _driveKey) {
      final drive = DynamicValue();
      drive['p_stat_State'] = 2;
      drive['p_stat_Frequency'] = 50.0;
      return Stream<DynamicValue>.value(drive);
    }
    if (key == _leftKey && left != null) {
      return Stream<DynamicValue>.value(left!);
    }
    if (key == _rightKey && right != null) {
      return Stream<DynamicValue>.value(right!);
    }
    // An optional binding that never emits — the "still connecting" shape.
    return const Stream<DynamicValue>.empty();
  }
}

/// An `FB_Sensor` HMI struct with just the two members the edge decode reads.
DynamicValue _fb({required bool output, required bool fault}) =>
    DynamicValue.fromMap(LinkedHashMap<String, dynamic>.from({
      SensorFbFields.output: output,
      SensorFbFields.fault: fault,
    }));

ConveyorPainter _painterOf(WidgetTester tester) {
  for (final cp in tester.widgetList<CustomPaint>(find.byType(CustomPaint))) {
    final painter = cp.painter;
    if (painter is ConveyorPainter) return painter;
  }
  fail('no ConveyorPainter was rendered');
}

Widget _wrap(ConveyorConfig config, StateMan stateMan) => ProviderScope(
      overrides: [stateManProvider.overrideWith((ref) async => stateMan)],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 120,
              child: Conveyor(config),
            ),
          ),
        ),
      ),
    );

ConveyorConfig _wagon({required bool inverted}) => ConveyorConfig(
      key: _driveKey,
      onRails: true,
      safetyLeftKey: _leftKey,
      safetyRightKey: _rightKey,
      invertSafetyPolarity: inverted,
    )..size = const RelativeSize(width: 1.0, height: 1.0);

void main() {
  Future<({bool left, bool right})> edges(
    WidgetTester tester, {
    required bool inverted,
    DynamicValue? left,
    DynamicValue? right,
  }) async {
    await tester.pumpWidget(_wrap(
      _wagon(inverted: inverted),
      _EdgeStateMan(left: left, right: right),
    ));
    await tester.pumpAndSettle();
    final painter = _painterOf(tester);
    return (left: painter.safetyLeftActive, right: painter.safetyRightActive);
  }

  testWidgets('a healthy normally-closed edge stops painting a false alarm',
      (tester) async {
    final healthy = _fb(output: true, fault: false);
    // Before the flag: a healthy NC edge is a permanent red bumper.
    expect(await edges(tester, inverted: false, left: healthy, right: healthy),
        (left: true, right: true));
    // With it: the same signal reads clear on both sides.
    expect(await edges(tester, inverted: true, left: healthy, right: healthy),
        (left: false, right: false));
  });

  testWidgets('a pressed normally-closed edge lights the bumper',
      (tester) async {
    final pressed = _fb(output: false, fault: false);
    expect(await edges(tester, inverted: true, left: pressed, right: pressed),
        (left: true, right: true));
    expect(await edges(tester, inverted: false, left: pressed, right: pressed),
        (left: false, right: false));
  });

  testWidgets('a faulted sensor still reads as pressed with inversion on',
      (tester) async {
    // The regression that matters: a broken sensor must not read as safe just
    // because the edge is wired the other way round.
    final faulted = _fb(output: false, fault: true);
    expect(await edges(tester, inverted: true, left: faulted, right: faulted),
        (left: true, right: true));
    expect(await edges(tester, inverted: false, left: faulted, right: faulted),
        (left: true, right: true));
  });

  testWidgets('one flag covers both edges, independently of each other',
      (tester) async {
    expect(
      await edges(tester,
          inverted: true,
          left: _fb(output: true, fault: false),
          right: _fb(output: false, fault: false)),
      (left: false, right: true),
    );
  });

  testWidgets('plain BOOL edges invert as well', (tester) async {
    expect(
      await edges(tester,
          inverted: true,
          left: DynamicValue(value: true),
          right: DynamicValue(value: false)),
      (left: false, right: true),
    );
  });

  testWidgets('an edge that has not reported yet is never a press',
      (tester) async {
    // No value at all is not a sensor saying anything, so there is nothing to
    // invert: a connecting wagon must not flash both bumpers red.
    expect(await edges(tester, inverted: true), (left: false, right: false));
    expect(await edges(tester, inverted: false), (left: false, right: false));
  });

  testWidgets('the roller wagon inherits the whole decode', (tester) async {
    // `RollerConveyorConfig` only changes the band renderer; nothing in the
    // roller path reads the edges for itself.
    final config = RollerConveyorConfig(
      key: _driveKey,
      onRails: true,
      safetyLeftKey: _leftKey,
      safetyRightKey: _rightKey,
      invertSafetyPolarity: true,
    )..size = const RelativeSize(width: 1.0, height: 1.0);
    final healthy = _fb(output: true, fault: false);
    await tester.pumpWidget(
        _wrap(config, _EdgeStateMan(left: healthy, right: healthy)));
    await tester.pumpAndSettle();
    final painter = _painterOf(tester);
    expect(painter.style, ConveyorStyle.roller);
    expect(painter.safetyLeftActive, isFalse);
    expect(painter.safetyRightActive, isFalse);
  });
}

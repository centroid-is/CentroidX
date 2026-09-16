// What the polarity flag actually changes on the mimic.
//
// Three wagons, each fed one safety-edge signal, drawn twice: once read as
// normally open (the default, unchanged) and once as normally closed. The
// middle pair is the point of the flag — a healthy edge on a normally-closed
// loop stops painting a permanent false alarm — and the bottom pair is the
// part that must NOT move: a faulted sensor keeps its red bumpers under both
// readings.

import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/conveyor.dart';
import 'package:tfc/page_creator/assets/sensor.dart' show SensorFbFields;
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/theme.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../../helpers/golden_fonts.dart';
import '../../helpers/golden_platform.dart';

const _sceneKey = Key('conveyor_safety_polarity_golden');
const _driveKey = 'line1.wagon.drive';

/// One row of the scene: the signal both readings are given, and what to call
/// it on screen.
typedef PolarityCase = ({String label, String keyStem, DynamicValue value});

DynamicValue _fb({required bool output, required bool fault}) =>
    DynamicValue.fromMap(LinkedHashMap<String, dynamic>.from({
      SensorFbFields.output: output,
      SensorFbFields.fault: fault,
    }));

/// Answers every configured key from a fixed table, so the frame is the same
/// on every run.
class _SceneStateMan extends Fake implements StateMan {
  _SceneStateMan(this.values);

  final Map<String, DynamicValue> values;

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async {
    // A plain BOOL drive: the belt reads as running without needing an
    // `FB_ATV320` enum, and with no frequency there is no animation to wait
    // on, so the captured frame is deterministic.
    if (key == _driveKey) {
      return Stream<DynamicValue>.value(DynamicValue(value: true));
    }
    final value = values[key];
    if (value == null) return const Stream<DynamicValue>.empty();
    return Stream<DynamicValue>.value(value);
  }
}

Widget buildPolarityScene(ThemeData theme, List<PolarityCase> cases) {
  final values = <String, DynamicValue>{
    for (final c in cases) ...{
      '${c.keyStem}.edgeLeft': c.value,
      '${c.keyStem}.edgeRight': c.value,
    }
  };

  Widget wagon(PolarityCase c, {required bool inverted}) => SizedBox(
        width: 230,
        height: 100,
        child: Conveyor(ConveyorConfig(
          key: _driveKey,
          onRails: true,
          safetyLeftKey: '${c.keyStem}.edgeLeft',
          safetyRightKey: '${c.keyStem}.edgeRight',
          invertSafetyPolarity: inverted,
        )..size = const RelativeSize(width: 1.0, height: 1.0)),
      );

  return ProviderScope(
    overrides: [
      stateManProvider.overrideWith((ref) async => _SceneStateMan(values)),
    ],
    child: MaterialApp(
      theme: theme,
      home: Scaffold(
        body: Center(
          child: RepaintBoundary(
            key: _sceneKey,
            child: Container(
              color: theme.colorScheme.surface,
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const SizedBox(width: 150),
                      SizedBox(
                          width: 230,
                          child: Text('read normally open',
                              style: theme.textTheme.bodySmall)),
                      const SizedBox(width: 16),
                      SizedBox(
                          width: 230,
                          child: Text('read normally closed',
                              style: theme.textTheme.bodySmall)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  for (final c in cases) ...[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        SizedBox(
                            width: 150,
                            child: Text(c.label,
                                style: theme.textTheme.bodySmall)),
                        wagon(c, inverted: false),
                        const SizedBox(width: 16),
                        wagon(c, inverted: true),
                      ],
                    ),
                    const SizedBox(height: 8),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('safety-edge polarity golden', skip: goldenSkip, () {
    setUpAll(loadGoldenFonts);

    final cases = <PolarityCase>[
      (
        label: 'signal true',
        keyStem: 'line1.wagonA',
        value: _fb(output: true, fault: false)
      ),
      (
        label: 'signal false',
        keyStem: 'line1.wagonB',
        value: _fb(output: false, fault: false)
      ),
      (
        label: 'sensor faulted',
        keyStem: 'line1.wagonC',
        value: _fb(output: false, fault: true)
      ),
    ];

    testWidgets('one signal, both readings, fault red either way',
        (tester) async {
      tester.view.physicalSize = const Size(900, 460);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(buildPolarityScene(solarized().$1, cases));
      await tester.pumpAndSettle();
      await expectLater(
        find.byKey(_sceneKey),
        matchesGoldenFile('goldens/conveyor_safety_polarity.png'),
      );
    });
  });
}

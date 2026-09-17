/// Sensors riding a wagon, as the operator sees them.
///
/// The names and keys are invented: a golden is a published image.
@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/conveyor.dart';
import 'package:tfc/page_creator/assets/sensor.dart';
import 'package:tfc/providers/collector.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/theme.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../../helpers/golden_fonts.dart';
import '../../helpers/golden_platform.dart';

const _frameKey = Key('wagon_sensors_golden');
const _activeKey = 'line1.wagon1.eyeFront';
const _clearKey = 'line1.wagon1.eyeBack';
const _positionKey = 'line1.wagon1.position';

class _SensorStateMan extends Fake implements StateMan {
  @override
  Future<Stream<DynamicValue>> subscribe(String key) async =>
      Stream<DynamicValue>.value(key == _positionKey
          ? DynamicValue(value: 55.0)
          : DynamicValue(value: key == _activeKey));

  @override
  String resolveKey(String key) => key;

  @override
  KeyMappings get keyMappings => KeyMappings(nodes: {});
}

// No `showTag`: the label is painted by `AssetStack` around the asset, and
// this frame is the conveyor alone.
SensorConfig _sensor(String key, String tag) =>
    SensorConfig(detectionKey: key, tag: tag);

ConveyorConfig _wagon({
  required List<WagonSensorEntry> sensors,
  bool across = true,
  bool reverse = false,
}) =>
    ConveyorConfig(
      key: 'line1.wagon1.belt',
      onRails: true,
      beltAlongRails: !across,
      reverseDirection: reverse,
      positionKey: _positionKey,
      wagonLength: 0.22,
      wagonSensors: sensors,
    )..size = const RelativeSize(width: 1.0, height: 1.0);

Widget _frame(ThemeData theme, List<(String, ConveyorConfig)> rows) =>
    MaterialApp(
      theme: theme,
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: RepaintBoundary(
            key: _frameKey,
            child: Container(
              color: theme.colorScheme.surface,
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final row in rows) ...[
                    Text(row.$1, style: theme.textTheme.bodySmall),
                    const SizedBox(height: 4),
                    SizedBox(
                        width: 700, height: 150, child: Conveyor(row.$2)),
                    const SizedBox(height: 12),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  group('wagon sensors golden', skip: goldenSkip, () {
    setUpAll(loadGoldenFonts);

    testWidgets('one at each end, two at one end, and along the rails',
        (tester) async {
      tester.view.physicalSize = const Size(780, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(ProviderScope(
        overrides: [
          collectorProvider.overrideWith((ref) async => null),
          stateManProvider.overrideWith((ref) async => _SensorStateMan()),
        ],
        child: _frame(solarized().$1, [
          (
            'one at each end: the front eye sees a pallet, the back one is clear',
            _wagon(sensors: [
              WagonSensorEntry(
                  end: WagonSensorEnd.front,
                  sensor: _sensor(_activeKey, 'Front')),
              WagonSensorEntry(
                  end: WagonSensorEnd.back, sensor: _sensor(_clearKey, 'Back')),
            ]),
          ),
          (
            'both at the front: side by side across the belt',
            _wagon(sensors: [
              WagonSensorEntry(
                  end: WagonSensorEnd.front,
                  sensor: _sensor(_activeKey, 'Left')),
              WagonSensorEntry(
                  end: WagonSensorEnd.front,
                  sensor: _sensor(_clearKey, 'Right')),
            ]),
          ),
          (
            'belt along the rails: the ends are left and right',
            _wagon(across: false, sensors: [
              WagonSensorEntry(
                  end: WagonSensorEnd.front,
                  sensor: _sensor(_activeKey, 'Front')),
              WagonSensorEntry(
                  end: WagonSensorEnd.back, sensor: _sensor(_clearKey, 'Back')),
            ]),
          ),
        ]),
      ));
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }

      await expectLater(find.byKey(_frameKey),
          matchesGoldenFile('goldens/conveyor_wagon_sensors.png'));
    });
  });
}

/// Sensors bolted along a belt, as the operator sees them: beside the band,
/// turned to look across it, the way the gates hang off the same edge.
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
import 'package:tfc/page_creator/assets/conveyor_gate.dart' show GateSide;
import 'package:tfc/page_creator/assets/sensor.dart';
import 'package:tfc/providers/collector.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/theme.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../../helpers/golden_fonts.dart';
import '../../helpers/golden_platform.dart';

const _frameKey = Key('child_sensors_golden');
const _activeKey = 'line1.conv1.eyeIn';
const _clearKey = 'line1.conv1.eyeOut';
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
// these frames are the conveyor alone.
ChildSensorEntry _eye(String key,
        {required double position,
        GateSide side = GateSide.left,
        SensorKind kind = SensorKind.redLight}) =>
    ChildSensorEntry(
      position: position,
      side: side,
      sensor: SensorConfig(detectionKey: key, kind: kind),
    );

ConveyorConfig _belt({
  required List<ChildSensorEntry> sensors,
  double? bandWidth,
  List<ConveyorTurnEntry>? turns,
}) =>
    ConveyorConfig(
      key: 'line1.conv1.belt',
      sensors: sensors,
      turns: turns,
    )
      ..beltWidthRelative = bandWidth
      ..size = const RelativeSize(width: 1.0, height: 1.0);

ConveyorConfig _wagon({required List<ChildSensorEntry> sensors}) =>
    ConveyorConfig(
      key: 'line1.wagon1.belt',
      onRails: true,
      positionKey: _positionKey,
      wagonLength: 0.22,
      sensors: sensors,
    )..size = const RelativeSize(width: 1.0, height: 1.0);

Widget _frame(
        ThemeData theme, List<(String, double, ConveyorConfig)> rows) =>
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
                        width: 700, height: row.$2, child: Conveyor(row.$3)),
                    const SizedBox(height: 14),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  group('child sensors golden', skip: goldenSkip, () {
    setUpAll(loadGoldenFonts);

    testWidgets('beside the band, on either edge, on a wagon and on a bend',
        (tester) async {
      tester.view.physicalSize = const Size(780, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(ProviderScope(
        overrides: [
          collectorProvider.overrideWith((ref) async => null),
          stateManProvider.overrideWith((ref) async => _SensorStateMan()),
        ],
        child: _frame(solarized().$1, [
          (
            'through-beam pairs: each spans the band, sending from one edge',
            110.0,
            _belt(bandWidth: 0.4, sensors: [
              _eye(_activeKey, position: 0.25),
              _eye(_clearKey, position: 0.7, side: GateSide.right),
            ]),
          ),
          (
            'a belt that fills its box: the beam still spans the belt',
            56.0,
            _belt(sensors: [_eye(_activeKey, position: 0.35)]),
          ),
          (
            'a transfer wagon: the eyes ride it, one near each end of its belt',
            150.0,
            _wagon(sensors: [
              _eye(_activeKey, position: 0.85),
              _eye(_clearKey, position: 0.15),
            ]),
          ),
          (
            'a bend: a single housing stands beside the band, looking across',
            170.0,
            _belt(
              bandWidth: 0.2,
              turns: [ConveyorTurnEntry(position: 0.55, angle: 60)],
              sensors: [
                _eye(_clearKey,
                    position: 0.3,
                    side: GateSide.right,
                    kind: SensorKind.opticField),
              ],
            ),
          ),
        ]),
      ));
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }

      await expectLater(find.byKey(_frameKey),
          matchesGoldenFile('goldens/conveyor_child_sensors.png'));
    });
  });
}

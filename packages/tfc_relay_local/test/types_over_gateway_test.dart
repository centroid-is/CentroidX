/// Enum NAMES cross a `buildGateway` gateway: PLC -> gateway -> socket -> panel.
///
/// `bench_smoke_test.dart`'s struct arm proves the MEMBER names cross, and says
/// in its own words that this is less than it once claimed: member names ride
/// on the struct value itself, and the enum vocabulary rides in the type
/// dictionary (`types` on the subscribe result, `typesLearned` after it),
/// which the server carries only when its source implements
/// `TypeDescriptions`. Until this file went red, `LocalStateMan` implemented
/// nothing, so every gateway composed by `buildGateway` served no dictionary
/// and `RemoteStateMan.typeOf` was null at the panel — the panel coloured
/// equipment from a bare integer, and every conveyor drew violet. That is the
/// 2026-09-17 plant defect `type_descriptor.dart` describes, and the shape the
/// plant simulator's `DriveStatus`/`RunMode` was built to reproduce; neither
/// e2e lane could pin it because both stand their gateway up this way.
///
/// **The late-learning path is exercised by construction.** The bench dials
/// its panels after the gateway starts, so the panel's own subscribe is what
/// makes the link establish the key, and the descriptor is learned from the
/// decode probe that follows — a moment after the subscribe snapshot went
/// out. The names therefore reach the panel through `typesLearned`, the push
/// `typesVersion` exists for, not through the snapshot. A source that never
/// bumped the counter would pass every other assertion here and fail this
/// file.
@TestOn('!windows')
@Tags(['opcua', 'e2e'])
library;

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'support/plant_bench.dart';

/// The default plant plus a scalar enum — `PKG01.state` in the demo fixture's
/// shape — so the enum-inside-a-struct and the bare enum are pinned by one
/// stand-up rather than two.
const String _spec = '''
types:
  - name: RunMode
    kind: enum
    values: {0: fault, 1: stopped, 2: auto, 3: manual, 4: clean}
  - name: DriveStatus
    kind: struct
    members:
      - {name: run_mode, type: RunMode, value: 2}
      - {name: speed_hz, type: double, value: 50}
      - {name: fault_code, type: int, value: 0}
servers:
  - alias: HALL1
    nodes:
      - {id: CN01.speed_hz, type: double, motion: ramp, min: 0, max: 50, period: 100ms}
      - {id: CN01.drive, type: DriveStatus, motion: cycle, period: 300ms}
      - {id: CN01.setpoint_kg, type: double, value: 12.5, motion: once, records: true}
      - {id: PKG01.state, type: RunMode, value: 1, motion: cycle, period: 300ms}
''';

void main() {
  test('the enum names inside a struct reach the panel, and 2 reads as auto',
      () async {
    final bench = await standUpPlant(spec: _spec);
    final drive = plantKey('HALL1', 'CN01.drive');

    await until(() => bench.panel.typeOf(drive) != null,
        describe: 'the drive struct\'s type to be described at the panel');
    final type = bench.panel.typeOf(drive)!;
    final runMode = type.members['run_mode'];
    expect(runMode, isNotNull,
        reason: 'the struct descriptor names its enum member');
    final table = runMode!.enumFields;
    expect(table, isNotNull,
        reason: 'the member carries the enum TABLE, not just a type id');
    // The name `readDriveState` switches on. The integer was always crossing;
    // this is the half that was not.
    expect(table![2]!.name, 'auto');
    expect(table[0]!.name, 'fault');
    expect(table.keys, unorderedEquals(<int>[0, 1, 2, 3, 4]));

    // And it describes what the panel is actually holding: the value's
    // `run_mode` is an integer the table can name.
    await until(() => bench.panel.read(drive)?.value != null,
        describe: 'the drive struct to reach the panel');
    final value = bench.panel.read(drive)!.value as Map;
    final mode = value['run_mode'];
    expect(mode, isA<DynamicValue>());
    expect(table[(mode as DynamicValue).value as int], isNotNull,
        reason: 'the mode the plant is in has a name in the table');
  });

  test('a bare enum is described too, under a type of its own', () async {
    final bench = await standUpPlant(spec: _spec);
    final state = plantKey('HALL1', 'PKG01.state');

    await until(() => bench.panel.typeOf(state) != null,
        describe: 'the scalar enum\'s type to be described at the panel');
    final type = bench.panel.typeOf(state)!;
    expect(type.enumFields, isNotNull,
        reason: 'a scalar enum carries its table at the top level');
    expect(type.enumFields![1]!.name, 'stopped');
    expect(type.members, isEmpty);
  });

  test('a plain scalar and a gateway-owned key answer no type at all',
      () async {
    final bench = await standUpPlant(spec: _spec);
    final drive = plantKey('HALL1', 'CN01.drive');
    final speed = plantKey('HALL1', 'CN01.speed_hz');

    // Wait for the dictionary to have been learned at all, so a null below is
    // a verdict and not a race.
    await until(() => bench.panel.typeOf(drive) != null,
        describe: 'the dictionary to have crossed');
    expect(bench.panel.typeOf(speed), isNull,
        reason: 'a double has nothing a panel cannot read off the value; '
            'describing it would be a made-up descriptor');
    expect(bench.panel.typeOf(PipeKeys.connected), isNull,
        reason: 'the gateway\'s own keys have no plant type');
    expect(bench.gateway.plant.typeIdOf(speed), isNull);
    expect(bench.gateway.plant.typeIdOf(PipeKeys.connected), isNull);
  });
}

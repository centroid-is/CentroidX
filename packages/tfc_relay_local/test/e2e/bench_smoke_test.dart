/// The bench itself: does the chain stand up, and is the instrument wired.
///
/// Before any case can mean "the transmission broke", this file has to mean
/// "the transmission worked". Everything in the attack suite is a difference
/// from what is asserted here.
@TestOn('!windows')
@Tags(['opcua', 'e2e'])
library;

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import '../support/plant_bench.dart';

void main() {
  test('a plant value crosses PLC -> gateway -> socket -> panel', () async {
    final bench = await standUpPlant();
    final speed = plantKey('HALL1', 'CN01.speed_hz');

    await until(() => bench.panel.read(speed)?.value != null,
        describe: 'a ramping speed to reach the panel');
    final value = bench.panel.read(speed)!;
    expect(value.quality, Quality.good,
        reason: 'a value the PLC is publishing is a good value');
    expect(value.value, isA<num>());
  });

  test('the panel sees the plant move', () async {
    final bench = await standUpPlant();
    final speed = plantKey('HALL1', 'CN01.speed_hz');

    final first = bench.panel.read(speed)!.value;
    await until(() => bench.panel.read(speed)!.value != first,
        describe: 'the ramp to move under the panel');
  });

  test('a panel write actuates the plant exactly once', () async {
    final bench = await standUpPlant();
    final setpoint = plantKey('HALL1', 'CN01.setpoint_kg');

    final outcome = await bench.panel.write(setpoint, 19.5);
    expect(outcome, isA<WriteApplied>(),
        reason: 'an ordinary write to a reachable node applies');

    await until(() => bench.actuations('CN01.setpoint_kg') == 1,
        describe: 'the write to be counted at the node');
    expect(bench.actuations('CN01.setpoint_kg'), 1,
        reason: 'one command, one movement of the machine');
    expect(bench.server().actuationsOf('CN01.setpoint_kg').single.value.asDouble,
        19.5);
  });

  test('a struct crosses the whole chain with its member names intact',
      () async {
    final bench = await standUpPlant();
    final drive = plantKey('HALL1', 'CN01.drive');

    await until(() => bench.panel.read(drive)?.value != null,
        describe: 'the drive struct to reach the panel');
    final value = bench.panel.read(drive)!;

    // **What this proves, and what it does NOT.** It proves the struct
    // crosses with its MEMBER names intact — `run_mode` arrives as a named
    // member rather than an index — which is a property of the struct value
    // itself and travels on every sample.
    //
    // It does **not** prove the enum NAMES cross, and an earlier version of
    // this comment claimed it did. Enum names ride in the type dictionary
    // (`types` on the subscribe result), which the server carries only when
    // its source implements `TypeDescriptions`. `LocalStateMan` implements
    // none, so a gateway composed by `buildGateway` serves no dictionary at
    // all and `RemoteStateMan.typeOf` is null here. The panel colours
    // equipment from enum names, so on this gateway every conveyor would
    // still draw violet.
    //
    // That gap is exactly why the member-name assertion read as sufficient
    // for so long: the half that was crossing is the half that is easy to
    // see. `test/e2e_assets/` carries the case that pins the enum names and
    // is parked on this gap; when it closes, strengthen this arm to match.
    expect(value.value, isNotNull,
        reason: 'the struct crossed at all');
    expect(value.toString(), contains('run_mode'),
        reason: 'the member names survived the type dictionary, the pipe and '
            'the wire');
  });
}

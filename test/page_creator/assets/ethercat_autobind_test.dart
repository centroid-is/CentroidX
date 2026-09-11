import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/beckhoff.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/ethercat_autobind.dart';
import 'package:tfc/page_creator/assets/ethercat_subdevice.dart';
import 'package:tfc/page_creator/assets/registry.dart';
import 'package:tfc/page_creator/assets/schneider.dart';

import '../../helpers/ethercat_fixtures.dart';

T make<T extends Asset>() => AssetRegistry.defaultFactories[T]!() as T;

String two(int i) => i.toString().padLeft(2, '0');

/// Device 1 as ST101 exports it: the CX's block, the PSU, the drives.
EcBus device1() => EcBus.fromValues('Device 1',
    info: array([
      for (var i = 1; i <= 15; i++)
        info('ST101.A1.${two(i)} (EL1008)', addr: 1000 + i),
      info('ST101.PSU (PS2001-2410)', addr: 1016),
      info('CVS01.CN01.FD01 (ATV320 EtherCAT)', addr: 1017),
      info('CVS01.CN02.FD01 (ATV320 EtherCAT)', addr: 1018),
    ]));

/// Device 2, whose ST107 block also has an A1.00 to A1.03.
EcBus device2() => EcBus.fromValues('Device 2',
    info: array([
      info('Box 84 (CU2508)', addr: 1001),
      for (var i = 0; i <= 3; i++) info('ST107.A1.0$i (EK1100)', addr: 1002 + i),
    ]));

void main() {
  final d1 = EcBusConfig(label: 'Device 1', diagKey: 'd1', infoKey: 'i1');
  final d2 = EcBusConfig(label: 'Device 2', diagKey: 'd2', infoKey: 'i2');
  late Map<EcBusConfig, EcBus> buses;
  setUp(() => buses = {d1: device1(), d2: device2()});

  /// `/+ST101` as the plant draws it: a CX5340 with its slices labelled by
  /// cabinet position only, the PSU, and drives labelled over two lines.
  List<Asset> page() => [
        make<BeckhoffCX5340Config>()
          ..nameOrId = 'A1.00'
          ..subdevices = [
            for (var i = 1; i <= 15; i++)
              make<BeckhoffEL1008Config>()..nameOrId = 'A1.${two(i)}',
          ],
        make<BeckhoffPS2001Config>()..nameOrId = 'ST101.PSU',
        SchneiderATV320Config(label: 'CVS01.\nCN01.FD01'),
        SchneiderATV320Config(label: 'CVS01.\nCN02.FD01'),
      ];

  test('binds the whole page, slices inside the rack included', () {
    final plan = planEcAutoBind(page(), buses);
    expect(plan.unmatched, isEmpty);
    expect(plan.ambiguous, isEmpty);
    expect(plan.matched, hasLength(18));
    expect({for (final m in plan.matched) m.bus}, {d1});
  });

  test('a drive label with a line break in it matches exactly', () {
    final m = planEcAutoBind(page(), buses)
        .matched
        .firstWhere((m) => m.asset is SchneiderATV320Config);
    expect(m.subdevice.position, 17);
    expect(m.binding.name, 'CVS01.CN01.FD01');
    expect(m.binding.diagKey, 'd1');
    expect(m.binding.infoKey, 'i1');
    expect(m.viaPageMaster, isFalse);
  });

  test('A1.01 is on two masters; the page\'s other matches decide it', () {
    final plan = planEcAutoBind(page(), buses);
    EcAutoBindMatch slice(String name) => plan.matched.firstWhere(
        (m) => m.asset is BeckhoffEL1008Config &&
            (m.asset as BeckhoffEL1008Config).nameOrId == name);
    expect(slice('A1.01').subdevice.position, 1);
    expect(slice('A1.01').viaPageMaster, isTrue);
    // ST107 stops at A1.03, so A1.05 was never in doubt.
    expect(slice('A1.05').viaPageMaster, isFalse);
  });

  test('with nothing on the page to decide it, a shared name is reported',
      () {
    final lone = make<BeckhoffEL1008Config>()..nameOrId = 'A1.01';
    final plan = planEcAutoBind([lone], buses);
    expect(plan.matched, isEmpty);
    expect(plan.ambiguous.single.candidates, hasLength(2));
  });

  test('no subdevice by the name, or no name at all, is unmatched', () {
    final plan = planEcAutoBind([
      make<BeckhoffEL1008Config>()..nameOrId = 'X9.99',
      make<BeckhoffEL1008Config>()..nameOrId = '',
    ], buses);
    expect(plan.unmatched, hasLength(2));
  });

  test('a suffix only counts at a dot', () {
    // `1.01` is the tail of ST101.A1.01 but not a name anything has.
    final plan =
        planEcAutoBind([make<BeckhoffEL1008Config>()..nameOrId = '1.01'], buses);
    expect(plan.unmatched, hasLength(1));
  });

  test('bound devices are left alone unless asked', () {
    final assets = page();
    final drive = assets[2] as SchneiderATV320Config
      ..ecSubDevice = EcSubDeviceBinding(diagKey: 'mine', position: 3);
    final plan = planEcAutoBind(assets, buses);
    expect(plan.skipped, [drive]);
    expect(plan.matched.any((m) => identical(m.asset, drive)), isFalse);
    expect(
        planEcAutoBind(assets, buses, overwrite: true)
            .matched
            .any((m) => identical(m.asset, drive)),
        isTrue);
  });

  test('apply writes the bindings, and a second pass has nothing to do', () {
    final assets = page();
    applyEcAutoBind(planEcAutoBind(assets, buses));
    final psu = assets[1] as BeckhoffPS2001Config;
    expect(psu.ecSubDevice!.position, 16);
    expect(psu.isEcBound, isTrue);
    final again = planEcAutoBind(assets, buses);
    expect(again.matched, isEmpty);
    expect(again.skipped, hasLength(18));
  });
}

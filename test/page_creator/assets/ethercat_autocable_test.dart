import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/beckhoff.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/ep_box.dart' show EPBoxVariant;
import 'package:tfc/page_creator/assets/ethercat_autocable.dart';
import 'package:tfc/page_creator/assets/ethercat_link.dart';
import 'package:tfc/page_creator/assets/ethercat_subdevice.dart';
import 'package:tfc/page_creator/assets/link_geometry.dart';
import 'package:tfc/page_creator/assets/schneider.dart';

import '../../helpers/ethercat_fixtures.dart';

/// The shape of `/+ST101`: a coupler, a terminal on its E-bus, a drop off its
/// branch port, and two drives in a chain.
EcBus _st101() => EcBus.fromValues(
      'Device 1',
      info: array([
        info('ST101.A1.00 (EK1100)', model: 'EK1100', addr: 1001),
        info('ST101.A1.01 (EL1008)',
            model: 'EL1008', addr: 1002, prev: 1001, prevPort: 'B'),
        info('ST101.EM02 (EP2338-0002)',
            model: 'EP2338-0002', addr: 1003, prev: 1001, prevPort: 'C'),
        info('CVS01.CN01.FD01 (ATV320 EtherCAT)',
            model: 'ATV320 EtherCAT', addr: 1004, prev: 1002, prevPort: 'B'),
        info('CVS01.CN02.FD01 (ATV320 EtherCAT)',
            model: 'ATV320 EtherCAT', addr: 1005, prev: 1004, prevPort: 'B'),
      ]),
      diag: array([diag(), diag(), diag(), diag(), diag()]),
    );

final _bus = EcBusConfig(label: 'Device 1', diagKey: 'd1', infoKey: 'i1');

EcSubDeviceBinding _at(int position) =>
    EcSubDeviceBinding(diagKey: 'd1', infoKey: 'i1', position: position);

SchneiderATV320Config _drive(String label, int position) =>
    SchneiderATV320Config(label: label)
      ..coordinates = Coordinates(x: 0.5, y: 0.5)
      ..ecSubDevice = _at(position);

void main() {
  Map<EcBusConfig, EcBus> buses() => {_bus: _st101()};

  test('draws the chain the export describes', () {
    final coupler = BeckhoffEK1100Config()
      ..nameOrId = 'ST101.A1.00'
      ..ecSubDevice = _at(1);
    final terminal = BeckhoffEL1008Config(nameOrId: 'ST101.A1.01')
      ..ecSubDevice = _at(2);
    final box = BeckhoffEPBoxConfig(
      variantModel: EPBoxVariant.ep2338,
      nameOrId: 'ST101.EM02',
    )..ecSubDevice = _at(3);
    final d1 = _drive('CVS01.CN01.FD01', 4);
    final d2 = _drive('CVS01.CN02.FD01', 5);
    final page = <Asset>[coupler, terminal, box, d1, d2];

    final plan = planEcAutoCables(page, buses());
    final labels = [for (final c in plan.cables) c.label];

    expect(labels, contains('ST101.A1.00 · B → ST101.A1.01 · A'));
    expect(labels, contains('ST101.A1.00 · C → ST101.EM02 · A'));
    expect(labels, contains('ST101.A1.01 · B → CVS01.CN01.FD01 · A'));
    expect(labels, contains('CVS01.CN01.FD01 · B → CVS01.CN02.FD01 · A'));
    expect(plan.cables, hasLength(4));
  });

  test('a cable the page already has is left alone', () {
    final terminal = BeckhoffEL1008Config(nameOrId: 'ST101.A1.01')
      ..ecSubDevice = _at(2);
    final drive = _drive('CVS01.CN01.FD01', 4);
    final drawn = EtherCatLinkConfig(
      run: LinkRun(
        from: LinkEnd(assetId: terminal.ensureId(), port: 'B'),
        to: LinkEnd(assetId: drive.ensureId(), port: 'A'),
      ),
    );
    final plan = planEcAutoCables(<Asset>[terminal, drive, drawn], buses());
    expect(plan.cables, isEmpty);
    expect(plan.notes.join(' '), contains('already drawn'));
  });

  test('a legacy X2 end counts as the cable it is', () {
    // Drawn before the device was bound, so the end says X2 — which on a
    // drive is port B. Proposing another cable there would double it.
    final d1 = _drive('CVS01.CN01.FD01', 4);
    final d2 = _drive('CVS01.CN02.FD01', 5);
    final drawn = EtherCatLinkConfig(
      run: LinkRun(
        from: LinkEnd(assetId: d1.ensureId(), port: 'X2'),
        to: LinkEnd(assetId: d2.ensureId(), port: 'X1'),
      ),
    );
    expect(planEcAutoCables(<Asset>[d1, d2, drawn], buses()).cables, isEmpty);
  });

  test('a neighbour nobody drew is reported, not invented', () {
    final terminal = BeckhoffEL1008Config(nameOrId: 'ST101.A1.01')
      ..ecSubDevice = _at(2);
    final plan = planEcAutoCables(<Asset>[terminal], buses());
    expect(plan.cables, isEmpty);
    expect(plan.notes.join(' '), contains('not on this page'));
  });

  test('unbound devices are not wired', () {
    final page = <Asset>[
      BeckhoffEL1008Config(nameOrId: 'ST101.A1.01'),
      _drive('CVS01.CN01.FD01', 4),
    ];
    expect(planEcAutoCables(page, buses()).cables, isEmpty);
  });

  test('applying adds the cables to the page, ends plugged in', () {
    final terminal = BeckhoffEL1008Config(nameOrId: 'ST101.A1.01')
      ..ecSubDevice = _at(2);
    final drive = _drive('CVS01.CN01.FD01', 4);
    final page = <Asset>[terminal, drive];
    final made = applyEcAutoCables(page, planEcAutoCables(page, buses()));

    expect(made, hasLength(1));
    expect(page.last, same(made.single));
    expect(made.single.run.from.assetId, terminal.id);
    expect(made.single.run.from.port, 'B');
    expect(made.single.run.to.assetId, drive.id);
    expect(made.single.run.to.port, 'A');
    expect(made.single.key, isEmpty);
  });
}

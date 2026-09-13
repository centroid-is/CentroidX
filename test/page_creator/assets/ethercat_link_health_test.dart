import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/beckhoff.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/ethercat_link.dart';
import 'package:tfc/page_creator/assets/ethercat_link_painter.dart';
import 'package:tfc/page_creator/assets/ethercat_subdevice.dart';
import 'package:tfc/page_creator/assets/link_anchors.dart';
import 'package:tfc/page_creator/assets/link_geometry.dart';
import 'package:tfc/page_creator/assets/schneider.dart';

import '../../helpers/ethercat_fixtures.dart';

const _canvas = Size(1000, 500);

/// A drive bound to [position] on `d1`.
/// Ids are minted before the anchors are built, the way the editor does it:
/// `PageLinkAnchors` indexes what already has an id and does not mint one, so
/// a lookup cannot quietly change the page.
SchneiderATV320Config _drive(String label, int position) =>
    SchneiderATV320Config(label: label)
      ..coordinates = Coordinates(x: 0.5, y: 0.5)
      ..ecSubDevice = EcSubDeviceBinding(diagKey: 'd1', position: position)
      ..ensureId();

/// Two drives in a chain: 1 → 2 on port B.
EcBus _bus({
  int deviceState2 = 8,
  int linkState1 = 0,
  List<int> crc1 = const [0, 0, 0, 0],
}) =>
    EcBus.fromValues(
      '',
      info: array([
        info('CVS01.CN01.FD01 (ATV320 EtherCAT)',
            model: 'ATV320 EtherCAT', addr: 1001),
        info('CVS01.CN02.FD01 (ATV320 EtherCAT)',
            model: 'ATV320 EtherCAT', addr: 1002, prev: 1001, prevPort: 'B'),
      ]),
      diag: array([
        diag(linkState: linkState1, crcPort: crc1, crcStable: 30),
        diag(deviceState: deviceState2),
      ]),
    );

void main() {
  group('resolving an end', () {
    test('a bound device and a letter port', () {
      final drive = _drive('CVS01.CN01.FD01', 1);
      final anchors = PageLinkAnchors([drive], _canvas);
      final end = resolveEcLinkEnd(
          LinkEnd(assetId: drive.ensureId(), port: 'B'), anchors)!;
      expect(end.port, EcPort.b);
      expect(end.binding.position, 1);
      expect(end.label, 'CVS01.CN01.FD01');
    });

    test('a cable drawn before binding keeps the socket it was drawn to', () {
      // X2 is the out socket. On a drive that is B; on an EK1100 it is the
      // RJ45 branch, which is C.
      final drive = _drive('CVS01.CN01.FD01', 1);
      final coupler = BeckhoffEK1100Config()
        ..nameOrId = 'ST107.A1.00'
        ..ecSubDevice = EcSubDeviceBinding(diagKey: 'd1', position: 1)
        ..ensureId();
      final anchors = PageLinkAnchors([drive, coupler], _canvas);
      expect(
        resolveEcLinkEnd(
                LinkEnd(assetId: drive.ensureId(), port: 'X2'), anchors)!
            .port,
        EcPort.b,
      );
      expect(
        resolveEcLinkEnd(
                LinkEnd(assetId: coupler.ensureId(), port: 'X2'), anchors)!
            .port,
        EcPort.c,
      );
    });

    test('an unbound device, a free end, and a stranger all resolve to null',
        () {
      final unbound = SchneiderATV320Config(label: 'x')
        ..coordinates = Coordinates(x: 0.2, y: 0.2)
        ..ensureId();
      final anchors = PageLinkAnchors([unbound], _canvas);
      expect(
          resolveEcLinkEnd(
              LinkEnd(assetId: unbound.ensureId(), port: 'A'), anchors),
          isNull);
      expect(resolveEcLinkEnd(LinkEnd(port: 'A'), anchors), isNull);
      expect(resolveEcLinkEnd(LinkEnd(assetId: 'nobody', port: 'A'), anchors),
          isNull);
    });
  });

  group('health from the two ends', () {
    LinkHealth health(EcBus bus, {EcPort a = EcPort.b, EcPort b = EcPort.a}) =>
        ecLinkHealth(bus, bus.at(1), a, bus, bus.at(2), b);

    test('both ends clean and in use is healthy', () {
      expect(health(_bus()), LinkHealth.healthy);
    });

    test('a missing link at either end takes the cable down', () {
      // 0x24: missing link, flagged on port B of the upstream drive.
      expect(health(_bus(linkState1: 0x24)), LinkHealth.down);
    });

    test('fresh CRC errors on one end degrade it', () {
      expect(health(_bus(crc1: const [0, 7, 0, 0])), LinkHealth.degraded);
    });

    test('the worse end decides', () {
      expect(
        health(_bus(linkState1: 0x24, crc1: const [0, 7, 0, 0])),
        LinkHealth.down,
      );
    });

    test('a run the topology does not know is drawn, not reported', () {
      // Port D on both ends: nothing plugged in as far as the PLC knows.
      expect(health(_bus(), a: EcPort.d, b: EcPort.d), LinkHealth.idle);
    });

    test('one bound end is judged on its own', () {
      final bus = _bus(crc1: const [0, 7, 0, 0]);
      expect(ecLinkHealth(bus, bus.at(1), EcPort.b, null, null, null),
          LinkHealth.degraded);
    });

    test('nothing known at all is unknown, not healthy', () {
      expect(ecLinkHealth(null, null, null, null, null, null),
          LinkHealth.unknown);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:tfc/page_creator/assets/ethercat_subdevice.dart';

import '../../helpers/ethercat_fixtures.dart';

void main() {
  group('decode', () {
    test('reads ST_EcSlaveInfo', () {
      final i = EcSubDeviceInfo.tryParse(info('CVS01.CN01.FD01 (ATV320 EtherCAT)',
          model: 'ATV320 EtherCAT', addr: 1017, prev: 1016, prevPort: 'B'))!;
      expect(i.shortName, 'CVS01.CN01.FD01');
      expect(i.model, 'ATV320 EtherCAT');
      expect(i.physAddr, 1017);
      expect(i.prevPhysAddr, 1016);
      expect(i.prevPort, EcPort.b);
    });

    test('reads ST_EcSlaveDiag, per-port arrays included', () {
      final d = EcSubDeviceDiag.tryParse(diag(
        crcPort: [0, 12, 0, 0],
        lost: [1, 0, 0, 0],
        crcSum: 12,
        crcStable: 30,
      ))!;
      expect(d.state, EcSubDeviceState.op);
      expect(d.crcPort, [0, 12, 0, 0]);
      expect(d.linkLostPort, [1, 0, 0, 0]);
      expect(d.crcFresh, isTrue);
    });

    test('a value that is not the struct decodes to null', () {
      expect(EcSubDeviceDiag.tryParse(DynamicValue(value: true)), isNull);
      expect(EcSubDeviceInfo.tryParse(DynamicValue(value: 3)), isNull);
    });

    test('a struct missing members degrades instead of throwing', () {
      final d = EcSubDeviceDiag.tryParse(DynamicValue(value: {
        EcDiagFields.deviceState: DynamicValue(value: 8),
      }))!;
      expect(d.state, EcSubDeviceState.op);
      expect(d.crcPort, [0, 0, 0, 0]);
      expect(d.health, EcHealth.ok);
    });

    test('falls back to the decoded enum when the raw byte is absent', () {
      final d = EcSubDeviceDiag.tryParse(DynamicValue(value: {
        EcDiagFields.state: DynamicValue(value: 4),
        EcDiagFields.error: DynamicValue(value: true),
      }))!;
      expect(d.state, EcSubDeviceState.safeOp);
      expect(d.error, isTrue);
    });

    test('X1/X2 read as A/B so cables drawn before binding keep meaning', () {
      expect(EcPort.parse('X1'), EcPort.a);
      expect(EcPort.parse('x2'), EcPort.b);
      expect(EcPort.parse('D'), EcPort.d);
      expect(EcPort.parse(''), isNull);
    });
  });

  group('health', () {
    EcSubDeviceDiag d({
      int state = 8,
      int link = 0,
      List<int> crc = const [0, 0, 0, 0],
      List<int> lost = const [0, 0, 0, 0],
      int crcSum = 0,
      int crcStable = 999999,
    }) =>
        EcSubDeviceDiag.tryParse(diag(
          deviceState: state,
          linkState: link,
          crcPort: crc,
          lost: lost,
          crcSum: crcSum,
          crcStable: crcStable,
        ))!;

    test('in OP and quiet is ok', () {
      expect(d().health, EcHealth.ok);
    });

    test('out of OP is a fault', () {
      expect(d(state: 4).health, EcHealth.fault);
      expect(d(state: 0).health, EcHealth.fault);
    });

    test('the error flag is a fault even in OP', () {
      expect(d(state: 0x18).health, EcHealth.fault);
    });

    test('a missing link is a fault, an extra one only a warning', () {
      // The PLC's bOk is false for both. An extra link is somebody having
      // plugged in something the export does not know about; the machine
      // runs.
      expect(d(link: 0x24).health, EcHealth.fault);
      expect(d(link: 0x28).health, EcHealth.warning);
    });

    test('CRC errors only count while fresh', () {
      expect(d(crc: [0, 40, 0, 0], crcSum: 40, crcStable: 60).health,
          EcHealth.warning);
      expect(
          d(crc: [0, 40, 0, 0], crcSum: 40, crcStable: 3 * 86400).health,
          EcHealth.ok,
          reason: 'forty errors last week and none since is a fixed cable');
    });

    test('a link drop stays a warning until somebody resets it', () {
      expect(d(lost: [0, 1, 0, 0]).health, EcHealth.warning);
    });

    test('port health is read off the flagged port only', () {
      final x = d(link: 0x24); // missing link on port B
      expect(x.portHealth(EcPort.a, inUse: true), EcHealth.ok);
      expect(x.portHealth(EcPort.b, inUse: true), EcHealth.fault);
    });

    test('a subdevice that is gone has no working port at all', () {
      final gone = d(state: 0, link: 0x01);
      expect(gone.present, isFalse);
      for (final p in EcPort.values) {
        expect(gone.portHealth(p, inUse: true), EcHealth.fault);
      }
    });

    test('but its empty sockets stay empty, not red', () {
      final gone = d(state: 0, link: 0x01);
      expect(gone.portHealth(EcPort.c, inUse: false), EcHealth.unused);
      // A fault that does name the port counts whether or not the export
      // puts a cable there.
      expect(d(link: 0x44).portHealth(EcPort.c, inUse: false), EcHealth.fault);
    });

    test('an unused port is unused, not ok', () {
      expect(d().portHealth(EcPort.c, inUse: false), EcHealth.unused);
    });

    test('worstHealth only reports unknown when nothing is known', () {
      expect(worstHealth([EcHealth.unknown, EcHealth.ok]), EcHealth.ok);
      expect(worstHealth([EcHealth.ok, EcHealth.fault]), EcHealth.fault);
      expect(worstHealth(const []), EcHealth.unknown);
    });
  });

  group('bus topology', () {
    // Master -> A1 -> A2, and a drop off A1's port C into T1 — the
    // ST107.A1.00 / ST101.EM02 shape on Device 2.
    final bus = EcBus.fromValues(
      'Device 2',
      info: array([
        info('A1 (EK1100)', addr: 1001, prev: 0, prevPort: 'B'),
        info('A2 (EL1008)', addr: 1002, prev: 1001, prevPort: 'B'),
        info('T1 (EP2338)', addr: 1003, prev: 1001, prevPort: 'C'),
        ...List.generate(5, (_) => emptyInfo()),
      ]),
      diag: array([
        diag(),
        diag(),
        diag(linkState: 0x14, deviceState: 8),
        ...List.generate(5, (_) => diag(deviceState: 0)),
      ]),
    );

    test('stops at the last named slot, not at 128', () {
      expect(bus.subdevices, hasLength(3));
      expect(bus.at(3)!.label, 'T1');
    });

    test('port A goes upstream, to the master for the first subdevice', () {
      expect(bus.neighbour(bus.at(1)!, EcPort.a)!.isMaster, isTrue);
      final up = bus.neighbour(bus.at(3)!, EcPort.a)!;
      expect(up.subdevice!.label, 'A1');
      expect(up.port, EcPort.c);
    });

    test('ports B to D are found by who names this subdevice upstream', () {
      final a1 = bus.at(1)!;
      expect(bus.neighbour(a1, EcPort.b)!.subdevice!.label, 'A2');
      expect(bus.neighbour(a1, EcPort.c)!.subdevice!.label, 'T1');
      expect(bus.neighbour(a1, EcPort.c)!.port, EcPort.a);
      expect(bus.neighbour(a1, EcPort.d), isNull);
    });

    test('port health brings the topology in', () {
      final a2 = bus.at(2)!;
      expect(bus.portHealth(a2, EcPort.a), EcHealth.ok);
      expect(bus.portHealth(a2, EcPort.b), EcHealth.unused);
    });

    test('counts by health', () {
      expect(bus.count(EcHealth.ok), 2);
    });

    test('without the info array the filled diag slots still list', () {
      final noInfo = EcBus.fromValues('D', diag: array([
        diag(),
        diag(deviceState: 4),
        diag(deviceState: 0),
      ]));
      expect(noInfo.subdevices, hasLength(2));
      expect(noInfo.at(2)!.label, '#2');
      expect(noInfo.at(2)!.health, EcHealth.fault);
    });
  });

  group('binding', () {
    final bus = EcBus.fromValues('D',
        info: array([
          info('A (X)', addr: 1001),
          info('B (X)', addr: 1002, prev: 1001),
          info('C (X)', addr: 1003, prev: 1002),
        ]));

    test('resolves by name first, then by position', () {
      expect(
          EcSubDeviceBinding(diagKey: 'd', position: 1, name: 'c')
              .resolve(bus)!
              .label,
          'C');
      expect(EcSubDeviceBinding(diagKey: 'd', position: 2).resolve(bus)!.label,
          'B');
    });

    test('a name that is no longer there falls back to the position', () {
      expect(
          EcSubDeviceBinding(diagKey: 'd', position: 2, name: 'gone')
              .resolve(bus)!
              .label,
          'B');
    });

    test('drifted when the name has moved since it was bound', () {
      // A subdevice inserted upstream shifts every position after it.
      expect(EcSubDeviceBinding(diagKey: 'd', position: 1, name: 'C').drifted(bus),
          isTrue);
      expect(EcSubDeviceBinding(diagKey: 'd', position: 3, name: 'C').drifted(bus),
          isFalse);
    });

    test('bound needs the array, and a position or a name', () {
      expect(EcSubDeviceBinding(diagKey: 'd', name: 'C').isBound, isTrue);
      expect(EcSubDeviceBinding(diagKey: 'd').isBound, isFalse);
      expect(EcSubDeviceBinding(position: 3).isBound, isFalse);
      expect(EcSubDeviceBinding().isEmpty, isTrue);
    });

    test('round-trips through JSON, leaving an absent name absent', () {
      final json = EcSubDeviceBinding(diagKey: 'd', infoKey: 'i', position: 17)
          .toJson();
      expect(json.containsKey('name'), isFalse);
      final b = EcSubDeviceBinding.fromJson(json);
      expect(b.position, 17);
      expect(b.keys, ['d', 'i']);
    });

    test('names compare without whitespace or case', () {
      expect(normaliseEcName('CVS01.\nCN01.fd01'), 'CVS01.CN01.FD01');
    });
  });

  group('master config', () {
    test('round-trips through JSON, leaving an absent count key absent', () {
      final json = EcBusConfig(label: 'Device 1', diagKey: 'd', infoKey: 'i')
          .toJson();
      expect(json.containsKey('countKey'), isFalse);
      final b = EcBusConfig.fromJson(json);
      expect(b.label, 'Device 1');
      expect(b.keys, ['d', 'i']);
    });
  });
}

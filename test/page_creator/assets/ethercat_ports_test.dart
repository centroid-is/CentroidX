import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/ethercat_ports.dart';
import 'package:tfc/page_creator/assets/ethercat_subdevice.dart';

import '../../helpers/ethercat_fixtures.dart';

void main() {
  setUp(debugResetEcPhysicalPorts);

  group('what the hardware has', () {
    test('a drive has two ports, not four', () {
      // The PLC publishes four port slots for every subdevice; an ATV320's C
      // and D read zero because they do not exist, which is not the same as
      // two clean sockets nobody plugged into.
      expect(ecPhysicalPorts('ATV320 EtherCAT'), [EcPort.a, EcPort.b]);
      expect(ecPhysicalPorts('EL1008'), [EcPort.a, EcPort.b]);
      expect(ecPhysicalPorts('EP2338-0002'), [EcPort.a, EcPort.b]);
    });

    test('a coupler has the branch its drops hang off', () {
      expect(ecPhysicalPorts('EK1100'), [EcPort.a, EcPort.b, EcPort.c]);
    });

    test('every model the ST101 export names is claimed by some device', () {
      // The models in ECT_Diag.TcGVL. One missing here is a row that falls
      // back to guessing its ports from the topology.
      for (final model in [
        'ATV320 EtherCAT',
        'CTEU-EtherCAT Modular',
        'CU2508',
        'EK1100',
        'EK1110',
        'EL1008',
        'EL2008',
        'EL2912',
        'EL6070',
        'EL9222-5500',
        'EP1918-0002',
        'EP2338-0002',
        'EP2338-1002',
        'PS2001-2410',
      ]) {
        expect(ecPhysicalPorts(model), isNotNull, reason: '$model is unclaimed');
      }
    });

    test('spelling is matched loosely, since the export decides it', () {
      expect(ecPhysicalPorts('atv320  ethercat'), [EcPort.a, EcPort.b]);
      expect(ecPhysicalPorts(' EL1008 '), [EcPort.a, EcPort.b]);
    });

    test('a model no device draws answers null', () {
      expect(ecPhysicalPorts('EL7031'), isNull);
      expect(ecPhysicalPorts(''), isNull);
      expect(ecPhysicalPorts(null), isNull);
    });
  });

  group('what a row draws', () {
    test('a known model shows its own sockets', () {
      final bus = EcBus.fromValues('D', info: array([
        info('CVS01.CN01.FD01 (ATV320 EtherCAT)',
            model: 'ATV320 EtherCAT', addr: 1001),
      ]), diag: array([diag()]));
      expect(ecShownPorts(bus, bus.at(1)!), [EcPort.a, EcPort.b]);
    });

    test('an unknown model shows the in-port and whatever is in use', () {
      final bus = EcBus.fromValues('D', info: array([
        info('X1 (EL7031)', model: 'EL7031', addr: 1001),
        info('X2 (EL7031)', model: 'EL7031', addr: 1002, prev: 1001,
            prevPort: 'C'),
      ]), diag: array([diag(), diag()]));
      // A drop on C, so C is real whatever the model is; B and D are not
      // drawn because nothing says they exist.
      expect(ecShownPorts(bus, bus.at(1)!), [EcPort.a, EcPort.c]);
    });

    test('counters on a port of an unknown model make it real too', () {
      final bus = EcBus.fromValues('D', info: array([
        info('X1 (EL7031)', model: 'EL7031', addr: 1001),
      ]), diag: array([
        diag(crcPort: const [0, 4, 0, 0], crcStable: 30),
      ]));
      expect(ecShownPorts(bus, bus.at(1)!), [EcPort.a, EcPort.b]);
    });

    test('with no info at all, only the in-port is certain', () {
      final bus = EcBus.fromValues('D', diag: array([diag()]));
      expect(ecShownPorts(bus, bus.at(1)!), [EcPort.a]);
    });
  });
}

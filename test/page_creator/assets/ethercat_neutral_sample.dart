// A small, invented EtherCAT bus for the tests and goldens that are about the
// pane's own chrome rather than about a particular topology.
//
// Deliberately not `ecSampleBuses()`: that one is the palette's picture of a
// real-looking station, and everything here ends up in a committed PNG. Names
// and models are made up — a coupler, a drive, an I/O module — so the images
// say nothing about anybody's plant.

import 'package:tfc/page_creator/assets/ethercat_subdevice.dart';

EcSubDevice _device(
  int position,
  String name,
  String model, {
  int prevPhysAddr = 0,
  EcPort? prevPort,
  int deviceState = 8,
  int linkState = 0,
  List<int> crc = const [0, 0, 0, 0],
  List<int> lost = const [0, 0, 0, 0],
  int stable = 0,
}) =>
    EcSubDevice(
      busLabel: 'Master 1',
      position: position,
      info: EcSubDeviceInfo(
        name: '$name ($model)',
        model: model,
        physAddr: 1000 + position,
        prevPhysAddr: prevPhysAddr,
        prevPort: prevPort,
      ),
      diag: EcSubDeviceDiag(
        deviceState: deviceState,
        linkState: linkState,
        crcSum: crc.fold(0, (a, b) => a + b),
        crcStableSeconds: stable,
        crcPort: crc,
        linkLostPort: lost,
      ),
    );

/// Three devices in a line: a coupler, a drive that has seen both kinds of
/// trouble, and an I/O module that is clean.
///
/// Position 2 is the interesting one — non-zero CRC *and* non-zero link loss —
/// because it is the case the explanation exists for.
EcBus neutralEcBus() => EcBus('Master 1', [
      _device(1, 'Coupler', 'Bus coupler', prevPort: EcPort.b),
      _device(
        2,
        'Drive 1',
        'Servo drive',
        prevPhysAddr: 1001,
        prevPort: EcPort.b,
        crc: const [6, 0, 0, 0],
        lost: const [3, 0, 0, 0],
        stable: 240,
      ),
      _device(
        3,
        'Module 1',
        'Digital input',
        prevPhysAddr: 1002,
        prevPort: EcPort.b,
      ),
    ]);

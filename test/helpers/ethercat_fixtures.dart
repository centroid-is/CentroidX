/// Values shaped like the PLC's `ST_EcSlaveInfo` / `ST_EcSlaveDiag`, for
/// tests that need a bus without a server.
library;

import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:tfc/page_creator/assets/ethercat_slave.dart';

DynamicValue array(List<DynamicValue> items) => DynamicValue(value: items);

DynamicValue info(
  String name, {
  String model = '',
  int addr = 1001,
  int prev = 0,
  String prevPort = 'B',
}) =>
    DynamicValue(value: {
      EcInfoFields.name: DynamicValue(value: name),
      EcInfoFields.model: DynamicValue(value: model),
      EcInfoFields.physAddr: DynamicValue(value: addr),
      EcInfoFields.prevPhysAddr: DynamicValue(value: prev),
      EcInfoFields.prevPort: DynamicValue(value: prevPort),
    });

DynamicValue emptyInfo() => info('', addr: 0, prevPort: '');

DynamicValue diag({
  int deviceState = 8,
  int linkState = 0,
  List<int> crcPort = const [0, 0, 0, 0],
  List<int> lost = const [0, 0, 0, 0],
  int? crcSum,
  int crcStable = 999999,
}) =>
    DynamicValue(value: {
      EcDiagFields.deviceState: DynamicValue(value: deviceState),
      EcDiagFields.linkState: DynamicValue(value: linkState),
      EcDiagFields.state: DynamicValue(value: deviceState & 0x0F),
      EcDiagFields.error: DynamicValue(value: deviceState & 0x10 != 0),
      EcDiagFields.linkDown: DynamicValue(value: linkState != 0),
      EcDiagFields.crcSum:
          DynamicValue(value: crcSum ?? crcPort.fold<int>(0, (a, b) => a + b)),
      EcDiagFields.crcStableSeconds: DynamicValue(value: crcStable),
      EcDiagFields.crcPort:
          DynamicValue(value: [for (final c in crcPort) DynamicValue(value: c)]),
      EcDiagFields.linkLostPort:
          DynamicValue(value: [for (final c in lost) DynamicValue(value: c)]),
      EcDiagFields.resetLinkLost: DynamicValue(value: false),
      EcDiagFields.resetCrc: DynamicValue(value: false),
      EcDiagFields.ok: DynamicValue(
          value: deviceState & 0x0F == 8 && deviceState & 0x10 == 0 &&
              linkState == 0),
    });

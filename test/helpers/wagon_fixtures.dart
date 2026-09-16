/// Values shaped like the PLC's `ST_WagonStation`, for tests that need a
/// wagon's station row without a server.
///
/// Every name here is invented. These build fixtures and goldens, and a
/// golden is a published image.
library;

import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:tfc/page_creator/assets/wagon_station.dart';

/// An `ARRAY [1..10] OF ST_WagonStation` holding [items].
DynamicValue stationArray(List<DynamicValue> items) =>
    DynamicValue(value: items);

/// One `ST_WagonStation`.
///
/// Defaults are a commissioned, idle source at the reference end, so a test
/// names only the members it is actually about.
DynamicValue station(
  String name, {
  int type = 0,
  int loc = 0,
  bool enabled = true,
  bool atStation = false,
  double position = 0,
  bool interlock = false,
  bool order = false,
  bool ready = false,
  bool deliveryComplete = false,
  bool outfeed = false,
  bool outfeedComplete = false,
  bool waitingForInterlock = false,
  Object? rawType,
  Object? rawLoc,
}) =>
    DynamicValue(value: {
      WagonStationFields.name: DynamicValue(value: name),
      WagonStationFields.type: DynamicValue(value: rawType ?? type),
      WagonStationFields.location: DynamicValue(value: rawLoc ?? loc),
      WagonStationFields.enabled: DynamicValue(value: enabled),
      WagonStationFields.atStation: DynamicValue(value: atStation),
      WagonStationFields.position: DynamicValue(value: position),
      WagonStationFields.interlock: DynamicValue(value: interlock),
      WagonStationFields.order: DynamicValue(value: order),
      WagonStationFields.ready: DynamicValue(value: ready),
      WagonStationFields.deliveryComplete:
          DynamicValue(value: deliveryComplete),
      WagonStationFields.outfeed: DynamicValue(value: outfeed),
      WagonStationFields.outfeedComplete: DynamicValue(value: outfeedComplete),
      WagonStationFields.waitingForInterlock:
          DynamicValue(value: waitingForInterlock),
    });

/// The stale tail of the array: an entry the plant never commissioned.
///
/// Not all-zero on purpose — a slot keeps whatever was last written to it, so
/// the filter has to turn on `xEnabled` and the name, not on the flags.
DynamicValue uncommissionedStation({String name = ''}) => station(
      name,
      enabled: false,
      position: 9999,
      order: true,
      ready: true,
    );

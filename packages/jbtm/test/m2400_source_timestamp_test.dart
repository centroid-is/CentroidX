/// The M2400 weigher supplies its own `sourceTimestamp`.
///
/// Jón's ruling on MORNING-NOTES item 0 (2026-09-07), option (b): the device
/// clients stamp, because the driver has the best estimate of when the reading
/// was produced. Downstream, `translateOpcUaSample` substitutes its own arrival
/// instant for any value that arrives unstamped and labels the result
/// `ts_source='plant'` anyway — so an unstamped weigher record becomes an alarm
/// row that says the plant said so when only the backend's socket did.
///
/// The M2400 is the one of the two protocols with a REAL device instant:
/// `M2400ParsedRecord.deviceTimestamp` is the weigher's own clock, recombined
/// from the record's date/time fields. These arms pin which of the two instants
/// is used in which case, and that the distinction is not silently blurred.
library;

import 'package:jbtm/src/m2400.dart';
import 'package:jbtm/src/m2400_dynamic_value.dart';
import 'package:jbtm/src/m2400_field_parser.dart';
import 'package:jbtm/src/m2400_fields.dart';
import 'package:test/test.dart';

/// Deliberately far apart, and deliberately not equal: every arm below
/// distinguishes the two, so a stamp that took the wrong one cannot pass by
/// coincidence.
final _deviceClock = DateTime.utc(2026, 3, 4, 12, 0, 0);
final _backendClock = DateTime.utc(2026, 3, 4, 18, 30, 15);

M2400ParsedRecord _record({DateTime? deviceTimestamp}) => M2400ParsedRecord(
      type: M2400RecordType.recBatch,
      typedFields: const {
        M2400Field.weight: 12.5,
        M2400Field.unit: 'kg',
      },
      unknownFields: const {99: 'raw'},
      rawFields: const {'1': '12.50', '2': 'kg', '99': 'raw'},
      receivedAt: _backendClock,
      deviceTimestamp: deviceTimestamp,
    );

void main() {
  group('convertRecordToDynamicValue stamps sourceTimestamp', () {
    test('a record with a device timestamp is stamped with the DEVICE clock',
        () {
      final dv = convertRecordToDynamicValue(_record(
        deviceTimestamp: _deviceClock,
      ));

      expect(dv.sourceTimestamp, _deviceClock);
      // The point of the arm: not the backend's receipt instant.
      expect(dv.sourceTimestamp, isNot(_backendClock));
    });

    // Superseded 2026-09-07 (afternoon ruling): this used to assert the
    // `?? receivedAt` fallback. `receivedAt` is a backend clock and this field
    // is read as a plant instant, so the fallback is gone. The full argument
    // and its arms live in `m2400_stamp_substitution_test.dart`; the arm is
    // kept here, inverted, so the pair of branches is still stated together.
    test('a record with NO device timestamp is left unstamped', () {
      final dv = convertRecordToDynamicValue(_record());

      expect(dv.sourceTimestamp, isNull);
    });

    test('every child carries the parent instant -- dotted keys are stamped too',
        () {
      // M2400ClientWrapper.subscribe('BATCH.weight') returns the CHILD
      // DynamicValue, not the parent. A parent-only stamp would leave every
      // dotted key in the key mapping unstamped and the fallback still firing
      // for the whole weigher fleet.
      final dv = convertRecordToDynamicValue(_record(
        deviceTimestamp: _deviceClock,
      ));

      expect(dv['weight'].sourceTimestamp, _deviceClock);
      expect(dv['unit'].sourceTimestamp, _deviceClock);
      expect(dv['99'].sourceTimestamp, _deviceClock);
      expect(dv['receivedAt'].sourceTimestamp, _deviceClock);
      expect(dv['deviceTimestamp'].sourceTimestamp, _deviceClock);
    });

    test('the unstamped-device case reaches the children too', () {
      final dv = convertRecordToDynamicValue(_record());

      expect(dv['weight'].sourceTimestamp, isNull);
      expect(dv['unit'].sourceTimestamp, isNull);
    });

    test('stamping does not disturb the payload the converter already built',
        () {
      final dv = convertRecordToDynamicValue(_record(
        deviceTimestamp: _deviceClock,
      ));

      expect(dv.name, 'recBatch');
      expect(dv['weight'].asDouble, 12.5);
      expect(dv['unit'].asString, 'kg');
      expect(dv['99'].asString, 'raw');
      expect(dv['receivedAt'].asInt, _backendClock.microsecondsSinceEpoch);
      expect(dv['deviceTimestamp'].asInt, _deviceClock.microsecondsSinceEpoch);
    });
  });
}

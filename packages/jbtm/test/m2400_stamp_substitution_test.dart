/// A weigher that stops sending its clock must not keep claiming it has one.
///
/// Jón's ruling, 2026-09-07 afternoon, on the measured outcome of the
/// driver-stamp task. That task made `convertRecordToDynamicValue` stamp
/// `record.deviceTimestamp ?? record.receivedAt`, which fixed the honest half
/// and left the other half indistinguishable from it: `receivedAt` is the
/// backend's own clock at the moment the frame was parsed, and every consumer
/// downstream — `translateOpcUaSample`, `resolveAlarmStamp`, the
/// `alarm_history.ts_source` column — read a non-null `sourceTimestamp` as
/// "the source said so" and wrote `plant`.
///
/// `package:open62541` states the field's contract in so many words
/// (`dynamic_value.dart:90-97`): *"The instant the SOURCE (the PLC, not this
/// process) says the value was produced, or null when the server sent no source
/// timestamp. Null is deliberate and load-bearing: a consumer that needs an
/// instant must substitute its own arrival time knowingly, and record that it
/// did."* `receivedAt` is this process. So the fallback goes, and the genuine
/// `deviceTimestamp` branch — the real win of the driver-stamp task — stays.
///
/// The instant is not lost: `receivedAt` is still a child field on the record,
/// which is where a consumer that wants the parse instant should read it from
/// and where nothing mistakes it for the scale's own clock.
library;

import 'package:jbtm/src/m2400.dart';
import 'package:jbtm/src/m2400_dynamic_value.dart';
import 'package:jbtm/src/m2400_field_parser.dart';
import 'package:jbtm/src/m2400_fields.dart';
import 'package:test/test.dart';

/// Six hours apart, deliberately. Every arm below distinguishes the two, so a
/// stamp that took the wrong instant cannot pass by coincidence.
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
  // The two instants must actually differ, or every arm below is vacuous: an
  // arm that says "not the backend clock" proves nothing when the two clocks
  // are the same reading.
  test('the fixture instants differ', () {
    expect(_deviceClock, isNot(_backendClock));
  });

  group('a substituted instant is not offered as a source timestamp', () {
    test('NEGATIVE: no device clock leaves sourceTimestamp null', () {
      final dv = convertRecordToDynamicValue(_record());

      // Null, not receivedAt. A non-null stamp here is read as a plant instant
      // by everything downstream, and this branch has no plant instant.
      expect(dv.sourceTimestamp, isNull);
    });

    test('CONTROL: a device clock IS stamped, and it is the device\'s', () {
      final dv = convertRecordToDynamicValue(_record(
        deviceTimestamp: _deviceClock,
      ));

      expect(dv.sourceTimestamp, _deviceClock);
      expect(dv.sourceTimestamp, isNot(_backendClock));
    });

    test('NEGATIVE: the children are unstamped too, not just the parent', () {
      // `M2400ClientWrapper.subscribe('BATCH.weight')` hands back the CHILD.
      // A parent-only correction would leave every dotted key in the key
      // mapping still claiming a source instant it does not have.
      final dv = convertRecordToDynamicValue(_record());

      expect(dv['weight'].sourceTimestamp, isNull);
      expect(dv['unit'].sourceTimestamp, isNull);
      expect(dv['99'].sourceTimestamp, isNull);
      expect(dv['receivedAt'].sourceTimestamp, isNull);
    });

    test('CONTROL: with a device clock the children carry it', () {
      final dv = convertRecordToDynamicValue(_record(
        deviceTimestamp: _deviceClock,
      ));

      expect(dv['weight'].sourceTimestamp, _deviceClock);
      expect(dv['unit'].sourceTimestamp, _deviceClock);
      expect(dv['99'].sourceTimestamp, _deviceClock);
      expect(dv['deviceTimestamp'].sourceTimestamp, _deviceClock);
    });
  });

  group('the parse instant is still reachable, just not as a source stamp', () {
    test('receivedAt survives as a child field on both branches', () {
      final unstamped = convertRecordToDynamicValue(_record());
      final stamped = convertRecordToDynamicValue(_record(
        deviceTimestamp: _deviceClock,
      ));

      expect(unstamped['receivedAt'].asInt,
          _backendClock.microsecondsSinceEpoch);
      expect(stamped['receivedAt'].asInt, _backendClock.microsecondsSinceEpoch);
      // And the device instant is only present when the device sent one.
      expect(stamped['deviceTimestamp'].asInt,
          _deviceClock.microsecondsSinceEpoch);
      expect((unstamped.value as Map).containsKey('deviceTimestamp'), isFalse);
      expect((stamped.value as Map).containsKey('deviceTimestamp'), isTrue);
    });

    test('the payload is untouched by either branch', () {
      final dv = convertRecordToDynamicValue(_record());

      expect(dv.name, 'recBatch');
      expect(dv['weight'].asDouble, 12.5);
      expect(dv['unit'].asString, 'kg');
      expect(dv['99'].asString, 'raw');
    });
  });
}

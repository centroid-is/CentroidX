/// The non-OPC-UA drivers supply their own source timestamp, so an alarm row
/// stops labelling a backend arrival instant as plant time.
///
/// **The defect these arms close.** Every protocol enters the pipe through
/// `PipeWorkerEndpoint._onSample` -> [translateOpcUaSample], which substitutes
/// its own `arrivedAt` when the sample carries no `sourceTimestamp` and calls
/// `onSourceTimeFallback`. Neither the Modbus driver nor the M2400 weighers
/// ever set one, so for the entire non-OPC-UA fleet the substitution fired on
/// every value and `alarm_history.ts_source` said `'plant'` over what was
/// really a backend receipt — exactly the lie `AlarmTsSource.backendReceipt`
/// exists to prevent (D-2).
///
/// Jón's ruling on MORNING-NOTES item 0, 2026-09-07, was option (b): the device
/// clients stamp, because the driver has the best estimate the protocol admits.
///
/// **Half of that was reversed the same afternoon** on the measured outcome:
/// only the M2400's genuine `deviceTimestamp` is a source instant. Modbus's
/// `readAt` and the M2400's `receivedAt` fallback are both clocks on this host
/// and no longer enter the field. See `stamp_substitution_test.dart` for the
/// argument and the arms; what remains here is what survived.
///
/// `onSourceTimeFallback` is the existing observable, so it is what these arms
/// watch. **Four of them are negative arms** ("the counter did NOT move"), and a
/// negative arm that cannot fail proves nothing — so the last group is the
/// control: a genuinely unstamped OPC UA sample must still move the counter and
/// still take `arrivedAt`. If the control ever goes green-by-collapse, the
/// negative arms above it are worthless.
@TestOn('vm')
library;


import 'package:jbtm/src/m2400.dart';
import 'package:jbtm/src/m2400_dynamic_value.dart';
import 'package:jbtm/src/m2400_field_parser.dart';
import 'package:jbtm/src/m2400_fields.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue, NodeId;
import 'package:tfc_dart/core/opcua_value_translation.dart';
import 'package:tfc_dart/core/state_man.dart' show StateMan;
import 'package:test/test.dart';

/// An arrival instant deliberately nowhere near any device instant, so a stamp
/// that fell back to it cannot be mistaken for one that did not.
final _arrivedAt = DateTime.utc(2031, 1, 1, 0, 0, 0);

/// A fixed epoch the applyBitMask arms hang their instants off, so nothing here
/// reads a real clock.
final _t0 = DateTime.utc(2026, 9, 7, 6, 0, 0);

DateTime _t(int seconds) => _t0.add(Duration(seconds: seconds));

/// Runs a sample through the pipe's translation edge and reports whether the
/// substitution fired.
({int substitutions, DateTime? sourceTime}) _translate(DynamicValue dv) {
  var fallbacks = 0;
  final translated = translateOpcUaSample(
    dv,
    arrivedAt: _arrivedAt,
    onSourceTimeFallback: () => fallbacks++,
  );
  return (substitutions: fallbacks, sourceTime: translated.sourceTime);
}

void main() {
  // The two Modbus groups that stood here -- "the driver read instant is the
  // source timestamp" and "UMAS-by-name values are stamped too" -- were
  // REVERSED the same afternoon, and their replacements live in
  // `stamp_substitution_test.dart`.
  //
  // Why: `readAt` is a clock on this host, and the field it was being written
  // into is documented (open62541 `dynamic_value.dart:90-97`) as the instant
  // the SOURCE, not this process, says the value was produced. Everything
  // downstream reads a non-null value there as a plant instant, so
  // `alarm_history.ts_source` said `plant` over a backend clock for the whole
  // Modbus fleet -- in direct mode as well as through the pipe. A bare
  // `DateTime` has no room to say which clock it came from, so the claim is not
  // made at all. See `.planning/quick/20260907-stamp-substitution-flag/`.
  //
  // What SURVIVED that reversal is everything below: the M2400's genuine device
  // instant, `applyBitMask` carrying real provenance across the mask, and the
  // control proving the OPC UA substitution path is still live.

  group('M2400: the weigher value reaches the pipe stamped', () {
    test('a record with a device timestamp does NOT trigger the substitution',
        () {
      final deviceClock = DateTime.utc(2026, 9, 7, 5, 55, 0);
      final dv = convertRecordToDynamicValue(M2400ParsedRecord(
        type: M2400RecordType.recBatch,
        typedFields: const {M2400Field.weight: 12.5},
        unknownFields: const {},
        rawFields: const {'1': '12.50'},
        receivedAt: DateTime.utc(2026, 9, 7, 5, 55, 2),
        deviceTimestamp: deviceClock,
      ));

      final result = _translate(dv);
      expect(result.substitutions, 0);
      expect(result.sourceTime, deviceClock);
      expect(result.sourceTime, isNot(_arrivedAt));
    });

    test('a dotted child value does NOT trigger the substitution either', () {
      // M2400ClientWrapper.subscribe('BATCH.weight') publishes the child.
      final deviceClock = DateTime.utc(2026, 9, 7, 5, 55, 0);
      final parent = convertRecordToDynamicValue(M2400ParsedRecord(
        type: M2400RecordType.recBatch,
        typedFields: const {M2400Field.weight: 12.5},
        unknownFields: const {},
        rawFields: const {'1': '12.50'},
        receivedAt: DateTime.utc(2026, 9, 7, 5, 55, 2),
        deviceTimestamp: deviceClock,
      ));

      final result = _translate(parent['weight']);
      expect(result.substitutions, 0);
      expect(result.sourceTime, deviceClock);
    });
  });

  group('applyBitMask carries the provenance across the mask', () {
    test('a masked value keeps statusCode and sourceTimestamp', () {
      final stamped = DynamicValue(value: 0x02, typeId: NodeId.uint16)
        ..statusCode = opcUaUncertainLastUsableValue
        ..sourceTimestamp = _t(3);

      final masked = StateMan.applyBitMask(stamped, 0x02, 1);

      expect(masked.value, true, reason: 'single-bit mask yields a bool');
      expect(masked.sourceTimestamp, _t(3));
      expect(masked.statusCode, opcUaUncertainLastUsableValue);
    });

    test('a multi-bit masked value keeps them too', () {
      final stamped = DynamicValue(value: 0x0C, typeId: NodeId.uint16)
        ..statusCode = opcUaStatusCodeGood
        ..sourceTimestamp = _t(4);

      final masked = StateMan.applyBitMask(stamped, 0x0C, 2);

      expect(masked.value, 3);
      expect(masked.sourceTimestamp, _t(4));
      expect(masked.statusCode, opcUaStatusCodeGood);
    });
  });

  group('CONTROL: the substitution path stays live', () {
    // Without this group the four "did NOT substitute" arms above are
    // unfalsifiable: deleting the fallback branch entirely would make them all
    // pass. This is the arm that dies if that happens.
    test('an unstamped OPC UA sample DOES substitute and DOES report it', () {
      final unstamped = DynamicValue(value: 7)..statusCode = 0;

      final result = _translate(unstamped);

      expect(result.substitutions, 1);
      expect(result.sourceTime, _arrivedAt);
    });

    test('a stamped OPC UA sample keeps the server instant, as it always did',
        () {
      final serverInstant = DateTime.utc(2026, 9, 7, 5, 0, 0);
      final stamped = DynamicValue(value: 7)
        ..statusCode = 0
        ..sourceTimestamp = serverInstant;

      final result = _translate(stamped);

      expect(result.substitutions, 0);
      expect(result.sourceTime, serverInstant);
    });
  });
}

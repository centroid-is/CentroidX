import 'dart:collection';

import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:test/test.dart';
import 'package:tfc_dart/core/collector.dart';

/// A motor-HMI-shaped struct, the shape `sample_members` exists for: the
/// whole struct is the subscribed key, but only the chosen members belong in
/// the timeseries — as one row per sample in ONE table.
DynamicValue motorStruct({double frequency = 25.0, double current = 3.2}) {
  return DynamicValue.fromMap(LinkedHashMap<String, dynamic>.from({
    'p_stat_Frequency': frequency,
    'p_stat_Current': current,
    'p_stat_xRunning': true,
    'p_cfg_AutoFreq': 30.0,
    'inner': LinkedHashMap<String, dynamic>.from({'leaf': 7}),
  }));
}

void main() {
  group('extractSampleMember', () {
    test('extracts a top-level member from a struct', () {
      final v = extractSampleMember(motorStruct(), 'p_stat_Frequency');
      expect(v, isNotNull);
      expect(v!.asDouble, 25.0);
    });

    test('extracts a nested member through a dotted path', () {
      final v = extractSampleMember(motorStruct(), 'inner.leaf');
      expect(v, isNotNull);
      expect(v!.asInt, 7);
    });

    test('returns null for a missing member', () {
      expect(extractSampleMember(motorStruct(), 'p_stat_missing'), isNull);
      expect(extractSampleMember(motorStruct(), 'inner.missing'), isNull);
      expect(
          extractSampleMember(motorStruct(), 'p_stat_Frequency.leaf'), isNull,
          reason: 'Descending into a non-object must degrade to null, '
              'never throw.');
    });
  });

  group('extractSampleMembers (one row per sample)', () {
    test('builds one object row keyed by the full member paths', () {
      final row = extractSampleMembers(
          motorStruct(frequency: 42.5, current: 1.5),
          ['p_stat_Frequency', 'p_stat_Current']);
      expect(row, isNotNull);
      expect(row!.isObject, isTrue);
      expect(row['p_stat_Frequency'].asDouble, 42.5);
      expect(row['p_stat_Current'].asDouble, 1.5);
      expect(row.contains('p_stat_xRunning'), isFalse,
          reason: 'Only the chosen members ride the row.');
    });

    test('omits unresolvable members but keeps the row', () {
      final row = extractSampleMembers(
          motorStruct(), ['p_stat_Frequency', 'p_stat_missing']);
      expect(row, isNotNull);
      expect(row!.contains('p_stat_Frequency'), isTrue);
      expect(row.contains('p_stat_missing'), isFalse);
    });

    test('returns null when nothing resolves — the sample must be skipped, '
        'not inserted as garbage', () {
      expect(extractSampleMembers(motorStruct(), ['nope', 'also.nope']),
          isNull);
      expect(
          extractSampleMembers(
              DynamicValue(value: true), ['p_stat_Frequency']),
          isNull,
          reason: 'A non-struct value has no members to sample.');
    });
  });

  group('CollectEntry.sampleMembers JSON', () {
    test('round-trips through sample_members', () {
      final entry = CollectEntry(
        key: 'motors.CVS01_CN01.HMI',
        sampleMembers: ['p_stat_Frequency', 'p_stat_Current'],
      );
      final json = entry.toJson();
      expect(
          json['sample_members'], ['p_stat_Frequency', 'p_stat_Current']);

      final restored = CollectEntry.fromJson(json);
      expect(restored.sampleMembers, ['p_stat_Frequency', 'p_stat_Current']);
    });

    test('legacy entries without sample_members load as whole-value '
        'collection', () {
      final restored = CollectEntry.fromJson({'key': '/some/key'});
      expect(restored.sampleMembers, isNull);
    });
  });
}

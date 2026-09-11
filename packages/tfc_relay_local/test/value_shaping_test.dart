/// The three value shapings a plant keymapping brings with it.
///
/// All three were **lifted**, not reimplemented, and the reason is that their
/// edge cases are the plant's rather than this project's. The shipped
/// `applyBitMask` is a pure static at
/// `packages/tfc_dart/lib/core/state_man.dart:1314-1327`, quoted here so the
/// three arms below can be read against it:
///
/// ```dart
/// static DynamicValue applyBitMask(
///     DynamicValue value, int? bitMask, int? bitShift) {
///   if (bitMask == null) return value;
///   final raw = value.value;
///   if (raw is! num) return value;
///   final intValue = raw.toInt();
///   final masked = (intValue & bitMask) >>> (bitShift ?? 0);
///   // Single-bit: power of two check (exactly one bit set)
///   final isSingle = bitMask != 0 && (bitMask & (bitMask - 1)) == 0;
///   if (isSingle) {
///     return DynamicValue(value: masked != 0, typeId: NodeId.boolean);
///   }
///   return DynamicValue(value: masked, typeId: value.typeId);
/// }
/// ```
///
/// A mask that starts returning ints where the page expects bools turns every
/// indicator on that page permanently truthy — `1` is as true as `true` to a
/// widget that only asks `asBool` — which is a screen full of green while the
/// line is down (T-08-15).
///
/// The M2400 shaping is inline on both shipped paths (`:2064-2073` on
/// subscribe, `:1819-1827` on read) and `extractSampleMember` /
/// `extractSampleMembers` are `collector.dart:62-69` and `:75-85`. That last
/// one's rule — a sample where **no** member resolves is skipped rather than
/// inserted — looks arbitrary until a struct arrives with none of its members.
@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

void main() {
  group('applyBitMask, the three shipped arms', () {
    test('a single-bit mask on an int yields a bool', () {
      final shaped = applyBitMask(DynamicValue(value: 0x05), 0x04, 2);

      expect(shaped.value, isTrue);
      expect(shaped.value, isA<bool>(),
          reason: 'an int here reads as true to every widget that asks '
              'asBool, so the indicator is on forever');
      expect(shaped.typeId, ValueType.boolean);
    });

    test('a single-bit mask that misses yields false, not null', () {
      final shaped = applyBitMask(DynamicValue(value: 0x01), 0x04, 2);

      expect(shaped.value, isFalse);
      expect(shaped.isNull, isFalse);
    });

    test('a multi-bit mask yields the shifted int', () {
      // 0xF0 over 0xA5 is 0xA0, shifted down by 4 is 0x0A.
      final shaped = applyBitMask(DynamicValue(value: 0xA5), 0xF0, 4);

      expect(shaped.value, 0x0A);
      expect(shaped.value, isA<int>());
    });

    test('a non-numeric value passes through unchanged', () {
      final original = DynamicValue(value: 'RUNNING');
      final shaped = applyBitMask(original, 0x01, 0);

      expect(shaped.value, 'RUNNING');
    });

    test('a null mask passes through unchanged', () {
      final original = DynamicValue(value: 0xFF);
      expect(applyBitMask(original, null, null).value, 0xFF);
    });

    test('a null shift is a shift of zero', () {
      expect(applyBitMask(DynamicValue(value: 0x03), 0x03, null).value, 0x03);
    });

    test('quality survives the mask, and is never upgraded to good', () {
      final degraded = DynamicValue(
          value: 0x05, quality: Quality.uncertainLastKnown);

      expect(applyBitMask(degraded, 0x04, 2).quality,
          Quality.uncertainLastKnown);
      expect(applyBitMask(degraded, 0xF0, 4).quality,
          Quality.uncertainLastKnown);
      expect(applyBitMask(degraded, null, null).quality,
          Quality.uncertainLastKnown);
    });

    test('the source time survives the mask', () {
      final at = DateTime.utc(2026, 9, 1, 12);
      final shaped =
          applyBitMask(DynamicValue(value: 0x05, sourceTime: at), 0x04, 2);

      expect(shaped.sourceTime, at);
    });
  });

  group('the M2400 shaping: filter, then extract', () {
    DynamicValue record({int status = 14, Quality quality = Quality.good}) =>
        DynamicValue(
          value: {'status': status, 'weight': 12.5, 'unit': 'kg'},
          quality: quality,
        );

    test('a record whose status fails the filter produces NO value', () {
      final shaped =
          applyM2400Shaping(record(status: 3), statusFilter: 14, field: 'weight');

      expect(shaped, isNull,
          reason: 'the sample is filtered, not emitted as a null-valued '
              'reading — a null reading would overwrite the last good weight '
              'on the screen with a dash');
    });

    test('a record that passes the filter yields the named field', () {
      final shaped = applyM2400Shaping(record(), statusFilter: 14, field: 'weight');

      expect(shaped, isNotNull);
      expect(shaped!.asDouble, 12.5);
    });

    test('no filter configured means every record passes', () {
      final shaped = applyM2400Shaping(record(status: 3), field: 'weight');

      expect(shaped!.asDouble, 12.5);
    });

    test('no field configured yields the whole record', () {
      final shaped = applyM2400Shaping(record(), statusFilter: 14);

      expect(shaped!.isObject, isTrue);
      expect(shaped['weight'].asDouble, 12.5);
    });

    test('a field the record does not carry is errorConfig, not a throw and '
        'not a plausible zero', () {
      final shaped = applyM2400Shaping(record(), field: 'temperature');

      expect(shaped, isNotNull);
      expect(shaped!.quality, Quality.errorConfig);
      expect(shaped.isNull, isTrue);
    });

    test('a status filter against a record with no status field is '
        'errorConfig, not a silent drop', () {
      final headless = DynamicValue(value: {'weight': 12.5});
      final shaped =
          applyM2400Shaping(headless, statusFilter: 14, field: 'weight');

      expect(shaped!.quality, Quality.errorConfig,
          reason: 'silently dropping every record of a misconfigured weigher '
              'is the page-reads-unknown-forever failure');
    });

    test('quality survives extraction — the member does not come back good', () {
      final shaped = applyM2400Shaping(
          record(quality: Quality.uncertainLastKnown),
          statusFilter: 14,
          field: 'weight');

      expect(shaped!.quality, Quality.uncertainLastKnown);
      expect(shaped.asDouble, 12.5);
    });

    test('the record\'s source time rides along with the extracted field', () {
      final at = DateTime.utc(2026, 9, 1, 12);
      final stamped = DynamicValue(
          value: {'status': 14, 'weight': 12.5}, sourceTime: at);

      expect(applyM2400Shaping(stamped, field: 'weight')!.sourceTime, at);
    });
  });

  group('sample_members: one row per sample, keyed by the full dotted path',
      () {
    DynamicValue sensor({Quality quality = Quality.good}) => DynamicValue(
          value: {
            'p_stat': {
              'xOutput': true,
              'tBlockedFor': 3,
            },
            'p_cmd': {'xReset': false},
          },
          quality: quality,
        );

    test('a resolvable dotted path walks into the struct', () {
      expect(extractSampleMember(sensor(), 'p_stat.tBlockedFor')!.asInt, 3);
    });

    test('a path whose segment is missing resolves to null', () {
      expect(extractSampleMember(sensor(), 'p_stat.xMissing'), isNull);
      expect(extractSampleMember(sensor(), 'nope.xOutput'), isNull);
    });

    test('a path that runs off the end of a scalar resolves to null', () {
      expect(
          extractSampleMember(sensor(), 'p_stat.xOutput.deeper'), isNull);
    });

    test('the row is keyed by the FULL dotted path, not the leaf name', () {
      final row = extractSampleMembers(
          sensor(), ['p_stat.xOutput', 'p_stat.tBlockedFor']);

      expect(row!.isObject, isTrue);
      expect(row.contains('p_stat.xOutput'), isTrue);
      expect(row.contains('p_stat.tBlockedFor'), isTrue);
      expect(row['p_stat.tBlockedFor'].asInt, 3);
      expect(row.contains('xOutput'), isFalse,
          reason: 'two members named the same thing under two parents would '
              'collide, and one chart would silently plot the other one');
    });

    test('a member missing from the sample is omitted, not nulled', () {
      final row = extractSampleMembers(
          sensor(), ['p_stat.xOutput', 'p_stat.xNeverExisted']);

      expect(row!.length, 1);
      expect(row.contains('p_stat.xNeverExisted'), isFalse);
    });

    test('a sample where NO member resolves returns null — that sample is '
        'skipped, not inserted', () {
      expect(extractSampleMembers(sensor(), ['a.b', 'c.d']), isNull);
      expect(extractSampleMembers(sensor(), const []), isNull);
    });

    test('quality survives the pick, and worst-wins over the members', () {
      final row = extractSampleMembers(
          sensor(quality: Quality.uncertainLastKnown), ['p_stat.xOutput']);

      expect(row!.quality, Quality.uncertainLastKnown,
          reason: 'a transform that hands back a good-quality row from an '
              'uncertain sample is a chart nobody can tell was guessed');
    });

    test('one bad member makes the whole row bad — worst-wins, not an '
        'average', () {
      final mixed = DynamicValue(value: {
        'p_stat': {
          'xOutput': DynamicValue(value: true),
          'tBlockedFor':
              DynamicValue(value: null, quality: Quality.badCommFault),
        },
      });

      final row = extractSampleMembers(
          mixed, ['p_stat.xOutput', 'p_stat.tBlockedFor']);

      expect(row!.quality, Quality.badCommFault);
    });

    test('a single member carries the parent sample\'s quality out with it',
        () {
      final degraded = sensor(quality: Quality.uncertainLastKnown);

      expect(extractSampleMember(degraded, 'p_stat.xOutput')!.quality,
          Quality.uncertainLastKnown);
    });
  });
}

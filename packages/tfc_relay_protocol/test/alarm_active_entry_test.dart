/// `AlarmActiveEntry`: the shape one active alarm takes on the wire.
///
/// **Why the field names are asserted against literals.** This payload crosses
/// between two halves that are deployed independently — a backend that has
/// been restarted with a new build and a panel on a station that has not. A
/// renamed field does not fail a test that reads it back through the same
/// constant; it fails silently in the plant, at the moment the banner is
/// needed. So every name is pinned against a string literal here, once, and
/// the `static const` on the class is what the rest of the workspace spells.
library;

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

void main() {
  group('AlarmActiveEntry', () {
    AlarmActiveEntry sample({
      List<String> group = const ['Line 3', 'Multivac'],
      String? historyId = '01J0000000000000000000000A',
      String tsSource = AlarmActiveEntry.tsSourcePlant,
    }) =>
        AlarmActiveEntry(
          uid: 'multivac-seal-temp',
          ruleIndex: 1,
          level: 'error',
          title: 'Seal bar over temperature',
          description: 'The seal bar exceeded its limit for more than 5 s.',
          group: group,
          expression: 'MUL01.seal.temp (212.0) > 200',
          activeAtMs: 1788696000000,
          tsSource: tsSource,
          pendingAck: true,
          historyId: historyId,
        );

    // ------------------------------------------------------------------ 1
    test('the field set is exactly D-9\'s, spelled as literals', () {
      final json = sample().toJson();

      expect(
        json.keys.toSet(),
        <String>{
          'uid',
          'ruleIndex',
          'level',
          'title',
          'description',
          'group',
          'expression',
          'activeAtMs',
          'tsSource',
          'pendingAck',
          'historyId',
        },
        reason: 'these names cross a wire between two independently deployed '
            'halves; a rename is a silent plant failure, not a test failure',
      );

      // And the constants the rest of the workspace spells are those names.
      expect(AlarmActiveEntry.kUid, 'uid');
      expect(AlarmActiveEntry.kRuleIndex, 'ruleIndex');
      expect(AlarmActiveEntry.kLevel, 'level');
      expect(AlarmActiveEntry.kTitle, 'title');
      expect(AlarmActiveEntry.kDescription, 'description');
      expect(AlarmActiveEntry.kGroup, 'group');
      expect(AlarmActiveEntry.kExpression, 'expression');
      expect(AlarmActiveEntry.kActiveAtMs, 'activeAtMs');
      expect(AlarmActiveEntry.kTsSource, 'tsSource');
      expect(AlarmActiveEntry.kPendingAck, 'pendingAck');
      expect(AlarmActiveEntry.kHistoryId, 'historyId');
    });

    // ------------------------------------------------------------------ 2
    test('round trips losslessly, including a null historyId and an empty '
        'group', () {
      final full = sample();
      expect(AlarmActiveEntry.fromJson(full.toJson()), full);

      // The two absences that a "just drop it if it is falsey" encoder would
      // lose: 14-05 leaves historyId null (14-06 fills it), and a root-level
      // alarm has no group at all.
      final bare = sample(group: const [], historyId: null);
      final decoded = AlarmActiveEntry.fromJson(bare.toJson());
      expect(decoded, bare);
      expect(decoded.historyId, isNull);
      expect(decoded.group, isEmpty);
    });

    // ------------------------------------------------------------------ 3
    test('activeAtMs is an int of epoch milliseconds UTC, and decodes to a '
        'UTC DateTime', () {
      final at = DateTime.utc(2026, 9, 6, 12, 0, 0);
      final entry = AlarmActiveEntry(
        uid: 'a',
        ruleIndex: 0,
        level: 'info',
        title: 't',
        description: 'd',
        activeAtMs: at.millisecondsSinceEpoch,
        tsSource: AlarmActiveEntry.tsSourcePlant,
      );

      expect(entry.toJson()['activeAtMs'], isA<int>());
      expect(entry.toJson()['activeAtMs'], at.millisecondsSinceEpoch);

      // A local-time round trip is the bug that makes two panels in different
      // time zones disagree about when the line stopped.
      expect(entry.activeAt.isUtc, isTrue);
      expect(entry.activeAt, at);
      expect(AlarmActiveEntry.fromJson(entry.toJson()).activeAt, at);
    });

    // ------------------------------------------------------------------ 4
    test('tsSource decodes only plant and backend_receipt; anything else is '
        'refused by name', () {
      expect(AlarmActiveEntry.tsSourcePlant, 'plant');
      expect(AlarmActiveEntry.tsSourceBackendReceipt, 'backend_receipt');

      for (final wire in [
        AlarmActiveEntry.tsSourcePlant,
        AlarmActiveEntry.tsSourceBackendReceipt,
      ]) {
        final json = sample(tsSource: wire).toJson();
        expect(AlarmActiveEntry.fromJson(json).tsSource, wire);
      }

      final poisoned = sample().toJson()..['tsSource'] = 'utc';
      expect(
        () => AlarmActiveEntry.fromJson(poisoned),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('utc'))
            .having((e) => e.message, 'message', contains('plant'))
            .having((e) => e.message, 'message', contains('backend_receipt'))),
        reason: 'a provenance nobody can interpret must be refused by name, '
            'never defaulted to "the plant said so"',
      );
    });

    // ------------------------------------------------------------------ 5
    test('the list form goes through DynamicValue\'s sanitizing constructor '
        'and comes back', () {
      final entries = [sample(), sample(historyId: null)];
      final encoded = AlarmActiveEntry.encodeList(entries);

      // Depth 3 for a plain entry (list -> entry map -> leaf), 4 through the
      // `group` list. DynamicValue's bound is 64.
      final value = DynamicValue(value: encoded);
      expect(value.quality, Quality.good);
      expect(value.asArray, hasLength(2));

      final round = AlarmActiveEntry.decodeList(value.toJson(slim: true));
      expect(round.entries, entries);
      expect(round.truncated, isFalse);
      expect(round.omitted, 0);
    });

    // ------------------------------------------------------------------ 6
    test('a truncated list carries one explicit marker, spelled once', () {
      final entries = [sample()];
      final encoded =
          AlarmActiveEntry.encodeList(entries, truncated: true, omitted: 41);

      expect(encoded, isA<List<Object?>>());
      expect((encoded as List).length, 2,
          reason: 'the cap\'s worth of entries, plus the marker');

      final round = AlarmActiveEntry.decodeList(
          DynamicValue(value: encoded).toJson(slim: true));
      expect(round.entries, entries,
          reason: 'the marker is not mistaken for an alarm');
      expect(round.truncated, isTrue);
      expect(round.omitted, 41);
    });
  });
}

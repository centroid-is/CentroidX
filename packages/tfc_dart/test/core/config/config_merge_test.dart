/// `mergeItemsForSave`: what an editor's save may replace, decided against
/// what the store holds now and what the editor was shown.
library;

import 'package:test/test.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_merge.dart';
import 'package:tfc_dart/core/config/config_store_errors.dart';

ConfigItem key(String id, String identifier, {int rev = 1}) => ConfigItem.of(
      kind: ConfigKind.keyMapping,
      id: id,
      value: {
        'opcua_node': {'namespace': 4, 'identifier': identifier},
      },
    ).stored(rev: rev, updatedAt: DateTime.utc(2026, 9, 1), updatedBy: 'x');

/// The editor's copy: no revision, as `keyMappingItems` emits it.
ConfigItem edited(String id, String identifier) => ConfigItem.of(
      kind: ConfigKind.keyMapping,
      id: id,
      value: {
        'opcua_node': {'namespace': 4, 'identifier': identifier},
      },
    );

Map<String, String> byId(List<ConfigItem> items) => {
      for (final item in items) item.id: item.decode()['opcua_node']['identifier'],
    };

void main() {
  test('no baseline is today\'s behaviour: the wanted list, untouched', () {
    final wanted = [edited('a', 'A')];
    expect(
        mergeItemsForSave(
            wanted: wanted, stored: [key('a', 'A'), key('b', 'B')], baseline: null),
        same(wanted));
  });

  group('added elsewhere since the editor loaded', () {
    test('is kept, as stored', () {
      final merged = mergeItemsForSave(
        wanted: [edited('a', 'A')],
        stored: [key('a', 'A'), key('b', 'B', rev: 1)],
        baseline: [key('a', 'A')],
      );
      expect(byId(merged), {'a': 'A', 'b': 'B'});
      expect(merged.singleWhere((i) => i.id == 'b').rev, 1,
          reason: 'kept as stored, revision included: the CAS needs it');
    });

    test('with the same id and content on both sides is nothing to write', () {
      final merged = mergeItemsForSave(
        wanted: [edited('a', 'A'), edited('b', 'B')],
        stored: [key('a', 'A'), key('b', 'B')],
        baseline: [key('a', 'A')],
      );
      expect(byId(merged), {'a': 'A', 'b': 'B'});
    });

    test('with the same id and different content is a conflict', () {
      expect(
          () => mergeItemsForSave(
                wanted: [edited('a', 'A'), edited('b', 'MINE')],
                stored: [key('a', 'A'), key('b', 'THEIRS')],
                baseline: [key('a', 'A')],
              ),
          throwsA(isA<ConfigConflict>().having((e) => e.key, 'key', 'b')));
    });
  });

  group('changed elsewhere since the editor loaded', () {
    test('and untouched here: theirs wins', () {
      final merged = mergeItemsForSave(
        wanted: [edited('a', 'A'), edited('b', 'B')],
        stored: [key('a', 'A'), key('b', 'THEIRS', rev: 2)],
        baseline: [key('a', 'A'), key('b', 'B', rev: 1)],
      );
      expect(byId(merged), {'a': 'A', 'b': 'THEIRS'});
      expect(merged.singleWhere((i) => i.id == 'b').rev, 2);
    });

    test('and changed here too: a conflict naming the key and the loaded rev',
        () {
      expect(
          () => mergeItemsForSave(
                wanted: [edited('a', 'A'), edited('b', 'MINE')],
                stored: [key('a', 'A'), key('b', 'THEIRS', rev: 2)],
                baseline: [key('a', 'A'), key('b', 'B', rev: 1)],
              ),
          throwsA(isA<ConfigConflict>()
              .having((e) => e.key, 'key', 'b')
              .having((e) => e.expectedRev, 'expectedRev', 1)));
    });

    test('and deleted here: a conflict', () {
      expect(
          () => mergeItemsForSave(
                wanted: [edited('a', 'A')],
                stored: [key('a', 'A'), key('b', 'THEIRS', rev: 2)],
                baseline: [key('a', 'A'), key('b', 'B', rev: 1)],
              ),
          throwsA(isA<ConfigConflict>().having((e) => e.key, 'key', 'b')));
    });
  });

  group('deleted elsewhere since the editor loaded', () {
    test('and untouched here: their delete stands', () {
      final merged = mergeItemsForSave(
        wanted: [edited('a', 'A'), edited('b', 'B')],
        stored: [key('a', 'A')],
        baseline: [key('a', 'A'), key('b', 'B')],
      );
      expect(byId(merged), {'a': 'A'});
    });

    test('and edited here: a conflict', () {
      expect(
          () => mergeItemsForSave(
                wanted: [edited('a', 'A'), edited('b', 'MINE')],
                stored: [key('a', 'A')],
                baseline: [key('a', 'A'), key('b', 'B')],
              ),
          throwsA(isA<ConfigConflict>().having((e) => e.key, 'key', 'b')));
    });

    test('and deleted here too: nothing to say', () {
      final merged = mergeItemsForSave(
        wanted: [edited('a', 'A')],
        stored: [key('a', 'A')],
        baseline: [key('a', 'A'), key('b', 'B')],
      );
      expect(byId(merged), {'a': 'A'});
    });
  });

  test('unmoved elsewhere: the editor decides, edits and deletes alike', () {
    final merged = mergeItemsForSave(
      wanted: [edited('a', 'MINE'), edited('c', 'NEW')],
      stored: [key('a', 'A'), key('b', 'B')],
      baseline: [key('a', 'A'), key('b', 'B')],
    );
    expect(byId(merged), {'a': 'MINE', 'c': 'NEW'});
  });

  test('the ordinary save — nothing moved anywhere — is the wanted list', () {
    final stored = [key('a', 'A'), key('b', 'B')];
    final merged = mergeItemsForSave(
      wanted: [edited('a', 'A'), edited('b', 'B2')],
      stored: stored,
      baseline: stored,
    );
    expect(byId(merged), {'a': 'A', 'b': 'B2'});
  });
}

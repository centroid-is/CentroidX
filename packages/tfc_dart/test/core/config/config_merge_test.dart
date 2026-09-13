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
          reason: 'kept as stored, revision included — it is the stored row '
              'itself, not a copy the editor built');
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

  group('refreshedBaseline: the editor\'s view after a save', () {
    test('an item the editor\'s content landed on takes the stored row, '
        'revision included', () {
      final storedNow = [key('a', 'MINE', rev: 2)];
      final baseline = refreshedBaseline(
        oldBaseline: [key('a', 'A', rev: 1)],
        editorWanted: [edited('a', 'MINE')],
        storedNow: storedNow,
      );
      expect(baseline, hasLength(1));
      expect(identical(baseline.single, storedNow.single), isTrue,
          reason: 'the stored row itself: the next save\'s compare-and-swap '
              'reads the revision off it');
    });

    test('an item the merge adopted from elsewhere keeps the old baseline '
        'entry, so the next save adopts theirs again rather than writing '
        'the editor\'s stale content over it', () {
      // The editor still shows `A`; the plant holds `THEIRS` at rev 2 and
      // the merge kept it. A baseline that took the stored row here would
      // have the next save see "unmoved elsewhere, the editor decides" and
      // write `A` over `THEIRS`.
      final baseline = refreshedBaseline(
        oldBaseline: [key('a', 'A', rev: 1)],
        editorWanted: [edited('a', 'A')],
        storedNow: [key('a', 'THEIRS', rev: 2)],
      );
      expect(byId(baseline), {'a': 'A'});
      expect(baseline.single.rev, 1);

      final next = mergeItemsForSave(
        wanted: [edited('a', 'A'), edited('c', 'NEW')],
        stored: [key('a', 'THEIRS', rev: 2)],
        baseline: baseline,
      );
      expect(byId(next), {'a': 'THEIRS', 'c': 'NEW'});
    });

    test('a row the merge kept from another station is *not* in the '
        'baseline: naming it would have the next save delete it', () {
      // `b` was added elsewhere while the editor was open; the merge kept it
      // and the editor does not show it. The first version of this refresh
      // took every stored row, and the second save deleted `b` as "in the
      // baseline, not on screen".
      final baseline = refreshedBaseline(
        oldBaseline: [key('a', 'A')],
        editorWanted: [edited('a', 'A2')],
        storedNow: [key('a', 'A2', rev: 2), key('b', 'B', rev: 1)],
      );
      expect(byId(baseline), {'a': 'A2'});

      final next = mergeItemsForSave(
        wanted: [edited('a', 'A3')],
        stored: [key('a', 'A2', rev: 2), key('b', 'B', rev: 1)],
        baseline: baseline,
      );
      expect(byId(next), {'a': 'A3', 'b': 'B'},
          reason: 'the second save keeps what the first one kept');
    });

    test('an item the editor holds that the store no longer does is left '
        'off', () {
      final baseline = refreshedBaseline(
        oldBaseline: [key('a', 'A'), key('b', 'B')],
        editorWanted: [edited('a', 'A'), edited('b', 'B')],
        storedNow: [key('a', 'A', rev: 1)],
      );
      expect(byId(baseline), {'a': 'A'});
    });

    test('with no old baseline, only what landed is in the new one', () {
      final baseline = refreshedBaseline(
        oldBaseline: null,
        editorWanted: [edited('a', 'A'), edited('b', 'B')],
        storedNow: [key('a', 'A'), key('b', 'THEIRS', rev: 2)],
      );
      expect(byId(baseline), {'a': 'A'});
    });
  });

  group('a revision moved with the content unchanged', () {
    test('is not a move: the editor decides, no conflict', () {
      // Station B edited `a` and then undid it: two revisions on, the
      // content the editor loaded. A conflict here would offer the
      // operator only Reload, over a change that no longer exists.
      final merged = mergeItemsForSave(
        wanted: [edited('a', 'MINE')],
        stored: [key('a', 'A', rev: 3)],
        baseline: [key('a', 'A', rev: 1)],
      );
      expect(byId(merged), {'a': 'MINE'});
    });

    test('and a delete here over it stands, for the same reason', () {
      final merged = mergeItemsForSave(
        wanted: const [],
        stored: [key('a', 'A', rev: 3)],
        baseline: [key('a', 'A', rev: 1)],
      );
      expect(merged, isEmpty);
    });

    test('a revision moved *with* the content is still a move', () {
      expect(
        () => mergeItemsForSave(
          wanted: [edited('a', 'MINE')],
          stored: [key('a', 'THEIRS', rev: 3)],
          baseline: [key('a', 'A', rev: 1)],
        ),
        throwsA(isA<ConfigConflict>()),
      );
    });
  });
}

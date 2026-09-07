/// Gapped ordering keys: the one genuinely new mechanism of this phase.
///
/// The property every test here is circling is **minimal diff**. The store
/// diffs `wanted` against its snapshot, and `sortIndex` is content
/// (`ConfigItem.sameContentAs` compares it), so a key that moves is a row that
/// is written and a change row that is logged. Dense ordinals would therefore
/// make dragging one asset to the front of a page 20 rows and 20 history
/// entries for one gesture — the "290 kB of noise" problem at page scale.
/// Every assertion below is either "exactly one key changed" or "these keys
/// are byte-identical".
library;

import 'package:test/test.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_store.dart';
import 'package:tfc_dart/core/config/sort_keys.dart';

/// An asset item at [ordinal] — the rank a codec emits, 0..n-1, which is what
/// [assignSortKeys] reads and never what it writes.
ConfigItem asset(String id, {String parent = '/roe', int? ordinal}) =>
    ConfigItem.of(
      kind: ConfigKind.asset,
      id: id,
      value: {'id': id},
      parentId: parent,
      sortIndex: ordinal,
    );

Map<String, int> storedKeys(Map<String, int> byId) => {
      for (final entry in byId.entries)
        configSnapshotKey(ConfigKind.asset, entry.key): entry.value,
    };

/// `id → key` of the result, for the kinds that carry one.
Map<String, int?> keysOf(List<ConfigItem> items) =>
    {for (final item in items) item.id: item.sortIndex};

void main() {
  group('the identity case is free', () {
    test('the same order back keeps every stored key exactly', () {
      final stored = storedKeys({'a': 1024, 'b': 2048, 'c': 3072});
      final result = assignSortKeys([
        asset('a', ordinal: 0),
        asset('b', ordinal: 1),
        asset('c', ordinal: 2),
      ], stored);

      expect(keysOf(result), {'a': 1024, 'b': 2048, 'c': 3072},
          reason: 'nothing moved, so nothing may reach the change log');
    });

    test('keys nobody chose are kept too — a rebalanced page stays put', () {
      // Keys are not always multiples of the gap: a midpoint insert leaves
      // 1536, and the next save must not tidy it into 2048.
      final stored = storedKeys({'a': 1024, 'b': 1536, 'c': 3072});
      final result = assignSortKeys([
        asset('a', ordinal: 0),
        asset('b', ordinal: 1),
        asset('c', ordinal: 2),
      ], stored);

      expect(keysOf(result), {'a': 1024, 'b': 1536, 'c': 3072});
    });
  });

  group('appending', () {
    test('one new item at the end is one new key at max + the gap', () {
      final stored = storedKeys({'a': 1024, 'b': 2048});
      final result = assignSortKeys([
        asset('a', ordinal: 0),
        asset('b', ordinal: 1),
        asset('new', ordinal: 2),
      ], stored);

      expect(keysOf(result), {'a': 1024, 'b': 2048, 'new': 2048 + kSortKeyGap});
    });

    test('the first key on an empty parent is the gap itself', () {
      final result = assignSortKeys([asset('only', ordinal: 0)], const {});
      expect(keysOf(result), {'only': kSortKeyGap});
      expect(result.single.sortIndex, greaterThan(0),
          reason: 'keys are always positive — sort_index is int4 and a '
              'negative one has nowhere to go when it is exhausted');
    });
  });

  group('a reorder moves one key, not the page', () {
    List<ConfigItem> twenty(List<String> order) => [
          for (var i = 0; i < order.length; i++) asset(order[i], ordinal: i),
        ];

    final ids = [for (var i = 0; i < 20; i++) 'a$i'];
    final stored = storedKeys({
      for (var i = 0; i < 20; i++) 'a$i': (i + 1) * kSortKeyGap,
    });

    test('bring-to-front changes exactly one key', () {
      final result = assignSortKeys(twenty([ids.last, ...ids.take(19)]), stored);
      final keys = keysOf(result);

      final moved = [
        for (final entry in keys.entries)
          if (entry.value !=
              stored[configSnapshotKey(ConfigKind.asset, entry.key)])
            entry.key,
      ];
      expect(moved, ['a19'],
          reason: 'the 19 siblings that did not move must not be written');
      expect(keys['a19'], lessThan(keys['a0']!));
      expect(keys['a19'], greaterThan(0));
    });

    test('send-to-back changes exactly one key', () {
      final result =
          assignSortKeys(twenty([...ids.skip(1), ids.first]), stored);
      final keys = keysOf(result);

      final moved = [
        for (final entry in keys.entries)
          if (entry.value !=
              stored[configSnapshotKey(ConfigKind.asset, entry.key)])
            entry.key,
      ];
      expect(moved, ['a0']);
      expect(keys['a0'], greaterThan(keys['a19']!));
    });

    test('a move to the front with no room below rebalances rather than '
        'going negative', () {
      // The one case where "keep the neighbours' keys" is impossible: the
      // front key is already 1 and something has to go before it.
      final stored = storedKeys({'a': 1, 'b': 2048});
      final result = assignSortKeys([
        asset('b', ordinal: 0),
        asset('a', ordinal: 1),
      ], stored);

      expect(keysOf(result), {'b': kSortKeyGap, 'a': 2 * kSortKeyGap});
      for (final item in result) {
        expect(item.sortIndex, greaterThan(0));
      }
    });
  });

  group('inserting between neighbours', () {
    test('a midpoint insert lands strictly between and moves nothing else',
        () {
      final stored = storedKeys({'a': 1024, 'b': 2048});
      final result = assignSortKeys([
        asset('a', ordinal: 0),
        asset('mid', ordinal: 1),
        asset('b', ordinal: 2),
      ], stored);
      final keys = keysOf(result);

      expect(keys['a'], 1024);
      expect(keys['b'], 2048);
      expect(keys['mid'], greaterThan(1024));
      expect(keys['mid'], lessThan(2048));
    });

    test('an exhausted gap renumbers that parent to multiples of the gap', () {
      // b - a < 2: there is no integer between them, and `sort_index` is
      // int4, so there is no fractional escape hatch either. The group
      // renumbers within this same call — the rebalance is never deferred to
      // a later save, because the save in hand is the one that has nowhere to
      // put the row.
      final stored = storedKeys({'a': 1024, 'b': 1025, 'c': 4096});
      final result = assignSortKeys([
        asset('a', ordinal: 0),
        asset('mid', ordinal: 1),
        asset('b', ordinal: 2),
        asset('c', ordinal: 3),
      ], stored);

      expect(keysOf(result), {
        'a': kSortKeyGap,
        'mid': 2 * kSortKeyGap,
        'b': 3 * kSortKeyGap,
        'c': 4 * kSortKeyGap,
      });
    });
  });

  group('what it must not touch', () {
    test('items with a null sortIndex pass through byte-identical', () {
      final mapping = ConfigItem.of(
        kind: ConfigKind.keyMapping,
        id: 'CN04.Belt.Speed',
        value: {'opcua_node': null},
      );
      final page = ConfigItem.of(
        kind: ConfigKind.page,
        id: '/roe',
        value: {'menu_item': null},
      );

      final result = assignSortKeys([mapping, page], const {});

      expect(result, [mapping, page]);
      expect(result.every((i) => i.sortIndex == null), isTrue);
    });

    test('the payload is never rebuilt', () {
      // C-6. This function reorders; a payload it re-encoded would diff as an
      // edit on every save.
      final item = asset('a', ordinal: 0);
      final result = assignSortKeys([item], const {});
      expect(identical(result.single.payload, item.payload), isTrue);
      expect(result.single.rev, item.rev);
      expect(result.single.parentId, item.parentId);
    });

    test('parents never interfere', () {
      final stored = {
        ...storedKeys({'a': 1024, 'b': 2048}),
        ...storedKeys({'x': 5, 'y': 9}),
      };
      final result = assignSortKeys([
        asset('a', ordinal: 0),
        asset('b', ordinal: 1),
        asset('y', parent: '/eviscerator', ordinal: 0),
        asset('x', parent: '/eviscerator', ordinal: 1),
      ], stored);
      final keys = keysOf(result);

      expect(keys['a'], 1024, reason: '/roe did not move at all');
      expect(keys['b'], 2048);
      // The other parent's swap is resolved inside its own group, against its
      // own keys, and cannot reach for /roe's numbers.
      expect(keys['y'], lessThan(keys['x']!));
      expect(keys['y'], greaterThan(0));
    });

    test('the caller\'s list order is preserved', () {
      final result = assignSortKeys([
        asset('c', ordinal: 2),
        asset('a', ordinal: 0),
        asset('b', ordinal: 1),
      ], const {});
      expect(result.map((i) => i.id), ['c', 'a', 'b'],
          reason: 'this function assigns keys; it does not sort the list');
      expect(keysOf(result),
          {'c': 3 * kSortKeyGap, 'a': kSortKeyGap, 'b': 2 * kSortKeyGap});
    });
  });

  group('the migration degenerate case', () {
    test('no stored keys yields (ordinal + 1) * the gap', () {
      // 03-03 calls exactly this, with `{}`, so the migration has one
      // definition of what the first keys are rather than a second copy of
      // the arithmetic.
      final result = assignSortKeys([
        asset('a', ordinal: 0),
        asset('b', ordinal: 1),
        asset('c', ordinal: 2),
      ], const {});

      expect(keysOf(result),
          {'a': kSortKeyGap, 'b': 2 * kSortKeyGap, 'c': 3 * kSortKeyGap});
    });

    test('ordinals are rank only — 0..n-1 is not assumed', () {
      // A codec that emitted 10, 20, 30 means the same thing as 0, 1, 2.
      final result = assignSortKeys([
        asset('a', ordinal: 10),
        asset('b', ordinal: 20),
      ], const {});
      expect(keysOf(result), {'a': kSortKeyGap, 'b': 2 * kSortKeyGap});
    });
  });
}

/// The two derived strings, pinned against the ones the direct path uses.
///
/// `configWriteKeyByKindSet` lives in `tfc_relay_protocol` because the policy
/// decorator derives a write's grading key from the caller's kind set and
/// `tfc_relay_server` cannot import `tfc_dart`. `kConfigWriteKeys` lives in
/// `tfc_dart` because that is where the guarded store checks a direct save.
/// Neither package can import the other, so there is exactly one place the
/// two can be compared — here — and if they ever disagree, a relayed page
/// save and a direct one are graded under different rules.
library;

import 'package:test/test.dart';
import 'package:tfc_dart/core/access/guarded_config_store.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

void main() {
  group('the relay grades a write under the key the station checks it under',
      () {
    test('a page save: {page, asset} is page_editor_data on both sides', () {
      expect(configWriteKeyFor({'page', 'asset'}),
          kConfigWriteKeys[ConfigKind.page]);
      expect(configWriteKeyFor({'page', 'asset'}),
          kConfigWriteKeys[ConfigKind.asset],
          reason: 'an asset is not separately permissioned from the page it '
              'sits on — the direct path says so by giving both kinds one '
              'key, and the relay has to say the same thing');
    });

    test('a key-mapping save: {key_mapping} is key_mappings on both sides',
        () {
      expect(configWriteKeyFor({'key_mapping'}),
          kConfigWriteKeys[ConfigKind.keyMapping]);
    });

    test('the order a caller names the kinds in cannot change the answer', () {
      expect(configWriteKeyFor({'asset', 'page'}),
          configWriteKeyFor({'page', 'asset'}));
    });
  });

  group('what the relay refuses to write through this door', () {
    test('a preference is not a set this member writes', () {
      expect(configWriteKeyFor({'preference'}), isNull,
          reason: 'preferences are graded per KEY. A kind-generic member '
              'would have to grade a preference replace-set at the strictest '
              'key in the plant and lock a configure user out of saving '
              'alarm_man_config');
    });

    test('a preference smuggled in beside a page borrows nothing', () {
      expect(configWriteKeyFor({'page', 'asset', 'preference'}), isNull,
          reason: 'the set is matched whole, so a set that merely CONTAINS '
              'page cannot take the page editor grading for what rides along');
    });

    test('a page without its assets is not the page save', () {
      expect(configWriteKeyFor({'page'}), isNull,
          reason: 'a partial set would replace pages while leaving the assets '
              'of a deleted page orphaned — the direct path never does that, '
              'and there is no key that describes doing it');
    });

    test('an empty set names nothing and is refused', () {
      expect(configWriteKeyFor(const <String>{}), isNull);
    });

    test('a kind this build does not know is refused', () {
      expect(configWriteKeyFor({'page_image'}), isNull,
          reason: 'page images are history-exempt and reach the plant by '
              'another path; a set naming one here would be graded as a page '
              'save without being one');
    });
  });

  test('every kind this door writes is a kind the wire knows', () {
    for (final set in configWriteKeyByKindSet.keys) {
      for (final kind in set.split(',')) {
        expect(configItemKinds, contains(kind),
            reason: '"$kind" is writable but not readable, which is a write '
                'path with no matching read');
      }
    }
  });
}

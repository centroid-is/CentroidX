import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc_dart/core/preferences.dart';

import 'package:tfc/core/pending_proposals_store.dart';

/// A store whose every call fails, standing in for a preferences plugin that
/// is missing or a file that cannot be written.
class _BrokenPreferences extends InMemoryPreferences {
  @override
  Future<String?> getString(String key) async =>
      throw StateError('no preferences here');

  @override
  Future<void> setString(String key, String value) async =>
      throw StateError('no preferences here');

  @override
  Future<void> remove(String key) async =>
      throw StateError('no preferences here');
}

void main() {
  final now = DateTime(2026, 9, 12, 12, 0);

  PersistedProposal proposal({
    String type = 'alarm',
    String title = 'High temp',
    String json = '{"_proposal_type":"alarm","title":"High temp"}',
    String operator = 'local',
    DateTime? createdAt,
    bool viewed = false,
  }) =>
      PersistedProposal(
        proposalType: type,
        title: title,
        proposalJson: json,
        operatorId: operator,
        createdAt: createdAt ?? now,
        viewed: viewed,
      );

  group('encode / decode', () {
    test('round-trips every field the operator sees, oldest first', () {
      final older = proposal(
        title: 'Older',
        json: '{"_proposal_type":"alarm","title":"Older"}',
        createdAt: now.subtract(const Duration(hours: 2)),
        viewed: true,
      );
      final newer = proposal(
        type: 'page',
        title: 'Newer',
        json: '{"_proposal_type":"page","title":"Newer"}',
        operator: 'agent-7',
      );

      final decoded =
          decodePendingProposals(encodePendingProposals([older, newer]), now: now);

      expect(decoded, hasLength(2));
      expect(decoded[0].title, 'Older');
      expect(decoded[0].viewed, isTrue);
      expect(decoded[0].createdAt, older.createdAt);
      expect(decoded[1].proposalType, 'page');
      expect(decoded[1].operatorId, 'agent-7');
      expect(decoded[1].proposalJson, newer.proposalJson);
      expect(decoded[1].viewed, isFalse);
    });

    test('the raw proposal JSON is preserved byte for byte', () {
      // addProposal deduplicates on the exact text, so a restored proposal
      // must carry the same bytes the live one did -- not a re-encoding.
      const raw = '{"_proposal_type":"alarm", "title":"Spaced",  "n":1.50}';
      final decoded = decodePendingProposals(
          encodePendingProposals([proposal(json: raw)]),
          now: now);
      expect(decoded.single.proposalJson, raw);
    });

    test('null, empty, garbage and non-object blobs decode to nothing', () {
      expect(decodePendingProposals(null, now: now), isEmpty);
      expect(decodePendingProposals('', now: now), isEmpty);
      expect(decodePendingProposals('{not json', now: now), isEmpty);
      expect(decodePendingProposals('[1,2,3]', now: now), isEmpty);
      expect(decodePendingProposals('"a string"', now: now), isEmpty);
      expect(decodePendingProposals('{"v":1,"proposals":"nope"}', now: now),
          isEmpty);
    });

    test('a blob from another format version is ignored, not guessed at', () {
      final blob = jsonEncode({
        'v': pendingProposalsFormatVersion + 1,
        'proposals': [proposal().toJson()],
      });
      expect(decodePendingProposals(blob, now: now), isEmpty);
    });

    test('one malformed entry is skipped and the rest survive', () {
      final blob = jsonEncode({
        'v': pendingProposalsFormatVersion,
        'proposals': [
          proposal(title: 'Good one').toJson(),
          {'title': 'no type or json'},
          42,
          proposal(title: 'Good two',
                  json: '{"_proposal_type":"alarm","title":"Good two"}')
              .toJson(),
        ],
      });
      final decoded = decodePendingProposals(blob, now: now);
      expect(decoded.map((p) => p.title), ['Good one', 'Good two']);
    });

    test('an entry with no createdAt counts as fresh', () {
      final entry = proposal().toJson()..remove('createdAt');
      final blob = jsonEncode({
        'v': pendingProposalsFormatVersion,
        'proposals': [entry],
      });
      final decoded = decodePendingProposals(blob, now: now);
      expect(decoded, hasLength(1));
      expect(decoded.single.createdAt, now);
    });
  });

  group('expiry and bounds', () {
    test('entries older than the maximum age are dropped on load', () {
      final stale = proposal(
        title: 'Stale',
        json: '{"_proposal_type":"alarm","title":"Stale"}',
        createdAt: now.subtract(pendingProposalMaxAge + const Duration(minutes: 1)),
      );
      final fresh = proposal(
        title: 'Fresh',
        json: '{"_proposal_type":"alarm","title":"Fresh"}',
        createdAt: now.subtract(pendingProposalMaxAge - const Duration(minutes: 1)),
      );
      final decoded = decodePendingProposals(
          encodePendingProposals([stale, fresh]),
          now: now);
      expect(decoded.map((p) => p.title), ['Fresh']);
    });

    test('decode defaults to the ambient clock', () {
      final blob = encodePendingProposals([proposal(createdAt: now)]);
      withClock(Clock.fixed(now.add(const Duration(hours: 1))), () {
        expect(decodePendingProposals(blob), hasLength(1));
      });
      withClock(Clock.fixed(now.add(const Duration(days: 2))), () {
        expect(decodePendingProposals(blob), isEmpty);
      });
    });

    test('only the newest entries are kept past the count limit', () {
      final many = [
        for (var i = 0; i < pendingProposalLimit + 10; i++)
          proposal(
            title: 'p$i',
            json: '{"_proposal_type":"alarm","title":"p$i"}',
            createdAt: now.subtract(Duration(minutes: pendingProposalLimit + 10 - i)),
          ),
      ];
      final decoded =
          decodePendingProposals(encodePendingProposals(many), now: now);
      expect(decoded, hasLength(pendingProposalLimit));
      // The oldest ten went; the newest survive in order.
      expect(decoded.first.title, 'p10');
      expect(decoded.last.title, 'p${pendingProposalLimit + 9}');
    });

    test('the encoded blob is trimmed from the oldest end to fit the byte cap',
        () {
      // Three proposals each big enough that only one fits.
      final filler = 'x' * (pendingProposalMaxBytes ~/ 2);
      final big = [
        for (var i = 0; i < 3; i++)
          proposal(
            title: 'big$i',
            json: '{"_proposal_type":"page","title":"big$i","blob":"$filler"}',
          ),
      ];
      final encoded = encodePendingProposals(big);
      expect(encoded.length, lessThanOrEqualTo(pendingProposalMaxBytes));
      final decoded = decodePendingProposals(encoded, now: now);
      expect(decoded.map((p) => p.title), ['big2']);
    });
  });

  group('PendingProposalStore', () {
    test('saves and loads through the preferences store', () async {
      final prefs = InMemoryPreferences();
      final store = PendingProposalStore(prefs);

      await store.save([proposal(title: 'Kept')]);
      expect(await prefs.getString(pendingProposalsPrefsKey), isNotNull);

      final loaded = await store.load();
      expect(loaded.single.title, 'Kept');
    });

    test('saving nothing clears the key', () async {
      final prefs = InMemoryPreferences();
      final store = PendingProposalStore(prefs);
      await store.save([proposal()]);
      await store.save(const []);
      expect(await prefs.containsKey(pendingProposalsPrefsKey), isFalse);
    });

    test('a corrupt blob loads as nothing pending', () async {
      final prefs = InMemoryPreferences();
      await prefs.setString(pendingProposalsPrefsKey, '{"v":1,"proposals":[');
      expect(await PendingProposalStore(prefs).load(), isEmpty);
    });

    test('a store that cannot be read or written never throws', () async {
      final store = PendingProposalStore(_BrokenPreferences());
      expect(await store.load(), isEmpty);
      await store.save([proposal()]);
      await store.save(const []);
    });
  });
}

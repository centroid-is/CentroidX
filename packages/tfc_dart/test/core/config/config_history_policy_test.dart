/// The no-history rule, and the transport it would break without the nudge.
///
/// Two things are asserted here that no behavioural test can assert: that the
/// exempt set is *exactly* two entries — widening it is a decision, not a
/// detail — and that **every** writer of a `config_change` row in `lib/`
/// consults the rule. The second is a source scan rather than a behaviour,
/// deliberately: there are three places in this package that insert into
/// `config_change`, and a fourth added later that did not know about the
/// exemption would put PBKDF2+AES-256-GCM ciphertext into a table that is
/// never pruned. That is a leak nothing can take back, so the guard has to be
/// structural rather than remembered.
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_dart/core/config/config_history_policy.dart';
import 'package:tfc_dart/core/config/config_item.dart';

/// Ids to ask the rule about: an ordinary one, the exempt preference id, a
/// content-addressed image id, and the empty string.
const List<String> _probeIds = [
  'CN04.MOT01.HMI',
  'server_config_envelope',
  'sha256-0a1b2c3d',
  '',
];

/// Every `(kind, id)` in the probe grid the rule says is exempt, as
/// `wire_name/id` strings.
Set<String> _exemptGrid() => {
      for (final kind in ConfigKind.values)
        for (final id in _probeIds)
          if (historyExempt(kind, id)) '${kind.wireName}/$id',
    };

/// Every `.dart` file under `lib/` — the scan's corpus.
List<File> _libSources() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .toList();

void main() {
  group('the exempt set', () {
    test('is exactly page images and the server-config envelope', () {
      expect(
        _exemptGrid(),
        {
          'page_image/CN04.MOT01.HMI',
          'page_image/server_config_envelope',
          'page_image/sha256-0a1b2c3d',
          'page_image/',
          'preference/server_config_envelope',
        },
        reason: 'Widening this is a decision, not a detail: an exempt entity '
            'has no history at all, so exempting a kind somebody later needs '
            'to audit silently removes the answer to "who changed this". The '
            'two entries here are argued in config_history_policy.dart; a '
            'third needs the same argument written down.',
      );
    });

    test('the kinds that carry history are exempt for no id at all', () {
      for (final kind in [
        ConfigKind.page,
        ConfigKind.asset,
        ConfigKind.keyMapping,
      ]) {
        for (final id in _probeIds) {
          expect(historyExempt(kind, id), isFalse,
              reason: '${kind.wireName} is what the history view and undo are '
                  'for; exempting one would make its rows unrecoverable.');
        }
      }
    });

    test('a preference other than the envelope keeps its history', () {
      expect(historyExempt(ConfigKind.preference, 'startup_page'), isFalse);
      expect(historyExempt(ConfigKind.preference, 'server_config_envelope'),
          isTrue);
    });

    test('both halves of the rule are named, so a reader can find them', () {
      expect(kHistoryExemptKinds, {ConfigKind.pageImage});
      expect(kHistoryExemptPreferenceIds, {'server_config_envelope'});
      expect(kHistoryExemptPreferenceIdPrefixes, {'chat.'});
    });

    test('a chat conversation is exempt by prefix; nothing else is', () {
      // The whole transcript is rewritten on every message. Logging both
      // sides per turn is O(N²) bytes in a table nothing prunes.
      expect(historyExempt(ConfigKind.preference, 'chat.history'), isTrue);
      expect(historyExempt(ConfigKind.preference, 'chat.conversation.7f3a'),
          isTrue);
      expect(historyExempt(ConfigKind.preference, 'chat'), isFalse,
          reason: 'the prefix is `chat.`; a key merely starting with the '
              'letters is not the assistant\'s');
      expect(historyExempt(ConfigKind.preference, 'llm.selected_provider'),
          isFalse, reason: 'a provider setting is configuration, and audited');
      expect(historyExempt(ConfigKind.keyMapping, 'chat.history'), isFalse,
          reason: 'the prefix rule is for preferences only');
    });

    test('a page image is exempt by its kind and by nothing else', () {
      // There was a third half between 04-05 and 04-09: a
      // `page_editor_image:` **id prefix** within `preference`, because a
      // shared preference had become a `config_item` row with a
      // `config_change` row beside it while `image_store.dart` was still
      // writing images as preferences. One screenshot would have cost ~13 MB
      // of history that is never pruned — C-3 reached by a different door.
      //
      // 04-09 put the images on their own kind, which is exempt outright, so
      // the prefix arm came out with the writes it was covering. A key that
      // still looks like one is now an ordinary preference: nothing writes
      // it, and if something did, its history would be a defect worth seeing
      // rather than a silent 13 MB.
      expect(historyExempt(ConfigKind.pageImage, 'anything at all'), isTrue);
      expect(
          historyExempt(ConfigKind.preference,
              'page_editor_image:9f86d081884c7d659a2feaa0c55ad015'),
          isFalse);
      expect(historyExempt(ConfigKind.preference, 'page_editor_data'), isFalse);
    });
  });

  group('no ciphertext can reach config_change', () {
    test('every writer of a change row in lib/ consults historyExempt', () {
      final writers = <String>[];
      final unguarded = <String>[];
      for (final file in _libSources()) {
        // Generated code defines the companion; it never writes one.
        if (file.path.endsWith('.g.dart')) continue;
        final source = file.readAsStringSync();
        // The companion is what a writer has to construct, and matching it
        // survives reformatting in a way that matching the `insert(` call
        // chain does not.
        if (!source.contains('ConfigChangeTableCompanion.insert')) continue;
        writers.add(file.path);
        if (!source.contains('historyExempt')) unguarded.add(file.path);
      }

      expect(unguarded, isEmpty,
          reason: 'A file that inserts into config_change without consulting '
              'the exemption is the leak this rule exists to prevent: '
              'config_change is never pruned, so a superseded ciphertext '
              'written there stays forever. Route the insert through a helper '
              'that asks historyExempt.');
      expect(writers, hasLength(4),
          reason: 'The scan is only as good as its corpus. Four writers are '
              'known: the store, the local preference store, the blob '
              'migration and — since 04-11 — the preference migration, whose '
              '_insertChange asks the rule for exactly the reason the others '
              'do (it copies the page images and the server_config_envelope, '
              'the two exempt things, out of the old table). A fifth is fine '
              '— add it here once you have checked it asks the rule — and a '
              'count that dropped means the scan stopped matching anything '
              'and would pass vacuously.');
    });
  });

  group('the reconcile nudge payload', () {
    test('round-trips the kinds it names', () {
      final payload = encodeReconcileNudge(
          {ConfigKind.pageImage, ConfigKind.preference});
      expect(decodeReconcileNudge(payload),
          {ConfigKind.pageImage, ConfigKind.preference});
    });

    test('the trigger\'s own empty payload is not a nudge', () {
      expect(decodeReconcileNudge(''), isNull,
          reason: 'The AFTER INSERT trigger notifies with an empty payload, '
              'and that must keep meaning "consume the change log" — not '
              '"reconcile nothing".');
    });

    test('a wire name this build does not know is skipped, not fatal', () {
      expect(decodeReconcileNudge('reconcile:page_image,pipe_dream'),
          {ConfigKind.pageImage},
          reason: 'A newer station may name a kind an older one has never '
              'heard of; the older one must still act on the rest.');
      expect(decodeReconcileNudge('reconcile:pipe_dream'), isEmpty);
    });

    test('the widest possible payload is nowhere near pg_notify\'s cap', () {
      final widest = encodeReconcileNudge(ConfigKind.values);
      expect(widest.length, lessThan(200),
          reason: 'pg_notify caps a payload at 8000 bytes and enforces it by '
              'erroring the statement that fired it — which for us would mean '
              'a failed save. Naming kinds and never entities is what makes '
              'the cap unreachable by construction rather than by luck.');
    });
  });
}

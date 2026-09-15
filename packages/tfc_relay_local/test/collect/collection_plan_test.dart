/// Keymappings in, entries and rejections out — the pure function that
/// decides *what* the gateway would collect before any database exists.
///
/// Two properties carry this file:
///
///  * **Per key, never per file.** One bad collect block in 430 must cost
///    exactly that key — 08-PATTERNS §2's `updateKeyMappings` discipline,
///    applied to the historian's config the way `KeyRouter` already applies
///    it to routing.
///  * **The table name is computed once, validated once.** It reaches SQL by
///    interpolation with the identifier unescaped (`database_drift.dart:687`,
///    `:907`), so plan time is the only place it can be stopped.
///
/// No hardware, no database, no clock: allocation and arithmetic.
@TestOn('vm')
library;

import 'package:tfc_dart/core/boolean_expression.dart'
    show Expression, ExpressionConfig;
import 'package:tfc_dart/core/collector.dart' show CollectEntry;
import 'package:tfc_dart/core/state_man.dart'
    show KeyMappingEntry, KeyMappings;
import 'package:tfc_dart/tfc_dart.dart' show RetentionPolicy;
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:test/test.dart';

import '../support/keymap_fixtures.dart';

/// An entry whose collect block names [name] (null means "same as key").
KeyMappingEntry collected(String key,
        {String? name,
        Duration? interval,
        List<String>? members,
        ExpressionConfig? expression,
        RetentionPolicy? retention}) =>
    KeyMappingEntry(
      opcuaNode: opcUaEntry(identifier: key).opcuaNode,
      collect: retention == null
          ? CollectEntry(
              key: key,
              name: name,
              sampleInterval: interval,
              sampleMembers: members,
              sampleExpression: expression,
            )
          : CollectEntry(
              key: key,
              name: name,
              sampleInterval: interval,
              sampleMembers: members,
              sampleExpression: expression,
              retention: retention,
            ),
    );

CollectionConfig defaultConfig() => CollectionConfig();

void main() {
  group('anti-vacuity: a keymapping with no collect blocks', () {
    test('yields zero entries and zero issues', () {
      // First, deliberately: every count below is trivially satisfied by a
      // function that returns empty lists for everything.
      final plan = CollectionPlan.from(
          generatedKeyMappings(10), defaultConfig());

      expect(plan.entries, isEmpty,
          reason: 'nothing here carries a collect block, so a non-empty '
              'plan is inventing rather than reading');
      expect(plan.rejected, isEmpty);
      expect(plan.adjusted, isEmpty,
          reason: 'no collect block means nothing to reject and nothing to '
              'adjust — an issue against a key that asked for nothing is '
              'noise an operator learns to ignore');
    });
  });

  group('what to collect comes from the keymappings', () {
    test('three entries, two collected, touches nothing else', () {
      final mappings = KeyMappings(nodes: {
        'Line1.Motor1': collected('Line1.Motor1'),
        'Line2.Motor1': collected('Line2.Motor1'),
        'Line3.Motor1': opcUaEntry(identifier: 'Line3.Motor1'),
      });

      final plan = CollectionPlan.from(mappings, defaultConfig());

      expect(plan.entries.map((e) => e.key),
          unorderedEquals(['Line1.Motor1', 'Line2.Motor1']),
          reason: 'the collector config IS the keymappings — there is no '
              'second file listing keys, and a key without a collect block '
              'is a key nobody asked to historise');
      expect(plan.rejected, isEmpty);
      expect(plan.adjusted, isEmpty);
    });

    test('the table name is prefix + (collect.name ?? key)', () {
      final mappings = KeyMappings(nodes: {
        'Line1.Motor1': collected('Line1.Motor1', name: 'Line1.Motor1'),
      });

      final plan = CollectionPlan.from(mappings, defaultConfig());

      expect(plan.entries.single.table, 'gw_Line1.Motor1',
          reason: 'with the default prefix the gateway writes beside the '
              'app\'s Line1.Motor1 table, never into it — the prefix is the '
              'side-by-side guarantee');
    });

    test('soleWriter with an empty prefix names the app\'s own table — '
        'the cutover mode', () {
      final mappings = KeyMappings(nodes: {
        'Line1.Motor1': collected('Line1.Motor1'),
      });

      final plan = CollectionPlan.from(mappings,
          CollectionConfig(tablePrefix: '', soleWriter: true));

      expect(plan.entries.single.table, 'Line1.Motor1',
          reason: 'after the cutover the gateway owns the very table the '
              'app wrote yesterday, so history reads continuously across '
              'the switch — that is the point of the mode');
    });

    test('sampleMembers, sampleInterval and sampleExpression are carried '
        'through unchanged', () {
      final expression =
          ExpressionConfig(value: Expression(formula: 'Line1.Motor1 > 0'));
      final mappings = KeyMappings(nodes: {
        st101Key: collected(st101Key,
            interval: const Duration(seconds: 5),
            members: const ['p_stat_xOutput', 'p_stat_tBlockedFor'],
            expression: expression),
      });

      final plan = CollectionPlan.from(mappings, defaultConfig());
      final entry = plan.entries.single;

      expect(entry.sampleInterval, const Duration(seconds: 5),
          reason: 'this function decides WHAT, never HOW — a plan that '
              'rewrites the cadence is a plan doing the runner\'s job');
      expect(entry.sampleMembers, const ['p_stat_xOutput', 'p_stat_tBlockedFor']);
      expect(entry.sampleExpression, same(expression),
          reason: 'carried through, not rebuilt: an expression re-parsed '
              'here would be a second parser to disagree with the first');
    });

    test('a usable retention is carried through unchanged', () {
      const retention = RetentionPolicy(dropAfter: Duration(days: 365));
      final mappings = KeyMappings(nodes: {
        'Line1.Motor1': collected('Line1.Motor1', retention: retention),
      });

      final plan = CollectionPlan.from(mappings, defaultConfig());

      expect(plan.entries.single.retention, retention);
      expect(plan.adjusted, isEmpty);
    });
  });

  group('the 63-byte limit', () {
    test('a table name that would exceed 63 bytes is rejected, naming the '
        'key and the length', () {
      final longKey = 'Line1.${'M' * 70}';
      final mappings = KeyMappings(nodes: {
        longKey: collected(longKey),
        'Line1.Motor1': collected('Line1.Motor1'),
      });

      final plan = CollectionPlan.from(mappings, defaultConfig());

      expect(plan.entries.map((e) => e.key), ['Line1.Motor1'],
          reason: 'one over-long key costs exactly that key');
      final issue = plan.rejected.single;
      expect(issue.key, longKey);
      expect(issue.message, contains('63'),
          reason: 'Postgres truncates identifiers at NAMEDATALEN-1 and does '
              'not warn; two long keys sharing a 63-byte prefix silently '
              'become one table, so the limit itself belongs in the '
              'sentence the operator reads');
      expect(issue.message, contains('${('gw_$longKey').length}'),
          reason: 'the length is what the operator has to shorten by');
    });

    test('exactly 63 bytes is accepted — the limit is the limit', () {
      final name63 = 'x' * (63 - 'gw_'.length);
      final mappings = KeyMappings(nodes: {
        'Line1.Motor1': collected('Line1.Motor1', name: name63),
      });

      final plan = CollectionPlan.from(mappings, defaultConfig());

      expect(plan.entries.single.table, 'gw_$name63',
          reason: 'a guard one byte too eager rejects a legitimate tag, and '
              'a rejected tag records nothing');
      expect(plan.rejected, isEmpty);
    });

    test('the limit is bytes, not code units — Icelandic names count double',
        () {
      // 'þ' is two UTF-8 bytes. 60 of them after the 3-byte prefix is 123
      // bytes in a 60-character string.
      final icelandic = 'þ' * 60;
      final mappings = KeyMappings(nodes: {
        'Line1.Motor1': collected('Line1.Motor1', name: icelandic),
      });

      final plan = CollectionPlan.from(mappings, defaultConfig());

      expect(plan.rejected, hasLength(1),
          reason: 'NAMEDATALEN is a byte budget; a code-unit count passes '
              'a name Postgres will truncate mid-character');
    });
  });

  group('the unsafe characters', () {
    test('a name carrying a quote, semicolon, backslash or control '
        'character is rejected on its own, naming the key', () {
      for (final bad in <String>[
        'Line1.Mo"tor',
        "Line1.Mo'tor",
        'Line1.Mo;tor',
        r'Line1.Mo\tor',
        'Line1.Mo\x01tor',
      ]) {
        final mappings = KeyMappings(nodes: {
          'bad.key': collected('bad.key', name: bad),
          'Line1.Motor1': collected('Line1.Motor1'),
        });

        final plan = CollectionPlan.from(mappings, defaultConfig());

        expect(plan.entries.map((e) => e.key), ['Line1.Motor1'],
            reason: 'the name reaches SQL through interpolation with no '
                'escaping of the table identifier (database_drift.dart:687, '
                ':907); plan time is the only place "$bad" can be stopped, '
                'and every other collected key must still load');
        expect(plan.rejected.single.key, 'bad.key',
            reason: 'the issue names the key, because the key is what the '
                'operator can find in the editor');
      }
    });
  });

  group('duplicate table names', () {
    test('two keys resolving to the same table reject BOTH, naming both '
        'keys', () {
      final mappings = KeyMappings(nodes: {
        'Line1.Motor1': collected('Line1.Motor1', name: 'shared'),
        'Line2.Motor1': collected('Line2.Motor1', name: 'shared'),
        'Line3.Motor1': collected('Line3.Motor1'),
      });

      final plan = CollectionPlan.from(mappings, defaultConfig());

      expect(plan.entries.map((e) => e.key), ['Line3.Motor1'],
          reason: 'one table fed by two differently-shaped values is the '
              'schema fight (database.dart:1042-1082) inside our own '
              'process — keeping either one silently blesses whichever '
              'happened to be listed first');
      expect(plan.rejected, hasLength(2));
      for (final issue in plan.rejected) {
        expect(issue.message,
            allOf(contains('Line1.Motor1'), contains('Line2.Motor1')),
            reason: 'the operator fixing one entry needs to know which '
                'OTHER entry it collided with, or they rename theirs into '
                'a third collision');
      }
    });
  });

  group('router-refused keys are never collected blind', () {
    test('a collected key the router rejected is skipped and counted', () {
      final mappings = KeyMappings(nodes: {
        'Line1.Motor1': collected('Line1.Motor1'),
        r'$station.speed': collected(r'$station.speed'),
      });

      final plan = CollectionPlan.from(mappings, defaultConfig(),
          unroutable: {r'$station.speed'});

      expect(plan.entries.map((e) => e.key), ['Line1.Motor1'],
          reason: 'a key the router cannot route has no value stream to '
              'sample; collecting it blind would historise nothing under a '
              'table name that looks alive');
      expect(plan.rejected.single.key, r'$station.speed',
          reason: 'skipped and COUNTED — a silently absent table and a '
              'named rejection are two different afternoons for whoever '
              'goes looking for the history');
    });
  });

  group('unusable retention adjusts, never rejects', () {
    test('the entry is collected with a null retention and a note naming '
        'the key and the stored value', () {
      // Under kMinRetentionDuration: a unit-conversion artifact, not an
      // operator's choice (database.dart:287-319).
      const artifact = RetentionPolicy(dropAfter: Duration(seconds: 5));
      final mappings = KeyMappings(nodes: {
        'Line1.Motor1': collected('Line1.Motor1', retention: artifact),
      });

      final plan = CollectionPlan.from(mappings, defaultConfig());

      expect(plan.entries, hasLength(1),
          reason: 'the shipped behaviour (database.dart:874-885): an '
              'unusable policy installs nothing and keeps collecting, '
              'because a table that keeps everything is the safe direction '
              'to fail in — rejecting the entry would trade a retention '
              'bug for a data gap');
      expect(plan.entries.single.retention, isNull,
          reason: 'null retention means "install no policy", never '
              '"install the artifact"');
      final note = plan.adjusted.single;
      expect(note.key, 'Line1.Motor1');
      expect(note.message, contains('0:00:05'),
          reason: 'the note carries the stored value so the operator can '
              'recognise their typo — recorded rather than logged away');
      expect(plan.rejected, isEmpty,
          reason: 'rejection and adjustment are genuinely different '
              'outcomes: "your tag is not being collected" and "your tag '
              'is being kept forever" must never be the same line');
    });
  });

  group('scale: the live file\'s shape', () {
    test('430 entries in both naming conventions, one unsafe, yields 429 '
        'and one rejection', () {
      // Both conventions, as 08-04 task 1's fixtures do: the live file says
      // Line1.Motor1, the new installations say ST101.CN01.MOT01.
      final nodes = <String, KeyMappingEntry>{};
      for (var i = 0; i < 215; i++) {
        final key = 'Line$i.Motor1';
        nodes[key] = collected(key, interval: const Duration(seconds: 5));
      }
      for (var i = 0; i < 214; i++) {
        final key =
            'ST${101 + (i % 3) * 100}.CN${(i % 20 + 1).toString().padLeft(2, '0')}.MOT01.m$i';
        nodes[key] = collected(key, interval: const Duration(seconds: 5));
      }
      const unsafeKey = 'Line1.Blower1';
      nodes[unsafeKey] = collected(unsafeKey, name: "Line1.Blo'wer1");
      expect(nodes, hasLength(430),
          reason: 'the fixture must be the live file\'s size or the case '
              'proves nothing about a file');

      final plan =
          CollectionPlan.from(KeyMappings(nodes: nodes), defaultConfig());

      expect(plan.entries, hasLength(429),
          reason: 'per key, never per file: one unsafe name in 430 costs '
              'exactly that key, and the other 429 still load');
      expect(plan.rejected.single.key, unsafeKey);
      expect(plan.adjusted, isEmpty);
    });
  });
}

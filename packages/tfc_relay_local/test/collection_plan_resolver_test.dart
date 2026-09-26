/// The one bidirectional map between what a client names and what the
/// database holds — and the proof that it never guesses.
///
/// Three lookups, one direction each, and **null always means refuse**
/// (`series_address.dart:136-158`). The cases below are written against the
/// live plant file's measured shape rather than against a convenient one,
/// because the identity assumption a synthetic fixture invites — series name
/// equals table name equals plant key — is wrong on the real configuration in
/// two different ways at once.
///
/// ## What was measured, on 2026-09-03, in `svn-key-mappings.json`
///
/// | Fact | Count |
/// |---|---|
/// | nodes in the file | 430 |
/// | nodes carrying a `collect` block | 140 |
/// | of those, `collect.name` differing from the key | **28** |
/// | two-segment whole-struct keys among the collected | 90 |
/// | OPC UA nodes with an identifier | 390, of which **316 distinct** |
///
/// And the fact the plan did not know, which the round-trip case turns into
/// an assertion: **all 28 renamed entries collide in 14 pairs.** Every
/// checkweigher's `.1` and `.2` key carries the same `collect.name`, so
/// `CollectionPlan.from` rejects both of each pair (8b-01's duplicate rule:
/// "two keys resolving to the same table reject ALL of them"). The live file
/// therefore yields **112** collectable entries, not 140, and **zero**
/// surviving renames. The rename path is real code on a real configuration —
/// the operator only has to fix one of each pair for it to light up — so it
/// is proven here against the live names with one of each pair's collect
/// blocks removed, which is what an operator fixing the collision would do.
///
/// The file itself is not in this repository (it is plant configuration, and
/// it is untracked in the working copy). `liveShapedMappings` below
/// reproduces its measured shape entry for entry, transcribed the way
/// `keymap_fixtures.dart` transcribes its two verbatim entries; the last case
/// in the file runs the same assertions against the real file when a
/// developer's checkout has it, and reports a named skip when it does not.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:tfc_dart/core/collector.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:test/test.dart';
import 'package:tfc_relay_local/src/collect/collection_config.dart';
import 'package:tfc_relay_local/src/collect/collection_plan.dart';
import 'package:tfc_relay_local/src/data/collection_plan_resolver.dart';
import 'package:tfc_relay_local/src/key_router.dart';
import 'package:tfc_relay_local/src/upstream_link.dart' show UpstreamLink;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show ResolvedSeries;

import 'support/fake_upstream_link.dart';

// --------------------------------------------------------------- the fixtures

/// The gateway's own prefix, as every deployment ships it. Spelled here and
/// nowhere in `lib/src/data/` — the prefix arrives inside the plan.
CollectionConfig config({String prefix = 'gw_'}) => CollectionConfig(
      enabled: false,
      tablePrefix: prefix,
    );

OpcUANodeConfig node(String identifier, int namespace, String? alias) =>
    OpcUANodeConfig(namespace: namespace, identifier: identifier)
      ..serverAlias = alias;

KeyMappingEntry opcUa(String identifier, {int namespace = 4, String? alias}) =>
    KeyMappingEntry(opcuaNode: node(identifier, namespace, alias));

CollectEntry collect(String key, {String? name}) =>
    CollectEntry(key: key, name: name);

KeyMappingEntry collected(String identifier, String key,
        {String? name, int namespace = 4, String? alias}) =>
    KeyMappingEntry(
      opcuaNode: node(identifier, namespace, alias),
      collect: collect(key, name: name),
    );

/// A router over one permissive link, so `mappings` is the file minus the
/// reserved-prefix refusals — exactly what the resolver must see.
KeyRouter routerOver(KeyMappings mappings) => KeyRouter.overLinks(
      <UpstreamLink>[FakeUpstreamLink(alias: 'plant')],
      mappings: mappings,
    );

CollectionPlanResolver resolverOver(KeyMappings mappings,
    {String prefix = 'gw_'}) {
  final router = routerOver(mappings);
  return CollectionPlanResolver(
    plan: CollectionPlan.from(mappings, config(prefix: prefix),
        unroutable: router.lastIngest.rejected.keys.toSet()),
    router: router,
  );
}

/// Three entries: a plain one, a renamed one, and one that is collected by
/// nobody. Enough to prove the code compiles and the three lookups differ.
final KeyMappings synthetic = KeyMappings(nodes: <String, KeyMappingEntry>{
  'Line1.Motor1': collected('GVL_BatchLines.Drives_Line1[1].HMI',
      'Line1.Motor1', name: 'Line1.Motor1'),
  'Line1.Motor2': collected('GVL_BatchLines.Drives_Line1[2].HMI',
      'Line1.Motor2', name: 'Line1.Motor2.renamed'),
  'Line1.Blower1.running': opcUa('GVL_BatchLines.Blowers[1].running'),
});

// ------------------------------------------------------ the live file's shape

/// The measured facts, as constants so a case can name the number it covers
/// instead of printing a bare integer.
const int liveNodeCount = 430;
const int liveCollectedCount = 140;
const int liveRenamedCount = 28;
const int liveCollidingPairs = 14;
const int liveEntryCount = liveCollectedCount - liveRenamedCount; // 112
const int liveTwoSegmentStructKeys = 90;

/// The three checkweigher lines, each contributing two renamed keys that
/// share one `collect.name` — the 14 colliding pairs, by their real names.
const List<String> liveCheckweigherBases = <String>[
  'SB1.CheckWeigher.Accepted',
  'SB1.CheckWeigher.Rejected',
  'SB2.CheckWeigher.Accepted',
  'SB2.CheckWeigher.Rejected',
  'SB3.CheckWeigher.Accepted',
  'SB3.CheckWeigher.Rejected',
  'SB1.CheckWeigher.Current',
  'SB1.BatchLid',
  'SB1.RejectLid',
  'SB2.CheckWeigher.Current',
  'SB2.BatchLid',
  'SB2.RejectLid',
  'SB3.CheckWeigher.Current',
  'SB3.BatchLid',
];

/// The live file's shape, reproduced: 430 nodes, 140 with a collect block, 28
/// of them renamed into 14 colliding pairs, 90 two-segment struct keys, and
/// the identifier collisions the SpeedBatchers really have (one identifier
/// carried by six keys across three server aliases).
///
/// [dropSecondOfPair] removes the `.2` sibling of every colliding pair's
/// collect block — what an operator fixing the collision would do, and the
/// only state in which the live file's rename path is reachable at all.
KeyMappings liveShapedMappings({bool dropSecondOfPair = false}) {
  final nodes = <String, KeyMappingEntry>{};

  // 90 two-segment whole-struct drive keys, the file's dominant shape.
  for (var i = 1; i <= liveTwoSegmentStructKeys; i++) {
    final line = ((i - 1) ~/ 30) + 1;
    final motor = ((i - 1) % 30) + 1;
    final key = 'Line$line.Motor$motor';
    nodes[key] =
        collected('GVL_BatchLines.Drives_Line$line[$motor].HMI', key);
  }

  // 28 renamed keys in 14 pairs, on three named SpeedBatcher aliases. Six of
  // the identifiers are shared by two keys each within a line and repeated
  // across lines, which is where the live file's 390 → 316 identifier
  // collapse comes from.
  for (var p = 0; p < liveCollidingPairs; p++) {
    final base = liveCheckweigherBases[p];
    final alias = 'speedbatcher${(p % 3) + 1}';
    final identifier = 'Checkweigher${(p % 2) + 1}.${base.split('.').last}';
    nodes['$base.1'] = collected(identifier, '$base.1',
        name: base, namespace: 2, alias: alias);
    nodes['$base.2'] = dropSecondOfPair
        ? opcUa(identifier, namespace: 2, alias: alias)
        : collected(identifier, '$base.2',
            name: base, namespace: 2, alias: alias);
  }

  // 22 more collected keys with no rename, taking the collect count to 140.
  for (var i = 1; i <= liveCollectedCount - liveTwoSegmentStructKeys - liveRenamedCount; i++) {
    final key = 'weigher${i}v.weight';
    nodes[key] = collected('Weighers.W$i.weight', key);
  }

  // The rest of the file: nodes with no collect block at all.
  var filler = 0;
  while (nodes.length < liveNodeCount) {
    filler++;
    nodes['CN${filler.toString().padLeft(2, '0')}.MOT01.running'] =
        opcUa('GVL_Conveyors.CN$filler.running');
  }
  return KeyMappings(nodes: nodes);
}

void main() {
  group('resolve: a wire name to a table, a member and a plant key', () {
    test('a plain series answers the prefixed table, no member, its own key',
        () {
      final resolver = resolverOver(synthetic);
      final resolved = resolver.resolve('Line1.Motor1');

      expect(resolved, isA<ResolvedSeries>());
      expect(resolved!.table, 'gw_Line1.Motor1',
          reason: 'this is the whole read-side half of 8b\'s deferred item: '
              'a chart that has always asked for `Line1.Motor1` must reach '
              'the GATEWAY\'s table, not the app collector\'s unprefixed one, '
              'without the chart changing');
      expect(resolved.member, isNull);
      expect(resolved.plantKey, 'Line1.Motor1',
          reason: 'canSee is asked about the plant key, and the key travels '
              'attached to the table so forgetting the check is a compile '
              'error rather than a policy hole');
    });

    test('a member address answers the same table with the member', () {
      final resolved = resolverOver(synthetic).resolve('Line1.Motor1:speed');

      expect(resolved!.table, 'gw_Line1.Motor1');
      expect(resolved.member, 'speed');
      expect(resolved.plantKey, 'Line1.Motor1',
          reason: 'a member is not a key: the policy question is about the '
              'series, so the struct\'s key is what comes back');
    });

    test('a renamed key resolves through the NAME, not through the key', () {
      final resolved = resolverOver(synthetic).resolve('Line1.Motor2');

      expect(resolved!.table, 'gw_Line1.Motor2.renamed',
          reason: 'the identity assumption — table name equals key — is '
              'wrong on 28 of the live file\'s 140 collect blocks. A '
              'resolver that assumed it would send 20% of the plant\'s '
              'charts at tables that do not exist');
      expect(resolved.plantKey, 'Line1.Motor2');
    });

    test('a malformed name throws rather than resolving to null', () {
      final resolver = resolverOver(synthetic);

      expect(() => resolver.resolve('a:b:c'), throwsFormatException,
          reason: '"you spelled it wrong" and "there is no such series" are '
              'two different facts and the caller acts on each differently');
      expect(() => resolver.resolve('Line1.Motor1:'), throwsFormatException);
      expect(() => resolver.resolve(''), throwsFormatException);
    });
  });

  group('null is refuse, everywhere', () {
    test('a series outside the plan is null, and so is its table and node',
        () {
      final resolver = resolverOver(synthetic);

      expect(resolver.resolve('Line1.Blower1.running'), isNull,
          reason: 'the key is in the keymappings but carries no collect '
              'block, so nothing was ever recorded under it — fail closed');
      expect(resolver.resolve('no.such.series'), isNull);
      expect(resolver.resolve('no.such.series:member'), isNull);
      expect(resolver.keyForTable('gw_no_such_table'), isNull);
      expect(resolver.keyForTable('pg_catalog.pg_authid'), isNull,
          reason: 'a client cannot make the gateway read an arbitrary '
              'relation, which is the point of the map being an allow-list '
              'rather than a transformation');
      expect(resolver.keyForNode('ns=2;s=Nothing'), isNull);
    });

    test('the physical table is not itself a wire name', () {
      final resolver = resolverOver(synthetic);

      expect(resolver.resolve('gw_Line1.Motor1'), isNull,
          reason: 'the wire names the plant key. Accepting the physical '
              'name too would give one series two spellings, and the second '
              'is the one a client would have had to learn the prefix to '
              'guess');
    });

    test('an app-collected table — no gw_ entry — resolves to null', () {
      final resolver = resolverOver(synthetic);

      expect(resolver.keyForTable('Line1.Motor1'), isNull,
          reason: 'research C.2\'s honest limit: this map covers what the '
              'GATEWAY collects. A pre-cutover table the app\'s own '
              'collector wrote is not in it, so a chart pointed at one '
              'answers "no such series" until 8b\'s one-shot INSERT INTO … '
              'SELECT migration runs');
    });
  });

  group('keyForTable inverts resolve', () {
    test('every one of the live file\'s plan entries round-trips', () {
      final mappings = liveShapedMappings();
      final resolver = resolverOver(mappings);
      final plan = CollectionPlan.from(mappings, config());

      expect(plan.entries, hasLength(liveEntryCount),
          reason: 'the live file has $liveCollectedCount collect blocks, and '
              '$liveRenamedCount of them collide in $liveCollidingPairs '
              'pairs on a shared collect.name — 8b-01 rejects ALL of each '
              'pair, so the plan is $liveEntryCount entries');

      var covered = 0;
      for (final entry in plan.entries) {
        final resolved = resolver.resolve(entry.key);
        expect(resolved, isNotNull, reason: 'no mapping for ${entry.key}');
        expect(resolved!.table, entry.table);
        expect(resolver.keyForTable(resolved.table), entry.key,
            reason: 'the round trip must be the identity for every entry, '
                'because _PolicyTimeseries asks canSee about whatever comes '
                'back from it');
        covered++;
      }
      expect(covered, liveEntryCount);
      printOnFailure('round-tripped $covered of $liveEntryCount plan '
          'entries (out of $liveCollectedCount collect blocks in the file)');
      // ignore: avoid_print
      print('round-tripped $covered plan entries from a '
          '$liveNodeCount-node file');
    });

    test('the 28 renamed live entries are rejected as colliding pairs', () {
      final mappings = liveShapedMappings();
      final plan = CollectionPlan.from(mappings, config());

      expect(plan.rejected, hasLength(liveRenamedCount),
          reason: 'every rename in the live file is half of a pair sharing '
              'one collect.name — this is a finding about the live '
              'configuration, not about this code, and it is asserted here '
              'so that a config fix shows up as a failing count rather than '
              'as a silent change of behaviour');
      final resolver = resolverOver(mappings);
      for (final issue in plan.rejected) {
        expect(resolver.resolve(issue.key), isNull,
            reason: 'a rejected key records nothing, so it must resolve to '
                'nothing: serving it would send a chart at a table that was '
                'never created');
      }
    });

    test(
        'with one of each pair fixed, SB1.CheckWeigher.Accepted.1 resolves '
        'through its name', () {
      final resolver = resolverOver(liveShapedMappings(dropSecondOfPair: true));

      final resolved = resolver.resolve('SB1.CheckWeigher.Accepted.1');
      expect(resolved, isNotNull,
          reason: 'the collision is gone, so the entry is collectable');
      expect(resolved!.table, 'gw_SB1.CheckWeigher.Accepted',
          reason: 'named entry: SB1.CheckWeigher.Accepted.1 carries '
              'collect.name "SB1.CheckWeigher.Accepted". It resolves through '
              'the NAME. Through the key it would have been '
              '"gw_SB1.CheckWeigher.Accepted.1", which no collector ever '
              'wrote');
      expect(resolved.plantKey, 'SB1.CheckWeigher.Accepted.1');
      expect(resolver.keyForTable('gw_SB1.CheckWeigher.Accepted'),
          'SB1.CheckWeigher.Accepted.1');
      expect(resolver.resolve('SB1.CheckWeigher.Accepted'), isNull,
          reason: 'the collect NAME is not a wire name either — only the '
              'plant key is');
    });
  });

  group('keyForNode: the browse inverse', () {
    test('an unambiguous identifier answers the key it is', () {
      final resolver = resolverOver(synthetic);

      expect(resolver.keyForNode('GVL_BatchLines.Drives_Line1[1].HMI'),
          'Line1.Motor1',
          reason: 'BrowseNode.id is the string NodeId as the PLC spells it '
              '(local_browse.dart:271), which is exactly what '
              'opcua_node.identifier holds');
    });

    test('a node with no collect block still answers its key', () {
      final resolver = resolverOver(synthetic);

      expect(resolver.keyForNode('GVL_BatchLines.Blowers[1].running'),
          'Line1.Blower1.running',
          reason: 'browse is about the address space, not about the '
              'historian: a tag nobody records is still a tag a station may '
              'or may not be allowed to see');
    });

    test('a folder or any id the keymappings never name answers null', () {
      final resolver = resolverOver(synthetic);

      expect(resolver.keyForNode('GVL_BatchLines'), isNull,
          reason: '_PolicyBrowse rule 2: a node the resolver maps to no key '
              'is NOT asked about and is NOT dropped. Pruning a folder would '
              'take every tag under it off the tree, including the ones the '
              'station may see');
      expect(resolver.keyForNode('speedbatcher1'), isNull,
          reason: 'the browse roots are link aliases, not variables');
    });

    test('an identifier several keys claim answers null, not one of them',
        () {
      final resolver = resolverOver(liveShapedMappings());

      expect(resolver.keyForNode('Checkweigher1.Accepted'), isNull,
          reason: 'the live file has 390 OPC UA nodes on 316 distinct '
              'identifiers: the SpeedBatchers repeat theirs across three '
              'server aliases, and keyForNode is handed an id with no alias. '
              'Picking one of the claimants is `_getClientWrapper`\'s '
              'firstWhereOrNull mistake (T-08-13), and it would ask canSee '
              'about the wrong tag half the time');
    });
  });

  group('the map is built once', () {
    test('a keymapping reload does not silently re-point a live resolver', () {
      final router = routerOver(synthetic);
      final resolver = CollectionPlanResolver(
        plan: CollectionPlan.from(synthetic, config()),
        router: router,
      );

      router.applyKeyMappings(KeyMappings(nodes: <String, KeyMappingEntry>{
        'Line9.Motor9': collected('GVL.Other', 'Line9.Motor9'),
      }));

      expect(resolver.keyForNode('GVL_BatchLines.Drives_Line1[1].HMI'),
          'Line1.Motor1',
          reason: 'the three maps are built at construction from the plan '
              'and the router, never derived per call — so a resolver is a '
              'SNAPSHOT, and re-pointing it is the composition root\'s job. '
              'Half a reload (the router\'s new mappings, the plan\'s old '
              'tables) is worse than none');
      expect(resolver.keyForNode('GVL.Other'), isNull);
    });
  });

  group('the real file, when this checkout has it', () {
    final live = File('${Directory.current.path}/../../svn-key-mappings.json');

    test('the measured numbers still hold', () {
      final mappings = KeyMappings.fromJson(
          (jsonDecode(live.readAsStringSync()) as Map)
              .cast<String, dynamic>());
      final plan = CollectionPlan.from(mappings, config());

      expect(mappings.nodes, hasLength(liveNodeCount));
      expect(
          mappings.nodes.values.where((n) => n.collect != null),
          hasLength(liveCollectedCount));
      expect(plan.entries, hasLength(liveEntryCount));
      expect(plan.rejected, hasLength(liveRenamedCount));

      final resolver = resolverOver(mappings);
      for (final entry in plan.entries) {
        expect(resolver.resolve(entry.key)!.table, entry.table);
        expect(resolver.keyForTable(entry.table), entry.key);
      }
    },
        skip: live.existsSync()
            ? null
            : 'skipped: svn-key-mappings.json is plant configuration and is '
                'not in this repository. The shape it was measured to have '
                'is reproduced by liveShapedMappings() above and asserted by '
                'every case in this file');
  });
}

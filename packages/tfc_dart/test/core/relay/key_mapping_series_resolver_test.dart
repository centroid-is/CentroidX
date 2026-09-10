/// `KeyMappingSeriesResolver`: the wire series name to the table the backend
/// actually writes, or nothing at all.
///
/// Two properties carry this file. The first is **fail-closed**: a key with no
/// `collect` entry has no history, and the resolver says so with null rather
/// than guessing a table from the key. `SeriesResolver`'s own doc
/// (`series_address.dart:150-158`) is explicit that no permissive
/// implementation may exist, so the arm that would catch one is worth more
/// than the arms that catch a wrong table.
///
/// The second is **agreement with the writer**. The resolver names a table a
/// client will read from; the collector names a table it inserts into. A
/// second spelling of the same rule compiles, keeps every suite green, and
/// serves a year of history out of a table nothing writes. So the derivation
/// is one function, `collectTableName`, and there is an arm asserting both
/// sides call it and a source pin asserting the collector spells it nowhere
/// else.
library;

import 'dart:io';

import 'package:logger/logger.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/collector.dart'
    show CollectEntry, collectTableName;
import 'package:tfc_dart/core/relay/key_mapping_series_resolver.dart';
import 'package:tfc_dart/core/state_man.dart'
    show KeyMappings, KeyMappingEntry, OpcUANodeConfig;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

// ---------------------------------------------------------------- the fixture

/// A plant mapping with one of everything this resolver has to answer for.
///
/// The two `SB1.CheckWeigher.Accepted.*` keys sharing one table are **not
/// invented**: the live SVN mapping has fourteen tables claimed by two keys
/// each, in exactly this shape (two checkweigher heads recording one stream).
KeyMappings _mappings() => KeyMappings(nodes: {
      // A collected scalar; the table is the key, because no name is set.
      'ST101.CN01.MOT01.setpoint': KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'MOT01.setpoint')
          ..serverAlias = 'ST101',
        collect: CollectEntry(key: 'ST101.CN01.MOT01.setpoint'),
      ),
      // A collected struct, members picked into one table under a chosen name.
      'ST101.CN01.SENS01': KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'SENS01')
          ..serverAlias = 'ST101',
        collect: CollectEntry(
          key: 'ST101.CN01.SENS01',
          name: 'st101_sensor_block',
          sampleMembers: ['p_stat_xOutput', 'p_stat_tBlockedFor'],
        ),
      ),
      // Mapped, never collected: the fail-closed case.
      'ST101.CN01.MOT01.running': KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'MOT01.running')
          ..serverAlias = 'ST101',
      ),
      // Two keys, one table.
      'SB1.CheckWeigher.Accepted.1': KeyMappingEntry(
        collect: CollectEntry(
            key: 'SB1.CheckWeigher.Accepted.1',
            name: 'SB1.CheckWeigher.Accepted'),
      ),
      'SB1.CheckWeigher.Accepted.2': KeyMappingEntry(
        collect: CollectEntry(
            key: 'SB1.CheckWeigher.Accepted.2',
            name: 'SB1.CheckWeigher.Accepted'),
      ),
    });

/// Captures the lines a [Logger] emits, so "it warns" is an assertion and not
/// a hope.
final class _Captured extends LogOutput {
  final List<String> lines = <String>[];

  @override
  void output(OutputEvent event) => lines.addAll(event.lines);
}

Logger _logger(_Captured sink) => Logger(
      level: Level.all,
      filter: ProductionFilter(),
      printer: SimplePrinter(printTime: false, colors: false),
      output: sink,
    );

/// A resolver whose collision warning goes nowhere.
///
/// The fixture collides on purpose, so every arm that is not about the warning
/// would otherwise print it. One arm owns the warning and builds its own.
KeyMappingSeriesResolver _quietResolver([KeyMappings? mappings]) =>
    KeyMappingSeriesResolver(
        keyMappings: mappings ?? _mappings(), logger: Logger(level: Level.off));

void main() {
  group('resolve', () {
    test('a collected scalar resolves to its table, its key and no member', () {
      final resolver = _quietResolver();
      final series = resolver.resolve('ST101.CN01.MOT01.setpoint');

      expect(series, isNotNull);
      expect(series!.table, 'ST101.CN01.MOT01.setpoint');
      expect(series.member, isNull);
      expect(series.plantKey, 'ST101.CN01.MOT01.setpoint',
          reason: 'the plant key is the name canSee is asked about; a table '
              'travelling without it is a caller who can read history for a '
              'tag the identity may not see');
    });

    test('a named collect entry resolves to the name, which is the table',
        () {
      final resolver = _quietResolver();

      expect(resolver.resolve('ST101.CN01.SENS01')!.table,
          'st101_sensor_block');
    });

    test('a struct member rides the same table and round-trips', () {
      final resolver = _quietResolver();
      final whole = resolver.resolve('ST101.CN01.SENS01')!;
      final member =
          resolver.resolve('ST101.CN01.SENS01:p_stat_tBlockedFor')!;

      expect(member.table, whole.table,
          reason: 'sample_members picks members into ONE table; a member is a '
              'column of the row, not a table of its own');
      expect(member.member, 'p_stat_tBlockedFor');
      expect(whole.member, isNull);
      expect(member.plantKey, whole.plantKey);
      expect(
          relay.SeriesAddress.parse('ST101.CN01.SENS01:p_stat_tBlockedFor')
              .toString(),
          'ST101.CN01.SENS01:p_stat_tBlockedFor');
    });

    test('a mapped key with no collect entry refuses, and guesses nothing', () {
      final resolver = _quietResolver();

      expect(resolver.resolve('ST101.CN01.MOT01.running'), isNull,
          reason: 'T-13-04-a: an identity fallback would answer with a table '
              'name a client supplied, for a series nothing records');
      expect(resolver.resolve('ST101.CN01.MOT01.running:member'), isNull,
          reason: 'a member of a series that is not recorded is still not '
              'recorded');
    });

    test('a key nothing maps refuses', () {
      final resolver = _quietResolver();

      expect(resolver.resolve('ST999.CN99.MOT99.setpoint'), isNull);
      expect(resolver.resolve('gw_ST101.CN01.MOT01.setpoint'), isNull,
          reason: 'a physical table name is not a series name; answering one '
              'would give a client a second, unchecked way to name a table');
    });

    test('a malformed name throws rather than resolving to null', () {
      final resolver = _quietResolver();

      expect(() => resolver.resolve('a:b:c'), throwsFormatException,
          reason: '"you spelled it wrong" and "there is no such series" are '
              'two different facts and the caller acts on them differently');
      expect(() => resolver.resolve('ST101.CN01.SENS01:'),
          throwsFormatException);
      expect(() => resolver.resolve(''), throwsFormatException);
    });
  });

  group('the two reverse directions', () {
    test('keyForTable answers the key a table records, and refuses an unknown '
        'table', () {
      final resolver = _quietResolver();

      expect(resolver.keyForTable('st101_sensor_block'), 'ST101.CN01.SENS01');
      expect(resolver.keyForTable('ST101.CN01.MOT01.setpoint'),
          'ST101.CN01.MOT01.setpoint');
      expect(resolver.keyForTable('gw_nothing'), isNull);
      expect(resolver.keyForTable('ST101.CN01.MOT01.running'), isNull,
          reason: 'an uncollected key is not a table');
    });

    test('keyForNode answers a mapped browse id with itself, and a folder with '
        'nothing', () {
      final resolver = _quietResolver();

      expect(resolver.keyForNode('ST101.CN01.MOT01.running'),
          'ST101.CN01.MOT01.running',
          reason: 'BackendBrowse spells a node id as the plant key, so the '
              'translation is identity for a mapped key — but only for one it '
              'actually maps');
      expect(resolver.keyForNode('ST101.CN01'), isNull,
          reason: 'a folder must answer null: the policy reads null as "do '
              'not ask canSee, do not drop", and pruning a folder takes every '
              'tag under it off the tree');
      expect(resolver.keyForNode('ST999.CN99.MOT99'), isNull);
    });
  });

  group('two keys, one table', () {
    test('the collision is warned about once, naming the table and both keys',
        () {
      final sink = _Captured();
      final resolver = KeyMappingSeriesResolver(
          keyMappings: _mappings(), logger: _logger(sink));

      final warnings = sink.lines
          .where((line) => line.contains('SB1.CheckWeigher.Accepted'))
          .toList();
      expect(warnings, hasLength(1),
          reason: 'one line for the whole mapping, not one per collision: a '
              'plant file with fourteen of these must not be fourteen startup '
              'lines');
      expect(warnings.single, contains('SB1.CheckWeigher.Accepted.1'));
      expect(warnings.single, contains('SB1.CheckWeigher.Accepted.2'));
      expect(resolver.ambiguousTables, {'SB1.CheckWeigher.Accepted'});
    });

    test('keyForTable refuses a table two keys claim, rather than picking one',
        () {
      final resolver = _quietResolver();

      expect(resolver.keyForTable('SB1.CheckWeigher.Accepted'), isNull,
          reason: 'T-13-04-d: last-write-wins would serve one head\'s history '
              'under the other head\'s name, and canSee would be asked about '
              'the wrong key');
    });

    test('each colliding key still resolves under its own name', () {
      final resolver = _quietResolver();
      final first = resolver.resolve('SB1.CheckWeigher.Accepted.1')!;
      final second = resolver.resolve('SB1.CheckWeigher.Accepted.2')!;

      expect(first.table, 'SB1.CheckWeigher.Accepted');
      expect(second.table, first.table);
      expect(first.plantKey, 'SB1.CheckWeigher.Accepted.1');
      expect(second.plantKey, 'SB1.CheckWeigher.Accepted.2',
          reason: 'the forward direction is unambiguous — the client named a '
              'key — so refusing it would take a working chart away for a '
              'config the plant deliberately runs');
    });
  });

  group('agreement with the collector', () {
    test('the resolver\'s table for a key is collectTableName, the same '
        'function the collector inserts through', () {
      final mappings = _mappings();
      final resolver = _quietResolver(mappings);

      var checked = 0;
      for (final entry in mappings.nodes.entries) {
        final collect = entry.value.collect;
        if (collect == null) {
          expect(resolver.resolve(entry.key), isNull);
          continue;
        }
        checked++;
        expect(resolver.resolve(entry.key)!.table, collectTableName(collect),
            reason: 'the resolver names the table a client reads and the '
                'collector names the table it writes; two spellings of one '
                'rule serve history from a table nothing writes');
      }
      expect(checked, 4);
    });

    test('the collector derives its table name through collectTableName and '
        'nowhere else', () {
      String strippedSource(String path) => File(path)
          .readAsStringSync()
          .split('\n')
          .map((line) {
            final slashes = line.indexOf('//');
            return slashes < 0 ? line : line.substring(0, slashes);
          })
          .join('\n');

      // `collectTableName` used to live in `collector.dart` and this arm read
      // that one file. The portable-types split moved it to
      // `collect_config.dart`, which is where a pure config helper belongs and
      // is why an HMI asset can name `CollectEntry` without linking an OPC UA
      // client. The rule did not change, so the arm follows it rather than
      // being deleted — and it is now stated as two halves, which is strictly
      // stronger than the single count it replaced: the derivation exists in
      // exactly one place, and the collector is not that place.
      final config = strippedSource('lib/core/collect_config.dart');
      final collector = strippedSource('lib/core/collector.dart');

      expect('entry.name ?? entry.key'.allMatches(config), hasLength(1),
          reason: 'exactly one occurrence, and it is the body of '
              'collectTableName itself');
      expect('entry.name ?? entry.key'.allMatches(collector), isEmpty,
          reason: 'every place the collector open-codes the derivation is a '
              'place it can drift from the resolver, which is the drift this '
              'arm exists for');
      expect(
          config,
          contains(
              'String collectTableName(CollectEntry entry) => entry.name ?? '
              'entry.key;'));
      expect('collectTableName('.allMatches(collector).length, greaterThan(2),
          reason: 'the three call sites the collector had; the declaration '
              'itself now lives in collect_config.dart');
    });
  });

  group('fail-closed, structurally', () {
    test('the implementation has no identity fallback', () {
      final source = File('lib/core/relay/key_mapping_series_resolver.dart')
          .readAsStringSync()
          .split('\n')
          .map((line) {
            final slashes = line.indexOf('//');
            return slashes < 0 ? line : line.substring(0, slashes);
          })
          .join('\n');

      expect(source, isNot(contains('plantKey: wireName')));
      expect(source, isNot(contains('table: wireName')));
      expect(source, isNot(contains('table: address.series')),
          reason: 'the table must come from a collect entry, never from the '
              'string the client sent — that is the whole of T-13-04-b');
      expect(source, contains('if (table == null) return null;'),
          reason: 'the refusal branch is pinned positively: sabotage (a) '
              'reached the identity fallback by writing `?? address.series` '
              'onto the lookup, which no negative substring arm can enumerate '
              'in advance. An early return that is gone is a fallback that '
              'has arrived');
    });
  });
}

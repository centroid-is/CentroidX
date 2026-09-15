/// The history-view mapping, with no database anywhere — the offline half.
///
/// Four of the eleven methods' hazards are properties of the *row shapes*, not
/// of the server: whether an `int` graph index can be stringified into a key
/// drift's `int.tryParse` will read back, which of `null` and `''` a graph
/// name is stored as, whether an absent alias defaults to the key, and what a
/// call does when the historian is not up. None of those needs Docker, and a
/// property gated behind Docker is a property nobody runs.
///
/// The round trips through a real server are the `db`-tagged
/// `history_view_read_test.dart`.
@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:tfc_relay_local/src/data/history_view_store.dart';
import 'package:tfc_relay_local/src/data/timescale_reader.dart'
    show HistorianUnavailable;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show HistoryViewGraphRecord, HistoryViewKeyRecord;

void main() {
  group('the graph map crosses as String keys and the conversion is total',
      () {
    test('every int index stringifies to a key int.tryParse reads back',
        () {
      // This is the assertion the plan asks for rather than the assumption it
      // replaces. drift's createHistoryView reads its graph map's keys with
      // `int.tryParse` and SILENTLY SKIPS every entry that returns null
      // (database_drift.dart:610, and again at :655 on the update path). The
      // wire type is `Map<int, …>`, so the untyped path is unreachable from a
      // client — but only if `'$index'` is always readable back, for every
      // int a client could send, including the ones nobody types by hand.
      const indexes = <int>[
        0,
        7,
        12,
        -1,
        -9007199254740991,
        9007199254740991,
        // The two ends of a Dart VM int. `int.tryParse` reads both; a key
        // built by any other route (a double, an enum index cast, a
        // radix-16 spelling) would not be.
        -9223372036854775808,
        9223372036854775807,
      ];

      final rows = graphConfigRows({
        for (final index in indexes)
          index: HistoryViewGraphRecord(graphIndex: index),
      });

      expect(rows, hasLength(indexes.length),
          reason: 'an index that cannot round-trip through a String key is an '
              'entry drift throws away without an error, and the operator '
              'sees a chart with a graph missing');
      for (final index in indexes) {
        expect(int.tryParse('$index'), index,
            reason: 'the stringification is what keeps drift\'s silent drop '
                'unreachable; if it is not total for $index the drop is '
                'reachable after all');
        expect(rows!.containsKey('$index'), isTrue);
      }
    });

    test('a null graph map stays null rather than becoming an empty one', () {
      // Not decoration: drift's `if (graphConfigs != null)` is the difference
      // between "this caller said nothing about graphs" and "this caller said
      // there are none". On the update path the second wipes the existing
      // rows and the first — no, it wipes them too, because the delete comes
      // first unconditionally. Kept identical so the store adds no new
      // behaviour of its own here; the note is the record that it was looked
      // at rather than assumed.
      expect(graphConfigRows(null), isNull);
      expect(keyConfigRows(null), isNull);
    });
  });

  group('null and the empty string are different things to a legend', () {
    test('an unnamed graph is stored as NULL, not as an empty string', () {
      final rows = graphConfigRows({
        0: const HistoryViewGraphRecord(graphIndex: 0),
        1: const HistoryViewGraphRecord(graphIndex: 1, name: 'Hraði'),
      })!;

      expect(rows['0']!['name'], isNull,
          reason: 'the column is nullable and the application\'s own HMI '
              'reads these rows directly; writing \'\' where it has always '
              'written NULL invents a third state in a table this gateway '
              'does not own');
      expect(rows['1']!['name'], 'Hraði');
    });

    test('a NULL name reads back as the empty string the record declares', () {
      // The record's `name` is a non-nullable String defaulting to '' —
      // mirroring drift's own `row.name ?? ''`. So the collapse is decided in
      // the protocol package and this direction only honours it.
      expect(
          graphRecordFrom(4, {
            'name': null,
            'yAxisUnit': null,
            'yAxis2Unit': null,
          }).name,
          '');
      expect(graphRecordFrom(4, const {}).yAxisUnit, '');
      expect(graphRecordFrom(4, const {'name': 'Hiti'}).name, 'Hiti');
      expect(graphRecordFrom(4, const {}).graphIndex, 4,
          reason: 'the index is the map key upstream and is not in the bag; '
              'a record that carried 0 instead would put every graph on the '
              'first axis');
    });
  });

  group('the alias default is drift\'s, implemented once', () {
    test('an absent alias becomes the key, and the record is what does it',
        () {
      expect(keyRecordFrom('Line1.Motor1', const {'alias': null}).alias,
          'Line1.Motor1',
          reason: 'the legend needs something to render and the key\'s own '
              'name is it (state_man_api.dart\'s HistoryViewKeyRecord doc, '
              'and the contract at data_services_contract.dart:294-296)');
      expect(keyRecordFrom('Line1.Motor1', const {'alias': 'Færiband'}).alias,
          'Færiband');
      expect(keyRecordFrom('Line1.Motor1', const {}).alias, 'Line1.Motor1');
    });

    test('the row the store writes carries the alias the record resolved', () {
      final rows = keyConfigRows({
        'a': const HistoryViewKeyRecord(key: 'a'),
        'b': const HistoryViewKeyRecord(key: 'b', alias: 'Bé', graphIndex: 2),
      })!;

      expect(rows['a']!['alias'], 'a',
          reason: 'the wire record cannot express "no alias" — its '
              'constructor has already substituted the key — so the row '
              'written for a key with no alias is one holding alias = key, '
              'and "absent" is not recoverable afterwards');
      expect(rows['b']!['alias'], 'Bé');
      expect(rows['b']!['graphIndex'], 2);
      expect(rows['b']!['useSecondYAxis'], isFalse);
    });
  });

  group('with no historian', () {
    final store = HistoryViewStore(database: () => null);

    test('every method refuses retryably rather than hanging or answering',
        () async {
      final calls = <String, Future<Object?> Function()>{
        'createHistoryView': () => store.createHistoryView('n', const []),
        'updateHistoryView': () => store.updateHistoryView(1, 'n', const []),
        'deleteHistoryView': () => store.deleteHistoryView(1),
        'selectHistoryViews': () => store.selectHistoryViews(),
        'getHistoryViewKeys': () => store.getHistoryViewKeys(1),
        'getHistoryViewGraphs': () => store.getHistoryViewGraphs(1),
        'getHistoryViewKeyNames': () => store.getHistoryViewKeyNames(1),
        'addHistoryViewPeriod': () => store.addHistoryViewPeriod(
            1, 'p', DateTime.utc(2026), DateTime.utc(2026, 1, 2)),
        'deleteHistoryViewPeriod': () => store.deleteHistoryViewPeriod(1),
        'listHistoryViewPeriods': () => store.listHistoryViewPeriods(1),
        'getGlobalRetentionHorizon': () => store.getGlobalRetentionHorizon(),
      };

      expect(calls, hasLength(11),
          reason: 'HistoryViewApi is eleven methods; a member added without a '
              'row here is a member with no historian-down answer');

      for (final entry in calls.entries) {
        await expectLater(entry.value(), throwsA(isA<HistorianUnavailable>()),
            reason: '${entry.key} answered something when the historian was '
                'not up. An empty list there is a view picker that reads as '
                '"you have saved nothing", and an operator saves it again');
      }
    });

    test('the refusal is retryable, because the historian coming up fixes it',
        () async {
      await expectLater(
          store.selectHistoryViews(),
          throwsA(isA<HistorianUnavailable>()
              .having((e) => e.retryable, 'retryable', isTrue)));
    });
  });
}

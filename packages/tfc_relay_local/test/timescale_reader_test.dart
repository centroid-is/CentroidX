/// What the reader does *before* it reaches a database — the belt, the
/// projection's column list, and the refusals a struct earns.
///
/// These cases need no server: their whole subject is what SQL was built and
/// whether any was built at all, and that is visible from a recording
/// `AppDatabase` with a `NativeDatabase.memory()` underneath it. Putting them
/// behind the `db` tag would hide the two properties this file exists for —
/// "no query ran" and "these columns and no others" — inside a lane that is
/// excluded on three of the four CI platforms.
///
/// The rows-come-back-from-a-real-TimescaleDB half is `timeseries_read_test.dart`,
/// which is 8b's `db` lane and stays there.
@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/state_man.dart' show KeyMappingEntry, KeyMappings;
import 'package:tfc_relay_local/src/key_router.dart';
import 'package:tfc_relay_local/src/local_state_man.dart';
import 'package:tfc_relay_local/src/data/read_limits.dart';
import 'package:tfc_relay_local/src/data/timescale_reader.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show SourceRefusal, TimeseriesApi;

import 'support/fake_upstream_link.dart';
// The recorder and the prefixing resolver, shared with `composed_seam_test.dart`
// so the reader-only cases and the composed-stack cases cannot drift into
// judging different fixtures.
import 'support/recording_backend.dart';

final DateTime to = DateTime.utc(2026, 9, 3, 12);
final DateTime from = DateTime.utc(2026, 9, 3, 11);

void main() {
  late RecordingBackend backend;
  late Database db;
  late TimescaleReader reader;

  setUp(() {
    backend = RecordingBackend();
    // `Database`'s constructor starts a 500 ms flush timer before the caller
    // can say a word (`database.dart:503`), so every test that wraps a
    // backend closes it — the caution `fake_write_backend.dart` inherits.
    db = Database(backend);
    reader = TimescaleReader(database: () => db, resolver: const OneSeries());
    addTearDown(db.close);
  });

  group('the belt: a name the plan does not know never reaches a statement',
      () {
    test('a hostile table name is refused and no SQL is built', () async {
      await expectLater(
          reader.queryTimeseriesData('pg_catalog.pg_authid', to),
          throwsA(isA<UnknownSeries>()));

      expect(backend.touchedSql, isFalse,
          reason: 'the resolver is the only thing between a client string '
              'and a FROM clause, so a refusal that happens after the '
              'statement is built is not a guard against it');
    });

    test('the same holds on all three methods', () async {
      await expectLater(reader.queryTimeseriesData('nope', to),
          throwsA(isA<UnknownSeries>()));
      await expectLater(reader.queryTimeseriesDataMultiple(['nope'], to),
          throwsA(isA<UnknownSeries>()));
      await expectLater(
          reader.queryTimeseriesDataDownsampled('nope', from, to),
          throwsA(isA<UnknownSeries>()));

      expect(backend.touchedSql, isFalse,
          reason: 'a filter fitted to the single-series path and forgotten '
              'on the other two hands the historian to the next chart');
    });

    test('one bad name in a batch refuses the batch', () async {
      await expectLater(
          reader.queryTimeseriesDataMultiple(['Line1.Motor1', 'nope'], to),
          throwsA(isA<UnknownSeries>()));

      expect(backend.touchedSql, isFalse,
          reason: 'refusing after the good names have been queried would '
              'have run the statement this belt exists to prevent, and the '
              'refusal would be claiming "no effect" untruthfully');
    });

    test('a malformed name throws a FormatException, not UnknownSeries',
        () async {
      await expectLater(
          reader.queryTimeseriesData('a:b:c', to), throwsFormatException,
          reason: '"you spelled it wrong" and "there is no such series" are '
              'two different facts');
      expect(backend.touchedSql, isFalse);
    });

    test('an orderBy outside the two-value allow-list is refused', () async {
      await expectLater(
          reader.queryTimeseriesData('Line1.Motor1', to,
              orderBy: 'time ASC, (SELECT 1)'),
          throwsA(isA<UnsupportedOrdering>()));
      await expectLater(
          reader.queryTimeseriesData('Line1.Motor1', to, orderBy: 'value DESC'),
          throwsA(isA<UnsupportedOrdering>()));

      expect(backend.touchedSql, isFalse,
          reason: 'the handler allow-lists this too (10-03). Two belts, and '
              'this is the last one before the fragment is concatenated into '
              'an ORDER BY clause — a caller that reaches the reader without '
              'passing the handler (a contract leg, an embedder) gets the '
              'same answer');
    });

    test('both accepted orderings reach the source verbatim', () async {
      backend.rows = [
        {'value': 1, 'time': to}
      ];
      await reader.queryTimeseriesData('Line1.Motor1', to, orderBy: 'time ASC');
      await reader.queryTimeseriesData('Line1.Motor1', to,
          orderBy: 'time DESC');

      expect(backend.windowQueries, hasLength(2));
      expect(backend.windowQueries[0], contains('ORDER BY time ASC'));
      expect(backend.windowQueries[1], contains('ORDER BY time DESC'),
          reason: 'the anti-vacuity arm: a belt that refused everything '
              'would pass every refusal case above');
    });
  });

  group('the member projection is a SELECT, not a fetch-then-filter', () {
    setUp(() {
      backend.columns = <String, String>{
        'speed': 'double precision',
        'current': 'double precision',
        'temp': 'double precision',
      };
      backend.rows = [
        {'speed': 47.5, 'time': to}
      ];
    });

    test('the executed query names the member column and time, nothing else',
        () async {
      final samples = await reader.queryTimeseriesData(
          'Line1.Motor1:speed', to,
          from: from);

      expect(samples.single.value, 47.5);
      final sql = backend.windowQueries.single;
      expect(sql, contains('SELECT "speed", "time"'),
          reason: 'ruling 2 is "bytes proportional to the chart\'s ask". '
              'Fetching every member and discarding all but one produces the '
              'same output as projecting, so the output cannot tell them '
              'apart — the column list is the only place the difference is '
              'visible, and it is the whole point');
      expect(sql, isNot(contains('current')),
          reason: 'and the members that were not asked for do not appear');
    });

    test('a member the table does not have is refused, naming what it has',
        () async {
      await expectLater(
          reader.queryTimeseriesData('Line1.Motor1:torque', to),
          throwsA(isA<UnknownSeriesMember>().having((e) => e.toString(),
              'message', allOf(contains('torque'), contains('speed')))));

      expect(backend.tableQueries, isEmpty,
          reason: 'a member name is a client-supplied string that would be '
              'concatenated into a select list; it is checked against the '
              'table\'s real columns before anything is built');
    });

    test('an unaddressed struct is a refusal naming its members', () async {
      await expectLater(
          reader.queryTimeseriesData('Line1.Motor1', to),
          throwsA(isA<StructSeriesUnaddressed>().having(
              (e) => e.toString(),
              'message',
              allOf(contains('speed'), contains('current'),
                  contains('temp')))));

      expect(backend.tableQueries, isEmpty,
          reason: 'the client decodes every sample as TimeseriesData<num> '
              '(client_sub_apis.dart:257). A Map on that wire is a CastError '
              'at the panel, which arrives as "the chart is broken" rather '
              'than as "you did not say which member"');
    });
  });

  group('a scalar table is unaffected', () {
    test('the bare series takes the same bounded statement, naming "value"',
        () async {
      backend.rows = [
        {'value': 7, 'time': to}
      ];
      final samples = await reader.queryTimeseriesData('Line1.Motor1', to);

      expect(samples.single.value, 7);
      expect(samples.single.time.isUtc, isTrue);
      expect(backend.windowQueries.single, contains('SELECT "value", "time"'),
          reason: 'ONE spelling, not two. Until 10-10 the scalar path '
              'delegated to Database.queryTimeseriesData and the member path '
              'spelled its own query, so the shapes were already written '
              'twice; the row ceiling needs a LIMIT and the shipped method '
              'has no parameter for one (and tfc_dart is not this phase\'s to '
              'change), so both paths now take the reader\'s own statement');
      expect(backend.tableQueries, isEmpty,
          reason: 'and nothing reaches AppDatabase.tableQuery, which cannot '
              'carry a LIMIT — a bound that one path can bypass is not a '
              'bound');
    });

    test('every window query carries LIMIT maxRows + 1, and nothing else does',
        () async {
      backend.rows = [
        {'value': 7, 'time': to}
      ];
      final bounded = TimescaleReader(
          database: () => db,
          resolver: const OneSeries(),
          limits: ReadLimits(maxTimeseriesRows: 7));

      await bounded.queryTimeseriesData('Line1.Motor1', to, from: from);

      expect(backend.windowQueries.single, contains('LIMIT 8'),
          reason: 'the detection is LIMIT n + 1: the extra row is how the '
              'reader learns the answer is over the cap WITHOUT building it. '
              'Counting first with a second query would double the work and '
              'race the writer; fetching everything and measuring afterwards '
              'would have the rows in memory already, which is the failure '
              'the send buffer is downstream of');
    });

    test('a boolean column charts as 1 and 0', () async {
      backend.columns = <String, String>{'value': 'boolean'};
      backend.rows = [
        {'value': true, 'time': to},
        {'value': false, 'time': to.add(const Duration(seconds: 1))},
      ];
      final samples = await reader.queryTimeseriesData('Line1.Motor1', to);

      expect(samples.map((s) => s.value), [1, 0],
          reason: 'graph.dart:949 already does exactly this at the chart; '
              'doing it here is what keeps the wire\'s sample type num, '
              'which is what the client decodes');
    });

    test('a text column refuses rather than sending an unchartable series',
        () async {
      backend.columns = <String, String>{'value': 'text'};
      backend.rows = [
        {'value': 'RUNNING', 'time': to}
      ];

      await expectLater(reader.queryTimeseriesData('Line1.Motor1', to),
          throwsA(isA<SeriesNotNumeric>()));
    });
  });

  group('the catalogue is asked about one schema', () {
    // 10-REVIEW WR-03. The statements built from the catalogue answer name the
    // table UNQUALIFIED, so they resolve through search_path — and without a
    // table_schema predicate the probe matched the name in every schema the
    // role can see and returned the UNION of their columns.
    test('the probe pins the schema the statements resolve to', () async {
      backend.rows = [
        {'value': 7, 'time': to}
      ];
      await reader.queryTimeseriesData('Line1.Motor1', to);

      final probe = backend.statements
          .firstWhere((s) => s.contains('information_schema.columns'));

      expect(probe, contains('table_schema = current_schema()'),
          reason: 'a staging schema, a timescaledb_internal chunk view, a '
              'per-tenant schema or an archive copy of the same table is '
              'enough, and all three consequences are silent: a struct read '
              'as a scalar, UnknownSeriesMember not raised (so a permanent '
              'failure goes out as retryable -32011), and SeriesTableMissing '
              'not raised for a table that is not there');
      expect(probe, isNot(contains("'public'")),
          reason: 'current_schema() and not a literal: what this has to match '
              'is wherever the unqualified statements resolve, which is the '
              'deployment\'s business and not this file\'s');
    });
  });

  group('every refusal carries its own disposition to the wire', () {
    // One instance of every member of the sealed family, so the switch that
    // decides `retryable` is exercised on all of them rather than on the one
    // a passing test happened to construct. Adding a subclass makes the switch
    // in `timescale_reader.dart` a compile error; this is the runtime half —
    // that the bit each arm answers is the right bit.
    final family = <TimeseriesReadRefusal, bool>{
      HistorianUnavailable(): true,
      UnknownSeries('Line1.Nope'): false,
      StructSeriesUnaddressed('Line1.Motor2', ['speed', 'temp']): false,
      UnknownSeriesMember('Line1.Motor2', 'torque', ['speed']): false,
      SeriesNotNumeric('Line1.State', 'text'): false,
      UnsupportedOrdering('value DESC'): false,
      SeriesTableMissing('Line1.Ghost', 'gw_gone'): false,
    };

    test('exactly one of them is worth retrying', () {
      expect(
          {
            for (final entry in family.entries)
              entry.key.runtimeType.toString(): entry.key.retryable,
          },
          {
            for (final entry in family.entries)
              entry.key.runtimeType.toString(): entry.value,
          },
          reason: 'the disposition is what `data_handlers.dart` maps on: false '
              'becomes INVALID_PARAMS and true is left to the catch-all\'s '
              'handlerFailed (-32011), which the wire documents as possibly '
              'transient. Getting one of these backwards is either a panel '
              'retrying forever something no retry can fix, or a panel told '
              'its perfectly good query was malformed because the database '
              'bounced');
      expect(family.values.where((r) => r).length, 1,
          reason: 'and the anti-vacuity arm: a family that answered the same '
              'bit for everything would pass a map comparison built from '
              'itself, but not this');
    });

    test('all of them reach the handler as a SourceRefusal', () {
      expect(family.keys, everyElement(isA<SourceRefusal>()),
          reason: 'the interface is the only thing tfc_relay_server can name: '
              'this family is declared here and the dependency edge runs '
              'local -> server, which is why 10-07, 10-08 and 10-09 each '
              'flagged the -32011 mapping and none of them could close it');
    });

    test('a DownsampleUnbounded is permanent whichever condition fired',
        () async {
      // Built through the reader rather than by hand: the three factories are
      // private, which is deliberate — the conditions are decided in one place
      // and a case constructing one directly would be asserting its own
      // arithmetic.
      backend.rows = [
        {'value': 7, 'time': to}
      ];
      final refusals = <DownsampleUnbounded>[];
      for (final ask in <Future<void> Function()>[
        () => reader.queryTimeseriesDataDownsampled('Line1.Motor1', to, to),
        () => reader.queryTimeseriesDataDownsampled('Line1.Motor1', from, to,
            maxPoints: 2),
      ]) {
        try {
          await ask();
        } on DownsampleUnbounded catch (e) {
          refusals.add(e);
        }
      }

      expect(refusals.map((r) => r.condition), [
        DownsampleFallback.zeroWidthWindow,
        DownsampleFallback.tooFewPoints,
      ]);
      expect(refusals.map((r) => r.retryable), everyElement(isFalse),
          reason: 'asking for zero buckets again produces zero buckets again. '
              'These are the two conditions reachable without a database, and '
              'the other two are covered in read_limits_test.dart\'s db lane');
    });
  });

  group('the composer answers a reader instead of throwing', () {
    LocalStateMan plant({TimeseriesApi? timeseries}) {
      final link = FakeUpstreamLink(alias: 'plant');
      final man = LocalStateMan(
        links: [link],
        router: KeyRouter.overLinks([link],
            mappings: KeyMappings(nodes: <String, KeyMappingEntry>{})),
        timeseries: timeseries,
      );
      addTearDown(man.dispose);
      return man;
    }

    test('LocalStateMan.timeseries is the reader it was composed with', () {
      final man = plant(timeseries: reader);

      expect(identical(man.timeseries, reader), isTrue,
          reason: 'the same instance every time it is asked for, like '
              '`browse`: a getter that rebuilt would throw away whatever the '
              'composition wired');
    });

    test('a gateway with no historian says so, and does not pretend', () {
      final man = plant();

      expect(() => man.timeseries, throwsA(isA<StateError>()),
          reason: 'a gateway with no `collection:` block constructs no '
              'database object at all (8b-01\'s deliberate two-field act), '
              'so there is nothing to read from. An empty reader would draw '
              'every chart flat forever and nothing anywhere would say why — '
              'and it is NOT an UnimplementedError either, because the '
              'member is implemented and this is a deployment fact');
      expect(() => man.timeseries, isNot(throwsUnimplementedError),
          reason: 'the ledger in freeze_test.dart drops from three to two in '
              'the same commit; an UnimplementedError here would mean the '
              'member is still owed, and it is not');
    });
  });

  group('without a database', () {
    test('the reader says so, and says it is worth retrying', () async {
      final orphan =
          TimescaleReader(database: () => null, resolver: const OneSeries());

      await expectLater(orphan.queryTimeseriesData('Line1.Motor1', to),
          throwsA(isA<HistorianUnavailable>()),
          reason: 'the sink connects in the background and the gateway does '
              'not wait for it (WR-03). A query in that window is retryable '
              'and must not be a refusal or a hang');
    });
  });
}

/// **The composition that ships, assembled.** Server, policy decorator, a
/// PREFIXING resolver, and the real [TimescaleReader] behind a real
/// `LocalStateMan`, over a real socket.
///
/// ## Why this file exists
///
/// 10-REVIEW's answer to question 1 counted five contract legs and found that
/// exactly one composition had never been assembled by anything — and that it
/// was the only one that ships:
///
/// | Leg | Source under the checks | Resolver | Policy |
/// |---|---|---|---|
/// | `fake_contract_test.dart` | `FakeStateMan` | — | no |
/// | `channel_full_contract_test.dart` | `FakeStateMan` | — | no |
/// | `tfc_relay_server/test/ws_contract_test.dart` | `FakeStateMan` | identity | yes |
/// | `tfc_relay_client/test/contract/ws_contract_test.dart` | `FakeStateMan` | identity | yes |
/// | `contract_db_test.dart` | **real reader/store** | prefixing | **no** |
///
/// Every leg with the policy uses a resolver that answers `table == series`,
/// which makes a *double* resolution idempotent and therefore invisible; the
/// one non-identity resolver in the suite runs in the leg with no policy. CR-01
/// lived in that hole for the whole phase: `_PolicyTimeseries` resolved the
/// wire name into a **physical table** and handed that down, and
/// `TimescaleReader` parsed its argument as a **wire name** and resolved it
/// again. Against the deployed `gw_` prefix the second lookup missed and every
/// timeseries request over the pipe answered `UnknownSeries`, naming a table
/// the caller never sent.
///
/// So the subject here is not a method. It is the **seam**: what one layer
/// hands the next, measured through the whole stack rather than at either end.
/// [OneSeries] is what makes it visible — the fixture resolver whose table is
/// `gw_Line1.Motor1` while its series is `Line1.Motor1`, shared with
/// `timescale_reader_test.dart` so the two files cannot drift into judging
/// different mappings.
///
/// ## Why not a sixth contract leg
///
/// A sixth leg would need a TimescaleDB and would therefore live behind the
/// `db` tag, which is excluded from the default lane on three of the four CI
/// platforms — and CR-01 is not a property of Postgres. What the defect needs
/// is the *hand-off*, and [RecordingBackend] shows the hand-off exactly: the
/// SQL the reader built, against the table it chose. The rows-come-back half is
/// `contract_db_test.dart`'s and stays there.
///
/// ## Why the socket
///
/// `DataHandlers._series` resolves the name a third time (10-REVIEW IN-03), and
/// `RelaySession` is what builds the `PolicyStateMan` a panel actually talks
/// through. Composing the decorator by hand would judge a second object built
/// the same way rather than the one that ships.
@TestOn('vm')
library;

import 'dart:async';

import 'package:test/test.dart';
// `TimeseriesData` is spelled in both packages and the protocol's is the wire
// one — `contract_db_test.dart:72-75` makes the same hide for the same reason.
import 'package:tfc_dart/core/database.dart' hide TimeseriesData;
import 'package:tfc_relay_client/tfc_relay_client.dart';
import 'package:tfc_relay_local/src/data/timescale_reader.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show StateManApi, TimeseriesData;
import 'package:tfc_relay_server/tfc_relay_server.dart';

import 'support/harnessed_local_state_man.dart';
import 'support/recording_backend.dart';

/// The wire name a panel spells — the plant key, never the physical table.
const String wireSeries = 'Line1.Motor1';

/// What [OneSeries] maps [wireSeries] onto. The `gw_` prefix is
/// `collection_config.dart:148`'s default and therefore every ordinary
/// deployment's shape.
const String physicalTable = 'gw_Line1.Motor1';

final DateTime to = DateTime.utc(2026, 9, 3, 12);
final DateTime from = DateTime.utc(2026, 9, 3, 11);

/// Polls [predicate] until it holds, or fails naming what was waited for.
Future<void> until(bool Function() predicate,
    {required String describe,
    Duration budget = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(budget);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out after ${budget.inSeconds}s waiting for $describe');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late RecordingBackend backend;
  late Database db;
  late StateManApi plant;
  late RelayServer server;
  late RemoteStateMan panel;

  setUp(() async {
    backend = RecordingBackend();
    // `Database`'s constructor starts a 500 ms flush timer before the caller
    // can say a word (`database.dart:503`), so every test that wraps a backend
    // closes it.
    db = Database(backend);
    addTearDown(db.close);

    // The real reader, over the real `LocalStateMan` seam
    // (`local_state_man.dart:1407`) — not a fake timeseries and not the reader
    // called directly.
    plant = buildHarnessedLocalStateMan(
      timeseries:
          TimescaleReader(database: () => db, resolver: const OneSeries()),
    );
    addTearDown(plant.dispose);

    server = RelayServer(
      // **The same instance both layers hold**, exactly as
      // `relay_gateway.dart:89` and `:114` hand one `LateSeriesResolver` to the
      // reader and to `buildGateway`. Two resolvers here would be a fixture
      // that could not reproduce the defect.
      resolver: const OneSeries(),
      api: plant,
      config: ServerConfig(tick: ServerConfig.minTick),
      // Several cases provoke refusals on purpose.
      onError: (_, __, ___) {},
    );
    await server.start();
    addTearDown(server.close);

    panel = RemoteStateMan(
      uri: Uri.parse('ws://127.0.0.1:${server.port}'),
      config: ClientConfig(),
    );
    addTearDown(panel.dispose);
    await until(() => panel.linkState == LinkState.ready,
        describe: 'the panel reaching ready over a real socket');
  });

  /// The window queries the reader built, table name and all.
  List<String> windowQueries() => backend.windowQueries;

  group('the name a panel spells survives the policy seam', () {
    setUp(() {
      backend.rows = [
        {'value': 1423.7, 'time': to},
      ];
    });

    test('a plain series answers its samples, from the prefixed table',
        () async {
      final samples = await panel.timeseries
          .queryTimeseriesData(wireSeries, to, from: from);

      expect(samples, hasLength(1),
          reason: 'this is CR-01. The decorator resolved "$wireSeries" into '
              '"$physicalTable" and handed the TABLE down; the reader parses '
              'its argument as a WIRE NAME and resolved it again, against a '
              'map keyed by plant key — a miss, and therefore UnknownSeries '
              'refused as INVALID_PARAMS naming a table the panel never sent. '
              'Every timeseries request on a prefixed deployment, which is '
              'every ordinary one');
      expect(samples.single.value, 1423.7);

      expect(windowQueries(), hasLength(1));
      expect(windowQueries().single, contains('"$physicalTable"'),
          reason: 'and the single resolution still has to reach the physical '
              'table. A fix that stopped resolving anywhere would pass the '
              'assertion above by reading a table named after a plant key, '
              'which does not exist');
    });

    test('a member address reaches the reader with its member intact',
        () async {
      backend.columns = <String, String>{
        'speed': 'double precision',
        'current': 'double precision',
      };
      backend.rows = [
        {'speed': 47.5, 'time': to},
      ];

      final samples = await panel.timeseries
          .queryTimeseriesData('$wireSeries:speed', to, from: from);

      expect(samples, hasLength(1),
          reason: 'the second half of CR-01, and it does not need the prefix: '
              'the decorator dropped `resolved.member` on the floor, so even '
              'where table == series the reader saw a bare name for a struct '
              'table and refused it as StructSeriesUnaddressed — "Ask for one '
              'member" to a caller that did. This is 10-CONTEXT ruling 2\'s '
              'whole feature and ninety of the plant\'s 140 collected keys');
      expect(samples.single.value, 47.5);

      expect(windowQueries().single, contains('"speed"'),
          reason: 'a member address is a SELECT of one column plus time, not '
              'a fetch of the row followed by a filter — the two are '
              'indistinguishable in the output, which is why the column list '
              'is what is asserted');
      expect(windowQueries().single, isNot(contains('"current"')));
    });

    test('two members of one struct are two different queries, not one',
        () async {
      backend.columns = <String, String>{
        'speed': 'double precision',
        'current': 'double precision',
      };
      backend.rows = [
        {'speed': 47.5, 'current': 3.2, 'time': to},
      ];

      final answered = await panel.timeseries.queryTimeseriesDataMultiple(
          <String>['$wireSeries:speed', '$wireSeries:current'], to,
          from: from);

      expect(answered.keys, containsAll(<String>[
        '$wireSeries:speed',
        '$wireSeries:current',
      ]), reason: 'one entry per requested name, keyed by the name the caller '
          'used');
      expect(windowQueries(), hasLength(2),
          reason: 'the decorator de-duplicated by TABLE, so two member '
              'addresses of one struct collapsed into a single query and the '
              'second member was answered with the first member\'s rows. '
              'De-duplication has to be by the address, not by the table');
      expect(windowQueries().map((q) => q.contains('"speed"')).toList(),
          containsAll(<bool>[true]));
      expect(windowQueries().where((q) => q.contains('"current"')), hasLength(1));
    });

    test('the downsampled method takes the same seam', () async {
      final samples = await panel.timeseries
          .queryTimeseriesDataDownsampled(wireSeries, from, to, maxPoints: 30);

      expect(samples, isA<List<TimeseriesData>>());
      expect(windowQueries().single, contains('"$physicalTable"'),
          reason: 'a fix fitted to queryTimeseriesData and forgotten on the '
              'other two is the shape 10-07 already had to correct once');
    });

  });

  group('the seam does not lose the refusals it is supposed to keep', () {
    test('a series the resolver will not map is still an empty series, and is '
        'still counted', () async {
      final samples = await panel.timeseries
          .queryTimeseriesData('CN09.MOT01.speed', to, from: from);

      expect(samples, isEmpty,
          reason: 'the wire answer for an unmappable series is deliberately '
              'indistinguishable from a series with no samples (T-10-12), and '
              'the fix for CR-01 must not turn it into a refusal on the way '
              'past');
      expect(backend.touchedSql, isFalse,
          reason: 'and it must not cost a round trip either: the round trip '
              'is itself a side channel');
      expect(server.seriesTally.unmappableQueries, 1,
          reason: 'silence outward, a count inward — 10-CONTEXT amendment 6. '
              'A decorator that stopped resolving altogether would answer the '
              'query correctly and leave this at zero');
      expect(server.seriesTally.unmappableNames, contains('CN09.MOT01.speed'));
    });

    test('a series that maps is not counted', () async {
      backend.rows = [
        {'value': 1, 'time': to},
      ];
      await panel.timeseries.queryTimeseriesData(wireSeries, to, from: from);

      expect(server.seriesTally.unmappableQueries, 0,
          reason: 'the anti-vacuity arm for the count above: a tally that rose '
              'on every query would be a tally nobody could read anything out '
              'of');
    });
  });
}

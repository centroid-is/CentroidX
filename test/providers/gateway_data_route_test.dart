@TestOn('vm')

/// The two data surfaces follow the transport, measured with Postgres
/// unreachable.
///
/// The sibling of `gateway_access_route_test.dart`, for the two gaps that file
/// did not cover. Both were the same defect in the same shape, and both were
/// **silent**:
///
///  * **Timeseries.** `TimeseriesKeyTracker.start()` and every chart in the app
///    opened with `db == null → return` over a `databaseProvider` that is null
///    by design on a gateway panel. Charts and trend readouts drew nothing, on
///    a plant that had been recording all week.
///  * **Saved history views.** `savedViewsProvider` answered `[]`. An empty
///    picker on a station whose backend is holding a dozen saved views, with no
///    error, no badge and no line on stderr — character for character the
///    `getRecentAlarms` bug this milestone had already fixed once.
///
/// Every gateway arm runs with `databaseProvider` overridden to **null** and,
/// separately, to **throwing** — `gateway_access_route_test.dart`'s discipline
/// and its reason: *a route that exists will be taken*, so the local route has
/// to be provably unavailable rather than merely unused. A provider can be
/// null-safe and still propagate an exception from a `watch` it did not need.
///
/// The far end is `test/helpers/scripted_gateway.dart` on a real loopback
/// socket, for that file's stated reason: the app cannot fake a
/// `RemoteStateMan` connection, it can only make one. Every arm is a plain
/// `test()`, never a widget test — the widget binding's fake-async zone will
/// not pump a real socket's completions.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/gateway_config.dart';
import 'package:tfc/core/timeseries_source.dart';
import 'package:tfc/pages/history_view.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/collector.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/providers/timeseries_source.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/database.dart' show Database;
import 'package:tfc_dart/core/database_drift.dart' show AppDatabase;
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart'
    show defaultPageSubscription;
// `PreferencesApi` is spelled in both packages; this file wants `tfc_dart`'s.
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    hide PreferencesApi;

import '../helpers/scripted_gateway.dart';
import '../helpers/test_helpers.dart';

/// The gateway's `ServerErrorCodes.forbidden`. A literal, driven from the far
/// side of the boundary, exactly as `gateway_access_route_test.dart` spells it.
const int _forbidden = -32005;

/// The gateway's `ServerErrorCodes.handlerFailed` — what a read that could not
/// be served comes back under.
const int _handlerFailed = -32011;

/// This station's mapping. It names [kScriptedSeededKey] because
/// `GatewayStateMan` fixes the client's subscription set from the mapping at
/// construction.
final KeyMappings _mappings = KeyMappings(nodes: {
  kScriptedSeededKey: KeyMappingEntry(
      opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'Connected')),
});

typedef _Answer = void Function(ScriptedLink link, int id);

/// A gateway that completes the handshake, seeds the subscription snapshot,
/// and answers from [answers]. An unscripted request gets **no answer**, so an
/// arm that forgot to script one fails on its own deadline rather than passing
/// on a default.
Future<ScriptedGateway> _gateway(Map<String, _Answer> answers) =>
    ScriptedGateway.start((link, method, id) {
      if (method == Methods.hello) return link.hello(id);
      if (method == Methods.subscribe) {
        return link.snapshot(id, defaultPageSubscription);
      }
      answers[method]?.call(link, id);
    });

/// A JSON-RPC error frame. [ScriptedLink.error] already writes one; this is
/// the same thing spelled once so an arm reads as the refusal it is about.
void _refuse(ScriptedLink link, int id, int code, String message) =>
    link.socket.add(jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'error': {'code': code, 'message': message},
    }));

final DateTime _t0 = DateTime.utc(2026, 9, 9, 6);

/// What the gateway serves for the happy path of both surfaces.
Map<String, _Answer> _servedData() => {
      DataServiceMethods.timeseriesQuery: (link, id) => link.result(id, [
            TimeseriesData<num>(41, _t0).toJson(),
            TimeseriesData<num>(42, _t0.add(const Duration(minutes: 1)))
                .toJson(),
          ]),
      DataServiceMethods.timeseriesQueryDownsampled: (link, id) =>
          link.result(id, [TimeseriesData<num>(7, _t0).toJson()]),
      DataServiceMethods.historySelectViews: (link, id) => link.result(id, [
            HistoryViewRecord(id: 4, name: 'Vakt 1', createdAt: _t0).toJson(),
            HistoryViewRecord(id: 2, name: 'Aflóð', createdAt: _t0).toJson(),
          ]),
      DataServiceMethods.historyGetKeyNames: (link, id) =>
          link.result(id, ['ST101.CN01.MOT01', 'ST101.CN02.MOT01']),
      DataServiceMethods.historyListPeriods: (link, id) => link.result(id, [
            HistoryViewPeriodRecord(
              id: 9,
              viewId: 4,
              name: 'Vaktaskipti',
              startAt: _t0,
              endAt: _t0.add(const Duration(hours: 8)),
              createdAt: _t0,
            ).toJson(),
          ]),
      DataServiceMethods.historyRetentionHorizon: (link, id) =>
          link.result(id, _t0.millisecondsSinceEpoch),
      DataServiceMethods.historyDeleteView: (link, id) => link.result(id, null),
      DataServiceMethods.historyCreateView: (link, id) => link.result(id, 11),
      DataServiceMethods.historyAddPeriod: (link, id) => link.result(id, 12),
      DataServiceMethods.historyDeletePeriod: (link, id) =>
          link.result(id, null),
      DataServiceMethods.historyUpdateView: (link, id) =>
          link.result(id, null),
    };

/// The full provider stack a gateway panel runs, with nothing about the
/// transport faked. [database] is a parameter because this file's whole point
/// is what happens when it is null and when it throws.
Future<ProviderContainer> _gatewayPanel(
  ScriptedGateway gateway, {
  required Future<Database?> Function() database,
}) async {
  final store = InMemoryPreferences();
  await writeGatewayConfig(
      store,
      GatewayConfig(
          mode: TransportMode.gateway, url: gateway.uri.toString()));
  final container = ProviderContainer(
    overrides: [
      preferencesProvider.overrideWith((ref) => createTestPreferences(
            keyMappings: _mappings,
            stateManConfig: StateManConfig(opcua: const []),
          )),
      systemPreferencesProvider.overrideWith((ref) => createTestPreferences(
            keyMappings: _mappings,
            stateManConfig: StateManConfig(opcua: const []),
          )),
      localPreferencesProvider.overrideWithValue(store),
      databaseProvider.overrideWith((ref) => database()),
      stationNameProvider.overrideWithValue('phase18-panel'),
      collectorProvider.overrideWith((ref) async => null),
      // A gateway station building a *local* StateMan is a defect in itself.
      stateManFactoryProvider.overrideWithValue(({
        required StateManConfig config,
        required KeyMappings keyMappings,
        List<DeviceClient> deviceClients = const [],
      }) async =>
          throw StateError('local StateMan construction reached')),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// A direct-mode container: no gateway row, so the config falls back to
/// direct and the transport plumbing is never touched.
ProviderContainer _directPanel(
    {required Future<Database?> Function() database}) {
  final container = ProviderContainer(
    overrides: [
      localPreferencesProvider.overrideWithValue(InMemoryPreferences()),
      databaseProvider.overrideWith((ref) => database()),
      stationNameProvider.overrideWithValue('phase18-panel'),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// An in-memory database whose teardown is registered at acquisition.
Database _testDatabase() {
  final appDb = AppDatabase.inMemoryForTest();
  final db = Database(appDb);
  addTearDown(() async {
    await db.dispose();
    await appDb.close();
  });
  return db;
}

/// "The database is down": not null — a route that *exists* and *throws*.
Future<Database?> _throwingDatabase() async =>
    throw StateError('postgres unreachable: connection refused');

/// A StateMan with **no relay client behind it** — the defect state.
class _ClientlessStateMan extends Fake implements StateMan {
  @override
  String resolveKey(String key) => key;
}

/// A gateway-mode container whose StateMan has no relay client, plus a
/// perfectly working database sitting right there.
///
/// The point of the second half: the local route is *available*, so a provider
/// that quietly fell back to it would answer, and answer plausibly. That is
/// the failure this pair of arms exists to refuse.
Future<ProviderContainer> _gatewayPanelWithoutAClient() async {
  final store = InMemoryPreferences();
  await writeGatewayConfig(
      store,
      const GatewayConfig(
          mode: TransportMode.gateway, url: 'wss://gateway.invalid:9443'));
  final container = ProviderContainer(
    overrides: [
      localPreferencesProvider.overrideWithValue(store),
      databaseProvider.overrideWith((ref) async => _testDatabase()),
      stationNameProvider.overrideWithValue('phase18-panel'),
      stateManProvider.overrideWith((ref) async => _ClientlessStateMan()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  // ---------------------------------------------------------------------------
  // Gap A — timeseries
  // ---------------------------------------------------------------------------

  group('gap A: timeseries over the relay, with NO database', () {
    test('arm 1: the source is non-null and answers what the gateway served',
        () async {
      final gateway = await _gateway(_servedData());
      final container =
          await _gatewayPanel(gateway, database: () async => null);

      final source = await container.read(timeseriesSourceProvider.future);
      expect(source, isNotNull,
          reason: 'a null source is what every chart in the app reads as "no '
              'data yet", on a panel whose gateway is serving history right '
              'now');
      final samples = await source!
          .queryTimeseriesData('ST101.CN01.MOT01', _t0, from: _t0);
      expect(samples.map((s) => s.value), [41, 42]);
      expect(samples.first.time, _t0);
    });

    test('arm 2: the same, with the database THROWING rather than absent',
        () async {
      final gateway = await _gateway(_servedData());
      final container =
          await _gatewayPanel(gateway, database: _throwingDatabase);

      final source = await container.read(timeseriesSourceProvider.future);
      final samples =
          await source!.queryTimeseriesDataDownsampled('a', _t0, _t0);

      expect(samples.single.value, 7,
          reason: 'the gateway branch must not watch databaseProvider at all. '
              'A provider that touches it is null-safe and still dies on a '
              'station whose Postgres is refusing connections — which is the '
              'state a gateway panel is permanently in');
    });

    test('arm 3: a gateway refusal throws — it is never an empty series',
        () async {
      final gateway = await _gateway({
        ...  _servedData(),
        DataServiceMethods.timeseriesQuery: (link, id) => _refuse(link, id,
            _handlerFailed, 'the historian could not answer this window'),
      });
      final container =
          await _gatewayPanel(gateway, database: () async => null);
      final source = await container.read(timeseriesSourceProvider.future);

      await expectLater(
        source!.queryTimeseriesData('a', _t0),
        throwsA(anything),
        reason: 'an empty list is what a quiet tag looks like. Answering one '
            'for a failed read reports a fact about the wire as a fact about '
            'the factory',
      );
    });

    test('arm 4: a policy refusal reaches the caller as a refusal', () async {
      final gateway = await _gateway({
        ..._servedData(),
        DataServiceMethods.timeseriesQuery: (link, id) => _refuse(link, id,
            _forbidden, 'a permission is missing, so this was refused'),
      });
      final container =
          await _gatewayPanel(gateway, database: () async => null);
      final source = await container.read(timeseriesSourceProvider.future);

      await expectLater(source!.queryTimeseriesData('a', _t0),
          throwsA(anything),
          reason: 'the check is server-side — PolicyStateMan._PolicyTimeseries '
              '— and the panel\'s job is to not swallow its verdict');
    });

    test('arm 5: direct mode is unchanged — a database yields a database '
        'source, and no database yields null', () async {
      final withDb = _directPanel(database: () async => _testDatabase());
      expect(await withDb.read(timeseriesSourceProvider.future),
          isA<DatabaseTimeseriesSource>());

      final without = _directPanel(database: () async => null);
      expect(await without.read(timeseriesSourceProvider.future), isNull,
          reason: 'null keeps its direct-mode meaning exactly: no Postgres '
              'configured, and the boot window before the connection opens. '
              'What it must never mean again is "this panel is a gateway '
              'panel"');
    });
  });

  // ---------------------------------------------------------------------------
  // Both gaps — the refuse-by-name discipline
  // ---------------------------------------------------------------------------

  group('a gateway station whose StateMan has no relay client', () {
    test('timeseriesSourceProvider refuses by name — it does not answer null, '
        'and it does not take the database sitting next to it', () async {
      final container = await _gatewayPanelWithoutAClient();

      await expectLater(
        container.read(timeseriesSourceProvider.future),
        throwsA(isA<UnsupportedError>()),
        reason: 'a route that exists will be taken. Null here would put every '
            'chart back on "no data yet" — the exact silence this change '
            'removed — and a fall-through to the working database would put '
            'the local route back on a station that must not have one, where '
            'it would go on answering plausibly for months',
      );
    });

    test('historyViewsProvider refuses by name for the same reason', () async {
      final container = await _gatewayPanelWithoutAClient();

      await expectLater(
        container.read(historyViewsProvider.future),
        throwsA(isA<UnsupportedError>()),
        reason: 'null here is the empty picker again, by a different route',
      );
    });

    test('the refusal names the file to fix, not the exception type', () async {
      final container = await _gatewayPanelWithoutAClient();

      await expectLater(
        container.read(historyViewsProvider.future),
        throwsA(predicate((Object e) =>
            '$e'.contains('lib/providers/state_man.dart') &&
            '$e'.contains('do not fall back to the database'))),
        reason: 'the message is the whole value of refusing rather than '
            'returning: whoever hits it has to be told where the defect is '
            'and what the wrong fix would be',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Gap B — saved history views
  // ---------------------------------------------------------------------------

  group('gap B: saved history views over the relay, with NO database', () {
    test('arm 6: savedViewsProvider answers the gateway\'s views, sorted',
        () async {
      final gateway = await _gateway(_servedData());
      final container =
          await _gatewayPanel(gateway, database: () async => null);

      final views = await container.read(savedViewsProvider.future);

      expect(views, hasLength(2),
          reason: 'this is the gap: the provider used to answer [] here, and '
              'an empty picker on a station with saved views is an empty '
              'answer presented as a fact');
      expect(views.map((v) => v.name), ['Aflóð', 'Vakt 1']);
      expect(views.first.keys, ['ST101.CN01.MOT01', 'ST101.CN02.MOT01']);
    });

    test('arm 7: the same, with the database THROWING rather than absent',
        () async {
      final gateway = await _gateway(_servedData());
      final container =
          await _gatewayPanel(gateway, database: _throwingDatabase);

      final views = await container.read(savedViewsProvider.future);

      expect(views.map((v) => v.name), ['Aflóð', 'Vakt 1']);
    });

    test('arm 8: saved periods and the retention horizon come from the '
        'gateway too', () async {
      final gateway = await _gateway(_servedData());
      final container =
          await _gatewayPanel(gateway, database: () async => null);

      final periods = await container.read(savedPeriodsProvider(4).future);
      expect(periods.single.name, 'Vaktaskipti');
      expect(periods.single.start, _t0);

      expect(await container.read(retentionHorizonProvider.future), _t0,
          reason: 'the horizon is what greys out a saved shift that retention '
              'has already eaten. Answering null on a gateway panel would '
              'mark every saved period as valid, including the ones whose '
              'rows are gone');
    });

    test('arm 9: a failed read throws rather than answering an empty picker',
        () async {
      final gateway = await _gateway({
        ..._servedData(),
        DataServiceMethods.historySelectViews: (link, id) => _refuse(
            link, id, _handlerFailed, 'the view table could not be read'),
      });
      final container =
          await _gatewayPanel(gateway, database: () async => null);

      await expectLater(
        container.read(savedViewsProvider.future),
        throwsA(anything),
        reason: 'an empty list and a failed read are opposite facts and look '
            'identical in a picker. The page renders an error; it must be '
            'given one',
      );
    });

    test('arm 10: the five writes go over the wire, and a gateway refusal '
        'arrives as AccessDenied', () async {
      final gateway = await _gateway({
        ..._servedData(),
        DataServiceMethods.historyDeleteView: (link, id) => _refuse(link, id,
            _forbidden,
            'a permission is missing, so "historyViews.deleteHistoryView" was '
            'refused. Nothing was changed, so this call definitively had no '
            'effect'),
      });
      final container =
          await _gatewayPanel(gateway, database: () async => null);

      final views = (await container.read(historyViewsProvider.future))!;

      // The permitted write reaches the far end and answers its id.
      expect(await views.createHistoryView('Ný sýn', ['a']), 11);

      // The refused one arrives as the exception the page already catches.
      await expectLater(
        views.deleteHistoryView(4),
        throwsA(isA<AccessDenied>()),
        reason: 'the page catches AccessDenied at all five writes and returns '
            'silently, because the shared prompt has already named the missing '
            'permission. A raw RpcException would fall through that catch and '
            'the page would go on to claim the delete landed',
      );
    });

    test('arm 11: direct mode is unchanged — a database yields a store, and '
        'no database yields null', () async {
      final withDb = _directPanel(database: () async => _testDatabase());
      expect(await withDb.read(historyViewsProvider.future), isNotNull);

      final without = _directPanel(database: () async => null);
      expect(await without.read(historyViewsProvider.future), isNull);
      expect(await without.read(savedViewsProvider.future), isEmpty,
          reason: 'direct mode stays behaviourally unchanged: a station with '
              'no database showed an empty picker before this change and '
              'shows one now. The gateway branch is the one that must never '
              'answer empty');
    });
  });
}

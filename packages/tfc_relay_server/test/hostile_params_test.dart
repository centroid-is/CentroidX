@TestOn('vm')

/// The input-validation surface for the timeseries family: what a client may
/// put in each of the seven parameters, and what happens to everything else.
///
/// ## Why this file exists at all
///
/// `TimeseriesApi`'s signatures were frozen verbatim from working code
/// (four then; three since the 2026-09-07 audit cut the count method), and
/// they carry strings that end up inside a SQL statement:
///
///  * `orderBy` reaches
///    `'SELECT $cols FROM "$tableName"$whereClause$orderByClause'`
///    (`database_drift.dart`'s `tableQuery`), unescaped, in a position where a
///    subquery is legal grammar.
///  * `tableName` reached `FROM "$tableName"` in the since-cut
///    `countTimeseriesDataMultiple` (`database.dart`) **with no
///    quote-doubling at all** — while `queryTimeseriesDataDownsampled`, in the
///    same file, does `tableName.replaceAll('"', '""')`. That is one codebase
///    being inconsistent about one hazard, which is the strongest possible
///    argument for not relying on it.
///
/// Mapping those onto the wire without a validation layer ships the
/// `query(sql)` RPC the project forbids, wearing a signature nobody reads as
/// one. So the gateway does not *sanitize* `orderBy` — it **refuses** it. A
/// sanitizer invites the question of whether it is complete; a two-value
/// allow-list does not, and the contract's own fake proves nothing more is
/// asked for: `FakeTimeseries` implements ordering as
/// `_descending(orderBy) ? window.reversed.toList() : window`, which is two
/// values and a default.
///
/// ## The allow-list is in the handler, and that is deliberate
///
/// Not in the database. `tfc_dart`'s database layer is shared with an
/// application that has always passed its own literals, so moving the check
/// down would either change `tfc_dart`'s behaviour for the app or leave the
/// gateway trusting that it did. The gateway does not trust a client-supplied
/// SQL fragment; it refuses one, at the boundary, where the client is.
///
/// ## Every refusal here is pre-effect
///
/// 05-03's discipline: `INVALID_PARAMS` means *no effect*, so every case
/// below asserts the source recorded **zero** calls. That is the assertion
/// that distinguishes a guard from a filter applied to an answer already
/// fetched — and a guard that runs after the query has already run is not a
/// guard against a query.
library;

import 'package:json_rpc_2/error_code.dart' as rpc_error;
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/data_handlers.dart';
import 'package:tfc_relay_server/src/server_config.dart';
import 'package:tfc_stateman_contract/testing/fake_data_services.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';

import 'support/permissive_resolver.dart';

const _series = 'st101_cn01_mot01_setpoint';

final _base = DateTime.utc(2026, 8, 13, 6);

int _ms(DateTime at) => at.millisecondsSinceEpoch;

/// A timeseries source that answers nothing and **records every call**.
///
/// The whole point of the file. A permissive fake would let a refusal that
/// happened *after* the query pass every assertion about the refusal itself,
/// and the property under test is that the query never happened.
///
/// Extends `FakeTimeseries` rather than implementing `TimeseriesApi` because
/// `FakeStateMan` takes the concrete type; all four members are overridden, so
/// nothing of the fake's own behaviour is reachable from here.
final class _RecordingTimeseries extends FakeTimeseries {
  final calls = <String>[];

  @override
  Future<List<TimeseriesData>> queryTimeseriesData(
      String tableName, DateTime to,
      {String? orderBy = 'time ASC', DateTime? from}) async {
    calls.add('queryTimeseriesData($tableName, orderBy: $orderBy)');
    return const [];
  }

  @override
  Future<Map<String, List<TimeseriesData>>> queryTimeseriesDataMultiple(
      List<String> tableNames, DateTime to,
      {String? orderBy = 'time ASC', DateTime? from}) async {
    calls.add(
        'queryTimeseriesDataMultiple($tableNames, orderBy: $orderBy)');
    return const {};
  }

  @override
  Future<List<TimeseriesData>> queryTimeseriesDataDownsampled(
      String tableName, DateTime from, DateTime to,
      {int maxPoints = 1000}) async {
    calls.add('queryTimeseriesDataDownsampled($tableName, $maxPoints)');
    return const [];
  }

}

/// The handlers under test, over a source that records rather than answers.
final class _Kit {
  _Kit(this.handlers, this.source);

  final DataHandlers handlers;
  final _RecordingTimeseries source;

  /// Asserts [ask] was refused, that the refusal is well formed, and — the
  /// property this file exists for — that **nothing was called**.
  Future<rpc.RpcException> refusedPreEffect(
      Future<Object?> Function() ask, String what,
      {required String reason}) async {
    final Object? answered;
    try {
      answered = await ask();
    } on rpc.RpcException catch (error) {
      expect(error.code, rpc_error.INVALID_PARAMS,
          reason: 'a wrong-shaped argument is the caller\'s mistake, not a '
              'handler failure. The difference is whether a panel retries: '
              '-32011 is documented as possibly transient, and $what will '
              'never succeed');
      expect((error.data! as Map)['request'], isA<String>(),
          reason: 'every refusal on this wire carries a pre-substituted '
              'data.request, or RpcException.serialize copies the offending '
              'request into the error and one carrying 1e999 makes the '
              'refusal itself unencodable');
      expect(source.calls, isEmpty,
          reason: '$reason — but the source was called '
              '${source.calls.length} time(s): ${source.calls}. A refusal '
              'that happens after the query has run is not a guard against '
              'the query; it is a filter on its answer, and INVALID_PARAMS '
              'would be claiming "no effect" untruthfully');
      return error;
    }
    fail('$what was answered with $answered instead of refused');
  }
}

_Kit _kit({ServerConfig? config}) {
  final timeseries = _RecordingTimeseries();
  final api = FakeStateMan(timeseries: timeseries);
  addTearDown(api.dispose);
  return _Kit(
      DataHandlers(
          source: api,
          config: config ?? ServerConfig(),
          resolver: const PermissiveSeriesResolver(),
          // This file is about what the timeseries bodies refuse; nothing in
          // it watches preferences, so nothing in it announces.
          notify: (_, __) {}),
      timeseries);
}

rpc.Parameters _params(String method, Map<String, Object?> value) =>
    rpc.Parameters(method, value);

/// Hostile `orderBy` strings, each with what it would have done had it reached
/// `ORDER BY $orderBy`.
///
/// Table-driven rather than eight copies of one case, because the property is
/// about the *shape of the allow-list* and a reader should be able to add a
/// row without reading a body.
const _hostileOrderings = <({String value, String wouldHaveDone})>[
  (
    value: 'time ASC, (SELECT 1)',
    wouldHaveDone: 'appended a subquery to the ORDER BY clause — a subquery '
        'is legal grammar in this position, so this is not an injection that '
        'has to escape a quote first',
  ),
  (
    value: 'time ASC; DROP TABLE gw_st101_cn01_mot01_setpoint',
    wouldHaveDone: 'ended the statement and started a second one',
  ),
  (
    value: 'time ASC, (SELECT value FROM gw_other_series LIMIT 1)',
    wouldHaveDone: 'ordered by a value read out of a *different* series, '
        'which leaks that series one comparison at a time to a caller who may '
        'not see it at all',
  ),
  (
    value: 'time',
    wouldHaveDone: 'ordered ambiguously — the database would pick a '
        'direction and the chart would sometimes draw backwards. It is '
        'refused rather than completed to "time ASC" because completing it '
        'is guessing',
  ),
  (
    value: 'TIME ASC',
    wouldHaveDone: 'passed under a case-insensitive comparison. Case is not '
        'silently normalised here: normalising is a transformation, and a '
        'transformation is the first step of a sanitizer',
  ),
  (
    value: 'time  ASC',
    wouldHaveDone: 'passed under a whitespace-collapsing comparison, for the '
        'same reason',
  ),
  (
    value: '',
    wouldHaveDone: 'produced " ORDER BY " with nothing after it — a syntax '
        'error the client would see as a handler failure and retry',
  ),
  (
    value: 'value DESC',
    wouldHaveDone: 'ordered by the sample rather than by the instant, which '
        'is a legal column and a chart nobody asked for: the line would join '
        'points in value order and draw a sawtooth',
  ),
  (
    value: 'time ASC --',
    wouldHaveDone: 'commented out whatever a later version of the query '
        'appends after the ORDER BY clause',
  ),
];

void main() {
  group('orderBy is two values or it is refused', () {
    for (final hostile in _hostileOrderings) {
      test('`${hostile.value}` is refused before the source is called',
          () async {
        final kit = _kit();

        final error = await kit.refusedPreEffect(
            () => kit.handlers.timeseriesQuery(
                    _params(DataServiceMethods.timeseriesQuery, {
                  'table': _series,
                  'to': _ms(_base),
                  'orderBy': hostile.value,
                })),
            'an orderBy of `${hostile.value}`',
            reason: 'had this reached ORDER BY it would have '
                '${hostile.wouldHaveDone}');

        expect(error.message, contains('time ASC'),
            reason: 'the refusal must name the values that *are* accepted. A '
                'refusal that only says "no" leaves the caller guessing, and '
                'the caller here is a chart widget somebody is porting');
        expect(error.message, contains('time DESC'));
      });
    }

    test('the two accepted values reach the source unchanged', () async {
      final kit = _kit();

      await kit.handlers.timeseriesQuery(
          _params(DataServiceMethods.timeseriesQuery,
              {'table': _series, 'to': _ms(_base), 'orderBy': 'time ASC'}));
      await kit.handlers.timeseriesQuery(
          _params(DataServiceMethods.timeseriesQuery,
              {'table': _series, 'to': _ms(_base), 'orderBy': 'time DESC'}));

      expect(kit.source.calls, [
        'queryTimeseriesData($_series, orderBy: time ASC)',
        'queryTimeseriesData($_series, orderBy: time DESC)',
      ], reason: 'the allow-list must be an allow-list and not a deny-list: '
          'both accepted values pass through verbatim, which is also the '
          'anti-vacuity arm for every refusal above — a guard that refused '
          'everything would satisfy all nine of them');
    });

    test('an absent orderBy is not refused, and is not invented either',
        () async {
      final kit = _kit();

      await kit.handlers.timeseriesQuery(_params(
          DataServiceMethods.timeseriesQuery,
          {'table': _series, 'to': _ms(_base)}));

      expect(kit.source.calls.single, contains('orderBy: null'),
          reason: 'null is a legitimate value — it means "no ordering asked '
              'for" — and the client sends the key even when it is null so '
              'the two are distinguishable on the far side '
              '(`client_sub_apis.dart:203-206`). Substituting a default here '
              'would take that distinction away from the source, which is '
              'where the frozen signature already declares one');
    });

    test('an orderBy that is not a string is refused, not cast', () async {
      final kit = _kit();

      await kit.refusedPreEffect(
          () => kit.handlers.timeseriesQuery(
                  _params(DataServiceMethods.timeseriesQuery, {
                'table': _series,
                'to': _ms(_base),
                'orderBy': 7,
              })),
          'an orderBy of 7',
          reason: 'the port source reads this as `valueOr(null) as String?`, '
              'and a cast error inside a handler is reported as '
              'handlerFailed — a retryable code for a request that cannot '
              'succeed');
    });

    test('the multi-series path refuses the same strings', () async {
      final kit = _kit();

      final error = await kit.refusedPreEffect(
          () => kit.handlers.timeseriesQueryMultiple(
                  _params(DataServiceMethods.timeseriesQueryMultiple, {
                'tables': [_series],
                'to': _ms(_base),
                'orderBy': 'time ASC, (SELECT 1)',
              })),
          'a multi-series query with a hostile orderBy',
          reason: 'the multi-series path builds the same statement, once per '
              'series. A guard on the single path only is a door with one of '
              'its two locks fitted');

      expect(error.message, contains('time ASC'));
    });
  });

  group('the series name is a name, not a fragment', () {
    test('a name with two colons is refused', () async {
      final kit = _kit();

      final error = await kit.refusedPreEffect(
          () => kit.handlers.timeseriesQuery(
                  _params(DataServiceMethods.timeseriesQuery, {
                'table': 'series:member:extra',
                'to': _ms(_base),
              })),
          'a series name selecting a member of a member',
          reason: 'the grammar is `<series>` or `<series>:<member>` '
              '(`series_address.dart`), and a best-effort split answers a '
              'different question than the one asked. Refusing here also '
              'means the string never reaches `FROM "$_series"`, which does '
              'no quote-doubling on the counting path');

      expect(error.message, contains('series:member:extra'),
          reason: 'a *malformed* name may be echoed: "you spelled it wrong" '
              'and "there is no such series" are different facts, and only '
              'the second one would enumerate the historian. This is the one '
              'place the name appears in a refusal, and it appears because '
              'the caller already knows it is not a name');
    });

    test('an empty series name is refused', () async {
      final kit = _kit();

      await kit.refusedPreEffect(
          () => kit.handlers.timeseriesQuery(_params(
              DataServiceMethods.timeseriesQuery,
              {'table': '', 'to': _ms(_base)})),
          'an empty series name',
          reason: 'an empty name interpolates to `FROM ""`');
    });

    test('a trailing colon is refused', () async {
      final kit = _kit();

      await kit.refusedPreEffect(
          () => kit.handlers.timeseriesQuery(_params(
              DataServiceMethods.timeseriesQuery,
              {'table': 'series:', 'to': _ms(_base)})),
          'a series name that ends mid-selection',
          reason: 'a colon selects a member, so this is a caller that meant '
              'to select one and did not; answering the whole series instead '
              'ships exactly the members 10-CONTEXT ruling 2 refuses to ship');
    });

    test('a malformed name inside the multi-series list is refused, and the '
        'whole call is', () async {
      final kit = _kit();

      await kit.refusedPreEffect(
          () => kit.handlers.timeseriesQueryMultiple(
                  _params(DataServiceMethods.timeseriesQueryMultiple, {
                'tables': [_series, 'a:b:c'],
                'to': _ms(_base),
              })),
          'a multi-series query with one malformed name',
          reason: 'the whole call, not the one entry: unlike readMany — whose '
              'per-key rejection map exists because a page config carries '
              '~1500 hand-edited keys and one typo must not cost the call — '
              'a chart asks for the four series it is drawing, and a '
              'malformed one is a bug in the chart rather than a stale tag');
    });

    test('a well-formed member address is accepted', () async {
      final kit = _kit();

      await kit.handlers.timeseriesQuery(_params(
          DataServiceMethods.timeseriesQuery,
          {'table': '$_series:speed', 'to': _ms(_base)}));

      expect(kit.source.calls.single, contains('$_series:speed'),
          reason: 'the anti-vacuity arm for the three refusals above: '
              '`<series>:<member>` is the addressing 10-CONTEXT ruling 2 '
              'settled on, and a guard that refused it would refuse every '
              'struct chart in the plant');
    });

    // 10-REVIEW WR-04. Nothing bounded a series name's LENGTH: the frame cap
    // is 1 MiB, maxKeysPerSubscribe is 2000, and SeriesMappingTally bounded
    // how many novel names it remembered but not how long each was.
    test('a name longer than the bound is refused, and is not echoed',
        () async {
      final kit = _kit();
      final long = 'A' * (DataHandlers.maxSeriesNameChars + 1);

      final error = await kit.refusedPreEffect(
          () => kit.handlers.timeseriesQuery(
                  _params(DataServiceMethods.timeseriesQuery, {
                'table': long,
                'to': _ms(_base),
              })),
          'a series name of ${long.length} characters',
          reason: 'unbounded, each of the tally\'s 64 retained names could be '
              'most of a megabyte and none of them is ever pruned — memory '
              'pinned for the life of the process by one authenticated '
              'station, plus 64 error-reporter lines of the same size');

      expect(error.message, contains('${long.length}'),
          reason: 'the length is the actionable fact');
      expect(error.message, isNot(contains(long)),
          reason: 'and the name itself must NOT be echoed. Echoing it is the '
              'thing being prevented, one layer up: a refusal carrying the '
              'megabyte is the megabyte, in the log and in the frame');
    });

    test('a name at exactly the bound is accepted', () async {
      // The boundary in the direction that matters: `>=` here would refuse a
      // legitimate name and the failure would look like a broken chart.
      final kit = _kit();
      final atBound = 'A' * DataHandlers.maxSeriesNameChars;

      await kit.handlers.timeseriesQuery(_params(
          DataServiceMethods.timeseriesQuery,
          {'table': atBound, 'to': _ms(_base)}));

      expect(kit.source.calls.single, contains(atBound));
    });
  });

  group('tables is bounded the same three ways readMany is', () {
    test('a tables that is not a list is refused', () async {
      final kit = _kit();

      await kit.refusedPreEffect(
          () => kit.handlers.timeseriesQueryMultiple(_params(
              DataServiceMethods.timeseriesQueryMultiple,
              {'tables': _series, 'to': _ms(_base)})),
          'a tables that is a bare string',
          reason: 'a bare string is iterable in some languages and not this '
              'one; the refusal is what stops it becoming a list of '
              'characters somewhere');
    });

    test('an empty tables is refused', () async {
      final kit = _kit();

      await kit.refusedPreEffect(
          () => kit.handlers.timeseriesQueryMultiple(_params(
              DataServiceMethods.timeseriesQueryMultiple,
              {'tables': <String>[], 'to': _ms(_base)})),
          'a request for no series at all',
          reason: 'a request for nothing is a round trip the client then '
              'waits on');
    });

    test('a tables over maxKeysPerSubscribe is refused, naming the limit',
        () async {
      final config = ServerConfig(maxKeysPerSubscribe: 4);
      final kit = _kit(config: config);

      final error = await kit.refusedPreEffect(
          () => kit.handlers.timeseriesQueryMultiple(
                  _params(DataServiceMethods.timeseriesQueryMultiple, {
                'tables': [for (var i = 0; i < 5; i++) '${_series}_$i'],
                'to': _ms(_base),
              })),
          'five series against a limit of four',
          reason: 'breadth on one round trip is the existing per-request '
              'bound, and reusing maxKeysPerSubscribe is deliberate: a second '
              'number for the same hazard is a second number to keep in step');

      expect(error.message, contains('4'),
          reason: 'the refusal names the limit, so the caller can split the '
              'request without reading this server\'s source');
    });
  });

  group('the three integers are bounded, and the bounds are on ServerConfig',
      () {
    test('a maxPoints below the floor is refused, citing the fallback',
        () async {
      final kit = _kit();

      final error = await kit.refusedPreEffect(
          () => kit.handlers.timeseriesQueryDownsampled(
                  _params(DataServiceMethods.timeseriesQueryDownsampled, {
                'table': _series,
                'from': _ms(_base),
                'to': _ms(_base.add(const Duration(days: 31))),
                'maxPoints': 2,
              })),
          'a maxPoints of 2',
          reason: 'this is the case that matters most and it is not obvious: '
              '`queryTimeseriesDataDownsampled` computes '
              '`numBuckets = (maxPoints / 3).floor()` and, when that is zero, '
              '**silently falls back to the unbounded raw query** '
              '(`database.dart`). A maxPoints of 2 is therefore a month of '
              'one-second samples wearing the bounded method\'s name — '
              'refusing it at the wire is what keeps the one bounded method '
              'bounded');

      expect(error.message, contains('${ServerConfig.minTimeseriesPoints}'));
    });

    test('a maxPoints above the ceiling is refused', () async {
      final kit = _kit();

      final error = await kit.refusedPreEffect(
          () => kit.handlers.timeseriesQueryDownsampled(
                  _params(DataServiceMethods.timeseriesQueryDownsampled, {
                'table': _series,
                'from': _ms(_base),
                'to': _ms(_base.add(const Duration(days: 31))),
                'maxPoints': 1_000_000,
              })),
          'a maxPoints of a million',
          reason: 'a chart has hundreds of pixels '
              '(`state_man_api.dart:277-283`), so a six-figure maxPoints is '
              'not a chart — it is a raw query wearing the bounded method\'s '
              'name, which is the same hazard as the floor from the other '
              'side');

      expect(error.message, contains('${ServerConfig().maxTimeseriesPoints}'));
    });

    test('maxPoints at each end of the band is accepted', () async {
      final kit = _kit();
      final config = ServerConfig();

      for (final maxPoints in [
        ServerConfig.minTimeseriesPoints,
        config.maxTimeseriesPoints,
      ]) {
        await kit.handlers.timeseriesQueryDownsampled(
            _params(DataServiceMethods.timeseriesQueryDownsampled, {
          'table': _series,
          'from': _ms(_base),
          'to': _ms(_base.add(const Duration(hours: 1))),
          'maxPoints': maxPoints,
        }));
      }

      expect(kit.source.calls, hasLength(2),
          reason: 'the anti-vacuity arm: the band is inclusive at both ends, '
              'and a guard that was off by one at either would refuse a '
              'legitimate chart while still passing both refusal cases above');
    });

  });

  group('a backwards window is refused, not answered empty', () {
    test('a from after its to is refused on the raw path', () async {
      final kit = _kit();

      final error = await kit.refusedPreEffect(
          () => kit.handlers.timeseriesQuery(
                  _params(DataServiceMethods.timeseriesQuery, {
                'table': _series,
                'from': _ms(_base.add(const Duration(hours: 2))),
                'to': _ms(_base),
              })),
          'a window running backwards',
          reason: 'the honest answer to "everything between 08:00 and 06:00" '
              'is that the question is wrong. An empty list would be read as '
              '"nothing was recorded in that window", which is a statement '
              'about the plant rather than about the request');

      expect(error.message, contains('from'));
      expect(error.message, contains('to'));
    });

    test('a from after its to is refused on the downsampled path, where the '
        'database would have swapped them', () async {
      final kit = _kit();

      await kit.refusedPreEffect(
          () => kit.handlers.timeseriesQueryDownsampled(
                  _params(DataServiceMethods.timeseriesQueryDownsampled, {
                'table': _series,
                'from': _ms(_base.add(const Duration(hours: 2))),
                'to': _ms(_base),
                'maxPoints': 100,
              })),
          'a backwards window on the downsampled path',
          reason: '`queryTimeseriesDataDownsampled` opens with '
              '`from.isBefore(to) ? from : to` and quietly answers the '
              'window the caller did not ask for. Two callers sending '
              'opposite arguments get identical answers, and neither is told '
              'which one it got');
    });

    test('a zero-width window is accepted', () async {
      final kit = _kit();

      await kit.handlers.timeseriesQuery(_params(
          DataServiceMethods.timeseriesQuery,
          {'table': _series, 'from': _ms(_base), 'to': _ms(_base)}));

      expect(kit.source.calls, hasLength(1),
          reason: 'anti-vacuity, and a real case: an instant is a legitimate '
              'window — "what was recorded at exactly this moment" — and the '
              'guard is `from` *after* `to`, not `from` not-before `to`');
    });
  });
}

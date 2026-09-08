@TestOn('vm')

/// The data-service handler bodies, judged as bodies rather than over a wire.
///
/// Called the way `RelaySession._on` calls them — one `rpc.Parameters` in, one
/// answer or one `RpcException` out — which is `value_handlers_test.dart`'s
/// dialect and for the same reason: registration is asserted over a real
/// socket in `surface_test.dart` and `ws_malformed_test.dart`, so what is left
/// for this file is what each body *answers* once it has been reached.
///
/// Two distinctions carry the file, and both are the kind that a plausible
/// implementation gets wrong silently:
///
///  * **Null is not the empty list.** `resolvePath` answers null for a target
///    that does not exist and a list for one that does. An empty list would
///    claim the target sits zero nodes from a root, and a panel restoring a
///    saved selection would render a breadcrumb with nothing in it instead of
///    dropping the pre-selection (`served_state_man.dart:501-507`).
///  * **A wrong-shaped parameter is a refusal, not a crash.** Every refusal on
///    this wire carries a pre-substituted `data.request`, because
///    `RpcException.serialize` otherwise copies the offending request into the
///    error — and one request carrying `1e999` then makes the *error*
///    unencodable, at which point the peer drops it and a caller with no
///    deadline waits forever (the 02-05 hang).
///
/// **10-03** adds the timeseries methods (four then; three since the
/// 2026-09-07 audit cut the count method). Their arguments are not
/// decoration: the frozen signatures carry strings that upstream interpolates
/// straight into SQL (`database_drift.dart`'s `tableQuery`), so what those
/// bodies *refuse* is as much of the surface as what they answer. The hostile
/// half lives in `hostile_params_test.dart`; what is here is the ordinary
/// shape of an answer and the one refusal that is about size rather than
/// about shape.
///
/// **10-04** adds the history-view eleven, and one of the cases below carries
/// a weight no other case in this file does.
///
/// The contract kit covers nine of the eleven through two checks. It does
/// **not** cover `historyViews.getGlobalRetentionHorizon`, and it may not be
/// made to: `data_services_contract.dart:4-30` is an explicit scope boundary
/// forbidding an eighth data-services case there, on the argument that a weak
/// version of a Phase 10 property frozen as contract is harder to correct
/// than an honest silence. So for that method **this file is the only judge
/// there is**. A gateway could answer it wrong — a horizon an hour off — and
/// every leg of the contract suite would stay green. The case says so at its
/// own site, because the sentence is only useful where somebody is about to
/// edit the thing.
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
import 'support/ws_harness.dart';

/// A node that really is in [FakeBrowse]'s default tree.
const _folder = BrowseNode(
    id: 'ST101.CN01', displayName: 'CN01', type: BrowseNodeType.folder);

/// A leaf the default tree seeds a reading for.
const _leaf = BrowseNode(
    id: 'ST101.CN01.MOT01.setpoint',
    displayName: 'setpoint',
    type: BrowseNodeType.variable,
    dataType: 'Float');

/// The series the timeseries cases record against, named the way the database
/// names tables rather than the way the key space names tags — the frozen
/// parameter is `tableName` (`state_man_api.dart:263-266`).
const _series = 'st101_cn01_mot01_setpoint';

/// A second series, deliberately never seeded: the one a multi-series query
/// must still hand back an entry for.
const _unrecorded = 'st201_cn04_mot01_setpoint';

/// The instant every timeseries case measures from. Fixed and UTC, so nothing
/// in this file is a reading of the machine's clock.
final _base = DateTime.utc(2026, 8, 13, 6);

/// Epoch milliseconds, which is how an instant travels on this wire.
int _ms(DateTime at) => at.millisecondsSinceEpoch;

/// A regular series, one sample a minute from [_base].
List<TimeseriesData> _minutely(int count) => [
      for (var i = 0; i < count; i++)
        TimeseriesData<num>(1200 + i, _base.add(Duration(minutes: i))),
    ];

/// The handlers under test, over a source a case can drive.
final class _Kit {
  _Kit(this.handlers, this.api);

  final DataHandlers handlers;
  final FakeStateMan api;
}

_Kit _kit(
    {FakeBrowse? browse,
    FakeTimeseries? timeseries,
    FakeHistoryViews? historyViews,
    FakePreferences? preferences,
    List<({String method, Map<String, Object?> params})>? sent}) {
  final api = FakeStateMan(
      browse: browse,
      timeseries: timeseries,
      historyViews: historyViews,
      preferences: preferences);
  addTearDown(api.dispose);
  return _Kit(
      DataHandlers(
          source: api,
          config: ServerConfig(),
          resolver: const PermissiveSeriesResolver(),
          // The session owns the peer; this object is handed a narrow way to
          // announce and nothing else, which is why a case can collect what it
          // announced without a socket. `preferences_notify_test.dart` is
          // where the same sender is judged over a real one.
          notify: (method, params) => sent?.add((
                method: method,
                params: params,
              ))),
      api);
}

/// The two plant keys the history-view cases plot.
///
/// Plant keys, **not** table names: a view is a list of tags an engineer
/// picked off the tree, which is why this family is the one data service that
/// never consults the series resolver.
const _viewKeyA = 'CN01.MOT01.speed';
const _viewKeyB = 'CN02.SEN01.temp';

rpc.Parameters _params(String method, Map<String, Object?> value) =>
    rpc.Parameters(method, value);

/// One decoded node list, as the wire would carry it.
List<Map<String, Object?>> _nodes(Object? raw) => [
      for (final entry in raw! as List) (entry as Map).cast<String, Object?>(),
    ];

/// A resolver that fails the case if anything asks it a question.
///
/// Used to prove a *negative* — that the browse handlers never consult the
/// mapping — which a permissive resolver cannot do, because a handler that
/// asked it would get a plausible answer and the case would pass.
final class _RefusesEverything implements SeriesResolver {
  const _RefusesEverything();

  @override
  ResolvedSeries? resolve(String wireName) =>
      throw StateError('a browse handler asked the resolver to resolve '
          '"$wireName"');

  @override
  String? keyForTable(String table) =>
      throw StateError('a browse handler asked the resolver about table '
          '"$table"');

  @override
  String? keyForNode(String nodeId) =>
      throw StateError('a browse handler asked the resolver about node '
          '"$nodeId"');
}

/// The refusal a body raised, or a failure naming what it answered instead.
Future<rpc.RpcException> _refusal(
    Future<Object?> Function() ask, String what) async {
  final Object? answered;
  try {
    answered = await ask();
  } on rpc.RpcException catch (error) {
    return error;
  }
  fail('$what was answered with $answered instead of refused');
}

void main() {
  group('browse.fetchRoots', () {
    test('answers the source\'s roots as a list of nodes', () async {
      final kit = _kit();

      final answer = _nodes(
          await kit.handlers.browseFetchRoots(_params('browse.fetchRoots', {})));

      expect(answer.map((node) => node['id']).toList(),
          [for (final root in FakeBrowse.defaultRoots) root.id],
          reason: 'the roots are the top level of the address space, in the '
              'order the source gave them. A panel renders this list as the '
              'first thing an engineer sees, and a reordering is a tree that '
              'moves under the cursor between two sessions');
      expect(answer.first['type'], 'folder',
          reason: 'the node kind survives the encode: it is what decides '
              'whether the row gets a disclosure triangle');
    });

    test('an empty address space is the empty list, never null', () async {
      final kit = _kit(browse: FakeBrowse(roots: const [], children: const {}));

      final answer =
          await kit.handlers.browseFetchRoots(_params('browse.fetchRoots', {}));

      expect(answer, isEmpty,
          reason: 'a source with nothing to browse has an empty address '
              'space, which is a fact. Null would decode on the client as a '
              'missing answer and the tree would show a spinner forever');
      expect(answer, isA<List<Object?>>(),
          reason: 'and it must still be a list, so one decoder reads both the '
              'populated and the empty case');
    });
  });

  group('browse.fetchChildren', () {
    test('answers the children of the node it was given', () async {
      final kit = _kit();

      final answer = _nodes(await kit.handlers.browseFetchChildren(
          _params('browse.fetchChildren', {'parent': _folder.toJson()})));

      expect(answer.map((node) => node['id']).toList(),
          ['ST101.CN01.MOT01', 'ST101.CN01.SEN01'],
          reason: 'the level under ST101.CN01, and only that one');
    });

    test('reads its argument rather than serving one canned level', () async {
      final kit = _kit();

      final first = _nodes(await kit.handlers.browseFetchChildren(
          _params('browse.fetchChildren', {'parent': _folder.toJson()})));
      final second = _nodes(await kit.handlers.browseFetchChildren(_params(
          'browse.fetchChildren', {
        'parent': const BrowseNode(
                id: 'ST201.CN04',
                displayName: 'CN04',
                type: BrowseNodeType.folder)
            .toJson()
      })));

      expect(second.map((node) => node['id']).toList(), ['ST201.CN04.MOT01'],
          reason: 'the two folders share no child id, which is what lets this '
              'case tell "decoded the parent" from "answered the last level '
              'it happened to hold"');
      expect(first, isNot(equals(second)));
    });

    test('a parent that is not an object is refused, not thrown through',
        () async {
      final kit = _kit();

      final error = await _refusal(
          () => kit.handlers.browseFetchChildren(
              _params('browse.fetchChildren', {'parent': 'ST101.CN01'})),
          'a fetchChildren whose parent is a bare string');

      expect(error.code, rpc_error.INVALID_PARAMS,
          reason: 'a caller that sent the wrong shape gets the wrong-shape '
              'code, not a handler failure — the difference is whether the '
              'panel retries');
      expect(error.message, contains('parent'),
          reason: 'the refusal must name the parameter, or the only way to '
              'find out which one was wrong is to read this file');
      expect((error.data! as Map)['request'], isA<String>(),
          reason: 'the request is pre-substituted. Without it '
              'RpcException.serialize copies the offending request into the '
              'error, and one carrying 1e999 makes the refusal itself '
              'unencodable — the caller then waits forever on a path with no '
              'deadline');
      expect((error.data! as Map)['method'], 'browse.fetchChildren');
    });

    test('a missing parent is refused the same way', () async {
      final kit = _kit();

      final error = await _refusal(
          () => kit.handlers
              .browseFetchChildren(_params('browse.fetchChildren', {})),
          'a fetchChildren with no parent at all');

      expect(error.code, rpc_error.INVALID_PARAMS);
      expect((error.data! as Map)['request'], isA<String>(),
          reason: 'the armor is on every arm of the refusal, not only the one '
              'a case happened to write first');
    });
  });

  group('browse.fetchDetail', () {
    test('answers the detail of the node it was given', () async {
      final kit = _kit();

      final answer = (await kit.handlers.browseFetchDetail(
          _params('browse.fetchDetail', {'node': _leaf.toJson()})))! as Map;
      final detail =
          BrowseNodeDetail.fromJson(answer.cast<String, Object?>());

      expect(detail.dataType, 'Float',
          reason: 'the data type is what the detail pane renders the reading '
              'with');
      expect(detail.value?.value, 1450.0,
          reason: 'a variable\'s detail carries its reading. A detail with no '
              'value would render an empty pane for a tag the tree just '
              'listed');
    });

    test('a node that is not an object is refused', () async {
      final kit = _kit();

      final error = await _refusal(
          () => kit.handlers.browseFetchDetail(
              _params('browse.fetchDetail', {'node': 42})),
          'a fetchDetail whose node is a number');

      expect(error.code, rpc_error.INVALID_PARAMS);
      expect(error.message, contains('node'));
      expect((error.data! as Map)['request'], isA<String>());
    });
  });

  group('the resolver seam', () {
    test('the handlers hold the resolver they were built with', () {
      const resolver = PermissiveSeriesResolver();
      final api = FakeStateMan();
      addTearDown(api.dispose);

      final handlers = DataHandlers(
          source: api,
          config: ServerConfig(),
          resolver: resolver,
          // Nothing here announces anything: this fixture is about the
          // handler bodies, and the sender is judged in its own file.
          notify: (_, __) {},
          );

      expect(identical(handlers.resolver, resolver), isTrue,
          reason: 'the same object, not an equal one: there is exactly one '
              'mapping per gateway and it is built from the keymappings the '
              'composition root already loaded. 10-03\'s timeseries handlers '
              'read it to turn a wire series name into a table, and a copy '
              'made somewhere in between is a second place a mapping could '
              'go stale');
    });

    test('the browse handlers do not consult it', () async {
      // Browse is the one family that does not need the mapping in the
      // handler: a node id is an upstream address-space identifier
      // (`client_sub_apis.dart:179-183`), and turning one into a plant key is
      // the *policy's* job, one layer down, so that a handler cannot forget
      // it. This case pins that division by handing the handlers a resolver
      // that would throw if it were asked.
      final api = FakeStateMan();
      addTearDown(api.dispose);
      final handlers = DataHandlers(
          source: api,
          config: ServerConfig(),
          resolver: const _RefusesEverything(),
          // Nothing here announces anything: this fixture is about the
          // handler bodies, and the sender is judged in its own file.
          notify: (_, __) {},
          );

      final roots = await handlers
          .browseFetchRoots(_params('browse.fetchRoots', {}));

      expect(roots, isNotEmpty,
          reason: 'fetchRoots asked the resolver a question. Filtering by '
              'visibility belongs to _PolicyBrowse, which is already between '
              'these handlers and the source — a second filter here would be '
              'a second place to keep in step');
    });
  });

  group('browse.resolvePath', () {
    test('answers the chain root to leaf', () async {
      final kit = _kit();

      final answer = _nodes(await kit.handlers.browseResolvePath(_params(
          'browse.resolvePath', {'targetId': 'ST101.CN01.MOT01.setpoint'})));

      expect(answer.map((node) => node['id']).toList(), [
        'ST101',
        'ST101.CN01',
        'ST101.CN01.MOT01',
        'ST101.CN01.MOT01.setpoint',
      ], reason: 'root first, leaf last, every step a real edge. The panel '
          'expands the tree by walking this list, so a gap in it is a level '
          'that never opens');
    });

    test('a target that does not exist answers null, not the empty list',
        () async {
      final kit = _kit();

      final answer = await kit.handlers.browseResolvePath(
          _params('browse.resolvePath', {'targetId': 'ST101.CN01.MOT99.gone'}));

      expect(answer, isNull,
          reason: 'null is "cannot resolve" and the empty list claims a '
              'zero-length chain. A page saved last year against a tag since '
              'renamed in the PLC is the ordinary case: it must degrade to no '
              'pre-selection, and a panel that read [] as a resolved chain '
              'would select the root');
      expect(answer, isNot(isA<List<Object?>>()),
          reason: 'stated the other way round too, because the failure this '
              'guards against is a body that answered [] and a matcher that '
              'called it falsy');
    });

    test('a targetId that is not a string is refused', () async {
      final kit = _kit();

      final error = await _refusal(
          () => kit.handlers.browseResolvePath(
              _params('browse.resolvePath', {'targetId': 7})),
          'a resolvePath whose targetId is a number');

      expect(error.code, rpc_error.INVALID_PARAMS);
      expect(error.message, contains('targetId'));
      expect((error.data! as Map)['request'], isA<String>());
    });
  });

  group('timeseries.queryTimeseriesData', () {
    test('a recorded series comes back inside the window, oldest first',
        () async {
      final kit = _kit(timeseries: FakeTimeseries()..seed(_series, _minutely(7)));

      final answer = _samples(await kit.handlers.timeseriesQuery(
          _params(DataServiceMethods.timeseriesQuery, {
        'table': _series,
        'to': _ms(_base.add(const Duration(minutes: 5))),
        'from': _ms(_base.add(const Duration(minutes: 1))),
        'orderBy': 'time ASC',
      })));

      expect(answer.map((sample) => sample['t']).toList(),
          [for (var i = 1; i <= 5; i++) _ms(_base.add(Duration(minutes: i)))],
          reason: 'seven samples were recorded and minutes one to five were '
              'asked for. Samples outside the window make a chart draw beyond '
              'the axis it was given; samples out of time order make it draw a '
              'scribble, because a line chart joins consecutive points and '
              'nothing sorts them on the way to the screen');
      expect(answer.map((sample) => sample['v']).toList(),
          [1201, 1202, 1203, 1204, 1205],
          reason: 'the samples that came back are not the ones that were '
              'recorded, so the chart is showing numbers the plant never '
              'produced');
    });

    test('every instant is epoch milliseconds and every sample is a num',
        () async {
      final kit = _kit(timeseries: FakeTimeseries()..seed(_series, _minutely(3)));

      final answer = _samples(await kit.handlers.timeseriesQuery(
          _params(DataServiceMethods.timeseriesQuery, {
        'table': _series,
        'to': _ms(_base.add(const Duration(minutes: 9))),
      })));

      expect(answer, hasLength(3));
      for (final sample in answer) {
        expect(sample['t'], isA<int>(),
            reason: 'an instant travels as epoch milliseconds, decoded on the '
                'far side by `TimeseriesData.fromJson` reading `t` through '
                '`num`. An ISO string here would decode to instant zero and '
                'the chart would draw 1970');
        expect(sample['v'], isA<num>(),
            reason: 'the wire sample type is num (10-CONTEXT ruling 2), and '
                'the client decodes it as one. A string would break every '
                'chart\'s arithmetic at the point of plotting rather than at '
                'the point of decoding');
      }
      expect(
          DateTime.fromMillisecondsSinceEpoch(answer.first['t']! as int,
              isUtc: true),
          _base,
          reason: 'read back as UTC it must be the instant that was recorded. '
              'A local-time encode would shift every chart in the plant by '
              'the machine\'s offset and nothing on the wire would say so');
    });

    test('a "to" that is missing is refused, not defaulted to now', () async {
      final kit = _kit(timeseries: FakeTimeseries()..seed(_series, _minutely(3)));

      final error = await _refusal(
          () => kit.handlers.timeseriesQuery(
              _params(DataServiceMethods.timeseriesQuery, {'table': _series})),
          'a queryTimeseriesData with no window end');

      expect(error.code, rpc_error.INVALID_PARAMS,
          reason: '`to` is the one positional argument of the frozen '
              'signature and there is no honest default for it: substituting '
              '"now" would answer a different question than the one asked and '
              'the caller could not tell');
      expect(error.message, contains('to'));
      expect((error.data! as Map)['request'], isA<String>());
    });

    test('a "to" that is not a number is refused', () async {
      final kit = _kit(timeseries: FakeTimeseries()..seed(_series, _minutely(3)));

      final error = await _refusal(
          () => kit.handlers.timeseriesQuery(
                  _params(DataServiceMethods.timeseriesQuery, {
                'table': _series,
                'to': '2026-08-13T06:00:00Z',
              })),
          'a queryTimeseriesData whose window end is an ISO string');

      expect(error.code, rpc_error.INVALID_PARAMS,
          reason: 'instants travel as epoch milliseconds on this wire '
              '(`client_sub_apis.dart` sends `msOf`). An ISO string reaching '
              '`(raw as num).toInt()` is a cast error inside the handler, '
              'which the session reports as handlerFailed — "possibly '
              'transient, retrying is legitimate" — for a request that will '
              'never succeed');
      expect(error.message, contains('to'));
    });
  });

  group('timeseries.queryTimeseriesDataMultiple', () {
    test('every requested series gets an entry, including the silent ones',
        () async {
      final kit = _kit(timeseries: FakeTimeseries()..seed(_series, _minutely(5)));

      final answer = _object(await kit.handlers.timeseriesQueryMultiple(
          _params(DataServiceMethods.timeseriesQueryMultiple, {
        'tables': [_series, _unrecorded],
        'to': _ms(_base.add(const Duration(hours: 1))),
        'from': _ms(_base),
      })));

      expect(answer.keys, containsAll([_series, _unrecorded]),
          reason: 'two series were asked for and ${answer.keys.toList()} came '
              'back. A name with no entry is a series the chart silently drops '
              'from its legend, which an operator reads as "this tag is flat" '
              'rather than as "nothing was recorded" — an absent entry and an '
              'empty entry are different answers and only one of them is true');
      expect(answer[_unrecorded], isEmpty,
          reason: 'the unrecorded series came back with samples in it, so the '
              'gateway is answering for a table it has nothing for');
      expect(answer[_series], isNotEmpty,
          reason: 'the recorded series came back empty in a multi-series query '
              'while it has samples, so the batching path is losing what the '
              'single-series path finds');
    });

    test('the answer is keyed by the names the caller asked for', () async {
      final kit = _kit(timeseries: FakeTimeseries()..seed(_series, _minutely(2)));

      final answer = _object(await kit.handlers.timeseriesQueryMultiple(
          _params(DataServiceMethods.timeseriesQueryMultiple, {
        'tables': [_unrecorded, _series],
        'to': _ms(_base.add(const Duration(hours: 1))),
      })));

      expect(answer.keys.toSet(), {_unrecorded, _series},
          reason: 'the gateway builds this map from the request rather than '
              'from the source\'s answer, so "one entry per requested series" '
              'is a property of the handler and not something it inherits '
              'from whatever is behind it. A source that omitted a silent '
              'table would still produce a complete map here, and 10-07\'s '
              'reader is exactly such a source');
    });

    test('a "tables" that is not a list is refused', () async {
      final kit = _kit(timeseries: FakeTimeseries());

      final error = await _refusal(
          () => kit.handlers.timeseriesQueryMultiple(
                  _params(DataServiceMethods.timeseriesQueryMultiple, {
                'tables': _series,
                'to': _ms(_base),
              })),
          'a multi-series query whose "tables" is a bare string');

      expect(error.code, rpc_error.INVALID_PARAMS,
          reason: 'the same three arms readMany has, for the same reason: a '
              'wrong-shaped breadth argument is the caller\'s mistake and it '
              'is refused before anything is read');
      expect(error.message, contains('tables'));
      expect((error.data! as Map)['request'], isA<String>());
    });
  });

  group('timeseries.queryTimeseriesDataDownsampled', () {
    test('honours maxPoints and still reaches both ends of the window',
        () async {
      final points = [
        for (var i = 0; i < 500; i++)
          TimeseriesData<num>(i, _base.add(Duration(seconds: i))),
      ];
      final kit = _kit(timeseries: FakeTimeseries()..seed(_series, points));
      final to = _base.add(const Duration(seconds: 499));

      final answer = _samples(await kit.handlers.timeseriesQueryDownsampled(
          _params(DataServiceMethods.timeseriesQueryDownsampled, {
        'table': _series,
        'from': _ms(_base),
        'to': _ms(to),
        'maxPoints': 50,
      })));

      expect(answer.length, lessThanOrEqualTo(50),
          reason: '500 samples were downsampled to 50 and ${answer.length} '
              'came back. A bound that is not kept means a year of one-second '
              'samples crosses the link the moment somebody widens a chart');
      expect(answer, isNotEmpty);
      expect(answer.first['t'], _ms(_base),
          reason: 'the downsampled series must start where the window starts, '
              'or the chart draws a line that begins after its own axis does');
      expect(answer.last['t'], _ms(to),
          reason: 'and end where the window ends. The newest sample is the '
              'one an operator reads as the current value, and a downsample '
              'that drops it shows the plant as it was with no indication of '
              'when');
    });
  });

  group('history views round-trip over the handler bodies', () {
    test('a view survives create, list, read back and delete', () async {
      final kit = _kit();

      final id = await kit.handlers.historyCreateView(
          _params(DataServiceMethods.historyCreateView, {
        'name': 'Vaktir',
        'keys': [_viewKeyA, _viewKeyB],
        'keyConfigs': {
          _viewKeyA: const HistoryViewKeyRecord(
                  key: _viewKeyA,
                  alias: 'Færiband 1',
                  useSecondYAxis: true,
                  graphIndex: 1)
              .toJson(),
        },
        'graphConfigs': historyViewGraphsToJson(const {
          1: HistoryViewGraphRecord(
              graphIndex: 1, name: 'Hitastig', yAxisUnit: '°C'),
        }),
      }));

      expect(id, isA<int>(),
          reason: 'creating a view answers its id as a number. Without one '
              'the caller cannot address the view it just made, and the panel '
              'has to guess by listing and matching on a name an operator may '
              'well have used twice');

      final listed = _objects(await kit.handlers
          .historySelectViews(_params(DataServiceMethods.historySelectViews, {})));
      expect(listed.map((view) => view['id']), contains(id),
          reason: 'the view the picker offers is the one that was saved');
      expect(listed.single['name'], 'Vaktir');
      expect(listed.single['createdAt'], isA<int>(),
          reason: 'every instant on this wire is epoch milliseconds, in both '
              'directions and in every record. An ISO string here decodes on '
              'the client through `(raw as num)` and throws inside a decoder '
              'nothing is catching');

      final keys = _object(await kit.handlers.historyGetKeys(
          _params(DataServiceMethods.historyGetKeys, {'viewId': id})));
      expect(keys.keys, containsAll([_viewKeyA, _viewKeyB]));
      expect(_object(keys[_viewKeyA])['alias'], 'Færiband 1',
          reason: 'the legend label the engineer typed has to survive the '
              'round trip, or the chart re-labels itself with raw tag names '
              'the next time the page opens');
      expect(_object(keys[_viewKeyA])['useSecondYAxis'], isTrue,
          reason: 'a series saved against the second Y axis coming back on '
              'the first puts a temperature and a motor speed on one scale, '
              'and the temperature becomes a flat line at the bottom');
      expect(_object(keys[_viewKeyB])['alias'], _viewKeyB,
          reason: 'a key saved with no alias comes back aliased to its own '
              'name — `row.alias ?? row.key`, defaulted inside the record\'s '
              'constructor so no call site has to remember it');

      final graphs = _object(await kit.handlers.historyGetGraphs(
          _params(DataServiceMethods.historyGetGraphs, {'viewId': id})));
      expect(graphs.keys, ['1'],
          reason: 'graph configuration is keyed by graph *index*, an int, and '
              'JSON objects key by String — so the map crosses with String '
              'keys and is converted back exactly once, at the boundary, by '
              '`historyViewGraphsFromJson`. A key left as an int here is a '
              'map json_rpc_2 cannot encode');
      expect(_object(graphs['1'])['yAxisUnit'], '°C',
          reason: 'without the unit the chart draws numbers with nothing '
              'saying what they are');

      final names = await kit.handlers.historyGetKeyNames(
          _params(DataServiceMethods.historyGetKeyNames, {'viewId': id}));
      expect(names, containsAll([_viewKeyA, _viewKeyB]),
          reason: 'the name-only accessor and the record accessor must agree '
              'about what this view plots; they are two reads of one row set '
              'and a caller picks whichever it needs');

      await kit.handlers.historyDeleteView(
          _params(DataServiceMethods.historyDeleteView, {'id': id}));

      expect(
          _objects(await kit.handlers.historySelectViews(
              _params(DataServiceMethods.historySelectViews, {}))),
          isEmpty,
          reason: 'the deleted view is still in the picker');
      expect(
          _object(await kit.handlers.historyGetKeys(
              _params(DataServiceMethods.historyGetKeys, {'viewId': id}))),
          isEmpty,
          reason: 'the delete has to take the key rows with it. Rows that '
              'outlive their view are how a deleted view comes back as a '
              'partial one after the next restart — a chart with a name, no '
              'title and two mystery lines');
    });

    test('a view can be renamed and re-keyed, and the old keys go', () async {
      final kit = _kit();
      final id = await kit.handlers.historyCreateView(
          _params(DataServiceMethods.historyCreateView, {
        'name': 'Vaktir',
        'keys': [_viewKeyA],
      }));

      await kit.handlers.historyUpdateView(
          _params(DataServiceMethods.historyUpdateView, {
        'id': id,
        'name': 'Vaktir, endurskoðað',
        'keys': [_viewKeyB],
      }));

      final listed = _objects(await kit.handlers.historySelectViews(
          _params(DataServiceMethods.historySelectViews, {})));
      expect(listed.single['name'], 'Vaktir, endurskoðað');
      expect(listed.single['updatedAt'], isA<int>(),
          reason: 'an edited view carries an updatedAt where a fresh one '
              'carries none, and the picker sorts and labels by exactly that '
              'distinction');
      expect(
          await kit.handlers.historyGetKeyNames(
              _params(DataServiceMethods.historyGetKeyNames, {'viewId': id})),
          [_viewKeyB],
          reason: 'update *replaces* the key list rather than adding to it. A '
              'union would make removing a line from a chart impossible '
              'through the only method that exists for it');
    });

    test('a saved time window survives add, list and delete, to the '
        'microsecond', () async {
      final kit = _kit();
      final id = await kit.handlers.historyCreateView(
          _params(DataServiceMethods.historyCreateView, {
        'name': 'Vaktir',
        'keys': [_viewKeyA],
      }));

      // **July on purpose.** A local-time constructor is invisible on a
      // machine sitting at UTC — Reykjavík is UTC+0 all year, and this suite
      // runs there — so the month alone does not prove anything and the case
      // does not rely on it. What it relies on is the *wire integer*: the
      // handler must emit exactly `start.millisecondsSinceEpoch` of the UTC
      // instant that went in, which is a claim no timezone can make true or
      // false by accident. The July instants are still worth having, because
      // on a CI runner in a DST zone a local-time constructor fails this case
      // by a whole hour and names itself.
      final start = DateTime.utc(2026, 7, 15, 6);
      final end = DateTime.utc(2026, 7, 15, 14);

      final periodId = await kit.handlers.historyAddPeriod(
          _params(DataServiceMethods.historyAddPeriod, {
        'viewId': id,
        'name': 'Vakt 1',
        'start': _ms(start),
        'end': _ms(end),
      }));
      expect(periodId, isA<int>());

      final periods = _objects(await kit.handlers.historyListPeriods(
          _params(DataServiceMethods.historyListPeriods, {'viewId': id})));
      expect(periods, hasLength(1));
      expect(periods.single['id'], periodId,
          reason: 'a window that comes back under a different id than adding '
              'it returned means deleting it addresses something else');
      expect(periods.single['viewId'], id);
      expect(periods.single['name'], 'Vakt 1');

      expect(periods.single['startAt'], _ms(start),
          reason: 'the exact epoch millisecond that went in. An operator '
              'returning to a saved shift lands on the wrong one if this is '
              'off by an hour, and every conclusion drawn from the chart is '
              'about the wrong hours — with nothing on screen saying so');
      expect(periods.single['endAt'], _ms(end));
      expect(
          DateTime.fromMillisecondsSinceEpoch(periods.single['startAt']! as int,
              isUtc: true),
          start,
          reason: 'and it decodes back to the same instant, equal to the '
              'microsecond rather than merely close. `DateTime` equality is '
              'exact, so this is the assertion that would catch a rounding '
              'through seconds');
      expect(
          DateTime.fromMillisecondsSinceEpoch(periods.single['endAt']! as int,
                  isUtc: true)
              .isUtc,
          isTrue,
          reason: 'decoded as UTC, which is what makes the comparison above a '
              'comparison of instants rather than of wall clocks');

      await kit.handlers.historyDeletePeriod(
          _params(DataServiceMethods.historyDeletePeriod, {'id': periodId}));
      expect(
          _objects(await kit.handlers.historyListPeriods(
              _params(DataServiceMethods.historyListPeriods, {'viewId': id}))),
          isEmpty,
          reason: 'the deleted window is still listed on the view');
    });

    test('deleting a view takes its saved windows with it', () async {
      final kit = _kit();
      final id = await kit.handlers.historyCreateView(
          _params(DataServiceMethods.historyCreateView, {
        'name': 'Vaktir',
        'keys': [_viewKeyA],
      }));
      await kit.handlers.historyAddPeriod(
          _params(DataServiceMethods.historyAddPeriod, {
        'viewId': id,
        'name': 'Vakt 1',
        'start': _ms(_base),
        'end': _ms(_base.add(const Duration(hours: 8))),
      }));

      await kit.handlers.historyDeleteView(
          _params(DataServiceMethods.historyDeleteView, {'id': id}));

      expect(
          _objects(await kit.handlers.historyListPeriods(
              _params(DataServiceMethods.historyListPeriods, {'viewId': id}))),
          isEmpty,
          reason: 'the cascade is spelled out by hand in the database layer '
              'rather than trusted to a foreign key, so it is a behaviour '
              'this gateway has to carry across rather than inherit');
    });
  });

  // **No contract check covers this method.** `data_services_contract.dart`'s
  // scope boundary (`:4-30`) forbids an eighth data-services case there, and
  // the two checks that do exist never call the retention horizon — so if this
  // handler is wrong, every leg of the contract suite stays green and the
  // first report is an operator saying a chart "goes back further than it
  // should". These two cases are the whole of the judgement on it.
  group('historyViews.getGlobalRetentionHorizon — uncovered upstream, judged '
      'here', () {
    test('null stays null, and is not an instant at the epoch', () async {
      final kit = _kit();

      final answer = await kit.handlers.historyRetentionHorizon(
          _params(DataServiceMethods.historyRetentionHorizon, {}));

      expect(answer, isNull,
          reason: '"nothing has been discarded yet" and "everything since '
              '1970 is gone" are opposite answers, and 0 is a perfectly valid '
              'epoch millisecond — so a handler that defaulted null to 0 '
              'would tell a chart that all of history has been dropped. The '
              'client\'s decoder is written against exactly this distinction '
              '(`client_sub_apis.dart`: `raw == null ? null : timeOf(raw)`)');
    });

    test('a horizon crosses as the exact epoch millisecond, in UTC', () async {
      final horizon = DateTime.utc(2026, 7, 15, 6, 30);
      final kit = _kit(
          historyViews: FakeHistoryViews()..setRetentionHorizon(horizon));

      final answer = await kit.handlers.historyRetentionHorizon(
          _params(DataServiceMethods.historyRetentionHorizon, {}));

      expect(answer, _ms(horizon),
          reason: 'the horizon is the line a chart draws between "nothing '
              'happened" and "nothing was kept", so an hour of drift moves '
              'that line across a whole shift. The upstream implementation '
              'builds it as `DateTime.now().subtract(maxDur)` '
              '(`database_drift.dart:775`) — a *local* instant — and this '
              'handler must not repeat that shape: epoch milliseconds are '
              'absolute, but a local DateTime handed to a client that decodes '
              'as UTC is off by the server\'s offset');
      expect(
          DateTime.fromMillisecondsSinceEpoch(answer! as int, isUtc: true),
          horizon,
          reason: 'and it decodes back to the same instant exactly');
    });
  });

  group('a malformed view id is refused, never carried into the database', () {
    for (final (label, value) in <(String, Object?)>[
      ('absent', null),
      ('a string', '1'),
      ('a decimal', 1.5),
      ('a list', <Object?>[1]),
    ]) {
      test('a viewId that is $label is INVALID_PARAMS', () async {
        final kit = _kit();

        final error = await _refusal(
            () => kit.handlers.historyGetKeys(_params(
                DataServiceMethods.historyGetKeys,
                {if (value != null) 'viewId': value})),
            'a getHistoryViewKeys whose viewId is $label');

        expect(error.code, rpc_error.INVALID_PARAMS,
            reason: 'and not handlerFailed: `params["viewId"].asInt` would '
                'raise an RpcException with no `data`, which json_rpc_2 then '
                'fills with the offending request — the shape this whole file '
                'exists to avoid');
        expect(error.message, contains('viewId'),
            reason: 'the refusal names the parameter, or the caller is '
                'reading a stack trace to find out which of four ids it got '
                'wrong');
        expect((error.data! as Map)['request'], isA<String>(),
            reason: 'pre-substituted, like every other refusal on this wire');
      });
    }

    test('a graph index that will not parse is refused, never dropped',
        () async {
      final kit = _kit();

      final error = await _refusal(
          () => kit.handlers.historyCreateView(
                  _params(DataServiceMethods.historyCreateView, {
                'name': 'Vaktir',
                'keys': [_viewKeyA],
                'graphConfigs': {
                  'top': {'graphIndex': 0, 'name': 'Hitastig'},
                },
              })),
          'a createHistoryView whose graphConfigs key is not a number');

      expect(error.code, rpc_error.INVALID_PARAMS);
      expect(error.message, contains('graphConfigs'));
      expect(
          _objects(await kit.handlers.historySelectViews(
              _params(DataServiceMethods.historySelectViews, {}))),
          isEmpty,
          reason: 'and nothing was created. This is the arm that keeps the '
              'refusal honest: upstream\'s `createHistoryView` parses these '
              'keys with `int.tryParse` and **silently skips** an entry that '
              'fails (`database_drift.dart:610`), so a chart saving four '
              'graphs would get three back with nothing said. The wire is '
              'typed `Map<int, HistoryViewGraphRecord>`, which is what makes '
              'that drop unreachable from a client speaking this protocol — '
              'and refusing here is what keeps it unreachable from one that '
              'is not');
    });
  });

  group('a result too large to send is a refusal, not a failure and not a '
      'close', () {
    test('the refusal is INVALID_PARAMS and names the bounded method it '
        'suggests', () async {
      final kit = _kit(timeseries: _TooLargeTimeseries());

      final error = await _refusal(
          () => kit.handlers.timeseriesQuery(
                  _params(DataServiceMethods.timeseriesQuery, {
                'table': _series,
                'to': _ms(_base.add(const Duration(days: 31))),
                'from': _ms(_base),
              })),
          'a month-long raw query the source refused to answer');

      expect(error.code, rpc_error.INVALID_PARAMS,
          reason: 'and deliberately not handlerFailed (-32011), which the '
              'wire documents as "possibly transient: retrying is '
              'legitimate". A panel that retries a month-long window forever '
              'is the denial of service the bound exists to prevent. A '
              'too-large query is a bad *request*, and the fix is in the '
              'caller\'s hands');
      expect(error.message,
          contains(DataServiceMethods.timeseriesQueryDownsampled),
          reason: 'the refusal has to name the method that would answer the '
              'same question within the limit, or it is a dead end reported '
              'as a broken chart');
      expect(error.message, contains('${_TooLargeTimeseries.limit}'),
          reason: 'and the limit, so an engineer knows whether to narrow the '
              'window a little or a lot');
      expect((error.data! as Map)['request'], isA<String>(),
          reason: 'the armor is on this arm too — it is the arm most likely '
              'to carry a wide window full of numbers');
    });

    test('the session answers the next request normally', () async {
      final fixture = relayFixture(timeseries: _TooLargeTimeseries());
      await fixture.ready;
      await fixture.hello();

      final error = await fixture.refusal(DataServiceMethods.timeseriesQuery,
          params: {
            'table': _series,
            'to': _ms(_base.add(const Duration(days: 31))),
            'from': _ms(_base),
          },
          what: 'a query the source refuses as too large');

      expect(error.code, rpc_error.INVALID_PARAMS);
      expect(error.message,
          contains(DataServiceMethods.timeseriesQueryDownsampled));
      await fixture.request(Methods.ping,
          what: 'a ping after a refused over-large query');
      expect(fixture.observedClose.closeCode, isNull,
          reason: 'a refusal must be cheaper than the request that caused it. '
              'The other tempting failure is to let the over-large answer '
              'through and have the conflating send buffer evict the session '
              'with 4004 — which reports "your query was too large" as "you '
              'disconnected", the class of failure this project exists to '
              'prevent (10-CONTEXT amendment 3)');
    }, tags: 'ws');

    test('a getAll too large to send is refused the same way, not -32011',
        () async {
      final kit = _kit(preferences: _TooLargePreferences());

      final error = await _refusal(
          () => kit.handlers
              .prefGetAll(_params(DataServiceMethods.prefGetAll, const {})),
          'a getAll over a store larger than the byte ceiling');

      expect(error.code, rpc_error.INVALID_PARAMS,
          reason: 'the timeseries family was wrapped in _sized when the '
              'mapping landed and this one was not, so a store over the cap '
              'reached the wire as handlerFailed (-32011) — documented as '
              'possibly transient. Five panels opening a settings page would '
              'each retry forever something no retry can fix');
      expect(error.message, contains('allowList'),
          reason: 'and the fix for a getAll that is too large is not another '
              'method, it is the allow-list');
    });
  });

  // The other half of the same sentence. A refusal that cannot become a
  // disconnect is worth little if it becomes an infinite retry instead, and
  // -32011 is documented as "possibly transient: retrying is legitimate".
  group('a refusal that no retry can fix does not wear a transient code', () {
    test('a permanent source refusal is INVALID_PARAMS, not handlerFailed',
        () async {
      final kit = _kit(timeseries: _RefusingTimeseries(retryable: false));

      final error = await _refusal(
          () => kit.handlers.timeseriesQuery(
                  _params(DataServiceMethods.timeseriesQuery, {
                'table': _series,
                'to': _ms(_base.add(const Duration(days: 1))),
                'from': _ms(_base),
              })),
          'a series the source will never have');

      expect(error.code, rpc_error.INVALID_PARAMS,
          reason: '"no series by that name is collected here" cannot become '
              'true by asking again. Reaching the wire as -32011 — which the '
              'wire documents as possibly transient — is an invitation to a '
              'panel to retry forever something no retry can fix. Two waves '
              'flagged this with no owner (10-07, 10-08, 10-09)');
      expect(error.message, contains(_RefusingTimeseries.permanentSentence),
          reason: 'and the source\'s own sentence survives the mapping: the '
              'reason a permanent refusal is worth a distinct code is that it '
              'tells the caller what to change, and a mapping that replaced '
              'the message with "invalid params" would take that back');
    });

    test('a retryable source refusal is left alone for the catch-all',
        () async {
      final kit = _kit(timeseries: _RefusingTimeseries(retryable: true));

      await expectLater(
          kit.handlers.timeseriesQuery(
              _params(DataServiceMethods.timeseriesQuery, {
            'table': _series,
            'to': _ms(_base.add(const Duration(days: 1))),
            'from': _ms(_base),
          })),
          throwsA(isA<SourceRefusal>()),
          reason: 'THE ANTI-VACUITY ARM, and the one that matters: "the '
              'historian is not connected" IS transient and -32011 is the '
              'right answer for it. A mapping that turned every source '
              'refusal into a bad request would tell a panel its perfectly '
              'good query was malformed, every time the database bounced');
    });
  });

  // ------------------------------------------------------------ preferences
  //
  // The last family, and the one whose *types* are the whole surface: a store
  // holds `Object?` and the wire promises seven typed accessors over it, so
  // what these bodies get wrong is never the round trip — it is a double that
  // comes back an int, a list that comes back a string, or a `800` a
  // hand-written client sent where Dart's own encoder would have written
  // `800.0`.
  group('preferences round-trip over the handler bodies', () {
    Future<Object?> get_(_Kit kit, String method,
            Future<Object?> Function(rpc.Parameters) body, String key) =>
        body(_params(method, {'key': key}));

    test('every typed setter stores what a getter reads back', () async {
      final kit = _kit();

      await kit.handlers.prefSetBool(
          _params(DataServiceMethods.prefSetBool, {'key': 'ui.dark', 'value': true}));
      await kit.handlers.prefSetInt(_params(
          DataServiceMethods.prefSetInt, {'key': 'chart.maxPoints', 'value': 800}));
      await kit.handlers.prefSetDouble(_params(DataServiceMethods.prefSetDouble,
          {'key': 'weigher.tolerance', 'value': 0.25}));
      await kit.handlers.prefSetString(_params(
          DataServiceMethods.prefSetString, {'key': 'site.name', 'value': 'Sæból'}));
      await kit.handlers.prefSetStringList(_params(
          DataServiceMethods.prefSetStringList,
          {'key': 'page.recent', 'value': ['frystir', 'pökkun']}));

      expect(
          await get_(kit, DataServiceMethods.prefGetBool,
              kit.handlers.prefGetBool, 'ui.dark'),
          isTrue);
      expect(
          await get_(kit, DataServiceMethods.prefGetInt,
              kit.handlers.prefGetInt, 'chart.maxPoints'),
          800);
      expect(
          await get_(kit, DataServiceMethods.prefGetDouble,
              kit.handlers.prefGetDouble, 'weigher.tolerance'),
          0.25);
      expect(
          await get_(kit, DataServiceMethods.prefGetString,
              kit.handlers.prefGetString, 'site.name'),
          'Sæból',
          reason: 'the site names here carry Icelandic characters, and a '
              'boundary that mangles them mangles them on every page header');
      expect(
          await get_(kit, DataServiceMethods.prefGetStringList,
              kit.handlers.prefGetStringList, 'page.recent'),
          ['frystir', 'pökkun']);
    });

    test('an integral JSON number is a double, not a refusal', () async {
      // **`asNum.toDouble()`, never `asDouble`** — the one decode in this
      // family that is a deliberate widening rather than a narrowing. Dart's
      // encoder writes an integral double as `800.0`, but a hand-written
      // client — a curl, a Python script, a panel written by the integrator —
      // sends `800`, and `jsonDecode` hands that back as an `int`. Refusing it
      // would be refusing a value the type admits
      // (`served_state_man.dart:683-692`).
      final kit = _kit();

      await kit.handlers.prefSetDouble(_params(
          DataServiceMethods.prefSetDouble,
          {'key': 'weigher.tolerance', 'value': 800}));

      final stored = await get_(kit, DataServiceMethods.prefGetDouble,
          kit.handlers.prefGetDouble, 'weigher.tolerance');
      expect(stored, 800.0);
      expect(stored, isA<double>(),
          reason: 'stored as an int, the next `getDouble` throws a TypeError '
              'the wire reports as -32010 — a settings page that saved a '
              'tolerance and cannot read it back');
    });

    test('containsKey tells absent from set-to-null, and remove is real',
        () async {
      final kit = _kit();
      await kit.handlers.prefSetBool(
          _params(DataServiceMethods.prefSetBool, {'key': 'ui.dark', 'value': true}));

      expect(
          await get_(kit, DataServiceMethods.prefContainsKey,
              kit.handlers.prefContainsKey, 'ui.dark'),
          isTrue);
      expect(
          await get_(kit, DataServiceMethods.prefContainsKey,
              kit.handlers.prefContainsKey, 'never.set'),
          isFalse,
          reason: '"absent" and "set to null" are different answers: a '
              'settings page renders the default for one and a blank for the '
              'other');

      await kit.handlers
          .prefRemove(_params(DataServiceMethods.prefRemove, {'key': 'ui.dark'}));

      expect(
          await get_(kit, DataServiceMethods.prefContainsKey,
              kit.handlers.prefContainsKey, 'ui.dark'),
          isFalse);
      expect(
          await get_(kit, DataServiceMethods.prefGetBool,
              kit.handlers.prefGetBool, 'ui.dark'),
          isNull);
    });

    test('getKeys and getAll answer the store, and honour an allow list',
        () async {
      final kit = _kit();
      await kit.handlers.prefSetInt(_params(
          DataServiceMethods.prefSetInt, {'key': 'chart.maxPoints', 'value': 800}));
      await kit.handlers.prefSetString(_params(
          DataServiceMethods.prefSetString, {'key': 'site.name', 'value': 'Sæból'}));

      expect(
          await kit.handlers.prefGetKeys(
              _params(DataServiceMethods.prefGetKeys, const {'allowList': null})),
          unorderedEquals(['chart.maxPoints', 'site.name']),
          reason: 'a list, not a set: JSON has no set, and the client rebuilds '
              'one on the far side');
      expect(
          await kit.handlers.prefGetAll(
              _params(DataServiceMethods.prefGetAll, const {'allowList': null})),
          containsPair('chart.maxPoints', 800));
      expect(
          await kit.handlers.prefGetKeys(_params(DataServiceMethods.prefGetKeys,
              const {'allowList': ['site.name']})),
          ['site.name'],
          reason: 'an allow list narrows the answer; a client that sends one '
              'is a settings page reading its own section of a store it '
              'shares with everything else on the site');
    });

    test('clear with an allow list removes only what it names', () async {
      final kit = _kit();
      await kit.handlers.prefSetInt(_params(
          DataServiceMethods.prefSetInt, {'key': 'chart.maxPoints', 'value': 800}));
      await kit.handlers.prefSetString(_params(
          DataServiceMethods.prefSetString, {'key': 'site.name', 'value': 'Sæból'}));

      await kit.handlers.prefClear(_params(DataServiceMethods.prefClear, const {
        'allowList': ['site.name'],
      }));

      expect(
          await kit.handlers.prefGetKeys(
              _params(DataServiceMethods.prefGetKeys, const {'allowList': null})),
          ['chart.maxPoints'],
          reason: 'an allow list on `clear` is the difference between wiping '
              'one page\'s settings and wiping the gateway\'s, `key_mappings` '
              'included. A handler that dropped the argument would take the '
              'plant\'s tag map with it');
    });

    test('a stored value of the wrong type is a TypeError, which the session '
        'answers as -32010', () async {
      // The gateway does **not** convert. `PreferencesApi` promises a
      // `TypeError` for a mismatch and 10-01 taught the client to read exactly
      // -32010 for it (`client_sub_apis.dart`'s `withTypedErrors`), so what
      // this body must do is let the store's cast throw and let
      // `RelaySession._answer` map it. A handler that caught and answered null
      // would render a default over a value that is really there.
      final kit = _kit();
      await kit.handlers.prefSetString(_params(
          DataServiceMethods.prefSetString, {'key': 'chart.maxPoints', 'value': 'lots'}));

      await expectLater(
          get_(kit, DataServiceMethods.prefGetInt, kit.handlers.prefGetInt,
              'chart.maxPoints'),
          throwsA(isA<TypeError>()),
          reason: 'the cast has to reach the session, which is the one place '
              'that knows -32010 is the wire code for it');
    });
  });

  group('a malformed preference parameter is refused, never coerced', () {
    test('a missing key is refused, naming the parameter', () async {
      final kit = _kit();

      final error = await _refusal(
          () => kit.handlers.prefGetBool(
              _params(DataServiceMethods.prefGetBool, const {})),
          'a getBool with no key');

      expect(error.code, rpc_error.INVALID_PARAMS);
      expect(error.message, contains('key'));
      expect((error.data! as Map)['request'], isNotNull,
          reason: 'every refusal on this wire carries a pre-substituted '
              '`data.request`, or `serialize` fills it with the offending '
              'request and one carrying 1e999 makes the error unencodable');
    });

    test('an empty key is refused', () async {
      final kit = _kit();

      final error = await _refusal(
          () => kit.handlers.prefGetString(
              _params(DataServiceMethods.prefGetString, const {'key': ''})),
          'a getString with an empty key');

      expect(error.code, rpc_error.INVALID_PARAMS);
    });

    test('a value of the wrong type is refused before the store', () async {
      final kit = _kit();

      final error = await _refusal(
          () => kit.handlers.prefSetBool(_params(
              DataServiceMethods.prefSetBool, {'key': 'ui.dark', 'value': 'true'})),
          'a setBool carrying the string "true"');

      expect(error.code, rpc_error.INVALID_PARAMS);
      expect(error.message, contains('bool'));
      expect(
          await kit.handlers.prefContainsKey(
              _params(DataServiceMethods.prefContainsKey, {'key': 'ui.dark'})),
          isFalse,
          reason: 'the refusal is pre-effect: a store holding the string '
              '"true" under a key every later `getBool` reads is a settings '
              'page that throws a TypeError forever');
    });

    test('a string list carrying a number is refused, not stringified',
        () async {
      // The port source writes `'$entry'` for each element, which turns `[1]`
      // into `['1']` silently. A gateway that coerces is a gateway that
      // decides what the client meant.
      final kit = _kit();

      final error = await _refusal(
          () => kit.handlers.prefSetStringList(_params(
              DataServiceMethods.prefSetStringList,
              {'key': 'page.recent', 'value': [1, 2]})),
          'a setStringList carrying numbers');

      expect(error.code, rpc_error.INVALID_PARAMS);
      expect(error.message, contains('index 0'));
    });

    test('an allow list carrying a non-string is refused', () async {
      final kit = _kit();

      final error = await _refusal(
          () => kit.handlers.prefGetKeys(_params(
              DataServiceMethods.prefGetKeys, const {'allowList': [7]})),
          'a getKeys whose allow list holds a number');

      expect(error.code, rpc_error.INVALID_PARAMS);
      expect(error.message, contains('allowList'));
    });

    test('an allow list that is not a list at all is refused', () async {
      final kit = _kit();

      final error = await _refusal(
          () => kit.handlers.prefClear(_params(
              DataServiceMethods.prefClear, const {'allowList': 'site.name'})),
          'a clear whose allow list is a bare string');

      expect(error.code, rpc_error.INVALID_PARAMS);
      expect(error.message, contains('allowList'));
    });
  });

  group('the changed notification is one frame per burst', () {
    test('a five-hundred-key clear announces once, naming five hundred keys',
        () async {
      // The coalescing property, judged at the body rather than over a socket:
      // `preferences_notify_test.dart` runs the same burst through the real
      // priority lane. Both are worth having — this one can count the source's
      // own events, which is what makes the assertion non-vacuous.
      final sent = <({String method, Map<String, Object?> params})>[];
      final kit = _kit(sent: sent);
      kit.handlers.watchPreferences();
      addTearDown(kit.handlers.releasePreferenceWatch);

      final store = kit.api.preferences;
      for (var i = 0; i < 500; i++) {
        await store.setInt('svn.page.$i', i);
      }
      // Everything above is a burst the watcher has already coalesced; what is
      // measured is the `clear` below.
      await pumpEventQueue();
      sent.clear();

      final sourceEvents = <String>[];
      final tap = store.onPreferencesChanged.listen(sourceEvents.add);
      addTearDown(tap.cancel);

      await store.clear();
      await pumpEventQueue();

      expect(sourceEvents, hasLength(500),
          reason: 'the anti-vacuity arm, and it goes first: the store really '
              'does fire once per key, so "one frame" below is coalescing '
              'rather than a store that announced a clear as a single event. '
              'Without this the case would pass against a source that said '
              'nothing at all');
      expect(sent, hasLength(1),
          reason: 'five hundred frames in the priority lane is a '
              'BufferDisconnect and a 4004 — a settings page evicting every '
              'panel in the plant, reported to the operator as backpressure '
              '(T-10-19). The lane is byte-capped, entry-capped, drained only '
              'by the tick and **not conflated**, so nothing downstream of '
              'here would have merged them');
      expect(sent.single.method, 'preferences.changed');
      expect(sent.single.params['keys'], hasLength(500));
    });

    test('a key written twice in one burst is named once', () async {
      final sent = <({String method, Map<String, Object?> params})>[];
      final kit = _kit(sent: sent);
      kit.handlers.watchPreferences();
      addTearDown(kit.handlers.releasePreferenceWatch);

      final store = kit.api.preferences;
      await store.setInt('chart.maxPoints', 800);
      await store.setInt('chart.maxPoints', 900);
      await pumpEventQueue();

      expect(sent, hasLength(1));
      expect(sent.single.params['keys'], ['chart.maxPoints'],
          reason: 'a **set**, not a list. A key saved twice while an operator '
              'held the slider is one key that changed, and a frame naming it '
              'twice makes every listener redraw twice');
    });

    test('a source with no preference store is not a startup failure',
        () async {
      final sent = <({String method, Map<String, Object?> params})>[];
      final kit = _kit(preferences: _NoPreferenceStore(), sent: sent);

      kit.handlers.watchPreferences();
      addTearDown(kit.handlers.releasePreferenceWatch);

      expect(sent, isEmpty);
      expect(
          await kit.handlers.browseFetchRoots(_params('browse.fetchRoots', {})),
          isNotEmpty,
          reason: 'a declared absence is not a startup failure: the rest of '
              'the surface has to keep answering. `UnsupportedError` is the '
              'one thing caught here, and nothing else, because nothing else '
              'is a shape a correct source can have');
    });
  });

  // 10-REVIEW IN-01, and the third place this pattern has been caught (10-08
  // found the first two). A `Future`-returning method whose body is not
  // `async` evaluates its argument guards BEFORE the delegated future exists,
  // so a refusal throws synchronously and a caller holding the future never
  // sees it. Defused on the wire by `RelaySession._on`'s
  // `() async => handler(params)` wrapper — which is why it is Info rather
  // than a wire defect — but a direct caller is a caller too, and a direct
  // caller is exactly how the earlier instances were found.
  group('every handler rejects its future rather than throwing out of it', () {
    /// Every guard-bearing handler whose body is one delegation, by name.
    ///
    /// The seven the review named plus the two `_viewId` ones beside them: the
    /// argument is about the shape of the body, so the list is every body of
    /// that shape rather than the ones that happened to be noticed.
    Map<String, Future<Object?> Function(DataHandlers)> delegating() =>
        <String, Future<Object?> Function(DataHandlers)>{
          'prefGetBool': (h) =>
              h.prefGetBool(_params(DataServiceMethods.prefGetBool, {})),
          'prefGetInt': (h) =>
              h.prefGetInt(_params(DataServiceMethods.prefGetInt, {})),
          'prefGetDouble': (h) =>
              h.prefGetDouble(_params(DataServiceMethods.prefGetDouble, {})),
          'prefGetString': (h) =>
              h.prefGetString(_params(DataServiceMethods.prefGetString, {})),
          'prefGetStringList': (h) => h.prefGetStringList(
              _params(DataServiceMethods.prefGetStringList, {})),
          'prefContainsKey': (h) =>
              h.prefContainsKey(_params(DataServiceMethods.prefContainsKey, {})),
          'historyGetKeyNames': (h) => h.historyGetKeyNames(
              _params(DataServiceMethods.historyGetKeyNames, {})),
          'historyGetKeys': (h) =>
              h.historyGetKeys(_params(DataServiceMethods.historyGetKeys, {})),
          'historyGetGraphs': (h) => h.historyGetGraphs(
              _params(DataServiceMethods.historyGetGraphs, {})),
        };

    for (final entry in delegating().entries) {
      test('${entry.key} refuses through the future it returned', () async {
        final kit = _kit();

        // **The call is NOT inside a try.** That is the whole case: a
        // synchronous throw fails here, on this line, which is what a caller
        // using `.catchError` experiences — the refusal arriving somewhere it
        // cannot be caught.
        final pending = entry.value(kit.handlers);

        Object? caught;
        await pending.then<void>((_) {}, onError: (Object error) {
          caught = error;
        });

        expect(caught, isA<rpc.RpcException>(),
            reason: 'the missing parameter has to come back as a rejected '
                'future. Wrapped by RelaySession._on it reaches the wire '
                'either way, so what this defends is a direct caller — a unit '
                'test or an embedder — and the fact that the next handler '
                'added here will be copied from one of these bodies');
        expect((caught! as rpc.RpcException).code, rpc_error.INVALID_PARAMS);
      });
    }
  });
}

/// A store that declares it has no change stream at all.
///
/// The shape `served_state_man.dart:428-437` catches: a source with no
/// preference store is legitimate — the data-services sub-suite is skipped for
/// it, with a reason on the record — and refusing to serve it would turn a
/// declared absence into a startup failure.
final class _NoPreferenceStore extends FakePreferences {
  @override
  Stream<String> get onPreferencesChanged =>
      throw UnsupportedError('this source has no preference change stream');
}

/// One decoded sample list, as the wire would carry it.
List<Map<String, Object?>> _samples(Object? raw) => [
      for (final entry in raw! as List) (entry as Map).cast<String, Object?>(),
    ];

/// One decoded JSON object, cast where the handler hands back `Object?`.
Map<String, Object?> _object(Object? raw) =>
    (raw! as Map).cast<String, Object?>();

/// One decoded list of JSON objects — a view list, a period list.
List<Map<String, Object?>> _objects(Object? raw) =>
    [for (final entry in raw! as List) _object(entry)];

/// A source that refuses every raw query as too large.
///
/// Nothing raises [ResultTooLarge] yet — 10-07's reader and 10-10's byte
/// ceiling do — so the mapping is driven from a source that throws it. That is
/// the honest way round: the *code* the wire answers is chosen at the handler
/// and deliberately not inside the exception (`result_too_large.dart:26-31`),
/// so the handler is where it has to be asserted.
final class _TooLargeTimeseries extends FakeTimeseries {
  /// A month of one-second samples, which is the number
  /// `result_too_large.dart` uses to make "rows" and "bytes" feel different.
  static const limit = 2678400;

  @override
  Future<List<TimeseriesData>> queryTimeseriesData(
          String tableName, DateTime to,
          {String? orderBy = 'time ASC', DateTime? from}) async =>
      throw const ResultTooLarge.rows(
        limit: limit,
        measured: limit * 2,
        suggestion: DataServiceMethods.timeseriesQueryDownsampled,
      );
}

/// A source that refuses every raw window, transiently or permanently.
///
/// Stands in for `tfc_relay_local`'s `TimeseriesReadRefusal` family, which this
/// package cannot name: the dependency edge runs local → server and never the
/// other way. What crosses the boundary is [SourceRefusal], and this is a
/// minimal implementation of it — which is also the point, because a mapping
/// that only worked for the one concrete family would not be a mapping.
final class _RefusingTimeseries extends FakeTimeseries {
  _RefusingTimeseries({required this.retryable});

  static const permanentSentence =
      'no series named "ST101.CN01.MOT01.speed" is collected by this gateway';

  final bool retryable;

  @override
  Future<List<TimeseriesData>> queryTimeseriesData(
          String tableName, DateTime to,
          {String? orderBy = 'time ASC', DateTime? from}) async =>
      throw _Refusal(
          retryable,
          retryable
              ? 'the historian is not connected; this is worth retrying'
              : permanentSentence);
}

final class _Refusal implements SourceRefusal {
  const _Refusal(this.retryable, this.message);

  @override
  final bool retryable;

  @override
  final String message;

  @override
  String toString() => message;
}

/// A store whose whole answer is over the byte ceiling.
///
/// The shape 10-10's `PreferenceStore` raises: bytes rather than rows, exact
/// rather than a floor, and the allow-list named as the way out.
final class _TooLargePreferences extends FakePreferences {
  static const limit = 1024 * 1024;

  @override
  Future<Map<String, Object?>> getAll({Set<String>? allowList}) async =>
      throw const ResultTooLarge.bytes(
        limit: limit,
        measured: limit + 1,
        suggestion: '${DataServiceMethods.prefGetAll} with an allowList '
            'naming the keys this page actually needs',
      );
}

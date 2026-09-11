/// The historical half of the backend adapter, judged without a Postgres.
///
/// Every arm here runs against the seams `backend_data_services.dart` declares
/// over the backend's own `Database` / `AppDatabase` / `Preferences`. That is
/// deliberate and it is bounded: these arms prove the **mapping and the
/// refusals**, and they prove nothing whatsoever about the database. The
/// real-database judgement is 13-09's `db`-tagged lane, which swaps a live
/// TimescaleDB in behind the same three seams.
///
/// What the seams let an arm see that a live database could not:
///
///  * **what the source was asked for**, not only what it answered — the only
///    way to assert that downsampling happened where the data is rather than
///    in Dart after a full read;
///  * a source that answers **more rows than it was asked for**, which is what
///    `Database.queryTimeseriesDataDownsampled`'s silent fallback to a raw
///    query looks like from here (`database.dart:991`);
///  * a change feed whose listener count an arm can read, which is how
///    "nothing is armed until something listens" is asserted rather than
///    hoped.
library;

import 'dart:async';
import 'dart:io';
import 'dart:mirrors';

import 'package:test/test.dart';
import 'package:tfc_dart/core/database.dart' as db;
import 'package:tfc_dart/core/database_drift.dart' as drift;
import 'package:tfc_dart/core/relay/backend_data_services.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' show StateManApi;
import 'package:tfc_stateman_contract/testing/runner_budget.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart'
    show StateManDataHarness, runDataServicesContract;

// ---------------------------------------------------------------- the fixture

/// The wire names this fixture's resolver knows, and the tables behind them.
///
/// Spelled the way the contract's own fixture spells them — table-shaped, not
/// key-shaped — because `data_services_contract.dart:52` names its series
/// `st101_cn01_mot01_setpoint` and this file's arms and 13-09's contract run
/// must agree about what a resolvable name looks like.
const _table = 'st101_cn01_mot01_setpoint';
const _otherTable = 'st201_cn04_mot01_setpoint';
const _structTable = 'st301_cn01_drv01';
const _arrayTable = 'sb1_checkweigher_heads';

/// A resolver over a literal map: 13-04's `KeyMappingSeriesResolver` is the
/// production one and needs a whole `KeyMappings` to build, which is a fixture
/// about browse rather than about history.
final class _FixtureResolver implements relay.SeriesResolver {
  const _FixtureResolver();

  static const _tables = <String, String>{
    _table: _table,
    _otherTable: _otherTable,
    _structTable: _structTable,
    _arrayTable: _arrayTable,
  };

  @override
  relay.ResolvedSeries? resolve(String wireName) {
    final address = relay.SeriesAddress.parse(wireName);
    final table = _tables[address.series];
    if (table == null) return null;
    return relay.ResolvedSeries(
        table: table, member: address.member, plantKey: address.series);
  }

  @override
  String? keyForTable(String table) => _tables.containsKey(table) ? table : null;

  @override
  String? keyForNode(String nodeId) => null;
}

/// One call the fake was asked to make, recorded in full.
final class _Ask {
  const _Ask(this.method, this.table, {this.maxPoints, this.from, this.to});
  final String method;
  final String table;
  final int? maxPoints;
  final DateTime? from;
  final DateTime? to;

  @override
  String toString() =>
      '$method($table${maxPoints == null ? '' : ', maxPoints: $maxPoints'})';
}

/// A `TimeseriesSource` over three in-memory tables.
///
/// Downsamples honestly — evenly spaced, both ends kept — so an arm asserting
/// the point budget is asserting the budget the adapter handed down, not this
/// fake's arithmetic.
final class _FakeTimeseries implements TimeseriesSource {
  final Map<String, List<db.TimeseriesData<dynamic>>> rows = {};
  final List<_Ask> asks = <_Ask>[];

  /// When set, `queryTimeseriesDataDownsampled` ignores its budget and answers
  /// everything — which is exactly what `Database`'s silent fallback to a raw
  /// query does for a column type it cannot bucket.
  bool downsampleFallsBack = false;

  /// When set, `queryTimeseriesDataDownsampled` answers exactly this many
  /// rows — the other way the budget gets exceeded. The bucketed path emits
  /// three rows per bucket, so when the bucket sizing and `time_bucket`'s
  /// alignment disagree about how many buckets a window spans it overruns by
  /// a whole bucket and no more (13-12: 51 for a budget of 50). That is a
  /// different defect, in a different file, from the fallback above.
  int? downsampleAnswers;

  void seed(String table, List<db.TimeseriesData<dynamic>> points) =>
      rows[table] = points;

  List<db.TimeseriesData<dynamic>> _window(
      String table, DateTime? from, DateTime to) {
    final all = rows[table] ?? const <db.TimeseriesData<dynamic>>[];
    return [
      for (final point in all)
        if (!point.time.isAfter(to) && (from == null || !point.time.isBefore(from)))
          point,
    ];
  }

  @override
  Future<List<db.TimeseriesData<dynamic>>> queryTimeseriesData(
      String tableName, DateTime to,
      {String? orderBy = 'time ASC', DateTime? from}) async {
    asks.add(_Ask('queryTimeseriesData', tableName, from: from, to: to));
    final window = _window(tableName, from, to);
    return orderBy == 'time DESC' ? window.reversed.toList() : window;
  }

  @override
  Future<Map<String, List<db.TimeseriesData<dynamic>>>>
      queryTimeseriesDataMultiple(List<String> tableNames, DateTime to,
          {String? orderBy = 'time ASC', DateTime? from}) async {
    for (final table in tableNames) {
      asks.add(_Ask('queryTimeseriesDataMultiple', table, from: from, to: to));
    }
    // Verbatim the shape `Database` answers with: a table it has nothing for
    // simply has no entry, which is the hole the adapter has to fill.
    return {
      for (final table in tableNames)
        if (_window(table, from, to).isNotEmpty)
          table: _window(table, from, to),
    };
  }

  @override
  Future<List<db.TimeseriesData<dynamic>>> queryTimeseriesDataDownsampled(
      String tableName, DateTime from, DateTime to,
      {int maxPoints = 1000}) async {
    asks.add(_Ask('queryTimeseriesDataDownsampled', tableName,
        maxPoints: maxPoints, from: from, to: to));
    final window = _window(tableName, from, to);
    if (downsampleAnswers != null) return window.take(downsampleAnswers!).toList();
    if (downsampleFallsBack || window.length <= maxPoints) return window;
    final step = (window.length - 1) / (maxPoints - 1);
    return [
      for (var i = 0; i < maxPoints; i++) window[(i * step).round()],
    ];
  }

}

/// A minute apart, ascending, starting at [base].
List<db.TimeseriesData<dynamic>> _minutely(DateTime base, int count) => [
      for (var i = 0; i < count; i++)
        db.TimeseriesData<dynamic>(1200 + i, base.add(Duration(minutes: i))),
    ];

final _base = DateTime.utc(2026, 8, 13, 6);

BackendTimeseries _timeseries(_FakeTimeseries? source,
        {TimeseriesLimits? limits}) =>
    BackendTimeseries(
      source: source,
      resolver: const _FixtureResolver(),
      limits: limits ?? TimeseriesLimits(),
    );

// ------------------------------------------------------------- history views

/// Two plotted keys, in the plant's tag convention.
const _keyA = 'ST101.CN01.MOT01.setpoint';
const _keyB = 'ST301.CN21.SEN01.temp';

/// A `HistoryViewSource` over four in-memory tables.
///
/// Answers the generated row classes and the untyped bags the drift layer
/// answers with, verbatim — mapping those onto the protocol's plain records is
/// what [BackendHistoryViews] is for and what these arms judge.
final class _FakeHistoryViews implements HistoryViewSource {
  final Map<int, drift.HistoryViewData> _views = {};
  final Map<int, Map<String, Map<String, dynamic>>> _keys = {};
  final Map<int, Map<int, Map<String, dynamic>>> _graphs = {};
  final Map<int, drift.HistoryViewPeriodData> _periods = {};
  int _nextId = 0;

  /// When set, every instant is handed back the way an unnormalised driver
  /// hands one back.
  bool handBackLocalTimes = false;

  DateTime _out(DateTime t) => handBackLocalTimes ? t.toLocal() : t;

  static final _created = DateTime.utc(2026, 8, 1, 9);

  @override
  Future<int> createHistoryView(String name, List<String> keys,
      [Map<String, Map<String, dynamic>>? keyConfigs,
      Map<String, Map<String, dynamic>>? graphConfigs]) async {
    final id = ++_nextId;
    _views[id] = drift.HistoryViewData(id: id, name: name, createdAt: _created);
    _writeKeys(id, keys, keyConfigs);
    _writeGraphs(id, graphConfigs);
    return id;
  }

  @override
  Future<void> updateHistoryView(int id, String name, List<String> keys,
      [Map<String, Map<String, dynamic>>? keyConfigs,
      Map<String, Map<String, dynamic>>? graphConfigs]) async {
    final was = _views[id];
    if (was == null) return;
    _views[id] = drift.HistoryViewData(
        id: id,
        name: name,
        createdAt: was.createdAt,
        updatedAt: DateTime.utc(2026, 8, 2, 9));
    _keys.remove(id);
    _graphs.remove(id);
    _writeKeys(id, keys, keyConfigs);
    _writeGraphs(id, graphConfigs);
  }

  void _writeKeys(int id, List<String> keys,
      Map<String, Map<String, dynamic>>? keyConfigs) {
    if (keys.isEmpty) return;
    _keys[id] = {
      for (final key in keys)
        key: {
          'key': key,
          'alias': keyConfigs?[key]?['alias'] ?? key,
          'useSecondYAxis': keyConfigs?[key]?['useSecondYAxis'] ?? false,
          'graphIndex': keyConfigs?[key]?['graphIndex'] ?? 0,
        },
    };
  }

  void _writeGraphs(int id, Map<String, Map<String, dynamic>>? graphConfigs) {
    if (graphConfigs == null) return;
    _graphs[id] = {
      for (final entry in graphConfigs.entries)
        if (int.tryParse(entry.key) != null)
          int.parse(entry.key): {
            'name': entry.value['name'] ?? '',
            'yAxisUnit': entry.value['yAxisUnit'] ?? '',
            'yAxis2Unit': entry.value['yAxis2Unit'] ?? '',
          },
    };
  }

  @override
  Future<void> deleteHistoryView(int id) async {
    _views.remove(id);
    _keys.remove(id);
    _graphs.remove(id);
    _periods.removeWhere((_, period) => period.viewId == id);
  }

  @override
  Future<List<drift.HistoryViewData>> selectHistoryViews() async => [
        for (final view in _views.values)
          drift.HistoryViewData(
              id: view.id,
              name: view.name,
              createdAt: _out(view.createdAt),
              updatedAt:
                  view.updatedAt == null ? null : _out(view.updatedAt!)),
      ];

  @override
  Future<Map<String, Map<String, dynamic>>> getHistoryViewKeys(
          int viewId) async =>
      _keys[viewId] ?? const {};

  @override
  Future<Map<int, Map<String, dynamic>>> getHistoryViewGraphs(
          int viewId) async =>
      _graphs[viewId] ?? const {};

  @override
  Future<List<String>> getHistoryViewKeyNames(int viewId) async =>
      (_keys[viewId] ?? const <String, Map<String, dynamic>>{}).keys.toList();

  @override
  Future<int> addHistoryViewPeriod(
      int viewId, String name, DateTime start, DateTime end) async {
    final id = ++_nextId;
    _periods[id] = drift.HistoryViewPeriodData(
        id: id,
        viewId: viewId,
        name: name,
        startAt: start,
        endAt: end,
        createdAt: _created);
    return id;
  }

  @override
  Future<void> deleteHistoryViewPeriod(int id) async => _periods.remove(id);

  @override
  Future<List<drift.HistoryViewPeriodData>> listHistoryViewPeriods(
          int viewId) async =>
      [
        for (final period in _periods.values)
          if (period.viewId == viewId)
            drift.HistoryViewPeriodData(
                id: period.id,
                viewId: period.viewId,
                name: period.name,
                startAt: _out(period.startAt),
                endAt: _out(period.endAt),
                createdAt: _out(period.createdAt)),
      ];

  @override
  Future<DateTime?> getGlobalRetentionHorizon() async =>
      _out(DateTime.utc(2025, 9, 6));
}

// --------------------------------------------------------------- preferences

const _prefKey = 'svn.ui.darkMode';
const _clearedKey = 'svn.chart.maxPoints';

/// A `PreferenceSource` over one map and one broadcast controller.
///
/// [feedListeners] is the number the listener-gating arm reads: a real
/// `Preferences` hides its controller behind a getter, and an arm that cannot
/// count subscriptions cannot tell an armed feed from a dormant one.
final class _FakePreferences implements PreferenceSource {
  final Map<String, Object?> _store = {};
  final List<Set<String>> deleted = <Set<String>>[];
  int feedListeners = 0;

  late final StreamController<String> _changes =
      StreamController<String>.broadcast(
    onListen: () => feedListeners++,
    onCancel: () => feedListeners--,
  );

  @override
  Stream<String> get onPreferencesChanged => _changes.stream;

  @override
  Future<Set<String>> getKeys({Set<String>? allowList}) async => allowList ==
          null
      ? _store.keys.toSet()
      : _store.keys.where(allowList.contains).toSet();

  @override
  Future<Map<String, Object?>> getAll({Set<String>? allowList}) async =>
      allowList == null
          ? Map.of(_store)
          : {
              for (final entry in _store.entries)
                if (allowList.contains(entry.key)) entry.key: entry.value,
            };

  @override
  Future<bool?> getBool(String key) async => _store[key] as bool?;
  @override
  Future<int?> getInt(String key) async => _store[key] as int?;
  @override
  Future<double?> getDouble(String key) async => _store[key] as double?;
  @override
  Future<String?> getString(String key) async => _store[key] as String?;
  @override
  Future<List<String>?> getStringList(String key) async =>
      _store[key] as List<String>?;
  @override
  Future<bool> containsKey(String key) async => _store.containsKey(key);

  void _set(String key, Object? value) {
    _store[key] = value;
    _changes.add(key);
  }

  @override
  Future<void> setBool(String key, bool value) async => _set(key, value);
  @override
  Future<void> setInt(String key, int value) async => _set(key, value);
  @override
  Future<void> setDouble(String key, double value) async => _set(key, value);
  @override
  Future<void> setString(String key, String value) async => _set(key, value);
  @override
  Future<void> setStringList(String key, List<String> value) async =>
      _set(key, value);

  @override
  Future<void> remove(String key) async {
    _store.remove(key);
    deleted.add({key});
    _changes.add(key);
  }

  @override
  Future<void> clearFromMemory({Set<String>? allowList}) async {
    if (allowList == null) {
      _store.clear();
    } else {
      _store.removeWhere((key, _) => allowList.contains(key));
    }
  }

  @override
  Future<void> deletePreferenceRows(Set<String> keys) async =>
      deleted.add(keys);
}

// -------------------------------------------------------- the contract's api

/// A `StateManApi` whose only real collaborators are this plan's three.
final class _DataOnlyApi implements StateManApi, StateManDataHarness {
  _DataOnlyApi()
      : _ts = _FakeTimeseries(),
        _hv = _FakeHistoryViews(),
        _prefs = _FakePreferences();

  final _FakeTimeseries _ts;
  final _FakeHistoryViews _hv;
  final _FakePreferences _prefs;

  @override
  void seedTimeseries(String tableName, List<relay.TimeseriesData> points) =>
      _ts.seed(tableName, [
        for (final point in points)
          db.TimeseriesData<dynamic>(point.value, point.time),
      ]);

  @override
  late final relay.TimeseriesApi timeseries = BackendTimeseries(
      source: _ts, resolver: const _FixtureResolver(), limits: TimeseriesLimits());

  @override
  late final relay.HistoryViewApi historyViews =
      BackendHistoryViews(source: _hv);

  @override
  late final relay.PreferencesApi preferences =
      BackendPreferences(source: _prefs);

  Never _notPartOfThisFixture(String member) => throw UnsupportedError(
      'the data-services fixture composed no $member; a case reached outside '
      'the three historical sub-interfaces, which this fixture cannot answer '
      'honestly');

  // The four access families (17-03). Deliberately not part of this fixture:
  // a data-services case that reached one is a case in the wrong file, and
  // this says so instead of answering emptily.
  @override
  relay.AccessTemplateApi get accessTemplates =>
      _notPartOfThisFixture('access template store');

  @override
  relay.AccessAdminApi get accessAdmin =>
      _notPartOfThisFixture('access admin store');

  @override
  relay.AuditApi get audit => _notPartOfThisFixture('audit trail store');

  @override
  relay.BackendConfigApi get backendConfig =>
      _notPartOfThisFixture('backend config document');

  /// The historical half has no link to bring up: it is serving from the
  /// instant the constructor returns.
  @override
  relay.DynamicValue? read(String key) => key == relay.PipeKeys.connected
      ? relay.DynamicValue(value: true)
      : _notPartOfThisFixture('value source');

  @override
  relay.ValueListenable<relay.DynamicValue> listen(String key) =>
      _notPartOfThisFixture('value source');
  @override
  Stream<relay.DynamicValue> subscribe(String key) =>
      _notPartOfThisFixture('value source');
  @override
  Future<relay.DynamicValue> readFresh(String key) async =>
      _notPartOfThisFixture('value source');
  @override
  Future<Map<String, relay.DynamicValue>> readMany(List<String> keys) async =>
      _notPartOfThisFixture('value source');
  @override
  List<String> get keys => _notPartOfThisFixture('value source');
  @override
  Future<relay.WriteResult> write(String key, Object? value,
          {Object? expect, String? cmd}) async =>
      _notPartOfThisFixture('write source');
  @override
  Future<List<relay.WriteResult>> writeStatus(List<String> cmds) async =>
      _notPartOfThisFixture('write source');
  @override
  Future<relay.HoldHandle> holdToRun(String key) async =>
      _notPartOfThisFixture('write source');
  @override
  relay.BrowseApi get browse => _notPartOfThisFixture('BrowseApi');
  @override
  Future<void> dispose() async {}
}

/// The instance members [type] declares, excluding accessors it inherits from
/// `Object` — 13-01's roster idiom, kept local.
Set<String> _membersOf(Type type) {
  final mirror = reflectClass(type);
  return {
    for (final declaration in mirror.declarations.values)
      if (declaration is MethodMirror &&
          !declaration.isConstructor &&
          !declaration.isStatic)
        MirrorSystem.getName(declaration.simpleName),
  };
}

/// [source] with Dart line comments removed.
String _stripDartComments(String source) => source
    .split('\n')
    .map((line) {
      final slashes = line.indexOf('//');
      return slashes < 0 ? line : line.substring(0, slashes);
    })
    .join('\n');

void main() {
  useRunnerBudgets();

  group('BackendTimeseries', () {
    test('a recorded series comes back in order, mapped onto the wire type',
        () async {
      final fake = _FakeTimeseries()..seed(_table, _minutely(_base, 7));
      final got = await _timeseries(fake).queryTimeseriesData(
          _table, _base.add(const Duration(minutes: 5)),
          from: _base.add(const Duration(minutes: 1)));

      expect(got.map((p) => p.time).toList(), [
        for (var i = 1; i <= 5; i++) _base.add(Duration(minutes: i)),
      ], reason: 'a line chart joins consecutive points and nothing sorts them '
          'on the way to the screen');
      expect(got.map((p) => p.value).toList(), [1201, 1202, 1203, 1204, 1205]);
      expect(got.first, isA<relay.TimeseriesData>(),
          reason: 'the wire carries the protocol\'s sample type, not '
              'tfc_dart\'s — they are different classes with the same name');
      expect(got.first.time.isUtc, isTrue,
          reason: 'every instant on this wire is absolute');
    });

    test('every requested series gets an entry, including the silent one',
        () async {
      final fake = _FakeTimeseries()..seed(_table, _minutely(_base, 5));
      final got = await _timeseries(fake).queryTimeseriesDataMultiple(
          [_table, _otherTable], _base.add(const Duration(hours: 1)),
          from: _base);

      expect(got.keys, containsAll([_table, _otherTable]),
          reason: 'a name with no entry is a series the chart drops from its '
              'legend, which reads as "this tag is flat" rather than as '
              '"nothing was recorded"');
      expect(got[_otherTable], isEmpty);
      expect(got[_table], hasLength(5));
    });

    test('a downsample is asked of the source with the caller\'s budget, and '
        'no raw read is made', () async {
      final fake = _FakeTimeseries()
        ..seed(_table, [
          for (var i = 0; i < 500; i++)
            db.TimeseriesData<dynamic>(i, _base.add(Duration(seconds: i))),
        ]);
      final to = _base.add(const Duration(seconds: 499));
      final got = await _timeseries(fake)
          .queryTimeseriesDataDownsampled(_table, _base, to, maxPoints: 50);

      expect(got, hasLength(lessThanOrEqualTo(50)));
      expect(got.first.time, _base);
      expect(got.last.time, to);

      // The property, and the only spelling of it that bites: a Dart-side
      // downsample would satisfy every assertion above while having asked the
      // database for all five hundred rows.
      expect(fake.asks.map((a) => a.method).toList(),
          ['queryTimeseriesDataDownsampled'],
          reason: 'downsampling happens where the data is. A raw read '
              'followed by a trim in Dart ships a month of one-second samples '
              'across a link that exists to avoid exactly that');
      expect(fake.asks.single.maxPoints, 50,
          reason: 'the caller\'s point budget must reach the database, not be '
              're-invented on the way');
    });

    test('a maxPoints over the configured ceiling is refused by name',
        () async {
      final fake = _FakeTimeseries();
      await expectLater(
          () => _timeseries(fake, limits: TimeseriesLimits(maxPoints: 6000))
              .queryTimeseriesDataDownsampled(
                  _table, _base, _base.add(const Duration(days: 30)),
                  maxPoints: 900000),
          throwsA(isA<ArgumentError>()
              .having((e) => '${e.message}', 'message',
                  allOf(contains('maxPoints'), contains('6000'), contains('900000')))),
          reason: 'the refusal names the bound and the value asked for, or an '
              'integrator cannot tell which knob to move');
      expect(fake.asks, isEmpty,
          reason: 'the bound is enforced BEFORE the query; a read that has '
              'already run has already cost what the bound exists to prevent');
    });

    test('a maxPoints under the floor the database silently falls back at is '
        'refused by name', () async {
      final fake = _FakeTimeseries();
      await expectLater(
          () => _timeseries(fake).queryTimeseriesDataDownsampled(
              _table, _base, _base.add(const Duration(days: 30)),
              maxPoints: 2),
          throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message',
              allOf(contains('maxPoints'), contains('3')))),
          reason: 'below three, `(maxPoints / 3).floor()` is zero and '
              'queryTimeseriesDataDownsampled answers a full raw read under '
              'the bounded method\'s name (database.dart:1570-1573)');
      expect(fake.asks, isEmpty);
    });

    test('a source that answers past the budget it was given is refused, not '
        'passed on', () async {
      final fake = _FakeTimeseries()
        ..downsampleFallsBack = true
        ..seed(_table, [
          for (var i = 0; i < 500; i++)
            db.TimeseriesData<dynamic>(i, _base.add(Duration(seconds: i))),
        ]);
      await expectLater(
          () => _timeseries(fake).queryTimeseriesDataDownsampled(
              _table, _base, _base.add(const Duration(seconds: 499)),
              maxPoints: 50),
          throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message',
              allOf(contains('50'), contains('500')))),
          reason: 'queryTimeseriesDataDownsampled falls back to a raw query '
              'for a column type it cannot bucket, silently '
              '(database.dart:991). Passing that on is a million rows into a '
              'socket under the bounded method\'s name');
    });

    test('a one-bucket overshoot is refused as a sizing bug, not as the raw '
        'fallback', () async {
      // The refusal is read by whoever has to fix it, and the two ways past
      // the budget live in different files. 51 for a budget of 50 is three
      // rows — one bucket — and a raw read of this window would have been
      // 500. Naming the fallback here would send the next reader to
      // `database.dart:991` and a struct-table story that does not apply,
      // when the defect is in the bucket sizing a thousand lines below it.
      final fake = _FakeTimeseries()
        ..downsampleAnswers = 51
        ..seed(_table, [
          for (var i = 0; i < 500; i++)
            db.TimeseriesData<dynamic>(i, _base.add(Duration(seconds: i))),
        ]);
      await expectLater(
          () => _timeseries(fake).queryTimeseriesDataDownsampled(
              _table, _base, _base.add(const Duration(seconds: 499)),
              maxPoints: 50),
          throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message',
              allOf(
                contains('50'),
                contains('51'),
                contains('time_bucket'),
                isNot(contains('database.dart:991')),
              ))),
          reason: 'a three-row overshoot diagnosed as the silent raw fallback '
              'sends the next reader to the wrong file');
    });

    test('a read wider than the row budget is refused, naming the bounded '
        'method that would answer it', () async {
      final fake = _FakeTimeseries()..seed(_table, _minutely(_base, 40));
      await expectLater(
          () => _timeseries(fake, limits: TimeseriesLimits(maxRows: 10))
              .queryTimeseriesData(_table, _base.add(const Duration(days: 1)),
                  from: _base),
          throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message',
              allOf(contains('10'), contains('40'),
                  contains('queryTimeseriesDataDownsampled')))),
          reason: 'a refusal that does not name the method which answers the '
              'same question inside the limit leaves the operator with a '
              'chart that will not draw and no way forward');
    });

    test('the row budget is the SUM across a multi-series read', () async {
      final fake = _FakeTimeseries()
        ..seed(_table, _minutely(_base, 8))
        ..seed(_otherTable, _minutely(_base, 8));
      await expectLater(
          () => _timeseries(fake, limits: TimeseriesLimits(maxRows: 10))
              .queryTimeseriesDataMultiple(
                  [_table, _otherTable], _base.add(const Duration(days: 1)),
                  from: _base),
          throwsA(isA<ArgumentError>()),
          reason: 'four tables each at the cap is four times the budget in '
              'one frame, arrived at by obeying the limit four times');
    });

    test('a series the resolver does not know is refused, and never reaches a '
        'statement', () async {
      final fake = _FakeTimeseries();
      await expectLater(
          () => _timeseries(fake)
              .queryTimeseriesData('flutter_preferences', _base),
          throwsA(isA<ArgumentError>()));
      expect(fake.asks, isEmpty,
          reason: 'T-13-05-b: the layer below interpolates client strings '
              'into SQL (database_drift.dart\'s tableQuery), so a name the '
              'resolver never approved must not reach the source');
    });

    test('a malformed series name throws rather than resolving to nothing',
        () async {
      await expectLater(
          () => _timeseries(_FakeTimeseries())
              .queryTimeseriesData('a:b:c', _base),
          throwsA(isA<FormatException>()),
          reason: '"you spelled it wrong" and "there is no such series" are '
              'two different facts and the caller acts on them differently');
    });

    test('an orderBy outside the two-value allow list is refused, not '
        'sanitized', () async {
      final fake = _FakeTimeseries();
      await expectLater(
          () => _timeseries(fake).queryTimeseriesData(_table, _base,
              orderBy: 'time ASC, (SELECT 1)'),
          throwsA(isA<ArgumentError>()));
      expect(fake.asks, isEmpty);
      // Both legal values still pass.
      await _timeseries(fake).queryTimeseriesData(_table, _base,
          orderBy: 'time DESC');
      await _timeseries(fake).queryTimeseriesData(_table, _base, orderBy: null);
    });

    test('an array-valued series is refused, naming the CastError it prevents',
        () async {
      final fake = _FakeTimeseries()
        ..seed(_arrayTable, [
          db.TimeseriesData<dynamic>(<double>[1.0, 2.0], _base),
        ]);
      await expectLater(
          () => _timeseries(fake).queryTimeseriesData(
              _arrayTable, _base.add(const Duration(minutes: 1)),
              from: _base),
          throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message',
              contains('CastError'))),
          reason: 'the wire\'s sample type is a scalar; a List there is a '
              'CastError at whatever panel plots it, and the refusal has to '
              'say so where somebody can read it');
    });

    test('a struct series with no member named is refused, listing its members',
        () async {
      final fake = _FakeTimeseries()
        ..seed(_structTable, [
          db.TimeseriesData<dynamic>(
              <String, dynamic>{'speed': 12.5, 'current': 3.2}, _base),
        ]);
      await expectLater(
          () => _timeseries(fake).queryTimeseriesData(
              _structTable, _base.add(const Duration(minutes: 1)),
              from: _base),
          throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message',
              allOf(contains('speed'), contains('current')))));
    });

    test('a named member is projected out of the struct row', () async {
      final fake = _FakeTimeseries()
        ..seed(_structTable, [
          db.TimeseriesData<dynamic>(
              <String, dynamic>{'speed': 12.5, 'current': 3.2}, _base),
          db.TimeseriesData<dynamic>(
              <String, dynamic>{'speed': 13.5, 'current': 3.4},
              _base.add(const Duration(minutes: 1))),
        ]);
      final got = await _timeseries(fake).queryTimeseriesData(
          '$_structTable:speed', _base.add(const Duration(minutes: 5)),
          from: _base);
      expect(got.map((p) => p.value).toList(), [12.5, 13.5]);
      expect(fake.asks.single.table, _structTable,
          reason: 'the member selects a field of a row; the table is what the '
              'resolver named');
    });

    test('a member the row does not carry is refused, listing what it has',
        () async {
      final fake = _FakeTimeseries()
        ..seed(_structTable, [
          db.TimeseriesData<dynamic>(
              <String, dynamic>{'speed': 12.5, 'current': 3.2}, _base),
        ]);
      await expectLater(
          () => _timeseries(fake).queryTimeseriesData(
              '$_structTable:torque', _base.add(const Duration(minutes: 1)),
              from: _base),
          throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message',
              allOf(contains('torque'), contains('speed')))));
    });

    test('a window whose from is after its to is refused, not silently '
        'swapped', () async {
      final fake = _FakeTimeseries();
      await expectLater(
          () => _timeseries(fake).queryTimeseriesDataDownsampled(
              _table, _base.add(const Duration(hours: 2)), _base),
          throwsA(isA<ArgumentError>()));
      expect(fake.asks, isEmpty,
          reason: 'queryTimeseriesDataDownsampled opens with '
              '`from.isBefore(to) ? from : to` and quietly answers the window '
              'the caller did not ask for');
    });

    group('composed with no database', () {
      test('every member refuses by name rather than answering empty',
          () async {
        final none = _timeseries(null);
        final calls = <String, Future<Object?> Function()>{
          'queryTimeseriesData': () => none.queryTimeseriesData(_table, _base),
          'queryTimeseriesDataMultiple': () =>
              none.queryTimeseriesDataMultiple([_table], _base),
          'queryTimeseriesDataDownsampled': () => none
              .queryTimeseriesDataDownsampled(_table, _base, _base),
        };
        for (final entry in calls.entries) {
          await expectLater(
              entry.value,
              throwsA(isA<StateError>().having(
                  (e) => e.message, 'message', contains(entry.key))),
              reason: '${entry.key} answered instead of refusing. An empty '
                  'list draws every chart flat, for months, with nothing '
                  'saying why');
        }
      });

      test('the refusal is a StateError and not an UnsupportedError',
          () async {
        await expectLater(
            () => _timeseries(null).queryTimeseriesData(_table, _base),
            throwsA(isA<StateError>()),
            reason: 'local_state_man.dart:1407 records the distinction: the '
                'member is implemented and what is absent is a historian in '
                'this deployment. UnsupportedError is reserved for '
                'preferences, which data_handlers.dart:216 catches on every '
                'session');
      });
    });

    test('a non-positive ceiling is refused at construction, naming the field',
        () {
      expect(() => TimeseriesLimits(maxPoints: 0), throwsArgumentError,
          reason: 'a gateway that refuses every query presents to an operator '
              'as "the historian is empty"');
      expect(() => TimeseriesLimits(maxRows: -1), throwsArgumentError);
    });
  });

  group('BackendHistoryViews', () {
    test('a view survives create, list, read back and delete', () async {
      final fake = _FakeHistoryViews();
      final views = BackendHistoryViews(source: fake);

      final id = await views.createHistoryView(
        'Frystir — vakt 1',
        [_keyA, _keyB],
        {
          _keyA: const relay.HistoryViewKeyRecord(
              key: _keyA,
              alias: 'Færiband 1',
              useSecondYAxis: true,
              graphIndex: 1),
        },
        {
          1: const relay.HistoryViewGraphRecord(
              graphIndex: 1, name: 'Frystir', yAxisUnit: '°C'),
        },
      );
      expect(id, greaterThan(0));

      final saved = await views.selectHistoryViews();
      expect(saved.single.id, id);
      expect(saved.single.name, 'Frystir — vakt 1');

      final keys = await views.getHistoryViewKeys(id);
      expect(keys.keys, containsAll([_keyA, _keyB]));
      expect(keys[_keyA]!.alias, 'Færiband 1');
      expect(keys[_keyA]!.useSecondYAxis, isTrue);
      expect(keys[_keyA]!.graphIndex, 1);
      expect(keys[_keyB]!.alias, _keyB,
          reason: 'a key saved with no alias still needs something to render '
              'in the legend, and its own name is it');

      final graphs = await views.getHistoryViewGraphs(id);
      expect(graphs[1]!.graphIndex, 1,
          reason: 'the drift layer keys the map by graph index and leaves the '
              'index out of the bag; the record carries it as a field');
      expect(graphs[1]!.yAxisUnit, '°C');
      expect(graphs[1]!.name, 'Frystir');

      expect(await views.getHistoryViewKeyNames(id), containsAll([_keyA, _keyB]));

      await views.deleteHistoryView(id);
      expect((await views.selectHistoryViews()).map((v) => v.id),
          isNot(contains(id)));
      expect(await views.getHistoryViewKeys(id), isEmpty,
          reason: 'rows that outlive their view are how a deleted view comes '
              'back as a partial one after the next restart');
    });

    test('a saved window survives add, list and delete, instants intact',
        () async {
      final views = BackendHistoryViews(source: _FakeHistoryViews());
      final viewId = await views.createHistoryView('Vaktir', [_keyA]);
      final start = DateTime.utc(2026, 8, 12, 6);
      final end = DateTime.utc(2026, 8, 12, 14);
      final periodId =
          await views.addHistoryViewPeriod(viewId, 'Vakt 1', start, end);

      final periods = await views.listHistoryViewPeriods(viewId);
      expect(periods, hasLength(1));
      expect(periods.single.id, periodId);
      expect(periods.single.viewId, viewId);
      expect(periods.single.name, 'Vakt 1');
      expect(periods.single.startAt, start);
      expect(periods.single.endAt, end);

      await views.deleteHistoryViewPeriod(periodId);
      expect(await views.listHistoryViewPeriods(viewId), isEmpty);
    });

    test('every instant crosses as an absolute UTC instant', () async {
      final fake = _FakeHistoryViews();
      final views = BackendHistoryViews(source: fake);
      final viewId = await views.createHistoryView('Vaktir', [_keyA]);
      // The driver hands timestamps back in local time unless something
      // normalises them; the adapter is the something.
      fake.handBackLocalTimes = true;
      await views.addHistoryViewPeriod(viewId, 'Vakt 1',
          DateTime.utc(2026, 8, 12, 6), DateTime.utc(2026, 8, 12, 14));

      final period = (await views.listHistoryViewPeriods(viewId)).single;
      expect(period.startAt.isUtc, isTrue,
          reason: 'a window that comes back an hour off lands on the wrong '
              'shift, twice a year, and every conclusion drawn from the chart '
              'is about the wrong hours');
      expect(period.startAt, DateTime.utc(2026, 8, 12, 6));
      expect(period.endAt, DateTime.utc(2026, 8, 12, 14));
      expect(period.createdAt.isUtc, isTrue);

      final view = (await views.selectHistoryViews()).single;
      expect(view.createdAt.isUtc, isTrue);

      expect((await views.getGlobalRetentionHorizon())!.isUtc, isTrue,
          reason: 'a chart that scrolls past the horizon is showing absence '
              'of data, not absence of events, and the horizon has to be the '
              'same instant on every station');
    });

    test('an update replaces the keys and the graphs it was given', () async {
      final views = BackendHistoryViews(source: _FakeHistoryViews());
      final id = await views.createHistoryView('Vaktir', [_keyA]);
      await views.updateHistoryView(id, 'Vaktir 2', [_keyB], {
        _keyB: const relay.HistoryViewKeyRecord(key: _keyB, alias: 'Hiti'),
      });
      expect((await views.selectHistoryViews()).single.name, 'Vaktir 2');
      expect(await views.getHistoryViewKeyNames(id), [_keyB]);
      expect((await views.getHistoryViewKeys(id))[_keyB]!.alias, 'Hiti');
    });

    test('a picker wider than the row ceiling is refused, not truncated',
        () async {
      final fake = _FakeHistoryViews();
      for (var i = 0; i < 12; i++) {
        await fake.createHistoryView('view $i', const []);
      }
      final views = BackendHistoryViews(source: fake, maxRows: 10);
      await expectLater(() => views.selectHistoryViews(),
          throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message',
              allOf(contains('10'), contains('12')))),
          reason: 'these rows are caller-grown: an operate station in a loop '
              'is the whole amplification (read_limits.dart:171-178)');
    });

    group('composed with no database', () {
      test('all eleven members refuse by name rather than answering empty',
          () async {
        final none = BackendHistoryViews(source: null);
        final calls = <String, Future<Object?> Function()>{
          'createHistoryView': () => none.createHistoryView('x', const []),
          'updateHistoryView': () => none.updateHistoryView(1, 'x', const []),
          'deleteHistoryView': () => none.deleteHistoryView(1),
          'selectHistoryViews': () => none.selectHistoryViews(),
          'getHistoryViewKeys': () => none.getHistoryViewKeys(1),
          'getHistoryViewGraphs': () => none.getHistoryViewGraphs(1),
          'getHistoryViewKeyNames': () => none.getHistoryViewKeyNames(1),
          'addHistoryViewPeriod': () =>
              none.addHistoryViewPeriod(1, 'x', DateTime.utc(2026), DateTime.utc(2026)),
          'deleteHistoryViewPeriod': () => none.deleteHistoryViewPeriod(1),
          'listHistoryViewPeriods': () => none.listHistoryViewPeriods(1),
          'getGlobalRetentionHorizon': () => none.getGlobalRetentionHorizon(),
        };
        expect(calls, hasLength(11),
            reason: 'HistoryViewApi declares eleven members; this roster is '
                'counted against the interface rather than eyeballed');
        for (final entry in calls.entries) {
          await expectLater(
              entry.value,
              throwsA(isA<StateError>()
                  .having((e) => e.message, 'message', contains(entry.key))),
              reason: '${entry.key} answered instead of refusing. A view '
                  'picker that says "you have saved nothing" to a plant that '
                  'has saved plenty is an operator saving their view a second '
                  'time, and then a third');
        }
      });

      test('the roster is exhaustive over HistoryViewApi', () {
        final declared = _membersOf(relay.HistoryViewApi);
        expect(declared, hasLength(11),
            reason: 'if the interface grew a twelfth member, this file has an '
                'unjudged one');
      });
    });
  });

  group('BackendPreferences', () {
    test('every typed preference round-trips and containsKey agrees',
        () async {
      final prefs = BackendPreferences(source: _FakePreferences());
      await prefs.setBool(_prefKey, true);
      expect(await prefs.getBool(_prefKey), isTrue);
      await prefs.setInt('svn.chart.maxPoints', 800);
      expect(await prefs.getInt('svn.chart.maxPoints'), 800);
      await prefs.setDouble('svn.weigher.tolerance', 0.25);
      expect(await prefs.getDouble('svn.weigher.tolerance'), 0.25);
      await prefs.setString('svn.site.name', 'Sæból');
      expect(await prefs.getString('svn.site.name'), 'Sæból');
      await prefs.setStringList('svn.page.recent', ['frystir', 'pökkun']);
      expect(await prefs.getStringList('svn.page.recent'),
          ['frystir', 'pökkun']);

      expect(await prefs.containsKey(_prefKey), isTrue);
      expect(await prefs.containsKey('svn.never.set'), isFalse);
      expect(await prefs.getKeys(), contains('svn.site.name'));
      expect((await prefs.getAll())['svn.site.name'], 'Sæból');

      await prefs.remove('svn.site.name');
      expect(await prefs.containsKey('svn.site.name'), isFalse);
      expect(await prefs.getString('svn.site.name'), isNull);
    });

    test('a change reaches a second listener', () async {
      final prefs = BackendPreferences(source: _FakePreferences());
      final first = prefs.onPreferencesChanged.first;
      final second = prefs.onPreferencesChanged.first;
      await prefs.setBool(_prefKey, true);
      expect(await first.timeout(const Duration(seconds: 1)), _prefKey);
      expect(await second.timeout(const Duration(seconds: 1)), _prefKey,
          reason: 'a settings page and a chart legend both listen to this, '
              'and a single-subscription stream gives the second an exception '
              'instead of the news');
    });

    test('clear removes the keys its allow list names and no others',
        () async {
      final fake = _FakePreferences();
      final prefs = BackendPreferences(source: fake);
      await prefs.setBool(_prefKey, true);
      await prefs.setInt(_clearedKey, 800);

      await prefs.clear(allowList: <String>{_clearedKey});

      expect(await prefs.containsKey(_clearedKey), isFalse);
      expect(await prefs.getBool(_prefKey), isTrue,
          reason: 'with no allow list clear removes every preference this '
              'backend holds, key_mappings — 518 KiB of routing configuration '
              'the whole plant is served through — included');
    });

    test('clear takes the durable rows with it, in one statement', () async {
      final fake = _FakePreferences();
      final prefs = BackendPreferences(source: fake);
      await prefs.setInt(_clearedKey, 800);
      await prefs.clear(allowList: <String>{_clearedKey});

      expect(fake.deleted, [
        {_clearedKey}
      ], reason: 'Preferences.clear empties the memory cache and never '
          'touches Postgres (preferences.dart:439-442), so a delegation would '
          'be a clear that undoes itself on the next rebuild — and the rows '
          'go in ONE statement, because a remove per key is one wire frame '
          'per key (preference_store.dart:462-470)');
    });

    test('clear announces every key it removed, with no await between',
        () async {
      final fake = _FakePreferences();
      final prefs = BackendPreferences(source: fake);
      await prefs.setBool(_prefKey, true);
      await prefs.setInt(_clearedKey, 800);
      final heard = <String>[];
      final sub = prefs.onPreferencesChanged.listen(heard.add);
      addTearDown(sub.cancel);

      await prefs.clear(allowList: <String>{_prefKey, _clearedKey});
      await Future<void>.delayed(Duration.zero);

      expect(heard.toSet(), {_prefKey, _clearedKey},
          reason: 'a clear that fires no change event is a settings page on '
              'another station still showing what was just deleted');
    });

    group('the change feed', () {
      test('nothing is armed until something listens', () async {
        final fake = _FakePreferences();
        final prefs = BackendPreferences(source: fake);
        expect(fake.feedListeners, 0,
            reason: 'an always-on subscription in tfc_dart plumbing fails '
                'unrelated widget tests, which is how this rule was learned');

        final sub = prefs.onPreferencesChanged.listen((_) {});
        expect(fake.feedListeners, 1);

        final second = prefs.onPreferencesChanged.listen((_) {});
        expect(fake.feedListeners, 1,
            reason: 'a broadcast feed costs the source one subscription, '
                'however many panels are watching');

        await sub.cancel();
        await second.cancel();
        expect(fake.feedListeners, 0,
            reason: 'started in onListen, stopped in onCancel');
      });

      test('no Timer.periodic anywhere in the implementation', () {
        final source = _stripDartComments(
            File('lib/core/relay/backend_data_services.dart')
                .readAsStringSync());
        expect(source, isNot(contains('Timer.periodic')),
            reason: 'an always-on Timer.periodic in tfc_dart plumbing fails '
                'unrelated widget tests');
        expect(source, isNot(contains('Timer(')));
      });
    });

    test('no member of this file requests secret material', () {
      // Comments stripped: the file's own doc has to be able to NAME the
      // spelling it forbids, or the rule survives only as long as whoever
      // reads the source already knows it.
      final source = _stripDartComments(
          File('lib/core/relay/backend_data_services.dart').readAsStringSync());
      expect(source, isNot(contains('secret:')),
          reason: 'the concrete Preferences carries a {bool secret = false} on '
              'twelve members that routes the call to the OS keychain. One '
              'client-supplied boolean spelled here would be remote retrieval '
              'of the secure store (SEC-01, T-13-05-c)');
    });

    group('composed with no preference store', () {
      test('every member refuses by name rather than answering empty',
          () async {
        final none = BackendPreferences(source: null);
        final calls = <String, Future<Object?> Function()>{
          'getKeys': () => none.getKeys(),
          'getAll': () => none.getAll(),
          'getBool': () => none.getBool('k'),
          'getInt': () => none.getInt('k'),
          'getDouble': () => none.getDouble('k'),
          'getString': () => none.getString('k'),
          'getStringList': () => none.getStringList('k'),
          'containsKey': () => none.containsKey('k'),
          'setBool': () => none.setBool('k', true),
          'setInt': () => none.setInt('k', 1),
          'setDouble': () => none.setDouble('k', 1.0),
          'setString': () => none.setString('k', 'v'),
          'setStringList': () => none.setStringList('k', const ['v']),
          'remove': () => none.remove('k'),
          'clear': () => none.clear(),
        };
        for (final entry in calls.entries) {
          await expectLater(
              entry.value,
              throwsA(isA<UnsupportedError>().having(
                  (e) => e.message, 'message', contains(entry.key))),
              reason: '${entry.key} answered instead of refusing');
        }
      });

      test('onPreferencesChanged throws an UnsupportedError, which is what '
          'every session survives', () {
        expect(() => BackendPreferences(source: null).onPreferencesChanged,
            throwsA(isA<UnsupportedError>()),
            reason: 'RelaySession calls watchPreferences() on EVERY session '
                'and data_handlers.dart:216 catches exactly UnsupportedError. '
                'A StateError here would fail every connect on a backend with '
                'no database — the default deployment');
      });
    });
  });

  group('the data-services contract', () {
    runDataServicesContract(_DataOnlyApi.new);
  });
}

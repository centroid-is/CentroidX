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
///    query looks like from here (`database.dart:947`);
///  * a change feed whose listener count an arm can read, which is how
///    "nothing is armed until something listens" is asserted rather than
///    hoped.
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:tfc_dart/core/database.dart' as db;
import 'package:tfc_dart/core/relay/backend_data_services.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

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
    if (downsampleFallsBack || window.length <= maxPoints) return window;
    final step = (window.length - 1) / (maxPoints - 1);
    return [
      for (var i = 0; i < maxPoints; i++) window[(i * step).round()],
    ];
  }

  @override
  Future<Map<DateTime, int>> countTimeseriesDataMultiple(
      String tableName, Duration interval, int howMany,
      {DateTime? since}) async {
    asks.add(_Ask('countTimeseriesDataMultiple', tableName));
    final end = since ?? DateTime.utc(2026, 8, 13, 12);
    return {
      for (var i = howMany - 1; i >= 0; i--)
        // Deliberately LOCAL, the way a Postgres driver hands a timestamp back
        // when nothing normalises it: the adapter owes the UTC.
        end.subtract(interval * (i + 1)).toLocal():
            _window(tableName, end.subtract(interval * (i + 1)),
                    end.subtract(interval * i))
                .length,
    };
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

void main() {
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
              'the bounded method\'s name (database.dart:1522-1525)');
      expect(fake.asks, isEmpty);
    });

    test('a howMany over the configured bucket ceiling is refused by name',
        () async {
      final fake = _FakeTimeseries();
      await expectLater(
          () => _timeseries(fake, limits: TimeseriesLimits(maxBuckets: 1000))
              .countTimeseriesDataMultiple(
                  _table, const Duration(minutes: 1), 50000),
          throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message',
              allOf(contains('howMany'), contains('1000'), contains('50000')))));
      expect(fake.asks, isEmpty,
          reason: 'howMany IS the number of UNION ALL subqueries in one '
              'statement (database.dart:1686-1695)');
    });

    test('a bucket wider than the configured interval ceiling is refused by '
        'name', () async {
      final fake = _FakeTimeseries();
      await expectLater(
          () => _timeseries(fake,
                  limits: TimeseriesLimits(maxIntervalMs: 86400000))
              .countTimeseriesDataMultiple(
                  _table, const Duration(days: 400), 10),
          throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message',
              allOf(contains('interval'), contains('86400000')))));
      expect(fake.asks, isEmpty);
    });

    test('a bucket that truncates to zero milliseconds is refused', () async {
      await expectLater(
          () => _timeseries(_FakeTimeseries()).countTimeseriesDataMultiple(
              _table, const Duration(microseconds: 500), 10),
          throwsA(isA<ArgumentError>()));
    });

    test('the bucket instants come back UTC', () async {
      final fake = _FakeTimeseries()..seed(_table, _minutely(_base, 20));
      final counts = await _timeseries(fake).countTimeseriesDataMultiple(
          _table, const Duration(minutes: 5), 4,
          since: DateTime.utc(2026, 8, 13, 7));
      expect(counts.keys.every((t) => t.isUtc), isTrue,
          reason: 'a bucket label an hour out puts the "is this series still '
              'recording?" strip on the wrong shift');
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
              '(database.dart:947). Passing that on is a million rows into a '
              'socket under the bounded method\'s name');
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
          reason: 'T-13-05-b: countTimeseriesDataMultiple interpolates its '
              'table name into SQL with no escaping at all '
              '(database.dart:1691), so a name the resolver never approved '
              'must not reach the source');
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
          'countTimeseriesDataMultiple': () => none.countTimeseriesDataMultiple(
              _table, const Duration(minutes: 1), 10),
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
}

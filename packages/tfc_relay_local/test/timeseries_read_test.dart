/// The four timeseries methods against a **real TimescaleDB** — the read leg.
///
/// 8b's `db` lane, not a second one: the same tag, the same env-addressed
/// fixture, the same CI step. Every table name carries a per-run random suffix
/// and every case drops what it created, so a Phase 10 read case and an 8b
/// `side_by_side_test.dart` case can share one database without either seeing
/// the other's rows.
///
/// Seeding goes through a bare `Database` doing `registerRetentionPolicy` then
/// `insertTimeseriesData` into the **prefixed** name — literally what
/// `TimescaleSink` does per entry, and the reason the rows here have the
/// shapes 8b-03 measured (a scalar table is `("value", "time")`; a struct
/// table is one column per named member plus `time`).
///
/// **Nothing in this file writes through the reader**, and nothing can: the
/// reader has no insert path and no retention path, which `freeze_test.dart`
/// asserts by sweeping `lib/src/data/`.
@TestOn('vm')
@Tags(['db'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:math';

import 'package:postgres/postgres.dart' as pg;
import 'package:test/test.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_relay_local/src/data/timescale_reader.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show ResolvedSeries, SeriesAddress, SeriesResolver;

import 'support/timescale_fixture.dart';

late TimescaleFixture fx;
late pg.Connection admin;

/// The per-run suffix every table name carries.
final String suffix =
    Random().nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0');

final Set<String> createdTables = <String>{};
final List<Database> writers = <Database>[];

const RetentionPolicy keepEverything =
    RetentionPolicy(dropAfter: Duration.zero);

int _serial = 0;

/// A name no other case in this run will use.
///
/// The serial is not decoration: several cases in a group seed the same
/// logical series from `setUp`, and a name that was only unique per RUN would
/// have each case appending to the previous one's rows — which reads as a
/// query returning twice what it should rather than as a fixture reusing a
/// table.
String freshTable(String base) {
  final name = 'gw_${base}_${suffix}_${_serial++}';
  createdTables.add(name);
  return name;
}

DatabaseConfig dbConfig() => DatabaseConfig(
      postgres: pg.Endpoint(
        host: fx.host,
        port: fx.port,
        database: fx.database,
        username: fx.username,
        password: fx.password,
      ),
      sslMode: pg.SslMode.disable,
      connectTimeout: const Duration(seconds: 5),
      // **Set explicitly, and this is the first of the three bounds.** A
      // badly-planned query dies in the database rather than in a send
      // buffer; `DatabaseConfig.queryTimeout` (database.dart:107, default at
      // :129) is threaded to the pool by drift at database_drift.dart:503 and
      // :552. Five seconds here because every window in this file is minutes
      // wide over tens of rows.
      queryTimeout: const Duration(seconds: 5),
      applicationName: 'relay-read-test',
    );

Future<Database> openWriter() async {
  final db = Database(await AppDatabase.create(dbConfig()));
  await db.open();
  writers.add(db);
  return db;
}

/// The resolver the reader is given: the plan, expressed directly. A wire
/// name is a plant key; the table is what the collection plan computed.
final class FixtureResolver implements SeriesResolver {
  FixtureResolver(this._tables);

  final Map<String, String> _tables;

  @override
  ResolvedSeries? resolve(String wireName) {
    final address = SeriesAddress.parse(wireName);
    final table = _tables[address.series];
    if (table == null) return null;
    return ResolvedSeries(
        table: table, member: address.member, plantKey: address.series);
  }

  @override
  String? keyForTable(String table) => _tables.entries
      .where((e) => e.value == table)
      .map((e) => e.key)
      .firstOrNull;

  @override
  String? keyForNode(String nodeId) => null;
}

/// The instant every window in this file is anchored on — fixed, so a case
/// measures rows rather than the machine's idea of now.
final DateTime anchor = DateTime.utc(2026, 9, 3, 12);

Future<void> seed(Database db, String table, List<(DateTime, Object?)> rows,
    {bool complex = false}) async {
  await db.registerRetentionPolicy(table, keepEverything);
  for (final (time, value) in rows) {
    await db.insertTimeseriesData(table, time, value);
  }
  await db.flush();
}

void main() {
  setUpAll(() async {
    fx = await TimescaleFixture.start();
    admin = await fx.connect();
  });

  tearDownAll(() async {
    for (final db in writers) {
      try {
        await db.close();
      } catch (_) {
        // A writer already closed by its own case is not a failure here.
      }
    }
    for (final table in createdTables) {
      await admin.execute('DROP TABLE IF EXISTS "$table" CASCADE');
    }
    await admin.close();
    await fx.stop();
  });

  group('a scalar series', () {
    late String table;
    late Database db;
    late TimescaleReader reader;

    setUp(() async {
      table = freshTable('speed');
      db = await openWriter();
      reader = TimescaleReader(
        database: () => db,
        resolver: FixtureResolver({'Line1.Motor1': table}),
      );
      await seed(db, table, [
        for (var i = 0; i < 10; i++)
          (anchor.subtract(Duration(minutes: 10 - i)), 1400 + i * 10),
      ]);
    });

    test('rows inside the window come back oldest first, num, UTC', () async {
      final samples = await reader.queryTimeseriesData('Line1.Motor1', anchor,
          from: anchor.subtract(const Duration(minutes: 11)));

      expect(samples, hasLength(10));
      expect(samples.map((s) => s.value), [
        for (var i = 0; i < 10; i++) 1400 + i * 10,
      ]);
      expect(samples.every((s) => s.value is num), isTrue,
          reason: 'the wire\'s sample type is num, and the client decodes '
              'every point as TimeseriesData<num>');
      expect(samples.every((s) => s.time.isUtc), isTrue,
          reason: 'an instant that is not absolute puts a chart an hour out '
              'twice a year, silently');
      expect(samples.first.time.isBefore(samples.last.time), isTrue);
    });

    test('a window that contains nothing is empty, not an error', () async {
      final samples = await reader.queryTimeseriesData('Line1.Motor1',
          anchor.subtract(const Duration(days: 30)),
          from: anchor.subtract(const Duration(days: 31)));

      expect(samples, isEmpty,
          reason: 'a chart scrolled past the start of the data does this on '
              'every frame of the scroll');
    });

    test('downsampled honours maxPoints and reaches both ends of the window',
        () async {
      final from = anchor.subtract(const Duration(minutes: 11));
      final samples = await reader.queryTimeseriesDataDownsampled(
          'Line1.Motor1', from, anchor,
          maxPoints: 9);

      expect(samples, isNotEmpty);
      expect(samples.length, lessThanOrEqualTo(9),
          reason: 'three points per bucket (min, max, last) and '
              '(maxPoints / 3).floor() buckets — and NO slack for a boundary '
              'bucket. `time_bucket` aligns to the Postgres epoch unless it '
              'is given an origin, so an arbitrary window straddles one more '
              'bucket than it was divided into and the answer comes back at '
              '3 × (buckets + 1). maxPoints is the interface\'s word '
              '(state_man_api.dart: "At most [maxPoints] samples") and a '
              'bound that is exceeded on every unaligned window is not a '
              'bound');
      final values = samples.map((s) => (s.value as num)).toList();
      expect(values.reduce(min), 1400,
          reason: 'the oldest sample must survive downsampling: a chart '
              'whose left edge is missing is a chart that lies about when '
              'the run started');
      expect(values.reduce(max), 1490);
      expect(samples.first.time, from,
          reason: 'the downsampled series starts at ${samples.first.time} '
              'where the caller asked for $from. An epoch-aligned bucket '
              'starts BEFORE the window, so the chart draws its first point '
              'to the left of its own axis — and it is a synthetic instant, '
              'not a sample\'s own, so nothing downstream can tell');
      expect(samples.last.time, anchor,
          reason: 'the downsampled series ends at ${samples.last.time} where '
              'the window ends at $anchor. The last bucket is emitted at '
              '`bucket + interval`, which is past the window by up to one '
              'bucket — on a month-wide chart at the default 1000 maxPoints '
              'that is forty minutes into the future, and the newest point '
              'is the one an operator reads as now');
    });

    /// **The case above is bucket-aligned by luck, and this one is not.**
    ///
    /// An eleven-minute window at `maxPoints: 9` is three 220-second buckets,
    /// and 220 seconds happens to divide the offset from `time_bucket`'s
    /// default origin exactly — so the boundary bucket never appears there
    /// and the two edges land on the window's own instants for free. Every
    /// assertion above therefore passes against an implementation that keeps
    /// none of those properties on an *arbitrary* window, which is every
    /// window a chart actually asks for.
    ///
    /// This is that window: 500 one-second samples, `maxPoints: 50`, so
    /// `(50 / 3).floor()` is sixteen buckets of 31 188 ms over a 499-second
    /// span, aligned to nothing. It is deliberately the shape
    /// `checkDownsampledRespectsMaxPoints` uses — the contract check that
    /// found this when 10-11 turned `supportsDataServices` on — so the
    /// property is defended in the package that owns the code and not only
    /// through a contract leg five files away.
    test('a window aligned to nothing keeps the bound and both edges',
        () async {
      final unaligned = freshTable('speed_unaligned');
      final base = anchor.subtract(const Duration(hours: 1));
      await seed(db, unaligned, [
        for (var i = 0; i < 500; i++) (base.add(Duration(seconds: i)), i),
      ]);
      final over = TimescaleReader(
        database: () => db,
        resolver: FixtureResolver({'Line1.Unaligned': unaligned}),
      );
      final to = base.add(const Duration(seconds: 499));

      final samples = await over.queryTimeseriesDataDownsampled(
          'Line1.Unaligned', base, to,
          maxPoints: 50);

      expect(samples.length, lessThanOrEqualTo(50),
          reason: 'sixteen buckets is 48 points and the window straddles a '
              'seventeenth, so the shipped arithmetic answers 51 where 50 '
              'was asked for. Three points is not a denial of service — the '
              'reason to close it is that a bound nobody keeps is a bound '
              'nobody can reason about, and this is the one method in the '
              'family that exists to be bounded');
      expect(samples.first.time, base,
          reason: 'the first point came back at ${samples.first.time}, '
              'BEFORE the window starts at $base. It is a bucket boundary, '
              'not a sample\'s own instant, so nothing downstream can '
              'recognise it as invented — and queryTimeseriesData refuses to '
              'return anything outside its window at all');
      expect(samples.last.time, to,
          reason: 'the last point came back at ${samples.last.time}, AFTER '
              'the window ends at $to. At the interface\'s default of 1000 '
              'maxPoints over a month a bucket is forty-three minutes, so '
              'the point an operator reads as the current value is drawn '
              'three quarters of an hour into the future');
      final values = samples.map((s) => s.value as num).toList();
      expect(values.reduce(min), 0,
          reason: 'the anti-vacuity arm: a downsampler that answered a '
              'clamped, empty or truncated list would satisfy the bound '
              'above without reaching either end of the data');
      expect(values.reduce(max), 499);
    });

    /// **The two residuals of 10-11's fix** (10-REVIEW WR-01), in the one
    /// window that shows both.
    ///
    /// 480 seconds at `maxPoints: 48` is sixteen buckets of exactly
    /// 30 000 ms — `rangeMs % numBuckets == 0`, so `numBuckets * bucketMs ==
    /// rangeMs` and the window's own right edge is a bucket **start**. The
    /// filter is `time <= to` inclusive, so a sample sitting on `to` opened
    /// bucket index sixteen, the seventeenth, and the answer was 3 × 17 = 51
    /// points for a bound of 48. No leg exercised it, because no leg seeded a
    /// sample at exactly `to` on a divisible window.
    ///
    /// And the terminal-timestamp collision is routine rather than exotic: the
    /// final bucket almost always starts before `to` and ends after it, so
    /// `LEAST(bucket + interval * 0.5, to)` and `LEAST(bucket + interval, to)`
    /// both evaluated to `to`, and the query emitted `max_val` and `last_val`
    /// at the identical instant with different values.
    test('a sample sitting exactly on a divisible window\'s edge keeps the '
        'bound, and no two points share an instant', () async {
      final divisible = freshTable('speed_divisible');
      final base = anchor.subtract(const Duration(hours: 2));
      // 481 samples one second apart: 0 s through 480 s inclusive, so the
      // last one is exactly on `to`.
      await seed(db, divisible, [
        for (var i = 0; i <= 480; i++) (base.add(Duration(seconds: i)), i),
      ]);
      final over = TimescaleReader(
        database: () => db,
        resolver: FixtureResolver({'Line1.Divisible': divisible}),
      );
      final to = base.add(const Duration(seconds: 480));

      final samples = await over.queryTimeseriesDataDownsampled(
          'Line1.Divisible', base, to,
          maxPoints: 48);

      expect(samples.length, lessThanOrEqualTo(48),
          reason: '480 000 ms over (48 / 3).floor() = 16 buckets is 30 000 ms '
              'exactly, so `to` is a bucket START and the sample on it opens '
              'a seventeenth bucket: 51 points for a bound of 48. The width '
              'is bumped by one millisecond when it divides evenly, which '
              'costs the last bucket 16 ms of extra span and cannot cost a '
              'point');

      final instants = samples.map((s) => s.time).toList();
      expect(instants.toSet(), hasLength(instants.length),
          reason: 'no two points may share an instant. The final bucket used '
              'to emit max_val and last_val both clamped to `to` — two '
              'different values stamped identically, which ORDER BY cannot '
              'separate and a chart draws as a vertical spike at its right '
              'edge. Every non-final bucket had the same collision with its '
              'NEIGHBOUR, because `bucket + interval` IS the next bucket\'s '
              'start');
      expect(instants, orderedEquals(List.of(instants)..sort()),
          reason: 'and they still come back oldest first');

      expect(samples.first.time, base,
          reason: 'the left edge is still the window\'s own start');
      expect(samples.last.time, to,
          reason: 'and the right edge is still exactly `to` — the clamp is '
              'gone but the last bucket overruns the window, so its last '
              'representable instant inside the window is `to` itself. A fix '
              'that moved the newest point a microsecond early would move the '
              'value an operator reads as now');

      final values = samples.map((s) => s.value as num).toList();
      expect(values.reduce(min), 0);
      expect(values.reduce(max), 480,
          reason: 'the anti-vacuity arm: the sample ON the edge is the one '
              'this case is about, and a downsampler that dropped it would '
              'satisfy the bound by losing the point');
    });
  });

  group('a struct series', () {
    late String table;
    late Database db;
    late TimescaleReader reader;

    setUp(() async {
      table = freshTable('drive');
      db = await openWriter();
      reader = TimescaleReader(
        database: () => db,
        resolver: FixtureResolver({'Line1.Motor2': table}),
      );
      await seed(db, table, [
        for (var i = 0; i < 6; i++)
          (
            anchor.subtract(Duration(minutes: 6 - i)),
            <String, dynamic>{
              'speed': 40.0 + i,
              'current': 3.0 + i,
              'temp': 60.0 + i,
            }
          ),
      ]);
    });

    test('one member is served as a scalar series of that column', () async {
      final samples = await reader.queryTimeseriesData(
          'Line1.Motor2:speed', anchor,
          from: anchor.subtract(const Duration(minutes: 7)));

      expect(samples, hasLength(6));
      expect(samples.map((s) => s.value), [40.0, 41.0, 42.0, 43.0, 44.0, 45.0]);
      expect(samples.every((s) => s.value is num), isTrue);
    });

    test('a different member is a different series over the same table',
        () async {
      final samples = await reader.queryTimeseriesData(
          'Line1.Motor2:current', anchor,
          from: anchor.subtract(const Duration(minutes: 7)));

      expect(samples.map((s) => s.value), [3.0, 4.0, 5.0, 6.0, 7.0, 8.0]);
    });

    test('the unaddressed struct is a refusal naming the members', () async {
      await expectLater(
          reader.queryTimeseriesData('Line1.Motor2', anchor),
          throwsA(isA<StructSeriesUnaddressed>().having(
              (e) => e.toString(),
              'message',
              allOf(contains('speed'), contains('current'),
                  contains('temp')))),
          reason: 'ninety of the live file\'s 140 collected keys are whole '
              'drive structs. Serving one unaddressed would put a Map where '
              'the client decodes a num, and the CastError arrives at the '
              'panel as a chart with no data');
    });

    test('a member series downsamples without falling back to the raw query',
        () async {
      final from = anchor.subtract(const Duration(minutes: 7));
      final samples = await reader.queryTimeseriesDataDownsampled(
          'Line1.Motor2:speed', from, anchor,
          maxPoints: 6);

      expect(samples, isNotEmpty);
      final values = samples.map((s) => s.value as num).toList();
      expect(values.reduce(min), 40.0);
      expect(values.reduce(max), 45.0);
      expect(samples.length, lessThanOrEqualTo(6),
          reason: 'Database.queryTimeseriesDataDownsampled looks for a '
              'column literally named `value` and silently returns the '
              'UNBOUNDED raw query when it finds none — which is every '
              'struct table there is. The member path must bucket for '
              'itself or a month-long struct chart is a month of raw rows — '
              'and it must keep the bound while doing it, boundary bucket '
              'included');
      expect(samples.first.time, from,
          reason: 'the projection has the same window edges to keep as the '
              'scalar path: ninety of the plant\'s 140 collected keys come '
              'through here');
      expect(samples.last.time, anchor,
          reason: 'and the same right-hand edge');
    });

    /// The projection's own unaligned window — see the scalar group's
    /// equivalent for why an aligned one proves nothing. Ninety of the
    /// plant's 140 collected keys come through this branch, and it spells its
    /// own bucketing rather than delegating, so the two have to be shown
    /// separately: a fix applied to one and forgotten on the other would
    /// leave two thirds of the historian unbounded.
    test('the projection keeps the bound and both edges on an unaligned '
        'window', () async {
      final unaligned = freshTable('drive_unaligned');
      final base = anchor.subtract(const Duration(hours: 2));
      await seed(db, unaligned, [
        for (var i = 0; i < 500; i++)
          (
            base.add(Duration(seconds: i)),
            <String, dynamic>{'speed': 40.0 + i, 'current': 3.0 + i},
          ),
      ]);
      final over = TimescaleReader(
        database: () => db,
        resolver: FixtureResolver({'Line1.Drive': unaligned}),
      );
      final to = base.add(const Duration(seconds: 499));

      final samples = await over.queryTimeseriesDataDownsampled(
          'Line1.Drive:speed', base, to,
          maxPoints: 50);

      expect(samples.length, lessThanOrEqualTo(50),
          reason: 'the member path computes the same '
              '(maxPoints / 3).floor() buckets and calls the same '
              'epoch-aligned time_bucket, so it overshoots the same way');
      expect(samples.first.time, base,
          reason: 'and starts before its own window the same way');
      expect(samples.last.time, to,
          reason: 'and ends after it the same way');
      final values = samples.map((s) => s.value as num).toList();
      expect(values.reduce(min), 40.0,
          reason: 'the anti-vacuity arm, as in the scalar group');
      expect(values.reduce(max), 539.0);
    });
  });

  group('several series in one call', () {
    test('scalar and member-projected series answer in one map, empty '
        'entries included', () async {
      final scalar = freshTable('multi_scalar');
      final struct = freshTable('multi_struct');
      final silent = freshTable('multi_silent');
      final db = await openWriter();
      final reader = TimescaleReader(
        database: () => db,
        resolver: FixtureResolver({
          'A.Scalar': scalar,
          'B.Struct': struct,
          'C.Silent': silent,
        }),
      );

      await seed(db, scalar, [
        (anchor.subtract(const Duration(minutes: 2)), 11),
        (anchor.subtract(const Duration(minutes: 1)), 12),
      ]);
      await seed(db, struct, [
        (
          anchor.subtract(const Duration(minutes: 2)),
          <String, dynamic>{'speed': 21.0, 'current': 1.0}
        ),
      ]);
      await seed(db, silent, [
        (anchor.subtract(const Duration(days: 40)), 99),
      ]);

      final answer = await reader.queryTimeseriesDataMultiple(
          ['A.Scalar', 'B.Struct:speed', 'C.Silent'], anchor,
          from: anchor.subtract(const Duration(minutes: 5)));

      expect(answer.keys, containsAll(['A.Scalar', 'B.Struct:speed', 'C.Silent']),
          reason: 'one entry per REQUESTED series, keyed by the name the '
              'caller used — a member address is its own series name');
      expect(answer['A.Scalar']!.map((s) => s.value), [11, 12]);
      expect(answer['B.Struct:speed']!.map((s) => s.value), [21.0]);
      expect(answer['C.Silent'], isEmpty,
          reason: 'an absent key and a key with no rows are different '
              'claims, and a chart drawing a gap where there was silence is '
              'the line that stops in mid-air');
    });
  });

  group('when the database goes away', () {
    test('the reader fails fast and answers again when it returns', () async {
      final table = freshTable('outage');
      final seeder = await openWriter();
      await seed(seeder, table, [(anchor.subtract(const Duration(minutes: 1)), 5)]);

      var current = await openWriter();
      final reader = TimescaleReader(
        database: () => current,
        resolver: FixtureResolver({'E.Outage': table}),
      );

      expect(
          (await reader.queryTimeseriesData('E.Outage', anchor,
                  from: anchor.subtract(const Duration(minutes: 5))))
              .single
              .value,
          5);

      await current.close();

      final watch = Stopwatch()..start();
      await expectLater(
          reader.queryTimeseriesData('E.Outage', anchor,
              from: anchor.subtract(const Duration(minutes: 5))),
          throwsA(anything),
          reason: 'an outage is handlerFailed (-32011, documented as '
              'possibly transient) at the wire, which is what a chart should '
              'retry. It is never a refusal — the request was fine — and '
              'never a hang: queryTimeout is what bounds it');
      expect(watch.elapsed, lessThan(const Duration(seconds: 30)));

      current = await openWriter();
      expect(
          (await reader.queryTimeseriesData('E.Outage', anchor,
                  from: anchor.subtract(const Duration(minutes: 5))))
              .single
              .value,
          5,
          reason: 'the supplier is the seam: the reader borrows whatever '
              'Database the composition currently holds rather than pinning '
              'one at construction, so a reconnect underneath it is '
              'invisible');
    });
  });
}

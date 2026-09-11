/// The outbound size discipline: the two ceilings, their derivation, and the
/// enforcement that refuses rather than truncates.
///
/// **Two lanes in one file, by design.** The derivation is arithmetic over
/// three numbers that already exist — `ServerConfig.maxPendingBytes`,
/// `ServerConfig.maxFrameBytes` and the protocol's own encoder — and needs no
/// database, so it runs in the ordinary lane where everybody sees it. The
/// enforcement is about what a real Postgres does when a window holds one row
/// too many, and that needs the `db` lane. The enforcement cases live under
/// one group carrying `tags: 'db'` rather than the file carrying
/// `@Tags(['db'])`, because a file-level tag would hide the arithmetic behind
/// Docker — and Docker is where three of the four CI platforms do not go.
///
/// **Every number in here is measured, or read off the thing it claims to be
/// derived from.** The lane ceiling is taken from a live `ServerConfig` rather
/// than copied as a literal, so a Phase 11 that moves it fails this file
/// instead of leaving a stale derivation that reads as though somebody checked.
@TestOn('vm')
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:postgres/postgres.dart' as pg;
import 'package:test/test.dart';
import 'package:tfc_dart/core/database.dart' hide TimeseriesData;
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_relay_local/src/data/preference_store.dart';
import 'package:tfc_relay_local/src/data/read_limits.dart';
import 'package:tfc_relay_local/src/data/timescale_reader.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show
        DataServiceMethods,
        ResolvedSeries,
        ResultSizeUnit,
        ResultTooLarge,
        SeriesAddress,
        SeriesResolver,
        TimeseriesData;
import 'package:tfc_relay_server/tfc_relay_server.dart' show ServerConfig;

import 'support/timescale_fixture.dart';

// ---------------------------------------------------------------------------
// The plant's own numbers, with their provenance.
// ---------------------------------------------------------------------------

/// How often SVN samples a collected key.
///
/// `svn-key-mappings.json`: `"sample_interval_us": 5000000` — the interval on
/// fourteen of the entries that name one; twelve name 500 000 and the rest
/// inherit the collector's default. Five seconds is what the windows below are
/// computed from, because a hardcoded row count stops being about the plant
/// the moment the interval changes.
const Duration svnSampleInterval = Duration(seconds: 5);

/// The live preference store, encoded as one `getAll` answer.
///
/// Measured on 2026-09-03 from `svn-prefs-live-20260811.csv` (the 2026-08-11
/// dump) by decoding the CSV and JSON-encoding the resulting
/// `Map<String, String>`:
///
/// | row | raw bytes | encoded bytes |
/// |---|---|---|
/// | `key_mappings` | 530 287 | 590 539 |
/// | `page_editor_data` | 145 405 | 163 869 |
/// | `mcp.config` | 185 | 211 |
/// | `alarm_man_config` | 13 | 17 |
/// | **the map** | **675 890** | **754 707** |
///
/// The encoded figure is the one that matters and it is **11.7 % larger than
/// the raw one**: the store's two big rows are themselves JSON documents, so
/// every `"` in them becomes `\"` on the way out. 10-09 measured 19 % against
/// a synthetic row of the same size; the real row escapes at 11.4 %, because
/// the synthetic packs more quotes per byte than the plant's actual tag map.
/// Both are recorded rather than reconciled — the real file is the claim.
const int liveStoreEncodedBytes = 754707;

/// What the live store is before encoding, for the margin sentence.
const int liveStoreRawBytes = 675890;

// ---------------------------------------------------------------------------
// A corpus of samples shaped like the plant's.
// ---------------------------------------------------------------------------

/// The float64 a float32 widens to — `1423.7` becomes `1423.699951171875`.
double asFloat32(double v) => (Float32List(1)..[0] = v)[0];

/// Values shaped like the ones SVN actually records.
///
/// Every collected column is `double precision` and most of what fills it
/// arrives as a PLC `REAL` — a float32 widened to float64, which prints its
/// full binary artifact rather than the round number an engineer typed. A
/// corpus of tidy one-decimal values would measure a sample half the size of
/// the ones a conveyor speed or a freezer temperature actually produce, and a
/// ceiling derived from that is a ceiling that does not hold.
///
/// So the corpus is the mix: float32 artifacts positive and negative (the far
/// side of CN20 is the freezer and runs below zero), tidy scaled values, and
/// the 1/0 a boolean charts as.
final List<num> plantSampleCorpus = <num>[
  1423, // a raw counter
  1423.7, // a conveyor speed as an engineer types it
  asFloat32(1423.7), // …as the PLC REAL actually widens
  asFloat32(-18.1), // freezer air, below zero
  asFloat32(0.1), // a 4-20 mA input near its floor
  asFloat32(3.72), // drive current
  0, // a boolean, charted
  1, // a boolean, charted
  65535, // a counter at full scale
];

/// The instant every sample in this file is stamped with — fixed, so the
/// measurement is about the encoder rather than about today's date.
final DateTime anchor = DateTime.utc(2026, 9, 3, 12);

// ---------------------------------------------------------------------------
// A store shaped like the live one, for the db lane's getAll cases.
// ---------------------------------------------------------------------------

/// Four rows sized and shaped like `svn-prefs-live-20260811.csv`'s.
///
/// Reproduces the sizes and the quote density rather than the plant's real tag
/// names — the escaping is what makes the encoded answer larger than the sum of
/// the values, so a builder that got the density wrong would measure the wrong
/// thing. The offline case below checks it against [liveStoreEncodedBytes] so
/// it cannot rot away from the file it stands in for.
Map<String, String> liveShapedStore() => <String, String>{
      'alarm_man_config': '{"alarms":[]}',
      'key_mappings': _sizedJson(530287, _keyMappingsEntry),
      'mcp.config': '{"serverEnabled":false,"chatEnabled":false,'
          '"knowledgeEnabled":false,"port":0,"host":"127.0.0.1",'
          '"transport":"stdio","allowWrites":false}',
      'page_editor_data': _sizedJson(145405, _pageEntry),
    };

String _keyMappingsEntry(int i) {
  final n = i.toString().padLeft(4, '0');
  return '"CN$n.SPD":{"opcua_node":{"namespace":4,'
      '"identifier":"AREA01.CNV$n.SUB01.speed","array_index":null,'
      '"server_alias":"st101"},"m2400_node":null,"io":null,"collect":null}';
}

String _pageEntry(int i) {
  final n = i.toString().padLeft(4, '0');
  return '"/page$n":{"menu_item":{"label":"Station $n","icon":"conveyor"},'
      '"widgets":[{"type":"asset","key":"CN$n.SPD","x":0.5,"y":0.5}]}';
}

/// A JSON document of exactly [bytes] characters, built from [entry].
String _sizedJson(int bytes, String Function(int) entry) {
  final buffer = StringBuffer('{"nodes":{');
  var i = 0;
  while (buffer.length < bytes - 128) {
    if (i > 0) buffer.write(',');
    buffer.write(entry(i));
    i++;
  }
  buffer.write('}');
  while (buffer.length < bytes - 1) {
    buffer.write(' ');
  }
  buffer.write('}');
  return buffer.toString();
}

// ---------------------------------------------------------------------------
// db-lane scaffolding, the same shape `timeseries_read_test.dart` uses.
// ---------------------------------------------------------------------------

late TimescaleFixture fx;
late pg.Connection admin;

final String suffix =
    Random().nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0');
final Set<String> createdTables = <String>{};
final List<Database> writers = <Database>[];
const RetentionPolicy keepEverything =
    RetentionPolicy(dropAfter: Duration.zero);
int _serial = 0;

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
      queryTimeout: const Duration(seconds: 20),
      applicationName: 'relay-read-limits-test',
    );

Future<Database> openWriter() async {
  final db = Database(await AppDatabase.create(dbConfig()));
  await db.open();
  writers.add(db);
  return db;
}

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

Future<void> seed(Database db, String table,
    List<(DateTime, Object?)> rows) async {
  await db.registerRetentionPolicy(table, keepEverything);
  for (final (time, value) in rows) {
    await db.insertTimeseriesData(table, time, value);
  }
  await db.flush();
}

/// [n] samples at the plant's own interval, ending at [anchor].
List<(DateTime, Object?)> ramp(int n) => [
      for (var i = 0; i < n; i++)
        (
          anchor.subtract(svnSampleInterval * (n - i)),
          1400.0 + i,
        ),
    ];

/// The lowered cap the boundary cases run against.
///
/// **Stated here rather than buried in a case.** The production default is
/// 40 000 rows and seeding that many is minutes of inserts per case; the
/// boundary this file is about is `n` versus `n + 1`, and that is the same
/// boundary at 12 as at 40 000. The production number is asserted separately,
/// by arithmetic, in the offline lane above.
const int loweredRows = 12;

/// The window every db case reads, wide enough to hold everything it seeded.
final DateTime wideFrom = anchor.subtract(const Duration(days: 2));

void main() {
  group('one sample, measured through the protocol\'s own encoder', () {
    test('the pinned bytes-per-sample is the worst the corpus produces', () {
      final sizes = <num, int>{
        for (final v in plantSampleCorpus)
          v: utf8
                  .encode(jsonEncode(TimeseriesData<num?>(v, anchor).toJson()))
                  .length +
              1, // the ',' that joins it to the next sample in the array
      };
      final worst = sizes.values.reduce(max);
      final mean = sizes.values.reduce((a, b) => a + b) / sizes.length;
      final widest = sizes.entries.reduce((a, b) => a.value >= b.value ? a : b);

      // ignore: avoid_print
      print('MEASURED bytes per encoded sample: worst=$worst '
          'mean=${mean.toStringAsFixed(1)} over ${sizes.length} plant-shaped '
          'values; the widest is ${widest.key} at ${widest.value} B');

      expect(ReadLimits.measuredBytesPerSample, worst,
          reason: 'the row ceiling is derived by dividing a byte budget by '
              'this number, so it must be the WORST a realistic sample '
              'produces and not the mean: half of a noisy series is above the '
              'mean, and a budget half a series exceeds is not a budget. If '
              'the encoder changes, this constant moves with it and the '
              'derived row cap is recomputed in the same commit');
    });
  });

  group('the row ceiling is derived from the priority lane', () {
    test('the priority lane is still 8 MiB, which the derivation divides', () {
      expect(ServerConfig().maxPendingBytes, 8 * 1024 * 1024,
          reason: 'every number in read_limits.dart is a fraction of this '
              'one. If it moved, the derivation in that file is stale — and a '
              'stale derivation is worse than none, because it reads as '
              'though somebody checked');
    });

    test('the default row cap fits a quarter of the lane at the measured size',
        () {
      final lane = ServerConfig().maxPendingBytes;
      final budget = lane ~/ 4;
      final derived = budget ~/ ReadLimits.measuredBytesPerSample;
      final chosen = ReadLimits.defaultMaxTimeseriesRows;
      final share =
          chosen * ReadLimits.measuredBytesPerSample * 100 / lane;

      // ignore: avoid_print
      print('DERIVATION: lane $lane B / 4 = $budget B budget; '
          '$budget / ${ReadLimits.measuredBytesPerSample} B per sample = '
          '$derived rows; chosen default = $chosen rows '
          '(${share.toStringAsFixed(1)}% of the whole lane)');

      expect(chosen, lessThanOrEqualTo(derived),
          reason: 'a response is budgeted at a quarter of the lane so a '
              'four-series chart plus the value updates and notifications the '
              'same session is receiving still fit — the lane is NOT '
              'conflated, so a response sits in it until the tick drains it');
      expect(chosen, greaterThan(derived ~/ 2),
          reason: 'headroom is not the same as timidity. A default far below '
              'the derived figure refuses windows the buffer could carry, and '
              'that refusal would be this file\'s fault rather than the '
              'lane\'s');
    });
  });

  group('the windows the default allows and the ones it refuses', () {
    int rowsIn(Duration window) =>
        window.inMicroseconds ~/ svnSampleInterval.inMicroseconds;

    test('a day of 5 s samples is answered and a month is refused', () {
      final cap = ReadLimits.defaultMaxTimeseriesRows;
      final day = rowsIn(const Duration(days: 1));
      final month = rowsIn(const Duration(days: 30));
      final widestDays =
          cap * svnSampleInterval.inSeconds / Duration.secondsPerDay;

      // ignore: avoid_print
      print('WINDOWS at ${svnSampleInterval.inSeconds} s sampling: '
          'a day = $day rows, a month = $month rows, cap = $cap rows; '
          'the widest window answered raw is '
          '${widestDays.toStringAsFixed(1)} days');

      expect(day, lessThan(cap),
          reason: 'a day is the window an operator scrolls to without '
              'thinking about it. A default that refused it would make the '
              'refusal the normal case, and a refusal nobody can avoid is a '
              'broken chart with a longer message');
      expect(month, greaterThan(cap),
          reason: 'a month is ${(month / cap).toStringAsFixed(0)}x the cap, '
              'about ${(month * ReadLimits.measuredBytesPerSample / (1024 * 1024)).toStringAsFixed(0)} '
              'MiB encoded — twice a whole session lane. This is the query '
              'that evicts a panel with 4004 and tells the operator they '
              'disconnected');
    });
  });

  group('the preference byte ceiling', () {
    test('it is above the live store, and the margin is printed', () {
      final cap = ReadLimits.defaultMaxPreferenceBytes;
      final margin = cap - liveStoreEncodedBytes;
      final escaping =
          (liveStoreEncodedBytes - liveStoreRawBytes) * 100 / liveStoreRawBytes;

      // ignore: avoid_print
      print('PREFERENCES: live store raw $liveStoreRawBytes B, encoded '
          '$liveStoreEncodedBytes B (+${escaping.toStringAsFixed(1)}%); '
          'cap $cap B; margin $margin B = '
          '${(margin * 100 / liveStoreEncodedBytes).toStringAsFixed(1)}% of '
          'today\'s store, which fills '
          '${(liveStoreEncodedBytes * 100 / cap).toStringAsFixed(1)}% of the '
          'cap');

      expect(cap, greaterThan(liveStoreEncodedBytes),
          reason: 'a cap below today\'s real store breaks getAll for the '
              'plant that is running now, and it breaks it as "the settings '
              'page will not open"');
    });

    test('it is maxFrameBytes, so one number bounds both directions', () {
      expect(ReadLimits.defaultMaxPreferenceBytes, ServerConfig().maxFrameBytes,
          reason: 'a value too large to be WRITTEN over the pipe is also too '
              'large to be read in bulk. Symmetric, and one number to '
              'remember instead of two');
    });

    test('the synthetic store matches the file it stands in for', () {
      final encoded = utf8.encode(jsonEncode(liveShapedStore())).length;
      final drift =
          (encoded - liveStoreEncodedBytes) * 100 / liveStoreEncodedBytes;

      // ignore: avoid_print
      print('SYNTHETIC store encodes to $encoded B against the recorded '
          '$liveStoreEncodedBytes B (${drift.toStringAsFixed(1)}%)');

      expect(encoded,
          closeTo(liveStoreEncodedBytes, liveStoreEncodedBytes * 0.15),
          reason: 'the db lane seeds this builder and calls it today\'s '
              'store. 10-09 measured a synthetic row escaping seven points '
              'higher than the real one, so the builder is checked against '
              'the recorded figure rather than trusted');
    });
  });

  group('a limit that refuses everything is refused at construction', () {
    test('zero rows is refused, naming the field', () {
      expect(
          () => ReadLimits(maxTimeseriesRows: 0),
          throwsA(isA<ArgumentError>()
              .having((e) => '$e', 'message', contains('maxTimeseriesRows'))),
          reason: 'a row cap of zero refuses every query, and a panel reports '
              'that as "the historian is empty"');
    });

    test('a negative row cap is refused, naming the field', () {
      expect(
          () => ReadLimits(maxTimeseriesRows: -1),
          throwsA(isA<ArgumentError>()
              .having((e) => '$e', 'message', contains('maxTimeseriesRows'))));
    });

    test('zero preference bytes is refused, naming the field', () {
      expect(
          () => ReadLimits(maxPreferenceBytes: 0),
          throwsA(isA<ArgumentError>()
              .having((e) => '$e', 'message', contains('maxPreferenceBytes'))));
    });

    test('a negative preference cap is refused, naming the field', () {
      expect(
          () => ReadLimits(maxPreferenceBytes: -1),
          throwsA(isA<ArgumentError>()
              .having((e) => '$e', 'message', contains('maxPreferenceBytes'))));
    });
  });

  // ------------------------------------------------------------- the db lane:
  // the boundary, against a real Postgres, at a lowered cap.

  group('enforcement, against a real historian', () {
    setUpAll(() async {
      // The gateway never asks for secret material (SEC-01), and a test
      // process must not be where a keychain prompt is discovered.
      SecureStorage.setInstance(const NoSecretStorage());
      fx = await TimescaleFixture.start();
      admin = await fx.connect();
    });

    tearDownAll(() async {
      for (final db in writers) {
        try {
          await db.close();
        } catch (_) {
          // A writer its own case already closed is not a failure here.
        }
      }
      for (final table in createdTables) {
        await admin.execute('DROP TABLE IF EXISTS "$table" CASCADE');
      }
      await admin.close();
      await fx.stop();
    });

    group('the row ceiling, at the boundary', () {
      test('exactly the cap is answered in full', () async {
        final table = freshTable('speed_at_cap');
        final db = await openWriter();
        await seed(db, table, ramp(loweredRows));
        final reader = TimescaleReader(
          database: () => db,
          resolver: FixtureResolver({'Line1.Motor1': table}),
          limits: ReadLimits(maxTimeseriesRows: loweredRows),
        );

        final samples = await reader.queryTimeseriesData('Line1.Motor1', anchor,
            from: wideFrom);

        expect(samples, hasLength(loweredRows),
            reason: 'a cap that fires AT the cap is a cap that fires a row '
                'early, and the chart it refuses is one the buffer could '
                'have carried. The lowered limit here is $loweredRows; the '
                'production default is asserted by arithmetic in the offline '
                'lane');
      });

      test('one row over the cap is refused, and nothing comes back',
          () async {
        final table = freshTable('speed_over_cap');
        final db = await openWriter();
        await seed(db, table, ramp(loweredRows + 1));
        final reader = TimescaleReader(
          database: () => db,
          resolver: FixtureResolver({'Line1.Motor1': table}),
          limits: ReadLimits(maxTimeseriesRows: loweredRows),
        );

        List<TimeseriesData>? answered;
        Object? caught;
        try {
          answered = await reader.queryTimeseriesData('Line1.Motor1', anchor,
              from: wideFrom);
        } catch (e) {
          caught = e;
        }

        expect(answered, isNull,
            reason: 'REFUSE, NEVER TRUNCATE. A partial list here is a chart '
                'whose line stops in mid-air, and the operator reads the '
                'truncation point as now');
        expect(caught, isA<ResultTooLarge>());
        final refusal = caught! as ResultTooLarge;
        expect(refusal.unit, ResultSizeUnit.rows);
        expect(refusal.limit, loweredRows);
        expect(refusal.atLeast, isTrue,
            reason: 'LIMIT n + 1 knows the answer is over the cap and not by '
                'how much; the sentence has to say so');
        expect(refusal.message,
            contains(DataServiceMethods.timeseriesQueryDownsampled),
            reason: 'the refusal names the method that would answer the same '
                'question inside the limit. "Too large" with no way out is a '
                'dead end an operator reports as a broken chart');
      });

      test('a member-projected series is bounded on the same boundary',
          () async {
        final table = freshTable('drive_over_cap');
        final db = await openWriter();
        await seed(db, table, [
          for (var i = 0; i < loweredRows + 1; i++)
            (
              anchor.subtract(svnSampleInterval * (loweredRows + 1 - i)),
              <String, dynamic>{'speed': 40.0 + i, 'current': 3.0 + i},
            ),
        ]);
        final reader = TimescaleReader(
          database: () => db,
          resolver: FixtureResolver({'Line1.Motor2': table}),
          limits: ReadLimits(maxTimeseriesRows: loweredRows),
        );

        await expectLater(
            reader.queryTimeseriesData('Line1.Motor2:speed', anchor,
                from: wideFrom),
            throwsA(isA<ResultTooLarge>()),
            reason: 'ninety of the plant\'s 140 collected keys are structs, '
                'so a bound fitted to the scalar path and forgotten on the '
                'projection is a bound that covers a third of the historian');

        final fits = TimescaleReader(
          database: () => db,
          resolver: FixtureResolver({'Line1.Motor2': table}),
          limits: ReadLimits(maxTimeseriesRows: loweredRows + 1),
        );
        expect(
            await fits.queryTimeseriesData('Line1.Motor2:speed', anchor,
                from: wideFrom),
            hasLength(loweredRows + 1),
            reason: 'the anti-vacuity arm: a projection that refused '
                'everything would pass the arm above');
      });
    });

    group('the multiple path is capped on the sum, not per table', () {
      late Database db;
      late Map<String, String> tables;

      setUp(() async {
        db = await openWriter();
        tables = <String, String>{};
        for (var s = 0; s < 4; s++) {
          final table = freshTable('series$s');
          tables['Line1.S$s'] = table;
          await seed(db, table, ramp(loweredRows));
        }
      });

      test('four tables each inside the cap are refused on the total',
          () async {
        final reader = TimescaleReader(
          database: () => db,
          resolver: FixtureResolver(tables),
          // Each table holds `loweredRows`; three fit, the fourth does not.
          limits: ReadLimits(maxTimeseriesRows: loweredRows * 3),
        );

        Object? caught;
        try {
          await reader.queryTimeseriesDataMultiple(
              tables.keys.toList(), anchor,
              from: wideFrom);
        } catch (e) {
          caught = e;
        }

        expect(caught, isA<ResultTooLarge>(),
            reason: 'a per-table cap would let four tables at the cap produce '
                'four times the budget in one frame — the exact failure the '
                'budget exists to prevent, arrived at by obeying the limit '
                'four times');
        expect((caught! as ResultTooLarge).message, contains('Line1.S3'),
            reason: 'the series that crossed the total is the one actionable '
                'fact in the refusal: it is the one to narrow');
      });

      test('a batch whose sum fits answers every series', () async {
        final reader = TimescaleReader(
          database: () => db,
          resolver: FixtureResolver(tables),
          limits: ReadLimits(maxTimeseriesRows: loweredRows * 4),
        );

        final answers = await reader.queryTimeseriesDataMultiple(
            tables.keys.toList(), anchor,
            from: wideFrom);

        expect(answers, hasLength(4));
        expect(answers.values.map((v) => v.length), everyElement(loweredRows),
            reason: 'the anti-vacuity arm: a sum cap that refused every batch '
                'would pass the arm above');
      });
    });

    group('the bounded method cannot silently lose its bound', () {
      late Database db;
      late String scalar;
      late TimescaleReader reader;

      setUp(() async {
        db = await openWriter();
        scalar = freshTable('downsample');
        await seed(db, scalar, ramp(30));
        reader = TimescaleReader(
          database: () => db,
          resolver: FixtureResolver({'Line1.Motor1': scalar}),
        );
      });

      test('fallback 1 of 4: a zero-width window is refused, not widened',
          () async {
        await expectLater(
            reader.queryTimeseriesDataDownsampled(
                'Line1.Motor1', anchor, anchor),
            throwsA(isA<DownsampleUnbounded>().having(
                (e) => e.condition,
                'condition',
                DownsampleFallback.zeroWidthWindow)),
            reason: 'database.dart:1471 returns the UNBOUNDED raw query for '
                'this, over the whole table, under the bounded method\'s name');
      });

      test('fallback 2 of 4: maxPoints below three is refused', () async {
        await expectLater(
            reader.queryTimeseriesDataDownsampled(
                'Line1.Motor1', wideFrom, anchor,
                maxPoints: 2),
            throwsA(isA<DownsampleUnbounded>().having((e) => e.condition,
                'condition', DownsampleFallback.tooFewPoints)),
            reason: '(2 / 3).floor() is zero buckets and database.dart:1477 '
                'answers the raw query. 10-03 refuses this at the wire; this '
                'is the second belt, for a caller that reaches the reader '
                'without passing a handler');
      });

      test('fallback 3 of 4: a table the catalogue does not know is refused',
          () async {
        final absent = TimescaleReader(
          database: () => db,
          resolver: FixtureResolver({'Line1.Ghost': 'gw_never_created_$suffix'}),
        );

        await expectLater(
            absent.queryTimeseriesDataDownsampled(
                'Line1.Ghost', wideFrom, anchor),
            throwsA(isA<SeriesTableMissing>()),
            reason: '_valueColumnType answers null when the catalogue has no '
                'value column for the table (database.dart:1487), and the '
                'shipped method then runs the raw query against a table that '
                'is not there. After _shapeOf the only way that happens is a '
                'missing table, so it is refused by name — and the old answer '
                'was StructSeriesUnaddressed with an EMPTY member list, which '
                'reads as "ask for one member: " and names none');
      });

      test('fallback 4 of 4: a boolean column is refused, not raw-queried',
          () async {
        final flags = freshTable('running');
        await seed(db, flags, [
          for (var i = 0; i < 8; i++)
            (anchor.subtract(svnSampleInterval * (8 - i)), i.isEven),
        ]);
        final booleans = TimescaleReader(
          database: () => db,
          resolver: FixtureResolver({'Line1.Run': flags}),
        );

        await expectLater(
            booleans.queryTimeseriesDataDownsampled(
                'Line1.Run', wideFrom, anchor),
            throwsA(isA<DownsampleUnbounded>().having((e) => e.condition,
                'condition', DownsampleFallback.notAggregatable)),
            reason: 'boolean is the ONE type this reader charts (as 1/0) that '
                'the shipped downsampler does not aggregate, so it is the one '
                'type that reaches database.dart:1512 and comes back as the '
                'unbounded raw query');

        expect(
            await booleans.queryTimeseriesData('Line1.Run', anchor,
                from: wideFrom),
            hasLength(8),
            reason: 'and the raw method still serves it as 1/0 — the refusal '
                'is about downsampling a boolean, not about reading one');
      });

      test('a downsampled query with none of the four conditions still works',
          () async {
        final samples = await reader.queryTimeseriesDataDownsampled(
            'Line1.Motor1', wideFrom, anchor,
            maxPoints: 9);

        expect(samples, isNotEmpty,
            reason: 'the anti-vacuity arm for all four above: a method that '
                'refused everything would pass every one of them');
      });
    });

    group('getAll is capped on encoded bytes', () {
      late Database db;
      late String ns;

      setUp(() async {
        db = await openWriter();
        ns = 'rl_${suffix}_${_serial++}_';
      });

      tearDown(() async {
        await admin.execute(
            "DELETE FROM flutter_preferences WHERE key LIKE '$ns%'");
      });

      Future<PreferenceStore> seededStore({ReadLimits? limits}) async {
        final writer = PreferenceStore(database: () => db);
        addTearDown(writer.close);
        for (final entry in liveShapedStore().entries) {
          await writer.setString('$ns${entry.key}', entry.value);
        }
        final store = PreferenceStore(database: () => db, limits: limits);
        addTearDown(store.close);
        return store;
      }

      test('today\'s real store passes under the production default',
          () async {
        final store = await seededStore();
        final all = await store.getAll(
            allowList: liveShapedStore().keys.map((k) => '$ns$k').toSet());

        final encoded = utf8.encode(jsonEncode(all)).length;
        // ignore: avoid_print
        print('GETALL over a live-shaped store: $encoded B encoded against a '
            '${ReadLimits.defaultMaxPreferenceBytes} B cap '
            '(${(encoded * 100 / ReadLimits.defaultMaxPreferenceBytes).toStringAsFixed(1)}% '
            'full)');

        expect(all, hasLength(4));
        expect(encoded, lessThan(ReadLimits.defaultMaxPreferenceBytes),
            reason: 'the plant that is running today must be able to open its '
                'settings page');
      });

      test('over the cap is refused, naming the byte limit and the allow-list',
          () async {
        final store =
            await seededStore(limits: ReadLimits(maxPreferenceBytes: 100000));

        Object? caught;
        Map<String, Object?>? answered;
        try {
          answered = await store.getAll();
        } catch (e) {
          caught = e;
        }

        expect(answered, isNull,
            reason: 'a partial map is a settings page rendering DEFAULTS over '
                'values that are really there, with nothing saying so');
        expect(caught, isA<ResultTooLarge>());
        final refusal = caught! as ResultTooLarge;
        expect(refusal.unit, ResultSizeUnit.bytes);
        expect(refusal.atLeast, isFalse,
            reason: 'the byte ceiling encodes the answer to measure it, so it '
                'knows the exact size — unlike the row ceiling');
        expect(refusal.measured, greaterThan(refusal.limit));
        expect(refusal.message, contains('allowList'),
            reason: 'the fix for a getAll that is too large is not another '
                'method, it is the allow-list every real caller should be '
                'passing — the interface\'s own doc calls it "highly '
                'recommended"');
      });

      test('an allow-list that fits is answered', () async {
        final store =
            await seededStore(limits: ReadLimits(maxPreferenceBytes: 100000));

        final some = await store
            .getAll(allowList: {'${ns}mcp.config', '${ns}alarm_man_config'});

        expect(some, hasLength(2),
            reason: 'the anti-vacuity arm: a cap that refused every getAll '
                'would pass the arm above, and the refusal names this as the '
                'fix — so it has to work');
      });

      test('the cap measures the ENCODED map, not the sum of value lengths',
          () async {
        final store = await seededStore();
        final keys = liveShapedStore().keys.map((k) => '$ns$k').toSet();
        final all = await store.getAll(allowList: keys);

        final raw = all.entries.fold<int>(
            0, (n, e) => n + utf8.encode('${e.value}').length);
        final encoded = utf8.encode(jsonEncode(all)).length;

        // ignore: avoid_print
        print('GETALL raw value bytes = $raw, encoded = $encoded '
            '(+${((encoded - raw) * 100 / raw).toStringAsFixed(1)}%)');

        expect(encoded, greaterThan(raw),
            reason: 'the frame is what fills the priority lane and JSON '
                'escaping of a 518 KiB key_mappings string is not free. '
                'Measuring the sum of the value lengths would under-count by '
                'the escaping, which is exactly the gap 10-09 found between '
                'the raw row and the frame');
      });
    });
  }, tags: 'db');
}

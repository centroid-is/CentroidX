/// `queryTimeseriesDataDownsampled` never answers with more than `maxPoints`.
///
/// ## Why this needs its own file, against a real TimescaleDB
///
/// The bound is not arithmetic that Dart can check on its own. It is a joint
/// property of the interval this side computes and of where **Postgres** puts
/// the bucket boundaries, and the two disagreed: `time_bucket(width, time)`
/// aligns buckets to a fixed origin (the epoch, for sub-day widths), not to
/// the start of the window being asked about. A window that is exactly N
/// intervals wide therefore *touches* N+1 boundaries whenever it does not
/// begin on one — and since every bucket contributes three rows (min, max,
/// last), a `maxPoints: 50` request came back with 51.
///
/// Measured, not reasoned about:
///
/// ```
/// SELECT count(DISTINCT time_bucket('31188 milliseconds', t))
/// FROM generate_series('2026-08-13 06:00:00+00', '2026-08-13 06:08:19+00',
///                      '1 second') g(t);
///  -- 17, first bucket 05:59:59.976 — before the window even opens
/// ```
///
/// with the same series and the same width bucketed from the window start:
///
/// ```
/// SELECT count(DISTINCT time_bucket('31188 milliseconds', t,
///                                   '2026-08-13 06:00:00+00'))
///  -- 16, first bucket 06:00:00.000
/// ```
///
/// So the cases below are written against a live server. A fake would encode
/// whatever alignment rule the author believed in, which is precisely the
/// thing that was wrong.
///
/// ## Why the bound matters beyond a red test
///
/// `BackendTimeseries.queryTimeseriesDataDownsampled` refuses to forward an
/// over-budget answer rather than pushing it across the link, so on the relay
/// path this overshoot is not a cosmetic three extra points — it is a hard
/// failure of the chart. And the bound is the entire reason the method exists
/// apart from `queryTimeseriesData`.
///
/// ## The port is hardcoded at 15432, and a parallel worktree collides
///
/// `docker_compose.dart:42`. Run the `db` lane alone.
@TestOn('vm')
@Tags(['db'])
@Timeout(Duration(minutes: 5))
library;

import 'package:test/test.dart';
import 'package:tfc_dart/core/database.dart';

import 'docker_compose.dart';

void main() {
  group('downsampled queries are bounded by maxPoints', () {
    late Database database;
    const table = 'test_downsample_bound';

    setUpAll(() async {
      await stopDockerCompose();
      await startDockerCompose();
      await waitForDatabaseReady();
      database = await connectToDatabase();
    });

    setUp(() async {
      // The table is created by the first insert, and only for a table that
      // has a retention policy registered — `registerRetentionPolicy` says so
      // in as many words, because the `value` column's type is not known
      // until a value turns up.
      await database.registerRetentionPolicy(
          table, const RetentionPolicy(dropAfter: Duration(hours: 2)));
    });

    tearDown(() async {
      try {
        await database.flush();
      } catch (_) {/* a failed flush must not fail the next test */}
      try {
        await database.db
            .customStatement('DROP TABLE IF EXISTS "$table" CASCADE');
      } catch (_) {/* the next test recreates what it needs */}
    });

    tearDownAll(() async {
      await database.close();
      await stopDockerCompose();
    });

    /// Writes [count] one-second samples starting at [base] and flushes.
    Future<void> seedSeconds(DateTime base, int count) async {
      for (var i = 0; i < count; i++) {
        await database.insertTimeseriesData(
            table, base.add(Duration(seconds: i)), i.toDouble());
      }
      await database.flush();
    }

    test('a window that does not begin on a bucket boundary stays in budget',
        () async {
      // The contract's own case, reproduced here where the failure can be
      // read directly off the database rather than through the adapter's
      // refusal. 500 one-second samples, a 499-second window, 50 points
      // asked for: 16 buckets of 31188 ms, which is 16 intervals of window —
      // but 17 epoch-aligned boundaries, hence 51 rows.
      final base = DateTime.utc(2026, 8, 13, 6);
      await seedSeconds(base, 500);
      final to = base.add(const Duration(seconds: 499));

      final got = await database.queryTimeseriesDataDownsampled(table, base, to,
          maxPoints: 50);

      expect(got.length, lessThanOrEqualTo(50),
          reason: '500 samples downsampled to 50 gave ${got.length}. The '
              'bucket width is computed from the window, but time_bucket '
              'aligns buckets to its own origin, so a window that does not '
              'begin on a boundary spans one more bucket than it was sized '
              'for — and each bucket is three rows');
      expect(got, isNotEmpty, reason: '500 samples downsampled to nothing');
      expect(got.first.time, base,
          reason: 'the series begins at ${got.first.time}, before the window '
              'it was asked for opens at $base — an epoch-aligned first '
              'bucket is labelled at its own start, which is outside the '
              'chart\'s own axis');
      expect(got.last.time, to,
          reason: 'the series ends at ${got.last.time} where the window ends '
              'at $to. The newest point is the one an operator reads as the '
              'current value, and a bucket labelled past the window end puts '
              'it off the axis');
    });

    test('a window whose span divides evenly still stays in budget', () async {
      // The second boundary case, and the one that survives merely aligning
      // buckets to the window start. maxPoints 30 is 10 buckets; a 500-second
      // window divides into 10 buckets of exactly 50000 ms; and because the
      // upper bound is INCLUSIVE, the sample at t+500s opens an eleventh
      // bucket all by itself. 11 x 3 = 33.
      final base = DateTime.utc(2026, 8, 13, 7);
      await seedSeconds(base, 501);
      final to = base.add(const Duration(seconds: 500));

      final got = await database.queryTimeseriesDataDownsampled(table, base, to,
          maxPoints: 30);

      expect(got.length, lessThanOrEqualTo(30),
          reason: 'a 500 s window at 10 buckets gave ${got.length} rows. The '
              'window boundary is inclusive, so a width that divides the span '
              'exactly leaves the final sample sitting in a bucket of its own');
      expect(got.first.time, base);
      expect(got.last.time, to);
    });

    test('the bound holds across window widths and budgets', () async {
      // A sweep, because the two cases above are two alignments out of many
      // and the property is meant to hold for all of them. Offsetting the
      // window start by a prime number of milliseconds is what keeps the
      // sweep from accidentally testing only boundary-aligned windows.
      final base = DateTime.utc(2026, 8, 13, 8);
      await seedSeconds(base, 600);

      for (final spanSeconds in [37, 121, 400, 599]) {
        for (final maxPoints in [3, 9, 30, 50, 99, 120]) {
          for (final offsetMs in [0, 7, 331]) {
            final from = base.add(Duration(milliseconds: offsetMs));
            final to = from.add(Duration(seconds: spanSeconds));

            final got = await database
                .queryTimeseriesDataDownsampled(table, from, to,
                    maxPoints: maxPoints);

            expect(got.length, lessThanOrEqualTo(maxPoints),
                reason: 'span ${spanSeconds}s, maxPoints $maxPoints, window '
                    'start offset by $offsetMs ms gave ${got.length} rows');
          }
        }
      }
    });

    test('no point is labelled outside the window it was asked for', () async {
      // The three rows a bucket contributes are labelled at its start, its
      // midpoint and its end, and the end of the last bucket lies past the
      // end of the window whenever the width does not divide the span. A
      // chart told to draw 06:00 to 06:08:19 should not be handed a point at
      // 06:08:19.008.
      final base = DateTime.utc(2026, 8, 13, 9);
      await seedSeconds(base, 500);
      final to = base.add(const Duration(seconds: 499));

      final got = await database.queryTimeseriesDataDownsampled(table, base, to,
          maxPoints: 51);

      for (final point in got) {
        expect(point.time.isBefore(base), isFalse,
            reason: '${point.time} is before the window start $base');
        expect(point.time.isAfter(to), isFalse,
            reason: '${point.time} is after the window end $to');
      }
    });
  });
}

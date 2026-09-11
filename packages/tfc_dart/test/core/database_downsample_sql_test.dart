import 'package:test/test.dart';
import 'package:tfc_dart/core/database.dart';

/// The min/max/last downsampling statement is the History View's whole cost
/// on a range query, and the "last" column is where that cost used to live:
/// `(array_agg(value ORDER BY time DESC))[1]` makes Postgres sort every row in
/// range before it can group them — `Sort Method: external merge  Disk:
/// 60288kB` over 1.8M rows on the plant database. TimescaleDB's
/// `last(value, time)` computes the same thing in one pass off the time index.
///
/// These are white-box assertions on the generated SQL on purpose: the two
/// spellings are *semantically identical* (see the doc comment on
/// [buildDownsampleSql], and the equivalence tests in
/// test/integration/database_integration_test.dart), so no black-box test can
/// tell them apart. What can regress is somebody "simplifying" the aggregate
/// back to portable SQL and quietly reinstating the sort.
void main() {
  group('buildDownsampleSql', () {
    test('scalar branch takes the per-bucket last off the time index', () {
      final sql = buildDownsampleSql(quotedTable: 'my_tag', isArray: false);

      expect(sql, contains('last(value, time)'));
      expect(sql, isNot(contains('array_agg(value ORDER BY time DESC)')));
      // The sort we are avoiding is specifically ORDER BY inside an
      // aggregate; the trailing ORDER BY 1 over ~1000 output rows is fine.
      expect(sql, isNot(contains('ORDER BY time DESC')));
    });

    test('array branch takes the per-element last off the time index', () {
      final sql = buildDownsampleSql(quotedTable: 'my_tag', isArray: true);

      expect(sql, contains('last(val, time)'));
      expect(sql, isNot(contains('array_agg(val ORDER BY time DESC)')));
      expect(sql, isNot(contains('ORDER BY time DESC')));
    });

    test('still emits min, max and last for every bucket', () {
      for (final isArray in [false, true]) {
        final sql = buildDownsampleSql(quotedTable: 'my_tag', isArray: isArray);
        final col = isArray ? 'val' : 'value';
        expect(sql, contains('min($col)'), reason: 'isArray=$isArray');
        expect(sql, contains('max($col)'), reason: 'isArray=$isArray');
        expect(sql, contains('time_bucket(\$1::interval, time, \$2::timestamptz)'),
            reason: 'isArray=$isArray');
      }
    });

    test('buckets from the window start, not from time_bucket\'s own origin',
        () {
      // The white-box half of the maxPoints bound. `time_bucket(width, time)`
      // aligns to a fixed origin — the epoch, for sub-day widths — so a
      // window sized for N buckets spans N+1 of them unless it happens to
      // begin on a boundary, and each bucket is three output rows. Measured
      // on pg17/TimescaleDB: one-second samples over 06:00:00Z..06:08:19Z at
      // 31188 ms gave 17 buckets epoch-aligned against 16 with the window
      // start as origin. The runtime half is
      // test/integration/database_downsample_bound_test.dart; this arm is
      // what makes dropping the third argument fail without a server.
      for (final isArray in [false, true]) {
        final sql = buildDownsampleSql(quotedTable: 'my_tag', isArray: isArray);
        expect(sql, isNot(contains('time_bucket(\$1::interval, time)')),
            reason: 'isArray=$isArray: an origin-less time_bucket aligns to '
                'the epoch and overruns maxPoints');
      }
    });

    test('clamps the derived labels to the window end', () {
      // A bucket's three rows are labelled at its start, midpoint and end so
      // they spread across the bucket. The bucket straddling the window's
      // upper bound would otherwise be labelled past it — 06:08:19.008 for a
      // window ending 06:08:19 — putting a point outside the axis the caller
      // asked for, and denying the chart a point at "now".
      for (final isArray in [false, true]) {
        final sql = buildDownsampleSql(quotedTable: 'my_tag', isArray: isArray);
        expect(sql, contains('LEAST(bucket + \$1::interval, \$3::timestamptz)'),
            reason: 'isArray=$isArray');
        expect(
            sql,
            contains(
                'LEAST(bucket + \$1::interval * 0.5, \$3::timestamptz)'),
            reason: 'isArray=$isArray');
      }
    });

    test('interpolates the table name inside quotes, as given', () {
      // The caller is responsible for doubling embedded quotes; this just
      // pins that the name lands inside the identifier quotes.
      final sql =
          buildDownsampleSql(quotedTable: 'weird""name', isArray: false);
      expect(sql, contains('"weird""name"'));
    });
  });

  /// The arithmetic half of the maxPoints bound, offline.
  ///
  /// Given buckets aligned to the window start (the origin argument above),
  /// the number the window touches is `floor(rangeMs / bucketMs) + 1`, and
  /// the bound is that this never exceeds the budget. Checking it here rather
  /// than only against a server means the `db` lane is not the only thing
  /// standing between a `ceil` and three extra points on every chart.
  group('downsampleBucketMs', () {
    /// How many window-aligned buckets a [rangeMs] window of [bucketMs]
    /// buckets touches, upper bound inclusive.
    int bucketsTouched(int rangeMs, int bucketMs) => rangeMs ~/ bucketMs + 1;

    test('a span that divides exactly still fits, because of the +1', () {
      // The case `ceil` gets wrong: 500 s at 10 buckets is exactly 50000 ms
      // per bucket, and the inclusive endpoint then opens an eleventh.
      expect(downsampleBucketMs(500000, 10), 50001);
      expect(bucketsTouched(500000, 50001), 10);
      expect(bucketsTouched(500000, 50000), 11,
          reason: 'the arithmetic this guards against, stated as a number');
    });

    test('the contract case comes out at 16 buckets, not 17', () {
      // 500 one-second samples, 499 s window, maxPoints 50.
      const numBuckets = 50 ~/ 3; // 16
      final bucketMs = downsampleBucketMs(499000, numBuckets);
      expect(bucketMs, 31188);
      expect(bucketsTouched(499000, bucketMs), 16);
      expect(bucketsTouched(499000, bucketMs) * 3, lessThanOrEqualTo(50));
    });

    test('never exceeds the bucket budget, over a wide sweep', () {
      const ranges = [
        1, 2, 7, 999, 1000, 1001, 60000, 499000, 500000, 3600000, 86400000,
        2592000000, // a month, the denial-of-service case
      ];
      for (final rangeMs in ranges) {
        for (var maxPoints = 3; maxPoints <= 3000; maxPoints += 7) {
          final numBuckets = maxPoints ~/ 3;
          final bucketMs = downsampleBucketMs(rangeMs, numBuckets);
          expect(bucketMs, greaterThanOrEqualTo(1),
              reason: 'rangeMs=$rangeMs maxPoints=$maxPoints: a zero-width '
                  'interval is not a bucket');
          expect(bucketsTouched(rangeMs, bucketMs),
              lessThanOrEqualTo(numBuckets),
              reason: 'rangeMs=$rangeMs maxPoints=$maxPoints');
          expect(bucketsTouched(rangeMs, bucketMs) * 3,
              lessThanOrEqualTo(maxPoints),
              reason: 'rangeMs=$rangeMs maxPoints=$maxPoints: three rows per '
                  'bucket is what the caller receives');
        }
      }
    });
  });
}

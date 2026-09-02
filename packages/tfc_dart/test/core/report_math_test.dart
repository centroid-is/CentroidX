import 'package:test/test.dart';
import 'package:tfc_dart/core/report.dart';
import 'package:tfc_dart/core/report_math.dart';

void main() {
  final start = DateTime(2026, 9, 1, 7);
  final end = DateTime(2026, 9, 1, 15);
  DateTime at(int minutes) => start.add(Duration(minutes: minutes));

  SampleWindow window(List<(int, double)> samples, {double? boundary}) =>
      SampleWindow(
        start: start,
        end: end,
        boundaryValue: boundary,
        samples: [for (final (m, v) in samples) Sample(at(m), v)],
      );

  group('first/last', () {
    test('first is the value standing at range start', () {
      expect(aggregate(ReportAggregate.first, window([(10, 5)], boundary: 3)),
          3);
      // No history before the window: the first in-range sample stands in.
      expect(aggregate(ReportAggregate.first, window([(10, 5)])), 5);
    });

    test('last falls back to the boundary when the range is empty', () {
      expect(
          aggregate(ReportAggregate.last, window([(10, 5), (20, 7)])), 7);
      expect(aggregate(ReportAggregate.last, window([], boundary: 3)), 3);
    });
  });

  group('min/max', () {
    test('include the standing boundary value', () {
      final w = window([(10, 5), (20, 7)], boundary: 2);
      expect(aggregate(ReportAggregate.min, w), 2);
      expect(aggregate(ReportAggregate.max, w), 7);
    });
  });

  test('mean averages the in-range samples only', () {
    final w = window([(10, 4), (20, 8)], boundary: 100);
    expect(aggregate(ReportAggregate.mean, w), 6);
    expect(aggregate(ReportAggregate.count, w), 2);
  });

  group('timeWeightedMean', () {
    test('weights each value by how long it stood', () {
      // 10 holds for the first 4 hours (as boundary), 20 for the last 4.
      final w = window([(240, 20)], boundary: 10);
      expect(aggregate(ReportAggregate.timeWeightedMean, w), 15);
    });

    test('a value standing all range is that value', () {
      expect(
          aggregate(ReportAggregate.timeWeightedMean, window([], boundary: 42)),
          42);
    });

    test('no boundary: weighting starts at the first sample', () {
      // 6h at 10, then 2h at 40 → (6*10 + 2*40)/8h... but with no boundary the
      // first hour (07:00-08:00) has no known value, so weights are 5h and 2h.
      final w = window([(60, 10), (360, 40)]);
      expect(aggregate(ReportAggregate.timeWeightedMean, w),
          closeTo((5 * 10 + 2 * 40) / 7, 1e-9));
    });
  });

  group('delta', () {
    test('plain counter increase uses the boundary as baseline', () {
      final w = window([(60, 110), (120, 130)], boundary: 100);
      expect(aggregate(ReportAggregate.delta, w), 30);
    });

    test('a reset to zero starts counting again instead of going negative',
        () {
      final w = window([(60, 150), (120, 5), (180, 25)], boundary: 100);
      // 100→150 is 50, reset gives 5, then 20 more.
      expect(aggregate(ReportAggregate.delta, w), 75);
    });

    test('a single sample with no baseline is zero increase', () {
      expect(aggregate(ReportAggregate.delta, window([(60, 500)])), 0);
    });
  });

  group('duration in state', () {
    test('durationTrue integrates the truthy stretches', () {
      // Running (1) as boundary, stops at +120 min, restarts at +180 min.
      final w = window([(120, 0), (180, 1)], boundary: 1);
      expect(aggregate(ReportAggregate.durationTrue, w),
          Duration(minutes: 120 + (480 - 180)).inSeconds);
      expect(aggregate(ReportAggregate.durationFalse, w),
          const Duration(minutes: 60).inSeconds);
    });
  });

  test('an empty window aggregates to null', () {
    for (final agg in ReportAggregate.values) {
      expect(aggregate(agg, window([])), isNull, reason: agg.name);
    }
  });

  group('bucketize', () {
    test('produces min/avg/max per bucket and skips empty buckets', () {
      final w = window([
        (10, 1),
        (20, 3),
        // nothing between +60 and +420 — that bucket range must be absent
        (430, 10),
      ]);
      final points = bucketize(w, 8); // 1h buckets over 8h
      expect(points.length, 2);
      expect(points.first.min, 1);
      expect(points.first.max, 3);
      expect(points.first.avg, 2);
      expect(points.last.avg, 10);
    });

    test('empty windows and degenerate ranges yield nothing', () {
      expect(bucketize(window([]), 10), isEmpty);
      expect(bucketize(window([(10, 1)]), 0), isEmpty);
    });
  });
}

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

  group('clip', () {
    test('takes its boundary from the samples it drops', () {
      final w = window([(10, 5), (60, 9)], boundary: 3);
      final c = w.clip(at(30), at(90));
      expect(c.boundaryValue, 5);
      expect(c.boundaryTime, at(10));
      expect(c.samples.single.value, 9);
    });

    test('keeps the original boundary when nothing precedes the sub-range',
        () {
      final w = window([(60, 9)], boundary: 3);
      expect(w.clip(at(10), at(30)).boundaryValue, 3);
    });
  });

  group('aggregateOver', () {
    // The "while running" scope: two stretches of production with the line
    // standing still in between.
    final ranges = [TimeRange(at(0), at(60)), TimeRange(at(180), at(240))];

    test('one range is the plain aggregate over that range', () {
      final w = window([(30, 8)], boundary: 4);
      expect(aggregateOver(ReportAggregate.timeWeightedMean, w,
          [TimeRange(at(0), at(60))]), 6);
    });

    test('a counter that moved while stopped does not count as production',
        () {
      // 100→110 while running, 110→300 during the pause, 300→320 running.
      final w = window([(60, 110), (170, 300), (240, 320)], boundary: 100);
      expect(aggregateOver(ReportAggregate.delta, w, ranges), 30);
    });

    test('durations and counts sum across the ranges', () {
      final w = window([(30, 0), (180, 1)], boundary: 1);
      expect(aggregateOver(ReportAggregate.durationTrue, w, ranges),
          const Duration(minutes: 30 + 60).inSeconds);
    });

    test('the time-weighted mean weighs each range by its length', () {
      final w = window([(60, 0), (180, 20)], boundary: 10);
      expect(aggregateOver(ReportAggregate.timeWeightedMean, w, ranges), 15);
    });

    test('extremes span the ranges, first and last come from the ends', () {
      final w = window([(30, 2), (200, 9)], boundary: 5);
      expect(aggregateOver(ReportAggregate.min, w, ranges), 2);
      expect(aggregateOver(ReportAggregate.max, w, ranges), 9);
      expect(aggregateOver(ReportAggregate.first, w, ranges), 5);
      expect(aggregateOver(ReportAggregate.last, w, ranges), 9);
    });

    test('no ranges at all is no answer', () {
      final w = window([(30, 2)], boundary: 5);
      expect(aggregateOver(ReportAggregate.mean, w, const []), isNull);
    });

    test('a range of no length still reports what stood there', () {
      final w = window([(30, 2)], boundary: 5);
      final instant = [TimeRange(at(30), at(30))];
      // No samples inside it, so no mean — but the standing value is known.
      expect(aggregateOver(ReportAggregate.mean, w, instant), isNull);
      expect(aggregateOver(ReportAggregate.first, w, instant), 2);
    });
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

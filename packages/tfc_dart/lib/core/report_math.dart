import 'report.dart';

/// One numeric sample as the aggregation math sees it. Booleans and integers
/// have already been coerced to double by the fetch layer.
class Sample {
  final DateTime time;
  final double value;

  const Sample(this.time, this.value);
}

/// The samples of one key/member over one report range, plus the value that
/// was standing when the range began.
///
/// Collected data is change-based or coarsely sampled, so the sample *before*
/// the window is not an edge case: a temperature that last changed an hour
/// before the shift began still has that value all shift. Every step-hold
/// aggregate here uses [boundaryValue] as the value standing at [start].
class SampleWindow {
  final DateTime start;
  final DateTime end;

  /// Value of the last sample at or before [start], or null when the key has
  /// no history before the window.
  final double? boundaryValue;

  /// When that boundary sample was taken. Null when there is none.
  ///
  /// The value alone is enough to step-hold; the *time* is what tells a
  /// one-second-sampled key whose collector died an hour before the shift
  /// apart from a change-based key that simply has not changed.
  final DateTime? boundaryTime;

  /// Samples strictly after [start] and at or before [end], sorted by time.
  final List<Sample> samples;

  const SampleWindow({
    required this.start,
    required this.end,
    required this.boundaryValue,
    this.boundaryTime,
    required this.samples,
  });

  bool get isEmpty => samples.isEmpty && boundaryValue == null;

  /// The same history seen through a shorter window `[from, to)`.
  ///
  /// The boundary is recomputed rather than carried over: the value standing
  /// when a sub-range began is usually a sample *inside* the original window,
  /// and using the original boundary would hold a value the data already
  /// replaced.
  SampleWindow clip(DateTime from, DateTime to) {
    var bv = boundaryValue;
    var bt = boundaryTime;
    final kept = <Sample>[];
    for (final s in samples) {
      if (!s.time.isAfter(from)) {
        bv = s.value;
        bt = s.time;
      } else if (!s.time.isAfter(to)) {
        kept.add(s);
      }
    }
    return SampleWindow(
      start: from,
      end: to,
      boundaryValue: bv,
      boundaryTime: bt,
      samples: kept,
    );
  }
}

/// A half-open span of time. Several of them are how a section says "only
/// while the line was running".
class TimeRange {
  final DateTime from;
  final DateTime to;

  const TimeRange(this.from, this.to);

  Duration get length => to.difference(from);
  bool get isEmpty => !to.isAfter(from);

  @override
  String toString() => '${from.toIso8601String()}..${to.toIso8601String()}';
}

/// Computes [agg] over the parts of [w] that fall inside [ranges], folding the
/// per-range results the way that aggregate means.
///
/// One range is the ordinary case — a section scoped to the production window
/// — and goes straight through [aggregate]. Several ranges is the "while
/// running" scope, where the point of the fold is that the pauses between the
/// ranges contribute nothing: a counter that was reset while the line stood
/// still does not invent production, and an average is not dragged down by
/// hours of zeros.
double? aggregateOver(
    ReportAggregate agg, SampleWindow w, List<TimeRange> ranges) {
  final live = ranges.where((r) => !r.isEmpty).toList();
  if (live.isEmpty) {
    // A range of no length still answers with whatever stood there, which is
    // what aggregating over it directly would say. Only the absence of any
    // range at all means "nothing to compute".
    return ranges.isEmpty
        ? null
        : aggregate(agg, w.clip(ranges.first.from, ranges.first.to));
  }
  if (live.length == 1) {
    return aggregate(agg, w.clip(live.first.from, live.first.to));
  }

  final parts = [for (final r in live) w.clip(r.from, r.to)];
  final values = [for (final p in parts) aggregate(agg, p)];
  final known = <int>[
    for (var i = 0; i < values.length; i++)
      if (values[i] != null) i,
  ];
  if (known.isEmpty) return null;

  double sum(Iterable<double> xs) => xs.fold(0.0, (a, b) => a + b);
  final present = [for (final i in known) values[i]!];

  return switch (agg) {
    ReportAggregate.first => values[known.first],
    ReportAggregate.last => values[known.last],
    ReportAggregate.min => present.reduce((a, b) => a < b ? a : b),
    ReportAggregate.max => present.reduce((a, b) => a > b ? a : b),
    // Sample-weighted, so the fold equals the mean of all the samples in the
    // ranges — not the mean of the per-range means.
    ReportAggregate.mean => () {
        var total = 0.0;
        var n = 0;
        for (final i in known) {
          final c = parts[i].samples.length;
          if (c == 0) continue;
          total += values[i]! * c;
          n += c;
        }
        return n == 0 ? null : total / n;
      }(),
    // Duration-weighted, for the same reason.
    ReportAggregate.timeWeightedMean => () {
        var total = 0.0;
        var us = 0;
        for (final i in known) {
          final d = live[i].length.inMicroseconds;
          if (d <= 0) continue;
          total += values[i]! * d;
          us += d;
        }
        return us == 0 ? null : total / us;
      }(),
    ReportAggregate.delta ||
    ReportAggregate.count ||
    ReportAggregate.durationTrue ||
    ReportAggregate.durationFalse =>
      sum(present),
  };
}

/// Computes [agg] over [w]. Returns null when the window holds no data at
/// all; durations are returned as seconds.
double? aggregate(ReportAggregate agg, SampleWindow w) {
  if (w.isEmpty) return null;
  return switch (agg) {
    ReportAggregate.first => w.boundaryValue ?? w.samples.first.value,
    ReportAggregate.last =>
      w.samples.isNotEmpty ? w.samples.last.value : w.boundaryValue,
    ReportAggregate.min => _extreme(w, (a, b) => a < b),
    ReportAggregate.max => _extreme(w, (a, b) => a > b),
    ReportAggregate.mean => _mean(w),
    ReportAggregate.timeWeightedMean => _timeWeighted(w, (v) => v),
    ReportAggregate.delta => _delta(w),
    ReportAggregate.count => w.samples.length.toDouble(),
    ReportAggregate.durationTrue => _timeWeighted(w, (v) => v != 0 ? 1 : 0,
        asIntegralSeconds: true),
    ReportAggregate.durationFalse => _timeWeighted(w, (v) => v == 0 ? 1 : 0,
        asIntegralSeconds: true),
  };
}

/// Min/max over everything that stood in the window, boundary value included:
/// the standing value *was* the value for part of the range.
double? _extreme(SampleWindow w, bool Function(double a, double b) better) {
  double? best = w.boundaryValue;
  for (final s in w.samples) {
    if (best == null || better(s.value, best)) best = s.value;
  }
  return best;
}

/// Plain average of the in-range samples. Kept sample-based on purpose — it
/// answers "what did the samples average", not "what stood over time"; the
/// latter is [ReportAggregate.timeWeightedMean].
double? _mean(SampleWindow w) {
  if (w.samples.isEmpty) return null;
  var sum = 0.0;
  for (final s in w.samples) {
    sum += s.value;
  }
  return sum / w.samples.length;
}

/// Walks the step-hold segments of the window: the boundary value holds from
/// [SampleWindow.start] to the first sample, each sample holds until the
/// next, the last holds until [SampleWindow.end].
///
/// With [asIntegralSeconds] the mapped value is integrated (seconds spent at
/// map(v)==1 when the map is a predicate); otherwise the time-weighted mean
/// of the mapped value is returned.
double? _timeWeighted(SampleWindow w, double Function(double v) map,
    {bool asIntegralSeconds = false}) {
  var t = w.start;
  var v = w.boundaryValue;
  var weighted = 0.0;
  var totalUs = 0;

  void segment(DateTime until) {
    final standing = v;
    if (standing == null || !until.isAfter(t)) return;
    final us = until.difference(t).inMicroseconds;
    weighted += map(standing) * us;
    totalUs += us;
  }

  for (final s in w.samples) {
    final at = s.time.isAfter(w.end) ? w.end : s.time;
    segment(at);
    if (at.isAfter(t)) t = at;
    v = s.value;
  }
  segment(w.end);

  if (asIntegralSeconds) return weighted / 1e6;
  if (totalUs == 0) {
    // No time elapsed with a known value — fall back to the standing value so
    // an instantaneous window still answers something sensible.
    return v;
  }
  return weighted / totalUs;
}

/// Counter increase over the window, robust to resets and rollovers: a drop
/// is read as "the counter started over", so the new value counts from zero
/// and the result never goes negative on a mid-shift reset.
double? _delta(SampleWindow w) {
  double? prev = w.boundaryValue;
  var total = 0.0;
  var sawAnything = prev != null;
  for (final s in w.samples) {
    sawAnything = true;
    if (prev != null) {
      final diff = s.value - prev;
      total += diff >= 0 ? diff : s.value;
    }
    prev = s.value;
  }
  return sawAnything ? total : null;
}

/// One chart bucket: the shape a report chart draws.
class ReportChartPoint {
  final DateTime time;
  final double min;
  final double avg;
  final double max;

  const ReportChartPoint({
    required this.time,
    required this.min,
    required this.avg,
    required this.max,
  });
}

/// Buckets the window's samples into at most [maxPoints] min/avg/max points.
/// Empty buckets are skipped rather than zero-filled — a gap in the data
/// should look like a gap.
List<ReportChartPoint> bucketize(SampleWindow w, int maxPoints) {
  if (w.samples.isEmpty || maxPoints <= 0) return const [];
  final rangeUs = w.end.difference(w.start).inMicroseconds;
  if (rangeUs <= 0) return const [];
  final bucketUs = (rangeUs / maxPoints).ceil();

  final out = <ReportChartPoint>[];
  var idx = -1;
  double lo = 0, hi = 0, sum = 0;
  var n = 0;

  void flush() {
    if (n == 0) return;
    out.add(ReportChartPoint(
      time: w.start.add(Duration(microseconds: idx * bucketUs)),
      min: lo,
      avg: sum / n,
      max: hi,
    ));
  }

  for (final s in w.samples) {
    final i = s.time.difference(w.start).inMicroseconds ~/ bucketUs;
    if (i != idx) {
      flush();
      idx = i;
      lo = hi = sum = 0;
      n = 0;
    }
    if (n == 0) {
      lo = hi = s.value;
    } else {
      if (s.value < lo) lo = s.value;
      if (s.value > hi) hi = s.value;
    }
    sum += s.value;
    n++;
  }
  flush();
  return out;
}

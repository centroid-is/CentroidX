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

  /// Samples strictly after [start] and at or before [end], sorted by time.
  final List<Sample> samples;

  const SampleWindow({
    required this.start,
    required this.end,
    required this.boundaryValue,
    required this.samples,
  });

  bool get isEmpty => samples.isEmpty && boundaryValue == null;
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

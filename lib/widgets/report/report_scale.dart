import 'dart:math' as math;

/// A value axis with round tick values.
///
/// [min] and [max] are the *scaled* bounds — already pushed out to whole
/// steps — so a plot drawn between them always starts and ends on a labelled
/// gridline.
class AxisScale {
  final double min;
  final double max;
  final double step;

  const AxisScale({required this.min, required this.max, required this.step});

  double get span => max - min;

  /// Where [v] sits on the axis, 0 at [min] and 1 at [max].
  double fraction(double v) => span == 0 ? 0 : (v - min) / span;

  List<double> get ticks {
    if (step <= 0 || span <= 0) return [min];
    final out = <double>[];
    // Counted rather than accumulated: adding a step repeatedly drifts, and a
    // drifted 1200 renders as 1199.9999999999998.
    final count = (span / step).round();
    for (var i = 0; i <= count; i++) {
      out.add(min + step * i);
    }
    return out;
  }
}

/// Steps a person would choose: 1, 2, 2.5 and 5 per decade.
///
/// 2.5 earns its place on a range like 0..1200, where 1-2-5 gives either five
/// ticks of 250 (fine) or three of 500 (coarse); without it a lot of plant
/// rates land on axes labelled 0/400/800/1200 or nothing at all.
const _niceSteps = <double>[1, 2, 2.5, 5, 10];

/// A round-numbered scale covering `[min, max]` in roughly [target] steps.
///
/// This exists because an axis labelled 888/976/1064/1152 — what a
/// divide-the-range-by-four axis produces — is unreadable: every label is a
/// different shape and none of them is a number anybody would say out loud.
/// The ticks here are always a round step apart, and the bounds are pushed out
/// to whole steps so the top and bottom of the plot are labelled too.
AxisScale niceTicks(double min, double max, {int target = 4}) {
  if (!min.isFinite || !max.isFinite) {
    return const AxisScale(min: 0, max: 1, step: 1);
  }
  var lo = math.min(min, max);
  var hi = math.max(min, max);
  if (lo == hi) {
    // A flat series still needs an axis with height to it, or the line has
    // nowhere to sit.
    final pad = lo == 0 ? 1.0 : lo.abs() * 0.1;
    lo -= pad;
    hi += pad;
  }
  final steps = target < 1 ? 1 : target;

  final rough = (hi - lo) / steps;
  final magnitude = math.pow(10, (math.log(rough) / math.ln10).floor()).toDouble();
  final normalized = rough / magnitude;
  var step = _niceSteps.last * magnitude;
  for (final candidate in _niceSteps) {
    if (normalized <= candidate) {
      step = candidate * magnitude;
      break;
    }
  }
  if (step <= 0 || !step.isFinite) return const AxisScale(min: 0, max: 1, step: 1);

  final scaledMin = (lo / step).floor() * step;
  final scaledMax = (hi / step).ceil() * step;
  return AxisScale(
    // -0.0 formats as "-0", which reads as a value rather than the origin.
    min: scaledMin == 0 ? 0 : scaledMin,
    max: scaledMax == scaledMin ? scaledMin + step : scaledMax,
    step: step,
  );
}

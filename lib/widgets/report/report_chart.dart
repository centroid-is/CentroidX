import 'package:flutter/material.dart';
// Only NumberFormat: intl also exports a TextDirection, which would shadow
// Flutter's and break every TextPainter in this file.
import 'package:intl/intl.dart' show NumberFormat;
import 'package:tfc_dart/tfc_dart.dart';

import '../../theme.dart';
import '../stop_timeline_geometry.dart';
import 'report_scale.dart';
import 'report_time_axis.dart';

/// Plot height, above the axis strip. The two together are the 200px a chart
/// section occupies — the container includes its own axis band, so a chart
/// never grows a nested scrollbar to reach its labels.
const double kReportPlotHeight = 170;

/// How many series get drawn before the rest are folded into a count.
///
/// Past four lines a report chart stops being a shape and becomes a puzzle,
/// and the fifth categorical hue is the one that stops being distinguishable
/// under colour-vision deficiency.
const int kMaxChartSeries = 4;

/// A report's chart, drawn against the report's own time scale.
///
/// Hand-painted rather than handed to the charting package, for three reasons
/// that all matter here: it has to share the production band's x-scale so a
/// dip lines up with the stop above it, it has to shade the parts of the range
/// that were outside the production window, and it has to mark now. None of
/// the three is expressible through a general-purpose chart widget.
class ReportChart extends StatelessWidget {
  const ReportChart({
    super.key,
    required this.section,
    required this.rangeStart,
    required this.rangeEnd,
    this.window,
  });

  final ChartSectionResult section;
  final DateTime rangeStart;
  final DateTime rangeEnd;
  final ProductionWindow? window;

  List<ChartSeriesResult> get _drawn {
    final withPoints = [
      for (final s in section.series)
        if (s.points.isNotEmpty) s,
    ];
    return withPoints.take(kMaxChartSeries).toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final series = _drawn;

    if (series.isEmpty) {
      return SizedBox(
        height: 80,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text('No data in this range',
              style: theme.textTheme.bodySmall?.copyWith(color: muted)),
        ),
      );
    }

    final hmi = HmiStateColors.of(context);
    final palette = <Color>[
      theme.colorScheme.primary,
      hmi.blue,
      hmi.yellow,
      hmi.violet,
    ];
    final hidden = section.series.where((s) => s.points.isNotEmpty).length -
        series.length;
    final timeline = reportWindow(
        window?.nominalStart ?? rangeStart, window?.nominalEnd ?? rangeEnd);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _topRow(context, series, palette, hidden),
        SizedBox(
          height: kReportPlotHeight,
          width: double.infinity,
          child: CustomPaint(
            painter: _ChartPainter(
              series: series,
              palette: palette,
              window: timeline,
              scale: _scale(series),
              // Not dividerColor: in this theme that resolves near-black, and
              // a black hairline every hour reads as data rather than grid.
              gridColor: theme.colorScheme.onSurface.withValues(alpha: 0.12),
              labelColor: muted,
              // Strong enough to be unmistakable against the area wash below
              // it — the two greys are saying opposite things ("this is the
              // data" / "this was not counted") and must not look alike.
              outsideColor: theme.colorScheme.surface.withValues(alpha: 0.78),
              markerColor: theme.colorScheme.onSurface,
              labelStyle: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 10,
                    color: muted,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ) ??
                  const TextStyle(fontSize: 10),
              outside: _outsideRanges(),
              conclusion: window?.concludedAt,
            ),
          ),
        ),
        ReportTimeAxisBar(window: timeline),
      ],
    );
  }

  /// Legend (two or more series) or the single series' summary — never both a
  /// legend and a one-swatch box restating the section title.
  Widget _topRow(BuildContext context, List<ChartSeriesResult> series,
      List<Color> palette, int hidden) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final children = <Widget>[];

    if (series.length > 1) {
      for (var i = 0; i < series.length; i++) {
        children.add(Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 12, height: 2, color: palette[i % palette.length]),
            const SizedBox(width: 6),
            // Identity rides the coloured key beside the text, never the text
            // itself: a light categorical hue is illegible as a label.
            Text(series[i].label,
                style: theme.textTheme.labelSmall?.copyWith(color: muted)),
          ],
        ));
      }
      if (hidden > 0) {
        children.add(Text('+$hidden not drawn',
            style: theme.textTheme.labelSmall?.copyWith(color: muted)));
      }
    }

    final summary = series.length == 1 ? _summary(series.single) : null;
    if (children.isEmpty && summary == null) return const SizedBox(height: 4);

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(child: Wrap(spacing: 16, runSpacing: 4, children: children)),
          if (summary != null)
            Text(summary,
                style: theme.textTheme.labelSmall?.copyWith(color: muted)),
        ],
      ),
    );
  }

  String _summary(ChartSeriesResult s) {
    var sum = 0.0;
    var peak = s.points.first.max;
    for (final p in s.points) {
      sum += p.avg;
      if (p.max > peak) peak = p.max;
    }
    return 'avg ${_number(sum / s.points.length)} · peak ${_number(peak)}';
  }

  AxisScale _scale(List<ChartSeriesResult> series) {
    var lo = double.infinity;
    var hi = double.negativeInfinity;
    for (final s in series) {
      for (final p in s.points) {
        if (p.avg < lo) lo = p.avg;
        if (p.avg > hi) hi = p.avg;
      }
    }
    if (!lo.isFinite || !hi.isFinite) return niceTicks(0, 1);
    // A rate baselined at 880 exaggerates every wobble into a cliff. When the
    // values are all positive the axis starts where the quantity does.
    return niceTicks(lo >= 0 ? 0 : lo, hi);
  }

  /// The stretches of the drawn range that fall outside the production window
  /// — before the line started, after it concluded, after now.
  List<TimeRange> _outsideRanges() {
    final w = window;
    if (w == null) return const [];
    final out = <TimeRange>[];
    final start = w.actualStart;
    if (start != null && start.isAfter(w.nominalStart)) {
      out.add(TimeRange(w.nominalStart, start));
    }
    final end = w.concludedAt;
    if (end != null && end.isBefore(w.nominalEnd)) {
      out.add(TimeRange(end, w.nominalEnd));
    } else if (w.cap.isBefore(w.nominalEnd)) {
      out.add(TimeRange(w.cap, w.nominalEnd));
    }
    if (w.isEmpty) {
      out.add(TimeRange(w.nominalStart, w.cap));
    }
    return out;
  }
}

String _number(double v) => NumberFormat.decimalPatternDigits(
        locale: 'en_US', decimalDigits: v.abs() >= 100 ? 0 : 1)
    .format(v);

/// Every tick on one axis shares a format, decided by the step rather than by
/// each value. Mixing "1,500" with "0.0" down a single axis makes a reader
/// stop and check whether the units changed halfway.
String _axisNumber(double v, double step) {
  final digits = step >= 1
      ? 0
      : step >= 0.1
          ? 1
          : 2;
  return NumberFormat.decimalPatternDigits(
          locale: 'en_US', decimalDigits: digits)
      .format(v);
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.series,
    required this.palette,
    required this.window,
    required this.scale,
    required this.gridColor,
    required this.labelColor,
    required this.outsideColor,
    required this.markerColor,
    required this.labelStyle,
    required this.outside,
    required this.conclusion,
  });

  final List<ChartSeriesResult> series;
  final List<Color> palette;
  final TimelineWindow window;
  final AxisScale scale;
  final Color gridColor;
  final Color labelColor;
  final Color outsideColor;
  final Color markerColor;
  final TextStyle labelStyle;
  final List<TimeRange> outside;
  final DateTime? conclusion;

  double _y(double value, double height) =>
      height - scale.fraction(value) * height;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    final grid = Paint()..color = gridColor;
    for (final tick in scale.ticks) {
      final y = _y(tick, h).roundToDouble();
      canvas.drawRect(Rect.fromLTWH(0, y, w, 1), grid);
    }
    for (final tick in timelineTicks(window, w)) {
      canvas.drawRect(Rect.fromLTWH(tick.x, 0, 1, h), grid);
    }

    for (var i = 0; i < series.length; i++) {
      _drawSeries(canvas, size, series[i], palette[i % palette.length],
          wash: series.length == 1);
    }

    // The parts of the range the figures below do not cover, dimmed over the
    // data rather than cropped out of it: the reader still sees the line was
    // flat there, and sees that it was not counted.
    for (final range in outside) {
      final x1 = window.xOf(range.from, w);
      final x2 = window.xOf(range.to, w);
      if (x2 <= x1) continue;
      canvas.drawRect(
          Rect.fromLTRB(x1, 0, x2, h), Paint()..color = outsideColor);
    }
    final end = conclusion;
    if (end != null) {
      final x = window.xOf(end, w);
      if (x > 0 && x < w) {
        canvas.drawRect(Rect.fromLTWH(x, 0, 1, h),
            Paint()..color = markerColor.withValues(alpha: 0.7));
      }
    }

    // Axis values last so a line never crosses a number. They sit on the
    // gridline they label rather than in a left gutter, which keeps the plot
    // exactly as wide as the production band above it.
    for (final tick in scale.ticks) {
      final y = _y(tick, h).roundToDouble();
      final painter = TextPainter(
        text: TextSpan(text: _axisNumber(tick, scale.step), style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      final top = (y - painter.height - 1).clamp(0.0, h - painter.height);
      painter.paint(canvas, Offset(2, top));
    }

    if (series.length == 1) _drawEndLabel(canvas, size, series.single);
  }

  /// The bucket spacing the series was built on, as the gap between
  /// consecutive points most of them share.
  Duration _spacing(List<ReportChartPoint> points) {
    if (points.length < 2) return Duration.zero;
    final gaps = <int>[
      for (var i = 1; i < points.length; i++)
        points[i].time.difference(points[i - 1].time).inMicroseconds,
    ]..sort();
    return Duration(microseconds: gaps[gaps.length ~/ 2]);
  }

  void _drawSeries(Canvas canvas, Size size, ChartSeriesResult s, Color color,
      {required bool wash}) {
    final w = size.width;
    final h = size.height;
    final spacing = _spacing(s.points);
    // An empty bucket is a gap in the record, not a zero. Joining across one
    // would draw production that never happened.
    final maxGap = spacing.inMicroseconds * 1.5;

    final runs = <List<Offset>>[];
    var current = <Offset>[];
    ReportChartPoint? previous;
    for (final p in s.points) {
      if (previous != null &&
          maxGap > 0 &&
          p.time.difference(previous.time).inMicroseconds > maxGap) {
        runs.add(current);
        current = [];
      }
      current.add(Offset(window.xOf(p.time, w), _y(p.avg, h)));
      previous = p;
    }
    if (current.isNotEmpty) runs.add(current);

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;

    for (final run in runs) {
      if (run.isEmpty) continue;
      if (run.length == 1) {
        canvas.drawCircle(run.single, 2, Paint()..color = color);
        continue;
      }
      final path = Path()..moveTo(run.first.dx, run.first.dy);
      for (final point in run.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
      if (wash) {
        // A wash, not a block: 10% of the line's own hue, so the area reads
        // as "under this line" without becoming a second mark.
        final area = Path.from(path)
          ..lineTo(run.last.dx, h)
          ..lineTo(run.first.dx, h)
          ..close();
        canvas.drawPath(area, Paint()..color = color.withValues(alpha: 0.07));
      }
      canvas.drawPath(path, stroke);
    }
  }

  /// One direct label at the line's end — the value a reader most wants and
  /// would otherwise read off a gridline. Skipped when it does not fit, never
  /// clipped.
  void _drawEndLabel(Canvas canvas, Size size, ChartSeriesResult s) {
    final last = s.points.last;
    final x = window.xOf(last.time, size.width);
    final y = _y(last.avg, size.height);
    final painter = TextPainter(
      text: TextSpan(
          text: _number(last.avg),
          style: labelStyle.copyWith(color: labelColor)),
      textDirection: TextDirection.ltr,
    )..layout();
    final left = x + 6;
    if (left + painter.width > size.width) return;
    painter.paint(
        canvas,
        Offset(left,
            (y - painter.height / 2).clamp(0.0, size.height - painter.height)));
  }

  @override
  bool shouldRepaint(_ChartPainter old) =>
      old.series != series ||
      old.window != window ||
      old.palette != palette ||
      old.outside != outside;
}

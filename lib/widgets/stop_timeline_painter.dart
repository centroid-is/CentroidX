import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:tfc_dart/core/alarm.dart' show AlarmLevel;
import 'package:tfc_dart/core/alarm_interval.dart';

import '../theme.dart';
import 'hatch.dart';
import 'stop_timeline_geometry.dart';

/// The severity colours, taken from [AlarmColors] so this asset never invents
/// a second colour language for the same three levels. They are deliberately
/// identical in both schemes (ISA-18.2).
Color colorForLevel(BuildContext context, AlarmLevel level) {
  final colors = AlarmColors.of(context);
  return switch (level) {
    AlarmLevel.info => colors.info,
    AlarmLevel.warning => colors.warning,
    AlarmLevel.error => colors.error,
  };
}

/// Paints one lane's bars.
///
/// Painted rather than built: a shift of chattering alarms is thousands of
/// rectangles, which is nothing for a canvas and fatal for a widget tree. The
/// painter takes its window from a [Listenable] so a pan repaints without
/// rebuilding anything above it.
class StopLanePainter extends CustomPainter {
  StopLanePainter({
    required this.series,
    required this.window,
    required this.now,
    required this.colors,
    required this.isGroup,
    required this.selectedInterval,
    required this.selectionColor,
    required this.laneColor,
    super.repaint,
  });

  final AlarmIntervalSeries series;
  final ValueListenable<TimelineWindow> window;
  final DateTime Function() now;

  /// Severity colour per level, resolved once by the caller so the painter
  /// does not need a BuildContext.
  final Map<AlarmLevel, Color> colors;

  /// Group lanes draw a heavier bar than alarm lanes, so "the whole group was
  /// down" never reads as just another alarm.
  final bool isGroup;

  final AlarmInterval? selectedInterval;
  final Color selectionColor;
  final Color laneColor;

  @override
  void paint(Canvas canvas, Size size) {
    // CustomPaint does not clip. An interval that started before the window
    // maps to a negative x, and without this clip its bar paints straight
    // across the label column to the left of the lane.
    canvas.clipRect(Offset.zero & size);
    canvas.drawRect(
        Offset.zero & size, Paint()..color = laneColor);

    final clock = now();
    final runs = laneRuns(series, window.value, size.width, now: clock);
    if (runs.isEmpty) return;

    final height = isGroup ? 14.0 : 8.0;
    final top = (size.height - height) / 2;

    for (final run in runs) {
      final paint = Paint()..color = colors[run.level]!;
      final rect = Rect.fromLTWH(run.x1, top, run.width, height);
      canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(1)), paint);

      // A bar at the minimum width is a stop too short to see. The tick above
      // and below turns a burst of them into a comb rather than a smudge.
      if (run.width <= minRunWidth + 0.01) {
        canvas.drawRect(
          Rect.fromLTWH(run.x1 + run.width / 2 - 0.5, top - 3, 1, height + 6),
          paint..color = paint.color.withValues(alpha: 0.55),
        );
      }

      // An alarm that has not cleared has no right edge to draw; it is marked
      // instead, so "still standing" is visible without reading the detail row.
      if (run.isOpen) {
        canvas.drawRect(
          Rect.fromLTWH(run.x2 - 1.5, top - 3, 2.5, height + 6),
          Paint()..color = colors[run.level]!,
        );
      }

      if (selectedInterval != null &&
          run.merged == 1 &&
          identical(run.interval, selectedInterval)) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect.inflate(2), const Radius.circular(2)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = selectionColor,
        );
      }
    }
  }

  @override
  bool shouldRepaint(StopLanePainter old) =>
      old.series != series ||
      old.selectedInterval != selectedInterval ||
      old.isGroup != isGroup ||
      old.laneColor != laneColor;
}

/// Gridlines, the unscheduled hatch and the dimmed future, drawn once over
/// every lane rather than eleven times per row.
class StopTimelineChromePainter extends CustomPainter {
  StopTimelineChromePainter({
    required this.window,
    required this.now,
    required this.excluded,
    required this.lineColor,
    required this.hourLineColor,
    required this.hatchColor,
    required this.futureColor,
    required this.nowColor,
    super.repaint,
  });

  final ValueListenable<TimelineWindow> window;
  final DateTime Function() now;
  final List<TimeRange> excluded;
  final Color lineColor;
  final Color hourLineColor;
  final Color hatchColor;
  final Color futureColor;
  final Color nowColor;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final w = window.value;

    // Unscheduled time is not downtime. Hatched so it reads as "the plant was
    // not meant to be running", and excluded from every duration reported.
    for (final range in excluded) {
      final x1 = w.xOf(range.start, size.width);
      final x2 = w.xOf(range.end, size.width);
      if (x2 <= 0 || x1 >= size.width) continue;
      paintHatch(canvas, Rect.fromLTRB(x1, 0, x2, size.height), hatchColor);
    }

    for (final tick in timelineTicks(w, size.width)) {
      canvas.drawRect(
        Rect.fromLTWH(tick.x, 0, 1, size.height),
        Paint()..color = tick.isHour ? hourLineColor : lineColor,
      );
    }

    final clock = now();
    if (clock.isBefore(w.end)) {
      final x = w.xOf(clock, size.width).clamp(0.0, size.width);
      canvas.drawRect(Rect.fromLTRB(x, 0, size.width, size.height),
          Paint()..color = futureColor);
      if (clock.isAfter(w.start)) {
        canvas.drawRect(
            Rect.fromLTWH(x, 0, 1, size.height), Paint()..color = nowColor);
      }
    }
  }

  @override
  bool shouldRepaint(StopTimelineChromePainter old) =>
      old.excluded != excluded ||
      old.lineColor != lineColor ||
      old.hourLineColor != hourLineColor ||
      old.hatchColor != hatchColor ||
      old.nowColor != nowColor ||
      old.futureColor != futureColor;
}

/// The overview strip: the whole period, with the visible window on top of it.
class StopTimelineBrushPainter extends CustomPainter {
  StopTimelineBrushPainter({
    required this.period,
    required this.window,
    required this.intervals,
    required this.now,
    required this.colors,
    required this.trackColor,
    required this.windowColor,
    required this.shadeColor,
    super.repaint,
  });

  final TimelineWindow period;
  final ValueListenable<TimelineWindow> window;

  /// The union across everything in scope — what the whole shift looked like.
  final List<AlarmInterval> intervals;
  final DateTime Function() now;
  final Map<AlarmLevel, Color> colors;
  final Color trackColor;
  final Color windowColor;
  final Color shadeColor;

  @override
  void paint(Canvas canvas, Size size) {
    // Same clip as the lanes: an interval reaching outside the period must
    // not paint across the day label beside the strip.
    canvas.clipRect(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, Paint()..color = trackColor);

    final clock = now();
    for (final iv in intervals) {
      final x1 = period.xOf(iv.start, size.width);
      var x2 = period.xOf(iv.endAt(clock), size.width);
      if (x2 - x1 < 1.5) x2 = x1 + 1.5;
      canvas.drawRect(
        Rect.fromLTRB(x1, size.height * 0.2, x2, size.height * 0.8),
        Paint()..color = colors[iv.level]!,
      );
    }

    final w = window.value;
    final left = period.xOf(w.start, size.width).clamp(0.0, size.width);
    final right = period.xOf(w.end, size.width).clamp(0.0, size.width);
    final shade = Paint()..color = shadeColor;
    canvas.drawRect(Rect.fromLTRB(0, 0, left, size.height), shade);
    canvas.drawRect(Rect.fromLTRB(right, 0, size.width, size.height), shade);
    // Filled as well as outlined: a stroke alone on a track the same colour as
    // the surface behind it reads as a stray line rather than a handle.
    final windowRect = Rect.fromLTRB(left, 0.5, right, size.height - 0.5);
    canvas.drawRect(
        windowRect, Paint()..color = windowColor.withValues(alpha: 0.18));
    canvas.drawRect(
      windowRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = windowColor,
    );
  }

  @override
  bool shouldRepaint(StopTimelineBrushPainter old) =>
      old.intervals != intervals || old.period != period;
}

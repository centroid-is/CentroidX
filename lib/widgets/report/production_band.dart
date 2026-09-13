import 'package:flutter/material.dart';
import 'package:tfc_dart/tfc_dart.dart';

import '../../theme.dart';
import '../hatch.dart';
import '../stop_timeline_geometry.dart';

/// The colour each production state is drawn in.
///
/// Straight out of the theme's state colours, so the band says "running" in
/// the same green the conveyor assets do. Idle is the scheme grey held back to
/// 55% — it is the absence of activity and should recede behind the states
/// that are something happening.
Map<ProductionState, Color> productionStateColors(BuildContext context) {
  final hmi = HmiStateColors.of(context);
  return {
    ProductionState.running: hmi.green,
    ProductionState.cleaning: hmi.blue,
    ProductionState.idle: hmi.grey.withValues(alpha: 0.55),
    ProductionState.fault: hmi.red,
    // Hatched, never filled — the fill colour here is only the hatch ink.
    ProductionState.noData: Theme.of(context).colorScheme.onSurface,
  };
}

/// The shift as one strip: what the plant was doing, minute by minute.
///
/// This is the picture the whole report hangs off — "how did the shift go" is
/// answered by its shape before a single number is read.
class ProductionBand extends StatelessWidget {
  const ProductionBand({
    super.key,
    required this.window,
    this.height = 26,
    this.laneHeight = 12,
    this.showLanes = true,
  });

  final ProductionWindow window;
  final double height;
  final double laneHeight;

  /// Per-signal lanes under the merged band. Only drawn when the report
  /// watches more than one signal — with one, the lane and the band are the
  /// same picture twice.
  final bool showLanes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final timeline = TimelineWindow(window.nominalStart, window.nominalEnd);
    final colors = productionStateColors(context);
    final lanes = showLanes && window.lanes.length > 1 ? window.lanes : const <SignalLane>[];

    Widget strip(List<StateSegment> segments, double h) => SizedBox(
          height: h,
          width: double.infinity,
          child: CustomPaint(
            painter: _BandPainter(
              segments: segments,
              window: timeline,
              colors: colors,
              // Slightly stronger than the charts' grid: these lines cross
              // filled state colour, not an empty plot. Still a hairline.
              gridColor: theme.colorScheme.onSurface.withValues(alpha: 0.18),
              futureColor: theme.colorScheme.surface.withValues(alpha: 0.5),
              markerColor: theme.colorScheme.onSurface,
              cap: window.cap,
              markers: [
                if (window.actualStart != null) window.actualStart!,
                if (window.concludedAt != null) window.concludedAt!,
              ],
            ),
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        strip(window.segments, height),
        for (final lane in lanes) ...[
          const SizedBox(height: 6),
          Text(
            lane.label,
            style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 10, color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 2),
          strip(lane.segments, laneHeight),
        ],
      ],
    );
  }
}

class _BandPainter extends CustomPainter {
  _BandPainter({
    required this.segments,
    required this.window,
    required this.colors,
    required this.gridColor,
    required this.futureColor,
    required this.markerColor,
    required this.cap,
    required this.markers,
  });

  final List<StateSegment> segments;
  final TimelineWindow window;
  final Map<ProductionState, Color> colors;
  final Color gridColor;
  final Color futureColor;
  final Color markerColor;
  final DateTime cap;
  final List<DateTime> markers;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final width = size.width;
    if (width <= 0) return;

    for (var i = 0; i < segments.length; i++) {
      final seg = segments[i];
      final x1 = window.xOf(seg.from, width);
      var x2 = window.xOf(seg.to, width);
      // A 2px gap in the surface colour is what separates neighbouring
      // states; drawing a border round each one would add ink that is not
      // data. The last segment keeps its full width — there is nothing after
      // it to separate from.
      if (i < segments.length - 1) x2 -= 2;
      // A ninety-second stop over an eight-hour band is a third of a pixel.
      // Without a floor the short interruptions — the ones worth finding —
      // are exactly the ones that vanish.
      if (x2 - x1 < minRunWidth) x2 = x1 + minRunWidth;
      final rect = Rect.fromLTRB(x1, 0, x2, size.height);
      if (rect.right <= 0 || rect.left >= width) continue;

      if (seg.state == ProductionState.noData) {
        paintHatch(canvas, rect, colors[seg.state]!.withValues(alpha: 0.25));
        continue;
      }
      canvas.drawRect(rect, Paint()..color = colors[seg.state]!);
    }

    // Hour gridlines over the fills: solid hairlines, one step off the
    // surface, so they orient without competing.
    final grid = Paint()..color = gridColor;
    for (final tick in timelineTicks(window, width)) {
      canvas.drawRect(Rect.fromLTWH(tick.x, 0, 1, size.height), grid);
    }

    // The rest of a shift that has not happened yet is dimmed rather than
    // left blank, so "no data here" and "not yet" never look alike.
    if (cap.isBefore(window.end)) {
      final x = window.xOf(cap, width).clamp(0.0, width);
      canvas.drawRect(
          Rect.fromLTRB(x, 0, width, size.height), Paint()..color = futureColor);
      if (cap.isAfter(window.start)) {
        canvas.drawRect(Rect.fromLTWH(x, 0, 1, size.height),
            Paint()..color = markerColor);
      }
    }

    for (final at in markers) {
      final x = window.xOf(at, width);
      if (x < 0 || x > width) continue;
      canvas.drawRect(Rect.fromLTWH(x, 0, 1, size.height),
          Paint()..color = markerColor.withValues(alpha: 0.7));
    }
  }

  @override
  bool shouldRepaint(_BandPainter old) =>
      old.segments != segments ||
      old.window != window ||
      old.cap != cap ||
      old.gridColor != gridColor;
}

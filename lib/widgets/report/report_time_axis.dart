import 'package:flutter/material.dart';

import '../stop_timeline_geometry.dart';

/// The shared time scale a report is drawn against.
///
/// Every column on the page — the production band, each chart — maps time to
/// pixels through the same [TimelineWindow] over the *nominal* range, so
/// 09:00 is the same x everywhere and a dip in the chart lines up with the
/// stop in the band directly above it. That is the whole reason this is a
/// shared object rather than each painter scaling its own data.
TimelineWindow reportWindow(DateTime start, DateTime end) =>
    TimelineWindow(start, end.isAfter(start) ? end : start.add(const Duration(minutes: 1)));

/// The height the axis strip needs: one row of hour labels, one of markers.
const double kReportAxisHeight = 30;

String _two(int n) => n.toString().padLeft(2, '0');
String _hhmm(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}';
bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// A tick's label: the time, or the date on a midnight tick.
///
/// Same rule the stop timeline follows — over a range that crosses midnight,
/// "00:00" says nothing anybody needed to know and "02/09" says which day
/// begins.
String reportTickLabel(TimelineTick tick, TimelineWindow window) {
  if (!_sameDay(window.start, window.end) &&
      tick.at.hour == 0 &&
      tick.at.minute == 0) {
    return '${_two(tick.at.day)}/${_two(tick.at.month)}';
  }
  return _hhmm(tick.at);
}

/// One labelled instant called out under the band — when production started,
/// when it concluded, where now is.
class AxisMarker {
  final DateTime at;
  final String caption;

  const AxisMarker({required this.at, required this.caption});
}

/// Hour labels for a report column, with optional captions beneath them.
///
/// Painted as a fixed-height strip rather than letting the labels size it, so
/// every chart on the page reserves the same band for its axis and the plots
/// stay the same height as each other.
class ReportTimeAxisBar extends StatelessWidget {
  const ReportTimeAxisBar({
    super.key,
    required this.window,
    this.markers = const [],
  });

  final TimelineWindow window;
  final List<AxisMarker> markers;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tickStyle = theme.textTheme.labelSmall?.copyWith(
      fontSize: 10,
      color: theme.colorScheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final markerStyle = theme.textTheme.labelSmall?.copyWith(
      fontSize: 10,
      color: theme.colorScheme.onSurfaceVariant,
    );

    return SizedBox(
      height: kReportAxisHeight,
      child: LayoutBuilder(
        builder: (context, c) {
          final width = c.maxWidth;
          if (width <= 0) return const SizedBox.shrink();
          const tickWidth = 56.0;
          const markerWidth = 130.0;
          return Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              for (final tick in timelineTicks(window, width))
                Positioned(
                  // Nudged inside rather than clipped, the way the stop
                  // timeline does it: a label a few pixels off its gridline
                  // beats a first label reading ":00".
                  left: (tick.x - tickWidth / 2)
                      .clamp(0.0, (width - tickWidth).clamp(0.0, width)),
                  top: 2,
                  width: tickWidth,
                  child: Text(
                    reportTickLabel(tick, window),
                    textAlign: TextAlign.center,
                    style: tickStyle,
                  ),
                ),
              for (final marker in markers)
                Positioned(
                  left: (window.xOf(marker.at, width) - markerWidth / 2)
                      .clamp(0.0, (width - markerWidth).clamp(0.0, width)),
                  top: 16,
                  width: markerWidth,
                  child: Text(
                    marker.caption,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                    style: markerStyle,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

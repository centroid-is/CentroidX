import 'package:flutter/material.dart';
import 'package:tfc_dart/tfc_dart.dart';

import '../../theme.dart';
import '../panes/pane_chrome.dart';
import '../stop_timeline_geometry.dart';
import 'production_band.dart';
import 'report_time_axis.dart';

String _two(int n) => n.toString().padLeft(2, '0');
String _hm(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}';

/// The planned length, without the trailing zero minutes a whole-hour shift
/// would otherwise carry — "the planned 8h", not "the planned 8h 0m".
String _plannedLength(Duration d) {
  final text = formatDurationCompact(d);
  return text.endsWith(' 0m') ? text.substring(0, text.length - 3) : text;
}

/// One word for what filled the shift after production concluded.
String _tailWord(ConclusionReason reason) => switch (reason) {
      ConclusionReason.cleaning => 'washing',
      ConclusionReason.noData => 'no data',
      _ => 'idle',
    };

/// The chip that answers "how did this shift end" before anything else is
/// read.
///
/// Green only while the line is actually running: a finished shift is not a
/// problem and must not be coloured like one, and a shift that ended early
/// after a wash is the ordinary case in a fish plant, not a fault.
PaneStatus productionStatus(BuildContext context, ProductionWindow w) {
  final hmi = HmiStateColors.of(context);
  if (w.isEmpty) {
    return PaneStatus(
      label: w.tentative ? 'No production yet' : 'No production',
      color: hmi.grey,
      icon: Icons.remove_circle_outline,
    );
  }
  if (w.reason == ConclusionReason.ongoing) {
    return PaneStatus(
      label: 'Running',
      color: hmi.green,
      icon: Icons.play_circle_fill,
    );
  }
  if (w.reason == ConclusionReason.shiftEnd) {
    return PaneStatus(
      label: 'Ran to shift end',
      color: hmi.grey,
      icon: Icons.check_circle_outline,
    );
  }
  final at = w.concludedAt;
  if (w.tentative) {
    return PaneStatus(
      // The conclusion is a judgement on a shift that is still open: the line
      // starting again would undo it. The hourglass says "not final yet".
      label: 'Possibly concluded · ${_tailWord(w.reason)} since '
          '${at == null ? '' : _hm(at)}',
      color: hmi.grey,
      icon: Icons.hourglass_bottom,
    );
  }
  return PaneStatus(
    label: 'Concluded ${at == null ? '' : _hm(at)} · '
        'then ${_tailWord(w.reason)}',
    color: hmi.grey,
    icon: Icons.check_circle_outline,
  );
}

/// The strip at the top of a report: when production actually ran, how much of
/// the planned shift that was, and the shift's shape as one band.
///
/// A fish plant runs while there is fish. Every figure below this strip is
/// computed over the window it describes, so the window has to be the first
/// thing on the page — a throughput average means nothing until the reader
/// knows it covers six hours of production and not eight hours of clock.
class ProductionHeader extends StatelessWidget {
  const ProductionHeader({super.key, required this.window});

  final ProductionWindow window;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final timeline = TimelineWindow(window.nominalStart, window.nominalEnd);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'PRODUCTION WINDOW',
            style: theme.textTheme.labelSmall
                ?.copyWith(fontSize: 10, letterSpacing: 1.2, color: muted),
          ),
          const SizedBox(height: 6),
          _headline(context),
          const SizedBox(height: 18),
          _figures(context),
          const SizedBox(height: 16),
          ProductionBand(window: window),
          const SizedBox(height: 2),
          ReportTimeAxisBar(window: timeline, markers: _markers()),
        ],
      ),
    );
  }

  Widget _headline(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    if (window.isEmpty) {
      return Text(
        window.tentative
            ? 'No production in this shift yet'
            : 'No production in this shift',
        style: theme.textTheme.titleMedium?.copyWith(fontSize: 16),
      );
    }
    final ongoing = window.concludedAt == null;
    // An en dash, not an arrow: the app declares no font faces, and the
    // fallback the HMI actually renders with has no U+2192 — it came out as a
    // blank gap between the two times.
    final range = ongoing
        ? '${_hm(window.effectiveStart)} – now'
        : '${_hm(window.effectiveStart)} – ${_hm(window.effectiveEnd)}';
    final sub = ongoing
        ? '(${formatDurationCompact(window.effectiveDuration)} so far)'
        : '${formatDurationCompact(window.effectiveDuration)} of the planned '
            '${_plannedLength(window.nominalDuration)}';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(range,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontSize: 16, fontWeight: FontWeight.w500)),
        const SizedBox(width: 12),
        Flexible(
          child: Text(sub,
              style: theme.textTheme.bodySmall?.copyWith(color: muted)),
        ),
      ],
    );
  }

  /// The hero figure and the state breakdown beside it.
  ///
  /// The breakdown doubles as the band's legend — each figure carries the
  /// swatch its segments are drawn in — which is why the band below has no
  /// legend of its own. A separate legend would be the same five words twice.
  Widget _figures(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final colors = productionStateColors(context);
    final availability = window.availability;

    final entries = <(ProductionState, Duration)>[
      (ProductionState.running, window.running),
      (ProductionState.fault, window.fault),
      (ProductionState.idle, window.idle),
      (ProductionState.cleaning, window.cleaning),
      if (window.noData > Duration.zero)
        (ProductionState.noData, window.noData),
    ];

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (availability != null) ...[
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${(availability * 100).round()}%',
                style: theme.textTheme.displaySmall?.copyWith(
                      fontSize: 44,
                      fontWeight: FontWeight.w600,
                      height: 1.0,
                    ) ??
                    const TextStyle(fontSize: 44),
              ),
              const SizedBox(height: 4),
              Text('availability',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(fontSize: 10, color: muted)),
            ],
          ),
          const SizedBox(width: 40),
        ],
        Expanded(
          child: Wrap(
            spacing: 28,
            runSpacing: 12,
            children: [
              for (final (state, duration) in entries)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: state == ProductionState.noData
                              ? BoxDecoration(
                                  border: Border.all(
                                      color: colors[state]!
                                          .withValues(alpha: 0.45)))
                              : BoxDecoration(color: colors[state]),
                        ),
                        const SizedBox(width: 6),
                        Text(formatDurationCompact(duration),
                            style: theme.textTheme.titleMedium?.copyWith(
                                fontSize: 16, fontWeight: FontWeight.w500)),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Padding(
                      padding: const EdgeInsets.only(left: 14),
                      child: Text(state.label,
                          style: theme.textTheme.labelSmall
                              ?.copyWith(fontSize: 10, color: muted)),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }

  List<AxisMarker> _markers() {
    final out = <AxisMarker>[];
    final start = window.actualStart;
    if (start != null) {
      out.add(AxisMarker(at: start, caption: 'started ${_hm(start)}'));
    }
    final end = window.concludedAt;
    if (end != null && window.endedEarly) {
      out.add(AxisMarker(at: end, caption: 'concluded ${_hm(end)}'));
    }
    if (window.cap.isBefore(window.nominalEnd) &&
        window.cap.isAfter(window.nominalStart)) {
      out.add(AxisMarker(at: window.cap, caption: 'now'));
    }
    return out;
  }
}

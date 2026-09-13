import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:tfc_dart/tfc_dart.dart';

/// The one-word qualifier a label earns when the aggregate changes what the
/// number *is* rather than how it was computed.
///
/// "Freezer temp · peak" is a different quantity from "Freezer temp"; an
/// average is not — it is what anybody assumes a shift figure already is. That
/// asymmetry is why the old "Avg (time-weighted)" subtitle under every tile
/// was noise: it spent a line of every tile explaining the engine to a reader
/// who wanted to know how the shift went.
String? aggregateQualifier(ReportAggregate aggregate) => switch (aggregate) {
      ReportAggregate.min => 'low',
      ReportAggregate.max => 'peak',
      ReportAggregate.first => 'start',
      ReportAggregate.last => 'end',
      _ => null,
    };

/// The number part of a metric, without its unit.
///
/// Grouped thousands, because 5231 and 52310 are the same shape at a glance
/// and 5,231 and 52,310 are not. Durations keep h:mm:ss — the form a shift is
/// actually discussed in.
String formatMetricValue(MetricResult m) {
  final v = m.value;
  if (v == null) return '—';
  if (m.aggregate.isDuration) return formatSeconds(v);
  // Locale pinned: the figure a report shows must not depend on which machine
  // it is read on, and goldens have to be reproducible.
  return NumberFormat.decimalPatternDigits(
          locale: 'en_US', decimalDigits: m.decimals)
      .format(v);
}

/// The short "why not" under a missing figure. The full error, with the key in
/// it, is in the tooltip; this is the part that fits.
///
/// It must never end mid-phrase: "no collected data for" reads as a truncated
/// sentence and sends the reader hunting for the rest, so a clause left
/// dangling on a preposition loses it.
String shortMetricReason(String error) {
  var s = error.trim();
  final cut = s.indexOf(RegExp(r'["(]'));
  if (cut > 0) s = s.substring(0, cut).trim();
  s = s.replaceFirst(RegExp(r'\s+(for|in|of|on|at|from|to|with)$'), '');
  if (s.isEmpty) s = error.trim();
  // Cut on a word boundary. "no production in this ran…" is worse than either
  // the whole phrase or an honest "no production…", and it is the shape a
  // fixed character count always eventually produces.
  if (s.length > 32) {
    final boundary = s.lastIndexOf(' ', 31);
    s = '${s.substring(0, boundary > 12 ? boundary : 31).trimRight()}…';
  }
  return s;
}

/// One headline figure: value, what it is, and its unit.
///
/// No card and no border. A row of identically outlined boxes flattens five
/// different questions into one texture; whitespace separates them and the
/// value's size is what makes it the thing you read first.
class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.metric, this.minWidth = 150});

  final MetricResult metric;
  final double minWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final qualifier = aggregateQualifier(metric.aggregate);
    final label =
        qualifier == null ? metric.label : '${metric.label} · $qualifier';
    final error = metric.error;

    final value = Text(
      formatMetricValue(metric),
      style: theme.textTheme.headlineMedium?.copyWith(
            fontSize: 28,
            fontWeight: FontWeight.w500,
            height: 1.1,
            color: error == null ? theme.colorScheme.onSurface : muted,
          ) ??
          const TextStyle(fontSize: 28),
    );

    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: minWidth),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Tooltips enhance, never gate: the short reason is on the page and
          // the tooltip only adds the key and the detail.
          error == null ? value : Tooltip(message: error, child: value),
          const SizedBox(height: 6),
          Text(label, style: theme.textTheme.bodySmall),
          if (error != null)
            // Muted, not error red: a figure the collector never recorded is
            // missing, not faulted, and red is reserved for the plant state.
            Text(shortMetricReason(error),
                style: theme.textTheme.labelSmall
                    ?.copyWith(fontSize: 10, color: muted))
          else if (metric.unit != null && metric.unit!.isNotEmpty)
            Text(metric.unit!,
                style: theme.textTheme.labelSmall
                    ?.copyWith(fontSize: 10, color: muted)),
        ],
      ),
    );
  }
}

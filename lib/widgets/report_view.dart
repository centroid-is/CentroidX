import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:tfc_dart/tfc_dart.dart';

import '../theme.dart';
import 'panes/pane_chrome.dart';
import 'report/production_header.dart';
import 'report/report_chart.dart';
import 'report/stat_tile.dart';
import 'stop_timeline_painter.dart' show colorForLevel;

/// Renders one generated [ReportResult].
///
/// Pure over the result — no database, no providers — following the
/// StopTimelineView split so the whole report look is golden-testable from a
/// fixture. The page owns generation; this owns presentation.
///
/// The layout has one job: answer "how did the shift go" before anybody reads
/// a number. That is why the production window comes first and why sections
/// are separated by whitespace and a heading rule rather than by cards — five
/// identical outlined boxes give five different questions the same weight,
/// which is the same as giving none of them any.
class ReportView extends StatelessWidget {
  const ReportView({super.key, required this.result});

  final ReportResult result;

  @override
  Widget build(BuildContext context) {
    final window = result.window;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
      children: [
        _header(context),
        if (window != null) ...[
          const SizedBox(height: 16),
          ProductionHeader(window: window),
        ],
        for (final section in result.sections) ...[
          const SizedBox(height: 28),
          _section(context, section),
        ],
      ],
    );
  }

  // --------------------------------------------------------------- chrome

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    final hmi = HmiStateColors.of(context);
    final window = result.window;
    final fmt = DateFormat('dd-MM-yyyy HH:mm');
    // The range label (a shift label, "Today", ...) already names the span;
    // spelling the timestamps out again next to it just repeats it longer.
    final range = result.rangeLabel.isNotEmpty
        ? result.rangeLabel
        : '${fmt.format(result.rangeStart)} — ${fmt.format(result.rangeEnd)}';

    final status = window != null
        ? productionStatus(context, window)
        : result.partial
            ? PaneStatus(
                label: 'So far',
                color: hmi.grey,
                icon: Icons.hourglass_bottom)
            : null;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(result.reportName, style: theme.textTheme.headlineSmall),
              const SizedBox(height: 2),
              Text(
                '$range · generated ${fmt.format(result.generatedAt)}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        if (status != null) ...[
          const SizedBox(width: 16),
          PaneStatusChip(status: status),
        ],
      ],
    );
  }

  /// A section heading: the name, a hairline rule running to the edge, and —
  /// when the report resolved a production window — what span the figures
  /// below cover. Without a window there is only one span, and the caption
  /// would be a sentence repeated down the page saying nothing.
  Widget _heading(BuildContext context, String? title, ReportScope? scope) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final named = title != null && title.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          if (named) ...[
            Text(
              title.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 11,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w500,
                  color: theme.colorScheme.onSurface),
            ),
            const SizedBox(width: 12),
          ],
          // dividerColor resolves near-black in this theme, which turns a
          // heading rule into an underline. A low-alpha onSurface is the
          // recessive hairline the layout wants.
          Expanded(
            child: Container(
                height: 1,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.18)),
          ),
          if (scope != null && result.window != null) ...[
            const SizedBox(width: 12),
            Text(scope.caption,
                style: theme.textTheme.labelSmall
                    ?.copyWith(fontSize: 10, color: muted)),
          ],
        ],
      ),
    );
  }

  Widget _section(BuildContext context, ReportSectionResult section) {
    return switch (section) {
      KpiSectionResult s => _kpi(context, s),
      TableSectionResult s => _table(context, s),
      ChartSectionResult s => _chart(context, s),
      AlarmSummarySectionResult s => _alarmSummary(context, s),
      DowntimeSectionResult s => _downtime(context, s),
      SqlSectionResult s => _sql(context, s),
      TextSectionResult s => _text(context, s),
    };
  }

  // -------------------------------------------------------------- sections

  Widget _kpi(BuildContext context, KpiSectionResult s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(context, s.title ?? 'Key figures', s.scope),
        Wrap(
          spacing: 36,
          runSpacing: 20,
          children: [for (final m in s.metrics) StatTile(metric: m)],
        ),
      ],
    );
  }

  Widget _table(BuildContext context, TableSectionResult s) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;

    Widget cell(Widget child, {bool first = false}) => Padding(
          padding: EdgeInsets.fromLTRB(first ? 0 : 12, 8, 0, 8),
          child: child,
        );
    Widget head(String text, {TextAlign align = TextAlign.right}) => Text(
          text,
          textAlign: align,
          style: theme.textTheme.labelSmall
              ?.copyWith(fontSize: 10, letterSpacing: 0.6, color: muted),
        );

    String unitOf(TableRowResult row) {
      for (final c in row.cells) {
        if (c.unit != null && c.unit!.isNotEmpty) return c.unit!;
      }
      return '';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(context, s.title, s.scope),
        Table(
          columnWidths: {
            0: const FlexColumnWidth(),
            for (var i = 0; i < s.aggregates.length; i++)
              i + 1: const IntrinsicColumnWidth(),
            s.aggregates.length + 1: const IntrinsicColumnWidth(),
          },
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          // Hairline separators only: a ruled grid around every cell is ink
          // the numbers already imply.
          border: TableBorder(
              horizontalInside: BorderSide(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.18),
                  width: 1)),
          children: [
            TableRow(children: [
              cell(head('', align: TextAlign.left), first: true),
              for (final agg in s.aggregates) cell(head(agg.shortLabel)),
              cell(head('UNIT', align: TextAlign.left)),
            ]),
            for (final row in s.rows)
              TableRow(children: [
                cell(Text(row.label, style: theme.textTheme.bodyMedium),
                    first: true),
                for (final c in row.cells) cell(_numberCell(context, c)),
                cell(Text(unitOf(row),
                    style: theme.textTheme.bodySmall?.copyWith(color: muted))),
              ]),
          ],
        ),
      ],
    );
  }

  /// A right-aligned figure in tabular digits — the one place equal-width
  /// digits belong, where numbers have to line up down a column.
  Widget _numberCell(BuildContext context, MetricResult m) {
    final theme = Theme.of(context);
    final text = Text(
      formatMetricValue(m),
      textAlign: TextAlign.right,
      style: theme.textTheme.bodyMedium?.copyWith(
        fontFeatures: const [FontFeature.tabularFigures()],
        color: m.error == null
            ? theme.colorScheme.onSurface
            : theme.colorScheme.onSurfaceVariant,
      ),
    );
    return m.error == null ? text : Tooltip(message: m.error!, child: text);
  }

  Widget _chart(BuildContext context, ChartSectionResult s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(context, s.title, s.scope),
        ReportChart(
          section: s,
          rangeStart: result.rangeStart,
          rangeEnd: result.rangeEnd,
          window: result.window,
        ),
      ],
    );
  }

  AlarmLevel _level(String name) => AlarmLevel.values.firstWhere(
        (l) => l.name == name,
        orElse: () => AlarmLevel.warning,
      );

  Widget _dot(BuildContext context, String level) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: colorForLevel(context, _level(level)),
          shape: BoxShape.circle,
        ),
      );

  /// Alarm load: how much the operator was interrupted, and by what.
  ///
  /// Only "most frequent". "Longest standing" is the downtime section's
  /// question asked in different words, and printing both put the same alarm
  /// on the screen three times in one report.
  Widget _alarmSummary(BuildContext context, AlarmSummarySectionResult s) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final concluded = result.window?.concludedAt;

    final parts = <String>[
      '${s.totalActivations} activations of ${s.distinctAlarms} alarms',
      '${s.perHour.toStringAsFixed(1)}/h',
      if (s.afterConclusion > 0 && concluded != null)
        '${s.afterConclusion} after '
            '${concluded.hour.toString().padLeft(2, '0')}:'
            '${concluded.minute.toString().padLeft(2, '0')}',
      if (s.openNow > 0) '${s.openNow} still active',
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(context, s.title ?? 'Alarms', s.scope),
        Text(parts.join(' · '), style: theme.textTheme.bodyMedium),
        const SizedBox(height: 12),
        if (s.topByCount.isEmpty)
          Text('No alarms in this range',
              style: theme.textTheme.bodySmall?.copyWith(color: muted))
        else
          for (final a in s.topByCount)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  _dot(context, a.level),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(a.title, overflow: TextOverflow.ellipsis),
                  ),
                  if (a.openNow)
                    Text('active',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(fontSize: 10, color: muted)),
                  const SizedBox(width: 16),
                  SizedBox(
                    width: 48,
                    child: Text('×${a.count}',
                        textAlign: TextAlign.right,
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: muted,
                            fontFeatures: const [
                              FontFeature.tabularFigures()
                            ])),
                  ),
                  const SizedBox(width: 16),
                  SizedBox(
                    width: 80,
                    child: Text(
                      formatSeconds(a.total.inMilliseconds / 1000),
                      textAlign: TextAlign.right,
                      style: theme.textTheme.bodySmall?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }

  /// The downtime pareto: what the stops cost, worst first.
  ///
  /// The share bar is neutral ink, not red. Length already carries the
  /// magnitude, and a row of saturated bars makes an ordinary shift look like
  /// an emergency — red stays reserved for the state colours that mean fault.
  Widget _downtime(BuildContext context, DowntimeSectionResult s) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    var grand = 0;
    for (final a in s.topByDuration) {
      grand += a.total.inMilliseconds;
    }
    final marker =
        result.partial ? 'still standing' : 'standing at conclusion';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(context, s.title ?? 'Downtime', s.scope),
        Text(
          'Down ${formatSeconds(s.totalDown.inMilliseconds / 1000)} · '
          '${(s.fraction * 100).toStringAsFixed(1)}% · ${s.stops} stops',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        if (s.topByDuration.isEmpty)
          Text(
            result.window != null
                ? 'No stops in the production window'
                : 'No stops in this range',
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          )
        else
          for (var i = 0; i < s.topByDuration.length; i++)
            _paretoRow(context, s.topByDuration[i], i + 1, grand, marker),
      ],
    );
  }

  Widget _paretoRow(BuildContext context, AlarmStat a, int rank, int grand,
      String marker) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final share = grand == 0 ? 0.0 : a.total.inMilliseconds / grand;
    final tabular = theme.textTheme.bodySmall
        ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 20,
            child: Text('$rank',
                textAlign: TextAlign.right,
                style: tabular?.copyWith(color: muted)),
          ),
          const SizedBox(width: 10),
          _dot(context, a.level),
          const SizedBox(width: 10),
          SizedBox(
            width: 200,
            child: Text(a.title, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 44,
            child: Text('×${a.count}',
                textAlign: TextAlign.right,
                style: tabular?.copyWith(color: muted)),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 76,
            child: Text(formatSeconds(a.total.inMilliseconds / 1000),
                textAlign: TextAlign.right, style: tabular),
          ),
          const SizedBox(width: 16),
          Expanded(
            // The track has to stay lighter than the fill, or the bar reads as
            // full width for every row and its length stops carrying the
            // share at all. dividerColor is near-black here, so it cannot be
            // the track.
            child: Container(
              height: 10,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.10),
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: share.clamp(0.0, 1.0),
                child: Container(
                    color: theme.colorScheme.onSurface
                        .withValues(alpha: 0.35)),
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 44,
            child: Text('${(share * 100).round()}%',
                textAlign: TextAlign.right,
                style: tabular?.copyWith(color: muted)),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 150,
            child: Text(a.openNow ? marker : '',
                style: theme.textTheme.labelSmall
                    ?.copyWith(fontSize: 10, color: muted)),
          ),
        ],
      ),
    );
  }

  Widget _sql(BuildContext context, SqlSectionResult s) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    if (s.error != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _heading(context, s.title, s.scope),
          Text('Query failed: ${s.error}',
              style: TextStyle(color: theme.colorScheme.error)),
        ],
      );
    }

    bool numeric(int column) {
      for (final row in s.rows) {
        if (column >= row.length) continue;
        if (double.tryParse(row[column]) == null) return false;
      }
      return s.rows.isNotEmpty;
    }

    final numericColumns = [
      for (var i = 0; i < s.columns.length; i++) numeric(i),
    ];

    Widget cell(String text, int column, {bool header = false}) => Padding(
          padding: EdgeInsets.fromLTRB(column == 0 ? 0 : 12, 8, 0, 8),
          child: Text(
            header ? text.toUpperCase() : text,
            textAlign:
                numericColumns[column] ? TextAlign.right : TextAlign.left,
            style: header
                ? theme.textTheme.labelSmall?.copyWith(
                    fontSize: 10, letterSpacing: 0.6, color: muted)
                : theme.textTheme.bodyMedium?.copyWith(
                    fontFeatures: numericColumns[column]
                        ? const [FontFeature.tabularFigures()]
                        : null),
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(context, s.title, s.scope),
        if (s.rows.isEmpty)
          Text('No rows',
              style: theme.textTheme.bodySmall?.copyWith(color: muted))
        else
          Table(
            columnWidths: {
              for (var i = 0; i < s.columns.length; i++)
                i: const IntrinsicColumnWidth(),
              // The label column absorbs the slack, so the figures stay in a
              // column beside it rather than drifting to the far edge.
              0: const FlexColumnWidth(),
            },
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            border: TableBorder(
                horizontalInside: BorderSide(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.18),
                    width: 1)),
            children: [
              TableRow(children: [
                for (var i = 0; i < s.columns.length; i++)
                  cell(s.columns[i], i, header: true),
              ]),
              for (final row in s.rows)
                TableRow(children: [
                  for (var i = 0; i < s.columns.length; i++)
                    cell(i < row.length ? row[i] : '', i),
                ]),
            ],
          ),
        if (s.truncated)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('Truncated to ${s.rows.length} rows',
                style: theme.textTheme.bodySmall?.copyWith(color: muted)),
          ),
      ],
    );
  }

  Widget _text(BuildContext context, TextSectionResult s) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(context, s.title, null),
        // Around 80 characters. A handover note running the full width of a
        // 1280px screen is one line the eye loses its place in.
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Text(s.text,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.5)),
        ),
      ],
    );
  }
}

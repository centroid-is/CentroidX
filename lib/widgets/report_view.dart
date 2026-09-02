import 'package:cristalyse/cristalyse.dart' as cs;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:tfc_dart/tfc_dart.dart';

import '../theme.dart';
import 'graph.dart';
import 'panes/pane_chrome.dart';

/// Renders one generated [ReportResult].
///
/// Pure over the result — no database, no providers — following the
/// StopTimelineView split so the whole report look is golden-testable from a
/// fixture. The page owns generation; this owns presentation.
class ReportView extends StatelessWidget {
  const ReportView({super.key, required this.result, this.chartTheme});

  final ReportResult result;

  /// Cristalyse theme for chart sections; null keeps the Graph default,
  /// which goldens rely on being deterministic.
  final cs.ChartTheme? chartTheme;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _header(context),
        for (final section in result.sections) ...[
          const SizedBox(height: 16),
          _section(context, section),
        ],
      ],
    );
  }

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    final hmi = theme.extension<HmiStateColors>() ??
        HmiStateColors.solarizedLight;
    final fmt = DateFormat('dd-MM-yyyy HH:mm');
    // The range label (a shift label, "Today", ...) already names the span;
    // spelling the timestamps out again next to it just repeats it longer.
    final range = result.rangeLabel.isNotEmpty
        ? result.rangeLabel
        : '${fmt.format(result.rangeStart)} — ${fmt.format(result.rangeEnd)}';
    return Row(
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
        if (result.partial)
          PaneStatusChip(
            status: PaneStatus(
              label: 'So far',
              color: hmi.grey,
              icon: Icons.hourglass_bottom,
            ),
          ),
      ],
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

  Widget _sectionTitle(BuildContext context, String? title) {
    if (title == null || title.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    );
  }

  Widget _kpi(BuildContext context, KpiSectionResult s) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(context, s.title),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final m in s.metrics)
              Card(
                margin: EdgeInsets.zero,
                child: Container(
                  constraints: const BoxConstraints(minWidth: 148),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(m.label,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                      const SizedBox(height: 4),
                      m.error != null
                          ? Tooltip(
                              message: m.error!,
                              child: Text('—',
                                  style: theme.textTheme.headlineSmall),
                            )
                          : Text(m.formatted,
                              style: theme.textTheme.headlineSmall),
                      const SizedBox(height: 2),
                      Text(m.aggregate.label,
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _table(BuildContext context, TableSectionResult s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(context, s.title),
        Card(
          margin: EdgeInsets.zero,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: [
                const DataColumn(label: Text('')),
                for (final agg in s.aggregates)
                  DataColumn(label: Text(agg.label)),
              ],
              rows: [
                for (final row in s.rows)
                  DataRow(cells: [
                    DataCell(Text(row.label)),
                    for (final cell in row.cells)
                      DataCell(cell.error != null
                          ? Tooltip(
                              message: cell.error!, child: const Text('—'))
                          : Text(cell.formatted)),
                  ]),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _sql(BuildContext context, SqlSectionResult s) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(context, s.title),
        Card(
          margin: EdgeInsets.zero,
          child: s.error != null
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('Query failed: ${s.error}',
                      style: TextStyle(color: theme.colorScheme.error)),
                )
              : s.rows.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('No rows',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: DataTable(
                            columns: [
                              for (final c in s.columns)
                                DataColumn(label: Text(c)),
                            ],
                            rows: [
                              for (final row in s.rows)
                                DataRow(cells: [
                                  for (final cell in row)
                                    DataCell(Text(cell)),
                                ]),
                            ],
                          ),
                        ),
                        if (s.truncated)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                            child: Text('Truncated to ${s.rows.length} rows',
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color:
                                        theme.colorScheme.onSurfaceVariant)),
                          ),
                      ],
                    ),
        ),
      ],
    );
  }

  Widget _chart(BuildContext context, ChartSectionResult s) {
    final theme = Theme.of(context);
    final data = <Map<String, dynamic>>[];
    for (final series in s.series) {
      for (final p in series.points) {
        data.add({
          'x': p.time.millisecondsSinceEpoch.toDouble(),
          'y': p.avg,
          's': series.label,
        });
      }
    }
    if (data.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(context, s.title),
          Card(
            margin: EdgeInsets.zero,
            child: SizedBox(
              height: 120,
              child: Center(
                child: Text('No data in range',
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ),
            ),
          ),
        ],
      );
    }

    final graph = Graph(
      config: GraphConfig(
        type: GraphType.timeseries,
        xAxis: const GraphAxisConfig(unit: ''),
        yAxis: const GraphAxisConfig(unit: ''),
        xRange: DateTimeRange(start: result.rangeStart, end: result.rangeEnd),
        pan: false,
        zoom: false,
      ),
      data: data,
      // Without a themed fallback cristalyse's default axis text has no font
      // family, which goldens render as solid boxes.
      chartTheme: chartTheme ??
          (theme.brightness == Brightness.dark
              ? darkChartTheme()
              : lightChartTheme()),
      showButtons: false,
      // Static data: nothing arrives later, so nothing ever asks to redraw.
      redraw: () {},
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(context, s.title),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: SizedBox(
              height: 260,
              child: Builder(builder: graph.build),
            ),
          ),
        ),
      ],
    );
  }

  Widget _alarmTable(BuildContext context, String caption, List<AlarmStat> stats) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(caption,
              style: theme.textTheme.labelLarge
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          for (final a in stats)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      a.title + (a.openNow ? ' (active)' : ''),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text('×${a.count}',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                  const SizedBox(width: 12),
                  Text(formatSeconds(a.total.inMilliseconds / 1000),
                      style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          if (stats.isEmpty)
            Text('None',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _alarmSummary(BuildContext context, AlarmSummarySectionResult s) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(context, s.title ?? 'Alarms'),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${s.totalActivations} activations of ${s.distinctAlarms} '
                  'alarms · ${s.perHour.toStringAsFixed(1)}/h'
                  '${s.openNow > 0 ? ' · ${s.openNow} still active' : ''}',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _alarmTable(context, 'Most frequent', s.topByCount),
                    const SizedBox(width: 24),
                    _alarmTable(
                        context, 'Longest standing', s.topByDuration),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _downtime(BuildContext context, DowntimeSectionResult s) {
    final theme = Theme.of(context);
    final hmi =
        theme.extension<HmiStateColors>() ?? HmiStateColors.solarizedLight;
    final top = s.topByDuration.isEmpty
        ? const Duration(seconds: 1)
        : s.topByDuration.first.total;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(context, s.title ?? 'Downtime'),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Down ${formatSeconds(s.totalDown.inMilliseconds / 1000)} · '
                  '${(s.fraction * 100).toStringAsFixed(1)}% of range · '
                  '${s.stops} stops'
                  '${s.openNow ? ' · one still standing' : ''}',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                for (final a in s.topByDuration)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 220,
                          child: Text(
                            a.title + (a.openNow ? ' (active)' : ''),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Expanded(
                          child: FractionallySizedBox(
                            alignment: Alignment.centerLeft,
                            widthFactor: top.inMicroseconds == 0
                                ? 0
                                : (a.total.inMicroseconds /
                                        top.inMicroseconds)
                                    .clamp(0.02, 1.0),
                            child: Container(
                              height: 14,
                              decoration: BoxDecoration(
                                color: hmi.red.withValues(alpha: 0.45),
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 96,
                          child: Text(
                            '${formatSeconds(a.total.inMilliseconds / 1000)}'
                            ' ×${a.count}',
                            textAlign: TextAlign.right,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (s.topByDuration.isEmpty)
                  Text('No stops in range',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _text(BuildContext context, TextSectionResult s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(context, s.title),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(s.text),
          ),
        ),
      ],
    );
  }
}

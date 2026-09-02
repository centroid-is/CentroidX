import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_dart/tfc_dart.dart';

import '../providers/report.dart';
import '../providers/state_man.dart';
import '../widgets/base_scaffold.dart';

/// Configures the shift calendar and the report definitions.
///
/// Buffered like Server Config: edits accumulate in local copies, the JSON
/// diff drives the unsaved marker, and Save writes both blobs through the
/// [ReportStore] then invalidates the viewer's providers.
class ReportEditorPage extends ConsumerStatefulWidget {
  const ReportEditorPage({super.key});

  @override
  ConsumerState<ReportEditorPage> createState() => _ReportEditorPageState();
}

class _ReportEditorPageState extends ConsumerState<ReportEditorPage> {
  ShiftManConfig? _shifts;
  ShiftManConfig? _savedShifts;
  ReportManConfig? _reports;
  ReportManConfig? _savedReports;
  String? _error;
  bool _saving = false;

  bool get _hasUnsavedChanges {
    if (_shifts == null || _reports == null) return false;
    return jsonEncode(_shifts!.toJson()) != jsonEncode(_savedShifts!.toJson()) ||
        jsonEncode(_reports!.toJson()) != jsonEncode(_savedReports!.toJson());
  }

  Future<void> _load(ReportStore store) async {
    try {
      final shifts = await store.loadShifts();
      final reports = await store.loadReports();
      if (!mounted) return;
      setState(() {
        _shifts = shifts;
        _savedShifts = ShiftManConfig.fromJson(shifts.toJson());
        _reports = reports;
        _savedReports = ReportManConfig.fromJson(reports.toJson());
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Failed to load: $e');
    }
  }

  Future<void> _save(ReportStore store) async {
    setState(() => _saving = true);
    try {
      await store.saveShifts(_shifts!);
      await store.saveReports(_reports!);
      if (!mounted) return;
      setState(() {
        _savedShifts = ShiftManConfig.fromJson(_shifts!.toJson());
        _savedReports = ReportManConfig.fromJson(_reports!.toJson());
        _saving = false;
        _error = null;
      });
      ref.invalidate(reportManConfigProvider);
      ref.invalidate(shiftCalendarProvider);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Failed to save: $e';
      });
    }
  }

  /// Collected keys — the only keys a report can chart or aggregate, since
  /// only they have timeseries tables behind them.
  List<String> get _collectedKeys {
    final nodes =
        ref.watch(stateManProvider).valueOrNull?.keyMappings.nodes ?? const {};
    final keys = [
      for (final entry in nodes.entries)
        if (entry.value.collect != null) entry.key,
    ]..sort();
    return keys;
  }

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(reportStoreProvider);
    if (store != null && _shifts == null && _error == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load(store));
    }

    final theme = Theme.of(context);
    final body = store == null
        ? const Center(child: Text('Database is not connected.'))
        : _shifts == null
            ? _error != null
                ? Center(
                    child: Text(_error!,
                        style: TextStyle(color: theme.colorScheme.error)))
                : const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        _shiftsCard(context),
                        const SizedBox(height: 16),
                        _reportsCard(context),
                      ],
                    ),
                  ),
                  Material(
                    elevation: 8,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      child: Row(
                        children: [
                          if (_error != null)
                            Expanded(
                              child: Text(_error!,
                                  style: TextStyle(
                                      color: theme.colorScheme.error)),
                            )
                          else if (_hasUnsavedChanges)
                            Expanded(
                              child: Text('Unsaved changes',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                      color:
                                          theme.colorScheme.onSurfaceVariant)),
                            )
                          else
                            const Spacer(),
                          FilledButton.icon(
                            onPressed: _hasUnsavedChanges && !_saving
                                ? () => _save(store)
                                : null,
                            icon: const Icon(Icons.save),
                            label: const Text('Save'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );

    return BaseScaffold(title: 'Report Editor', body: body);
  }

  // ------------------------------------------------------------------ shifts

  Widget _shiftsCard(BuildContext context) {
    final theme = Theme.of(context);
    final shifts = _shifts!.shifts;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Shift calendar', style: theme.textTheme.titleMedium),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => setState(() {
                    shifts.add(ShiftDef(
                        name: 'Shift ${shifts.length + 1}',
                        startMinutes: 7 * 60,
                        durationMinutes: 8 * 60));
                  }),
                  icon: const Icon(Icons.add),
                  label: const Text('Add shift'),
                ),
              ],
            ),
            if (shifts.isEmpty)
              Text(
                'No shifts defined. Shift-based reports fall back to whole '
                'days until a pattern exists.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            for (var i = 0; i < shifts.length; i++)
              _shiftRow(context, shifts, i),
          ],
        ),
      ),
    );
  }

  Widget _shiftRow(BuildContext context, List<ShiftDef> shifts, int index) {
    final shift = shifts[index];
    String two(int n) => n.toString().padLeft(2, '0');
    final start = TimeOfDay(
        hour: shift.startMinutes ~/ 60, minute: shift.startMinutes % 60);
    final end = shift.startMinutes + shift.durationMinutes;

    return Padding(
      key: ValueKey('shift-$index'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 8,
        children: [
          SizedBox(
            width: 180,
            child: TextFormField(
              key: ValueKey('shift-name-$index-${shift.name.hashCode}'),
              initialValue: shift.name,
              decoration: const InputDecoration(
                  labelText: 'Name', isDense: true),
              onChanged: (v) => setState(() => shift.name = v),
            ),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.schedule, size: 18),
            label: Text('Starts ${two(start.hour)}:${two(start.minute)}'),
            onPressed: () async {
              final picked =
                  await showTimePicker(context: context, initialTime: start);
              if (picked != null) {
                setState(() =>
                    shift.startMinutes = picked.hour * 60 + picked.minute);
              }
            },
          ),
          SizedBox(
            width: 110,
            child: TextFormField(
              key: ValueKey('shift-dur-$index'),
              initialValue: '${shift.durationMinutes ~/ 60}',
              decoration: const InputDecoration(
                  labelText: 'Hours', isDense: true),
              keyboardType: TextInputType.number,
              onChanged: (v) {
                final hours = double.tryParse(v);
                if (hours != null && hours > 0 && hours <= 24) {
                  setState(
                      () => shift.durationMinutes = (hours * 60).round());
                }
              },
            ),
          ),
          Text(
            'ends ${two((end ~/ 60) % 24)}:${two(end % 60)}'
            '${end >= 24 * 60 ? ' (+1d)' : ''}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          Wrap(
            spacing: 4,
            children: [
              for (var d = DateTime.monday; d <= DateTime.sunday; d++)
                FilterChip(
                  label: Text(
                      const ['M', 'T', 'W', 'T', 'F', 'S', 'S'][d - 1]),
                  visualDensity: VisualDensity.compact,
                  selected: shift.weekdays.contains(d),
                  onSelected: (on) => setState(() {
                    on ? shift.weekdays.add(d) : shift.weekdays.remove(d);
                    shift.weekdays.sort();
                  }),
                ),
            ],
          ),
          IconButton(
            tooltip: 'Remove shift',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => setState(() => shifts.removeAt(index)),
          ),
        ],
      ),
    );
  }

  // ----------------------------------------------------------------- reports

  Widget _reportsCard(BuildContext context) {
    final theme = Theme.of(context);
    final reports = _reports!.reports;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Reports', style: theme.textTheme.titleMedium),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => setState(() {
                    reports.add(ReportConfig(
                      id: 'report-${DateTime.now().millisecondsSinceEpoch}',
                      name: 'New report',
                      sections: [KpiSectionConfig()],
                    ));
                  }),
                  icon: const Icon(Icons.add),
                  label: const Text('Add report'),
                ),
              ],
            ),
            for (var i = 0; i < reports.length; i++)
              _reportTile(context, reports, i),
          ],
        ),
      ),
    );
  }

  Widget _reportTile(
      BuildContext context, List<ReportConfig> reports, int index) {
    final report = reports[index];
    return ExpansionTile(
      // A PageStorageKey here stores the expanded bool in a bucket the inner
      // text fields' scrollables then read back as a scroll offset — a
      // double cast on a bool. Plain key, no persisted expansion.
      key: ValueKey('report-tile-${report.id}'),
      title: Text(report.name),
      subtitle: Text('${report.range.name} · '
          '${report.sections.length} sections'),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 220,
              child: TextFormField(
                key: ValueKey('report-name-${report.id}'),
                initialValue: report.name,
                decoration:
                    const InputDecoration(labelText: 'Name', isDense: true),
                onChanged: (v) => setState(() => report.name = v),
              ),
            ),
            SizedBox(
              width: 320,
              child: TextFormField(
                key: ValueKey('report-desc-${report.id}'),
                initialValue: report.description ?? '',
                decoration: const InputDecoration(
                    labelText: 'Description', isDense: true),
                onChanged: (v) =>
                    setState(() => report.description = v.isEmpty ? null : v),
              ),
            ),
            DropdownButton<ReportRangeKind>(
              value: report.range,
              items: [
                for (final kind in ReportRangeKind.values)
                  DropdownMenuItem(
                      value: kind, child: Text('Per ${kind.name}')),
              ],
              onChanged: (kind) =>
                  setState(() => report.range = kind ?? report.range),
            ),
            IconButton(
              tooltip: 'Duplicate report',
              icon: const Icon(Icons.copy),
              onPressed: () => setState(() {
                final copy = ReportConfig.fromJson(report.toJson())
                  ..id = 'report-${DateTime.now().millisecondsSinceEpoch}'
                  ..name = '${report.name} (copy)';
                reports.insert(index + 1, copy);
              }),
            ),
            IconButton(
              tooltip: 'Delete report',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => setState(() => reports.removeAt(index)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (var s = 0; s < report.sections.length; s++)
          _sectionCard(context, report, s),
        Align(
          alignment: Alignment.centerLeft,
          child: PopupMenuButton<String>(
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add),
                  SizedBox(width: 4),
                  Text('Add section'),
                ],
              ),
            ),
            onSelected: (type) => setState(() {
              report.sections.add(switch (type) {
                KpiSectionConfig.kType => KpiSectionConfig(),
                TableSectionConfig.kType => TableSectionConfig(),
                ChartSectionConfig.kType => ChartSectionConfig(),
                AlarmSummarySectionConfig.kType =>
                  AlarmSummarySectionConfig(),
                DowntimeSectionConfig.kType => DowntimeSectionConfig(),
                _ => TextSectionConfig(),
              });
            }),
            itemBuilder: (context) => const [
              PopupMenuItem(
                  value: KpiSectionConfig.kType, child: Text('KPI row')),
              PopupMenuItem(
                  value: TableSectionConfig.kType, child: Text('Table')),
              PopupMenuItem(
                  value: ChartSectionConfig.kType, child: Text('Chart')),
              PopupMenuItem(
                  value: AlarmSummarySectionConfig.kType,
                  child: Text('Alarm summary')),
              PopupMenuItem(
                  value: DowntimeSectionConfig.kType,
                  child: Text('Downtime')),
              PopupMenuItem(
                  value: TextSectionConfig.kType, child: Text('Text')),
            ],
          ),
        ),
      ],
    );
  }

  static String _sectionLabel(ReportSectionConfig s) => switch (s) {
        KpiSectionConfig() => 'KPI row',
        TableSectionConfig() => 'Table',
        ChartSectionConfig() => 'Chart',
        AlarmSummarySectionConfig() => 'Alarm summary',
        DowntimeSectionConfig() => 'Downtime',
        TextSectionConfig() => 'Text',
      };

  Widget _sectionCard(BuildContext context, ReportConfig report, int index) {
    final theme = Theme.of(context);
    final section = report.sections[index];
    return Card(
      key: ValueKey('section-${report.id}-$index'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(_sectionLabel(section),
                    style: theme.textTheme.labelLarge),
                const SizedBox(width: 16),
                Expanded(
                  child: TextFormField(
                    key: ValueKey('section-title-${report.id}-$index'),
                    initialValue: section.title ?? '',
                    decoration: const InputDecoration(
                        labelText: 'Title (optional)', isDense: true),
                    onChanged: (v) =>
                        setState(() => section.title = v.isEmpty ? null : v),
                  ),
                ),
                IconButton(
                  tooltip: 'Move up',
                  icon: const Icon(Icons.arrow_upward, size: 18),
                  onPressed: index == 0
                      ? null
                      : () => setState(() {
                            report.sections.insert(
                                index - 1, report.sections.removeAt(index));
                          }),
                ),
                IconButton(
                  tooltip: 'Move down',
                  icon: const Icon(Icons.arrow_downward, size: 18),
                  onPressed: index == report.sections.length - 1
                      ? null
                      : () => setState(() {
                            report.sections.insert(
                                index + 1, report.sections.removeAt(index));
                          }),
                ),
                IconButton(
                  tooltip: 'Remove section',
                  icon: const Icon(Icons.delete_outline, size: 18),
                  onPressed: () =>
                      setState(() => report.sections.removeAt(index)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _sectionBody(context, report, index, section),
          ],
        ),
      ),
    );
  }

  Widget _sectionBody(BuildContext context, ReportConfig report, int index,
      ReportSectionConfig section) {
    switch (section) {
      case KpiSectionConfig s:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < s.metrics.length; i++)
              _metricRow(context, report, index, s.metrics, i),
            TextButton.icon(
              onPressed: () => setState(() => s.metrics.add(
                  ReportMetricConfig(key: _collectedKeys.firstOrNull ?? ''))),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add metric'),
            ),
          ],
        );
      case TableSectionConfig s:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 4,
              children: [
                for (final agg in ReportAggregate.values)
                  FilterChip(
                    label: Text(agg.label),
                    visualDensity: VisualDensity.compact,
                    selected: s.aggregates.contains(agg),
                    onSelected: (on) => setState(() {
                      on ? s.aggregates.add(agg) : s.aggregates.remove(agg);
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < s.rows.length; i++)
              _tableRowEditor(context, report, index, s.rows, i),
            TextButton.icon(
              onPressed: () => setState(() => s.rows.add(
                  TableRowConfig(key: _collectedKeys.firstOrNull ?? ''))),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add row'),
            ),
          ],
        );
      case ChartSectionConfig s:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < s.series.length; i++)
              _seriesRow(context, report, index, s.series, i),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () => setState(() => s.series.add(
                      ReportChartSeriesConfig(
                          key: _collectedKeys.firstOrNull ?? ''))),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add series'),
                ),
                const SizedBox(width: 16),
                SizedBox(
                  width: 120,
                  child: TextFormField(
                    key: ValueKey('chart-points-${report.id}-$index'),
                    initialValue: '${s.maxPoints}',
                    decoration: const InputDecoration(
                        labelText: 'Max points', isDense: true),
                    keyboardType: TextInputType.number,
                    onChanged: (v) {
                      final n = int.tryParse(v);
                      if (n != null && n > 0 && n <= 2000) {
                        setState(() => s.maxPoints = n);
                      }
                    },
                  ),
                ),
              ],
            ),
          ],
        );
      case AlarmSummarySectionConfig s:
        return _topNField(report, index, s.topN, (n) => s.topN = n);
      case DowntimeSectionConfig s:
        return _topNField(report, index, s.topN, (n) => s.topN = n);
      case TextSectionConfig s:
        return TextFormField(
          key: ValueKey('text-${report.id}-$index'),
          initialValue: s.text,
          decoration:
              const InputDecoration(labelText: 'Text', isDense: true),
          maxLines: 4,
          minLines: 2,
          onChanged: (v) => setState(() => s.text = v),
        );
    }
  }

  Widget _topNField(
      ReportConfig report, int index, int value, void Function(int) set) {
    return Align(
      alignment: Alignment.centerLeft,
      child: SizedBox(
        width: 120,
        child: TextFormField(
          key: ValueKey('topn-${report.id}-$index'),
          initialValue: '$value',
          decoration:
              const InputDecoration(labelText: 'Top N', isDense: true),
          keyboardType: TextInputType.number,
          onChanged: (v) {
            final n = int.tryParse(v);
            if (n != null && n > 0 && n <= 50) setState(() => set(n));
          },
        ),
      ),
    );
  }

  /// A key field with fuzzy suggestions over the collected keys. Free text is
  /// allowed — a key can be configured before its collection is.
  Widget _keyField(String id, String value, void Function(String) onChanged) {
    return SizedBox(
      width: 280,
      child: RawAutocomplete<String>(
        key: ValueKey(id),
        initialValue: TextEditingValue(text: value),
        optionsBuilder: (text) {
          if (text.text.isEmpty) return _collectedKeys.take(20);
          final q = text.text.toLowerCase();
          return _collectedKeys
              .where((k) => k.toLowerCase().contains(q))
              .take(20);
        },
        onSelected: (v) => setState(() => onChanged(v)),
        fieldViewBuilder: (context, controller, focusNode, onSubmitted) =>
            TextFormField(
          controller: controller,
          focusNode: focusNode,
          decoration:
              const InputDecoration(labelText: 'Key', isDense: true),
          onChanged: (v) => setState(() => onChanged(v)),
        ),
        optionsViewBuilder: (context, onSelected, options) => Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            child: ConstrainedBox(
              constraints:
                  const BoxConstraints(maxHeight: 240, maxWidth: 400),
              child: ListView(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                children: [
                  for (final o in options)
                    ListTile(
                      dense: true,
                      title: Text(o),
                      onTap: () => onSelected(o),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _smallField(String id, String label, String value, double width,
      void Function(String) onChanged) {
    return SizedBox(
      width: width,
      child: TextFormField(
        key: ValueKey(id),
        initialValue: value,
        decoration: InputDecoration(labelText: label, isDense: true),
        onChanged: (v) => setState(() => onChanged(v)),
      ),
    );
  }

  Widget _metricRow(BuildContext context, ReportConfig report,
      int sectionIndex, List<ReportMetricConfig> metrics, int i) {
    final m = metrics[i];
    final id = '${report.id}-$sectionIndex-metric-$i';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _keyField('$id-key', m.key, (v) => m.key = v),
          _smallField('$id-member', 'Member', m.member ?? '', 150,
              (v) => m.member = v.isEmpty ? null : v),
          _smallField('$id-label', 'Label', m.label ?? '', 150,
              (v) => m.label = v.isEmpty ? null : v),
          DropdownButton<ReportAggregate>(
            value: m.aggregate,
            isDense: true,
            items: [
              for (final agg in ReportAggregate.values)
                DropdownMenuItem(value: agg, child: Text(agg.label)),
            ],
            onChanged: (agg) =>
                setState(() => m.aggregate = agg ?? m.aggregate),
          ),
          _smallField('$id-unit', 'Unit', m.unit ?? '', 80,
              (v) => m.unit = v.isEmpty ? null : v),
          _smallField('$id-dec', 'Dec', '${m.decimals}', 60, (v) {
            final n = int.tryParse(v);
            if (n != null && n >= 0 && n <= 6) m.decimals = n;
          }),
          IconButton(
            tooltip: 'Remove metric',
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => setState(() => metrics.removeAt(i)),
          ),
        ],
      ),
    );
  }

  Widget _tableRowEditor(BuildContext context, ReportConfig report,
      int sectionIndex, List<TableRowConfig> rows, int i) {
    final row = rows[i];
    final id = '${report.id}-$sectionIndex-row-$i';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _keyField('$id-key', row.key, (v) => row.key = v),
          _smallField('$id-member', 'Member', row.member ?? '', 150,
              (v) => row.member = v.isEmpty ? null : v),
          _smallField('$id-label', 'Label', row.label ?? '', 150,
              (v) => row.label = v.isEmpty ? null : v),
          _smallField('$id-unit', 'Unit', row.unit ?? '', 80,
              (v) => row.unit = v.isEmpty ? null : v),
          _smallField('$id-dec', 'Dec', '${row.decimals}', 60, (v) {
            final n = int.tryParse(v);
            if (n != null && n >= 0 && n <= 6) row.decimals = n;
          }),
          IconButton(
            tooltip: 'Remove row',
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => setState(() => rows.removeAt(i)),
          ),
        ],
      ),
    );
  }

  Widget _seriesRow(BuildContext context, ReportConfig report,
      int sectionIndex, List<ReportChartSeriesConfig> series, int i) {
    final s = series[i];
    final id = '${report.id}-$sectionIndex-series-$i';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _keyField('$id-key', s.key, (v) => s.key = v),
          _smallField('$id-member', 'Member', s.member ?? '', 150,
              (v) => s.member = v.isEmpty ? null : v),
          _smallField('$id-label', 'Label', s.label ?? '', 150,
              (v) => s.label = v.isEmpty ? null : v),
          IconButton(
            tooltip: 'Remove series',
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => setState(() => series.removeAt(i)),
          ),
        ],
      ),
    );
  }
}

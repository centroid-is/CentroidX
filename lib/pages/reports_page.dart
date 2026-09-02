import 'package:beamer/beamer.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:tfc_dart/tfc_dart.dart';

import '../providers/alarm.dart';
import '../providers/report.dart';
import '../routes.dart';
import '../widgets/base_scaffold.dart';
import '../widgets/graph.dart';
import '../widgets/report_view.dart';

/// The report viewer: pick a report, walk shifts (or days/weeks) backwards
/// and forwards, and read the generated result. Generation happens on every
/// selection change; Refresh re-generates, which is how a "current shift so
/// far" report is brought up to date.
class ReportsPage extends ConsumerStatefulWidget {
  const ReportsPage({super.key, this.debugClock});

  /// Fixed clock for tests; null uses the wall clock.
  final DateTime? debugClock;

  @override
  ConsumerState<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends ConsumerState<ReportsPage> {
  String? _reportId;

  /// 0 is the current period, -1 the one before, and so on.
  int _offset = 0;

  ReportResult? _result;
  bool _generating = false;
  String? _error;

  /// Monotonic guard: a slow generate finishing after the operator has
  /// already navigated elsewhere must not overwrite the newer result.
  int _generation = 0;

  DateTime get _now => widget.debugClock ?? DateTime.now();

  /// The concrete range for [_offset] under [report]'s range kind, plus its
  /// label. Null when nothing is resolvable (shift kind, empty calendar —
  /// the caller falls back to day).
  (DateTime, DateTime, String)? _resolveRange(
      ReportConfig report, ShiftCalendar calendar) {
    final now = _now;
    switch (report.range) {
      case ReportRangeKind.shift:
        final shift = calendar.byOffset(now, _offset);
        if (shift == null) return null;
        return (shift.start, shift.end, shift.label);
      case ReportRangeKind.day:
        final day = DateTime(now.year, now.month, now.day + _offset);
        final label = _offset == 0
            ? 'Today'
            : _offset == -1
                ? 'Yesterday'
                : DateFormat('EEE dd-MM-yyyy').format(day);
        return (day, DateTime(day.year, day.month, day.day + 1), label);
      case ReportRangeKind.week:
        final monday = DateTime(
            now.year, now.month, now.day - (now.weekday - 1) + 7 * _offset);
        final label =
            'Week of ${DateFormat('dd-MM-yyyy').format(monday)}';
        return (
          monday,
          DateTime(monday.year, monday.month, monday.day + 7),
          label
        );
    }
  }

  Future<void> _generate() async {
    final gen = ++_generation;
    final reports = ref.read(reportManConfigProvider).valueOrNull;
    final calendar = ref.read(shiftCalendarProvider).valueOrNull;
    final engine = ref.read(reportEngineProvider);
    final store = ref.read(reportStoreProvider);
    if (reports == null || calendar == null) return;
    if (engine == null || store == null) {
      setState(() => _error = 'Database is not connected.');
      return;
    }
    final report = reports.reports
        .where((r) => r.id == _reportId)
        .firstOrNull;
    if (report == null) return;

    var resolved = _resolveRange(report, calendar);
    var shiftFallback = false;
    if (resolved == null) {
      // Shift report without a configured calendar: day arithmetic keeps the
      // page useful, and the banner below says why.
      shiftFallback = true;
      final now = _now;
      final day = DateTime(now.year, now.month, now.day + _offset);
      resolved = (
        day,
        DateTime(day.year, day.month, day.day + 1),
        _offset == 0 ? 'Today' : DateFormat('EEE dd-MM-yyyy').format(day)
      );
    }
    final (start, end, label) = resolved;

    setState(() {
      _generating = true;
      _error = null;
      _shiftFallback = shiftFallback;
    });

    try {
      // The live active set fills the open-interval gap alarm_history has by
      // design. An unavailable AlarmMan (no PLC connection) degrades to
      // closed activations only.
      var active = const <OpenAlarm>[];
      try {
        final alarmMan = ref.read(alarmManProvider).valueOrNull;
        if (alarmMan != null) {
          final current = await alarmMan
              .activeAlarms()
              .first
              .timeout(const Duration(seconds: 2));
          active = [
            for (final a in current)
              OpenAlarm(
                uid: a.alarm.config.uid,
                title: a.alarm.config.title,
                level: a.notification.rule.level.name,
                start: a.notification.timestamp,
              ),
          ];
        }
      } catch (_) {
        // Degrade silently; the report still covers everything that cleared.
      }

      final result = await engine.generate(
        report,
        rangeStart: start,
        rangeEnd: end,
        rangeLabel: label,
        now: _now,
        activeAlarms: active,
        alarmMeta: await store.loadAlarmMeta(),
      );
      if (!mounted || gen != _generation) return;
      setState(() {
        _result = result;
        _generating = false;
      });
    } catch (e) {
      if (!mounted || gen != _generation) return;
      setState(() {
        _error = 'Failed to generate: $e';
        _generating = false;
      });
    }
  }

  bool _shiftFallback = false;

  void _select(String? reportId, {int? offset}) {
    setState(() {
      _reportId = reportId;
      if (offset != null) _offset = offset;
    });
    _generate();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reportsAsync = ref.watch(reportManConfigProvider);
    // Watched so a calendar edit re-resolves the ranges on next generate.
    ref.watch(shiftCalendarProvider);

    final reports = reportsAsync.valueOrNull?.reports ?? const [];
    if (_reportId == null && reports.isNotEmpty) {
      _reportId = reports.first.id;
      WidgetsBinding.instance.addPostFrameCallback((_) => _generate());
    }

    return BaseScaffold(
      title: 'Reports',
      body: reports.isEmpty
          ? _empty(context, reportsAsync)
          : Column(
              key: const ValueKey('reports-body'),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Row(
                    children: [
                      DropdownButton<String>(
                        value: _reportId,
                        items: [
                          for (final r in reports)
                            DropdownMenuItem(
                                value: r.id, child: Text(r.name)),
                        ],
                        onChanged: (id) => _select(id, offset: 0),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Previous',
                        icon: const Icon(Icons.chevron_left),
                        onPressed: () => _select(_reportId,
                            offset: _offset - 1),
                      ),
                      IconButton(
                        tooltip: 'Next',
                        icon: const Icon(Icons.chevron_right),
                        onPressed: _offset >= 0
                            ? null
                            : () =>
                                _select(_reportId, offset: _offset + 1),
                      ),
                      TextButton(
                        onPressed: _offset == 0 && _result != null
                            ? null
                            : () => _select(_reportId, offset: 0),
                        child: const Text('Current'),
                      ),
                      IconButton(
                        tooltip: 'Refresh',
                        icon: const Icon(Icons.refresh),
                        onPressed: _generate,
                      ),
                      IconButton(
                        tooltip: 'Configure reports',
                        icon: const Icon(Icons.edit),
                        onPressed: () =>
                            Beamer.of(context).beamToNamed(AppRoutes.reportEditor),
                      ),
                    ],
                  ),
                ),
                if (_shiftFallback)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Row(
                      children: [
                        Icon(Icons.info_outline,
                            size: 16,
                            color: theme.colorScheme.onSurfaceVariant),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'No shifts configured — showing whole days. '
                            'Define shifts in the report editor.',
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(_error!,
                        style: TextStyle(color: theme.colorScheme.error)),
                  ),
                Expanded(
                  child: _generating && _result == null
                      ? const Center(child: CircularProgressIndicator())
                      : _result == null
                          ? const SizedBox.shrink()
                          : Stack(
                              children: [
                                ReportView(
                                  result: _result!,
                                  chartTheme: ref
                                      .watch(chartThemeNotifierProvider),
                                ),
                                if (_generating)
                                  const Positioned(
                                    top: 8,
                                    right: 8,
                                    child: SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    ),
                                  ),
                              ],
                            ),
                ),
              ],
            ),
    );
  }

  Widget _empty(BuildContext context, AsyncValue<ReportManConfig> async) {
    final theme = Theme.of(context);
    if (async.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    return Center(
      key: const ValueKey('reports-empty'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.summarize_outlined,
              size: 48, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text('No reports defined yet', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('Create one in the report editor.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () =>
                Beamer.of(context).beamToNamed(AppRoutes.reportEditor),
            icon: const Icon(Icons.edit),
            label: const Text('Open report editor'),
          ),
        ],
      ),
    );
  }
}

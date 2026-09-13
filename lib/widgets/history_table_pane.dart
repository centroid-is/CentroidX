import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rxdart/rxdart.dart';
import 'package:tfc_dart/core/collector.dart';
import 'package:tfc_dart/core/database.dart';

import '../page_creator/assets/graph.dart' show describeTrendFetchError;
import '../providers/collector.dart';
import '../models/history_models.dart';

// -----------------------------------------------------------------------------
// Table pane – merges selected keys by nearest timestamp
// -----------------------------------------------------------------------------
class HistoryTablePane extends ConsumerStatefulWidget {
  final List<String> keys;
  final bool realtime;
  final DateTimeRange? range;
  final Duration realtimeDuration;
  final int rows;
  final Map<String, GraphKeyConfig> graphConfigs;

  const HistoryTablePane({
    super.key,
    required this.keys,
    required this.realtime,
    required this.range,
    required this.realtimeDuration,
    required this.graphConfigs,
    this.rows = 50,
  });

  @override
  ConsumerState<HistoryTablePane> createState() => _HistoryTablePaneState();
}

enum _TableSortOrder { newestFirst, oldestFirst }

class _HistoryTablePaneState extends ConsumerState<HistoryTablePane> {
  _TableSortOrder _sortOrder = _TableSortOrder.newestFirst;

  /// True when the visible rows cross a calendar-day boundary, so the
  /// Timestamp column must carry the date — HH:mm:ss alone made a multi-day
  /// range unreadable (every midnight looked like a rewind).
  bool _showDates = false;

  // Cache processed data to avoid recalculation
  List<Map<String, dynamic>>? _cachedTableRows;
  List<List<TimeseriesData<dynamic>>>? _lastProcessedData;
  int _lastDataHash = 0;

  // Debounce updates to reduce frequency
  Timer? _updateTimer;

  /// The merged history stream, kept across rebuilds.
  ///
  /// Building it issues a `queryTimeseriesData` and hands `StreamBuilder` a
  /// stream object it has never seen, so it resubscribes and falls back to its
  /// spinner. Doing that from `build` meant every unrelated rebuild — a sort
  /// toggle, a parent resizing — re-ran the query and blanked the table.
  Stream<List<List<TimeseriesData<dynamic>>>>? _dataStream;

  /// The inputs [_dataStream] was built from; a change here, and only here,
  /// earns a new query.
  String? _dataStreamKey;

  @override
  void dispose() {
    _updateTimer?.cancel();
    super.dispose();
  }

  Stream<List<List<TimeseriesData<dynamic>>>> _streamFor(Collector collector) {
    final key = [
      identityHashCode(collector),
      widget.realtime,
      widget.realtimeDuration.inMilliseconds,
      widget.range?.start.toIso8601String(),
      widget.range?.end.toIso8601String(),
      widget.keys.join(','),
    ].join('|');
    final cached = _dataStream;
    if (cached != null && _dataStreamKey == key) return cached;

    Duration since;
    DateTimeRange? fetchRange; // Extended range for fetching

    if (widget.realtime) {
      since = widget.realtimeDuration;
    } else {
      since = DateTime.now().difference(widget.range!.start);

      // Calculate extended range: 50% more on each side
      final rangeDuration = widget.range!.end.difference(widget.range!.start);
      final extension = Duration(
        milliseconds: (rangeDuration.inMilliseconds * 0.5).round(),
      );

      fetchRange = DateTimeRange(
        start: widget.range!.start.subtract(extension),
        end: widget.range!.end.add(extension),
      );
    }

    final streams = widget.keys.map((k) {
      if (widget.realtime) {
        final liveStream = collector.collectStream(k, since: since);
        final cutoff = DateTime.now().toUtc().subtract(since);
        final dbStream = Stream.fromFuture(
          collector.database
              .queryTimeseriesData(k, DateTime.now().toUtc(), from: cutoff)
              // See the same guard in history_graph_pane: `combineLatest2`
              // emits nothing until every source has, so an erroring
              // backfill takes the live stream beside it down with it.
              .catchError((Object e) => <TimeseriesData<dynamic>>[]),
        );
        return Rx.combineLatest2<List<TimeseriesData<dynamic>>,
            List<TimeseriesData<dynamic>>, List<TimeseriesData<dynamic>>>(
          dbStream,
          liveStream,
          (dbData, liveData) {
            final merged = <int, TimeseriesData<dynamic>>{};
            for (final d in dbData) {
              merged[d.time.millisecondsSinceEpoch] = d;
            }
            for (final d in liveData) {
              merged[d.time.millisecondsSinceEpoch] = d;
            }
            final result = merged.values.toList()
              ..sort((a, b) => a.time.compareTo(b.time));
            return result;
          },
        );
      } else {
        // Use extended range for fetching
        return Stream.fromFuture(collector.database
            .queryTimeseriesData(k, fetchRange!.end, from: fetchRange!.start));
      }
    }).toList();

    _dataStreamKey = key;
    return _dataStream = Rx.combineLatestList(streams);
  }

  @override
  Widget build(BuildContext context) {
    final collectorAsync = ref.watch(collectorProvider);

    return collectorAsync.when(
      data: (collector) {
        if (collector == null) {
          return const Center(child: Text('No collector available'));
        }
        if (widget.keys.isEmpty) {
          return const Center(child: Text('Select keys to view history'));
        }
        if (!widget.realtime && widget.range == null) {
          return const Center(child: Text('Pick a start & end date'));
        }

        return StreamBuilder<List<List<TimeseriesData<dynamic>>>>(
          stream: _streamFor(collector),
          builder: (context, snap) {
            if (!snap.hasData) {
              // An error used to land here as a spinner that never stopped:
              // "still loading" and "there is no table for this key" looked
              // identical. Say which, in the same words the trends use.
              if (snap.hasError) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      describeTrendFetchError(
                          widget.keys.join(', '), snap.error!),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                );
              }
              return const Center(child: CircularProgressIndicator());
            }

            final lists = snap.data!;

            // Quick hash check to see if data actually changed
            final currentHash = _calculateDataHash(lists);
            if (currentHash != _lastDataHash) {
              _lastDataHash = currentHash;
              _updateTimer?.cancel();
              _updateTimer = Timer(const Duration(milliseconds: 50), () {
                if (mounted) {
                  _processDataEfficiently(lists);
                }
              });
            }

            return _buildOptimizedTable();
          },
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
    );
  }

  // Fast hash calculation to detect data changes
  int _calculateDataHash(List<List<TimeseriesData<dynamic>>> lists) {
    int hash = 0;
    for (final list in lists) {
      if (list.isNotEmpty) {
        hash ^= list.length.hashCode;
        hash ^= list.first.time.millisecondsSinceEpoch.hashCode;
        hash ^= list.last.time.millisecondsSinceEpoch.hashCode;
      }
    }
    return hash;
  }

  void _processDataEfficiently(List<List<TimeseriesData<dynamic>>> lists) {
    // Remove the early return check when called directly from timestamp click
    // Only skip if called from the timer and data hasn't changed
    if (_lastProcessedData != null &&
        _listsEqual(_lastProcessedData!, lists) &&
        _lastDataHash != 0) {
      return;
    }

    final stopwatch = Stopwatch()..start();

    // Pre-allocate collections with known sizes
    final allTs = <DateTime>{};
    final keyData = <String, List<TimeseriesData<dynamic>>>{};

    // Single pass to collect timestamps and organize data by key
    for (int i = 0; i < widget.keys.length && i < lists.length; i++) {
      final key = widget.keys[i];
      final list = lists[i];
      keyData[key] = list;

      for (final s in list) {
        // For historical data, only include data within the selected range
        if (!widget.realtime && widget.range != null) {
          if (s.time.isBefore(widget.range!.start) ||
              s.time.isAfter(widget.range!.end)) {
            continue;
          }
        }
        allTs.add(s.time);
      }
    }

    // Sort timestamps once
    final ordered = allTs.toList();
    if (_sortOrder == _TableSortOrder.newestFirst) {
      ordered.sort((a, b) => b.compareTo(a));
    } else {
      ordered.sort((a, b) => a.compareTo(b));
    }

    final kept =
        widget.rows == -1 ? ordered : ordered.take(widget.rows).toList();

    // Pre-allocate table rows
    final tableRows =
        List<Map<String, dynamic>>.filled(kept.length, <String, dynamic>{});

    // Optimized row processing with early termination
    const epsilon = Duration(seconds: 5);
    for (int i = 0; i < kept.length; i++) {
      final t = kept[i];
      final row = <String, dynamic>{'Timestamp': t};

      for (final key in widget.keys) {
        final list = keyData[key]!;
        TimeseriesData<dynamic>? best;
        var bestDt = epsilon + const Duration(days: 999);

        // Early termination: if we find a perfect match, stop looking
        for (final s in list) {
          final d = s.time.difference(t).abs();
          if (d <= epsilon && d < bestDt) {
            best = s;
            bestDt = d;
            if (d.inMilliseconds == 0) break; // Perfect match, stop
          }
        }
        row[key] = best?.value;
      }
      tableRows[i] = row;
    }

    if (mounted) {
      setState(() {
        _cachedTableRows = tableRows;
        _lastProcessedData = lists;
        // ordered is sorted, so the ends bound the whole set.
        _showDates = ordered.isNotEmpty &&
            !_sameCalendarDay(ordered.first, ordered.last);
      });
    }

    stopwatch.stop();
  }

  bool _listsEqual(List<List<TimeseriesData<dynamic>>> a,
      List<List<TimeseriesData<dynamic>>> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].length != b[i].length) return false;
      if (a[i].isNotEmpty && b[i].isNotEmpty) {
        if (a[i].first.time != b[i].first.time ||
            a[i].last.time != b[i].last.time) {
          return false;
        }
      }
    }
    return true;
  }

  Widget _buildOptimizedTable() {
    if (_cachedTableRows == null) {
      return const Center(child: CircularProgressIndicator());
    }

    // Create columns with aliases
    final columns = ['Timestamp'];
    final keyColumns = <String>[];

    for (final key in widget.keys) {
      final config = widget.graphConfigs[key];
      final displayName = config?.alias ?? key;
      keyColumns.add(displayName);
    }

    columns.addAll(keyColumns);

    return LayoutBuilder(
      builder: (context, constraints) {
        // Use ListView.builder for virtualization - only renders visible rows
        return ListView.builder(
          itemCount: _cachedTableRows!.length + 1, // +1 for header
          itemExtent: 32.0, // Fixed row height for better performance
          itemBuilder: (context, index) {
            if (index == 0) {
              return _buildTableHeader(columns);
            }

            final rowIndex = index - 1;
            final row = _cachedTableRows![rowIndex];

            return _buildTableRow(row, columns, keyColumns, rowIndex);
          },
        );
      },
    );
  }

  Widget _buildTableHeader(List<String> columns) {
    return Container(
      height: 32,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: columns
            .map((c) => Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8.0, vertical: 4.0),
                    child: c == 'Timestamp'
                        ? InkWell(
                            onTap: () {
                              setState(() {
                                _sortOrder =
                                    _sortOrder == _TableSortOrder.newestFirst
                                        ? _TableSortOrder.oldestFirst
                                        : _TableSortOrder.newestFirst;
                                // Force reprocessing by clearing the data hash
                                _lastDataHash = 0;
                                if (_lastProcessedData != null) {
                                  _processDataEfficiently(_lastProcessedData!);
                                }
                              });
                            },
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  c,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(width: 4),
                                Icon(
                                  _sortOrder == _TableSortOrder.newestFirst
                                      ? Icons.arrow_downward
                                      : Icons.arrow_upward,
                                  size: 16,
                                ),
                              ],
                            ),
                          )
                        : Text(
                            c,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 14),
                            overflow: TextOverflow.ellipsis,
                          ),
                  ),
                ))
            .toList(),
      ),
    );
  }

  Widget _buildTableRow(Map<String, dynamic> row, List<String> columns,
      List<String> keyColumns, int index) {
    return Container(
      height: 32,
      decoration: BoxDecoration(
        color: index.isEven
            ? Theme.of(context).colorScheme.surface
            : Theme.of(context).colorScheme.surfaceContainerLowest,
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).dividerColor.withOpacity(0.2),
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        children: columns
            .map((c) => Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8.0, vertical: 2.0),
                    child: Text(
                      c == 'Timestamp'
                          ? _formatTimestamp(row[c] as DateTime)
                          : _fmt(row[widget.keys[columns.indexOf(c) -
                              1]]), // Use original key for data lookup
                      style: const TextStyle(fontSize: 13),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ))
            .toList(),
      ),
    );
  }

  static bool _sameCalendarDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  String _formatTimestamp(DateTime ts) {
    final time = '${ts.hour.toString().padLeft(2, '0')}:'
        '${ts.minute.toString().padLeft(2, '0')}:'
        '${ts.second.toString().padLeft(2, '0')}';
    if (!_showDates) return time;
    return '${ts.year}-${ts.month.toString().padLeft(2, '0')}-'
        '${ts.day.toString().padLeft(2, '0')} $time';
  }

  static String _fmt(dynamic v) {
    if (v == null) return '—';
    if (v is num) {
      if (v is double) return v.toStringAsFixed(2);
      return v.toString();
    }
    if (v is bool) return v ? 'true' : 'false';
    return v.toString();
  }
}

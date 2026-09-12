import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rxdart/rxdart.dart';
import 'package:cristalyse/cristalyse.dart' as cs;
import 'package:tfc_dart/core/collector.dart';
import 'package:tfc_dart/core/database.dart';

import 'graph.dart';
import '../page_creator/assets/graph.dart' show describeTrendFetchError;
import '../providers/collector.dart';
import '../models/history_models.dart';

/// How many points a historical range asks the server for.
///
/// A chart is about a thousand pixels wide and never plots more than that, but
/// the range query fetched every raw row: a 2 Hz tag over an eight-hour shift
/// is 57 600 samples the server sorted and shipped and the UI isolate then
/// decoded and threw away — between 181x and 1800x more rows than pixels.
/// `queryTimeseriesDataDownsampled` buckets server-side into min/max/last
/// triples, so spikes and step changes survive; this is not "every third
/// sample". Measured on the plant database: 574 ms → 220 ms on a short range,
/// 6 204 ms → 2 157 ms on a long one.
///
/// Only the historical range uses it. Realtime keeps its raw backfill for the
/// reason spelled out at the call site.
///
/// Boolean, text and struct columns have no numeric `value` to aggregate, and
/// the query silently returns raw rows for them — unchanged behaviour, and
/// deliberately so: min/max/last of a boolean is not a boolean, and a digital
/// trace is read for its *edges*, the one thing bucketing would blur. Those
/// need run-length encoding or paging, not this.
const int kGraphMaxPoints = 1000;

// -----------------------------------------------------------------------------
// Graph pane (realtime or range) – uses collectorProvider for history
// -----------------------------------------------------------------------------
class HistoryGraphPane extends ConsumerStatefulWidget {
  final List<String> keys;
  final bool realtime;
  final DateTimeRange? range;
  final Duration realtimeDuration;
  final Map<String, GraphKeyConfig> graphConfigs;
  final Map<int, GraphDisplayConfig> graphDisplayConfigs;
  final void Function(int graphIndex)? onEditGraph;
  final void Function(int graphIndex)? onSelectGraph;
  final void Function(int fromIndex, int toIndex)? onSwapGraphs;
  final int targetGraphIndex;

  const HistoryGraphPane({
    super.key,
    required this.keys,
    required this.realtime,
    required this.range,
    required this.realtimeDuration,
    required this.graphConfigs,
    required this.graphDisplayConfigs,
    this.onEditGraph,
    this.onSelectGraph,
    this.onSwapGraphs,
    this.targetGraphIndex = 0,
  });

  @override
  ConsumerState<HistoryGraphPane> createState() => _HistoryGraphPaneState();
}

class _HistoryGraphPaneState extends ConsumerState<HistoryGraphPane> {
  bool _paused = false;
  DateTime? _pausedAt;
  List<List<dynamic>>? _pausedData;
  cs.ChartTheme? _chartTheme;

  /// The combined history stream, kept across rebuilds.
  ///
  /// Building it issues a `queryTimeseriesData` and hands `StreamBuilder` a
  /// stream object it has never seen, which makes it resubscribe and fall back
  /// to its spinner. Doing that from `build` meant every unrelated rebuild —
  /// the chart's own `redraw` callback, a parent resizing, a theme change —
  /// re-ran the query and flashed the chart back to "loading".
  Stream<List<List<dynamic>>>? _dataStream;

  /// The inputs [_dataStream] was built from; a change here, and only here,
  /// earns a new query.
  String? _dataStreamKey;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // todo this does not work properly
    _chartTheme = ref.watch(chartThemeNotifierProvider);
  }

  /// Invalidates [_dataStream] so the next build fetches afresh. The cached
  /// stream is single-subscription, so anything that has to re-listen (a
  /// resume after a pause) has to go through here.
  void _refetch() {
    _dataStream = null;
    _dataStreamKey = null;
  }

  Stream<List<List<dynamic>>> _streamFor(Collector collector) {
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
    DateTimeRange? fetchRange;

    if (widget.realtime) {
      since = widget.realtimeDuration;
    } else {
      since = DateTime.now().difference(widget.range!.start);

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
        // Combine a DB backfill query (full window) with the live stream.
        // collectStream caches internally, so if the user increases the
        // window the cached stream won't have older data. The DB query
        // fills in the gap.
        //
        // Raw, deliberately — see [kGraphMaxPoints]. collectStream loads its
        // own raw history for the same window, and the merge below dedupes
        // the two by millisecond; downsampled points carry synthetic bucket
        // timestamps that would not line up with the raw ones, so they would
        // be plotted *alongside* them instead of in place of them.
        final liveStream = collector.collectStream(k, since: since);
        final cutoff = DateTime.now().toUtc().subtract(since);
        final dbStream = Stream.fromFuture(
          collector.database
              .queryTimeseriesData(k, DateTime.now().toUtc(), from: cutoff)
              // An empty backfill, not a failed one. `combineLatest2` emits
              // nothing until every source has emitted at least once, so a
              // backfill that errors before its first value silences the
              // live stream next to it for good -- the pane showed the
              // message and never drew another point, however healthy the
              // subscription was. The live stream still reports its own
              // failure, which is what names a key that is really dead.
              .catchError((Object e) => <TimeseriesData<dynamic>>[]),
        );
        return Rx.combineLatest2<List<TimeseriesData<dynamic>>,
            List<TimeseriesData<dynamic>>, List<dynamic>>(
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
        return Stream.fromFuture(collector.database
            .queryTimeseriesDataDownsampled(
                k, fetchRange!.start, fetchRange!.end,
                maxPoints: kGraphMaxPoints));
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

        return StreamBuilder<List<List<dynamic>>>(
          stream: _paused ? null : _streamFor(collector),
          builder: (context, snap) {
            List<List<dynamic>> data;
            if (_paused && _pausedData != null) {
              data = _pausedData!;
            } else if (snap.hasData) {
              data = snap.data!;
              _pausedData = data;
            } else if (snap.hasError) {
              // Say what went wrong, in the same words the asset trends use.
              // A key whose table is missing used to sit on the spinner.
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
            } else {
              return _WaitingForData(keys: widget.keys);
            }

            // Group data by graph index
            final Map<int, List<Map<GraphDataConfig, List<List<double>>>>>
                graphDataByIndex = {};

            for (int i = 0;
                i < math.min(widget.keys.length, data.length);
                i++) {
              final seriesKey = widget.keys[i];
              final seriesData = data[i];
              final config = widget.graphConfigs[seriesKey];

              if (config == null) continue;

              final points = <List<double>>[];

              // Booleans draw as square steps: hold the previous level up to
              // the sample that changed, then jump. The old code injected the
              // *inverted* level at every sample — a run of identical trues
              // rendered as a full-height sawtooth.
              double? prevBoolY;
              for (final sample in seriesData) {
                final value = sample.value;
                final time = sample.time.millisecondsSinceEpoch.toDouble();
                double? y;
                if (value is num) {
                  y = value.toDouble();
                } else if (value is Map && value['value'] is num) {
                  y = (value['value'] as num).toDouble();
                } else if (value is bool) {
                  y = value ? 1.0 : 0.0;
                }
                if (y != null) {
                  if (value is bool) {
                    if (prevBoolY != null && prevBoolY != y) {
                      points.add([time, prevBoolY]);
                    }
                    prevBoolY = y;
                  }
                  points.add([time, y]);
                }
              }

              final graphData = {
                GraphDataConfig(
                  label: config.alias,
                  mainAxis: !config.useSecondYAxis,
                  color: GraphConfig.colors[i % GraphConfig.colors.length],
                ): points,
              };

              graphDataByIndex
                  .putIfAbsent(config.graphIndex, () => [])
                  .add(graphData);
            }

            final Duration xSpan = widget.realtime
                ? widget.realtimeDuration
                : (widget.range != null
                    ? widget.range!.end.difference(widget.range!.start)
                    : const Duration(minutes: 10));

            // Include the target graph index so an empty placeholder appears
            final usedGraphIndices = <int>{
              ...graphDataByIndex.keys,
              widget.targetGraphIndex,
            }.toList()
              ..sort();

            return Stack(
              children: [
                Column(
                  children: [
                    ...usedGraphIndices.map((graphIndex) {
                      final graphData = graphDataByIndex[graphIndex] ?? [];
                      final graphDisplayConfig =
                          widget.graphDisplayConfigs[graphIndex];
                      final isTarget = graphIndex == widget.targetGraphIndex;

                      return Expanded(
                        child: DragTarget<int>(
                          onWillAcceptWithDetails: (details) =>
                              details.data != graphIndex,
                          onAcceptWithDetails: (details) {
                            widget.onSwapGraphs?.call(details.data, graphIndex);
                          },
                          builder: (context, candidateData, _) {
                            final isDropTarget = candidateData.isNotEmpty;
                            return Container(
                              margin: const EdgeInsets.only(bottom: 4),
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: isDropTarget
                                      ? Theme.of(context)
                                          .colorScheme
                                          .primary
                                          .withAlpha(200)
                                      : isTarget
                                          ? Theme.of(context)
                                              .colorScheme
                                              .primary
                                              .withAlpha(120)
                                          : Colors.transparent,
                                  width: 2,
                                ),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Stack(
                                children: [
                                  // Graph content
                                  graphData.isEmpty
                                      ? Center(
                                          child: Text(
                                            'Tick keys in the left pane to plot them here '
                                            '(Graph ${graphIndex + 1})',
                                            style: TextStyle(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                              fontSize: 13,
                                            ),
                                          ),
                                        )
                                      : Builder(
                                          builder: (context) {
                                            return _buildGraph(
                                              context,
                                              graphData,
                                              graphDisplayConfig,
                                              xSpan,
                                            );
                                          },
                                        ),
                                  // Overlay: label on top, drag + edit below
                                  Positioned(
                                    top: 4,
                                    left: 4,
                                    child: _buildGraphOverlay(
                                      context,
                                      graphIndex: graphIndex,
                                      label: graphDisplayConfig?.displayName ??
                                          'Graph ${graphIndex + 1}',
                                      isTarget: isTarget,
                                      showDrag: usedGraphIndices.length > 1 &&
                                          widget.onSwapGraphs != null,
                                      showEdit: widget.onEditGraph != null,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      );
                    }),
                  ],
                ),
                // Pause/resume overlay
                if (widget.realtime && _paused)
                  Positioned(
                    top: 12,
                    right: 12,
                    child: Card(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      child: InkWell(
                        onTap: () {
                          setState(() {
                            _paused = false;
                            _pausedAt = null;
                            _pausedData = null;
                            // Resuming re-listens, and the cached stream is
                            // single-subscription — plus the operator wants
                            // the gap they paused over filled in.
                            _refetch();
                          });
                        },
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.play_arrow,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onPrimaryContainer,
                                  size: 20),
                              const SizedBox(width: 4),
                              Text(
                                'Resume',
                                style: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onPrimaryContainer,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                if (widget.realtime && _paused && _pausedAt != null)
                  Positioned(
                    bottom: 12,
                    right: 12,
                    child: Card(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest
                          .withAlpha(200),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        child: Text(
                          'Paused at ${_pausedAt!.toString().substring(11, 19)}',
                          style: TextStyle(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
    );
  }

  Widget _buildGraphOverlay(
    BuildContext context, {
    required int graphIndex,
    required String label,
    required bool isTarget,
    required bool showDrag,
    required bool showEdit,
  }) {
    final cs = Theme.of(context).colorScheme;
    final bgColor = isTarget
        ? cs.primaryContainer.withAlpha(220)
        : cs.surfaceContainerHighest.withAlpha(180);
    final fgColor = isTarget ? cs.onPrimaryContainer : cs.onSurfaceVariant;

    return IntrinsicWidth(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Graph N label (select button)
          Material(
            color: bgColor,
            borderRadius: BorderRadius.circular(4),
            child: InkWell(
              borderRadius: BorderRadius.circular(4),
              onTap: () => widget.onSelectGraph?.call(graphIndex),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: isTarget ? FontWeight.bold : FontWeight.normal,
                    color: fgColor,
                  ),
                ),
              ),
            ),
          ),
          // Drag handle + settings row
          if (showDrag || showEdit) ...[
            const SizedBox(height: 2),
            Row(
              children: [
                if (showDrag)
                  Expanded(
                    child: Draggable<int>(
                      data: graphIndex,
                      feedback: Material(
                        elevation: 4,
                        borderRadius: BorderRadius.circular(4),
                        color: cs.primaryContainer,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          child: Text(
                            label,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: cs.onPrimaryContainer,
                            ),
                          ),
                        ),
                      ),
                      childWhenDragging: Material(
                        color: cs.surfaceContainerHighest.withAlpha(100),
                        borderRadius: BorderRadius.circular(4),
                        child: const Center(
                          child: Padding(
                            padding: EdgeInsets.all(3),
                            child: Icon(Icons.drag_indicator,
                                size: 14, color: Colors.grey),
                          ),
                        ),
                      ),
                      child: Material(
                        color: bgColor,
                        borderRadius: BorderRadius.circular(4),
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.all(3),
                            child: Icon(Icons.drag_indicator,
                                size: 14, color: fgColor),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (showDrag && showEdit) const SizedBox(width: 2),
                if (showEdit)
                  Expanded(
                    child: Material(
                      color: bgColor,
                      borderRadius: BorderRadius.circular(4),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(4),
                        onTap: () => widget.onEditGraph!(graphIndex),
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.all(3),
                            child:
                                Icon(Icons.settings, size: 14, color: fgColor),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildGraph(
    BuildContext context,
    List<Map<GraphDataConfig, List<List<double>>>> graphData,
    GraphDisplayConfig? displayCfg,
    Duration xSpan,
  ) {
    final flattened = <Map<String, dynamic>>[];
    for (final seriesMap in graphData) {
      final entry = seriesMap.entries.first;
      final gdc = entry.key;
      final pts = entry.value;
      final axisKey = gdc.mainAxis ? 'y' : 'y2';
      for (final p in pts) {
        if (p.length < 2) continue;
        flattened.add({
          'x': p[0],
          axisKey: p[1],
          's': gdc.label,
        });
      }
    }

    final cfg = GraphConfig(
      type: GraphType.timeseries,
      xAxis: const GraphAxisConfig(unit: ''),
      yAxis: GraphAxisConfig(
        unit: displayCfg?.yAxisUnit ?? '',
        title: (displayCfg?.yAxisUnit ?? '').isNotEmpty
            ? displayCfg!.yAxisUnit
            : 'Y',
      ),
      yAxis2:
          (displayCfg?.yAxis2Unit != null && displayCfg!.yAxis2Unit!.isNotEmpty)
              ? GraphAxisConfig(
                  unit: displayCfg.yAxis2Unit!,
                  title: displayCfg.yAxis2Unit,
                )
              : graphData.any((m) => m.keys.any((k) => !k.mainAxis))
                  ? const GraphAxisConfig(unit: '', title: 'Y2')
                  : null,
      xSpan: widget.realtime ? xSpan : null,
      xRange: widget.realtime ? null : widget.range,
      pan: false,
    );

    final graph = Graph(
      chartTheme: _chartTheme,
      config: cfg,
      data: flattened,
      onPanStart: (_) {},
      onPanUpdate: (_) {},
      onPanEnd: (_) {},
      onNowPressed: () {},
      onSetDatePressed: () {},
      redraw: () {
        if (mounted) setState(() {});
      },
      showButtons: false,
    );

    graph.theme(ref.watch(chartThemeNotifierProvider));
    return graph.build(context);
  }
}

/// The spinner, with a deadline: after ten seconds without a first sample it
/// says so and names the keys, so a dead key reads as "no data" rather than
/// "still loading". The stream stays subscribed -- if data arrives later the
/// chart draws.
class _WaitingForData extends StatefulWidget {
  const _WaitingForData({required this.keys});
  final List<String> keys;

  @override
  State<_WaitingForData> createState() => _WaitingForDataState();
}

class _WaitingForDataState extends State<_WaitingForData> {
  Timer? _timer;
  bool _late = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 10), () {
      if (mounted) setState(() => _late = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_late) return const Center(child: CircularProgressIndicator());
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 8),
            Text(
              'No data yet for ${widget.keys.join(', ')}',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Nothing has been received in 10 s -- the key may not be '
              'collected, or the PLC is not publishing it. Still listening.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

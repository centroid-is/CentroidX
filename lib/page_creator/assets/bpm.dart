import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tfc/widgets/panes/standard_dialog.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/duration_field.dart';
import 'common.dart';
import 'option_variable.dart';
import 'helper/database_recovery.dart';
import 'helper/timeseries_notify_mixin.dart';
import '../../providers/current_page_assets.dart';
import '../../providers/database.dart';
import '../../providers/timeseries.dart';
import '../../widgets/graph.dart';
import 'package:tfc/converter/color_converter.dart';
import 'package:tfc_dart/core/database.dart';

part 'bpm.g.dart';

@JsonSerializable(explicitToJson: true)
class BpmConfig extends BaseAsset {
  @override
  String get displayName => 'BPM Counter';
  @override
  String get category => 'Text & Numbers';

  String key;
  @ColorConverter()
  @JsonKey(name: 'text_color')
  Color textColor;
  @JsonKey(name: 'poll_interval')
  Duration pollInterval;
  @JsonKey(name: 'default_interval')
  int defaultInterval; // in minutes
  @JsonKey(name: 'how_many')
  int howMany;
  @JsonKey(name: 'graph_header')
  String? graphHeader;
  @JsonKey(name: 'interval_presets', defaultValue: [1, 5, 10, 30, 60])
  List<int> intervalPresets;
  @JsonKey(name: 'show_bph', defaultValue: false)
  bool showBph;
  @JsonKey(defaultValue: 'bpm')
  String unit;
  @JsonKey(name: 'interval_variable')
  String? intervalVariable;

  BpmConfig({
    required this.key,
    this.textColor = Colors.black,
    this.pollInterval = const Duration(seconds: 15),
    this.defaultInterval = 1,
    this.howMany = 20,
    this.graphHeader,
    this.intervalPresets = const [1, 5, 10, 30, 60],
    this.showBph = false,
    this.unit = 'bpm',
    this.intervalVariable,
  });

  BpmConfig.preview()
      : key = "key",
        textColor = Colors.black,
        pollInterval = const Duration(seconds: 15),
        defaultInterval = 1,
        howMany = 20,
        intervalPresets = const [1, 5, 10, 30, 60],
        showBph = false,
        unit = 'bpm',
        intervalVariable = null;

  factory BpmConfig.fromJson(Map<String, dynamic> json) =>
      _$BpmConfigFromJson(json);
  Map<String, dynamic> toJson() => _$BpmConfigToJson(this);

  @override
  Widget build(BuildContext context) => BpmWidget(config: this);

  @override
  Widget configure(BuildContext context) => _BpmConfigEditor(config: this);
}

/// Compute rate from a raw count over [windowMinutes].
/// [bph] == true  → batches per hour
/// [bph] == false → batches per minute
double _rate(int count, int windowMinutes, {required bool bph}) {
  if (windowMinutes <= 0) return 0;
  return bph ? count * 60.0 / windowMinutes : count / windowMinutes.toDouble();
}

String _formatRate(double rate) {
  if (rate == rate.roundToDouble()) return rate.toInt().toString();
  return rate.toStringAsFixed(1);
}

// ---------------------------------------------------------------------------
// Config editor
// ---------------------------------------------------------------------------

class _BpmConfigEditor extends ConsumerStatefulWidget {
  final BpmConfig config;
  const _BpmConfigEditor({required this.config});

  @override
  ConsumerState<_BpmConfigEditor> createState() => _BpmConfigEditorState();
}

class _BpmConfigEditorState extends ConsumerState<_BpmConfigEditor> {
  Widget _buildIntervalVariableDropdown() {
    final pageAssets = ref.watch(currentPageAssetsProvider);
    final optionVars = pageAssets.whereType<OptionVariableConfig>().toList();

    return DropdownButtonFormField<String?>(
      value: widget.config.intervalVariable,
      decoration: const InputDecoration(
        labelText: 'Interval Variable',
        helperText: 'Link to an OptionVariable to control interval',
      ),
      items: [
        const DropdownMenuItem<String?>(
          value: null,
          child: Text('None — use default'),
        ),
        ...optionVars.map((ov) => DropdownMenuItem<String?>(
              value: ov.variableName,
              child: Text(ov.variableName),
            )),
      ],
      onChanged: (value) =>
          setState(() => widget.config.intervalVariable = value),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          KeyField(
            initialValue: widget.config.key,
            onChanged: (value) => setState(() => widget.config.key = value),
          ),
          const SizedBox(height: 16),
          TextFormField(
            initialValue: widget.config.text,
            decoration: const InputDecoration(labelText: 'Label'),
            onChanged: (value) => setState(() => widget.config.text = value),
          ),
          const SizedBox(height: 16),
          TextFormField(
            initialValue: widget.config.graphHeader,
            decoration: const InputDecoration(
              labelText: 'Graph Header',
              helperText: 'Custom header for the chart dialog (optional)',
            ),
            onChanged: (value) =>
                setState(() => widget.config.graphHeader = value),
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: DurationField(
                  value: Duration(minutes: widget.config.defaultInterval),
                  labelText: 'Default Interval',
                  helperText: 'window for the main display rate',
                  min: const Duration(minutes: 1),
                  max: const Duration(hours: 24),
                  units: const [DurationUnit.minutes, DurationUnit.hours],
                  // The config stores bare minutes.
                  resolution: const Duration(minutes: 1),
                  onChanged: (value) => setState(
                      () => widget.config.defaultInterval = value.inMinutes),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _buildIntervalVariableDropdown(),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextFormField(
            initialValue: widget.config.howMany.toString(),
            decoration: const InputDecoration(
              labelText: 'Chart Buckets',
              helperText: 'Number of time buckets in the chart',
            ),
            keyboardType: TextInputType.number,
            onChanged: (value) {
              final v = int.tryParse(value);
              if (v != null && v > 0) {
                setState(() => widget.config.howMany = v);
              }
            },
          ),
          const SizedBox(height: 16),
          DurationField(
            value: widget.config.pollInterval,
            labelText: 'Poll Interval',
            helperText: 'how often to refresh the count',
            min: const Duration(seconds: 1),
            max: const Duration(hours: 1),
            units: const [DurationUnit.seconds, DurationUnit.minutes],
            onChanged: (value) =>
                setState(() => widget.config.pollInterval = value),
          ),
          const SizedBox(height: 16),
          TextFormField(
            initialValue: widget.config.unit,
            decoration: const InputDecoration(
              labelText: 'Unit Prefix',
              helperText: 'e.g. "b" for bpm/bph, "c" for cpm/cph',
            ),
            onChanged: (value) {
              setState(() => widget.config.unit = value);
            },
          ),
          const SizedBox(height: 16),
          SwitchListTile(
            title: Text('Show ${widget.config.unit} (Per Hour)'),
            subtitle: Text('Off = ${widget.config.unit} (Per Minute)'),
            value: widget.config.showBph,
            onChanged: (value) => setState(() => widget.config.showBph = value),
          ),
          const SizedBox(height: 16),
          DropdownButton<TextPos>(
            value: widget.config.textPos ?? TextPos.right,
            isExpanded: true,
            onChanged: (value) =>
                setState(() => widget.config.textPos = value!),
            items: TextPos.values
                .map((e) =>
                    DropdownMenuItem<TextPos>(value: e, child: Text(e.name)))
                .toList(),
          ),
          const SizedBox(height: 16),
          CoordinatesField(
            initialValue: widget.config.coordinates,
            onChanged: (c) => setState(() => widget.config.coordinates = c),
            enableAngle: true,
          ),
          const SizedBox(height: 16),
          SizeField(
            initialValue: widget.config.size,
            onChanged: (size) => setState(() => widget.config.size = size),
          ),
          const SizedBox(height: 16),
          const Text('Available Intervals',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [1, 5, 10, 30, 60].map((minutes) {
              final selected = widget.config.intervalPresets.contains(minutes);
              return FilterChip(
                label: Text(_formatIntervalMinutes(minutes)),
                selected: selected,
                onSelected: (value) {
                  setState(() {
                    if (value) {
                      widget.config.intervalPresets.add(minutes);
                      widget.config.intervalPresets.sort();
                    } else {
                      widget.config.intervalPresets.remove(minutes);
                    }
                  });
                },
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

String _formatIntervalMinutes(int minutes) {
  if (minutes < 60) return '${minutes}m';
  if (minutes < 1440) return '${minutes ~/ 60}h';
  return '${minutes ~/ 1440}d';
}

// ---------------------------------------------------------------------------
// Main display widget
// ---------------------------------------------------------------------------

class BpmWidget extends ConsumerStatefulWidget {
  final BpmConfig config;
  const BpmWidget({super.key, required this.config});

  @override
  ConsumerState<BpmWidget> createState() => _BpmWidgetState();
}

class _BpmWidgetState extends ConsumerState<BpmWidget>
    with TimeseriesNotifyMixin<BpmWidget> {
  late int _activeInterval;
  int? _count;

  // ── TimeseriesNotifyMixin overrides ─────────────────────────────────

  @override
  List<String> get tsKeys => [widget.config.key];

  @override
  String? get tsIntervalVariable => widget.config.intervalVariable;

  @override
  int get tsMaxWindowMinutes => [
        _activeInterval,
        ...widget.config.intervalPresets,
      ].reduce(math.max);

  @override
  void tsOnIntervalChanged(int minutes) {
    if (minutes != _activeInterval) {
      _activeInterval = minutes;
      tsUpdateDisplay();
    }
  }

  @override
  void tsUpdateDisplay() {
    if (!mounted) return;
    final since = DateTime.now().subtract(Duration(minutes: _activeInterval));
    final count = tsCache.countSince(widget.config.key, since);
    setState(() => _count = count);
    tsScheduleExpiry(_activeInterval);
  }

  // ── Lifecycle ───────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _activeInterval = widget.config.defaultInterval;
    tsInit();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    tsDidChangeDependencies();
  }

  @override
  void dispose() {
    tsDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.config.key == "key") {
      return _buildDisplay(context, "42 ${widget.config.unit}",
          activeInterval: _activeInterval);
    }

    String displayValue = "---";
    if (_count != null) {
      final r = _rate(_count!, _activeInterval, bph: widget.config.showBph);
      displayValue = "${_formatRate(r)} ${widget.config.unit}";
    }
    return _buildDisplay(context, displayValue,
        activeInterval: _activeInterval);
  }

  Widget _buildDisplay(BuildContext context, String value,
      {int? activeInterval}) {
    // Laid out at its final size rather than scaled there by a `FittedBox`;
    // see the note on `AutoSizedText` in common.dart.
    Widget displayWidget = AutoSizedText(
      value,
      angleRadians: (widget.config.coordinates.angle ?? 0) * math.pi / 180,
      style: TextStyle(color: widget.config.textColor),
    );

    displayWidget = GestureDetector(
      onTap: () => _showChartDialog(
          context, activeInterval ?? widget.config.defaultInterval),
      child: displayWidget,
    );

    return displayWidget;
  }

  String get _chartDialogId => 'chart:${identityHashCode(widget.config)}';

  /// A trend belongs next to the thing it describes, not on top of it — so
  /// the chart opens in a free-floating window the operator can drag off the
  /// live value and leave running.
  void _showChartDialog(BuildContext context, int activeInterval) {
    final size = MediaQuery.of(context).size;
    showFloatingDialog(
      context: context,
      id: _chartDialogId,
      title: widget.config.graphHeader ?? widget.config.text ?? 'BPM Counter',
      icon: Icons.speed,
      size: Size(size.width * 0.7, size.height * 0.7),
      scrollable: false,
      builder: (context) => _BpmChartView(
        config: widget.config,
        initialInterval: activeInterval,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Dialog view: summary cards + line chart
// ---------------------------------------------------------------------------

class _BpmChartView extends ConsumerStatefulWidget {
  final BpmConfig config;
  final int initialInterval;

  const _BpmChartView({required this.config, required this.initialInterval});

  @override
  ConsumerState<_BpmChartView> createState() => _BpmChartViewState();
}

class _BpmChartViewState extends ConsumerState<_BpmChartView> {
  late Duration _selectedInterval;
  List<DateTime> _rawTimestamps = [];

  /// Whether [_rawTimestamps] holds anything worth drawing yet: the readout's
  /// seed, or the window's own fetch.
  bool _hasData = false;

  /// A history fetch is in flight -- the opening one, or the refresh button.
  bool _fetching = false;

  /// Epoch ms before which [_rawTimestamps] knows nothing, while it holds
  /// only the readout's seed. Null once the window's own fetch has landed.
  int? _coverageStartMs;

  late Graph _graph;
  final Map<int, Graph> _graphs = {};
  DateTime _dataStart = DateTime.now();
  DateTime _dataEnd = DateTime.now();
  Timer? _pollTimer;
  bool _realTimeActive = true;
  bool _fetchingOlder = false;
  Database? _db;

  /// Cached finalized (closed) buckets per interval.
  final Map<int, List<(int, int)>> _bucketCache = {}; // ms → count
  /// Current open bucket count & start per interval.
  final Map<int, int> _openCount = {};
  final Map<int, int> _openStartMs = {};

  @override
  void initState() {
    super.initState();
    _selectedInterval = Duration(minutes: widget.initialInterval);
    _graph = _getOrCreateGraph(_selectedInterval.inMinutes);
    _seedFromReadout();
    // This window is meant to be dragged off the readout and left running, so
    // it has to survive the database coming up after it did. See
    // reinitOnDatabaseAvailable.
    reinitOnDatabaseAvailable(
      ref,
      currentDatabase: () => _db,
      onDatabaseAvailable: (_) {
        if (!mounted) return;
        _pollTimer?.cancel();
        _init();
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final theme = ref.watch(chartThemeNotifierProvider);
    for (final graph in _graphs.values) {
      graph.theme(theme);
    }
  }

  /// Starts the chart from what the readout on the mimic already holds.
  ///
  /// The window used to open on a spinner and stay on it until one query
  /// reaching back `howMany` x the largest preset (20 h at the default
  /// presets) came back -- while the readout the operator had just tapped was
  /// holding the last hour of the very same rows in the shared tracker. That
  /// hour is every summary card and the whole 1-minute chart, so the window
  /// now opens on them and the fetch fills in the rest.
  ///
  /// The tracker is only read, never created: `ref.exists` first, because
  /// reading an absent one would start a tracker, and with it a history query
  /// of its own.
  void _seedFromReadout() {
    final key = widget.config.key;
    final provider = timeseriesTrackerProvider(key);
    if (!ref.exists(provider)) return;
    final tracker = ref.read(provider);
    // An empty cache cannot tell "no batches this hour" from "not fetched
    // yet", and a row of zeros on a running line is worse than a dash.
    final seed = tracker.cache.timestamps(key).toList()..sort();
    if (seed.isEmpty) return;
    _rawTimestamps = seed;
    _coverageStartMs = DateTime.now()
        .subtract(Duration(minutes: tracker.windowMinutes))
        .millisecondsSinceEpoch;
    _hasData = true;
    _buildCache(_selectedInterval.inMinutes);
    _pushToGraph(_graph, _selectedInterval.inMinutes);
  }

  Graph _getOrCreateGraph(int intervalMinutes) {
    return _graphs[intervalMinutes] ??=
        _createGraphForInterval(Duration(minutes: intervalMinutes));
  }

  Graph _createGraphForInterval(Duration interval) {
    final xSpan = interval * widget.config.howMany;
    return Graph(
      config: GraphConfig(
        type: GraphType.timeseries,
        xAxis: const GraphAxisConfig(unit: ''),
        yAxis: GraphAxisConfig(
          unit: widget.config.unit,
          min: 0,
          integersOnly: true,
        ),
        pan: true,
        tooltip: true,
        xSpan: xSpan,
      ),
      data: [],
      showButtons: true,
      onPanUpdate: _onPanUpdate,
      onPanEnd: _onPanEnd,
      onNowPressed: _onNowPressed,
      onSetDatePressed: _onSetDatePressed,
      chartTheme: ref.read(chartThemeNotifierProvider),
      redraw: () {
        if (mounted) setState(() {});
      },
    );
  }

  // ── Bucket cache ──────────────────────────────────────────────────────

  int _bucketStart(int tsMs, int intervalMs) =>
      (tsMs ~/ intervalMs) * intervalMs;

  /// Build full bucket cache from raw timestamps for one interval.
  /// Always generates zero-filled buckets for the full viewport so the
  /// series line spans the entire graph and pan gestures work.
  void _buildCache(int minutes) {
    final intervalMs = minutes * 60000;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final openMs = _bucketStart(nowMs, intervalMs);
    final viewStartMs = openMs - (widget.config.howMany - 1) * intervalMs;

    // Effective start: include older data if user panned into the past
    int startMs = viewStartMs;
    if (_rawTimestamps.isNotEmpty) {
      final dataMs =
          _bucketStart(_rawTimestamps.first.millisecondsSinceEpoch, intervalMs);
      if (dataMs < startMs) startMs = dataMs;
    }

    // Seeded from the readout: nothing is known before its window, and the
    // bucket straddling that edge would be drawn short. Start at the first
    // bucket the seed covers completely; the fetch lifts this.
    final coverage = _coverageStartMs;
    if (coverage != null) {
      final firstFull = _bucketStart(coverage + intervalMs - 1, intervalMs);
      if (firstFull > startMs) startMs = firstFull;
    }

    // Count timestamps per closed bucket
    final counts = <int, int>{};
    int openCnt = 0;
    for (final ts in _rawTimestamps) {
      final b = _bucketStart(ts.millisecondsSinceEpoch, intervalMs);
      if (b >= openMs) {
        openCnt++;
      } else if (b >= startMs) {
        counts[b] = (counts[b] ?? 0) + 1;
      }
    }

    // Generate zero-filled closed buckets for the full range
    final closed = <(int, int)>[];
    for (var b = startMs; b < openMs; b += intervalMs) {
      closed.add((b, counts[b] ?? 0));
    }

    _bucketCache[minutes] = closed;
    _openCount[minutes] = openCnt;
    _openStartMs[minutes] = openMs;
  }

  /// Incrementally ingest new timestamps into all caches.
  void _ingest(List<DateTime> newTs) {
    if (newTs.isEmpty) return;
    _rawTimestamps.addAll(newTs);

    final nowMs = DateTime.now().millisecondsSinceEpoch;

    for (final minutes in _bucketCache.keys.toList()) {
      final intervalMs = minutes * 60000;
      final cache = _bucketCache[minutes]!;
      final openMs = _bucketStart(nowMs, intervalMs);
      final prevOpenMs = _openStartMs[minutes] ?? openMs;

      // Finalize rolled-over buckets
      if (openMs > prevOpenMs) {
        var fill = prevOpenMs;
        while (fill < openMs) {
          cache
              .add((fill, fill == prevOpenMs ? (_openCount[minutes] ?? 0) : 0));
          fill += intervalMs;
        }
        _openCount[minutes] = 0;
        _openStartMs[minutes] = openMs;
      }

      // Count new timestamps in the open bucket
      for (final ts in newTs) {
        if (ts.millisecondsSinceEpoch >= openMs) {
          _openCount[minutes] = (_openCount[minutes] ?? 0) + 1;
        }
      }
    }
  }

  /// Push cached buckets into a Graph.
  void _pushToGraph(Graph graph, int minutes) {
    final cache = _bucketCache[minutes];
    if (cache == null) return;
    final bph = widget.config.showBph;
    final unit = widget.config.unit;
    final data = <Map<String, dynamic>>[];
    for (final (ms, count) in cache) {
      data.add({
        'x': ms.toDouble(),
        'y': _rate(count, minutes, bph: bph),
        's': unit,
      });
    }
    // Append open bucket
    final openMs = _openStartMs[minutes];
    if (openMs != null) {
      data.add({
        'x': openMs.toDouble(),
        'y': _rate(_openCount[minutes] ?? 0, minutes, bph: bph),
        's': unit,
      });
    }
    graph.data.clear();
    if (data.isNotEmpty) graph.addAll(data);
  }

  // ── Init / fetch ──────────────────────────────────────────────────────

  Future<void> _init() async {
    _db = await ref.read(databaseProvider.future);
    if (_db == null || !mounted) return;
    await _fetchRawData();
    _schedulePoll();
  }

  Future<void> _fetchRawData() async {
    if (_db == null || !mounted) return;
    setState(() => _fetching = true);
    try {
      final maxMinutes = widget.config.intervalPresets.reduce(math.max);
      final totalWindow = Duration(minutes: maxMinutes * widget.config.howMany);
      _dataStart = DateTime.now().subtract(totalWindow);
      _dataEnd = DateTime.now();

      final rows = await _db!.queryTimeseriesData(widget.config.key, _dataStart,
          orderBy: 'time ASC');
      if (!mounted) return;

      // Replaces the seed wholesale rather than merging into it: the fetch
      // covers everything the seed did, so nothing is kept and nothing is
      // counted twice.
      _rawTimestamps = rows.map((r) => r.time).toList();
      _coverageStartMs = null;
      _hasData = true;
      _bucketCache.clear();
      _openCount.clear();
      _openStartMs.clear();

      // Build selected interval first
      _buildCache(_selectedInterval.inMinutes);
      _pushToGraph(_graph, _selectedInterval.inMinutes);

      // Build remaining in background
      _buildRemainingCaches();
    } catch (_) {
      // Stays on whatever it was drawing: the seed, or the empty frame.
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  Future<void> _buildRemainingCaches() async {
    for (final minutes in widget.config.intervalPresets) {
      if (!mounted) return;
      if (_bucketCache.containsKey(minutes)) continue;
      _buildCache(minutes);
      final g = _getOrCreateGraph(minutes);
      _pushToGraph(g, minutes);
      await Future.delayed(Duration.zero);
    }
  }

  // ── Polling ───────────────────────────────────────────────────────────

  /// Schedule poll at next bucket boundary of selected interval + 1s buffer.
  void _schedulePoll() {
    _pollTimer?.cancel();
    if (!_realTimeActive) return;

    final intervalMs = _selectedInterval.inMilliseconds;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final nextBoundaryMs = _bucketStart(nowMs, intervalMs) + intervalMs;
    final delayMs = (nextBoundaryMs - nowMs) + 1000;

    _pollTimer = Timer(Duration(milliseconds: delayMs), () {
      _pollNewData();
      _schedulePoll();
    });
  }

  Future<void> _pollNewData() async {
    if (!_realTimeActive || _db == null || !mounted) return;
    try {
      final rows = await _db!.queryTimeseriesData(
        widget.config.key,
        _dataEnd,
        orderBy: 'time ASC',
      );
      if (!mounted) return;
      _dataEnd = DateTime.now();

      _ingest(rows.map((r) => r.time).toList());
      _pushToGraph(_graph, _selectedInterval.inMinutes);
      if (rows.isNotEmpty) {
        _graph.panForward(DateTime.now().millisecondsSinceEpoch.toDouble());
      }
    } catch (_) {}
  }

  // --- Pan / navigation callbacks ---

  void _onPanUpdate(GraphPanEvent event) {
    if (event.visibleMinX == null) return;
    if (event.delta != null && event.delta!.dx > 0) _disableRealTime();
    final dataStartMs = _dataStart.millisecondsSinceEpoch.toDouble();
    if (event.visibleMinX! < dataStartMs) {
      _fetchOlderData(
          DateTime.fromMillisecondsSinceEpoch(event.visibleMinX!.toInt()));
    }
  }

  void _onPanEnd(GraphPanEvent event) => _onPanUpdate(event);

  Future<void> _fetchOlderData(DateTime newStart) async {
    if (_fetchingOlder || _db == null || !mounted) return;
    _fetchingOlder = true;
    try {
      final fetchStart =
          newStart.subtract(_selectedInterval * widget.config.howMany);
      final rows = await _db!.queryTimeseriesData(
        widget.config.key,
        _dataStart,
        from: fetchStart,
        orderBy: 'time ASC',
      );
      if (!mounted) return;
      if (rows.isNotEmpty) {
        _rawTimestamps.insertAll(0, rows.map((r) => r.time).toList());
      }
      _dataStart = fetchStart;
      // Rebuild caches with new historical data
      _bucketCache.clear();
      _openCount.clear();
      _openStartMs.clear();
      _buildCache(_selectedInterval.inMinutes);
      _pushToGraph(_graph, _selectedInterval.inMinutes);
      _buildRemainingCaches();
    } catch (_) {
    } finally {
      _fetchingOlder = false;
    }
  }

  void _onNowPressed() {
    _realTimeActive = true;
    _dataEnd = DateTime.now();
    // Rebuild cache so zero-fill range is anchored to current time
    _buildCache(_selectedInterval.inMinutes);
    _graph.setNowButtonDisabled(true);
    _schedulePoll();
    _pushToGraph(_graph, _selectedInterval.inMinutes);
  }

  void _onSetDatePressed() => _disableRealTime();

  void _disableRealTime() {
    if (!_realTimeActive) return;
    _realTimeActive = false;
    _pollTimer?.cancel();
    _graph.setNowButtonDisabled(false);
  }

  void _changeChartInterval(Duration interval) {
    _selectedInterval = interval;
    final minutes = interval.inMinutes;
    if (!_bucketCache.containsKey(minutes)) _buildCache(minutes);
    // Always create fresh graph so viewport is anchored to "now"
    _graph = _createGraphForInterval(interval);
    _graphs[minutes] = _graph;
    _pushToGraph(_graph, minutes);
    setState(() {});
    if (_realTimeActive) _schedulePoll();
  }

  // --- Helpers ---

  int _rateCount(int minutes) {
    final now = DateTime.now();
    final start = now.subtract(Duration(minutes: minutes));
    int lo = 0, hi = _rawTimestamps.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_rawTimestamps[mid].isBefore(start)) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final loIdx = lo;
    lo = 0;
    hi = _rawTimestamps.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_rawTimestamps[mid].isBefore(now)) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo - loIdx;
  }

  /// Whether a card over the last [minutes] can be believed: there is data,
  /// and it reaches back that far.
  bool _covers(int minutes) {
    if (!_hasData) return false;
    final coverage = _coverageStartMs;
    if (coverage == null) return true;
    return DateTime.now()
            .subtract(Duration(minutes: minutes))
            .millisecondsSinceEpoch >=
        coverage;
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final presets = widget.config.intervalPresets;

    // No spinner standing in for the whole window: the cards, the interval
    // toggle and the chart frame all draw on the first frame, from the
    // readout's seed where there is one, and the fetch fills them in. See
    // [_seedFromReadout].
    return Column(
      children: [
        _buildRateSummary(context, presets),
        const SizedBox(height: 12),
        Row(
          children: [
            const Spacer(),
            if (presets.length > 1)
              ToggleButtons(
                isSelected: presets
                    .map((m) => Duration(minutes: m) == _selectedInterval)
                    .toList(),
                onPressed: (i) =>
                    _changeChartInterval(Duration(minutes: presets[i])),
                borderRadius: BorderRadius.circular(8),
                constraints: const BoxConstraints(minHeight: 36, minWidth: 48),
                children: presets
                    .map((m) => Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          child: Text(_formatIntervalMinutes(m)),
                        ))
                    .toList(),
              ),
            const SizedBox(width: 8),
            IconButton(
              icon: _fetching
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh),
              onPressed: _fetching ? null : _fetchRawData,
              tooltip: 'Refresh',
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          // The seed is drawn and the deep history is still on its way; a
          // chart with nothing in it yet draws this bar itself. No bar, no
          // Stack: the chart is then laid out exactly as it would be without
          // this window's loading state at all. See the note in
          // widgets/graph.dart for what an unconditional Stack cost.
          child: _fetching && _hasData
              ? Stack(
                  fit: StackFit.passthrough,
                  children: [
                    _graph.build(context),
                    const Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                  ],
                )
              : _graph.build(context),
        ),
      ],
    );
  }

  Widget _buildRateSummary(BuildContext context, List<int> presets) {
    return Row(
      children: presets.map((minutes) {
        final count = _rateCount(minutes);
        final r = _rate(count, minutes, bph: widget.config.showBph);
        return Expanded(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
              child: Column(
                children: [
                  Text(
                    _formatIntervalMinutes(minutes),
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    // Past the seed's reach a count is short, not zero: a
                    // dash until the fetch can say.
                    _covers(minutes) ? _formatRate(r) : '–',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  Text(
                    widget.config.unit,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

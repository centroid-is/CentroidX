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
import '../../providers/timeseries_source.dart';
import '../../widgets/graph.dart';
import 'package:tfc/converter/color_converter.dart';
import '../../core/timeseries_source.dart';
// `TimeseriesData` — the sample type both transports answer in.
import 'package:tfc_dart/core/database.dart' show TimeseriesData;

part 'rate_value.g.dart';

/// Compute rate from a raw sum over [windowMinutes].
/// [perHour] == true  → value per hour
/// [perHour] == false → value per minute
double _valueRate(double sum, int windowMinutes, {required bool perHour}) {
  if (windowMinutes <= 0) return 0;
  return perHour ? sum * 60.0 / windowMinutes : sum / windowMinutes.toDouble();
}

String _formatRate(double rate) {
  if (rate == rate.roundToDouble()) return rate.toInt().toString();
  return rate.toStringAsFixed(1);
}

@JsonSerializable(explicitToJson: true)
class RateValueConfig extends BaseAsset {
  @override
  String get displayName => 'Rate Value';
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
  @JsonKey(name: 'show_per_hour', defaultValue: false)
  bool showPerHour;
  @JsonKey(defaultValue: 'kg/min')
  String unit;
  @JsonKey(name: 'interval_variable')
  String? intervalVariable;
  @JsonKey(name: 'decimal_places', defaultValue: 1)
  int decimalPlaces;

  RateValueConfig({
    required this.key,
    this.textColor = Colors.black,
    this.pollInterval = const Duration(seconds: 15),
    this.defaultInterval = 1,
    this.howMany = 20,
    this.graphHeader,
    this.intervalPresets = const [1, 5, 10, 30, 60],
    this.showPerHour = false,
    this.unit = 'kg/min',
    this.intervalVariable,
    this.decimalPlaces = 1,
  });

  RateValueConfig.preview()
      : key = 'key',
        textColor = Colors.black,
        pollInterval = const Duration(seconds: 15),
        defaultInterval = 1,
        howMany = 20,
        intervalPresets = const [1, 5, 10, 30, 60],
        showPerHour = false,
        unit = 'kg/min',
        intervalVariable = null,
        decimalPlaces = 1;

  factory RateValueConfig.fromJson(Map<String, dynamic> json) =>
      _$RateValueConfigFromJson(json);
  @override
  Map<String, dynamic> toJson() => _$RateValueConfigToJson(this);

  @override
  Widget build(BuildContext context) => RateValueWidget(config: this);

  @override
  Widget configure(BuildContext context) =>
      _RateValueConfigEditor(config: this);
}

// ---------------------------------------------------------------------------
// Config editor
// ---------------------------------------------------------------------------

class _RateValueConfigEditor extends ConsumerStatefulWidget {
  final RateValueConfig config;
  const _RateValueConfigEditor({required this.config});

  @override
  ConsumerState<_RateValueConfigEditor> createState() =>
      _RateValueConfigEditorState();
}

class _RateValueConfigEditorState
    extends ConsumerState<_RateValueConfigEditor> {
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
            initialValue: widget.config.decimalPlaces.toString(),
            decoration: const InputDecoration(
              labelText: 'Decimal Places',
              helperText: 'Decimal places for the rate display',
            ),
            keyboardType: TextInputType.number,
            onChanged: (value) {
              final v = int.tryParse(value);
              if (v != null && v >= 0) {
                setState(() => widget.config.decimalPlaces = v);
              }
            },
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
            helperText: 'how often to refresh the rate',
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
              labelText: 'Unit',
              helperText: 'Display unit e.g. "kg/min", "kg/h", "bpm"',
            ),
            onChanged: (value) {
              setState(() => widget.config.unit = value);
            },
          ),
          const SizedBox(height: 16),
          SwitchListTile(
            title: const Text('Calculate Per Hour'),
            subtitle:
                const Text('Off = divide by minutes, On = multiply to hourly'),
            value: widget.config.showPerHour,
            onChanged: (value) =>
                setState(() => widget.config.showPerHour = value),
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

class RateValueWidget extends ConsumerStatefulWidget {
  final RateValueConfig config;
  const RateValueWidget({super.key, required this.config});

  @override
  ConsumerState<RateValueWidget> createState() => _RateValueWidgetState();
}

class _RateValueWidgetState extends ConsumerState<RateValueWidget>
    with TimeseriesNotifyMixin<RateValueWidget> {
  late int _activeInterval;
  double? _sum;

  // ── TimeseriesNotifyMixin overrides ─────────────────────────────────

  @override
  bool get tsCacheValues => true;

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
    final sum = tsCache.sumSince(widget.config.key, since);
    setState(() => _sum = sum);
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
    final rateUnit = widget.config.unit;

    if (widget.config.key == 'key') {
      return _buildDisplay(context, '42 $rateUnit',
          activeInterval: _activeInterval);
    }

    String displayValue = '---';
    if (_sum != null) {
      final r = _valueRate(_sum!, _activeInterval,
          perHour: widget.config.showPerHour);
      displayValue = '${_formatRate(r)} $rateUnit';
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
      title: widget.config.graphHeader ?? widget.config.text ?? 'Rate Value',
      icon: Icons.show_chart,
      size: Size(size.width * 0.7, size.height * 0.7),
      scrollable: false,
      builder: (context) => _RateValueChartView(
        config: widget.config,
        initialInterval: activeInterval,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Dialog view: summary cards + line chart
// ---------------------------------------------------------------------------

class _RateValueChartView extends ConsumerStatefulWidget {
  final RateValueConfig config;
  final int initialInterval;

  const _RateValueChartView(
      {required this.config, required this.initialInterval});

  @override
  ConsumerState<_RateValueChartView> createState() =>
      _RateValueChartViewState();
}

class _RateValueChartViewState extends ConsumerState<_RateValueChartView> {
  late Duration _selectedInterval;
  List<TimeseriesData> _rawData = [];
  bool _isLoading = true;
  late Graph _graph;
  final Map<int, Graph> _graphs = {};
  DateTime _dataStart = DateTime.now();
  DateTime _dataEnd = DateTime.now();
  Timer? _pollTimer;
  bool _realTimeActive = true;
  bool _fetchingOlder = false;
  TimeseriesSource? _source;

  /// Cached finalized (closed) buckets per interval: ms → sum of values.
  final Map<int, List<(int, double)>> _bucketCache = {};

  /// Current open bucket sum & start per interval.
  final Map<int, double> _openSum = {};
  final Map<int, int> _openStartMs = {};

  @override
  void initState() {
    super.initState();
    _selectedInterval = Duration(minutes: widget.initialInterval);
    _graph = _getOrCreateGraph(_selectedInterval.inMinutes);
    // This window is meant to be dragged off the readout and left running, so
    // it has to survive the database coming up after it did. See
    // reinitOnTimeseriesSourceAvailable.
    reinitOnTimeseriesSourceAvailable(
      ref,
      currentSource: () => _source,
      onSourceAvailable: (_) {
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

  Graph _getOrCreateGraph(int intervalMinutes) {
    return _graphs[intervalMinutes] ??=
        _createGraphForInterval(Duration(minutes: intervalMinutes));
  }

  Graph _createGraphForInterval(Duration interval) {
    final xSpan = interval * widget.config.howMany;
    final rateUnit = widget.config.unit;
    return Graph(
      config: GraphConfig(
        type: GraphType.timeseries,
        xAxis: const GraphAxisConfig(unit: ''),
        yAxis: GraphAxisConfig(unit: rateUnit),
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

  double _toDouble(dynamic v) {
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0.0;
  }

  /// Build full bucket cache from raw data for one interval.
  void _buildCache(int minutes) {
    final intervalMs = minutes * 60000;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final openMs = _bucketStart(nowMs, intervalMs);
    final viewStartMs = openMs - (widget.config.howMany - 1) * intervalMs;

    int startMs = viewStartMs;
    if (_rawData.isNotEmpty) {
      final dataMs =
          _bucketStart(_rawData.first.time.millisecondsSinceEpoch, intervalMs);
      if (dataMs < startMs) startMs = dataMs;
    }

    // Sum values per closed bucket
    final sums = <int, double>{};
    double openVal = 0;
    for (final row in _rawData) {
      final b = _bucketStart(row.time.millisecondsSinceEpoch, intervalMs);
      final v = _toDouble(row.value);
      if (b >= openMs) {
        openVal += v;
      } else if (b >= startMs) {
        sums[b] = (sums[b] ?? 0) + v;
      }
    }

    final closed = <(int, double)>[];
    for (var b = startMs; b < openMs; b += intervalMs) {
      closed.add((b, sums[b] ?? 0));
    }

    _bucketCache[minutes] = closed;
    _openSum[minutes] = openVal;
    _openStartMs[minutes] = openMs;
  }

  /// Incrementally ingest new data into all caches.
  void _ingest(List<TimeseriesData> newRows) {
    if (newRows.isEmpty) return;
    _rawData.addAll(newRows);

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
          cache.add((fill, fill == prevOpenMs ? (_openSum[minutes] ?? 0) : 0));
          fill += intervalMs;
        }
        _openSum[minutes] = 0;
        _openStartMs[minutes] = openMs;
      }

      for (final row in newRows) {
        if (row.time.millisecondsSinceEpoch >= openMs) {
          _openSum[minutes] = (_openSum[minutes] ?? 0) + _toDouble(row.value);
        }
      }
    }
  }

  /// Push cached buckets into a Graph as rates.
  void _pushToGraph(Graph graph, int minutes) {
    final cache = _bucketCache[minutes];
    if (cache == null) return;
    final perHour = widget.config.showPerHour;
    final rateUnit =
        perHour ? '${widget.config.unit}/h' : '${widget.config.unit}/min';
    final data = <Map<String, dynamic>>[];
    for (final (ms, sum) in cache) {
      data.add({
        'x': ms.toDouble(),
        'y': _valueRate(sum, minutes, perHour: perHour),
        's': rateUnit,
      });
    }
    // Append open bucket
    final openMs = _openStartMs[minutes];
    if (openMs != null) {
      data.add({
        'x': openMs.toDouble(),
        'y': _valueRate(_openSum[minutes] ?? 0, minutes, perHour: perHour),
        's': rateUnit,
      });
    }
    graph.data.clear();
    if (data.isNotEmpty) graph.addAll(data);
  }

  // ── Init / fetch ──────────────────────────────────────────────────────

  Future<void> _init() async {
    _source = await ref.read(timeseriesSourceProvider.future);
    if (_source == null || !mounted) return;
    await _fetchRawData(showSpinner: true);
    _schedulePoll();
  }

  Future<void> _fetchRawData({bool showSpinner = false}) async {
    if (showSpinner) setState(() => _isLoading = true);
    try {
      if (_source == null || !mounted) return;
      final maxMinutes = widget.config.intervalPresets.reduce(math.max);
      final totalWindow = Duration(minutes: maxMinutes * widget.config.howMany);
      _dataStart = DateTime.now().subtract(totalWindow);
      _dataEnd = DateTime.now();

      final rows = await _source!.queryTimeseriesData(widget.config.key, _dataStart,
          orderBy: 'time ASC');
      if (!mounted) return;

      _rawData = rows;
      _bucketCache.clear();
      _openSum.clear();
      _openStartMs.clear();

      _buildCache(_selectedInterval.inMinutes);
      _isLoading = false;
      _pushToGraph(_graph, _selectedInterval.inMinutes);

      _buildRemainingCaches();
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
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
    if (!_realTimeActive || _source == null || !mounted) return;
    try {
      final rows = await _source!.queryTimeseriesData(
        widget.config.key,
        _dataEnd,
        orderBy: 'time ASC',
      );
      if (!mounted) return;
      _dataEnd = DateTime.now();

      _ingest(rows);
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
    if (_fetchingOlder || _source == null || !mounted) return;
    _fetchingOlder = true;
    try {
      final fetchStart =
          newStart.subtract(_selectedInterval * widget.config.howMany);
      final rows = await _source!.queryTimeseriesData(
        widget.config.key,
        _dataStart,
        from: fetchStart,
        orderBy: 'time ASC',
      );
      if (!mounted) return;
      if (rows.isNotEmpty) {
        _rawData.insertAll(0, rows);
      }
      _dataStart = fetchStart;
      _bucketCache.clear();
      _openSum.clear();
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
    _graph = _createGraphForInterval(interval);
    _graphs[minutes] = _graph;
    _pushToGraph(_graph, minutes);
    setState(() {});
    if (_realTimeActive) _schedulePoll();
  }

  // --- Helpers ---

  double _rateSum(int minutes) {
    final now = DateTime.now();
    final start = now.subtract(Duration(minutes: minutes));
    double sum = 0;
    int lo = 0, hi = _rawData.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_rawData[mid].time.isBefore(start)) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    for (var i = lo; i < _rawData.length; i++) {
      if (_rawData[i].time.isAfter(now)) break;
      sum += _toDouble(_rawData[i].value);
    }
    return sum;
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final presets = widget.config.intervalPresets;

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

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
              icon: _isLoading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh),
              onPressed: _isLoading ? null : _fetchRawData,
              tooltip: 'Refresh',
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(child: _graph.build(context)),
      ],
    );
  }

  Widget _buildRateSummary(BuildContext context, List<int> presets) {
    final rateUnit = widget.config.unit;
    return Row(
      children: presets.map((minutes) {
        final sum = _rateSum(minutes);
        final r = _valueRate(sum, minutes, perHour: widget.config.showPerHour);
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
                    _formatRate(r),
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    rateUnit,
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

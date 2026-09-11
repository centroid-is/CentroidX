import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode;
import 'dart:math' as math;

import 'package:cristalyse/cristalyse.dart' as cs;
import 'package:flutter/material.dart';
import 'package:tfc/widgets/panes/color_picker_dialog.dart';
import 'package:intl/intl.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';
import 'package:tfc/converter/color_converter.dart';
import 'package:tfc_dart/converter/duration_converter.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../../widgets/duration_field.dart';
import 'common.dart';
import 'helper/database_recovery.dart';
import '../../widgets/graph.dart';
import '../../core/timeseries_source.dart';
import '../../providers/timeseries.dart' show kTimeseriesPollInterval;
import '../../providers/timeseries_source.dart';
import '../../providers/state_man.dart';
import 'package:tfc_dart/core/database.dart';

part 'graph.g.dart';

@JsonEnum()
enum Aggregation {
  none,
  minMaxLast,
}

@JsonSerializable(explicitToJson: true)
class GraphSeriesConfig {
  String key;
  String label;
  @OptionalColorConverter()
  Color? color;

  /// Member path plucked out of each stored row, for keys collected with
  /// `sample_members` (one table holding several members per sample — e.g. a
  /// motor's frequency and current). Null charts the row value as-is — the
  /// scalar-series behaviour every existing config has.
  String? member;

  GraphSeriesConfig(
      {required this.key, required this.label, this.color, this.member});

  String get legend => label.isNotEmpty ? label : key;

  factory GraphSeriesConfig.fromJson(Map<String, dynamic> json) =>
      _$GraphSeriesConfigFromJson(json);
  Map<String, dynamic> toJson() => _$GraphSeriesConfigToJson(this);
}

/// Resolves a [GraphSeriesConfig.member] against one stored row value.
///
/// Collected rows cross the database boundary either as decoded maps or as
/// raw JSON text depending on the path (historical query vs. notification
/// payload), so both are accepted. Returns a chartable `num` (bools chart as
/// 1/0), or `null` when the member is absent — that point is dropped.
num? extractSeriesMemberValue(dynamic row, String member) {
  var value = row;
  if (value is String) {
    try {
      value = jsonDecode(value);
    } catch (_) {
      return null;
    }
  }
  if (value is! Map) return null;
  var current = value[member];
  if (current is bool) return current ? 1 : 0;
  if (current is num) return current;
  if (current is String) {
    if (current == 'true') return 1;
    if (current == 'false') return 0;
    return num.tryParse(current);
  }
  return null;
}

@JsonSerializable(explicitToJson: true)
class GraphAssetConfig extends BaseAsset {
  @override
  String get displayName => 'Graph';
  @override
  String get category => 'Visualization';

  @JsonKey(name: 'graph_type')
  GraphType graphType;
  @JsonKey(name: 'primary_series')
  List<GraphSeriesConfig> primarySeries;
  @JsonKey(name: 'secondary_series')
  List<GraphSeriesConfig> secondarySeries;
  @JsonKey(name: 'x_axis')
  GraphAxisConfig xAxis;
  @JsonKey(name: 'y_axis')
  GraphAxisConfig yAxis;
  @JsonKey(name: 'y_axis2')
  GraphAxisConfig? yAxis2;
  @DurationMinutesConverterNonNull()
  @JsonKey(name: 'time_window_min')
  Duration timeWindowMinutes;
  @JsonKey(name: 'header_text')
  String? headerText;
  @JsonKey(defaultValue: Aggregation.none)
  Aggregation aggregation;
  @JsonKey(defaultValue: false)
  bool tooltip;

  GraphAssetConfig({
    this.graphType = GraphType.line,
    List<GraphSeriesConfig>? primarySeries,
    List<GraphSeriesConfig>? secondarySeries,
    GraphAxisConfig? xAxis,
    GraphAxisConfig? yAxis,
    this.yAxis2,
    this.timeWindowMinutes = const Duration(minutes: 10),
    this.headerText,
    this.aggregation = Aggregation.none,
    this.tooltip = false,
  })  : primarySeries = primarySeries ?? [],
        secondarySeries = secondarySeries ?? [],
        xAxis = xAxis ?? GraphAxisConfig(unit: 's'),
        yAxis = yAxis ?? GraphAxisConfig(unit: '');

  @override
  List<String> get allKeys {
    final keys = <String>{};
    for (final series in primarySeries) {
      if (series.key.isNotEmpty) keys.add(series.key);
    }
    for (final series in secondarySeries) {
      if (series.key.isNotEmpty) keys.add(series.key);
    }
    return keys.toList();
  }

  factory GraphAssetConfig.fromJson(Map<String, dynamic> json) =>
      _$GraphAssetConfigFromJson(json);
  @override
  Map<String, dynamic> toJson() => _$GraphAssetConfigToJson(this);

  GraphAssetConfig.preview({String? key})
      : graphType = GraphType.timeseries,
        primarySeries =
            key != null ? [GraphSeriesConfig(key: key, label: '')] : [],
        secondarySeries = [],
        xAxis = GraphAxisConfig(unit: 's'),
        yAxis = GraphAxisConfig(unit: ''),
        timeWindowMinutes = const Duration(minutes: 10),
        aggregation = Aggregation.none,
        tooltip = false;

  @override
  Widget build(BuildContext context) {
    if (primarySeries.isEmpty && secondarySeries.isEmpty) {
      return CustomPaint(painter: _GraphPreviewPainter());
    }
    return GraphAsset(this);
  }

  @override
  Widget configure(BuildContext context) => GraphContentConfig(config: this);

  GraphConfig toGraphConfig({bool legend = true}) => GraphConfig(
        type: graphType,
        xAxis: xAxis,
        yAxis: yAxis,
        yAxis2: yAxis2,
        xSpan: timeWindowMinutes,
        tooltip: tooltip,
        legend: legend,
      );

  Map<String, Color> get colorPalette => Map.fromEntries(
        [...primarySeries, ...secondarySeries]
            .where((e) => e.color != null)
            .map((e) => MapEntry(e.legend, e.color!)),
      );
}

/// Operator wording for a history fetch that failed.
///
/// The database's own message names a relation and an SQLSTATE, which is
/// for us. What the operator needs is which key, and whether it is a matter
/// of configuration (not collected) or of the database being unreachable.
String describeTrendFetchError(String keys, Object e) {
  final text = e.toString();
  if (text.contains('42P01') || text.contains('does not exist')) {
    return 'No history for $keys.\n'
        'There is no table for this key: it is not being collected, or its '
        'collection never started because the PLC does not publish it. '
        'Check the key mapping and the collector.';
  }
  return 'Could not load history for $keys.\n$text';
}

class GraphContentConfig extends StatefulWidget {
  final GraphAssetConfig config;
  const GraphContentConfig({required this.config});

  @override
  State<GraphContentConfig> createState() => GraphContentConfigState();
}

class GraphContentConfigState extends State<GraphContentConfig> {
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height:
          MediaQuery.of(context).size.height * 0.8, // Use 80% of screen height
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButton<GraphType>(
                value: widget.config.graphType,
                onChanged: (value) {
                  setState(() {
                    widget.config.graphType = value!;
                  });
                },
                items: GraphType.values
                    .map((e) => DropdownMenuItem(
                          value: e,
                          child: Text(
                              e.name[0].toUpperCase() + e.name.substring(1)),
                        ))
                    .toList(),
              ),
              const SizedBox(height: 16),
              _buildSeriesSection(
                'Primary Y Series',
                widget.config.primarySeries,
                (updated) =>
                    setState(() => widget.config.primarySeries = updated),
              ),
              const SizedBox(height: 16),
              _buildSeriesSection(
                'Secondary Y Series',
                widget.config.secondarySeries,
                (updated) =>
                    setState(() => widget.config.secondarySeries = updated),
              ),
              const SizedBox(height: 16),
              _buildAxisConfig(
                'X Axis',
                widget.config.xAxis,
                (updated) => setState(() => widget.config.xAxis = updated!),
                showBoolean: false,
              ),
              const SizedBox(height: 16),
              _buildAxisConfig(
                'Y Axis',
                widget.config.yAxis,
                (updated) => setState(() => widget.config.yAxis = updated!),
              ),
              const SizedBox(height: 16),
              _buildAxisConfig(
                'Y Axis 2 (optional)',
                widget.config.yAxis2,
                (updated) => setState(() => widget.config.yAxis2 = updated),
              ),
              const SizedBox(height: 16),
              DurationField(
                value: widget.config.timeWindowMinutes,
                labelText: 'Time Window',
                min: const Duration(minutes: 1),
                max: const Duration(days: 7),
                units: const [
                  DurationUnit.minutes,
                  DurationUnit.hours,
                  DurationUnit.days,
                ],
                // Serialised as whole minutes — see DurationMinutesConverter.
                resolution: const Duration(minutes: 1),
                onChanged: (value) => setState(
                    () => widget.config.timeWindowMinutes = value),
              ),
              const SizedBox(height: 16),
              TextFormField(
                initialValue: widget.config.headerText,
                decoration: const InputDecoration(labelText: 'Header Text'),
                onChanged: (value) {
                  setState(() => widget.config.headerText = value);
                },
              ),
              const SizedBox(height: 16),
              DropdownButton<Aggregation>(
                value: widget.config.aggregation,
                isExpanded: true,
                onChanged: (value) {
                  setState(() {
                    widget.config.aggregation = value!;
                  });
                },
                items: Aggregation.values
                    .map((e) => DropdownMenuItem(
                          value: e,
                          child: Text(e == Aggregation.none
                              ? 'No aggregation'
                              : 'Min / Max / Last'),
                        ))
                    .toList(),
              ),
              const SizedBox(height: 16),
              CheckboxListTile(
                title: const Text('Show Tooltip'),
                value: widget.config.tooltip,
                onChanged: (value) {
                  setState(() => widget.config.tooltip = value ?? false);
                },
              ),
              const SizedBox(height: 16),
              SizeField(
                initialValue: widget.config.size,
                onChanged: (value) =>
                    setState(() => widget.config.size = value),
              ),
              const SizedBox(height: 16),
              CoordinatesField(
                initialValue: widget.config.coordinates,
                onChanged: (c) => setState(() => widget.config.coordinates = c),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSeriesSection(
    String title,
    List<GraphSeriesConfig> series,
    ValueChanged<List<GraphSeriesConfig>> onChanged,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        ...series.asMap().entries.map((entry) {
          final idx = entry.key;
          final config = entry.value;
          return Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          initialValue: config.label,
                          decoration: const InputDecoration(labelText: 'Label'),
                          onChanged: (value) {
                            final updated =
                                List<GraphSeriesConfig>.from(series);
                            updated[idx] = GraphSeriesConfig(
                              key: config.key,
                              label: value,
                              color: config.color,
                              member: config.member,
                            );
                            onChanged(updated);
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.delete),
                        onPressed: () {
                          final updated = List<GraphSeriesConfig>.from(series)
                            ..removeAt(idx);
                          onChanged(updated);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  KeyField(
                    initialValue: config.key,
                    onChanged: (value) {
                      final updated = List<GraphSeriesConfig>.from(series);
                      updated[idx] = GraphSeriesConfig(
                        key: value,
                        label: config.label,
                        color: config.color,
                        member: config.member,
                      );
                      onChanged(updated);
                    },
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    initialValue: config.member ?? '',
                    decoration: const InputDecoration(
                      labelText: 'Struct member (optional)',
                      hintText: 'e.g. p_stat_Frequency',
                      helperText: 'For keys collected with sample_members: '
                          'chart this member out of each stored row.',
                      helperMaxLines: 2,
                    ),
                    onChanged: (value) {
                      final updated = List<GraphSeriesConfig>.from(series);
                      updated[idx] = GraphSeriesConfig(
                        key: config.key,
                        label: config.label,
                        color: config.color,
                        member: value.trim().isEmpty ? null : value.trim(),
                      );
                      onChanged(updated);
                    },
                  ),
                  const SizedBox(height: 8),
                  ColorPickerRow(
                    label: 'Color',
                    color: config.color,
                    onChanged: (color) {
                      final updated = List<GraphSeriesConfig>.from(series);
                      updated[idx] = GraphSeriesConfig(
                        key: config.key,
                        label: config.label,
                        color: color,
                        member: config.member,
                      );
                      onChanged(updated);
                    },
                    onCleared: () {
                      final updated = List<GraphSeriesConfig>.from(series);
                      updated[idx] = GraphSeriesConfig(
                        key: config.key,
                        label: config.label,
                        color: null,
                        member: config.member,
                      );
                      onChanged(updated);
                    },
                  ),
                ],
              ),
            ),
          );
        }),
        TextButton.icon(
          icon: const Icon(Icons.add),
          label: const Text('Add Series'),
          onPressed: () {
            final updated = List<GraphSeriesConfig>.from(series)
              ..add(GraphSeriesConfig(
                key: '',
                label: '',
              ));
            onChanged(updated);
          },
        ),
      ],
    );
  }

  Widget _buildAxisConfig(String label, GraphAxisConfig? axis,
      ValueChanged<GraphAxisConfig?> onChanged,
      {bool showBoolean = true}) {
    axis ??= GraphAxisConfig(unit: '');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Row(
          spacing: 8,
          children: [
            Expanded(
              child: TextFormField(
                initialValue: axis.title,
                decoration: const InputDecoration(labelText: 'Title'),
                onChanged: (value) {
                  onChanged(GraphAxisConfig(
                    title: value,
                    unit: axis!.unit,
                    min: axis.min,
                    max: axis.max,
                    boolean: axis.boolean,
                    integersOnly: axis.integersOnly,
                  ));
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          spacing: 8,
          children: [
            Expanded(
              child: TextFormField(
                initialValue: axis.unit,
                decoration: const InputDecoration(labelText: 'Unit'),
                onChanged: (value) {
                  onChanged(GraphAxisConfig(
                    title: axis!.title,
                    unit: value,
                    min: axis.min,
                    max: axis.max,
                    boolean: axis.boolean,
                    integersOnly: axis.integersOnly,
                  ));
                },
              ),
            ),
            Expanded(
              child: TextFormField(
                initialValue: axis.min?.toString() ?? '',
                decoration: const InputDecoration(labelText: 'Min'),
                keyboardType: TextInputType.number,
                onChanged: (value) {
                  onChanged(GraphAxisConfig(
                    title: axis!.title,
                    unit: axis.unit,
                    min: double.tryParse(value),
                    max: axis.max,
                    boolean: axis.boolean,
                    integersOnly: axis.integersOnly,
                  ));
                },
              ),
            ),
            Expanded(
              child: TextFormField(
                initialValue: axis.max?.toString() ?? '',
                decoration: const InputDecoration(labelText: 'Max'),
                keyboardType: TextInputType.number,
                onChanged: (value) {
                  onChanged(GraphAxisConfig(
                    title: axis!.title,
                    unit: axis.unit,
                    min: axis.min,
                    max: double.tryParse(value),
                    boolean: axis.boolean,
                    integersOnly: axis.integersOnly,
                  ));
                },
              ),
            ),
          ],
        ),
        if (showBoolean) const SizedBox(height: 8),
        if (showBoolean)
          Row(
            children: [
              const Expanded(child: Text('Boolean')),
              const SizedBox(width: 16),
              Switch(
                value: axis.boolean,
                onChanged: (value) {
                  onChanged(GraphAxisConfig(
                      title: axis!.title,
                      unit: axis.unit,
                      min: axis.min,
                      max: axis.max,
                      boolean: value,
                      integersOnly: axis.integersOnly));
                },
              ),
            ],
          ),
        if (showBoolean) const SizedBox(height: 8),
        if (showBoolean)
          Row(
            children: [
              const Expanded(child: Text('Integers Only')),
              const SizedBox(width: 16),
              Checkbox(
                value: axis.integersOnly,
                onChanged: (value) {
                  onChanged(GraphAxisConfig(
                      title: axis!.title,
                      unit: axis.unit,
                      min: axis.min,
                      max: axis.max,
                      boolean: axis.boolean,
                      integersOnly: value ?? false));
                },
              ),
            ],
          ),
      ],
    );
  }
}

/// What a [GraphAsset]'s data actually depends on, as a comparable string.
///
/// Deliberately not the whole `toJson()`: [BaseAsset] serialises the asset's
/// coordinates and size, so dragging a graph around the page editor — or
/// moving the floating dialog it sits in — would read as a config change and
/// re-run every history query. Geometry is layout, not data.
///
/// [resolveKey] is `StateMan.resolveKey`, and its output is part of the
/// signature because a substitution change points an otherwise identical
/// config at different tables. Pass null before StateMan is available; the
/// raw keys stand in until then.
String graphDataSignature(
  GraphAssetConfig config, {
  String Function(String key)? resolveKey,
}) {
  final json = config.toJson()
    ..remove('coordinates')
    ..remove('size')
    ..remove('textPos');
  final resolved = [...config.primarySeries, ...config.secondarySeries]
      .map((s) => resolveKey == null ? s.key : resolveKey(s.key));
  return '${jsonEncode(json)}|${resolved.join(',')}';
}

// The actual widget that displays the graph using the configuration
class GraphAsset extends ConsumerStatefulWidget {
  final GraphAssetConfig config;

  /// Draw for a pane trend tile rather than a full chart: no legend column,
  /// no pan/zoom/now row, and gutters sized for bare tick labels.
  ///
  /// At ~130px tall the buttons and the legend between them take more of the
  /// tile than the plot does. The full chart is one tap away in the floating
  /// dialog, which is where those controls belong.
  final bool compact;

  const GraphAsset(this.config, {this.compact = false, super.key});

  @override
  ConsumerState<GraphAsset> createState() => _GraphAssetState();
}

class _GraphAssetState extends ConsumerState<GraphAsset> {
  static final _log = Logger(printer: SimplePrinter(printTime: false));

  late Graph _graph;
  int _dataMinX;
  int _dataMaxX;
  TimeseriesSource? _source;
  bool _realTimeActive = true;
  final List<StreamSubscription<TimeseriesInsert>> _realtimeSubscriptions = [];
  final _rtThrottleBuffer = List<Map<String, dynamic>>.empty(growable: true);
  Timer? _rtThrottleTimer;
  static const _rtThrottleInterval = Duration(seconds: 1);

  /// The tail poll a source that cannot push is followed with.
  ///
  /// A gateway panel has no LISTEN/NOTIFY (`TimeseriesSource.liveInserts`), so
  /// on that transport this timer is the only thing that ever advances a live
  /// trend. Without it the chart draws its history and then freezes on a
  /// running line — which is worse than an empty chart, because a frozen trend
  /// reads as a stopped machine.
  Timer? _rtPollTimer;

  /// The instant the tail poll has already taken rows up to, so a poll asks
  /// only for what is new. Newest row seen, never `DateTime.now()`: the
  /// collector batches its inserts, and a poll that advanced to "now" would
  /// step over every row whose `time` was still in a batch.
  DateTime? _rtPolledThrough;
  StateMan? _stateMan;
  late cs.ChartTheme _chartTheme;

  /// The visible window size (ms) when data was last fetched with aggregation.
  /// Used to detect zoom changes that require re-fetching at a different bucket resolution.
  double _lastFetchWindowMs = 0;

  /// [_dataSignature] as of the last [_init], so [didUpdateWidget] can tell a
  /// config edit from a plain rebuild. Null until the first init finishes.
  String? _initSignature;

  /// Bumped by every [_init] so a superseded one can bail out at its awaits.
  int _initGeneration = 0;

  _GraphAssetState()
      : _dataMinX = 0,
        _dataMaxX = 0;

  /// The theme to draw with. A compact tile needs its own gutters, or the
  /// tick labels print over the tile caption and the time row.
  cs.ChartTheme _themeFor(cs.ChartTheme base) {
    if (!widget.compact) return base;
    return chartThemeWithPadding(
      base,
      widget.config.yAxis2 != null
          ? kCompactChartPadding
          : kCompactChartPaddingSingleAxis,
    );
  }

  @override
  void initState() {
    super.initState();
    _chartTheme = ref.read(chartThemeNotifierProvider);
    _graph = Graph(
        config: widget.config.toGraphConfig(legend: !widget.compact),
        data: [],
        showButtons: !widget.compact,
        onPanUpdate: _onPanUpdate,
        onPanEnd: _onPanUpdate,
        onNowPressed: _onNowPressed,
        onSetDatePressed: _disableRealtimeUpdates,
        redraw: () {
          if (mounted) {
            setState(() {});
          }
        },
        tooltipBuilder: _buildTooltip,
        categoryColors: widget.config.colorPalette);
    _graph.theme(_themeFor(_chartTheme));
    // The database is regularly not up yet when the first page renders — on a
    // plant-wide power cut Flutter is drawing while Postgres is still
    // replaying WAL. Without this the trend takes the null and stays empty
    // until the station is restarted. Same teardown/rebuild pair
    // didUpdateWidget uses; _init's generation counter settles any overlap.
    reinitOnTimeseriesSourceAvailable(
      ref,
      currentSource: () => _source,
      onSourceAvailable: (_) {
        if (!mounted) return;
        _cleanup();
        _init();
      },
    );
    _init();
  }

  String _dataSignature() => graphDataSignature(
        widget.config,
        resolveKey: _stateMan?.resolveKey,
      );

  Future<void> _init() async {
    // Two inits can overlap — the awaits below are real — and the loser must
    // not stomp the winner's data or leave a stale signature behind.
    final generation = ++_initGeneration;
    _graph = Graph(
        config: widget.config.toGraphConfig(legend: !widget.compact),
        data: [],
        showButtons: !widget.compact,
        onPanUpdate: _onPanUpdate,
        onPanEnd: _onPanUpdate,
        onNowPressed: _onNowPressed,
        onSetDatePressed: _disableRealtimeUpdates,
        redraw: () {
          if (mounted) {
            setState(() {});
          }
        },
        tooltipBuilder: _buildTooltip,
        categoryColors: widget.config.colorPalette);
    _graph.theme(_themeFor(ref.read(chartThemeNotifierProvider)));
    final trendName =
        widget.config.headerText ?? widget.config.allKeys.join(',');
    _log.d('trend "$trendName": init, waiting for state manager');
    _stateMan = await ref.read(stateManProvider.future);
    _log.d('trend "$trendName": waiting for its timeseries source');
    _source = await ref.read(timeseriesSourceProvider.future);
    if (!mounted || generation != _initGeneration) return;
    // Recorded only now: the signature resolves keys through StateMan, which
    // was not available when this init started.
    _initSignature = _dataSignature();
    _log.d('trend "$trendName": querying history');
    final start =
        // 300% of the time window, refer to panUpdate method for more details
        DateTime.now().subtract(widget.config.timeWindowMinutes * 3);
    final end = DateTime.now();
    _dataMinX = start.millisecondsSinceEpoch.toInt();
    _dataMaxX = end.millisecondsSinceEpoch.toInt();
    _lastFetchWindowMs =
        widget.config.timeWindowMinutes.inMilliseconds.toDouble();
    final List<Map<String, dynamic>> initial;
    try {
      initial = await _queryData(DateTimeRange(start: start, end: end));
    } catch (e, st) {
      // Say so on the chart. Left to escape, this was an unhandled async
      // error nobody saw and a spinner that never stopped: "Batcher 4
      // weigher left" sat loading for good because its key is mapped but
      // not collected, so its table was never created.
      _log.w('Trend "${widget.config.headerText ?? ''}" has no data: $e',
          error: e, stackTrace: st);
      if (!mounted || generation != _initGeneration) return;
      final keys = [
        ...widget.config.primarySeries,
        ...widget.config.secondarySeries
      ].map((s) => s.key).join(', ');
      _graph.showError(describeTrendFetchError(keys, e));
      return;
    }
    if (!mounted || generation != _initGeneration) return;
    _log.d('trend "$trendName": ${initial.length} points');
    _addData(initial);
    _realTimeActive = true;
    _initRealtimeUpdates();
  }

  @override
  void didUpdateWidget(GraphAsset oldWidget) {
    super.didUpdateWidget(oldWidget);
    _chartTheme = ref.read(chartThemeNotifierProvider);
    _graph.theme(_chartTheme);

    // The page editor's form mutates the config in place and StateMan
    // substitutions re-point the same config at another table, so there is
    // nothing meaningful to compare by identity — compare what the data
    // actually depends on instead. A rebuild that leaves that untouched (a
    // move, a resize, a parent's setState) keeps the chart it already has,
    // rather than dropping its subscriptions and re-running every history
    // query while the operator watches.
    final signature = _dataSignature();
    if (_initSignature != null && signature == _initSignature) return;

    _cleanup();
    _init();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _graph.theme(_themeFor(ref.watch(chartThemeNotifierProvider)));
  }

  void _initRealtimeUpdates() async {
    _graph.setNowButtonDisabled(_realTimeActive);
    if (!_realTimeActive) return;
    if (_source == null) return; // this should never happen
    final source = _source!;

    /// One arriving row, folded into the throttle buffer. Shared by the push
    /// path and the poll path so the two cannot disagree about how a sample
    /// becomes a point — which member is extracted, which axis it lands on,
    /// and that `_dataMaxX` advances with it.
    void ingest(GraphSeriesConfig series, bool isPrimary, DateTime time,
        Object? raw) {
      dynamic value = raw;
      if (series.member?.isNotEmpty ?? false) {
        value = extractSeriesMemberValue(value, series.member!);
        if (value == null) return;
      }
      _dataMaxX = time.millisecondsSinceEpoch.toInt();
      _rtThrottleBuffer.addAll(_unpackData(time.millisecondsSinceEpoch
          .toDouble(), isPrimary ? 'y' : 'y2', value, series.legend));
    }

    /// The push channel for one series, or **null** when this transport has
    /// none — which is not a failure, and is answered by the tail poll below.
    Future<StreamSubscription<TimeseriesInsert>?> initSeries(
        GraphSeriesConfig series, bool isPrimary) async {
      final tableName = _stateMan!.resolveKey(
          series.key); // would be nice if key would know how to resolve itself
      final stream = await source.liveInserts(tableName);
      if (stream == null) return null;
      return stream.listen(
          (insert) => ingest(series, isPrimary, insert.time, insert.value));
    }

    // if we are already subscribing to realtime updates, don't do it again
    if (_realtimeSubscriptions.isNotEmpty || _rtPollTimer != null) {
      return;
    }

    var pushes = true;
    for (final (series, isPrimary) in [
      for (final s in widget.config.primarySeries) (s, true),
      for (final s in widget.config.secondarySeries) (s, false),
    ]) {
      final subscription = await initSeries(series, isPrimary);
      if (subscription == null) {
        pushes = false;
        break;
      }
      _realtimeSubscriptions.add(subscription);
    }

    if (!pushes) {
      // A source with no push channel: the tail poll IS the live trend. Every
      // series is polled — including any that did hand out a stream before the
      // loop broke, so the two mechanisms never run side by side on one chart
      // and double-count a row.
      for (final subscription in _realtimeSubscriptions) {
        subscription.cancel();
      }
      _realtimeSubscriptions.clear();
      _log.i('trend "${widget.config.headerText ?? widget.config.allKeys.join(',')}": '
          'polling every ${kTimeseriesPollInterval.inSeconds}s — this '
          'station\'s timeseries source has no push channel.');
      _rtPollTimer =
          Timer.periodic(kTimeseriesPollInterval, (_) => _pollRealtimeTail(ingest));
    }

    _rtThrottleTimer = Timer.periodic(_rtThrottleInterval, (timer) {
      if (_rtThrottleBuffer.isNotEmpty && mounted) {
        _addData(_rtThrottleBuffer);
        _rtThrottleBuffer.clear();
        // not strictly correct, but yeah
        _graph.panForward(DateTime.now().millisecondsSinceEpoch.toDouble());
      }
    });

    if (!_realTimeActive) {
      _disableRealtimeUpdates();
    }
  }

  /// One tail poll: everything each series has recorded since the last one.
  ///
  /// The window opens at the newest row already on the chart, so a row the
  /// collector wrote late — its `time` is inside a batch that had not been
  /// flushed when the previous poll ran — is picked up by the next poll rather
  /// than stepped over. Rows that are already on the chart are re-fetched and
  /// re-ingested; that is deliberate, and cheap: the alternative is a poll
  /// that opens at `now` and silently drops whatever the batcher was holding.
  Future<void> _pollRealtimeTail(
      void Function(GraphSeriesConfig, bool, DateTime, Object?) ingest) async {
    final source = _source;
    if (source == null || !mounted || !_realTimeActive) return;
    final since = _rtPolledThrough ??
        DateTime.fromMillisecondsSinceEpoch(_dataMaxX).toUtc();
    DateTime? newest;
    for (final (series, isPrimary) in [
      for (final s in widget.config.primarySeries) (s, true),
      for (final s in widget.config.secondarySeries) (s, false),
    ]) {
      try {
        final rows = await source.queryTimeseriesData(
            _stateMan!.resolveKey(series.key), since,
            orderBy: 'time ASC');
        if (!mounted) return;
        for (final row in rows) {
          if (!row.time.isAfter(since)) continue;
          ingest(series, isPrimary, row.time, row.value);
          if (newest == null || row.time.isAfter(newest)) newest = row.time;
        }
      } catch (e) {
        // Said once per poll and not swallowed silently: on this transport the
        // poll is the only delivery, so a failing one is the whole live trend
        // stopping. The history already drawn stays, exactly as it does when a
        // push channel dies.
        _log.w('trend tail poll for "${series.key}" failed: $e');
      }
    }
    if (newest != null) _rtPolledThrough = newest;
  }

  void _disableRealtimeUpdates() {
    _realTimeActive = false;
    _rtThrottleTimer?.cancel();
    _rtPollTimer?.cancel();
    _rtPollTimer = null;
    _rtPolledThrough = null;
    _rtThrottleBuffer.clear();
    _graph.setNowButtonDisabled(_realTimeActive);
    for (final subscription in _realtimeSubscriptions) {
      subscription.cancel();
    }
    _realtimeSubscriptions.clear();
  }

  void _onNowPressed() {
    _realTimeActive = true;
    _initRealtimeUpdates();
  }

  List<Map<String, dynamic>> _unpackData(
      double x, String axis, dynamic value, String legend) {
    if (value is List) {
      int i = 1;
      return value
          .map((e) => {'x': x, axis: e, 's': "$legend.${i++}"})
          .toList();
    }
    return [
      {'x': x, axis: value, 's': legend}
    ];
  }

  Future<List<Map<String, dynamic>>> _queryData(DateTimeRange range) async {
    if (_source == null) return [];
    final db = _source!;
    final keys = {
      'y': widget.config.primarySeries,
      'y2': widget.config.secondarySeries
    };
    //final allKeys = [...primarySeries, ...secondarySeries];

    //final watch = Stopwatch()..start();

    // final res = await db.queryTimeseriesDataMultiple(allKeys, range.end,
    //     from: range.start);

    //print('queryTimeseriesDataMultiple took ${watch.elapsed}');

    // print('first result: ${res.entries.first.value.first.time}');
    // print('last result: ${res.entries.first.value.last.time}');

    final result = <Map<String, dynamic>>[];

    // for (final foo in res.entries) {
    //   for (final value in foo.value) {
    //     result.add({
    //       'x': value.time.millisecondsSinceEpoch.toDouble(),
    //       'y': value.value, // todo
    //       's': foo.key
    //     });
    //   }
    // }

    for (final entry in keys.entries) {
      final axisKey = entry.key;
      for (final series in entry.value) {
        final tableName = _stateMan!.resolveKey(series.key);
        final List<TimeseriesData<dynamic>> data;
        if (widget.config.aggregation == Aggregation.minMaxLast) {
          data = await db.queryTimeseriesDataDownsampled(
              tableName, range.start, range.end);
        } else {
          data = await db.queryTimeseriesData(tableName, range.end,
              from: range.start);
        }
        for (final e in data) {
          dynamic value = e.value;
          if (series.member?.isNotEmpty ?? false) {
            value = extractSeriesMemberValue(value, series.member!);
            if (value == null) continue;
          } else if (value is bool) {
            value = e.value ? 1.0 : 0.0;
          }
          final x = e.time.millisecondsSinceEpoch.toDouble();
          result.addAll(_unpackData(x, axisKey, value, series.legend));
        }
      }
    }
    return result;
  }

  Widget _buildTooltip(cs.DataPointInfo point) {
    final x = point.xValue as double;
    final config = widget.config;
    final isTimeseries = config.graphType == GraphType.timeseries ||
        config.graphType == GraphType.barTimeseries;
    final xLabel = config.xAxis.title ?? (isTimeseries ? 'Time' : 'X');
    String xStr;
    if (isTimeseries) {
      xStr = DateFormat('HH:mm:ss')
          .format(DateTime.fromMillisecondsSinceEpoch(x.toInt()));
    } else {
      final unit = config.xAxis.unit;
      xStr =
          x == x.roundToDouble() ? x.round().toString() : x.toStringAsFixed(2);
      if (unit.isNotEmpty) xStr = '$xStr $unit';
    }

    // Find nearest point per series
    final nearest = <String, Map<String, dynamic>>{};
    final nearestDist = <String, double>{};
    for (final d in _graph.data) {
      final s = d['s'] as String? ?? '';
      final dx = ((d['x'] as double) - x).abs();
      if (!nearest.containsKey(s) || dx < nearestDist[s]!) {
        nearest[s] = d;
        nearestDist[s] = dx;
      }
    }

    bool hasApprox = false;
    final yUnit = config.yAxis.unit;
    final y2Unit = config.yAxis2?.unit ?? '';
    final rows = nearest.entries.map((e) {
      final isY2 = e.value.containsKey('y2');
      final value = isY2 ? e.value['y2'] : e.value['y'];
      final unit = isY2 ? y2Unit : yUnit;
      String valueStr;
      if (value is num) {
        valueStr = value == value.roundToDouble()
            ? value.round().toString()
            : value.toStringAsFixed(2);
      } else {
        valueStr = value?.toString() ?? 'N/A';
      }
      if (unit.isNotEmpty) valueStr = '$valueStr $unit';
      final approx = nearestDist[e.key]! > 0;
      if (approx) hasApprox = true;
      return Text(
        '${e.key}: ${approx ? '~' : ''}$valueStr',
        style: const TextStyle(color: Colors.white, fontSize: 12),
      );
    }).toList();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$xLabel: $xStr',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
        const Divider(height: 8, color: Colors.white54),
        ...rows,
        if (hasApprox) ...[
          const SizedBox(height: 4),
          Text(
            '~ nearest value to $xLabel',
            style: TextStyle(
                color: Colors.white.withAlpha(150),
                fontSize: 10,
                fontStyle: FontStyle.italic),
          ),
        ],
      ],
    );
  }

  void _addData(List<Map<String, dynamic>> data) {
    _graph.addAll(data);
  }

  Future<void> _onPanUpdate(GraphPanEvent event) async {
    if (event.visibleMinX == null || event.visibleMaxX == null) return;

    // if we are panning to the left, we disable realtime updates
    // apperantly +dx is to the left and -dx is to the right
    if (event.delta != null && event.delta!.dx > 0) {
      _disableRealtimeUpdates();
    }

    // When panning, the data size size will differ
    // To begin with it is 300% and the window shows the real time data

    // Initial data size is 300%
    // X axis
    //
    // | buffer1 | buffer2 |      window     |
    // |   100%  |   100%  |     100%        |
    // Now if we pan into buffer2, it becomes the case below rigth

    // Min data size is 300%
    // X axis
    // | buffer1 |      window     | buffer2 |
    // |   100%  |     100%        |   100%  |
    // Now if we pan into buffer2 we fetch 100% data for that direction, see below

    // Data size is 400%
    // X axis
    // | buffer1 |      window     | buffer2 | buffer3 |
    // |   100%  |     100%        |   100%  |   100%  |

    // Max data size is 500%
    // X axis
    // | buffer1 |      window     | buffer2 |
    // |   200%  |     100%        |   200%  |

    final xWindowSize = event.visibleMaxX! - event.visibleMinX!;

    // When aggregation is active, detect zoom changes that need re-fetching
    // at a different bucket resolution. If window shrunk to <50% or grew to >200%
    // of the last fetch, clear data and re-fetch the visible range + buffers.
    if (widget.config.aggregation != Aggregation.none &&
        _lastFetchWindowMs > 0 &&
        (xWindowSize < _lastFetchWindowMs * 0.5 ||
            xWindowSize > _lastFetchWindowMs * 2.0)) {
      _lastFetchWindowMs = xWindowSize;
      final start = DateTime.fromMillisecondsSinceEpoch(
          (event.visibleMinX! - xWindowSize).toInt());
      final end = DateTime.fromMillisecondsSinceEpoch(math
          .min(event.visibleMaxX! + xWindowSize,
              DateTime.now().millisecondsSinceEpoch.toDouble())
          .toInt());
      // Fetch new data at finer/coarser resolution in the background,
      // keeping old data visible until the new data arrives.
      final data = await _queryData(DateTimeRange(start: start, end: end));
      if (!mounted) return;
      _dataMinX = start.millisecondsSinceEpoch;
      _dataMaxX = end.millisecondsSinceEpoch;
      _graph.removeWhere((_) => true);
      _addData(data);
      return;
    }

    final double mustMin = event.visibleMinX! - xWindowSize * 0.5;
    final double mustMax = math.min(event.visibleMaxX! + xWindowSize * 0.5,
        DateTime.now().millisecondsSinceEpoch.toDouble());
    final double capMin = event.visibleMinX! - xWindowSize * 2.0;
    final double capMax = math.min(event.visibleMaxX! + xWindowSize * 2.0,
        DateTime.now().millisecondsSinceEpoch.toDouble());

    if (_dataMinX > mustMin) {
      // fetch one time window of data
      final end = DateTime.fromMillisecondsSinceEpoch(_dataMinX.toInt());
      final start = end.subtract(widget.config.timeWindowMinutes);
      _dataMinX = start.millisecondsSinceEpoch
          .toInt(); // we only want to query the data once, so if we get subsequent onpanupdate we don't query the same data again
      final data = await _queryData(DateTimeRange(start: start, end: end));
      _addData(data);
    }

    if (_dataMaxX < mustMax) {
      // fetch one time window of data
      final start = DateTime.fromMillisecondsSinceEpoch(_dataMaxX.toInt());
      final end = start.add(widget.config.timeWindowMinutes);
      _dataMaxX = end.millisecondsSinceEpoch.toInt();
      final data = await _queryData(DateTimeRange(start: start, end: end));
      _addData(data);
    }

    // if we are not yet within the must range, we might have jumped back in time or forward in time
    if (_dataMinX > mustMin || _dataMaxX < mustMax) {
      final start = DateTime.fromMillisecondsSinceEpoch(capMin.toInt());
      final end = DateTime.fromMillisecondsSinceEpoch(capMax.toInt());
      _dataMinX = start.millisecondsSinceEpoch.toInt();
      _dataMaxX = end.millisecondsSinceEpoch.toInt();
      final data = await _queryData(DateTimeRange(start: start, end: end));
      _addData(data);
    }

    // --- Prune to stay within the 500% cap ---
    bool removed = false;
    _graph.removeWhere((row) {
      final x = row['x'];
      final out = (x < capMin) || (x > capMax);
      if (out) removed = true;
      return out;
    });

    // Keep trackers consistent with pruning
    if (removed) {
      if (_dataMinX < capMin) _dataMinX = capMin.toInt();
      if (_dataMaxX > capMax) _dataMaxX = capMax.toInt();
    }
  }

  @override
  Widget build(BuildContext context) {
    return _graph.build(context);
  }

  @override
  void dispose() {
    super.dispose();
    _cleanup();
  }

  void _cleanup() {
    for (final subscription in _realtimeSubscriptions) {
      subscription.cancel();
    }
    _realtimeSubscriptions.clear();
    // _initRealtimeUpdates starts a 1 Hz throttle timer and assigns it here
    // unconditionally. Leaving it running orphans one timer per teardown —
    // per dispose, and per didUpdateWidget re-init — each holding this State
    // alive for the life of the process.
    _rtThrottleTimer?.cancel();
    _rtThrottleTimer = null;
    _rtThrottleBuffer.clear();
  }
}

class _GraphPreviewPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final axisPaint = Paint()
      ..color = Colors.grey.shade600
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    // Draw axes
    final left = size.width * 0.12;
    final bottom = size.height * 0.85;
    final right = size.width * 0.95;
    final top = size.height * 0.1;
    canvas.drawLine(Offset(left, top), Offset(left, bottom), axisPaint);
    canvas.drawLine(Offset(left, bottom), Offset(right, bottom), axisPaint);

    // Draw a sample line
    final linePaint = Paint()
      ..color = Colors.blue
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    final path = Path();
    final points = [0.0, 0.3, 0.25, 0.6, 0.5, 0.45, 0.7, 0.8, 0.65, 0.9];
    final w = right - left;
    final h = bottom - top;
    for (int i = 0; i < points.length; i++) {
      final x = left + w * (i / (points.length - 1));
      final y = bottom - h * points[i];
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

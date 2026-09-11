import 'dart:math' as math;
import 'dart:async';
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
import 'package:tfc_dart/converter/duration_converter.dart';
import 'package:tfc_dart/core/database.dart';

part 'ratio_number.g.dart';

@JsonSerializable(explicitToJson: true)
class RatioNumberConfig extends BaseAsset {
  @override
  String get displayName => 'Ratio Number';
  @override
  String get category => 'Text & Numbers';

  String key1;
  String key2;
  @JsonKey(name: 'key1_label')
  String key1Label;
  @JsonKey(name: 'key2_label')
  String key2Label;
  @ColorConverter()
  @JsonKey(name: 'text_color')
  Color textColor;
  @DurationMinutesConverterNonNull()
  @JsonKey(name: 'since_minutes')
  Duration sinceMinutes;
  @JsonKey(name: 'how_many')
  int howMany;
  @JsonKey(name: 'poll_interval')
  Duration pollInterval;
  @JsonKey(name: 'graph_header')
  String? graphHeader;
  @JsonKey(name: 'bars_clock_aligned', defaultValue: false)
  bool barsClockAligned;
  @JsonKey(name: 'integers_only', defaultValue: false)
  bool integersOnly;
  @JsonKey(name: 'bars_interactive', defaultValue: false)
  bool barsInteractive;
  @JsonKey(name: 'interval_presets', defaultValue: [1, 5, 10, 60, 240])
  List<int> intervalPresets;
  @JsonKey(name: 'interval_variable')
  String? intervalVariable;
  @JsonKey(name: 'decimal_places', defaultValue: 1)
  int decimalPlaces;

  RatioNumberConfig({
    required this.key1,
    required this.key2,
    this.key1Label = '',
    this.key2Label = '',
    this.textColor = Colors.black,
    this.sinceMinutes = const Duration(minutes: 10),
    this.howMany = 10,
    this.pollInterval = const Duration(seconds: 1),
    this.graphHeader,
    this.barsClockAligned = false,
    this.integersOnly = false,
    this.barsInteractive = false,
    this.intervalPresets = const [1, 5, 10, 60, 240],
    this.intervalVariable,
    this.decimalPlaces = 1,
  });

  RatioNumberConfig.preview()
      : key1 = "key1",
        key2 = "key2",
        key1Label = "Key 1",
        key2Label = "Key 2",
        textColor = Colors.black,
        sinceMinutes = const Duration(minutes: 10),
        howMany = 10,
        pollInterval = const Duration(seconds: 1),
        barsClockAligned = false,
        integersOnly = false,
        barsInteractive = false,
        intervalPresets = const [1, 5, 10, 60, 240],
        intervalVariable = null,
        decimalPlaces = 1;

  factory RatioNumberConfig.fromJson(Map<String, dynamic> json) =>
      _$RatioNumberConfigFromJson(json);
  Map<String, dynamic> toJson() => _$RatioNumberConfigToJson(this);

  // Helper method to get display label for a key
  String getDisplayLabel(String key) {
    if (key == key1) {
      return key1Label.isNotEmpty ? key1Label : key1;
    } else if (key == key2) {
      return key2Label.isNotEmpty ? key2Label : key2;
    }
    return key;
  }

  @override
  Widget build(BuildContext context) => RatioNumberWidget(config: this);

  @override
  Widget configure(BuildContext context) =>
      _RatioNumberConfigEditor(config: this);
}

class _RatioNumberConfigEditor extends ConsumerStatefulWidget {
  final RatioNumberConfig config;
  const _RatioNumberConfigEditor({required this.config});

  @override
  ConsumerState<_RatioNumberConfigEditor> createState() =>
      _RatioNumberConfigEditorState();
}

class _RatioNumberConfigEditorState
    extends ConsumerState<_RatioNumberConfigEditor> {
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
            initialValue: widget.config.key1,
            onChanged: (value) => setState(() => widget.config.key1 = value),
          ),
          const SizedBox(height: 16),
          TextFormField(
            initialValue: widget.config.key1Label,
            decoration: const InputDecoration(
              labelText: 'Key 1 Label',
              helperText: 'Custom label for Key 1 in legend (optional)',
            ),
            onChanged: (value) =>
                setState(() => widget.config.key1Label = value),
          ),
          const SizedBox(height: 16),
          KeyField(
            initialValue: widget.config.key2,
            onChanged: (value) => setState(() => widget.config.key2 = value),
          ),
          const SizedBox(height: 16),
          TextFormField(
            initialValue: widget.config.key2Label,
            decoration: const InputDecoration(
              labelText: 'Key 2 Label',
              helperText: 'Custom label for Key 2 in legend (optional)',
            ),
            onChanged: (value) =>
                setState(() => widget.config.key2Label = value),
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
              helperText: 'Custom header for the graph dialog (optional)',
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
                  value: widget.config.sinceMinutes,
                  labelText: 'Since',
                  helperText: 'window for counting data points',
                  min: const Duration(minutes: 1),
                  max: const Duration(days: 7),
                  units: const [
                    DurationUnit.minutes,
                    DurationUnit.hours,
                    DurationUnit.days,
                  ],
                  // Serialised as whole minutes.
                  resolution: const Duration(minutes: 1),
                  onChanged: (value) =>
                      setState(() => widget.config.sinceMinutes = value),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _buildIntervalVariableDropdown(),
              ),
            ],
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
          TextFormField(
            initialValue: widget.config.howMany.toString(),
            decoration: const InputDecoration(
              labelText: 'How Many Buckets',
              helperText: 'Number of time buckets for historical data',
            ),
            keyboardType: TextInputType.number,
            onChanged: (value) {
              final howMany = int.tryParse(value);
              if (howMany != null && howMany > 0) {
                setState(() => widget.config.howMany = howMany);
              }
            },
          ),
          const SizedBox(height: 16),
          DurationField(
            value: widget.config.pollInterval,
            labelText: 'Poll Interval',
            helperText: 'how often to refresh the ratio',
            min: const Duration(seconds: 1),
            max: const Duration(hours: 1),
            units: const [DurationUnit.seconds, DurationUnit.minutes],
            onChanged: (value) =>
                setState(() => widget.config.pollInterval = value),
          ),
          const SizedBox(height: 16),
          TextFormField(
            initialValue: widget.config.decimalPlaces.toString(),
            decoration: const InputDecoration(
              labelText: 'Decimal Places',
              helperText: 'Number of digits after the decimal point',
            ),
            keyboardType: TextInputType.number,
            onChanged: (value) {
              final dp = int.tryParse(value);
              if (dp != null && dp >= 0 && dp <= 5) {
                setState(() => widget.config.decimalPlaces = dp);
              }
            },
          ),
          const SizedBox(height: 16),
          SwitchListTile(
            title: const Text('Clock-Aligned Bars'),
            subtitle: const Text(
                'Align bar chart buckets to clock boundaries (e.g. on the hour)'),
            value: widget.config.barsClockAligned,
            onChanged: (value) =>
                setState(() => widget.config.barsClockAligned = value),
          ),
          SwitchListTile(
            title: const Text('Integer Ticks'),
            subtitle:
                const Text('Only show whole numbers on the bar chart Y-axis'),
            value: widget.config.integersOnly,
            onChanged: (value) =>
                setState(() => widget.config.integersOnly = value),
          ),
          SwitchListTile(
            title: const Text('Interactive Bars'),
            subtitle: const Text('Show tooltip on hover/tap in bar chart'),
            value: widget.config.barsInteractive,
            onChanged: (value) =>
                setState(() => widget.config.barsInteractive = value),
          ),
          const SizedBox(height: 16),
          const Text('Available Intervals',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [1, 5, 10, 30, 60, 240, 720, 1440].map((minutes) {
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

/// The interval chips the accept/reject chart's control bar is built from.
///
/// Returned as a list rather than wrapped in a container of their own so a
/// caller can splice them into its layout: the chart's control bar flows them
/// through the same `Wrap` as its chart/table toggle, and a `Wrap` nested in a
/// `Wrap` is handed an unbounded width and cannot reflow. The 3rd-party side
/// pane wraps them itself.
///
/// Shared so the two surfaces cannot drift apart — the pane's picker and the
/// chart it opens must offer the same windows, spelled the same way.
/// [dense] shrinks them for a side pane, where the ladder shares a narrow
/// column with the machine's status diodes and a chip at dialog size pushes
/// those off the bottom of a short screen. Same chips, same wording — only
/// the padding differs.
List<Widget> ratioIntervalChips({
  required List<int> options,
  required int selectedMinutes,
  required ValueChanged<int> onSelected,
  bool dense = false,
}) {
  return [
    for (final minutes in options)
      ChoiceChip(
        label: Text(_formatIntervalMinutes(minutes)),
        selected: minutes == selectedMinutes,
        onSelected: (_) => onSelected(minutes),
        visualDensity: dense ? VisualDensity.compact : null,
        materialTapTargetSize:
            dense ? MaterialTapTargetSize.shrinkWrap : null,
        labelPadding:
            dense ? const EdgeInsets.symmetric(horizontal: 2) : null,
      ),
  ];
}

/// Returns the end of the current clock-aligned bucket.
/// E.g., with a 1-hour interval at 10:35, returns 11:00.
DateTime _clockAlignedEnd(DateTime time, Duration interval) {
  final ms = interval.inMilliseconds;
  final startOfDay = DateTime(time.year, time.month, time.day);
  final msSinceStartOfDay = time.difference(startOfDay).inMilliseconds;
  final bucketStart = (msSinceStartOfDay ~/ ms) * ms;
  return startOfDay.add(Duration(milliseconds: bucketStart + ms));
}

class RatioNumberWidget extends ConsumerStatefulWidget {
  final RatioNumberConfig config;

  /// Counting window imposed from outside the config — the 3rd-party side
  /// pane's window picker.
  ///
  /// Wins over both [RatioNumberConfig.sinceMinutes] and any interval
  /// variable, and is not written back: the config is shared with the readout
  /// painted on the mimic, and an operator widening the pane's view of the
  /// accept rate must not re-scale everyone else's. Null leaves the widget on
  /// its configured window, which is what every other caller gets.
  final Duration? intervalOverride;

  /// Every window [intervalOverride] may be switched to while this widget is
  /// mounted.
  ///
  /// Folded into the mixin's max window so the one historical fetch at init
  /// covers the LARGEST offered window and cache pruning never trims below
  /// it. Without this, picking a window wider than the configured one would
  /// count over a cache that was only ever filled to the narrow one, and the
  /// figure would silently be an average of less than it claims.
  final List<int> intervalOptions;

  const RatioNumberWidget({
    super.key,
    required this.config,
    this.intervalOverride,
    this.intervalOptions = const [],
  });

  @override
  ConsumerState<RatioNumberWidget> createState() => _RatioNumberWidgetState();
}

class _RatioNumberWidgetState extends ConsumerState<RatioNumberWidget>
    with TimeseriesNotifyMixin<RatioNumberWidget> {
  late Duration _activeSinceMinutes;
  int? _count1;
  int? _count2;

  // ── TimeseriesNotifyMixin overrides ─────────────────────────────────

  @override
  List<String> get tsKeys => [widget.config.key1, widget.config.key2];

  @override
  String? get tsIntervalVariable => widget.config.intervalVariable;

  @override
  int get tsMaxWindowMinutes => [
        _activeSinceMinutes.inMinutes,
        ...widget.config.intervalPresets,
        ...widget.intervalOptions,
      ].reduce(math.max);

  @override
  void tsOnIntervalChanged(int minutes) {
    // An externally imposed window outranks the interval variable: the pane
    // picker is the operator asking for THIS window, now.
    if (widget.intervalOverride != null) return;
    final d = Duration(minutes: minutes);
    if (d != _activeSinceMinutes) {
      _activeSinceMinutes = d;
      tsUpdateDisplay();
    }
  }

  @override
  void tsUpdateDisplay() {
    if (!mounted) return;
    final since = DateTime.now().subtract(_activeSinceMinutes);
    final c1 = tsCache.countSince(widget.config.key1, since);
    final c2 = tsCache.countSince(widget.config.key2, since);
    setState(() {
      _count1 = c1;
      _count2 = c2;
    });
    tsScheduleExpiry(_activeSinceMinutes.inMinutes);
  }

  // ── Lifecycle ───────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _activeSinceMinutes = widget.intervalOverride ?? widget.config.sinceMinutes;
    tsInit();
  }

  @override
  void didUpdateWidget(RatioNumberWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    final override = widget.intervalOverride;
    if (override == null || override == oldWidget.intervalOverride) return;
    // Cache-only: the mixin already holds every event back to the widest
    // offered window, so a switch is a recount, not a refetch.
    _activeSinceMinutes = override;
    tsUpdateDisplay();
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
    if (widget.config.key1 == "key1" && widget.config.key2 == "key2") {
      return _buildDisplay(
          context, "${(75.0).toStringAsFixed(widget.config.decimalPlaces)}%",
          activeSinceMinutes: _activeSinceMinutes);
    }

    String displayValue = "---";
    if (_count1 != null && _count2 != null) {
      final total = _count1! + _count2!;
      if (total > 0) {
        displayValue =
            "${(_count1! / total * 100).toStringAsFixed(widget.config.decimalPlaces)}%";
      } else {
        displayValue = "0.0%";
      }
    }

    return _buildDisplay(context, displayValue,
        activeSinceMinutes: _activeSinceMinutes);
  }

  Widget _buildDisplay(BuildContext context, String value,
      {Duration? activeSinceMinutes}) {
    // Laid out at its final size rather than scaled there by a `FittedBox`;
    // see the note on `AutoSizedText` in common.dart.
    Widget displayWidget = AutoSizedText(
      value,
      angleRadians: (widget.config.coordinates.angle ?? 0) * math.pi / 180,
      style: TextStyle(
        color: widget.config.textColor,
      ),
    );

    // Make clickable to show bar chart
    displayWidget = GestureDetector(
      onTap: () => _showBarChartDialog(
          context, activeSinceMinutes ?? widget.config.sinceMinutes),
      child: displayWidget,
    );

    return displayWidget;
  }

  void _showBarChartDialog(
          BuildContext context, Duration activeSinceMinutes) =>
      showRatioAnalysisDialog(context, widget.config,
          interval: activeSinceMinutes);
}

/// Opens the accept/reject analysis window for [config] — the same one the
/// RatioNumber readout opens when tapped.
///
/// Top-level rather than private to the widget's state so other surfaces —
/// the 3rd-party side pane's chart button — can open it without faking a tap
/// on the readout.
///
/// Opens on the tap. It used to await both keys' history first — five hours
/// of raw rows on the plant's checkweighers — so for as long as the database
/// took, the tap did nothing anyone could see, and read as a tap that had
/// missed. The window now opens straight away on what the readout already
/// holds and fills in behind it; see [RatioAnalysisView].
void showRatioAnalysisDialog(BuildContext context, RatioNumberConfig config,
    {Duration? interval}) {
  final size = MediaQuery.of(context).size;
  showFloatingDialog(
    context: context,
    id: 'ratio:${identityHashCode(config)}',
    title: config.graphHeader ?? config.text ?? 'Ratio Analysis',
    icon: Icons.percent,
    size: Size(size.width * 0.7, size.height * 0.7),
    scrollable: false,
    builder: (context) => RatioAnalysisView(
      config: config,
      initialInterval: interval ?? config.sinceMinutes,
    ),
  );
}

class RatioAnalysisView extends ConsumerStatefulWidget {
  final RatioNumberConfig config;

  /// History to open on, for a caller that already has it. Left empty —
  /// which is what [showRatioAnalysisDialog] does — the view seeds itself
  /// from the readout's live cache and fetches the rest.
  final List<TimeseriesData<dynamic>> key1Queue;
  final List<TimeseriesData<dynamic>> key2Queue;
  final Duration? initialInterval;

  const RatioAnalysisView({
    super.key,
    required this.config,
    this.key1Queue = const [],
    this.key2Queue = const [],
    this.initialInterval,
  });

  @override
  ConsumerState<RatioAnalysisView> createState() => _RatioAnalysisViewState();
}

class _RatioAnalysisViewState extends ConsumerState<RatioAnalysisView> {
  bool _showChart = true;
  late Duration _selectedInterval;
  late List<TimeseriesData<dynamic>> _key1Queue;
  late List<TimeseriesData<dynamic>> _key2Queue;
  bool _isLoading = false;

  /// The opening fetch is in flight, with the seed on screen.
  bool _filling = false;

  /// While the queues hold only the readout's seed: the earliest instant the
  /// seed speaks for. Buckets starting before it are drawn empty rather than
  /// short. Null once the queues are the database's answer.
  DateTime? _coverageStart;

  Database? _db;

  // Cache: interval → (key1Data, key2Data)
  final Map<Duration,
          (List<TimeseriesData<dynamic>>, List<TimeseriesData<dynamic>>)>
      _cache = {};

  @override
  void initState() {
    super.initState();
    _selectedInterval = widget.initialInterval ?? widget.config.sinceMinutes;
    if (widget.key1Queue.isNotEmpty || widget.key2Queue.isNotEmpty) {
      _key1Queue = widget.key1Queue;
      _key2Queue = widget.key2Queue;
      _cache[_selectedInterval] = (_key1Queue, _key2Queue);
    } else {
      _seed(_selectedInterval);
    }
    // Opened before the database was up — a power cut brings the HMI back
    // well ahead of Postgres — the window fills in when it arrives instead
    // of staying on the seed. Same contract as the BPM window.
    reinitOnDatabaseAvailable(
      ref,
      currentDatabase: () => _db,
      onDatabaseAvailable: (_) {
        if (mounted) _fill();
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _fill());
  }

  DateTime _endFor(Duration interval) => widget.config.barsClockAligned
      ? _clockAlignedEnd(DateTime.now(), interval)
      : DateTime.now();

  /// Fills the queues for [interval] from the readouts' shared caches, so the
  /// window has bars on its first frame.
  ///
  /// The readout the operator tapped is on [TimeseriesNotifyMixin], which
  /// holds both keys back to its widest interval preset — four hours on the
  /// plant's checkweighers — in the tracker every readout of those keys
  /// shares. That covers every bucket at the short intervals and most of them
  /// at 30 minutes; the fetch replaces it wholesale when it lands.
  ///
  /// The trackers are only read, never created: `ref.exists` first, because
  /// reading an absent one would start a tracker and a history query of its
  /// own. Without one — the window opened from a surface with no readout on
  /// it — every bucket waits for the fetch.
  void _seed(Duration interval) {
    final end = _endFor(interval);
    final want = end.subtract(interval * widget.config.howMany);
    var coverage = want;
    final queues = <List<TimeseriesData<dynamic>>>[];
    for (final key in [widget.config.key1, widget.config.key2]) {
      final provider = timeseriesTrackerProvider(key);
      if (!ref.exists(provider)) {
        _key1Queue = const [];
        _key2Queue = const [];
        _coverageStart = end;
        return;
      }
      final tracker = ref.read(provider);
      final held =
          DateTime.now().subtract(Duration(minutes: tracker.windowMinutes));
      if (held.isAfter(coverage)) coverage = held;
      queues.add([
        // Newest first, the order the query answers in.
        for (final (time, value)
            in tracker.cache.valuesSince(key, want).reversed)
          TimeseriesData<dynamic>(value, time),
      ]);
    }
    _key1Queue = queues[0];
    _key2Queue = queues[1];
    _coverageStart = coverage.isAfter(want) ? coverage : null;
  }

  /// The opening fetch: the database's answer for the interval on screen,
  /// which replaces the seed wholesale — it covers everything the seed did,
  /// so nothing is kept and nothing is counted twice. Then the other
  /// presets, in the background, as before.
  Future<void> _fill() async {
    final db = await ref.read(databaseProvider.future);
    if (db == null || !mounted) return;
    _db = db;
    final interval = _selectedInterval;
    if (!_cache.containsKey(interval)) {
      setState(() => _filling = true);
      final data = await _fetchForInterval(db, interval);
      if (!mounted) return;
      _cache[interval] = data;
      setState(() {
        _filling = false;
        if (_selectedInterval == interval) {
          _key1Queue = data.$1;
          _key2Queue = data.$2;
          _coverageStart = null;
        }
      });
    }
    await _prefetchAll();
  }

  Future<void> _prefetchAll() async {
    final db = await ref.read(databaseProvider.future);
    if (db == null || !mounted) return;
    final presets =
        widget.config.intervalPresets.map((m) => Duration(minutes: m)).toList();
    for (final interval in presets) {
      if (_cache.containsKey(interval)) continue;
      final data = await _fetchForInterval(db, interval);
      if (!mounted) return;
      _cache[interval] = data;
    }
  }

  Future<(List<TimeseriesData<dynamic>>, List<TimeseriesData<dynamic>>)>
      _fetchForInterval(Database db, Duration interval) async {
    final endTime = _endFor(interval);
    final since = interval * widget.config.howMany;
    Future<List<TimeseriesData<dynamic>>> safeQuery(String key) async {
      try {
        return await db.queryTimeseriesData(key, endTime.subtract(since),
            orderBy: 'time DESC');
      } catch (_) {
        return [];
      }
    }

    final results = await Future.wait([
      safeQuery(widget.config.key1),
      safeQuery(widget.config.key2),
    ]);
    return (results[0], results[1]);
  }

  Future<void> _fetchData() async {
    setState(() => _isLoading = true);
    try {
      final db = await ref.read(databaseProvider.future);
      if (db == null) {
        // Left spinning, the refresh button stayed disabled for good.
        if (mounted) setState(() => _isLoading = false);
        return;
      }
      // Fetch current view first
      final data = await _fetchForInterval(db, _selectedInterval);
      if (!mounted) return;
      _cache[_selectedInterval] = data;
      setState(() {
        _key1Queue = data.$1;
        _key2Queue = data.$2;
        _coverageStart = null;
        _isLoading = false;
      });
      // Then refresh all other cached intervals in background
      final presets = widget.config.intervalPresets
          .map((m) => Duration(minutes: m))
          .toList();
      for (final interval in presets) {
        if (interval == _selectedInterval) continue;
        final other = await _fetchForInterval(db, interval);
        if (!mounted) return;
        _cache[interval] = other;
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _changeInterval(Duration interval) {
    _selectedInterval = interval;
    final cached = _cache[interval];
    if (cached != null) {
      setState(() {
        _key1Queue = cached.$1;
        _key2Queue = cached.$2;
        _coverageStart = null;
      });
    } else {
      // Not fetched yet: draw what the readout holds for it, then fetch.
      setState(() => _seed(interval));
      _fetchData();
    }
  }

  @override
  Widget build(BuildContext context) {
    final presets =
        widget.config.intervalPresets.map((m) => Duration(minutes: m)).toList();

    return Column(
      children: [
        // Control bar. A single flowing row rather than the centred Stack
        // this used to be: the chart/table toggle was painted ON TOP of the
        // interval row, so shrinking the window slid it straight over the
        // interval picker. A Wrap reflows onto a second line instead, and
        // every control here is narrower than the 320px the floating dialog
        // can be dragged down to, so nothing can overflow its own line.
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            // Chips, not a ToggleButtons: six intervals in one indivisible
            // widget is wider than a shrunk dialog, and chips wrap. Same
            // idiom as the config editor's interval ladder, and the same
            // chips the 3rd-party side pane offers.
            if (presets.length > 1)
              ...ratioIntervalChips(
                options: widget.config.intervalPresets,
                selectedMinutes: _selectedInterval.inMinutes,
                onSelected: (m) => _changeInterval(Duration(minutes: m)),
              ),
            ToggleButtons(
              isSelected: [_showChart, !_showChart],
              onPressed: (index) {
                setState(() => _showChart = index == 0);
              },
              borderRadius: BorderRadius.circular(8),
              constraints: const BoxConstraints(minHeight: 36, minWidth: 48),
              children: const [
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.bar_chart, size: 18),
                      SizedBox(width: 4),
                      Text('Chart'),
                    ],
                  ),
                ),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.table_chart, size: 18),
                      SizedBox(width: 4),
                      Text('Table'),
                    ],
                  ),
                ),
              ],
            ),
            IconButton(
              icon: _isLoading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh),
              onPressed: _isLoading ? null : _fetchData,
              tooltip: 'Refresh',
            ),
          ],
        ),
        const SizedBox(height: 16),
        // Content area
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: _showChart
                    ? RatioBarChart(
                        config: widget.config,
                        key1Queue: _key1Queue,
                        key2Queue: _key2Queue,
                        intervalOverride: _selectedInterval,
                        coverageStart: _coverageStart,
                      )
                    : RatioTableView(
                        config: widget.config,
                        key1Queue: _key1Queue,
                        key2Queue: _key2Queue,
                      ),
              ),
              // The seed is on screen and the database's answer is on its
              // way: say so along the top edge, without covering the bars.
              if (_filling || _isLoading)
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: LinearProgressIndicator(minHeight: 2),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class RatioTableView extends StatefulWidget {
  final RatioNumberConfig config;
  final List<TimeseriesData<dynamic>> key1Queue;
  final List<TimeseriesData<dynamic>> key2Queue;

  const RatioTableView({
    super.key,
    required this.config,
    required this.key1Queue,
    required this.key2Queue,
  });

  @override
  State<RatioTableView> createState() => _RatioTableViewState();
}

class _RatioTableViewState extends State<RatioTableView> {
  String?
      _activeFilter; // null = no filter, 'key1' = filter by key1, 'key2' = filter by key2

  @override
  Widget build(BuildContext context) {
    // Combine and sort all data points by time
    final allData = <_TableRow>[];

    for (final dataPoint in widget.key1Queue) {
      allData.add(_TableRow(
        time: dataPoint.time,
        key: widget.config.getDisplayLabel(widget.config.key1),
        value: dataPoint.value.toString(),
        color: Colors.blue,
        keyType: 'key1',
      ));
    }

    for (final dataPoint in widget.key2Queue) {
      allData.add(_TableRow(
        time: dataPoint.time,
        key: widget.config.getDisplayLabel(widget.config.key2),
        value: dataPoint.value.toString(),
        color: Colors.red,
        keyType: 'key2',
      ));
    }

    // Sort by time (newest first)
    allData.sort((a, b) => b.time.compareTo(a.time));

    // Apply filter if active
    final filteredData = _activeFilter == null
        ? allData
        : allData.where((row) => row.keyType == _activeFilter).toList();

    return SingleChildScrollView(
      child: Column(
        children: [
          // Summary row
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildSummaryItem(
                    context,
                    widget.config.getDisplayLabel(widget.config.key1),
                    widget.key1Queue.length,
                    Colors.blue,
                    'key1',
                  ),
                  _buildSummaryItem(
                    context,
                    widget.config.getDisplayLabel(widget.config.key2),
                    widget.key2Queue.length,
                    Colors.red,
                    'key2',
                  ),
                  _buildSummaryItem(
                    context,
                    'Total',
                    widget.key1Queue.length + widget.key2Queue.length,
                    Colors.grey,
                    null,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Data table - now spans full width
          Card(
            child: SizedBox(
              width: double.infinity,
              child: DataTable(
                columnSpacing: 20,
                columns: const [
                  DataColumn(label: Text('Time')),
                  DataColumn(label: Text('Key')),
                  DataColumn(label: Text('Value')),
                ],
                rows: filteredData.map((row) {
                  return DataRow(
                    cells: [
                      DataCell(Text(_formatDateTime(row.time))),
                      DataCell(
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: row.color.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: row.color),
                          ),
                          child: Text(
                            row.key,
                            style: TextStyle(
                              color: row.color,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                      DataCell(Text(row.value)),
                    ],
                  );
                }).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryItem(BuildContext context, String label, int count,
      Color color, String? filterKey) {
    final isActive = _activeFilter == filterKey;

    return GestureDetector(
      onTap: () {
        setState(() {
          _activeFilter = isActive ? null : filterKey;
        });
      },
      child: Column(
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                ),
          ),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: isActive ? color : color.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: color),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                color: isActive ? Colors.white : color,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDateTime(DateTime dateTime) {
    return '${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}:${dateTime.second.toString().padLeft(2, '0')}';
  }
}

// Helper class for table rows
class _TableRow {
  final DateTime time;
  final String key;
  final String value;
  final Color color;
  final String keyType; // 'key1' or 'key2' for filtering

  _TableRow({
    required this.time,
    required this.key,
    required this.value,
    required this.color,
    required this.keyType,
  });
}

class RatioBarChart extends ConsumerWidget {
  final RatioNumberConfig config;
  final List<TimeseriesData<dynamic>> key1Queue;
  final List<TimeseriesData<dynamic>> key2Queue;
  final Duration? intervalOverride;

  /// The earliest instant the queues speak for, while they are a seed from
  /// the readout rather than the database's answer. A bucket starting before
  /// it is drawn empty — its bar would be short, then jump when the fetch
  /// lands — and the bucket axis stays the same either way, so nothing moves
  /// when it does.
  final DateTime? coverageStart;

  const RatioBarChart({
    super.key,
    required this.config,
    required this.key1Queue,
    required this.key2Queue,
    this.intervalOverride,
    this.coverageStart,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Create time buckets for the historical data
    final buckets = _createTimeBuckets();
    final key1Data = _aggregateDataByBucket(key1Queue, buckets);
    final key2Data = _aggregateDataByBucket(key2Queue, buckets);

    final data = <Map<String, dynamic>>[];
    for (final entry in key1Data.entries) {
      data.add({
        'x': entry.key.millisecondsSinceEpoch.toDouble(),
        'y': entry.value.toDouble(),
        's': config.getDisplayLabel(config.key1),
      });
    }
    for (final entry in key2Data.entries) {
      data.add({
        'x': entry.key.millisecondsSinceEpoch.toDouble(),
        'y': entry.value.toDouble(),
        's': config.getDisplayLabel(config.key2),
      });
    }

    final key1Label = config.getDisplayLabel(config.key1);
    final key2Label = config.getDisplayLabel(config.key2);

    return Graph(
      config: GraphConfig(
        type: GraphType.barTimeseries,
        xAxis: GraphAxisConfig(unit: ''),
        yAxis:
            GraphAxisConfig(unit: 'Count', integersOnly: config.integersOnly),
        pan: false,
        tooltip: config.barsInteractive,
        width: 0.5,
      ),
      data: data,
      showButtons: false,
      chartTheme: ref.watch(chartThemeNotifierProvider),
      redraw: () {},
      tooltipBuilder: (point) {
        final x = point.xValue as double;
        // Find both series for this time bucket
        final match1 = data.where((d) => d['x'] == x && d['s'] == key1Label);
        final match2 = data.where((d) => d['x'] == x && d['s'] == key2Label);
        final v1 =
            match1.isNotEmpty ? (match1.first['y'] as double).round() : 0;
        final v2 =
            match2.isNotEmpty ? (match2.first['y'] as double).round() : 0;
        final total = v1 + v2;
        final pct = total > 0
            ? (v1 / total * 100).toStringAsFixed(config.decimalPlaces)
            : (0.0).toStringAsFixed(config.decimalPlaces);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$key1Label: $v1',
                style: const TextStyle(color: Colors.white, fontSize: 12)),
            Text('$key2Label: $v2',
                style: const TextStyle(color: Colors.white, fontSize: 12)),
            const Divider(height: 8, color: Colors.white54),
            Text('Ratio: $pct%',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold)),
          ],
        );
      },
    ).build(context);
  }

  List<DateTime> _createTimeBuckets() {
    final buckets = <DateTime>[];
    final bucketDuration = intervalOverride ?? config.sinceMinutes;
    final endTime = config.barsClockAligned
        ? _clockAlignedEnd(DateTime.now(), bucketDuration)
        : DateTime.now();

    for (int i = config.howMany - 1; i >= 0; i--) {
      final bucketStart = endTime.subtract(bucketDuration * (i + 1));
      buckets.add(bucketStart);
    }

    return buckets;
  }

  Map<DateTime, int> _aggregateDataByBucket(
      List<TimeseriesData<dynamic>> dataPoints, List<DateTime> buckets) {
    final result = <DateTime, int>{};

    for (final bucket in buckets) {
      if (coverageStart != null && bucket.isBefore(coverageStart!)) {
        result[bucket] = 0;
        continue;
      }
      final bucketEnd = bucket.add(intervalOverride ?? config.sinceMinutes);
      final count = dataPoints
          .where((point) =>
              point.time.isAfter(bucket) && point.time.isBefore(bucketEnd))
          .length;
      result[bucket] = count;
    }

    return result;
  }
}

import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:rxdart/rxdart.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;

import 'package:tfc/widgets/number_slider.dart';
import 'common.dart';
import '../../providers/collector.dart';
import '../../providers/state_man.dart';
import 'package:tfc_dart/core/collector.dart';
import 'package:tfc_dart/core/database.dart' show TimeseriesData;
import 'package:tfc/converter/color_converter.dart';
import 'graph.dart';
import '../../widgets/graph.dart';
import '../../widgets/panes/pane_chrome.dart';
import '../../widgets/panes/side_pane.dart';
import '../../widgets/tag_access_guard.dart';

part 'analog_box.g.dart';

/// CONFIG

@JsonSerializable(explicitToJson: true)
class AnalogBoxConfig extends BaseAsset {
  @override
  String get displayName => 'Analog Box';
  @override
  String get category => 'Text & Numbers';

  /// Live analog value source
  @JsonKey(name: 'analog_key')
  String analogKey;

  @JsonKey(name: 'analog_sensor_range_min_key')
  String? analogSensorRangeMinKey;
  @JsonKey(name: 'analog_sensor_range_max_key')
  String? analogSensorRangeMaxKey;

  /// Optional keys for setpoints / hysteresis (writeable)
  @JsonKey(name: 'setpoint1_key')
  String? setpoint1Key;
  @JsonKey(name: 'setpoint1_hysteresis_key')
  String? setpoint1HysteresisKey; // +/- around setpoint1
  @JsonKey(name: 'setpoint2_key')
  String? setpoint2Key;

  /// Error indicator
  @JsonKey(name: 'error_key')
  String? errorKey;

  /// Min/max scaling
  @JsonKey(name: 'min_value')
  double minValue;
  @JsonKey(name: 'max_value')
  double maxValue;

  /// Visual / UX
  String? units;
  @JsonKey(name: 'range_units')
  String? rangeUnits; // Units for range min/max, falls back to units
  @JsonKey(name: 'border_radius_pct')
  double borderRadiusPct; // relative to shortest side (0..0.5)
  bool vertical; // vertical tank-style; if false, horizontal bar
  @JsonKey(name: 'reverse_fill')
  bool
      reverseFill; // low at bottom vs top (for vertical), left vs right (horizontal)

  /// Colors
  @JsonKey(name: 'bg_color')
  @ColorConverter()
  Color bgColor;
  @JsonKey(name: 'fill_color')
  @ColorConverter()
  Color fillColor;
  @JsonKey(name: 'sp1_color')
  @ColorConverter()
  Color setpoint1Color;
  @JsonKey(name: 'sp2_color')
  @ColorConverter()
  Color setpoint2Color;
  @JsonKey(name: 'hyst_color')
  @ColorConverter()
  Color hysteresisColor;

  /// Whether tapping opens the detail side pane. The JSON key predates the
  /// dialog→pane conversion and is kept for persisted pages.
  @JsonKey(name: 'enable_dialog')
  bool enableDialog;

  /// Pane: include the trend tile (small preview, full chart behind a tap)
  @JsonKey(name: 'graph_config')
  GraphAssetConfig? graphConfig;

  AnalogBoxConfig({
    required this.analogKey,
    this.analogSensorRangeMinKey,
    this.analogSensorRangeMaxKey,
    this.setpoint1Key,
    this.setpoint1HysteresisKey,
    this.setpoint2Key,
    this.errorKey,
    this.minValue = 0,
    this.maxValue = 100,
    this.units,
    this.rangeUnits,
    this.borderRadiusPct = .15,
    this.vertical = true,
    this.reverseFill = false,
    this.bgColor = const Color(0xFFEFEFEF),
    this.fillColor = const Color(0xFF6EC1E4),
    this.setpoint1Color = Colors.red,
    this.setpoint2Color = Colors.orange,
    this.hysteresisColor = const Color(0x44FF0000),
    this.enableDialog = true,
    this.graphConfig,
  });

  AnalogBoxConfig.preview()
      : analogKey = 'AnalogBox preview',
        minValue = 0,
        maxValue = 100,
        units = 'bar',
        rangeUnits = null,
        borderRadiusPct = .18,
        vertical = true,
        reverseFill = false,
        bgColor = const Color(0xFFEFEFEF),
        fillColor = const Color(0xFF6EC1E4),
        setpoint1Color = Colors.red,
        setpoint2Color = Colors.orange,
        hysteresisColor = const Color(0x44FF0000),
        errorKey = null,
        enableDialog = true,
        graphConfig = GraphAssetConfig.preview();

  /// The scale, shape and colours — everything about how the bar reads that
  /// is worth setting on a row of them at once. The OPC UA keys are left to
  /// the per-asset form: pointing eight boxes at one tag is a mistake that
  /// looks like eight working boxes.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  List<BulkProperty> get bulkProperties => [
        ...super.bulkProperties,
        NumberBulkProperty(
          id: 'AnalogBoxConfig.minValue',
          label: 'Min value',
          group: _bulkGroup,
          read: () => minValue,
          apply: (value) => minValue = (value ?? minValue).toDouble(),
        ),
        NumberBulkProperty(
          id: 'AnalogBoxConfig.maxValue',
          label: 'Max value',
          group: _bulkGroup,
          read: () => maxValue,
          apply: (value) => maxValue = (value ?? maxValue).toDouble(),
        ),
        TextBulkProperty(
          id: 'AnalogBoxConfig.units',
          label: 'Units',
          group: _bulkGroup,
          read: () => units,
          apply: (value) => units = value,
        ),
        TextBulkProperty(
          id: 'AnalogBoxConfig.rangeUnits',
          label: 'Range units',
          group: _bulkGroup,
          read: () => rangeUnits,
          apply: (value) => rangeUnits = value,
        ),
        NumberBulkProperty(
          id: 'AnalogBoxConfig.borderRadiusPct',
          label: 'Corner radius',
          group: _bulkGroup,
          unit: '%',
          // The field is a fraction of the shortest side, capped at a half —
          // beyond that the "rounded rectangle" is a stadium and further
          // values do nothing visible.
          min: 0,
          max: 50,
          read: () => borderRadiusPct * 100,
          apply: (value) => borderRadiusPct = (value ?? 0) / 100,
        ),
        BoolBulkProperty(
          id: 'AnalogBoxConfig.vertical',
          label: 'Vertical',
          group: _bulkGroup,
          read: () => vertical,
          apply: (value) => vertical = value,
        ),
        BoolBulkProperty(
          id: 'AnalogBoxConfig.reverseFill',
          label: 'Reverse fill',
          group: _bulkGroup,
          read: () => reverseFill,
          apply: (value) => reverseFill = value,
        ),
        BoolBulkProperty(
          id: 'AnalogBoxConfig.enableDialog',
          label: 'Opens pane',
          group: _bulkGroup,
          read: () => enableDialog,
          apply: (value) => enableDialog = value,
        ),
        ColorBulkProperty(
          id: 'AnalogBoxConfig.bgColor',
          label: 'Background',
          group: _bulkGroup,
          read: () => bgColor,
          apply: (value) => bgColor = value ?? bgColor,
        ),
        ColorBulkProperty(
          id: 'AnalogBoxConfig.fillColor',
          label: 'Fill',
          group: _bulkGroup,
          read: () => fillColor,
          apply: (value) => fillColor = value ?? fillColor,
        ),
        ColorBulkProperty(
          id: 'AnalogBoxConfig.setpoint1Color',
          label: 'Setpoint 1',
          group: _bulkGroup,
          read: () => setpoint1Color,
          apply: (value) => setpoint1Color = value ?? setpoint1Color,
        ),
        ColorBulkProperty(
          id: 'AnalogBoxConfig.setpoint2Color',
          label: 'Setpoint 2',
          group: _bulkGroup,
          read: () => setpoint2Color,
          apply: (value) => setpoint2Color = value ?? setpoint2Color,
        ),
        ColorBulkProperty(
          id: 'AnalogBoxConfig.hysteresisColor',
          label: 'Hysteresis',
          group: _bulkGroup,
          read: () => hysteresisColor,
          apply: (value) => hysteresisColor = value ?? hysteresisColor,
        ),
      ];

  static const String _bulkGroup = 'Analog Box';

  factory AnalogBoxConfig.fromJson(Map<String, dynamic> json) =>
      _$AnalogBoxConfigFromJson(json);
  Map<String, dynamic> toJson() => _$AnalogBoxConfigToJson(this);

  @override
  Widget build(BuildContext context) => AnalogBox(config: this);

  @override
  Widget configure(BuildContext context) =>
      _AnalogBoxConfigEditor(config: this);
}

/// CONFIG UI

class _AnalogBoxConfigEditor extends StatefulWidget {
  final AnalogBoxConfig config;
  const _AnalogBoxConfigEditor({required this.config});

  @override
  State<_AnalogBoxConfigEditor> createState() => _AnalogBoxConfigEditorState();
}

class _AnalogBoxConfigEditorState extends State<_AnalogBoxConfigEditor> {
  bool showGraph = false;

  @override
  void initState() {
    super.initState();
    showGraph = widget.config.graphConfig != null;
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // LEFT: core config
          Expanded(
            flex: 2,
            child: Column(
              children: [
                KeyField(
                  initialValue: widget.config.analogKey,
                  onChanged: (v) => setState(() => widget.config.analogKey = v),
                  label: 'Analog value key',
                ),
                const SizedBox(height: 12),
                KeyField(
                  initialValue: widget.config.analogSensorRangeMinKey,
                  onChanged: (v) =>
                      setState(() => widget.config.analogSensorRangeMinKey = v),
                  label: 'Analog sensor range min key (optional)',
                ),
                const SizedBox(height: 8),
                KeyField(
                  initialValue: widget.config.analogSensorRangeMaxKey,
                  onChanged: (v) =>
                      setState(() => widget.config.analogSensorRangeMaxKey = v),
                  label: 'Analog sensor range max key (optional)',
                ),
                const SizedBox(height: 8),
                KeyField(
                  initialValue: widget.config.setpoint1Key,
                  onChanged: (v) =>
                      setState(() => widget.config.setpoint1Key = v),
                  label: 'Setpoint 1 key (optional)',
                ),
                const SizedBox(height: 8),
                KeyField(
                  initialValue: widget.config.setpoint1HysteresisKey,
                  onChanged: (v) =>
                      setState(() => widget.config.setpoint1HysteresisKey = v),
                  label: 'Setpoint 1 hysteresis key (optional, ±)',
                ),
                const SizedBox(height: 8),
                KeyField(
                  initialValue: widget.config.setpoint2Key,
                  onChanged: (v) =>
                      setState(() => widget.config.setpoint2Key = v),
                  label: 'Setpoint 2 key (optional)',
                ),
                const SizedBox(height: 8),
                KeyField(
                  initialValue: widget.config.errorKey,
                  onChanged: (v) => setState(() => widget.config.errorKey = v),
                  label:
                      'Error key (optional, red border when true / non-zero)',
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        initialValue: widget.config.minValue.toString(),
                        decoration: InputDecoration(
                          labelText: 'Min value',
                          helperText: widget.config.analogSensorRangeMinKey
                                      ?.isNotEmpty ==
                                  true
                              ? 'Using dynamic value from ${widget.config.analogSensorRangeMinKey}'
                              : null,
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        onChanged: (v) {
                          final d = double.tryParse(v);
                          if (d != null) {
                            setState(() => widget.config.minValue = d);
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        initialValue: widget.config.maxValue.toString(),
                        decoration: InputDecoration(
                          labelText: 'Max value',
                          helperText: widget.config.analogSensorRangeMaxKey
                                      ?.isNotEmpty ==
                                  true
                              ? 'Using dynamic value from ${widget.config.analogSensorRangeMaxKey}'
                              : null,
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        onChanged: (v) {
                          final d = double.tryParse(v);
                          if (d != null) {
                            setState(() => widget.config.maxValue = d);
                          }
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  initialValue: widget.config.units,
                  decoration: const InputDecoration(labelText: 'Units'),
                  onChanged: (v) => setState(() => widget.config.units = v),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  initialValue: widget.config.rangeUnits,
                  decoration: InputDecoration(
                    labelText: 'Range units',
                    helperText:
                        'Optional: units for range min/max values (falls back to main units)',
                  ),
                  onChanged: (v) =>
                      setState(() => widget.config.rangeUnits = v),
                ),
                const SizedBox(height: 12),
                NumberSlider(
                  label: 'Radius',
                  min: 0,
                  max: .5,
                  divisions: 50,
                  displayScale: 100,
                  suffix: '%',
                  value: widget.config.borderRadiusPct,
                  onChanged: (v) =>
                      setState(() => widget.config.borderRadiusPct = v),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  title: const Text('Vertical'),
                  value: widget.config.vertical,
                  onChanged: (b) => setState(() => widget.config.vertical = b),
                ),
                SwitchListTile(
                  title: const Text('Reverse fill direction'),
                  subtitle: const Text(
                      'Top→bottom (vertical) / Right→left (horizontal)'),
                  value: widget.config.reverseFill,
                  onChanged: (b) =>
                      setState(() => widget.config.reverseFill = b),
                ),
                const SizedBox(height: 12),
                CoordinatesField(
                  initialValue: widget.config.coordinates,
                  onChanged: (c) =>
                      setState(() => widget.config.coordinates = c),
                  enableAngle: true,
                ),
                const SizedBox(height: 12),
                SizeField(
                  initialValue: widget.config.size,
                  onChanged: (s) => setState(() => widget.config.size = s),
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  title: const Text('Enable tap pane'),
                  value: widget.config.enableDialog,
                  onChanged: (v) =>
                      setState(() => widget.config.enableDialog = v),
                ),
                SwitchListTile(
                  title: const Text('Include trend in pane'),
                  value: showGraph,
                  onChanged: (v) => setState(() {
                    showGraph = v;
                    if (v && widget.config.graphConfig == null) {
                      widget.config.graphConfig = GraphAssetConfig.preview(
                          key: widget.config.analogKey);
                    }
                    if (!v) widget.config.graphConfig = null;
                  }),
                ),
              ],
            ),
          ),

          // RIGHT: graph config (optional)
          if (showGraph && widget.config.graphConfig != null) ...[
            const SizedBox(width: 24),
            Expanded(
              flex: 3,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: GraphContentConfig(config: widget.config.graphConfig!),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// WIDGET

class AnalogBox extends ConsumerWidget {
  final AnalogBoxConfig config;
  const AnalogBox({required this.config, super.key});

  /// One pane per placed asset: the pane follows the config instance, and a
  /// second tap on the same box toggles it shut ([showSidePane] semantics).
  String get _paneId => 'analog_box:${identityHashCode(config)}';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The pane lives in the root overlay; owning it here closes it when the
    // asset leaves the tree (page change), same contract as the sensor pane.
    return SidePaneOwner(paneId: _paneId, child: _buildBox(context, ref));
  }

  Widget _buildBox(BuildContext context, WidgetRef ref) {
    final size = config.size.toSize(MediaQuery.of(context).size);

    // Preview
    if (config.analogKey == 'AnalogBox preview') {
      return SizedBox(
        width: size.width,
        height: size.height,
        child: GestureDetector(
          onTap: config.enableDialog ? () => _showPane(context) : null,
          child: CustomPaint(
            painter: _AnalogBoxPainter(
              percent: .62,
              min: config.minValue,
              max: config.maxValue,
              bgColor: config.bgColor,
              fillColor: config.fillColor,
              setpoint1: 60,
              setpoint1Hyst: 4,
              setpoint2: 80,
              setpoint1Color: config.setpoint1Color,
              setpoint2Color: config.setpoint2Color,
              hysteresisColor: config.hysteresisColor,
              vertical: config.vertical,
              reverseFill: config.reverseFill,
              borderRadiusPct: config.borderRadiusPct,
              labelAngleDeg: config.coordinates.angle ?? 0,
            ),
          ),
        ),
      );
    }

    // Live streams
    final streams = <Stream<(String, DynamicValue)>>[];

    void addKey(String? key, String tag) {
      if (key == null || key.isEmpty) return;
      final s = ref.watch(keyStreamProvider(key)).map((dv) => (tag, dv));
      streams.add(s);
    }

    addKey(config.analogKey, 'analog');
    addKey(config.analogSensorRangeMinKey, 'min');
    addKey(config.analogSensorRangeMaxKey, 'max');
    addKey(config.setpoint1Key, 'sp1');
    addKey(config.setpoint1HysteresisKey, 'hyst');
    addKey(config.setpoint2Key, 'sp2');
    addKey(config.errorKey, 'error');

    if (streams.isEmpty) {
      // nothing configured
      return SizedBox(
        width: size.width,
        height: size.height,
        child: CustomPaint(
          painter: _AnalogBoxPainter(
            percent: 0,
            min: config.minValue,
            max: config.maxValue,
            bgColor: config.bgColor,
            fillColor: config.fillColor,
            setpoint1: null,
            setpoint1Hyst: null,
            setpoint2: null,
            setpoint1Color: config.setpoint1Color,
            setpoint2Color: config.setpoint2Color,
            hysteresisColor: config.hysteresisColor,
            vertical: config.vertical,
            reverseFill: config.reverseFill,
            borderRadiusPct: config.borderRadiusPct,
            labelAngleDeg: config.coordinates.angle ?? 0,
          ),
        ),
      );
    }

    final combined = CombineLatestStream.list(streams).map((list) {
      final map = <String, DynamicValue>{};
      for (final e in list) {
        map[e.$1] = e.$2;
      }
      return map;
    }).distinct((prev, curr) {
      // Check error state change
      final prevError = prev['error']?.asBool ?? false;
      final currError = curr['error']?.asBool ?? false;
      if (prevError != currError) return false;

      // Only consider the analog value for change detection
      final prevAnalog = prev['analog'];
      final currAnalog = curr['analog'];

      if (prevAnalog == null || currAnalog == null) {
        return prevAnalog == currAnalog; // Both null or both not null
      }

      if (!prevAnalog.isDouble && !prevAnalog.isInteger) {
        return !currAnalog.isDouble && !currAnalog.isInteger;
      }

      if (!currAnalog.isDouble && !currAnalog.isInteger) {
        return false; // Different types
      }

      final prevValue = prevAnalog.asDouble;
      final currValue = currAnalog.asDouble;
      final prevPercent =
          _toPercent(prevValue, config.minValue, config.maxValue);
      final currPercent =
          _toPercent(currValue, config.minValue, config.maxValue);

      // Return true if values are "the same" (change < 1%)
      final change = (currPercent - prevPercent).abs();
      return change < 0.01; // 1% threshold
    });

    return StreamBuilder<Map<String, DynamicValue>>(
      stream: combined,
      builder: (context, snapshot) {
        double? analog;
        double? sp1;
        double? hyst;
        double? sp2;
        bool showError = false;
        // double? dynamicMin;
        // double? dynamicMax;

        if (snapshot.hasData) {
          final m = snapshot.data!;
          if (m['analog'] case final v?) {
            if (v.isDouble || v.isInteger) analog = v.asDouble;
          }
          if (m['sp1'] case final v?) {
            if (v.isDouble || v.isInteger) sp1 = v.asDouble;
          }
          if (m['hyst'] case final v?) {
            if (v.isDouble || v.isInteger) hyst = v.asDouble;
          }
          if (m['sp2'] case final v?) {
            if (v.isDouble || v.isInteger) sp2 = v.asDouble;
          }
          showError = m['error']?.asBool ?? false;
          // if (m['min'] case final v?) {
          //   if (v.isDouble || v.isInteger) dynamicMin = v.asDouble;
          // }
          // if (m['max'] case final v?) {
          //   if (v.isDouble || v.isInteger) dynamicMax = v.asDouble;
          // }
        }

        // Use dynamic min/max if available, otherwise fall back to config values
        final effectiveMin = config.minValue;
        final effectiveMax = config.maxValue;

        final pct = _toPercent(
          analog,
          effectiveMin,
          effectiveMax,
        );

        return GestureDetector(
          onTap: config.enableDialog ? () => _showPane(context) : null,
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: CustomPaint(
              painter: _AnalogBoxPainter(
                percent: pct,
                min: effectiveMin,
                max: effectiveMax,
                bgColor: config.bgColor,
                fillColor: config.fillColor,
                setpoint1: sp1,
                setpoint1Hyst: hyst,
                setpoint2: sp2,
                setpoint1Color: config.setpoint1Color,
                setpoint2Color: config.setpoint2Color,
                hysteresisColor: config.hysteresisColor,
                vertical: config.vertical,
                reverseFill: config.reverseFill,
                borderRadiusPct: config.borderRadiusPct,
                labelAngleDeg: config.coordinates.angle ?? 0,
                showError: showError,
              ),
            ),
          ),
        );
      },
    );
  }

  static double _toPercent(double? value, double min, double max) {
    if (value == null || max <= min) return 0;
    final p = (value - min) / (max - min);
    return p.clamp(0, 1);
  }

  void _showPane(BuildContext context) {
    showSidePane(
      context: context,
      id: _paneId,
      builder: (_) => _AnalogBoxPaneLoader(config: config),
    );
  }
}

/// OPERATOR PANE

/// A key that counts as configured: non-null AND non-empty. `KeyField`
/// reports a cleared field as `''`, so both spellings mean "not bound" —
/// an empty-string range key must not conjure an empty Sensor range section.
String? _definedKey(String? key) => (key == null || key.isEmpty) ? null : key;

/// Trims the trailing zeros off a 3-decimal rendering: `62.500` → `62.5`,
/// `4.000` → `4`. Pane values are read at a glance; the padding is noise.
String _fmtValue(double v) {
  var s = v.toStringAsFixed(3);
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }
  return s;
}

/// The pane's title. Key strings are wiring, not something an operator
/// reads — with no label configured the pane names the device by what it is.
String _paneTitle(AnalogBoxConfig config) =>
    config.text?.isNotEmpty == true ? config.text! : 'Analog value';

/// Subscribes the configured keys and feeds [AnalogBoxPane] plain values.
///
/// The subscriptions live and die with the pane — closing it releases them
/// (same lifetime contract as the conveyor and sensor panes).
class _AnalogBoxPaneLoader extends ConsumerStatefulWidget {
  final AnalogBoxConfig config;
  const _AnalogBoxPaneLoader({required this.config});

  @override
  ConsumerState<_AnalogBoxPaneLoader> createState() =>
      _AnalogBoxPaneLoaderState();
}

class _AnalogBoxPaneLoaderState extends ConsumerState<_AnalogBoxPaneLoader> {
  AnalogBoxConfig get config => widget.config;

  /// The combined stream, built once: built in `build` it was a new object on
  /// every rebuild, and `StreamBuilder` re-subscribes to a new object and
  /// starts over empty -- the pane flashed its values away on any rebuild.
  Stream<Map<String, DynamicValue>>? _combined;

  Stream<Map<String, DynamicValue>> _combinedStream() {
    final cached = _combined;
    if (cached != null) return cached;
    final keys = <String, String>{};
    void put(String tag, String? key) {
      final k = _definedKey(key);
      if (k != null) keys[tag] = k;
    }

    put('analog', config.analogKey);
    put('min', config.analogSensorRangeMinKey);
    put('max', config.analogSensorRangeMaxKey);
    put('sp1', config.setpoint1Key);
    put('hyst', config.setpoint1HysteresisKey);
    put('sp2', config.setpoint2Key);
    put('error', config.errorKey);

    // Each key's stream starts with null so the combine emits before every
    // subscription has produced a value — fields fill in as data arrives
    // instead of the whole pane waiting on the slowest key. A failing
    // subscribe (stale key on a live page) blanks that field, not the pane.
    final streams = [
      for (final entry in keys.entries)
        ref
            .read(stateManProvider.future)
            .asStream()
            .switchMap((sm) =>
                sm.subscribe(entry.value).asStream().switchMap((s) => s))
            .map<DynamicValue?>((dv) => dv)
            .onErrorReturn(null)
            .startWith(null)
            .map((dv) => MapEntry(entry.key, dv)),
    ];

    return _combined = CombineLatestStream.list(streams)
        .map((entries) => <String, DynamicValue>{
              for (final e in entries)
                if (e.value != null) e.key: e.value!,
            });
  }

  @override
  Widget build(BuildContext context) {
    final combined = _combinedStream();

    // No member: every key this pane writes is a scalar analog node, so the
    // question is about the key as a whole. A refused write prompts and
    // returns without reaching the PLC.
    Future<void> write(String key, double val) async {
      final sm = await ref.read(stateManProvider.future);
      final curr = await sm.read(key);
      curr.value = val;
      await writeTag(ref, sm, key, curr);
    }

    // Trend tile — only when the page author opted the trend in. The small
    // preview charts the primary series from the collector; the full chart
    // behind the tap honours the whole GraphAssetConfig (extra series, time
    // window), as the old dialog's embedded graph did.
    Widget? trendTile;
    final gc = config.graphConfig;
    if (gc != null) {
      if (gc.primarySeries.isEmpty && config.analogKey.isNotEmpty) {
        gc.primarySeries = [
          GraphSeriesConfig(
            key: config.analogKey,
            label: config.text ?? 'Value',
          ),
        ];
      }
      gc.graphType = GraphType.timeseries;
      final series = gc.primarySeries.isNotEmpty ? gc.primarySeries.first : null;
      if (series != null) {
        trendTile = PaneGraphTile(
          // The preview drops the chart's own legend to keep the width, so
          // the header names the trace instead.
          label: series.label,
          // Tall enough for a line chart to be readable rather than
          // decorative — the conveyor's trend height, taken off the shared
          // constant rather than a literal that happens to match.
          height: kPaneTrendTileHeight,
          preview: AnalogBoxTrendGraphLoader(
            keyName: series.key,
            member: series.member,
            seriesLabel: series.label,
            units: config.units,
            showButtons: false,
            compact: true,
            xSpan: const Duration(minutes: 5),
          ),
          expandedTitle: '${_paneTitle(config)} — trend',
          expandedSize: kPaneTrendDialogSize,
          expandedBuilder: (_) => GraphAsset(gc),
        );
      }
    }

    return StreamBuilder<Map<String, DynamicValue>>(
      stream: combined,
      builder: (context, snapshot) {
        final m = snapshot.data ?? const <String, DynamicValue>{};
        double? numOf(String tag) {
          final v = m[tag];
          return (v != null && (v.isDouble || v.isInteger)) ? v.asDouble : null;
        }

        return AnalogBoxPane(
          config: config,
          value: numOf('analog'),
          setpoint1: numOf('sp1'),
          setpoint1Hysteresis: numOf('hyst'),
          setpoint2: numOf('sp2'),
          rangeMin: numOf('min'),
          rangeMax: numOf('max'),
          error: m['error']?.asBool ?? false,
          trendTile: trendTile,
          // A rejected write is reported rather than swallowed: the field
          // snaps back on the next PLC update, and without this the operator
          // sees their entry silently undone. Messenger resolved before the
          // await so nothing reaches for a disposed context afterwards.
          onWrite: (key, value) {
            final messenger = ScaffoldMessenger.maybeOf(context);
            write(key, value).catchError((Object e) {
              messenger?.showSnackBar(
                SnackBar(content: Text('Write failed: $e')),
              );
            });
          },
        );
      },
    );
  }
}

/// The operator pane. Split from [_AnalogBoxPaneLoader] and fed plain values
/// plus an [onWrite] callback so goldens and widget tests can pump it without
/// a live `StateMan` behind it (same shape as [SensorFbPane]).
///
/// Sections appear only when the config binds the keys behind them: no
/// setpoint keys, no Setpoints section — and no range keys, no Sensor range
/// section. The range section replaces the old dialog's "Advanced" switch,
/// whose `!= null` gate showed the toggle even for cleared (empty-string)
/// keys with nothing behind it.
class AnalogBoxPane extends StatelessWidget {
  final AnalogBoxConfig config;
  final double? value;
  final double? setpoint1;
  final double? setpoint1Hysteresis;
  final double? setpoint2;
  final double? rangeMin;
  final double? rangeMax;
  final bool error;

  /// The trend tile (a [PaneGraphTile]), or null when the page author left
  /// the trend out. Injected as a built widget so tests can supply a canned,
  /// provider-free preview.
  final Widget? trendTile;

  /// Called with the state key to write and the parsed value; only keys the
  /// config binds are ever passed.
  final void Function(String key, double value) onWrite;

  const AnalogBoxPane({
    super.key,
    required this.config,
    required this.onWrite,
    this.value,
    this.setpoint1,
    this.setpoint1Hysteresis,
    this.setpoint2,
    this.rangeMin,
    this.rangeMax,
    this.error = false,
    this.trendTile,
  });

  @override
  Widget build(BuildContext context) {
    final sp1Key = _definedKey(config.setpoint1Key);
    final hystKey = _definedKey(config.setpoint1HysteresisKey);
    final sp2Key = _definedKey(config.setpoint2Key);
    final rangeMinKey = _definedKey(config.analogSensorRangeMinKey);
    final rangeMaxKey = _definedKey(config.analogSensorRangeMaxKey);
    final units = config.units;
    final rangeUnits = config.rangeUnits?.isNotEmpty == true
        ? config.rangeUnits
        : units;

    String withUnit(double? v, String? unit) => v == null
        ? '---'
        : unit == null || unit.isEmpty
            ? _fmtValue(v)
            : '${_fmtValue(v)} $unit';

    return SidePane(
      title: _paneTitle(config),
      subtitle: config.text?.isNotEmpty == true ? 'Analog value' : null,
      icon: Icons.speed,
      // Fault outranks everything: with the error bit set the reading is not
      // to be trusted, whatever the number says.
      status: error
          ? const PaneStatus.fault('Sensor error')
          : value == null
              ? const PaneStatus.unknown('No data')
              : const PaneStatus.running('Live'),
      child: PaneBody(
        sections: [
          // --- Live value ------------------------------------------------
          PaneBodySection.status(
            title: 'Signal',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                PaneTileRow(
                  children: [
                    PaneMetricTile(
                      label: 'Current',
                      value: value != null ? _fmtValue(value!) : '---',
                      unit: units,
                      icon: Icons.speed,
                      width: 150,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // The bar's display scale — what "full" means on the mimic.
                PaneDetailRow(
                  label: 'Scale',
                  value:
                      '${_fmtValue(config.minValue)} – ${withUnit(config.maxValue, units)}',
                ),
              ],
            ),
          ),

          // --- Trend -----------------------------------------------------
          //
          // A preview in the pane, the real chart in a floating dialog the
          // operator can park next to the mimic (conveyor/sensor shape).
          if (trendTile != null) PaneBodySection.trend(child: trendTile!),

          // --- Setpoints -------------------------------------------------
          //
          // Inline, not behind a fold: adjusting a threshold is the routine
          // operator act on an analog box. Committed on submit (Enter /
          // focus-out) only — a half-typed value must not reach the PLC.
          if (sp1Key != null || hystKey != null || sp2Key != null)
            PaneBodySection.setpoints(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (sp1Key != null)
                        Expanded(
                          child: _ValueField(
                            fieldKey: 'analog_sp1_field',
                            label: 'Setpoint 1',
                            value: setpoint1,
                            units: units,
                            onSubmitted: (v) => onWrite(sp1Key, v),
                          ),
                        ),
                      if (sp1Key != null && hystKey != null)
                        const SizedBox(width: 8),
                      if (hystKey != null)
                        Expanded(
                          child: _ValueField(
                            fieldKey: 'analog_hyst_field',
                            label: 'Hysteresis ±',
                            value: setpoint1Hysteresis,
                            units: units,
                            onSubmitted: (v) => onWrite(hystKey, v),
                          ),
                        ),
                    ],
                  ),
                  if (sp2Key != null) ...[
                    const SizedBox(height: 8),
                    _ValueField(
                      fieldKey: 'analog_sp2_field',
                      label: 'Setpoint 2',
                      value: setpoint2,
                      units: units,
                      onSubmitted: (v) => onWrite(sp2Key, v),
                    ),
                  ],
                ],
              ),
            ),

          // --- Sensor range ----------------------------------------------
          //
          // What the old dialog kept behind its "Advanced" switch. Read-only
          // live values up front; the editable fields sit folded behind
          // "Adjust" — re-ranging a transmitter is a rare, deliberate act
          // (same fold as the sensor pane's debounce).
          if (rangeMinKey != null || rangeMaxKey != null)
            PaneBodySection.details(
              title: 'Sensor range',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (rangeMinKey != null)
                    PaneDetailRow(
                      label: 'Range min',
                      value: withUnit(rangeMin, rangeUnits),
                    ),
                  if (rangeMaxKey != null)
                    PaneDetailRow(
                      label: 'Range max',
                      value: withUnit(rangeMax, rangeUnits),
                    ),
                  ExpansionTile(
                    key: const Key('analog_range_adjust'),
                    title: Text(
                      'Adjust',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    tilePadding: EdgeInsets.zero,
                    // Top padding matters: the ExpansionTile clips its
                    // children, and the fields' floating labels paint above
                    // the field box — flush at the top they lose their upper
                    // half to the clip.
                    childrenPadding: const EdgeInsets.only(top: 8, bottom: 8),
                    shape: const Border(),
                    collapsedShape: const Border(),
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (rangeMinKey != null)
                            Expanded(
                              child: _ValueField(
                                fieldKey: 'analog_range_min_field',
                                label: 'Range min',
                                value: rangeMin,
                                units: rangeUnits,
                                onSubmitted: (v) => onWrite(rangeMinKey, v),
                              ),
                            ),
                          if (rangeMinKey != null && rangeMaxKey != null)
                            const SizedBox(width: 8),
                          if (rangeMaxKey != null)
                            Expanded(
                              child: _ValueField(
                                fieldKey: 'analog_range_max_field',
                                label: 'Range max',
                                value: rangeMax,
                                units: rangeUnits,
                                onSubmitted: (v) => onWrite(rangeMaxKey, v),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'The transmitter\'s calibrated span. Change it only '
                        'to match a re-ranged sensor.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// An analog write field. Commits on Enter / focus-out only. The key embeds
/// the current value so the field resets when the PLC reports a different
/// one (conveyor/sensor convention).
class _ValueField extends StatelessWidget {
  final String fieldKey;
  final String label;
  final double? value;
  final String? units;
  final ValueChanged<double> onSubmitted;

  const _ValueField({
    required this.fieldKey,
    required this.label,
    required this.value,
    required this.onSubmitted,
    this.units,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      key: Key('$fieldKey-$value'),
      initialValue: value != null ? _fmtValue(value!) : '',
      // Signed: analog spans go below zero (a -50…150 °C transmitter).
      keyboardType:
          const TextInputType.numberWithOptions(decimal: true, signed: true),
      decoration: InputDecoration(
        labelText: label,
        suffixText: units,
        isDense: true,
      ),
      onFieldSubmitted: (text) {
        final parsed = double.tryParse(text.trim());
        if (parsed == null) return;
        onSubmitted(parsed);
      },
    );
  }
}

/// The collected history of the analog value. Mirrors `ConveyorStatsGraph` /
/// `SensorTrendGraph`: the same widget serves the pane's small preview
/// (`compact`, no buttons) and could serve a full chart.
///
/// [member] picks the chartable number out of each stored row for struct
/// keys collected with `sample_members`; null charts the row value as-is.
class AnalogBoxTrendGraph extends ConsumerWidget {
  final Collector? collector;
  final String keyName;
  final String? member;

  /// Names the series, fixed by the caller so the preview and the expanded
  /// chart read as the same chart.
  final String seriesLabel;

  /// Y-axis unit on the full chart; the compact preview drops it.
  final String? units;

  /// Pan/zoom/now buttons. Off in the pane preview.
  final bool showButtons;

  /// Visible window. The preview shows a short span so the line has shape.
  final Duration xSpan;

  /// Drops the axis units/labels — the pane preview has no room for them
  /// and the tile caption names the chart instead.
  final bool compact;

  const AnalogBoxTrendGraph({
    required this.collector,
    required this.keyName,
    required this.seriesLabel,
    this.member,
    this.units,
    this.showButtons = true,
    this.xSpan = const Duration(minutes: 5),
    this.compact = false,
    super.key,
  });

  num? _pointOf(dynamic value) {
    if (member?.isNotEmpty ?? false) {
      return extractSeriesMemberValue(value, member!);
    }
    if (value is num) return value;
    if (value is bool) return value ? 1 : 0;
    if (value is String) return num.tryParse(value);
    return null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return StreamBuilder<List<TimeseriesData<dynamic>>>(
      stream:
          collector?.collectStream(keyName, since: const Duration(hours: 2)),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const Center(child: Text('No data'));
        }

        // The collector hands over two hours of history but the plot only
        // shows the last [xSpan] of it, so the y-range is taken from the
        // samples inside that window. Scaling to all two hours is what made
        // the trace sit flat and then jump the moment an old extreme aged
        // out of the buffer — see [stableTrendRange].
        final windowStart = DateTime.now()
            .subtract(xSpan)
            .millisecondsSinceEpoch
            .toDouble();
        var minY = double.infinity;
        var maxY = double.negativeInfinity;
        final data = <Map<String, dynamic>>[];
        for (final sample in snapshot.data!) {
          final y = _pointOf(sample.value)?.toDouble();
          if (y == null) continue;
          final x = sample.time.millisecondsSinceEpoch.toDouble();
          if (x >= windowStart) {
            if (y < minY) minY = y;
            if (y > maxY) maxY = y;
          }
          data.add({'x': x, 'y': y, 's': seriesLabel});
        }
        if (data.isEmpty) {
          return const Center(child: Text('No data'));
        }
        // Nothing inside the window yet — a key that has stopped updating.
        // Frame the newest sample rather than drawing an empty axis.
        if (minY > maxY) {
          final last = data.last['y'] as double;
          minY = last;
          maxY = last;
        }

        final range = stableTrendRange(minY, maxY);

        final graphConfig = GraphConfig(
          type: GraphType.timeseries,
          xAxis: GraphAxisConfig(unit: compact ? '' : 'Time'),
          yAxis: GraphAxisConfig(
            unit: compact ? '' : (units ?? ''),
            min: range.min,
            max: range.max,
          ),
          xSpan: xSpan,
          // One series, already named by the pane — the legend column would
          // only take width off a plot this small.
          legend: !compact,
        );

        // The compact preview needs its own gutters — same trick as
        // `ConveyorStatsGraph`, minus the right gutter it keeps for its
        // second axis.
        final theme = compact
            ? (Theme.of(context).brightness == Brightness.dark
                ? darkChartTheme(padding: kCompactChartPaddingSingleAxis)
                : lightChartTheme(padding: kCompactChartPaddingSingleAxis))
            : ref.watch(chartThemeNotifierProvider);

        return Graph(
          config: graphConfig,
          data: data,
          showButtons: showButtons,
          categoryColors: {seriesLabel: Colors.blue},
          chartTheme: theme,
          redraw: () {},
        ).build(context);
      },
    );
  }
}

/// Resolves the collector for [AnalogBoxTrendGraph] — mirrors
/// `SensorTrendGraphLoader`.
class AnalogBoxTrendGraphLoader extends ConsumerWidget {
  final String keyName;
  final String? member;
  final String seriesLabel;
  final String? units;
  final bool showButtons;
  final Duration xSpan;
  final bool compact;

  const AnalogBoxTrendGraphLoader({
    required this.keyName,
    required this.seriesLabel,
    this.member,
    this.units,
    this.showButtons = true,
    this.xSpan = const Duration(minutes: 5),
    this.compact = false,
    super.key,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<Collector?>(
      future: ref.watch(collectorProvider.future),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return AnalogBoxTrendGraph(
          collector: snapshot.data,
          keyName: keyName,
          member: member,
          seriesLabel: seriesLabel,
          units: units,
          showButtons: showButtons,
          xSpan: xSpan,
          compact: compact,
        );
      },
    );
  }
}

/// PAINTER

class _AnalogBoxPainter extends CustomPainter {
  final double percent; // 0..1
  final double min;
  final double max;

  final Color bgColor;
  final Color fillColor;

  final double? setpoint1;
  final double? setpoint1Hyst; // +/- around sp1
  final double? setpoint2;

  final Color setpoint1Color;
  final Color setpoint2Color;
  final Color hysteresisColor;

  final bool vertical;
  final bool reverseFill;
  final double borderRadiusPct;
  final double labelAngleDeg;
  final bool showError;

  _AnalogBoxPainter({
    required this.percent,
    required this.min,
    required this.max,
    required this.bgColor,
    required this.fillColor,
    required this.setpoint1,
    required this.setpoint1Hyst,
    required this.setpoint2,
    required this.setpoint1Color,
    required this.setpoint2Color,
    required this.hysteresisColor,
    required this.vertical,
    required this.reverseFill,
    required this.borderRadiusPct,
    required this.labelAngleDeg,
    this.showError = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final r = Radius.circular(size.shortestSide * borderRadiusPct.clamp(0, .5));
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, r);

    // Background
    final bg = Paint()..color = bgColor;
    canvas.drawRRect(rrect, bg);

    // Fill clip
    final p = percent.clamp(0.0, 1.0);
    Rect fillRect;
    if (vertical) {
      final h = size.height * p.toDouble();
      final y = reverseFill ? 0.0 : size.height - h;
      fillRect = Rect.fromLTWH(0, y, size.width, h);
    } else {
      final w = size.width * p.toDouble();
      final x = reverseFill ? size.width - w : 0.0;
      fillRect = Rect.fromLTWH(x, 0, w, size.height);
    }
    final fill = Paint()..color = fillColor;
    canvas.save();
    canvas.clipRRect(rrect);
    canvas.drawRect(fillRect, fill);
    canvas.restore();

    // Hysteresis band around SP1
    if (setpoint1 != null && setpoint1Hyst != null && max > min) {
      final lo = ((setpoint1! - setpoint1Hyst!) - min) / (max - min);
      final hi = ((setpoint1! + setpoint1Hyst!) - min) / (max - min);
      _drawBand(canvas, size, lo.clamp(0.0, 1.0), hi.clamp(0.0, 1.0),
          hysteresisColor);
    }

    // Setpoint lines
    if (setpoint1 != null) {
      _drawSetpoint(canvas, size, setpoint1!, setpoint1Color);
    }
    if (setpoint2 != null) {
      _drawSetpoint(canvas, size, setpoint2!, setpoint2Color, dashed: true);
    }

    // Border
    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = showError ? 3 : 2
      ..color = showError ? Colors.red : Colors.black;
    canvas.drawRRect(rrect, border);
  }

  void _drawSetpoint(Canvas canvas, Size size, double sp, Color color,
      {bool dashed = false}) {
    if (max <= min) return;
    final t = ((sp - min) / (max - min)).clamp(0.0, 1.0);
    final p1 = Paint()
      ..color = color
      ..strokeWidth = 2;

    if (vertical) {
      final y = size.height * (reverseFill ? t : 1 - t);
      if (dashed) {
        _drawDashedLine(canvas, Offset(0, y), Offset(size.width, y), p1);
      } else {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), p1);
      }
    } else {
      final x = size.width * (reverseFill ? 1 - t : t);
      if (dashed) {
        _drawDashedLine(canvas, Offset(x, 0), Offset(x, size.height), p1);
      } else {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), p1);
      }
    }
  }

  void _drawBand(Canvas canvas, Size size, double lo, double hi, Color color) {
    final paint = Paint()..color = color;
    if (vertical) {
      final y1 = size.height * (reverseFill ? lo : 1 - lo);
      final y2 = size.height * (reverseFill ? hi : 1 - hi);
      final top = math.min(y1, y2);
      final height = (y2 - y1).abs();
      canvas.drawRect(Rect.fromLTWH(0, top, size.width, height), paint);
    } else {
      final x1 = size.width * (reverseFill ? 1 - lo : lo);
      final x2 = size.width * (reverseFill ? 1 - hi : hi);
      final left = math.min(x1, x2);
      final width = (x2 - x1).abs();
      canvas.drawRect(Rect.fromLTWH(left, 0, width, size.height), paint);
    }
  }

  void _drawDashedLine(
    Canvas canvas,
    Offset a,
    Offset b,
    Paint paint, {
    double dash = 6,
    double gap = 4,
  }) {
    final total = (b - a).distance;
    final dir = (b - a) / total;
    double t = 0;
    while (t < total) {
      final t2 = math.min(t + dash, total);
      final p = a + dir * t;
      final q = a + dir * t2;
      canvas.drawLine(p, q, paint);
      t = t2 + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _AnalogBoxPainter old) {
    return percent != old.percent ||
        min != old.min ||
        max != old.max ||
        bgColor != old.bgColor ||
        fillColor != old.fillColor ||
        setpoint1 != old.setpoint1 ||
        setpoint1Hyst != old.setpoint1Hyst ||
        setpoint2 != old.setpoint2 ||
        vertical != old.vertical ||
        reverseFill != old.reverseFill ||
        borderRadiusPct != old.borderRadiusPct ||
        labelAngleDeg != old.labelAngleDeg ||
        showError != old.showError;
  }
}

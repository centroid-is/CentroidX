import 'dart:math' show pi;

import 'package:flutter/material.dart';
import 'package:tfc/widgets/panes/color_picker_dialog.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:tfc/converter/color_converter.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:tfc_dart/core/collector.dart' show CollectEntry, Collector;
import 'package:tfc_dart/core/database.dart' show TimeseriesData;

import '../../providers/collector.dart';
import '../../providers/state_man.dart';
import '../../widgets/graph.dart';
import 'common.dart';
import 'graph.dart' show extractSeriesMemberValue;
import '../../widgets/panes/pane_chrome.dart';
import '../../widgets/panes/side_pane.dart';
import '../../widgets/state_value_builder.dart';
import '../../widgets/panes/setpoint_field.dart';
import '../../widgets/tag_access_guard.dart';
import 'sensor_painter.dart';

part 'sensor.g.dart';

// ---------------------------------------------------------------------------
// FB_Sensor binding
// ---------------------------------------------------------------------------
//
// The PLC side of this asset is `FB_Sensor` in the SVNCoreComponents library
// (`SVNCoreComponents/DigitalSignals/Sensor/FB_Sensor.TcPOU`). Every instance
// carries a PERSISTENT RETAIN `HMI : ST_Sensor_HMI` member published as an OPC
// UA structured type — that struct node is what `SensorConfig.detectionKey`
// should point at (e.g. `sensors.CVS01_CN01_PX01.HMI`).
//
// The FB writes the status mirrors every scan and reads the two config members
// back, so the operator can retune debounce from the side pane without a
// download. Writes go back as a whole-struct copy-on-write, the same shape the
// conveyor pane uses — the status members the FB owns are overwritten on the
// next scan, so echoing them back is harmless.
//
// A plain BOOL node still works: when the subscribed value is not an
// `ST_Sensor_HMI` struct the widget falls back to reading it as a bare bool and
// the pane degrades to the read-only detail list.

/// Member names on `ST_Sensor_HMI`. Spelled once so a rename in the PLC
/// library is a one-line change here rather than a hunt through string
/// literals.
abstract final class SensorFbFields {
  /// Final output after on/off delay — what interlock chains read.
  static const output = 'p_stat_xOutput';

  /// Unfiltered NO input.
  static const rawNO = 'p_stat_xRaw';

  /// Unfiltered NC input (only meaningful when [hasNC] is set).
  static const rawNC = 'p_stat_xRawNC';

  /// Neither NO nor NC active for 100 ms — the sensor state is unknowable.
  static const fault = 'p_stat_xFault';

  /// Whether this instance is wired with both an NO and an NC contact.
  static const hasNC = 'p_stat_xHasNC';

  /// Time the output has been continuously TRUE (caps at one day).
  static const blockedFor = 'p_stat_tBlockedFor';

  /// Time the output has been continuously FALSE (caps at one day).
  static const clearFor = 'p_stat_tClearFor';

  /// Rising-edge (on) delay — writable.
  static const onDelay = 'p_cfg_tOnDelay';

  /// Falling-edge (off) delay — writable.
  static const offDelay = 'p_cfg_tOffDelay';
}

/// A decoded snapshot of one `ST_Sensor_HMI` struct.
///
/// Pure value type — no widgets, no I/O — so the decode rules are unit
/// testable without a live `StateMan`.
///
/// TwinCAT publishes `TIME` as a millisecond count, which is why the four
/// duration members are read through [_durationAt] rather than `asDateTime`.
@immutable
class SensorFbState {
  final bool output;
  final bool rawNO;
  final bool rawNC;
  final bool fault;
  final bool hasNC;
  final Duration blockedFor;
  final Duration clearFor;
  final Duration onDelay;
  final Duration offDelay;

  const SensorFbState({
    required this.output,
    required this.rawNO,
    required this.rawNC,
    required this.fault,
    required this.hasNC,
    required this.blockedFor,
    required this.clearFor,
    required this.onDelay,
    required this.offDelay,
  });

  /// Decodes [value] when it is an `ST_Sensor_HMI` struct, `null` otherwise.
  ///
  /// The discriminator is the presence of [SensorFbFields.output]: it is the
  /// member the FB always publishes and no plain BOOL node can carry it. A
  /// `null` return is the legacy path — the caller reads the node as a bare
  /// bool instead.
  static SensorFbState? tryParse(DynamicValue value) {
    if (!value.isObject) return null;
    if (!value.contains(SensorFbFields.output)) return null;
    return SensorFbState(
      output: _boolAt(value, SensorFbFields.output),
      rawNO: _boolAt(value, SensorFbFields.rawNO),
      rawNC: _boolAt(value, SensorFbFields.rawNC),
      fault: _boolAt(value, SensorFbFields.fault),
      hasNC: _boolAt(value, SensorFbFields.hasNC),
      blockedFor: _durationAt(value, SensorFbFields.blockedFor),
      clearFor: _durationAt(value, SensorFbFields.clearFor),
      onDelay: _durationAt(value, SensorFbFields.onDelay),
      offDelay: _durationAt(value, SensorFbFields.offDelay),
    );
  }

  /// `DynamicValue.operator[]` throws on a missing member, so every read is
  /// guarded — an older PLC library revision missing a member must degrade,
  /// not crash the mimic.
  static bool _boolAt(DynamicValue value, String field) =>
      value.contains(field) ? value[field].asBool : false;

  static Duration _durationAt(DynamicValue value, String field) =>
      Duration(milliseconds: value.contains(field) ? value[field].asInt : 0);
}

/// Formats an elapsed time for a [PaneMetricTile] as a `(value, unit)` pair.
///
/// `q_tBlockedFor` / `q_tClearFor` run from milliseconds to a full day, so a
/// single format string cannot stay readable across the range.
(String, String) formatSensorElapsed(Duration d) {
  if (d.inSeconds < 60) {
    return ((d.inMilliseconds / 1000).toStringAsFixed(1), 's');
  }
  if (d.inMinutes < 60) {
    return (
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}',
      'm:s'
    );
  }
  return (
    '${d.inHours}:${(d.inMinutes % 60).toString().padLeft(2, '0')}',
    'h:m'
  );
}

/// Whether a sensor's bound key has chartable data gathering behind it.
///
/// A plain BOOL series charts as-is; a struct key is only chartable when the
/// collect entry samples the debounced output bit into its rows
/// (`sample_members` containing [SensorFbFields.output]) — a whole-struct
/// series has nothing the graph can draw.
bool sensorTrendAvailable({
  required bool isStruct,
  required CollectEntry? collect,
}) {
  if (collect == null) return false;
  if (!isStruct) return true;
  return collect.sampleMembers?.contains(SensorFbFields.output) ?? false;
}

/// Series name for the sensor trend, fixed so the small preview in the pane
/// and the full chart in the floating dialog read as the same chart —
/// mirrors `kConveyorFreqSeries` in `conveyor.dart`.
const String kSensorTrendSeries = 'Blocked';

const Map<String, Color> sensorTrendColors = {
  kSensorTrendSeries: Colors.blue,
};

/// Gutters for the compact sensor preview. The boolean tick labels
/// ("False"/"True") are wider than the bare numbers the shared
/// [kCompactChartPaddingSingleAxis] was sized for, so its left gutter clips
/// them; everything else matches.
const EdgeInsets kSensorTrendCompactPadding =
    EdgeInsets.only(left: 48, right: 30, top: 6, bottom: 20);

/// The blocked/clear history of a collected sensor key as a boolean state
/// timeline. Mirrors `ConveyorStatsGraph`: the same widget serves the pane's
/// small preview (`compact`, no buttons) and the floating full chart.
///
/// [member] picks the chartable bit out of each stored row for struct keys
/// collected with `sample_members` (`p_stat_xOutput`); null charts the row
/// value as-is (plain BOOL series).
class SensorTrendGraph extends ConsumerWidget {
  final Collector? collector;
  final String keyName;
  final String? member;

  /// Pan/zoom/now buttons. Off in the pane preview, on in the floating chart.
  final bool showButtons;

  /// Visible window. The preview shows a short span so the line has shape;
  /// the expanded chart shows more history.
  final Duration xSpan;

  /// Drops the axis units/labels — the ~60px pane preview has no room for
  /// them and the tile caption names the chart instead.
  final bool compact;

  const SensorTrendGraph({
    required this.collector,
    required this.keyName,
    this.member,
    this.showButtons = true,
    this.xSpan = const Duration(minutes: 5),
    this.compact = false,
    super.key,
  });

  /// One stored row → one 0/1 point. Rows from `sample_members` collections
  /// are objects ([member] plucks the bit); plain BOOL series cross the
  /// boundary as bools or bool-ish strings.
  num? _pointOf(dynamic value) {
    if (member != null && member!.isNotEmpty) {
      return extractSeriesMemberValue(value, member!);
    }
    if (value is bool) return value ? 1 : 0;
    if (value is num) return value;
    if (value is String) {
      if (value == 'true') return 1;
      if (value == 'false') return 0;
      return num.tryParse(value);
    }
    return null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return StreamBuilder<List<TimeseriesData<dynamic>>>(
      stream: collector?.collectStream(keyName, since: const Duration(hours: 2)),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const Center(child: Text('No data'));
        }

        final data = <Map<String, dynamic>>[
          for (final sample in snapshot.data!)
            if (_pointOf(sample.value) case final num y)
              {
                'x': sample.time.millisecondsSinceEpoch.toDouble(),
                'y': y,
                's': kSensorTrendSeries,
              },
        ];

        final graphConfig = GraphConfig(
          type: GraphType.timeseries,
          xAxis: GraphAxisConfig(unit: compact ? '' : 'Time'),
          // The boolean axis pins the ticks to true/false; a whisker of
          // headroom keeps the trace off the frame edges.
          yAxis: GraphAxisConfig(
              unit: '', boolean: true, min: -0.1, max: 1.1),
          xSpan: xSpan,
          // One series on a true/false axis — the legend column would only
          // take width off a plot this small.
          legend: !compact,
        );

        // The compact preview needs its own gutters — same trick as
        // `ConveyorStatsGraph`, with a wider left gutter for the
        // "False"/"True" tick labels.
        final theme = compact
            ? (Theme.of(context).brightness == Brightness.dark
                ? darkChartTheme(padding: kSensorTrendCompactPadding)
                : lightChartTheme(padding: kSensorTrendCompactPadding))
            : ref.watch(chartThemeNotifierProvider);

        return Graph(
          config: graphConfig,
          data: data,
          showButtons: showButtons,
          categoryColors: sensorTrendColors,
          chartTheme: theme,
          redraw: () {},
        ).build(context);
      },
    );
  }
}

/// Resolves the collector for [SensorTrendGraph] — mirrors
/// `_ConveyorStatsGraphLoader`.
class SensorTrendGraphLoader extends ConsumerWidget {
  final String keyName;
  final String? member;
  final bool showButtons;
  final Duration xSpan;
  final bool compact;

  const SensorTrendGraphLoader({
    required this.keyName,
    this.member,
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
        return SensorTrendGraph(
          collector: snapshot.data,
          keyName: keyName,
          member: member,
          showButtons: showButtons,
          xSpan: xSpan,
          compact: compact,
        );
      },
    );
  }
}

/// The kind of sensor — drives painter dispatch and glyph appearance.
@JsonEnum()
enum SensorKind {
  redLight,
  opticField,
  inductiveField,
}

/// Configuration for a sensor asset.
///
/// Pure data model — JSON-serialisable, no widget/painter wiring. The widget,
/// painter, registry registration, and config dialog are introduced in
/// Plans 02–05 of the same phase.
@JsonSerializable(explicitToJson: true)
class SensorConfig extends BaseAsset {
  @override
  String get displayName => 'Sensor';

  @override
  String get category => 'Visualization';

  /// Sensor kind — determines which painter renders the glyph.
  @JsonKey(unknownEnumValue: SensorKind.redLight)
  SensorKind kind;

  /// State key the sensor binds to.
  ///
  /// Preferred: the `HMI` member of an `FB_Sensor` instance (an
  /// `ST_Sensor_HMI` struct node) — that unlocks the full pane, including
  /// live debounce. A plain BOOL node is still accepted and read as
  /// the raw detection bit; the decode is shape-driven
  /// (see [SensorFbState.tryParse]).
  String detectionKey;

  /// When true, the visual `isActive` is the inverse of the detection bool.
  bool invertActivePolarity;

  /// Legacy: state key carrying the rising-edge delay (ms).
  ///
  /// No longer surfaced anywhere — the debounce lives in the `ST_Sensor_HMI`
  /// struct behind [detectionKey] (`p_cfg_tOnDelay`). Retained so pages
  /// persisted before the struct binding round-trip without data loss.
  String risingEdgeDelayKey;

  /// Legacy: state key carrying the falling-edge delay (ms).
  ///
  /// See [risingEdgeDelayKey] — superseded by `p_cfg_tOffDelay`.
  String fallingEdgeDelayKey;

  /// Per-instance active colour. Defaults to the scheme's running colour,
  /// matching `led.dart`.
  @AssetColorConverter()
  AssetColor activeColor;

  /// Per-instance inactive colour. Defaults to the scheme's stopped colour.
  @AssetColorConverter()
  AssetColor inactiveColor;

  /// Optional human-readable label (e.g. `"PE-101A"`).
  String? tag;

  /// Whether [tag] is painted on the main screen. Off by default: on a busy
  /// mimic the tags are noise, and the side pane (where the tag is the pane
  /// title) is the reading surface for identity.
  bool showTag;

  /// `Asset.text` is what `AssetStack` (in `lib/pages/page_view.dart`) reads
  /// to paint the label OUTSIDE the asset's rotated subtree. By aliasing
  /// `text` onto `tag` here, the sensor label rides the same path as Button's
  /// caption (`ButtonConfig.labelColor => textColor`) and stays upright
  /// regardless of `Coordinates.angle` — which supersedes the in-painter
  /// label machinery (counterRotateLabel / _paintLabel) introduced as a
  /// 180° hack in 5509d610.
  ///
  /// Gated on [showTag]: a hidden tag yields `null` here so `AssetStack`
  /// short-circuits its label block, while the pane keeps reading [tag].
  @override
  String? get text => showTag ? tag : null;

  /// Setter accepts non-null writes only. The generated `fromJson` calls
  /// `..text = json['text']` AFTER the constructor has already set `tag`
  /// from the JSON `tag` key. Legacy persisted pages have `text: null` and
  /// a non-null `tag` — adopting `null` here would clobber that tag and
  /// silently erase the operator's label on first load. Non-null adoption
  /// preserves both the legacy load path and the new round-trip (where
  /// `text` mirrors `tag` when [showTag] is set, and is `null` otherwise).
  @override
  set text(String? value) {
    if (value != null) tag = value;
  }

  SensorConfig({
    this.kind = SensorKind.redLight,
    this.detectionKey = '',
    this.invertActivePolarity = false,
    this.risingEdgeDelayKey = '',
    this.fallingEdgeDelayKey = '',
    AssetColor? activeColor,
    AssetColor? inactiveColor,
    this.tag,
    this.showTag = false,
  })  : activeColor = activeColor ?? AssetColor.green,
        inactiveColor = inactiveColor ?? AssetColor.grey {
    // Default label position — matches LED/Button convention (those default
    // to TextPos.right). Sensors carry short tag labels and read most
    // naturally below the glyph on a busy HMI canvas.
    textPos = TextPos.below;
  }

  /// Preview factory with reasonable defaults for the asset palette.
  SensorConfig.preview() : this();

  factory SensorConfig.fromJson(Map<String, dynamic> json) =>
      _$SensorConfigFromJson(json);

  @override
  Map<String, dynamic> toJson() => _$SensorConfigToJson(this);

  @override
  Widget build(BuildContext context) {
    return Sensor(config: this);
  }

  /// Returns the body of the configure dialog. The dialog chrome is
  /// supplied by the page editor's `showDialog` caller — this method
  /// returns the editor *body* only (matches `_ConveyorGateConfigEditor`
  /// pattern in `conveyor_gate.dart`).
  @override
  Widget configure(BuildContext context) {
    return _SensorConfigEditor(config: this);
  }
}

/// Apply polarity inversion to a raw detection bool.
///
/// Locked formula (per `01-UI-SPEC.md` §Polarity inversion semantics):
/// `isActive = invertActivePolarity ? !rawBool : rawBool`.
///
/// The label is NOT affected by polarity inversion — polarity is purely a
/// visual-mapping concern.
bool sensorIsActive({
  required bool rawBool,
  required bool invertActivePolarity,
}) {
  return invertActivePolarity ? !rawBool : rawBool;
}

// ---------------------------------------------------------------------------
// Sensor widget — runtime entry point.
// ---------------------------------------------------------------------------

/// Live sensor widget driven by a bool detection state key.
///
/// Subscribes to `config.detectionKey` via `stateManProvider`. The stream is
/// hoisted to `initState` (Pitfall 2 — no resubscribe storm under high-
/// frequency rebuilds). Visual flips immediately on bool change — no client-
/// side animation, no tween, no debounce, no smoothing (SENS-05). The
/// `StreamBuilder` rebuild is the entire flip mechanism; this property is
/// grep-guarded by a regression test on the source text.
/// Renders neutral grey when the key is empty, the stream has no value yet,
/// or the stream errors (SENS-14, three stale paths).
///
/// Honours `Coordinates.angle` via `LayoutRotatedBox`. Tap opens the config
/// dialog through a real `GestureDetector` with `HitTestBehavior.opaque`
/// (UI-SPEC §Interaction Contract); this survives a translating ancestor
/// (Phase 3 forward-compat — sensor as elevator child).
class Sensor extends ConsumerStatefulWidget {
  final SensorConfig config;
  const Sensor({super.key, required this.config});

  @override
  ConsumerState<Sensor> createState() => _SensorState();
}

class _SensorState extends ConsumerState<Sensor> {
  /// The value stream constructed once per mount (or per detectionKey
  /// change). `null` indicates the stale path: no key — no stream needed.
  ///
  /// Carries the raw [DynamicValue] rather than a pre-mapped bool: the same
  /// subscription serves both bindings — an `ST_Sensor_HMI` struct (decoded by
  /// [SensorFbState.tryParse]) and a plain BOOL node (read with `asBool`).
  Stream<DynamicValue>? _detectionStream;

  /// The detectionKey that `_detectionStream` was constructed for. Compared
  /// against `widget.config.detectionKey` in `didUpdateWidget` so we re-hoist
  /// even when the editor mutates the same `SensorConfig` instance in-place
  /// (the case where `oldWidget.config` and `widget.config` are identical
  /// references and we cannot rely on `oldWidget.config` to reflect the
  /// previous value).
  String? _hoistedKey;

  @override
  void initState() {
    super.initState();
    _hoistStream();
  }

  @override
  void didUpdateWidget(covariant Sensor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-hoist only when the key actually changes — preserves stream identity
    // across rebuilds with same config (Pitfall 2 invariant). Compare against
    // the stored `_hoistedKey` rather than `oldWidget.config` because the
    // editor mutates the same config instance in-place, so `oldWidget.config`
    // and `widget.config` are the same reference.
    if (_hoistedKey != widget.config.detectionKey) {
      _hoistStream();
    }
  }

  /// Construct the bool stream once. Called from `initState` and from
  /// `didUpdateWidget` only when `detectionKey` changes. NEVER called from
  /// `build()` — that would recreate the stream every frame and trigger an
  /// OPC UA monitored-item create/cancel storm (Pitfall 2).
  void _hoistStream() {
    final key = widget.config.detectionKey;
    _hoistedKey = key;
    if (key.isEmpty) {
      _detectionStream = null;
      return;
    }
    _detectionStream = ref
        .read(stateManProvider.future)
        .asStream()
        .asyncExpand((sm) => sm.subscribe(key).asStream())
        .asyncExpand((s) => s);
  }

  /// Test-only window: resolves the painter `isActive` from a raw stream
  /// bool by applying `widget.config.invertActivePolarity` via
  /// [sensorIsActive]. Public-via-annotation only — production code should
  /// continue to read polarity through the `StreamBuilder` path in
  /// [build]. Used by polarity-through-widget tests in
  /// `test/page_creator/assets/sensor_widget_test.dart` to assert that the
  /// widget honours the polarity flag without a real `StateMan`.
  @visibleForTesting
  bool resolveIsActive(bool rawBool) => sensorIsActive(
        rawBool: rawBool,
        invertActivePolarity: widget.config.invertActivePolarity,
      );

  /// Test-only window onto the hoisted stream identity. Production code
  /// must NOT depend on this — it exists so the Pitfall 2 stream-lifecycle
  /// regression tests can assert `identical(oldStream, newStream)` across
  /// rebuilds (no resubscribe storm) and a fresh stream after a
  /// key change.
  @visibleForTesting
  Stream<DynamicValue>? get debugDetectionStream => _detectionStream;

  /// Per-kind painter dispatch — exhaustive switch (no `default` clause so
  /// adding a future SensorKind value is a compile error here, not a runtime
  /// surprise). One painter class per kind closes Pitfall 3.
  ///
  /// The painter no longer draws the label — that is handled by `AssetStack`
  /// in `lib/pages/page_view.dart` via `Asset.text` (aliased onto `tag` by
  /// `SensorConfig`). Routing the label outside the rotated subtree means
  /// it stays upright at any `Coordinates.angle`, which obsoletes the
  /// in-painter `counterRotateLabel` hack from 5509d610.
  CustomPainter _createPainter({
    required bool isActive,
    required bool isStale,
  }) {
    final activeColor = widget.config.activeColor.resolve(context);
    final inactiveColor = widget.config.inactiveColor.resolve(context);
    switch (widget.config.kind) {
      case SensorKind.redLight:
        return RedLightBeamPainter(
          isActive: isActive,
          activeColor: activeColor,
          inactiveColor: inactiveColor,
          isStale: isStale,
        );
      case SensorKind.opticField:
        return OpticFieldPainter(
          isActive: isActive,
          activeColor: activeColor,
          inactiveColor: inactiveColor,
          isStale: isStale,
        );
      case SensorKind.inductiveField:
        return InductiveFieldPainter(
          isActive: isActive,
          activeColor: activeColor,
          inactiveColor: inactiveColor,
          isStale: isStale,
        );
    }
  }

  /// Opens the operator pane for this sensor (Plan 04-05 / SENS-01).
  ///
  /// Two shapes, chosen from what the bound node actually carries:
  ///
  ///  * `ST_Sensor_HMI` struct → [SensorFbPane]. Live signal state plus the
  ///    two debounce setpoints, editable. This is the only surface on which
  ///    a sensor writes to the PLC, and it writes exactly two members —
  ///    `p_cfg_tOnDelay` and `p_cfg_tOffDelay`, both declared config members
  ///    the FB reads back every scan.
  ///  * anything else (empty key, still connecting, subscription error, or a
  ///    plain BOOL node) → [_staticPane]: the read-only detail list this pane
  ///    has always shown.
  ///
  /// Page *configuration* stays editor-only in both shapes — routed through
  /// `page_editor.dart` → `SensorConfig.configure(context)`. Editing a PLC
  /// setpoint is an operator action; editing the mimic is not.
  String get _paneId => 'sensor:${identityHashCode(widget.config)}';

  /// The read-only detail list — the fallback when no `ST_Sensor_HMI` struct
  /// is in hand. [liveState] fills the "Detection state" row when a value is
  /// available; `null` leaves it deferring to the glyph.
  ///
  /// Live values only, per the pane house rules: no key names, no polarity
  /// wording, no debounce section (without a struct there is no live debounce
  /// to read). The tag is the pane's title, mirroring the 3rd-party pane.
  Widget _staticPane(PaneStatus status, bool? liveState, {Widget? trendTile}) {
    final config = widget.config;
    final tagged = config.tag != null && config.tag!.isNotEmpty;
    return SidePane(
      title: tagged ? config.tag! : 'Sensor',
      subtitle: tagged ? '${config.kind.name} · sensor' : config.kind.name,
      icon: Icons.sensors,
      status: status,
      child: PaneBody(
        sections: [
          PaneBodySection.status(
            title: 'Signal',
            child: PaneDetailRow(
              label: 'Detection state',
              value: config.detectionKey.isEmpty
                  ? 'no key configured'
                  : liveState == null
                      ? '(see glyph)'
                      : liveState
                          ? 'true'
                          : 'false',
            ),
          ),
          if (trendTile != null) PaneBodySection.trend(child: trendTile),
        ],
      ),
    );
  }

  void _showDetailsPane(BuildContext context) {
    final key = widget.config.detectionKey;
    if (key.isEmpty) {
      showSidePane(
        context: context,
        id: _paneId,
        builder: (_) => _staticPane(const PaneStatus.unknown('No key'), null),
      );
      return;
    }

    // A second subscription, independent of the glyph's: it lives and dies
    // with the pane, so closing the pane releases it (same lifetime contract
    // as the conveyor pane). It is paired with the `StateMan` that produced
    // it so the setpoint fields have something to write through.
    showSidePane(
      context: context,
      id: _paneId,
      // One subscription for the life of the pane (StateManValueBuilder): a
      // stream built inline re-subscribed on every rebuild, and tapping a
      // delay field is a rebuild -- the pane flashed "Connecting" and the
      // field lost what was typed.
      builder: (paneContext) => StateManValueBuilder(
        keyName: key,
        waiting: (_) => _staticPane(const PaneStatus.unknown('Connecting'), null),
        error: (_, __) => _staticPane(const PaneStatus.fault('Error'), null),
        builder: (context, stateMan, dynValue) {
            final fb = SensorFbState.tryParse(dynValue);

            // Data gathering on this key unlocks the inline trend — see
            // [sensorTrendAvailable] for the chartability rule. The pane
            // shows a small preview; the full chart floats behind a tap
            // (same shape as the conveyor's trend tile).
            final chartable = sensorTrendAvailable(
              isStruct: fb != null,
              collect: stateMan.keyMappings.nodes[key]?.collect,
            );
            Widget? trendTile;
            if (chartable) {
              final member = fb != null ? SensorFbFields.output : null;
              final tag = widget.config.tag;
              final title = tag != null && tag.isNotEmpty ? tag : key;
              trendTile = PaneGraphTile(
                // A two-state timeline, not a line chart — see
                // [kPaneBooleanTrendTileHeight] for why this one tile is
                // shorter than every other trend tile on the HMI.
                height: kPaneBooleanTrendTileHeight,
                preview: SensorTrendGraphLoader(
                  keyName: key,
                  member: member,
                  showButtons: false,
                  compact: true,
                  xSpan: const Duration(minutes: 5),
                ),
                expandedTitle: '$title — trend',
                expandedSize: const Size(820, 420),
                expandedBuilder: (context) => SensorTrendGraphLoader(
                  keyName: key,
                  member: member,
                  xSpan: const Duration(minutes: 30),
                ),
              );
            }

            if (fb == null) {
              // Plain BOOL node — no FB behind this key, so no setpoints to
              // offer. Show the detail list with the live bit filled in.
              final raw = dynValue.asBool;
              return _staticPane(
                raw
                    ? const PaneStatus.running('Detected')
                    : const PaneStatus.stopped('Clear'),
                raw,
                trendTile: trendTile,
              );
            }

            // A `Consumer` rather than this State's own `ref`: the pane lives
            // in the overlay, not in this widget's subtree, and its `ref` must
            // outlive nothing it does not own.
            return Consumer(
              builder: (context, ref, _) => SensorFbPane(
                config: widget.config,
                state: fb,
                trendTile: trendTile,
                // Copy-on-write, mirroring the conveyor pane: clone the struct,
                // set one member, write the whole thing back. The `p_stat_*`
                // members ride along unchanged and the FB overwrites them on the
                // next scan.
                //
                // `field` is the member the template's rules are written
                // against — `SensorFbFields`' constants, which are the PLC's
                // own `p_cfg_*` names and not the labels beside them.
                //
                // A rejected write is reported rather than swallowed. The only
                // feedback a setpoint has is the field itself, and on the next
                // PLC update that field snaps back to the old value — without
                // this the operator sees their entry silently undone with no
                // reason given. A tap-time refusal no longer arrives here at
                // all: `writeTag` answers false, having already prompted, and
                // this `catchError` is left for the comms failure it was
                // written for.
                onWrite: (field, value) {
                  final messenger = ScaffoldMessenger.maybeOf(context);
                  final newValue = DynamicValue.from(dynValue);
                  newValue[field] = value;
                  writeTag(ref, stateMan, key, newValue, member: field)
                      .catchError((Object e) {
                    messenger?.showSnackBar(
                      SnackBar(content: Text('Write to $key failed: $e')),
                    );
                    return false;
                  });
                },
              ),
            );
        },
      ),
    );
  }

  /// Wraps the painter in a tap-receiving GestureDetector + a rotating
  /// layout box. The GestureDetector is the single tap source — never
  /// painter hit-testing (UI-SPEC §Interaction Contract).
  ///
  /// Layering order (outer → inner):
  ///   LayoutRotatedBox → GestureDetector → LayoutBuilder → CustomPaint
  ///
  /// The hover tooltip path was removed — operators read full state via
  /// `_showDetailsPane` on tap. No floating panel sits above the sensor
  /// on a busy HMI canvas.
  ///
  /// The GestureDetector lives INSIDE LayoutRotatedBox:
  /// `_RenderLayoutRotatedBox.hitTest` (in `common.dart`, ELEV-19 fix)
  /// forwards hits to its child in the child's un-rotated frame — for any
  /// incoming position that lands on the ROTATED glyph, including positions
  /// outside the unrotated layout rect. With the detector outside, its own
  /// `RenderBox.hitTest` clamps to the unrotated rect first, so a rotated
  /// sensor was only tappable on the sliver where the rotated visual
  /// overlaps that rect (the page-level chain is hit-permissive via
  /// `_HitPermissiveSizedBox` in `lib/pages/page_view.dart`).
  /// Tap-through-`Transform.translate` (Phase 3 forward-compat) is
  /// unaffected: `Transform.translate` defaults `transformHitTests: true`.
  ///
  /// The inner `LayoutBuilder` propagates the parent's bounded constraints
  /// into `CustomPaint.size:` so the painter fills the asset rect — and so
  /// the GestureDetector has a non-zero hit-test box.
  Widget _buildPaint(CustomPainter painter) {
    final angleDeg = widget.config.coordinates.angle ?? 0.0;
    return LayoutRotatedBox(
      angle: angleDeg * pi / 180,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _showDetailsPane(context),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // When placed inside a parent with bounded constraints (the
            // asset rect), use them directly. Otherwise fall back to the
            // config size resolved against the screen — standalone path.
            final Size paintSize;
            if (constraints.hasBoundedWidth && constraints.hasBoundedHeight) {
              paintSize = Size(constraints.maxWidth, constraints.maxHeight);
            } else {
              paintSize =
                  widget.config.size.toSize(MediaQuery.of(context).size);
            }
            return CustomPaint(
              size: paintSize,
              painter: painter,
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Stale path #1: empty key — no stream constructed in initState.
    if (_detectionStream == null) {
      return _buildPaint(_createPainter(isActive: false, isStale: true));
    }

    return StreamBuilder<DynamicValue>(
      stream: _detectionStream,
      builder: (context, snapshot) {
        // Stale path #2 + #3: stream emitted nothing yet, or errored.
        if (!snapshot.hasData || snapshot.hasError) {
          return _buildPaint(_createPainter(isActive: false, isStale: true));
        }
        // Stale path #4: `q_xFault` — the FB sees neither the NO nor the NC
        // contact, so the true state is unknowable. Grey is the honest
        // rendering; painting "clear" would assert something the PLC does
        // not know. Only reachable on the FB binding (a plain BOOL has no
        // fault channel).
        final fb = SensorFbState.tryParse(snapshot.data!);
        if (fb != null && fb.fault) {
          return _buildPaint(_createPainter(isActive: false, isStale: true));
        }
        // `p_stat_xOutput` — the debounced, delay-respected output the FB
        // tells interlock chains to read — not `p_stat_xRaw`. The mimic and
        // the interlocks must agree on what "detected" means.
        final isActive = sensorIsActive(
          rawBool: fb?.output ?? snapshot.data!.asBool,
          invertActivePolarity: widget.config.invertActivePolarity,
        );
        return _buildPaint(_createPainter(isActive: isActive, isStale: false));
      },
    );
  }
}

// ---------------------------------------------------------------------------
// FB_Sensor operator pane
// ---------------------------------------------------------------------------

/// The operator pane shown when the sensor is bound to an `FB_Sensor`.
///
/// Split out from `_SensorState` and driven by a plain [SensorFbState] +
/// [onWrite] callback so it can be pumped in tests without a live `StateMan`
/// behind it.
///
/// [onWrite] is called with a member name from [SensorFbFields] and the new
/// value; only the two `p_cfg_*` members are ever passed — this pane offers no
/// commands, because `FB_Sensor` has none.
class SensorFbPane extends StatelessWidget {
  final SensorConfig config;
  final SensorFbState state;
  final void Function(String field, Object? value) onWrite;

  /// The inline blocked/clear trend tile (a [PaneGraphTile]), or null when
  /// the bound key has no chartable data gathering configured (no
  /// `CollectEntry`, or a struct collected without `p_stat_xOutput` among
  /// its `sample_members`). Injected as a built widget so goldens and tests
  /// can supply a canned, provider-free preview.
  final Widget? trendTile;

  /// Replaces the kind-derived subtitle. The conveyor reuses this pane for
  /// a wagon's safety edges, where "redLight · FB_Sensor" would name a
  /// glyph the asset does not draw.
  final String? subtitleOverride;

  const SensorFbPane({
    super.key,
    required this.config,
    required this.state,
    required this.onWrite,
    this.trendTile,
    this.subtitleOverride,
  });

  @override
  Widget build(BuildContext context) {
    final (blockedValue, blockedUnit) = formatSensorElapsed(state.blockedFor);
    final (clearValue, clearUnit) = formatSensorElapsed(state.clearFor);
    final tagged = config.tag != null && config.tag!.isNotEmpty;

    return SidePane(
      // The tag names the pane — key strings are wiring, not something an
      // operator reads (same convention as the 3rd-party pane).
      title: tagged ? config.tag! : 'Sensor',
      subtitle: subtitleOverride ?? '${config.kind.name} · FB_Sensor',
      icon: Icons.sensors,
      // Fault outranks detection: with neither contact reporting, "clear"
      // would be a guess. Matches the glyph, which goes grey on the same
      // condition.
      status: state.fault
          ? const PaneStatus.fault('Signal fault')
          : state.output
              ? const PaneStatus.running('Blocked')
              : const PaneStatus.stopped('Clear'),
      child: PaneBody(
        sections: [
          // --- Live signal ---------------------------------------------
          PaneBodySection.status(
            title: 'Signal',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                PaneTileRow(
                  children: [
                    // Wider than the 108 default: only two tiles share the
                    // row, and at the default "Blocked for" ellipsizes to
                    // "Blocked …" — which is not a label.
                    PaneMetricTile(
                      label: 'Blocked for',
                      value: blockedValue,
                      unit: blockedUnit,
                      icon: Icons.timer,
                      width: 150,
                    ),
                    PaneMetricTile(
                      label: 'Clear for',
                      value: clearValue,
                      unit: clearUnit,
                      icon: Icons.timer_off,
                      width: 150,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                PaneDetailRow(
                  label: 'Output',
                  // Under fault the FB's Q still follows the NO contact, but
                  // that contact is the thing we cannot see — reporting
                  // "clear" here would contradict the glyph, which greys out.
                  value: state.fault
                      ? 'unknown'
                      : state.output
                          ? 'blocked'
                          : 'clear',
                ),
                // No raw NO/NC rows: the Output row already says what the
                // sensor reports, and the undebounced bits are diagnostics,
                // not something an operator acts on. When the contacts
                // disagree, the Fault row below carries the message.
                if (state.fault)
                  const PaneDetailRow(
                    label: 'Fault',
                    value: 'NO and NC both inactive',
                  ),
              ],
            ),
          ),

          // --- Trend -----------------------------------------------------
          //
          // A preview in the pane, the real chart in a floating dialog the
          // operator can park next to the mimic (same shape as the
          // conveyor's trend). Only present when the bound key's data
          // gathering makes the output chartable.
          if (trendTile != null) PaneBodySection.trend(child: trendTile!),

          // --- Debounce --------------------------------------------------
          //
          // Read-only live values up front: the operator reads the tuning at
          // a glance but cannot fat-finger it. The editable fields sit
          // folded behind "Adjust" — retuning is a rare, deliberate act, so
          // it must not be reachable on the pane's first paint.
          //
          // `p_cfg_tOnDelay` / `p_cfg_tOffDelay` are PERSISTENT RETAIN on the
          // PLC, so a change here survives a restart without a download.
          // Committed on submit (Enter / focus-out) only — a half-typed delay
          // must not reach the FB. The field keys embed the current value so
          // the box resets if the PLC reports a different one.
          PaneBodySection.setpoints(
            title: 'Signal delays',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                PaneDetailRow(
                  label: 'On delay',
                  value: '${state.onDelay.inMilliseconds} ms',
                ),
                PaneDetailRow(
                  label: 'Off delay',
                  value: '${state.offDelay.inMilliseconds} ms',
                ),
                ExpansionTile(
                  key: const Key('sensor_debounce_adjust'),
                  title: Text(
                    'Adjust',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  tilePadding: EdgeInsets.zero,
                  // Top padding matters: the ExpansionTile clips its
                  // children, and the delay fields' floating labels paint
                  // above the field box — flush at the top they lose their
                  // upper half to the clip.
                  childrenPadding: const EdgeInsets.only(top: 8, bottom: 8),
                  // No divider lines when open — the section title already
                  // scopes the fold.
                  shape: const Border(),
                  collapsedShape: const Border(),
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: SetpointField<int>(
                            fieldKey: 'sensor_on_delay_field',
                            label: 'On delay',
                            text: state.onDelay.inMilliseconds.toString(),
                            current: state.onDelay.inMilliseconds,
                            // Negative rejected rather than clamped: `TIME` is
                            // unsigned, and silently turning -50 into 0 hides a
                            // typo from the operator.
                            parse: (t) {
                              final v = int.tryParse(t);
                              return v == null || v < 0 ? null : v;
                            },
                            suffix: 'ms',
                            decimal: false,
                            onSubmitted: (ms) =>
                                onWrite(SensorFbFields.onDelay, ms),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: SetpointField<int>(
                            fieldKey: 'sensor_off_delay_field',
                            label: 'Off delay',
                            text: state.offDelay.inMilliseconds.toString(),
                            current: state.offDelay.inMilliseconds,
                            // Negative rejected rather than clamped: `TIME` is
                            // unsigned, and silently turning -50 into 0 hides a
                            // typo from the operator.
                            parse: (t) {
                              final v = int.tryParse(t);
                              return v == null || v < 0 ? null : v;
                            },
                            suffix: 'ms',
                            decimal: false,
                            onSubmitted: (ms) =>
                                onWrite(SensorFbFields.offDelay, ms),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'On delay holds a detection off until the input has '
                      'been stable; off delay holds it on after the input '
                      'drops.',
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


// ---------------------------------------------------------------------------
// Details rows (Plan 04-05 / SENS-01)
// ---------------------------------------------------------------------------
//
// The private `_DetailRow` helper that used to live here is now
// `PaneDetailRow` in widgets/panes/pane_chrome.dart, shared by every pane and
// dialog.

// ---------------------------------------------------------------------------
// Config editor — the body of the configure dialog.
// ---------------------------------------------------------------------------

/// Editor body for `SensorConfig`. Mirrors `_ConveyorGateConfigEditor` but
/// without animation (sensor has no animated state) and with the locked
/// field order from `01-UI-SPEC.md` §Config Dialog Layout.
///
/// All edits are mutations on the live `widget.config` instance — the page
/// editor reuses the same config object across rebuilds, so the parent's
/// page model picks the changes up automatically (see `Sensor.didUpdateWidget`
/// for the matching invariant on the runtime side).
class _SensorConfigEditor extends StatefulWidget {
  final SensorConfig config;
  const _SensorConfigEditor({required this.config});

  @override
  State<_SensorConfigEditor> createState() => _SensorConfigEditorState();
}

class _SensorConfigEditorState extends State<_SensorConfigEditor> {
  late TextEditingController _tagController;

  @override
  void initState() {
    super.initState();
    _tagController = TextEditingController(text: widget.config.tag ?? '');
  }

  @override
  void dispose() {
    _tagController.dispose();
    super.dispose();
  }

  /// Per-kind painter dispatch for the live preview. Mirrors the runtime
  /// dispatch in `_SensorState._createPainter` but always renders
  /// `isActive: true` so the preview shows the active visual. The preview
  /// glyph is intentionally label-free — operators can read the tag in the
  /// adjacent `TextFormField` below.
  CustomPainter _previewPainter(BuildContext context, SensorConfig config) {
    final activeColor = config.activeColor.resolve(context);
    final inactiveColor = config.inactiveColor.resolve(context);
    switch (config.kind) {
      case SensorKind.redLight:
        return RedLightBeamPainter(
          isActive: true,
          activeColor: activeColor,
          inactiveColor: inactiveColor,
        );
      case SensorKind.opticField:
        return OpticFieldPainter(
          isActive: true,
          activeColor: activeColor,
          inactiveColor: inactiveColor,
        );
      case SensorKind.inductiveField:
        return InductiveFieldPainter(
          isActive: true,
          activeColor: activeColor,
          inactiveColor: inactiveColor,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = widget.config;

    return Container(
      width: 360,
      padding: const EdgeInsets.all(24), // UI-SPEC lg = 24
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // -- Live preview (150x150) — no Play button (sensor has no animation) --
            Center(
              child: SizedBox(
                width: 150,
                height: 150,
                child: CustomPaint(painter: _previewPainter(context, config)),
              ),
            ),
            const Divider(),

            // -- Sensor Kind --
            Text('Sensor Kind', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            SegmentedButton<SensorKind>(
              segments: const [
                ButtonSegment(
                    value: SensorKind.redLight, label: Text('Red Light')),
                ButtonSegment(
                    value: SensorKind.opticField, label: Text('Optic Field')),
                ButtonSegment(
                    value: SensorKind.inductiveField,
                    label: Text('Inductive Field')),
              ],
              selected: {config.kind},
              onSelectionChanged: (selection) {
                setState(() => config.kind = selection.first);
              },
            ),
            const SizedBox(height: 16),

            // -- Detection State Key --
            KeyField(
              label: 'Detection State Key',
              initialValue: config.detectionKey,
              onChanged: (v) => setState(() => config.detectionKey = v),
            ),
            const SizedBox(height: 4),
            Text(
              'Point at an FB_Sensor HMI struct for live state and debounce '
              'in the side pane. A plain BOOL key also works.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),

            // -- Invert Active Polarity (locked subtitle copy contract) --
            SwitchListTile(
              title: const Text('Invert Active Polarity'),
              subtitle: Text(
                config.invertActivePolarity
                    ? 'Active when state is false'
                    : 'Active when state is true',
              ),
              value: config.invertActivePolarity,
              onChanged: (v) => setState(() => config.invertActivePolarity = v),
              contentPadding: EdgeInsets.zero,
            ),
            const SizedBox(height: 16),

            // The rising/falling edge delay KeyFields that used to sit here
            // are gone: the debounce lives in the FB_Sensor struct behind
            // the detection key, and the side pane reads and edits it
            // there. The config fields survive for JSON compatibility only.

            // -- Active Color --
            AssetColorPickerRow(
              label: 'Active Color',
              color: config.activeColor,
              onChanged: (c) => setState(() => config.activeColor = c),
            ),
            const SizedBox(height: 8),

            // -- Inactive Color --
            AssetColorPickerRow(
              label: 'Inactive Color',
              color: config.inactiveColor,
              onChanged: (c) => setState(() => config.inactiveColor = c),
            ),
            const SizedBox(height: 16),

            // -- Tag --
            TextFormField(
              controller: _tagController,
              decoration: const InputDecoration(
                labelText: 'Tag (e.g. PE-101A)',
                hintText: 'Optional',
              ),
              onChanged: (v) {
                setState(() {
                  config.tag = v.isEmpty ? null : v;
                });
              },
            ),
            const SizedBox(height: 16),

            // -- Label Position (mirrors button.dart:758 / led.dart:164) --
            //
            // The checkbox gates whether the tag is painted on the canvas at
            // all (off by default — the pane title carries the tag). The
            // position dropdown is disabled while hidden: position without a
            // label is a meaningless knob.
            Text('Label Position',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: DropdownButton<TextPos>(
                    // Coalesce null → TextPos.below for legacy persisted
                    // pages that pre-date this picker (text_pos: null).
                    value: config.textPos ?? TextPos.below,
                    isExpanded: true,
                    onChanged: config.showTag
                        ? (value) {
                            setState(() {
                              config.textPos = value!;
                            });
                          }
                        : null,
                    items: TextPos.values
                        .map((e) => DropdownMenuItem<TextPos>(
                              value: e,
                              child: Text(e.name),
                            ))
                        .toList(),
                  ),
                ),
                const SizedBox(width: 8),
                Checkbox(
                  value: config.showTag,
                  onChanged: (v) => setState(() => config.showTag = v ?? false),
                ),
                GestureDetector(
                  onTap: () => setState(() => config.showTag = !config.showTag),
                  child: const Text('Show on screen'),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // -- Size --
            SizeField(
              initialValue: config.size,
              onChanged: (v) => setState(() => config.size = v),
            ),
            const SizedBox(height: 16),

            // -- Coordinates (includes angle field — SENS-15;
            //    enableAngle: true exposes the angle slider) --
            CoordinatesField(
              initialValue: config.coordinates,
              onChanged: (c) => setState(() => config.coordinates = c),
              enableAngle: true,
            ),
          ],
        ),
      ),
    );
  }
}

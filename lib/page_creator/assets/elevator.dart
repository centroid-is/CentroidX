import 'dart:async';
import 'dart:math' show pi;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:tfc/widgets/panes/standard_dialog.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;

import '../../providers/state_man.dart';
import '../../widgets/panes/pane_chrome.dart';
import '../../widgets/panes/side_pane.dart';
import 'package:tfc/widgets/number_slider.dart';
import '../../widgets/duration_field.dart';
import 'common.dart';
import 'conveyor.dart' show ConveyorConfig;
import 'elevator_layout.dart';
import 'elevator_painter.dart';
import 'registry.dart';
import 'sensor.dart' show SensorConfig;

part 'elevator.g.dart';

// ---------------------------------------------------------------------------
// Polymorphic child JSON helpers
// ---------------------------------------------------------------------------

/// Deserialise a polymorphic child asset for an [ElevatorChildEntry].
///
/// Walks the existing [AssetRegistry.parse] path so any registered asset
/// type Just Works without elevator-side switching (Anti-Pattern 1 from
/// research/ARCHITECTURE.md).
///
/// The `{'wrapped_child': json}` envelope makes [AssetRegistry.parse]'s
/// JSON-tree crawl find exactly one asset (the child) without bare-Map
/// ambiguity — `parse` skips the outer Map (no `asset_name` key on it)
/// and recurses into the single value, where it finds the registered
/// `asset_name` and dispatches to the matching factory.
///
/// REGRESSION GUARD: Locked by the polymorphic round-trip tests in
/// `test/page_creator/assets/elevator_config_test.dart` group
/// 'Polymorphic child round-trip' (3 tests, including a heterogeneous
/// SensorConfig + ConveyorGateConfig fixture). If you change this
/// helper, those tests must continue to pass.
///
/// FAIL-LOUD CONTRACT (T-02-04): When [AssetRegistry.parse] returns an
/// empty list — meaning the JSON's `asset_name` is not registered in
/// [AssetRegistry] — this throws [FormatException] with the offending
/// name. This is intentional: silent drop would let saved pages lose
/// children invisibly (counter to Pitfall 5).
BaseAsset _childFromJson(Map<String, dynamic> json) {
  final assets = AssetRegistry.parse(<String, dynamic>{'wrapped_child': json});
  if (assets.isEmpty) {
    throw FormatException(
      'ElevatorChildEntry.child JSON did not match any registered '
      'asset_name in AssetRegistry: ${json[constAssetName]}',
    );
  }
  return assets.first as BaseAsset;
}

Map<String, dynamic> _childToJson(BaseAsset child) => child.toJson();

// ---------------------------------------------------------------------------
// Children list legacy / forward-compat shim
// ---------------------------------------------------------------------------

/// Legacy / forward-compat shim for the children list. Locked in
/// Phase 2 from day one (ROADMAP key decision) to avoid the
/// wrapper-promotion migration trap (PITFALLS Pitfall 5).
///
/// Today: returns [] for missing / null and parses each entry as a
/// new-format ElevatorChildEntry. Future schema evolutions add
/// branches here without touching the public type — exact same
/// pattern as conveyor.dart:_gatesFromJson.
List<ElevatorChildEntry> _childrenFromJson(List<dynamic>? json) {
  if (json == null) return <ElevatorChildEntry>[];
  return json
      .map((item) => ElevatorChildEntry.fromJson(item as Map<String, dynamic>))
      .toList();
}

List<Map<String, dynamic>> _childrenToJson(List<ElevatorChildEntry> list) =>
    list.map((e) => e.toJson()).toList();

// ---------------------------------------------------------------------------
// ElevatorChildEntry — locked wrapper schema
// ---------------------------------------------------------------------------

// Monotonic suffix appended to ElevatorChildEntry ids. Windows clock
// resolution (~15ms) can cause back-to-back DateTime.now() calls to
// return identical microseconds; the suffix guarantees uniqueness
// regardless of clock granularity.
int _nextElevatorChildEntryIdSuffix = 0;

/// Wrapper for a child asset attached to an Elevator's platform.
///
/// Schema locked in Phase 2 (ROADMAP key decision) from day one — even
/// though the children list is empty in this phase, future Phase 3
/// extensions add to the children list without changing the wrapper
/// shape. The `id` is used as a `ValueKey<String>` in Phase 3 to keep
/// child widget identity stable across position changes (Pitfall 1).
@JsonSerializable(explicitToJson: true)
class ElevatorChildEntry {
  /// Stable identity for ValueKey use (Pitfall 1 — Phase 3).
  /// Defaults to a microsecond timestamp suffixed with a monotonic
  /// counter — the suffix prevents collisions on Windows where
  /// DateTime resolution is coarse.
  String id;

  /// Lateral position on the platform (0.0 = far left, 1.0 = far
  /// right). Default 0.5 = centre.
  double offsetX;

  /// Anchor offset along Y (units of child height): -1.0..+1.0.
  /// Default 0.0 = bottom-on-platform. Positive raises the child above
  /// the platform; negative lowers it below. Unclamped — Stack(Clip.none)
  /// handles overhang. (Plan 260511-ehy)
  @JsonKey(defaultValue: 0.0)
  double offsetY;

  /// Polymorphic child asset. Round-trips via [AssetRegistry.parse].
  @JsonKey(fromJson: _childFromJson, toJson: _childToJson)
  BaseAsset child;

  ElevatorChildEntry({
    String? id,
    this.offsetX = 0.5,
    this.offsetY = 0.0,
    required this.child,
  }) : id = id ??
            '${DateTime.now().microsecondsSinceEpoch}-${_nextElevatorChildEntryIdSuffix++}';

  factory ElevatorChildEntry.fromJson(Map<String, dynamic> json) =>
      _$ElevatorChildEntryFromJson(json);

  Map<String, dynamic> toJson() => _$ElevatorChildEntryToJson(this);
}

// ---------------------------------------------------------------------------
// ElevatorConfig — pure data model
// ---------------------------------------------------------------------------

/// Configuration for the Elevator asset.
///
/// Pure data model — JSON-serialisable, no widget/painter wiring.
/// The widget, painter, registry registration, and config dialog
/// are introduced in Plans 02-03..02-05 of this phase.
@JsonSerializable(explicitToJson: true)
class ElevatorConfig extends BaseAsset {
  @override
  String get displayName => 'Elevator';

  @override
  String get category => 'Visualization';

  /// PLC state key emitting the raw 0..100% position float.
  String positionKey;

  /// Tween animation duration in ms. Default 250 (CONTEXT specifics).
  int tweenDurationMs;

  /// Fraction of bbox height for the platform's vertical travel range.
  /// 0.0 = pinned at bottom; 1.0 = full headroom climb (default).
  /// Clamped to [0, 1] at runtime; the effective travel is further
  /// clamped to `bboxH - platformH` so the platform never overhangs the
  /// bbox top.
  ///
  /// Plan 260511-fd6 — replaces the auto-deduce from child heights that
  /// shipped in Plan 260511-dxa. Operator picks the travel range
  /// explicitly via a Slider in the config editor; the runtime no longer
  /// reads child sizes when computing platform motion. See the plan
  /// SUMMARY for the width-bug reproducer that motivated the change.
  @JsonKey(defaultValue: 1.0)
  double travelRange;

  /// Child assets riding the platform. Phase 2 ships with [] —
  /// Phase 3 fills the list via the config-dialog dropdown.
  @JsonKey(fromJson: _childrenFromJson, toJson: _childrenToJson)
  List<ElevatorChildEntry> children;

  /// Plan 04-04 (QUAL-08) — when true, the runtime ignores the live PLC
  /// stream and animates `_progress` smoothly between 0% and 100% on a
  /// fixed cycle (50ms tick × 0.01 step → ~5s up, ~5s down). Useful for
  /// previewing elevator pages without a live PLC.
  ///
  /// Nullable + `includeIfNull: false` so legacy saved pages (pre-Plan
  /// 04-04) round-trip bit-perfectly: omitting the field yields `null`,
  /// which surfaces as "off" via the `simulate ?? false` guards.
  @JsonKey(includeIfNull: false)
  bool? simulate;

  ElevatorConfig({
    this.positionKey = '',
    this.tweenDurationMs = 250,
    this.simulate,
    this.travelRange = 1.0,
    List<ElevatorChildEntry>? children,
  }) : children = children != null ? List<ElevatorChildEntry>.of(children) : [];

  /// Preview factory for the asset palette.
  ElevatorConfig.preview() : this();

  factory ElevatorConfig.fromJson(Map<String, dynamic> json) =>
      _$ElevatorConfigFromJson(json);

  @override
  Map<String, dynamic> toJson() => _$ElevatorConfigToJson(this);

  /// Returns positionKey (if non-empty) + each child's allKeys flat-mapped,
  /// deduplicated.
  ///
  /// Required override (ARCHITECTURE Anti-Pattern 6 — default
  /// `BaseAsset.allKeys` introspects only top-level JSON field names matching
  /// the key pattern. It does NOT recurse into the children wrapper list, so
  /// without this override alarms and collectors silently miss every state
  /// key configured on a child asset (sensor detection keys, conveyor
  /// batches keys, etc.).
  ///
  /// Order: positionKey first (if non-empty), then children in declaration
  /// order. Duplicates are removed (a key configured on both parent and a
  /// child appears exactly once).
  ///
  /// REGRESSION GUARD: locked by
  /// `test/page_creator/assets/elevator_config_test.dart` group
  /// 'allKeys flat-map (ELEV-13)' (6 tests). If you change the order or
  /// dedup semantics, those tests must continue to pass.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  List<String> get allKeys {
    // Order: positionKey first, then each child's allKeys flat-mapped via
    // `children.expand((e) => e.child.allKeys)` — recursive walk into the
    // polymorphic child without any switch on runtimeType.
    //
    // Dedup + empty-filter via a Set<String> literal (LinkedHashSet, so
    // insertion order is preserved → parent first, then children in
    // declaration order).
    return <String>{
      if (positionKey.isNotEmpty) positionKey,
      for (final k in children.expand((e) => e.child.allKeys))
        if (k.isNotEmpty) k,
    }.toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    return Elevator(config: this);
  }

  /// Returns the body of the configure dialog. The dialog chrome is
  /// applied by `_ElevatorState._openConfigDialog` (a `Dialog`) so the
  /// `TextFormField`/`KeyField`/etc. inside the editor find a `Material`
  /// ancestor — mirrors the `Sensor` precedent.
  @override
  Widget configure(BuildContext context) {
    return _ElevatorConfigEditor(config: this);
  }
}

// ---------------------------------------------------------------------------
// Elevator widget — runtime entry point.
// ---------------------------------------------------------------------------

/// Live elevator widget — runtime entry point.
///
/// Subscribes to `config.positionKey` via `stateManProvider`. The stream
/// is hoisted to `initState` (Pitfall 2 — no resubscribe storm under
/// high-frequency rebuilds). The position is fed through
/// [platformProgress] (clamp + normalise) into a [ValueNotifier<double>]
/// that the painter listens to via `super(repaint:)`. Smooth motion is
/// applied by a `TweenAnimationBuilder<double>` wrapper added in
/// Cycle C (Plan 02-04 Tasks 5-6).
///
/// Stale rendering covers three paths: empty positionKey, stream pre-
/// data, stream error (mirrors sensor.dart precedent — ELEV-14).
///
/// Tap opens the config dialog through a real `GestureDetector` wrapping
/// the painter — survives a translating ancestor (forward-compat for
/// Phase 3, where the elevator may be embedded in another moving widget).
class Elevator extends ConsumerStatefulWidget {
  final ElevatorConfig config;
  const Elevator({super.key, required this.config});

  @override
  ConsumerState<Elevator> createState() => _ElevatorState();
}

class _ElevatorState extends ConsumerState<Elevator> {
  /// Target progress 0..1, written by stream emissions; the painter
  /// listens via super(repaint:).
  late final ValueNotifier<double> _progress;

  /// Per-frame animation notifier. The painter's super(repaint:) listens
  /// to this; the TweenAnimationBuilder writes to it on every frame so
  /// the painter sees smooth motion without rebuilding above the
  /// CustomPaint subtree (ARCHITECTURE Pattern 3).
  late final ValueNotifier<double> _animProgress;

  /// The double stream constructed once per mount (or per positionKey
  /// change). Null when positionKey is empty (stale path 1).
  Stream<DynamicValue>? _positionStream;

  /// Subscription to _positionStream; null when no stream hoisted.
  StreamSubscription<DynamicValue>? _streamSub;

  /// The positionKey that _positionStream was constructed for. Compared
  /// against widget.config.positionKey in didUpdateWidget so we re-hoist
  /// even when the editor mutates the same ElevatorConfig instance
  /// in-place (matches the sensor.dart precedent — `oldWidget.config`
  /// and `widget.config` are the same reference, so we cannot rely on
  /// `oldWidget.config.positionKey` to reflect the previous value).
  String? _hoistedKey;

  /// True while the stream has not yet emitted a usable double, or has
  /// errored. Flipped to false on the first valid emission. The painter
  /// receives this OR'd with `config.positionKey.isEmpty`.
  bool _isStreamStale = true;

  /// True when the most recent stream emission was outside [0, 100]
  /// (ELEV-15). The painter renders an amber outline when this is true.
  /// Mutually exclusive with [_isStaleEffective]: an out-of-range value
  /// is also a valid emission, so it flips [_isStreamStale] to false.
  /// Stale paths (no key, no data, error) leave this false — the
  /// painter never shows both grey AND amber at once.
  bool _isOutOfRange = false;

  /// Plan 04-04 (QUAL-08) — periodic timer that drives `_progress` between
  /// 0 and 1 when `widget.config.simulate == true`. Null when simulation is
  /// off (the default). Cancelled in `dispose()` and when the simulate
  /// flag flips back to false in `didUpdateWidget`.
  Timer? _simTimer;

  /// Current simulation progress (0..1). Held separately from
  /// `_progress.value` so reversal direction can be tracked without
  /// reading the public notifier (which the painter also writes through).
  double _simProgress = 0.0;

  /// True while the simulation sweep is ascending (0 → 1). Flipped to
  /// false at the top of the sweep and back to true at the bottom.
  bool _simAscending = true;

  /// Tick step for the simulation. 0.01 per 50ms tick → ~5s for 0→1
  /// and ~10s for a full round trip (matches the conveyor.dart precedent
  /// for a comfortable preview cadence).
  static const double _kSimStep = 0.01;
  static const Duration _kSimTick = Duration(milliseconds: 50);

  @override
  void initState() {
    super.initState();
    _progress = ValueNotifier<double>(0.0);
    _animProgress = ValueNotifier<double>(0.0);
    _hoistStream();
    // Plan 04-04 — kick off the simulation immediately if the saved config
    // has simulate=true. Done after the stream hoist so the early-return
    // guard in _onStreamData sees the same `widget.config.simulate` flag
    // any subsequent emissions will see.
    if (widget.config.simulate ?? false) {
      _handleSimulationChange(true);
    }
  }

  @override
  void didUpdateWidget(covariant Elevator oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-hoist only when the key actually changes — preserves stream
    // identity across rebuilds with same config (Pitfall 2 invariant).
    // Compare against the stored `_hoistedKey` rather than
    // `oldWidget.config.positionKey` because the editor mutates the
    // same config instance in-place, so `oldWidget.config` and
    // `widget.config` are the same reference.
    if (_hoistedKey != widget.config.positionKey) {
      _hoistStream();
    }
    // Plan 04-04 — start/stop the simulation timer when the simulate
    // flag flips. Compare against the actual timer presence rather than
    // the old widget's flag because the editor mutates `widget.config`
    // in place (oldWidget.config and widget.config are the same
    // reference, mirroring the positionKey precedent above).
    final wantSim = widget.config.simulate ?? false;
    final hasSim = _simTimer != null;
    if (wantSim != hasSim) {
      _handleSimulationChange(wantSim);
    }
  }

  /// Starts or stops the simulation timer based on `simOn`.
  ///
  /// ON: spins up a `Timer.periodic` ticking every 50ms that nudges
  /// `_simProgress` by ±0.01 and writes the clamped value into the
  /// public `_progress` notifier. Direction reverses at each end so the
  /// platform sweeps 0 → 1 → 0 forever.
  ///
  /// OFF: cancels the timer and leaves `_progress.value` at the last
  /// simulated reading. The next live PLC emission resumes ownership of
  /// the notifier (the early-return guard in `_onStreamData` consults
  /// `widget.config.simulate` before each write).
  void _handleSimulationChange(bool simOn) {
    if (simOn) {
      // Idempotent: only start if not already ticking.
      if (_simTimer != null) return;
      _simProgress = _progress.value.clamp(0.0, 1.0);
      _simAscending = _simProgress < 1.0;
      _simTimer = Timer.periodic(_kSimTick, (_) {
        if (!mounted) {
          _simTimer?.cancel();
          _simTimer = null;
          return;
        }
        if (_simAscending) {
          _simProgress += _kSimStep;
          if (_simProgress >= 1.0) {
            _simProgress = 1.0;
            _simAscending = false;
          }
        } else {
          _simProgress -= _kSimStep;
          if (_simProgress <= 0.0) {
            _simProgress = 0.0;
            _simAscending = true;
          }
        }
        _progress.value = _simProgress;
      });
    } else {
      _simTimer?.cancel();
      _simTimer = null;
      // Leave _progress.value as-is (frozen) — the next stream emission
      // will overwrite it via the existing _onStreamData path.
    }
  }

  /// Construct the position stream once. Called from `initState` and
  /// `didUpdateWidget` only when `positionKey` changes. NEVER called
  /// from `build()` — that would recreate the stream every frame and
  /// trigger an OPC UA monitored-item create/cancel storm (Pitfall 2).
  ///
  /// LOCKED — Pitfall 2 regression guard:
  ///   100 rebuilds with the same positionKey MUST preserve
  ///   `_positionStream` reference identity. Enforced by
  ///   `test/page_creator/assets/elevator_widget_test.dart`,
  ///   group 'Stream lifecycle (Pitfall 2)', test
  ///   '100 rebuilds with same positionKey: stream identity preserved'.
  ///   If you change this method, that test must continue to pass.
  ///
  ///   Equally locked: 'changing positionKey re-hoists stream
  ///   (different identity)' — re-hoist guard via `_hoistedKey`.
  ///
  ///   And: 'unmount disposes ValueNotifier and cancels subscription'
  ///   — `_streamSub.cancel()` before re-hoisting closes Pitfall 10.
  void _hoistStream() {
    // Cancel any prior subscription before re-hoisting.
    _streamSub?.cancel();
    _streamSub = null;

    final key = widget.config.positionKey;
    _hoistedKey = key;
    if (key.isEmpty) {
      _positionStream = null;
      // Empty key — stale path 1 — no setState needed during initState
      // because _isStreamStale is already true. didUpdateWidget guards
      // the redundant flip via the equality check inside the listener.
      // Re-hoisting from a non-empty key MUST also clear any prior
      // _isOutOfRange flag (mutual-exclusivity contract — ELEV-15).
      if (mounted && (!_isStreamStale || _isOutOfRange)) {
        setState(() {
          _isStreamStale = true;
          _isOutOfRange = false;
        });
      } else {
        _isStreamStale = true;
        _isOutOfRange = false;
      }
      return;
    }
    _positionStream = ref
        .read(stateManProvider.future)
        .asStream()
        .asyncExpand((sm) => sm.subscribe(key).asStream())
        .asyncExpand((s) => s);

    _streamSub = _positionStream!.listen(
      _onStreamData,
      onError: _onStreamError,
    );
    // Initial state: stale until first emission. Also clear any prior
    // out-of-range flag carried over from the previous positionKey.
    if (mounted && (!_isStreamStale || _isOutOfRange)) {
      setState(() {
        _isStreamStale = true;
        _isOutOfRange = false;
      });
    } else {
      _isStreamStale = true;
      _isOutOfRange = false;
    }
  }

  void _onStreamData(DynamicValue dv) {
    // Plan 04-04 (QUAL-08) — when simulate is ON the simulation owns
    // `_progress`. Early-return so a live PLC emission can't fight the
    // periodic timer. We still let the stale/out-of-range flags stay
    // accurate against the live stream (handled by the timer path) so
    // the painter visuals reflect simulated state, not stream state.
    if (widget.config.simulate ?? false) {
      return;
    }
    // Guard for non-double / non-integer values (per analog_box.dart
    // precedent). `.asDouble` throws or coerces depending on type;
    // require explicit guard.
    final raw = _coerceDouble(dv);
    if (raw == null) {
      if (!_isStreamStale && mounted) {
        setState(() => _isStreamStale = true);
      }
      return;
    }
    // Out-of-range detection (ELEV-15) — flag BEFORE clamping so the
    // painter can surface the amber outline. NaN is also flagged so the
    // operator sees a fault rather than a silent grey-stale render.
    final outOfRange = raw.isNaN || raw < 0.0 || raw > 100.0;
    _progress.value = platformProgress(raw);
    final wasStale = _isStreamStale;
    final wasOutOfRange = _isOutOfRange;
    if (mounted && (wasStale || wasOutOfRange != outOfRange)) {
      setState(() {
        _isStreamStale = false;
        _isOutOfRange = outOfRange;
      });
    } else {
      // No setState needed (mounted=false or no flag changes) — but
      // keep the field in sync for any future reads.
      _isStreamStale = false;
      _isOutOfRange = outOfRange;
    }
  }

  /// Test seam — drive a synthetic [DynamicValue] through the same
  /// listener path a real stream would. Used by the ELEV-15 widget tests
  /// in `elevator_widget_test.dart` so out-of-range behaviour can be
  /// asserted without a full StateMan stub. Production code MUST NOT
  /// depend on this method.
  @visibleForTesting
  void debugInjectRaw(DynamicValue dv) => _onStreamData(dv);

  void _onStreamError(Object error, StackTrace st) {
    // Stale and out-of-range are mutually exclusive (CONTEXT §decisions /
    // ELEV-15). Errors fall back to the grey stale palette — clear the
    // amber outline if it was previously raised.
    if (mounted && (!_isStreamStale || _isOutOfRange)) {
      setState(() {
        _isStreamStale = true;
        _isOutOfRange = false;
      });
    } else {
      _isStreamStale = true;
      _isOutOfRange = false;
    }
  }

  /// Coerces a [DynamicValue] to a double if it carries a numeric
  /// payload; returns null otherwise (stale path).
  double? _coerceDouble(DynamicValue dv) {
    try {
      return dv.asDouble;
    } catch (_) {
      return null;
    }
  }

  /// Test seam — production code MUST NOT depend on this getter.
  /// Used by the Pitfall 2 stream-lifecycle regression test in
  /// `elevator_widget_test.dart` (Cycle B) to assert
  /// `identical(oldStream, newStream)` across rebuilds with same
  /// positionKey.
  @visibleForTesting
  Stream<DynamicValue>? get debugPositionStream => _positionStream;

  /// Test seam — exposes the live ValueNotifier so animation tests
  /// can assert progress.value reflects the most recent emission
  /// without poking into private state.
  @visibleForTesting
  ValueListenable<double> get debugProgress => _progress;

  /// Effective stale flag fed to the painter — true when no key is
  /// configured OR the stream has not produced a usable double yet OR
  /// the stream errored.
  bool get _isStaleEffective =>
      widget.config.positionKey.isEmpty || _isStreamStale;

  /// Identity of this elevator's docked pane. Tapping the same elevator
  /// twice toggles the pane; opening another asset's pane replaces it.
  String get _paneId => 'elevator:${identityHashCode(widget.config)}';

  /// Opens the read-only details pane (Plan 04-05 / ELEV-01).
  ///
  /// Operators tap the elevator at runtime to inspect current state —
  /// position key, current progress, tween duration, simulate flag,
  /// out-of-range/stale flags, child count. The pane is purely
  /// informational: no PLC writes, no config edits. Configuration is
  /// editor-only and routed through `page_editor.dart` →
  /// `ElevatorConfig.configure(context)`.
  ///
  /// Since Plan 260811 this is a non-modal [SidePane] instead of an
  /// `AlertDialog`: the plant view behind it keeps running, so an operator
  /// can watch the lift move while reading its numbers. That also lets the
  /// body listen to `_progress` — the pane lives in its own overlay subtree,
  /// so a 50ms simulator tick rebuilds only these few rows and never the
  /// elevator itself (the reason the old dialog froze its value at
  /// open-time). `_progress` is owned by this State, so the pane MUST be
  /// closed from [dispose] before the notifier goes away.
  void _showDetailsPane(BuildContext context) {
    showSidePane(
      context: context,
      id: _paneId,
      builder: (paneContext) => ValueListenableBuilder<double>(
        valueListenable: _progress,
        builder: (paneContext, progress, _) {
          final pct = (progress.clamp(0.0, 1.0) * 100).round();
          final simulating = widget.config.simulate ?? false;
          final stale = _isStaleEffective;
          final outOfRange = _isOutOfRange && !stale;
          final positionText = simulating
              ? 'simulating ($pct%)'
              : (stale ? '— (stale)' : '$pct%');
          return SidePane(
            title: 'Elevator',
            subtitle: widget.config.positionKey.isEmpty
                ? 'no position key'
                : widget.config.positionKey,
            icon: Icons.elevator,
            status: stale
                ? const PaneStatus.stale()
                : outOfRange
                    ? const PaneStatus.warning('Out of range')
                    : simulating
                        ? const PaneStatus.running('Simulating')
                        : const PaneStatus.running('Live'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                PaneSection(
                  title: 'Position',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PaneTileRow(
                        children: [
                          PaneMetricTile(
                            label: 'Travel',
                            value: stale && !simulating ? '—' : '$pct',
                            unit: '%',
                            icon: Icons.height,
                          ),
                          PaneMetricTile(
                            label: 'Tween',
                            value: '${widget.config.tweenDurationMs}',
                            unit: 'ms',
                            icon: Icons.timer_outlined,
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      // Always determinate: an indeterminate bar would
                      // animate forever, which reads as "moving" on a stale
                      // lift and never lets a test settle. Staleness is
                      // carried by the status chip and the Stale row.
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: progress.clamp(0.0, 1.0),
                          minHeight: 8,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                PaneSection(
                  title: 'Details',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PaneDetailRow(
                        label: 'Position key',
                        value: widget.config.positionKey.isEmpty
                            ? '—'
                            : widget.config.positionKey,
                      ),
                      PaneDetailRow(
                        label: 'Current position',
                        value: positionText,
                      ),
                      PaneDetailRow(
                        label: 'Tween duration',
                        value: '${widget.config.tweenDurationMs} ms',
                      ),
                      PaneDetailRow(
                        label: 'Out-of-range',
                        value: outOfRange ? 'yes' : 'no',
                      ),
                      PaneDetailRow(
                        label: 'Stale',
                        value: stale ? 'yes' : 'no',
                      ),
                      PaneDetailRow(
                        label: 'Simulate motion',
                        value: simulating ? 'on' : 'off',
                      ),
                      PaneDetailRow(
                        label: 'Children',
                        value: '${widget.config.children.length} attached',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    // The pane's body listens to `_progress`, which dies with this State —
    // and a docked pane outlives the route that opened it. Close it first.
    closeSidePane(id: _paneId, immediate: true);
    _streamSub?.cancel();
    // Plan 04-04 — cancel the simulation timer (if running) BEFORE
    // disposing the progress notifier so a final tick can't fire on
    // the disposed notifier (QUAL-07 + QUAL-08 leak contract).
    _simTimer?.cancel();
    _simTimer = null;
    _progress.dispose();
    _animProgress.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Phase 3 — child composition
  //
  // CONTEXT §Hit-Test Through Translation: children's hit-test follows
  // their `Positioned.top` value — Flutter's hit-test walks the layout
  // tree, so Positioned-driven layout means taps land on the rendered
  // glyph regardless of platform position. This is the user's locked
  // directive (ELEV-19 / Pitfall 7) — DO NOT replace Positioned with
  // Transform.translate around children.
  //
  // CONTEXT §Child Layout & Identity:
  //   - Stack(clipBehavior: Clip.none) so children may extend outside
  //     the elevator bbox during translation without being clipped.
  //   - Each child wrapper carries ValueKey<String>(entry.id) — the UUID
  //     locked in Plan 02-02's ElevatorChildEntry schema (ELEV-12).
  //   - Each child renders via entry.child.build(context) — the elevator
  //     NEVER switches on child runtime type (ELEV-11, ARCHITECTURE
  //     Anti-Pattern 1).
  //   - Each child's bottom edge sits on the platform's top edge:
  //     `top = platformOffsetTop(progress, bboxH, platformH) - childH`.
  // ---------------------------------------------------------------------------

  /// Builds the Stack that composes the elevator visuals: painter at
  /// index 0, then one Positioned per ElevatorChildEntry. Driven by
  /// `_animProgress` so children translate in lock-step with the
  /// platform.
  Widget _buildStack(
    Size paintSize,
    bool isStale,
    bool isOutOfRange,
    Color activeColor,
  ) {
    // Platform deck height — MUST match `kPlatformHeightFraction` in
    // elevator_painter.dart so children anchor exactly to the painted
    // platform's top edge. The fraction is the painter's source of
    // truth; we import the constant directly to keep the two values
    // welded together.
    final platformH = paintSize.height * kPlatformHeightFraction;
    // Travel range driver (Plan 260511-fd6 / ELEV-10): `config.travelRange`
    // fraction of bbox height, clamped to headroom so the platform never
    // overhangs the bbox top. Replaces the auto-deduce from children's
    // heights (Plan 260511-dxa) — see plan SUMMARY for rationale. The
    // local name `maxChildHeight` is preserved so downstream callers
    // (ElevatorPainter + _buildPositionedChild) need no rename; it now
    // means "effective travel in pixels" rather than "tallest child
    // height".
    final maxChildHeight =
        (widget.config.travelRange.clamp(0.0, 1.0) * paintSize.height)
            .clamp(0.0, paintSize.height - platformH);
    final children = <Widget>[
      CustomPaint(
        size: paintSize,
        painter: ElevatorPainter(
          progress: _animProgress,
          isStale: isStale,
          isOutOfRange: isOutOfRange,
          activeColor: activeColor,
          maxChildHeight: maxChildHeight,
        ),
      ),
      for (final entry in widget.config.children)
        _buildPositionedChild(entry, paintSize, platformH, maxChildHeight),
    ];
    return SizedBox(
      width: paintSize.width,
      height: paintSize.height,
      child: Stack(clipBehavior: Clip.none, children: children),
    );
  }

  /// Builds a Positioned wrapper for a single child entry. The child
  /// subtree is built ONCE and cached as the inner ValueListenableBuilder's
  /// `child:` parameter — only the Positioned (and its `top`) rebuilds
  /// per `_animProgress` change. This preserves the child's State
  /// identity across frames (Pitfall 1: 50 progress changes → 1 initState
  /// call). The KeyedSubtree carrying the `ValueKey<String>(entry.id)`
  /// is what Flutter's element-reconciliation algorithm uses to
  /// recognise the subtree as the same instance even if the child list
  /// is mutated.
  Widget _buildPositionedChild(
    ElevatorChildEntry entry,
    Size paintSize,
    double platformH,
    double maxChildHeight,
  ) {
    final intrinsic = entry.child.size.toSize(paintSize);
    final childW =
        intrinsic.width <= 0 ? paintSize.shortestSide / 4 : intrinsic.width;
    final childH =
        intrinsic.height <= 0 ? paintSize.shortestSide / 4 : intrinsic.height;
    final left = entry.offsetX * paintSize.width - childW / 2;
    return ValueListenableBuilder<double>(
      valueListenable: _animProgress,
      child: KeyedSubtree(
        key: ValueKey<String>(entry.id),
        child: SizedBox(
          width: childW,
          height: childH,
          child: entry.child.build(context),
        ),
      ),
      builder: (ctx, animProgress, builtChild) {
        final platformY = platformOffsetTop(
          animProgress,
          paintSize.height,
          platformH,
          maxChildHeight,
        );
        // Anchor offset (260511-ehy): `top = platformY - childH * (1 + offsetY)`.
        // offsetY = 0 keeps bottom-on-platform (Plan 260511-dxa invariant).
        // Positive offsetY raises the child; negative lowers it. Unclamped —
        // Stack(clipBehavior: Clip.none) tolerates overhang per Pitfall 7.
        final top = platformY - childH * (1.0 + entry.offsetY);
        return Positioned(
          left: left,
          top: top,
          width: childW,
          height: childH,
          child: builtChild!,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final angleDeg = widget.config.coordinates.angle ?? 0.0;
    final activeColor = Theme.of(context).colorScheme.primary;
    // The detector sits INSIDE the rotation, as on the sensor and the
    // conveyor: an opaque detector outside it claims the unrotated w×h rect
    // and nothing else, so on a turned elevator it both swallowed taps meant
    // for whatever sits in that rect and ignored the part of the visual that
    // rotates out of it.
    return LayoutRotatedBox(
      angle: angleDeg * pi / 180,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _showDetailsPane(context),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final Size paintSize;
            if (constraints.hasBoundedWidth && constraints.hasBoundedHeight) {
              paintSize = Size(constraints.maxWidth, constraints.maxHeight);
            } else {
              paintSize =
                  widget.config.size.toSize(MediaQuery.of(context).size);
            }
            // Animation pipeline (ELEV-06):
            //   _progress (target 0..1, written by stream listener)
            //   → ValueListenableBuilder<double>
            //     → TweenAnimationBuilder<double>
            //       → _animProgress (per-frame interpolated value)
            //         → ElevatorPainter.progress (super(repaint:))
            //
            // The Tween's `Tween(begin: target, end: target)` idiom (per
            // CONTEXT decisions §Visual & Position Pipeline) lets each
            // change in _progress.value drive a fresh interpolation toward
            // the new target — no animation while values are equal, smooth
            // glide when the target moves. Curves.linear matches operator
            // expectation for industrial position lifts (no overshoot).
            return ValueListenableBuilder<double>(
              valueListenable: _progress,
              builder: (ctx, target, _) {
                return TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: target, end: target),
                  duration: Duration(
                    milliseconds: widget.config.tweenDurationMs,
                  ),
                  curve: Curves.linear,
                  builder: (ctx, animValue, _) {
                    // Push the animated value into the per-frame notifier
                    // so the painter's super(repaint:) sees changes
                    // without rebuilding the CustomPaint subtree itself.
                    _animProgress.value = animValue;
                    return _buildStack(
                      paintSize,
                      _isStaleEffective,
                      // Stale and out-of-range are mutually exclusive
                      // (ELEV-15) — never raise the amber outline while
                      // the painter is also rendering grey.
                      _isOutOfRange && !_isStaleEffective,
                      activeColor,
                    );
                  },
                );
              },
            );
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Details rows (Plan 04-05 / ELEV-01)
// ---------------------------------------------------------------------------
//
// The private `_DetailRow` helper that used to live here was the third copy
// of the same label/value row (sensor.dart, conveyor.dart, here) — it is now
// `PaneDetailRow` in widgets/panes/pane_chrome.dart, shared by every pane and
// dialog, exactly as the old TODO on this helper asked for.

// ---------------------------------------------------------------------------
// Config editor — the body of the configure dialog.
// ---------------------------------------------------------------------------

/// Editor body for `ElevatorConfig`. Mirrors `_SensorConfigEditor` but
/// skips colour/kind/preview controls (elevator has only one variant
/// and no per-instance colour overrides in this phase). The "Children"
/// section is a read-only placeholder in Phase 2 — the schema is locked
/// (Plan 02-02) but the list-management UI lands in Phase 3.
///
/// All edits are mutations on the live `widget.config` instance — the
/// page editor reuses the same config object across rebuilds, so the
/// parent's page model picks the changes up automatically (see
/// `Elevator.didUpdateWidget` for the matching invariant on the runtime
/// side — re-hoists position stream when `positionKey` changes).
class _ElevatorConfigEditor extends StatefulWidget {
  final ElevatorConfig config;
  const _ElevatorConfigEditor({required this.config});

  @override
  State<_ElevatorConfigEditor> createState() => _ElevatorConfigEditorState();
}

class _ElevatorConfigEditorState extends State<_ElevatorConfigEditor> {
  /// Hard-coded factory map per CONTEXT §specifics + ELEV-07. The user
  /// explicitly locked the dropdown to {Sensor, Conveyor} — do NOT iterate
  /// `AssetRegistry.defaultFactories` and filter; the explicit list is the
  /// safer expression of the locked decision (T-03-08 mitigation).
  ///
  /// REGRESSION GUARD: locked by `test/page_creator/assets/elevator_widget_test.dart`
  /// group 'Editor — child management (ELEV-07, ELEV-08)' — specifically the
  /// 'Add child opens dropdown filtered to Sensor and Conveyor only' test
  /// with 3 negative assertions (LED, Number, Button). If you change this
  /// map, that test must continue to pass.
  static final Map<String, BaseAsset Function()> _allowedChildFactories = {
    'Sensor': SensorConfig.preview,
    'Conveyor': ConveyorConfig.preview,
  };


  /// Opens a `SimpleDialog` listing the allowed child factories. Picking
  /// one appends a new `ElevatorChildEntry` with auto-generated UUID and
  /// `offsetX = 0.5` default.
  ///
  /// SimpleDialog (rather than `showMenu` or PopupMenuButton) is chosen
  /// for test-friendliness: the option labels are reliably findable via
  /// `find.text('Sensor')` after `pumpAndSettle()`.
  Future<void> _onAddChildPressed(BuildContext context) async {
    final selected = await showDialog<String>(
      context: context,
      // A plain option list, in the standard frame. Kept findable by label
      // (`find.text('Sensor')`) for the ELEV-07 tests.
      builder: (dialogCtx) => StandardDialogFrame(
        title: 'Add child',
        icon: Icons.add,
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _allowedChildFactories.keys
              .map((name) => ListTile(
                    title: Text(name),
                    onTap: () => Navigator.of(dialogCtx).pop(name),
                  ))
              .toList(),
        ),
      ),
    );
    if (selected == null) return;
    final factory = _allowedChildFactories[selected]!;
    setState(() {
      widget.config.children.add(ElevatorChildEntry(
        // id auto-generated by ElevatorChildEntry constructor
        // (microsecondsSinceEpoch.toString()).
        offsetX: 0.5,
        child: factory(),
      ));
    });
  }

  /// Recursive edit dispatch — opens the child's own `configure(context)`
  /// dialog wrapped in a `Dialog` (mirrors `_ElevatorState._openConfigDialog`
  /// so the child's TextField/KeyField widgets find a Material ancestor).
  /// On dismissal, `setState` refreshes this editor in case the child's
  /// fields changed (ELEV-08).
  void _onEditChildPressed(BuildContext context, ElevatorChildEntry entry) {
    showStandardDialog<void>(
      context: context,
      title: entry.child.displayName,
      subtitle: 'Configuration',
      builder: (_) => entry.child.configure(context),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  /// Removes the entry from `widget.config.children` and refreshes the
  /// editor. No confirmation dialog — matches `conveyor.dart` precedent
  /// (operator authority surface; T-03-09 accepted).
  void _onRemoveChildPressed(ElevatorChildEntry entry) {
    setState(() {
      widget.config.children.removeWhere((e) => e.id == entry.id);
    });
  }

  /// Swaps `entry` with its `delta`-neighbour in `widget.config.children`.
  /// `delta = +1` raises z (moves later in the list = paints on top).
  /// `delta = -1` lowers z (moves earlier in the list = paints behind).
  ///
  /// Looks up the index by `entry.id` (not by widget order) so the handler
  /// is robust against display reversal — the editor displays
  /// `children.reversed`, but mutations are always on the underlying list.
  /// No-op if the entry is missing or the swap target is out of bounds
  /// (defensive — UI buttons disable at the boundary, but the handler is
  /// the safety net per T-04-03-A).
  void _onReorderChildPressed(ElevatorChildEntry entry, int delta) {
    final list = widget.config.children;
    final i = list.indexWhere((e) => e.id == entry.id);
    if (i < 0) return;
    final j = i + delta;
    if (j < 0 || j >= list.length) return;
    setState(() {
      final tmp = list[i];
      list[i] = list[j];
      list[j] = tmp;
    });
  }

  @override
  Widget build(BuildContext context) {
    final config = widget.config;

    return Container(
      width: 360,
      padding: const EdgeInsets.all(24), // mirrors sensor.dart UI-SPEC lg = 24
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // -- Position State Key (ELEV-04 surface) --
            KeyField(
              label: 'Position State Key (0-100%)',
              initialValue: config.positionKey,
              onChanged: (v) => setState(() => config.positionKey = v),
            ),
            const SizedBox(height: 8),

            // -- Plan 260511-fd6: Travel range (fraction of bbox height) --
            //   Operator-explicit fraction [0..1] of bbox height for the
            //   platform's vertical travel range. Replaces the auto-deduce
            //   from child heights (Plan 260511-dxa). Sits between the
            //   position key and the simulate switch so it is visible
            //   without scrolling on the default 600px test viewport.
            NumberSlider(
              labelAbove: true,
              label: 'Travel range (% of bbox height)',
              min: 0.0,
              max: 1.0,
              divisions: 100,
              displayScale: 100,
              suffix: '%',
              value: config.travelRange.clamp(0.0, 1.0),
              onChanged: (v) => setState(() => config.travelRange = v),
            ),
            Text(
              'Higher = platform travels more vertically. '
              'Children may overshoot the bbox at high values.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),

            // -- Plan 04-04 (QUAL-08): Simulate motion --
            //   When ON, the runtime ignores the live PLC stream and
            //   animates the platform smoothly between 0% and 100% on a
            //   fixed cycle. Useful for previewing pages without a live
            //   PLC. The `simulate` field on ElevatorConfig is nullable
            //   with `includeIfNull:false` so legacy saved pages omit
            //   the key entirely (back-compat).
            //
            //   Using a SwitchListTile with `dense: true` and zero
            //   contentPadding so it fits compactly into the editor
            //   alongside the existing fields without pushing the
            //   "Add child" button below the default 600-px test
            //   viewport. Tests still find it via
            //   `find.widgetWithText(SwitchListTile, 'Simulate motion')`.
            SwitchListTile(
              title: const Text('Simulate motion'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: config.simulate ?? false,
              onChanged: (v) => setState(() => config.simulate = v),
            ),
            const SizedBox(height: 8),

            // -- Tween Duration --
            DurationField(
              value: Duration(milliseconds: config.tweenDurationMs),
              labelText: 'Tween Duration',
              helperText: 'smoothing for platform position changes',
              min: Duration.zero,
              max: const Duration(seconds: 10),
              units: const [DurationUnit.milliseconds, DurationUnit.seconds],
              // The config stores whole milliseconds.
              resolution: const Duration(milliseconds: 1),
              onChanged: (v) =>
                  setState(() => config.tweenDurationMs = v.inMilliseconds),
            ),
            const SizedBox(height: 16),

            // -- Size --
            SizeField(
              initialValue: config.size,
              onChanged: (v) => setState(() => config.size = v),
            ),
            const SizedBox(height: 16),

            // -- Coordinates (includes angle slider — enableAngle: true,
            //    same as Sensor / Conveyor) --
            CoordinatesField(
              initialValue: config.coordinates,
              onChanged: (c) => setState(() => config.coordinates = c),
              enableAngle: true,
            ),
            const SizedBox(height: 16),
            const Divider(),

            // -- Children (Phase 3 / Plan 03-03 — full add/edit/remove UI;
            //    mirrors conveyor.dart:382-465 precedent. Dropdown is
            //    hard-coded to {Sensor, Conveyor} per CONTEXT §specifics +
            //    ELEV-07, locked by widget tests with 3 negative
            //    assertions). --
            Text('Children', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: () => _onAddChildPressed(context),
              icon: const Icon(Icons.add),
              label: const Text('Add child'),
            ),
            const SizedBox(height: 8),
            if (config.children.isEmpty)
              Text(
                'No children configured',
                style: Theme.of(context).textTheme.bodyMedium,
              )
            else
              // Display children in REVERSED order (Photoshop / Figma
              // convention) — topmost paint (highest z =
              // config.children[N-1]) appears at the TOP of the editor
              // list. The actual index in config.children is computed
              // from the display index so the reorder handler still
              // mutates the underlying list correctly. Stack composition
              // in build() iterates config.children directly, so
              // reordering the list naturally re-orders paint order
              // without touching the runtime widget.
              ...config.children.reversed
                  .toList()
                  .asMap()
                  .entries
                  .map((displayed) {
                final displayIndex = displayed.key;
                final entry = displayed.value;
                final actualIndex = config.children.length - 1 - displayIndex;
                final isTopmost = actualIndex == config.children.length - 1;
                final isBottommost = actualIndex == 0;
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
                              child: Text(
                                entry.child.displayName,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.arrow_upward, size: 20),
                              tooltip: 'Move forward (paint on top)',
                              onPressed: isTopmost
                                  ? null
                                  : () => _onReorderChildPressed(entry, 1),
                            ),
                            IconButton(
                              icon: const Icon(Icons.arrow_downward, size: 20),
                              tooltip: 'Move backward (paint behind)',
                              onPressed: isBottommost
                                  ? null
                                  : () => _onReorderChildPressed(entry, -1),
                            ),
                            IconButton(
                              icon: const Icon(Icons.edit, size: 20),
                              tooltip: 'Edit child',
                              onPressed: () =>
                                  _onEditChildPressed(context, entry),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete, size: 20),
                              tooltip: 'Remove child',
                              onPressed: () => _onRemoveChildPressed(entry),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        NumberSlider(
                          labelAbove: true,
                          label: 'Lateral position',
                          min: 0.0,
                          max: 1.0,
                          divisions: 100,
                          displayScale: 100,
                          suffix: '%',
                          value: entry.offsetX,
                          onChanged: (v) => setState(() => entry.offsetX = v),
                        ),
                        NumberSlider(
                          labelAbove: true,
                          label: 'Vertical offset (% of child height)',
                          min: -1.0,
                          max: 1.0,
                          divisions: 200,
                          displayScale: 100,
                          suffix: '%',
                          value: entry.offsetY,
                          onChanged: (v) => setState(() => entry.offsetY = v),
                        ),
                      ],
                    ),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}

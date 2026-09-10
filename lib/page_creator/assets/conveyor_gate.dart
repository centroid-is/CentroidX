import 'dart:math';


import 'package:logger/logger.dart';

import 'package:flutter/material.dart';
import 'package:tfc/widgets/panes/color_picker_dialog.dart';
import 'package:tfc/widgets/number_slider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:open62541/open62541.dart' show DynamicValue, NodeId;
import 'package:rxdart/rxdart.dart';
import '../../theme.dart';
import '../../widgets/hit_boundary.dart';
import '../../widgets/panes/pane_chrome.dart';
import '../../widgets/panes/side_pane.dart';

import 'package:tfc/converter/color_converter.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/conveyor_gate_painter.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/widgets/tag_access_guard.dart';
import '../../widgets/duration_field.dart';
import '../../widgets/memo_stream_builder.dart';

part 'conveyor_gate.g.dart';

/// File-level logger. These diagnostics used to go to stderr, which in a
/// windowed MSIX build with no console is discarded outright.
final Logger _log = Logger();

/// Color helpers for JSON serialization: legacy records hold a raw ARGB int
/// (a literal), newer ones may hold `{"role": ...}` (follows the scheme).
Object _colorToJson(AssetColor c) => c.role != null
    ? const AssetColorConverter().toJson(c)
    : c.literal!.toARGB32();
AssetColor _colorFromJson(dynamic v) => v is int
    ? AssetColor.literal(Color(v))
    : const AssetColorConverter().fromJson((v as Map).cast<String, dynamic>());

/// The type of gate mechanism.
@JsonEnum()
enum GateVariant {
  pneumatic,
  slider,
  pusher,
}

/// Which side the gate flap hinges from.
@JsonEnum()
enum GateSide {
  left,
  right,
}

/// Wrapper for a gate placed as a child of a conveyor belt.
///
/// Holds conveyor-specific placement metadata (position along the belt and
/// which side the gate is on) separately from the gate's own configuration.
@JsonSerializable(explicitToJson: true)
class ChildGateEntry {
  /// Fractional position along conveyor belt (0.0 = start, 1.0 = end).
  double position;

  @JsonKey(unknownEnumValue: GateSide.left)
  GateSide side;

  @JsonKey(fromJson: _gateFromJson, toJson: _gateToJson)
  ConveyorGateConfig gate;

  ChildGateEntry({
    this.position = 0.5,
    this.side = GateSide.left,
    required this.gate,
  });

  factory ChildGateEntry.fromJson(Map<String, dynamic> json) =>
      _$ChildGateEntryFromJson(json);
  Map<String, dynamic> toJson() => _$ChildGateEntryToJson(this);
}

ConveyorGateConfig _gateFromJson(Map<String, dynamic> json) =>
    ConveyorGateConfig.fromJson(json);
Map<String, dynamic> _gateToJson(ConveyorGateConfig gate) => gate.toJson();

/// Configuration for a conveyor gate asset.
///
/// Extends [BaseAsset] with fields specific to the pneumatic diverter gate:
/// variant type, hinge side, OPC UA state key, opening angle, animation timing,
/// and configurable open/closed colors.
@JsonSerializable(explicitToJson: true)
class ConveyorGateConfig extends BaseAsset {
  @override
  String get displayName => 'Conveyor Gate';

  @override
  String get category => 'Visualization';

  @JsonKey(unknownEnumValue: GateVariant.pneumatic)
  GateVariant gateVariant;

  @JsonKey(unknownEnumValue: GateSide.left)
  GateSide side;

  String stateKey;

  double openAngleDegrees;

  int openTimeMs;

  int? closeTimeMs;

  @JsonKey(fromJson: _colorFromJson, toJson: _colorToJson)
  AssetColor openColor;

  @JsonKey(fromJson: _colorFromJson, toJson: _colorToJson)
  AssetColor closedColor;

  /// For slider variant: when true, active/open state pushes lid OUT.
  /// When false, active state pulls lid IN (retracted).
  bool sliderActiveOut;

  /// For slider variant: angle of the lid in degrees (0 = perpendicular).
  double sliderLidAngleDegrees;

  /// For slider variant: lid length as fraction of gate width (0.1–1.0).
  double sliderLidLength;

  /// For slider variant: actuation travel as fraction of available range (0.1–1.0).
  double sliderActuationLength;

  /// OPC UA key to write a force-open command (DATA-02).
  String forceOpenKey;

  /// OPC UA key to subscribe for force-open active feedback (DATA-03).
  String forceOpenFeedbackKey;

  /// OPC UA key to write a force-close command (DATA-04).
  String forceCloseKey;

  /// OPC UA key to subscribe for force-close active feedback (DATA-05).
  String forceCloseFeedbackKey;

  ConveyorGateConfig({
    this.gateVariant = GateVariant.pneumatic,
    this.side = GateSide.left,
    this.stateKey = '',
    this.openAngleDegrees = 45.0,
    this.openTimeMs = 800,
    this.closeTimeMs,
    this.openColor = AssetColor.green,
    this.closedColor = const AssetColor.literal(Colors.white),
    this.sliderActiveOut = true,
    this.sliderLidAngleDegrees = 0.0,
    this.sliderLidLength = 0.55,
    this.sliderActuationLength = 1.0,
    this.forceOpenKey = '',
    this.forceOpenFeedbackKey = '',
    this.forceCloseKey = '',
    this.forceCloseFeedbackKey = '',
  });

  /// Preview factory with reasonable defaults for the asset palette.
  ConveyorGateConfig.preview() : this();

  factory ConveyorGateConfig.fromJson(Map<String, dynamic> json) =>
      _$ConveyorGateConfigFromJson(json);

  @override
  Map<String, dynamic> toJson() => _$ConveyorGateConfigToJson(this);

  @override
  Widget build(BuildContext context) {
    return ConveyorGate(config: this);
  }

  @override
  Widget configure(BuildContext context) =>
      _ConveyorGateConfigEditor(config: this);
}

/// Subscribe to a boolean OPC UA feedback key.
///
/// Returns a stream that emits `false` immediately and then tracks the live
/// value. When [key] is empty the stream emits a single `false` (no-op).
Stream<bool> _boolFeedback(WidgetRef ref, String key) {
  if (key.isEmpty) return Stream.value(false);
  return ref
      .watch(keyStreamProvider(key))
      .map((v) => v.asBool)
      .startWith(false);
}

// ---------------------------------------------------------------------------
// Runtime widget with animation and OPC UA data binding
// ---------------------------------------------------------------------------

/// Animated conveyor gate driven by an OPC UA boolean state key.
///
/// The gate subscribes to [ConveyorGateConfig.stateKey] via [stateManProvider]
/// and smoothly animates between open (true) and closed (false) positions using
/// an ease-out curve. When the key is empty or OPC UA data is unavailable, the
/// gate renders in grey.
class ConveyorGate extends ConsumerStatefulWidget {
  final ConveyorGateConfig config;
  const ConveyorGate({super.key, required this.config});

  @override
  ConsumerState<ConveyorGate> createState() => _ConveyorGateState();
}

class _ConveyorGateState extends ConsumerState<ConveyorGate>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final ValueNotifier<double> _progress;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: widget.config.openTimeMs),
    );
    _progress = ValueNotifier<double>(0.0);
    _controller.addListener(() {
      _progress.value = Curves.easeOut.transform(_controller.value);
    });
  }

  @override
  void dispose() {
    // The pane outlives this widget's route otherwise.
    closeSidePane(id: _paneId, immediate: true);
    _controller.dispose();
    _progress.dispose();
    super.dispose();
  }

  /// Trigger animation toward open or closed.
  ///
  /// Sets the appropriate duration before animating so that open and close
  /// speeds can differ. Called on every OPC UA state change, including after
  /// reconnects, ensuring the visual always matches the live state.
  void _onStateChanged(bool isOpen) {
    if (isOpen) {
      _controller.duration = Duration(milliseconds: widget.config.openTimeMs);
      _controller.forward();
    } else {
      _controller.duration = Duration(
        milliseconds: widget.config.closeTimeMs ?? widget.config.openTimeMs,
      );
      _controller.reverse();
    }
  }

  /// Selects the correct painter based on [ConveyorGateConfig.gateVariant].
  ///
  /// [paintSize] is the box the gate is drawn in. The diverter needs it to
  /// answer where its arm is: `CustomPainter.hitTest` is not given a size, so
  /// a painter that claims only its own ink has to be told one.
  CustomPainter _createPainter(Color stateColor, Size paintSize) {
    switch (widget.config.gateVariant) {
      case GateVariant.pneumatic:
        return PneumaticDiverterPainter(
          progress: _progress,
          stateColor: stateColor,
          openAngleDegrees: widget.config.openAngleDegrees,
          side: widget.config.side,
          paintSize: paintSize,
        );
      case GateVariant.slider:
        return SliderGatePainter(
          progress: _progress,
          stateColor: stateColor,
          side: widget.config.side,
          activeOut: widget.config.sliderActiveOut,
          lidAngleDegrees: widget.config.sliderLidAngleDegrees,
          lidLengthFraction: widget.config.sliderLidLength,
          actuationLengthFraction: widget.config.sliderActuationLength,
        );
      case GateVariant.pusher:
        return PusherGatePainter(
          progress: _progress,
          stateColor: stateColor,
          side: widget.config.side,
        );
    }
  }

  /// Builds the gate, with its tap target INSIDE the rotation.
  ///
  /// The detector used to be added by each caller, around the whole of this
  /// — outside `LayoutRotatedBox`. Every render object out there hit-tests
  /// against its own box, and that box is the gate's *unrotated* rect, so a
  /// gate that is not square and carries an angle only answered where the
  /// rotated visual crosses that rect. Building it here keeps the detector
  /// under the rotation, which hands it positions already mapped into the
  /// unrotated frame. Same arrangement as the sensor and the conveyor.
  Widget _buildGate(Color stateColor, {bool interactive = false}) {
    Widget paint = LayoutBuilder(
      builder: (context, constraints) {
        // When placed inside a Positioned with explicit size (child-of-conveyor),
        // use the constraints directly. Otherwise fall back to config.size (standalone).
        final Size paintSize;
        if (constraints.hasBoundedWidth && constraints.hasBoundedHeight) {
          paintSize = Size(constraints.maxWidth, constraints.maxHeight);
        } else {
          paintSize = widget.config.size.toSize(MediaQuery.of(context).size);
        }
        final painter = _createPainter(stateColor, paintSize);
        final Widget face = CustomPaint(size: paintSize, painter: painter);
        // A diverter takes taps on the arm as drawn, not on the box it is laid
        // out in, so it publishes that rectangle for the mark the plant view
        // draws while its pane is open — the same one `hitTest` answers from.
        // The other variants fill their box and publish nothing.
        return painter is PneumaticDiverterPainter
            ? AssetHitShape(
                shape: () => Path()..addRect(painter.tapTarget(paintSize)),
                child: face,
              )
            : face;
      },
    );
    if (interactive) {
      paint = GestureDetector(
        onTap: () => _showForcePane(context),
        child: paint,
      );
    }
    return LayoutRotatedBox(
      angle: (widget.config.coordinates.angle ?? 0.0) * pi / 180,
      child: paint,
    );
  }

  /// Write a boolean value to an OPC UA force key.
  ///
  /// No member: a force key is its own BOOL node, so the question is about the
  /// key as a whole. A refused force never reaches the PLC — `writeTag` has
  /// already prompted and returns false — and the `catch` below is left for
  /// the comms failure it was written for.
  Future<void> _writeForce(String key, bool value) async {
    if (key.isEmpty) return;
    try {
      final client = await ref.read(stateManProvider.future);
      await writeTag(
        ref,
        client,
        key,
        DynamicValue(value: value, typeId: NodeId.boolean),
      );
    } catch (e) {
      // The logger, not stderr: a force write that silently fails looks
      // identical to a stuck PLC bit from the operator's side, and stderr in
      // a windowed MSIX build is exactly as silent as writing nothing.
      _log.e('ConveyorGate: failed to write force key "$key": $e');
    }
  }

  String get _paneId => 'gate:${identityHashCode(widget.config)}';

  /// Show the force-control pane (INT-02).
  ///
  /// Forcing a gate is a watch-the-gate operation, so the pane leaves the
  /// mimic visible instead of covering it the way the old dialog did.
  void _showForcePane(BuildContext context) {
    showSidePane(
      context: context,
      id: _paneId,
      builder: (_) => _GateForcePane(
        config: widget.config,
        writeForce: _writeForce,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isInteractive = widget.config.forceOpenKey.isNotEmpty ||
        widget.config.forceCloseKey.isNotEmpty;

    // When no state key is configured, render in grey (DATA-06).
    if (widget.config.stateKey.isEmpty) {
      return _buildGate(Colors.grey, interactive: isInteractive);
    }

    final forcedColor = Theme.of(context).colorScheme.tertiary;
    final hasForceFeedback = widget.config.forceOpenFeedbackKey.isNotEmpty ||
        widget.config.forceCloseFeedbackKey.isNotEmpty;

    // Read here rather than in the nested builder below. That builder belongs
    // to the `StreamBuilder`'s element, not to this one, so a `ref.watch`
    // inside it is not a watch this widget holds — the dependency would lapse
    // and the shared stream could be disposed underneath it.
    final forceFeedback = hasForceFeedback
        ? Rx.combineLatest2(
            _boolFeedback(ref, widget.config.forceOpenFeedbackKey),
            _boolFeedback(ref, widget.config.forceCloseFeedbackKey),
            (a, b) => a || b,
          )
        : null;

    return StreamBuilder<DynamicValue>(
      stream: ref.watch(keyStreamProvider(widget.config.stateKey)),
      builder: (context, snapshot) {
        // Resolve base color from OPC UA state.
        final bool isOpen = snapshot.hasData && snapshot.data!.asBool;
        _onStateChanged(isOpen);

        final Color baseColor;
        if (!snapshot.hasData) {
          baseColor = Colors.grey; // DATA-06: grey when disconnected
        } else if (isOpen) {
          baseColor = widget.config.openColor.resolve(context);
        } else {
          baseColor = widget.config.closedColor.resolve(context);
        }

        // If force feedback keys are configured, nest a second StreamBuilder
        // that overrides color when any force feedback is active (VIS-03).
        if (forceFeedback != null) {
          return StreamBuilder<bool>(
            stream: forceFeedback,
            builder: (context, fbSnapshot) {
              final forceActive = fbSnapshot.data ?? false;
              final displayColor = forceActive ? forcedColor : baseColor;
              return _buildGate(displayColor, interactive: isInteractive);
            },
          );
        }

        // No force feedback -- use base color directly.
        return _buildGate(baseColor, interactive: isInteractive);
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Force pane (the gate's SidePane)
// ---------------------------------------------------------------------------

/// Tri-state force selection: force open, no force (release), force close.
enum _ForceSelection { open, none, close }

/// A button that writes TRUE while held and FALSE when let go.
///
/// Stateful only to render the pressed look; the write is the point. Cancel
/// is treated as release -- a drag off the button must not leave the bit set.
class _HoldToPushButton extends StatefulWidget {
  final bool enabled;
  final Future<void> Function(bool down) onChanged;

  const _HoldToPushButton({required this.enabled, required this.onChanged});

  @override
  State<_HoldToPushButton> createState() => _HoldToPushButtonState();
}

class _HoldToPushButtonState extends State<_HoldToPushButton> {
  bool _down = false;

  void _set(bool down) {
    if (!widget.enabled || _down == down) return;
    setState(() => _down = down);
    widget.onChanged(down);
  }

  @override
  void dispose() {
    // Releasing on dispose matters: closing the pane mid-press would
    // otherwise leave the pusher driven out with no way to release it.
    if (_down) widget.onChanged(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const forced = Colors.orange;
    return GestureDetector(
      // Opaque, not the default deferToChild: the child is wrapped in an
      // IgnorePointer so the button cannot swallow the gesture, which also
      // makes it fail hit-testing -- and with deferToChild that means this
      // detector never sees the press at all. Same arrangement as
      // `ThirdPartyEquipment._buildBody`.
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      child: SizedBox(
        width: double.infinity,
        child: IgnorePointer(
          child: FilledButton.tonalIcon(
            icon: const Icon(Icons.east),
            label: Text(_down ? 'Pushing' : 'Press to push'),
            style: FilledButton.styleFrom(
              foregroundColor: widget.enabled ? forced : null,
              backgroundColor:
                  forced.withValues(alpha: _down ? 0.42 : 0.18),
            ),
            onPressed: widget.enabled ? () {} : null,
          ),
        ),
      ),
    );
  }
}

/// Live gate state + force feedback, combined so one stream drives both the
/// header chip and the selector highlight.
typedef _GateSnapshot = ({bool? isOpen, bool forcedOpen, bool forcedClosed});

class _GateForcePane extends ConsumerStatefulWidget {
  final ConveyorGateConfig config;
  final Future<void> Function(String key, bool value) writeForce;

  const _GateForcePane({
    required this.config,
    required this.writeForce,
  });

  @override
  ConsumerState<_GateForcePane> createState() => _GateForcePaneState();
}

class _GateForcePaneState extends ConsumerState<_GateForcePane> {
  ConveyorGateConfig get config => widget.config;
  Future<void> Function(String key, bool value) get writeForce =>
      widget.writeForce;


  /// The opposite force is cleared before the requested one is set so the
  /// PLC never sees both force commands high at once. `None` clears both —
  /// this is the unforce path.
  Future<void> _apply(_ForceSelection selection) async {
    switch (selection) {
      case _ForceSelection.open:
        await writeForce(config.forceCloseKey, false);
        await writeForce(config.forceOpenKey, true);
      case _ForceSelection.close:
        await writeForce(config.forceOpenKey, false);
        await writeForce(config.forceCloseKey, true);
      case _ForceSelection.none:
        await writeForce(config.forceOpenKey, false);
        await writeForce(config.forceCloseKey, false);
    }
  }

  String get _variantLabel => switch (config.gateVariant) {
        GateVariant.pneumatic => 'Diverter gate',
        GateVariant.slider => 'Slider gate',
        GateVariant.pusher => 'Pusher gate',
      };

  /// Header chip: an active force wins (it is the reason to be in this
  /// pane), then plain open/closed from the theme's state colors, unknown
  /// grey while there is no data.
  PaneStatus _status(BuildContext context, _GateSnapshot snap) {
    final isPusher = config.gateVariant == GateVariant.pusher;
    // A pusher has no held force to report: its command bit is momentary and
    // the PLC clears it on processing, so "Forced out" would flash for one
    // cycle and then lie. Its state key is the only honest thing to show.
    if (!isPusher) {
      if (snap.forcedOpen) return const PaneStatus.warning('Forced open');
      if (snap.forcedClosed) return const PaneStatus.warning('Forced closed');
    }
    final isOpen = snap.isOpen;
    if (isOpen == null) return const PaneStatus.unknown();
    final hmi = HmiStateColors.of(context);
    return isOpen
        ? PaneStatus(label: isPusher ? 'Out' : 'Open', color: hmi.green)
        : PaneStatus(label: isPusher ? 'In' : 'Closed', color: hmi.grey);
  }

  /// Gate open/closed as a nullable bool — null until the first value
  /// arrives, and forever when no state key is configured.
  Stream<bool?> _gateState(WidgetRef ref) {
    if (config.stateKey.isEmpty) return Stream<bool?>.value(null);
    return ref
        .watch(keyStreamProvider(config.stateKey))
        .map<bool?>((v) => v.asBool)
        .startWith(null);
  }

  @override
  Widget build(BuildContext context) {
    // Sources are Riverpod's (stable while watched); the combined wrapper is
    // kept across rebuilds so the pane does not restart on each.
    final sources = [
      config.stateKey.isEmpty ? null : ref.watch(keyStreamProvider(config.stateKey)),
      config.forceOpenFeedbackKey.isEmpty
          ? null
          : ref.watch(keyStreamProvider(config.forceOpenFeedbackKey)),
      config.forceCloseFeedbackKey.isEmpty
          ? null
          : ref.watch(keyStreamProvider(config.forceCloseFeedbackKey)),
    ];
    return MemoStreamBuilder<_GateSnapshot>(
      keys: sources,
      stream: Rx.combineLatest3(
        _gateState(ref),
        _boolFeedback(ref, config.forceOpenFeedbackKey),
        _boolFeedback(ref, config.forceCloseFeedbackKey),
        (bool? isOpen, bool fo, bool fc) =>
            (isOpen: isOpen, forcedOpen: fo, forcedClosed: fc),
      ),
      builder: (context, snapshot) {
        final snap = snapshot.data ??
            (isOpen: null, forcedOpen: false, forcedClosed: false);
        return SidePane(
          title: 'Gate',
          subtitle: _variantLabel,
          icon: Icons.swap_horiz,
          status: _status(context, snap),
          child: PaneSection(
            title: 'Force',
            // A diverter or slider is held open or closed, so it gets the
            // Open / None / Close idiom of the IO module panes. A pusher
            // instead runs one stroke and returns by itself -- there is no
            // state to hold and nothing to release -- so it gets a single
            // momentary button.
            child: config.gateVariant == GateVariant.pusher
                ? _pusherForceControls(context, snap)
                : _forceSelector(context, snap, snapshot.hasData),
          ),
        );
      },
    );
  }

  /// The pusher's manual control: one button that follows its own state.
  ///
  /// Held down the bit is TRUE, released it is FALSE, so what the operator
  /// sees under their finger is what the PLC has. The two obvious
  /// alternatives are both worse here. Writing TRUE and letting the PLC clear
  /// the bit -- `ST_Section_HMI`'s `p_cmd_*` contract -- latches forever,
  /// because `FB_Pusher` never reads the bit, let alone clears it. Pulsing it
  /// instead runs one fixed stroke out and back, which is not control, just a
  /// twitch. Following the button leaves the operator holding the pusher
  /// where they want it.
  Widget _pusherForceControls(BuildContext context, _GateSnapshot snap) {
    return _HoldToPushButton(
      enabled: config.forceOpenKey.isNotEmpty,
      onChanged: (down) => writeForce(config.forceOpenKey, down),
    );
  }

  Widget _forceSelector(BuildContext context, _GateSnapshot snap, bool live) {
    final hasFeedback = config.forceOpenFeedbackKey.isNotEmpty ||
        config.forceCloseFeedbackKey.isNotEmpty;
    // Without feedback keys the live force state is unknown — show no
    // selection instead of claiming None.
    final selection = !hasFeedback || !live
        ? <_ForceSelection>{}
        : {
            snap.forcedOpen
                ? _ForceSelection.open
                : snap.forcedClosed
                    ? _ForceSelection.close
                    : _ForceSelection.none
          };

    // Forced is orange throughout the pane system (PaneStatus.warning, the
    // IO panes' forced markers); the active segment wears the same tint as
    // the header chip.
    const forced = Colors.orange;
    return SegmentedButton<_ForceSelection>(
      emptySelectionAllowed: true,
      showSelectedIcon: false,
      // Fill the section width so the pill sits on the pane grid instead of
      // floating centered under the left-aligned section title.
      expandedInsets: EdgeInsets.zero,
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: forced.withValues(alpha: 0.18),
        selectedForegroundColor: forced,
      ),
      segments: [
        ButtonSegment(
          value: _ForceSelection.open,
          label: const Text('Open'),
          enabled: config.forceOpenKey.isNotEmpty,
        ),
        ButtonSegment(
          value: _ForceSelection.none,
          label: const Text('None'),
          enabled: config.forceOpenKey.isNotEmpty ||
              config.forceCloseKey.isNotEmpty,
        ),
        ButtonSegment(
          value: _ForceSelection.close,
          label: const Text('Close'),
          enabled: config.forceCloseKey.isNotEmpty,
        ),
      ],
      selected: selection,
      // Re-tapping the highlighted segment yields an empty set — treat
      // it as a release, same as picking None.
      onSelectionChanged: (sel) =>
          _apply(sel.isEmpty ? _ForceSelection.none : sel.first),
    );
  }
}

// ---------------------------------------------------------------------------
// Config editor widget with live preview
// ---------------------------------------------------------------------------

class _ConveyorGateConfigEditor extends StatefulWidget {
  final ConveyorGateConfig config;
  const _ConveyorGateConfigEditor({required this.config});

  @override
  State<_ConveyorGateConfigEditor> createState() =>
      _ConveyorGateConfigEditorState();
}

class _ConveyorGateConfigEditorState extends State<_ConveyorGateConfigEditor>
    with SingleTickerProviderStateMixin {
  /// Progress notifier drives the gate painter repaint.
  late final ValueNotifier<double> _previewProgress;

  /// Animation controller for the "play" preview cycle.
  late final AnimationController _animController;

  @override
  void initState() {
    super.initState();
    _previewProgress = ValueNotifier<double>(0.5);
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..addListener(() {
        // Forward 0->1 then reverse 1->0 via a ping-pong curve.
        _previewProgress.value = _animController.value;
      });
  }

  @override
  void dispose() {
    _previewProgress.dispose();
    _animController.dispose();
    super.dispose();
  }

  /// Select the correct painter for the config editor live preview.
  CustomPainter _previewPainter(BuildContext context, ConveyorGateConfig config) {
    final stateColor = config.openColor.resolve(context);
    switch (config.gateVariant) {
      case GateVariant.pneumatic:
        return PneumaticDiverterPainter(
          progress: _previewProgress,
          stateColor: stateColor,
          openAngleDegrees: config.openAngleDegrees,
          side: config.side,
        );
      case GateVariant.slider:
        return SliderGatePainter(
          progress: _previewProgress,
          stateColor: stateColor,
          side: config.side,
          activeOut: config.sliderActiveOut,
          lidAngleDegrees: config.sliderLidAngleDegrees,
          lidLengthFraction: config.sliderLidLength,
          actuationLengthFraction: config.sliderActuationLength,
        );
      case GateVariant.pusher:
        return PusherGatePainter(
          progress: _previewProgress,
          stateColor: stateColor,
          side: config.side,
        );
    }
  }

  void _playPreview() {
    if (_animController.isAnimating) {
      _animController.stop();
      return;
    }
    final openMs = widget.config.openTimeMs;
    final closeMs = widget.config.closeTimeMs ?? openMs;
    _animController.duration = Duration(milliseconds: openMs);
    _animController.reverseDuration = Duration(milliseconds: closeMs);
    _animController.forward().then((_) {
      if (mounted) _animController.reverse();
    });
  }

  @override
  Widget build(BuildContext context) {
    final config = widget.config;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // -- Live preview --
          Center(
            child: Column(
              children: [
                SizedBox(
                  width: 150,
                  height: 150,
                  child: CustomPaint(
                    painter: _previewPainter(context, config),
                  ),
                ),
                IconButton(
                  icon: Icon(
                    _animController.isAnimating ? Icons.stop : Icons.play_arrow,
                  ),
                  tooltip: 'Play open/close animation',
                  onPressed: _playPreview,
                ),
              ],
            ),
          ),
          const Divider(),

          // -- Gate Variant --
          Text('Gate Variant', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          SegmentedButton<GateVariant>(
            segments: const [
              ButtonSegment(
                  value: GateVariant.pneumatic, label: Text('Diverter')),
              ButtonSegment(value: GateVariant.slider, label: Text('Slider')),
              ButtonSegment(value: GateVariant.pusher, label: Text('Pusher')),
            ],
            selected: {config.gateVariant},
            onSelectionChanged: (selection) {
              setState(() => config.gateVariant = selection.first);
            },
          ),
          const SizedBox(height: 16),

          // -- Gate State Key --
          KeyField(
            label: 'Gate State Key',
            initialValue: config.stateKey,
            onChanged: (v) => setState(() => config.stateKey = v),
          ),
          const SizedBox(height: 16),

          // -- Gate Side --
          Text('Gate Side', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          SegmentedButton<GateSide>(
            segments: const [
              ButtonSegment(value: GateSide.left, label: Text('Left')),
              ButtonSegment(value: GateSide.right, label: Text('Right')),
            ],
            selected: {config.side},
            onSelectionChanged: (selection) {
              setState(() => config.side = selection.first);
            },
          ),
          const SizedBox(height: 16),

          // -- Slider Active Direction + Lid Angle --
          if (config.gateVariant == GateVariant.slider) ...[
            SwitchListTile(
              title: const Text('Active Position Out'),
              subtitle: Text(config.sliderActiveOut
                  ? 'Open = lid pushed out'
                  : 'Open = lid pulled in'),
              value: config.sliderActiveOut,
              onChanged: (v) => setState(() => config.sliderActiveOut = v),
              contentPadding: EdgeInsets.zero,
            ),
            const SizedBox(height: 8),
            NumberSlider(
              labelAbove: true,
              label: 'Lid Angle',
              min: -45,
              max: 45,
              divisions: 90,
              suffix: '\u00B0',
              value: config.sliderLidAngleDegrees,
              onChanged: (v) =>
                  setState(() => config.sliderLidAngleDegrees = v),
            ),
            const SizedBox(height: 8),
            NumberSlider(
              labelAbove: true,
              label: 'Lid Length',
              min: 0.1,
              max: 1.0,
              divisions: 18,
              displayScale: 100,
              suffix: '%',
              value: config.sliderLidLength,
              onChanged: (v) => setState(() => config.sliderLidLength = v),
            ),
            const SizedBox(height: 8),
            NumberSlider(
              labelAbove: true,
              label: 'Actuation Length',
              min: 0.1,
              max: 1.0,
              divisions: 18,
              displayScale: 100,
              suffix: '%',
              value: config.sliderActuationLength,
              onChanged: (v) =>
                  setState(() => config.sliderActuationLength = v),
            ),
            const SizedBox(height: 8),
          ],

          // -- Opening Angle (diverter only, Pitfall 4) --
          if (config.gateVariant == GateVariant.pneumatic) ...[
            NumberSlider(
              labelAbove: true,
              label: 'Opening Angle',
              min: 0,
              max: 90,
              divisions: 90,
              suffix: '\u00B0',
              value: config.openAngleDegrees,
              onChanged: (v) => setState(() => config.openAngleDegrees = v),
            ),
            const SizedBox(height: 8),
          ],

          // -- Open Time --
          DurationField(
            value: Duration(milliseconds: config.openTimeMs),
            labelText: 'Open Time',
            min: const Duration(milliseconds: 1),
            max: const Duration(minutes: 10),
            units: const [DurationUnit.milliseconds, DurationUnit.seconds],
            // The config stores whole milliseconds.
            resolution: const Duration(milliseconds: 1),
            onChanged: (v) =>
                setState(() => config.openTimeMs = v.inMilliseconds),
          ),
          const SizedBox(height: 8),

          // -- Close Time --
          DurationField(
            value: config.closeTimeMs == null
                ? null
                : Duration(milliseconds: config.closeTimeMs!),
            labelText: 'Close Time',
            hintText: 'Same as open time',
            min: const Duration(milliseconds: 1),
            max: const Duration(minutes: 10),
            units: const [DurationUnit.milliseconds, DurationUnit.seconds],
            resolution: const Duration(milliseconds: 1),
            onChanged: (v) =>
                setState(() => config.closeTimeMs = v.inMilliseconds),
            // Empty means "mirror the open time" — a real state, not
            // half-typed input.
            onCleared: () => setState(() => config.closeTimeMs = null),
          ),
          const SizedBox(height: 16),

          // -- Open Color --
          AssetColorPickerRow(
            label: 'Open Color',
            color: config.openColor,
            onChanged: (color) => setState(() => config.openColor = color),
          ),
          const SizedBox(height: 12),

          // -- Closed Color --
          AssetColorPickerRow(
            label: 'Closed Color',
            color: config.closedColor,
            onChanged: (color) => setState(() => config.closedColor = color),
          ),
          const SizedBox(height: 16),

          // -- Force Controls --
          Text('Force Controls', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          KeyField(
            label: 'Force Open Key',
            initialValue: config.forceOpenKey,
            onChanged: (v) => setState(() => config.forceOpenKey = v),
          ),
          const SizedBox(height: 8),
          KeyField(
            label: 'Force Open Feedback Key',
            initialValue: config.forceOpenFeedbackKey,
            onChanged: (v) => setState(() => config.forceOpenFeedbackKey = v),
          ),
          const SizedBox(height: 8),
          KeyField(
            label: 'Force Close Key',
            initialValue: config.forceCloseKey,
            onChanged: (v) => setState(() => config.forceCloseKey = v),
          ),
          const SizedBox(height: 8),
          KeyField(
            label: 'Force Close Feedback Key',
            initialValue: config.forceCloseFeedbackKey,
            onChanged: (v) => setState(() => config.forceCloseFeedbackKey = v),
          ),
          const SizedBox(height: 16),

          // -- Size --
          SizeField(
            initialValue: config.size,
            onChanged: (size) => setState(() => config.size = size),
          ),
          const SizedBox(height: 16),

          // -- Coordinates --
          CoordinatesField(
            initialValue: config.coordinates,
            onChanged: (v) => setState(() => config.coordinates = v),
          ),
        ],
      ),
    );
  }
}

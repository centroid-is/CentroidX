/// Festo pneumatics assets — the VTUG-14 valve terminal with its CTEU-EC bus
/// node.
///
/// The decode, the coil model and the pane live in `vtug.dart`, which knows
/// nothing about Riverpod or OPC UA and is tested on its own. This file is
/// the part that subscribes: the page-editor config, the live widget, and
/// the writes.
///
/// The terminal is `ST303.A1` on ST301's Device 2 and two more nodes on
/// Device 5, each a CTEU-EC carrying one `VAEM-L1-S-8-PT [16DO]` valve
/// cluster. What is fitted at each of the eight positions is a property of
/// the manifold, not of the PLC, so it is configured on the page rather than
/// read from a key — a blanking plate publishes nothing to discover it by.
library;

import 'dart:collection' show LinkedHashMap;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:rxdart/rxdart.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../../widgets/tag_access_guard.dart' show writeTag;

import '../../painter/festo/vtug.dart';
import '../../providers/state_man.dart';
import '../../theme.dart' show HmiStateColors;
import '../../widgets/panes/side_pane.dart';
import 'common.dart';
import 'vtug.dart';

part 'festo.g.dart';

/// What is fitted at one valve position, as the page editor records it.
///
/// Two fields rather than two parallel lists on the terminal: a position's
/// kind and its name are edited together, moved together when a manifold is
/// rebuilt, and are meaningless apart.
@JsonSerializable(explicitToJson: true)
class VtugSliceConfig {
  VtugSliceConfig({
    this.kind = VtugValveKind.valve52Mono,
    this.name = '',
  });

  /// Blank, single or double solenoid. Drives how many LEDs the slice wears
  /// and which coils the pane offers.
  VtugValveKind kind;

  /// What the plant calls this valve — `Gate 1 lift`, `Pusher extend`.
  /// Empty leaves the position unnamed rather than inventing a caption.
  String name;

  factory VtugSliceConfig.fromJson(Map<String, dynamic> json) =>
      _$VtugSliceConfigFromJson(json);

  Map<String, dynamic> toJson() => _$VtugSliceConfigToJson(this);
}

/// The manifold as ordered: five 5/2 monostables, then three 5/3 closed
/// centres.
///
/// From the parts list — `573482 VUVG-B14-M52 x5` and
/// `573485 VUVG-B14-P53C x3` — which is eight positions and eleven of the
/// sixteen coils `VAEM-L1-S-8-PT [16DO]` can drive.
///
/// **The order along the manifold is a guess**: the parts list says how many
/// of each, not which position each sits at, so this puts them in the order
/// they were listed. Every position's kind is editable, so a page built
/// against the real terminal fixes it in the editor rather than here.
List<VtugSliceConfig> defaultVtugSlices() => [
      for (var i = 0; i < vtugPositionCount; i++)
        VtugSliceConfig(
          kind: i < 5
              ? VtugValveKind.valve52Mono
              : VtugValveKind.valve53Closed,
        ),
    ];

/// Festo VTUG-14 valve terminal with a CTEU-EC bus node.
///
/// One state key, holding the `ST_VTUG_16` struct documented on
/// [VtugTerminal]. The struct's `p_stat_*` members are read and its
/// `p_cmd_*` members are written; both halves travel in one struct write, so
/// a coil is never taken without being told what to do in the same scan.
///
/// With no key, the asset draws the manifold with every lamp unknown and the
/// pane says there is nothing to command. That is the state a freshly placed
/// asset is in, and it is a useful one — the drawing is what makes the
/// terminal findable on the page while somebody works out what the key is.
@JsonSerializable(explicitToJson: true)
class FestoVTUGConfig extends BaseAsset {
  @override
  String get displayName => 'Festo VTUG-14 (8 valves)';

  @override
  String get category => 'Festo Devices';

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  List<String> get searchKeywords => const [
        'VTUG',
        'CTEU',
        'CTEU-EC',
        'VAEM',
        'valve terminal',
        'valve manifold',
        'solenoid',
        'pneumatic',
      ];

  /// Worn on the right end plate — `ST303.A1`, the tag on the cabinet
  /// drawing. A page carrying three of these wants to say which is which.
  @JsonKey(defaultValue: '')
  String nameOrId;

  /// The `ST_VTUG_16` struct.
  String? stateKey;

  /// The eight positions, position 1 first.
  @JsonKey(defaultValue: null)
  List<VtugSliceConfig> slices;

  FestoVTUGConfig({
    this.nameOrId = '',
    this.stateKey,
    List<VtugSliceConfig>? slices,
  }) : slices = slices ?? defaultVtugSlices();

  FestoVTUGConfig.preview()
      : nameOrId = 'ST303.A1',
        stateKey = null,
        slices = defaultVtugSlices(),
        super();

  factory FestoVTUGConfig.fromJson(Map<String, dynamic> json) {
    final config = _$FestoVTUGConfigFromJson(json);
    // A page saved before a position existed, or by hand, must still
    // deserialise to a whole manifold — every consumer indexes positions
    // 1..8 and a short list would throw on the first paint.
    while (config.slices.length < vtugPositionCount) {
      config.slices.add(VtugSliceConfig(kind: VtugValveKind.blank));
    }
    if (config.slices.length > vtugPositionCount) {
      config.slices = config.slices.sublist(0, vtugPositionCount);
    }
    return config;
  }

  @override
  Map<String, dynamic> toJson() => _$FestoVTUGConfigToJson(this);

  /// The manifold's population, in the order [VtugTerminal] wants it.
  List<VtugValveKind> get kinds => [for (final s in slices) s.kind];

  /// The position names, in the same order.
  List<String> get names => [for (final s in slices) s.name];

  @override
  Widget build(BuildContext context) {
    final targetSize = size.toSize(MediaQuery.of(context).size);
    return SizedBox.fromSize(
      size: targetSize,
      child: FittedBox(
        fit: BoxFit.contain,
        alignment: Alignment.center,
        child: _FestoVTUG(config: this),
      ),
    );
  }

  @override
  Widget configure(BuildContext context) {
    return SizedBox(
      width: 620,
      height: 560,
      child: _FestoVTUGConfigEditor(config: this),
    );
  }
}

// ---------------------------------------------------------------------------
// Live widget
// ---------------------------------------------------------------------------

/// The subscribed terminal.
///
/// Holds the last struct it received, because every command is that struct
/// with two members changed. Reading the struct back before each write would
/// put a server round trip inside a momentary push — the operator would hold
/// the button and the valve would follow a beat later, which on a manual
/// override is the difference between a control and a suggestion.
class _FestoVTUG extends ConsumerStatefulWidget {
  const _FestoVTUG({required this.config});

  final FestoVTUGConfig config;

  @override
  ConsumerState<_FestoVTUG> createState() => _FestoVTUGState();
}

class _FestoVTUGState extends ConsumerState<_FestoVTUG> {
  Stream<Map<String, DynamicValue>>? _stream;
  StateMan? _stateMan;

  /// The last struct received, or null before the first emission. The source
  /// of every write.
  DynamicValue? _latest;

  @override
  void initState() {
    super.initState();
    ref.read(stateManProvider.future).then((sm) {
      if (!mounted) return;
      setState(() {
        _stateMan = sm;
        _stream = _subscribe(sm);
      });
    });
  }

  /// A fresh subscription to the terminal's key.
  ///
  /// Called twice — once for the body and once each time the pane opens —
  /// because `CombineLatestStream` is single-subscription and the two
  /// surfaces have different lifetimes: the body lives as long as the asset
  /// is on the page, the pane's ends when the pane is closed. Handing both
  /// the same stream throws `Stream has already been listened to` the moment
  /// the pane opens, which is how this arrangement was arrived at. The
  /// Advantys modules take the same shape for the same reason.
  Stream<Map<String, DynamicValue>> _subscribe(StateMan stateMan) =>
      _combinedStream(
        LinkedHashMap<String, String?>.from(<String, String?>{
          'state': widget.config.stateKey,
        }),
        stateMan,
      );

  @override
  void dispose() {
    // The pane lives in the root overlay and holds this state's callbacks,
    // so it has to go before the state does — otherwise a page change would
    // leave a pane behind writing to a terminal that is no longer on screen.
    closeSidePane(id: _paneId, immediate: true);
    _stream = null;
    _stateMan = null;
    _latest = null;
    super.dispose();
  }

  String get _paneId => 'festo-vtug:${identityHashCode(widget.config)}';

  VtugTerminal _decode(DynamicValue? struct) => VtugTerminal.read(
        struct,
        kinds: widget.config.kinds,
        descriptions: widget.config.names,
      );

  /// True when the cluster is publishing — which is all this page can honestly
  /// say about the bus node. See [CteuLink].
  CteuLink _link(DynamicValue? struct) =>
      struct == null ? CteuLink.dark : CteuLink.live;

  /// Writes [mask] and [value] into the struct's command members.
  ///
  /// Both in one write: a coil taken by `p_cmd_Force` without `p_cmd_Value`
  /// arriving in the same scan is a coil the PLC has let go of and nobody
  /// has picked up.
  Future<void> _command(int mask, int value) async {
    final key = widget.config.stateKey;
    final stateMan = _stateMan;
    final latest = _latest;
    if (key == null || stateMan == null || latest == null) return;

    final next = DynamicValue.from(latest);
    next['p_cmd_Force'] = mask;
    next['p_cmd_Value'] = value;
    // Captured before the await: a write that fails after the page has
    // changed has no messenger to complain to, and reaching for one through
    // a disposed context is how that turns into a crash.
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      // Resolved at the tap like every other command write: a refusal
      // prompts, writes nothing, and throws nothing on the operator's path.
      // No member — both command words move in one struct write, and the
      // guard's own diff asks per member from the baseline.
      await writeTag(ref, stateMan, key, next);
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Valve terminal write failed: $e')),
      );
    }
  }

  /// The command words currently in effect, as the terminal last reported
  /// them. Zero before anything has arrived, which is also the right answer:
  /// nothing can be held on a terminal that has not spoken.
  ({int mask, int value}) get _commandWords {
    final latest = _latest;
    int member(String name) {
      if (latest == null || !latest.contains(name)) return 0;
      return latest[name].asInt;
    }

    return (mask: member('p_cmd_Force'), value: member('p_cmd_Value'));
  }

  void _force(VtugValve valve, VtugForce force) {
    final words = _commandWords;
    final next = vtugApplyForce(
      forceMask: words.mask,
      forceValue: words.value,
      kind: valve.kind,
      position: valve.position,
      force: force,
    );
    _command(next.mask, next.value);
  }

  void _push(VtugValve valve, VtugCoil coil, bool pressed) {
    final words = _commandWords;
    final next = vtugApplyPush(
      forceMask: words.mask,
      forceValue: words.value,
      position: valve.position,
      coil: coil,
      pressed: pressed,
    );
    _command(next.mask, next.value);
  }

  void _releaseAll() {
    final next = vtugReleaseAll();
    _command(next.mask, next.value);
  }

  @override
  Widget build(BuildContext context) {
    final stream = _stream;
    if (stream == null) {
      return _shell(_decode(null), CteuLink.dark);
    }
    return StreamBuilder<Map<String, DynamicValue>>(
      stream: stream,
      builder: (context, snap) {
        final data = (snap.hasData && !snap.hasError) ? snap.data : null;
        _latest = data?['state'];
        return _shell(_decode(_latest), _link(_latest));
      },
    );
  }

  Widget _shell(VtugTerminal terminal, CteuLink link) {
    final colors = HmiStateColors.of(context);
    return GestureDetector(
      // Opaque so a tap on the gaps between fittings still opens the pane —
      // most of this drawing is gaps.
      behavior: HitTestBehavior.opaque,
      onTap: _openPane,
      child: VtugWidget(
        slices: [
          for (final valve in terminal.valves)
            VtugSliceView(
              coils: [
                for (final coil in VtugCoil.values)
                  if (valve.hasCoil(coil)) valve.coilState(coil),
              ],
              held: valve.force != VtugForce.auto,
            ),
        ],
        leds: link.leds,
        litColor: colors.yellow,
        name: widget.config.nameOrId,
        disconnected: link == CteuLink.dark,
      ),
    );
  }

  void _openPane() {
    final stateMan = _stateMan;
    final canCommand = widget.config.stateKey != null && stateMan != null;
    showVtugPane(
      context: context,
      id: _paneId,
      title: widget.config.nameOrId.isEmpty
          ? 'VTUG-14'
          : widget.config.nameOrId,
      subtitle: 'Festo · valve terminal',
      initial: _decode(_latest),
      // The pane's own subscription, released when the pane closes. It only
      // feeds the pane's display — `_latest`, which every command is built
      // from, is kept current by the body, which is on screen for as long as
      // the asset is.
      stream: stateMan == null
          ? const Stream<VtugTerminal>.empty()
          : _subscribe(stateMan).map((data) => _decode(data['state'])),
      onForce: canCommand ? _force : null,
      onPush: canCommand ? _push : null,
      onReleaseAll: canCommand ? _releaseAll : null,
    );
  }
}

/// Subscribes the configured keys and pairs each emission by name.
///
/// The same shape as the one in `beckhoff.dart`, taking a resolved
/// [StateMan] rather than a `WidgetRef`: the pane outlives the build that
/// opened it and has no `ref.watch` to hold the shared stream alive.
CombineLatestStream<DynamicValue, Map<String, DynamicValue>> _combinedStream(
  LinkedHashMap<String, String?> keys,
  StateMan stateMan,
) {
  return CombineLatestStream([
    for (final entry in keys.entries)
      if (entry.value != null)
        stateMan.subscribe(entry.value!).asStream().asyncExpand((s) => s),
  ], (values) {
    final map = <String, DynamicValue>{};
    var i = 0;
    for (final entry in keys.entries) {
      if (entry.value != null) map[entry.key] = values[i++];
    }
    return map;
  });
}

// ---------------------------------------------------------------------------
// Configure form
// ---------------------------------------------------------------------------

class _FestoVTUGConfigEditor extends StatefulWidget {
  const _FestoVTUGConfigEditor({required this.config});

  final FestoVTUGConfig config;

  @override
  State<_FestoVTUGConfigEditor> createState() => _FestoVTUGConfigEditorState();
}

class _FestoVTUGConfigEditorState extends State<_FestoVTUGConfigEditor> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizeField(
            initialValue: widget.config.size,
            onChanged: (size) => widget.config.size = size,
          ),
          const SizedBox(height: 16),
          CoordinatesField(
            initialValue: widget.config.coordinates,
            onChanged: (coordinates) =>
                widget.config.coordinates = coordinates,
            enableAngle: false,
          ),
          const SizedBox(height: 16),
          TextFormField(
            decoration: const InputDecoration(
              labelText: 'Name or ID',
              helperText: 'Printed on the end plate — e.g. ST303.A1',
            ),
            initialValue: widget.config.nameOrId,
            onChanged: (value) => widget.config.nameOrId = value,
          ),
          const SizedBox(height: 16),
          KeyField(
            label: 'State key (ST_VTUG_16)',
            initialValue: widget.config.stateKey,
            onChanged: (value) => widget.config.stateKey = value,
          ),
          const SizedBox(height: 20),
          Text(
            'VALVE POSITIONS',
            style: theme.textTheme.labelSmall?.copyWith(
              letterSpacing: 1.1,
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'What is fitted at each of the eight positions. A blank is a '
            'blanking plate — no coil, no LED and nothing to command. A '
            'single solenoid drives coil 14 only and springs back; a double '
            'drives 14 and 12 and stays where it was put.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          for (var i = 0; i < widget.config.slices.length; i++)
            _sliceRow(context, i),
        ],
      ),
    );
  }

  Widget _sliceRow(BuildContext context, int index) {
    final slice = widget.config.slices[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 34,
            child: Text(vtugPositionLabel(index + 1)),
          ),
          SizedBox(
            width: 160,
            child: DropdownButtonFormField<VtugValveKind>(
              key: ValueKey('vtug-kind-${index + 1}'),
              initialValue: slice.kind,
              decoration: const InputDecoration(isDense: true),
              items: [
                for (final kind in VtugValveKind.values)
                  DropdownMenuItem(
                    value: kind,
                    child: Text(kind.label),
                  ),
              ],
              onChanged: (kind) {
                if (kind == null) return;
                setState(() => slice.kind = kind);
              },
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextFormField(
              key: ValueKey('vtug-name-${index + 1}'),
              enabled: slice.kind != VtugValveKind.blank,
              decoration: InputDecoration(
                isDense: true,
                labelText: 'What it does',
                hintText: slice.kind.blurb,
              ),
              initialValue: slice.name,
              onChanged: (value) => slice.name = value,
            ),
          ),
        ],
      ),
    );
  }
}

// Advantys STB module asset configs + their live ConsumerStatefulWidgets.
//
// Phase 1 (this file): `STBDDI3725Config` — 16-channel digital-input module.
// Phase 2: `STBDDO3705Config` — 16-channel digital-output module.
// Phase 3: `STBNIP2311Config` — Modbus network interface module.
// Phase 4: `STBPDT3100Config` — 24V DC power distribution module.
// Phase 5: composite parent moved ONTO `STBNIP2311Config` (retrofit
//          2026-05-12 — head IS the composite; mirrors CX5010/EK1100).
//
// Conventions locked by Plan 01:
// - Bit-to-channel mapping comes from `kSTBChannelBitOrder` in
//   `package:tfc/painter/advantys_stb/io16.dart` (LSB-first locked default).
// - LED rendering goes through `bitmaskToLedStates(raw, forceValues: ...)`
//   from the same file — painters and widgets never re-derive bit math.
// - Schneider cream `bodyColor` is imported from
//   `package:tfc/painter/advantys_stb/io16.dart` (re-exported from Beckhoff
//   in Plan 01 to keep the brownfield import boundary clean).
//
// Plan 02 ships:
// - `STBDDI3725Config` data class + JSON round-trip.
// - `_STBDDI3725` ConsumerStatefulWidget with the `_combinedStream` hoisted to
//   `initState` (QUAL-03 / PITFALL M-03).
// - `STBDDI3725BodyPainter` + `STBDDI3725Widget` in
//   `lib/painter/advantys_stb/ddi3725.dart`.
// - 5 KeyField editor body (Task 3).
// - 10 golden PNGs under `test/page_creator/assets/goldens/advantys_stb/` (Task 5).
//
// Plan 03 will replace the onTap stub with the real per-channel detail dialog.
// Plan 04 will register the asset in `registry.dart` + add the leak test.

import 'dart:collection' show LinkedHashMap;

import 'package:json_annotation/json_annotation.dart';
import 'package:flutter/material.dart';
import 'package:tfc/widgets/panes/standard_dialog.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';
import 'package:rxdart/rxdart.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:tfc_dart/core/state_man_types.dart';

import 'common.dart';
import '../page.dart' show AssetListConverter;
import 'beckhoff.dart' show RowIOView, FilterEdit;
import '../../providers/state_man.dart';
import '../../painter/advantys_stb/io16.dart';
import '../../painter/advantys_stb/ddi3725.dart';
import '../../painter/advantys_stb/ddo3705.dart';
import '../../painter/advantys_stb/nip2311.dart';
import '../../painter/advantys_stb/pdt3100.dart';
import '../../painter/beckhoff/io8.dart' show IOState;
import '../../widgets/panes/side_pane.dart';
import '../../widgets/tag_access_guard.dart' show writeTag;
import 'io_pane.dart';

part 'advantys_stb.g.dart';

// ---------------------------------------------------------------------------
// STBDDI3725Config — Schneider Advantys STB 16-channel digital-input module.
// ---------------------------------------------------------------------------

/// Schneider Advantys STB DDI3725 — 16-channel digital input module.
///
/// Five optional state keys (raw bitmask + force values + on/off filter ms +
/// descriptions) drive the live LED block and the detail dialog. All keys are
/// nullable; `BaseAsset.allKeys` picks them up automatically via the `Key$`
/// regex (no override needed) and filters out empty strings.
@JsonSerializable(explicitToJson: true)
class STBDDI3725Config extends BaseAsset {
  @override
  String get displayName => 'STBDDI3725 (16-Ch DI)';
  @override
  String get category => 'Advantys STB';

  @JsonKey(defaultValue: '1')
  String nameOrId;

  String? rawStateKey;
  String? forceValuesKey;
  String? onFiltersKey;
  String? offFiltersKey;
  String? descriptionsKey;

  STBDDI3725Config({
    this.nameOrId = '1',
    this.rawStateKey,
    this.forceValuesKey,
    this.onFiltersKey,
    this.offFiltersKey,
    this.descriptionsKey,
  });

  STBDDI3725Config.preview()
      : nameOrId = '1',
        rawStateKey = null,
        forceValuesKey = null,
        onFiltersKey = null,
        offFiltersKey = null,
        descriptionsKey = null,
        super();

  factory STBDDI3725Config.fromJson(Map<String, dynamic> json) =>
      _$STBDDI3725ConfigFromJson(json);

  @override
  Map<String, dynamic> toJson() => _$STBDDI3725ConfigToJson(this);

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.contain,
      child: _STBDDI3725(config: this),
    );
  }

  @override
  Widget configure(BuildContext context) {
    final media = MediaQuery.of(context).size;
    final maxWidth = media.width * 0.9;
    final maxHeight = media.height * 0.8;

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth,
          maxHeight: maxHeight,
          minWidth: 320,
          minHeight: 200,
        ),
        child: Material(
          borderRadius: BorderRadius.circular(24),
          color: DialogTheme.of(context).backgroundColor ??
              Theme.of(context).colorScheme.surface,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: SingleChildScrollView(
              child: _STBDDI3725ConfigEditor(config: this),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Live widget — _STBDDI3725
//
// ConsumerStatefulWidget so `_combinedStream` can be hoisted to `initState`
// per PITFALL M-03 / QUAL-03. The stream is built ONCE per widget instance
// after the StateMan future resolves; subsequent parent rebuilds re-use the
// cached stream and do not trigger fresh OPC UA subscriptions.
// ---------------------------------------------------------------------------

class _STBDDI3725 extends ConsumerStatefulWidget {
  final STBDDI3725Config config;
  const _STBDDI3725({required this.config});

  @override
  ConsumerState<_STBDDI3725> createState() => _STBDDI3725State();
}

class _STBDDI3725State extends ConsumerState<_STBDDI3725> {
  Stream<Map<String, DynamicValue>>? _combinedStreamCache;
  StateMan? _stateMan;

  @override
  void initState() {
    super.initState();
    // Resolve StateMan once. After it lands, construct the combined stream
    // ONCE and stash it in `_combinedStreamCache`. The build() method reads
    // the cache; it never reconstructs the stream. This is the QUAL-03 /
    // PITFALL M-03 contract.
    ref.read(stateManProvider.future).then((sm) {
      if (!mounted) return;
      setState(() {
        _stateMan = sm;
        _combinedStreamCache = _combinedStream(
          LinkedHashMap<String, String?>.from(<String, String?>{
            'raw': widget.config.rawStateKey,
            'force': widget.config.forceValuesKey,
          }),
          sm,
        );
      });
    });
  }

  @override
  void dispose() {
    // DDI-10 / QUAL-03 lifecycle hygiene. The body stream uses
    // `StreamBuilder` exclusively, so the `StreamSubscription` is
    // owned + cancelled by the framework on unmount. We still null out
    // `_combinedStreamCache` defensively to release the closure-captured
    // reference to `StateMan` (prevents the cached cold stream from
    // keeping `StateMan` reachable through GC roots if the page is
    // long-lived but the widget cycles in/out). The `_stateMan` field
    // is similarly cleared to drop the strong ref.
    //
    // The docked pane holds `_stateMan` too and lives in the root overlay, so
    // it must go first — otherwise a page change would leave a pane behind
    // writing to a module that is no longer on screen.
    closeSidePane(id: _paneId, immediate: true);
    _combinedStreamCache = null;
    _stateMan = null;
    super.dispose();
  }

  /// Identity of this module's docked pane — tapping it again toggles it.
  String get _paneId => 'stb-ddi3725:${identityHashCode(widget.config)}';

  @override
  Widget build(BuildContext context) {
    if (_combinedStreamCache == null) {
      return _buildShell(
        ledStates: List<IOState>.filled(16, IOState.low),
        isStale: true,
      );
    }
    return StreamBuilder<Map<String, DynamicValue>>(
      stream: _combinedStreamCache,
      builder: (context, snap) {
        final data = (snap.hasData && !snap.hasError) ? snap.data : null;
        if (data == null) {
          return _buildShell(
            ledStates: List<IOState>.filled(16, IOState.low),
            isStale: true,
          );
        }
        final rawDv = data['raw'];
        final raw = rawDv?.asInt ?? 0;
        final forceList = _forceArrayFromDynamicValue(data['force']);
        final leds = bitmaskToLedStates(raw, forceValues: forceList);
        return _buildShell(ledStates: leds, isStale: false);
      },
    );
  }

  Widget _buildShell({
    required List<IOState> ledStates,
    required bool isStale,
  }) {
    return GestureDetector(
      // QUAL-05: opaque hit-test so taps register on transparent gaps in the
      // body (the body painter has empty regions between LEDs and terminal
      // blocks). Without this, taps on those gaps would fall through.
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (_stateMan == null) return;
        _showDDI3725DetailPane(
          context,
          widget.config,
          _stateMan!,
          const AlwaysStoppedAnimation<int>(0),
          _paneId,
        );
      },
      child: STBDDI3725Widget(
        ledStates: ledStates,
        isStale: isStale,
        isDisconnected: false,
        animation: const AlwaysStoppedAnimation<int>(0),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Configure dialog body — _STBDDI3725ConfigEditor
// ---------------------------------------------------------------------------

class _STBDDI3725ConfigEditor extends StatefulWidget {
  final STBDDI3725Config config;
  const _STBDDI3725ConfigEditor({required this.config});

  @override
  State<_STBDDI3725ConfigEditor> createState() =>
      _STBDDI3725ConfigEditorState();
}

class _STBDDI3725ConfigEditorState extends State<_STBDDI3725ConfigEditor> {
  @override
  Widget build(BuildContext context) {
    return Column(
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
          onChanged: (coordinates) => widget.config.coordinates = coordinates,
          enableAngle: false,
        ),
        const SizedBox(height: 16),
        TextFormField(
          decoration: const InputDecoration(
            labelText: 'Name or ID',
            border: OutlineInputBorder(),
          ),
          initialValue: widget.config.nameOrId,
          onChanged: (value) => widget.config.nameOrId = value,
        ),
        const SizedBox(height: 16),
        KeyField(
          initialValue: widget.config.rawStateKey,
          onChanged: (value) => widget.config.rawStateKey = value,
          label: 'Raw State Key',
        ),
        const SizedBox(height: 16),
        KeyField(
          initialValue: widget.config.forceValuesKey,
          onChanged: (value) => widget.config.forceValuesKey = value,
          label: 'Force Values Key',
        ),
        const SizedBox(height: 16),
        KeyField(
          initialValue: widget.config.onFiltersKey,
          onChanged: (value) => widget.config.onFiltersKey = value,
          label: 'On Filters Key',
        ),
        const SizedBox(height: 16),
        KeyField(
          initialValue: widget.config.offFiltersKey,
          onChanged: (value) => widget.config.offFiltersKey = value,
          label: 'Off Filters Key',
        ),
        const SizedBox(height: 16),
        KeyField(
          initialValue: widget.config.descriptionsKey,
          onChanged: (value) => widget.config.descriptionsKey = value,
          label: 'Descriptions Key',
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

/// Combine N nullable state-keys into a single stream emitting a map of
/// `{logical-name → DynamicValue}`. Mirrors the Beckhoff `_combinedStream` at
/// `lib/page_creator/assets/beckhoff.dart` (ARCHITECTURE §9.3 advises to
/// duplicate rather than refactor — Beckhoff conventions remain isolated).
CombineLatestStream<DynamicValue, Map<String, DynamicValue>> _combinedStream(
  LinkedHashMap<String, String?> keys,
  StateMan stateMan,
) {
  return CombineLatestStream<DynamicValue, Map<String, DynamicValue>>(
    [
      for (final entry in keys.entries)
        if (entry.value != null)
          stateMan.subscribe(entry.value!).asStream().asyncExpand((s) => s),
    ],
    (values) {
      final map = <String, DynamicValue>{};
      int i = 0;
      for (final entry in keys.entries) {
        if (entry.value != null) {
          map[entry.key] = values[i++];
        }
      }
      return map;
    },
  );
}

/// Extracts a per-channel `int8[16]` force-values array from a [DynamicValue].
///
/// CONTEXT.md D-ForceValues locks the wire format to `int8[16]`. The expected
/// runtime shape is `dv.isArray == true` with `dv.asArray` being a
/// `List<DynamicValue>` of length 16, each entry's `.asInt` in `{0, 1, 2}`.
///
/// Returns `null` if `dv == null` or `dv.isArray == false`. Returns a list of
/// up to 16 ints otherwise; `bitmaskToLedStates` tolerates a short list
/// (treated as auto on remaining channels) per its Plan 01 contract.
///
/// PITFALL M-04 / M-02 trip-wire: if `dv` arrives as a packed int instead of
/// an array (Beckhoff convention — `forceValuesKey` is a single integer where
/// `.asInt` encodes all eight channels), this returns null and the LED block
/// silently renders raw bits only. The commissioning-time fix is to align the
/// backend wire format with CONTEXT.md D-ForceValues (int8[16] array per
/// channel), not to patch the painter. Carried forward in SUMMARY.md.
List<int>? _forceArrayFromDynamicValue(DynamicValue? dv) {
  if (dv == null) return null;
  if (!dv.isArray) return null;
  final list = dv.asArray;
  final out = <int>[];
  for (int i = 0; i < list.length && i < 16; i++) {
    out.add(list[i].asInt);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Detail pane — _showDDI3725DetailPane
//
// Since Plan 260811 tapping the module opens a non-modal `SidePane` instead of
// an `AlertDialog`. The 8 rows × 2 columns of `RowIOView` did not fit a pane
// and never really fitted a dialog either — per-channel force buttons, two
// filter fields and a description field are simply wide. So the surface is
// split the way the pane standard prescribes:
//
//   * the PANE carries identity, link status, a 16-channel state strip and
//     the forced-channel count — a glance, no scrolling;
//   * the GRID moves behind a `PaneExpandTile` into a free-floating
//     `StandardDialog` the operator can drag onto the plant view and resize.
//
// Stream lifetimes are unchanged in kind: the pane subscribes to raw + force
// only (like the body), while the grid subscribes to all FIVE keys (raw,
// force, on_filters, off_filters, descriptions) and owns that subscription
// through its own `StreamBuilder` — closing the dialog disposes the builder
// and releases the StateMan listeners, exactly as popping the dialog did.
// ---------------------------------------------------------------------------

void _showDDI3725DetailPane(
  BuildContext context,
  STBDDI3725Config config,
  StateMan stateMan,
  Animation<int> animation,
  String paneId,
) {
  showIoModulePane(
    context: context,
    id: paneId,
    title: config.nameOrId,
    subtitle: 'Advantys STB · 16 DI',
    summaryStream: _combinedStream(
      LinkedHashMap<String, String?>.from(<String, String?>{
        'raw': config.rawStateKey,
        'force': config.forceValuesKey,
      }),
      stateMan,
    ),
    statesOf: (data) => bitmaskToLedStates(
      data?['raw']?.asInt ?? 0,
      forceValues: _forceArrayFromDynamicValue(data?['force']),
    ),
    gridSummary: 'Force, filters and descriptions for all 16',
    gridBuilder: (context) => _DDI3725ChannelGrid(
      config: config,
      stateMan: stateMan,
      animation: animation,
    ),
  );
}

/// The full per-channel grid: 8 rows × 2 columns of `RowIOView`, each row
/// pairing channels `(r+1, r+9)` (UI-SPEC §Detail Dialog). Per-channel
/// surface: state indicator + force `SegmentedButton` + ON/OFF filter
/// `TextFormField`s + description `TextFormField`.
///
/// Lifted verbatim out of the old `AlertDialog` so the force/filter write
/// paths are byte-for-byte the ones the Plan 03/04 tests lock; only its host
/// changed, from a modal dialog to a floating one.
/// A `ConsumerWidget` rather than a `StatelessWidget`, and only because the
/// force and filter writes go through [writeTag] — which needs a `WidgetRef`
/// to resolve the permission before it issues anything. The grid is built
/// into the pane's own subtree, so this is its ref and not the module's.
class _DDI3725ChannelGrid extends ConsumerWidget {
  final STBDDI3725Config config;
  final StateMan stateMan;
  final Animation<int> animation;

  const _DDI3725ChannelGrid({
    required this.config,
    required this.stateMan,
    required this.animation,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      IoGridViewport(child: _buildGrid(context, ref));

  Widget _buildGrid(BuildContext context, WidgetRef ref) {
    return StreamBuilder<Map<String, DynamicValue>>(
      stream: _combinedStream(
        LinkedHashMap<String, String?>.from(<String, String?>{
          'raw': config.rawStateKey,
          'force': config.forceValuesKey,
          'on_filters': config.onFiltersKey,
          'off_filters': config.offFiltersKey,
          'descriptions': config.descriptionsKey,
        }),
        stateMan,
      ),
      builder: (context, snap) {
        if (!snap.hasData || snap.hasError) {
          return const SizedBox.shrink();
        }
        final map = snap.data!;
        final rawDv = map['raw'];
        final List<bool>? rawStates = rawDv != null
            ? List<bool>.generate(16, (i) => (rawDv.asInt & (1 << i)) != 0)
            : null;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (int r = 0; r < 8; r++)
              Padding(
                padding: EdgeInsets.only(bottom: r < 7 ? 2.0 : 0.0),
                child: RowIOView(
                  leftRaw: rawStates?[r] ?? false,
                  rightRaw: rawStates?[r + 8] ?? false,
                  leftProcessed: null,
                  rightProcessed: null,
                  leftSelected: map['force']?[r].asInt ?? 0,
                  rightSelected: map['force']?[r + 8].asInt ?? 0,
                  animationValue: animation,
                  // No member on any of these six: `force`, `on_filters` and
                  // `off_filters` are `int8[16]` arrays, not structs. The
                  // channel is an index, and an index is not a member name a
                  // template could ever have a rule for — so the question is
                  // asked about the key as a whole, which is the honest one.
                  leftOnChanged: (value) async {
                    map['force']![r].value = value;
                    await writeTag(
                        ref, stateMan, config.forceValuesKey!, map['force']!);
                  },
                  rightOnChanged: (value) async {
                    map['force']![r + 8].value = value;
                    await writeTag(
                        ref, stateMan, config.forceValuesKey!, map['force']!);
                  },
                  leftDescription: map['descriptions']?[r].asString,
                  rightDescription: map['descriptions']?[r + 8].asString,
                  leftFilterEdit: (map.containsKey('on_filters') &&
                          map.containsKey('off_filters'))
                      ? FilterEdit(
                          onFilter: map['on_filters']?[r].asInt ?? 0,
                          offFilter: map['off_filters']?[r].asInt ?? 0,
                          onChangedOnFilter: (v) async {
                            map['on_filters']![r].value = v;
                            await writeTag(ref, stateMan, config.onFiltersKey!,
                                map['on_filters']!);
                          },
                          onChangedOffFilter: (v) async {
                            map['off_filters']![r].value = v;
                            await writeTag(ref, stateMan, config.offFiltersKey!,
                                map['off_filters']!);
                          },
                        )
                      : null,
                  rightFilterEdit: (map.containsKey('on_filters') &&
                          map.containsKey('off_filters'))
                      ? FilterEdit(
                          onFilter: map['on_filters']?[r + 8].asInt ?? 0,
                          offFilter: map['off_filters']?[r + 8].asInt ?? 0,
                          onChangedOnFilter: (v) async {
                            map['on_filters']![r + 8].value = v;
                            await writeTag(ref, stateMan, config.onFiltersKey!,
                                map['on_filters']!);
                          },
                          onChangedOffFilter: (v) async {
                            map['off_filters']![r + 8].value = v;
                            await writeTag(ref, stateMan, config.offFiltersKey!,
                                map['off_filters']!);
                          },
                        )
                      : null,
                ),
              ),
          ],
        );
      },
    );
  }
}

// ===========================================================================
// STBDDO3705Config — Schneider Advantys STB 16-channel digital-output module.
// ===========================================================================
//
// Phase 2 deliverable. Clone of `STBDDI3725Config` MINUS the on/off filter
// keys (outputs are commanded, not sampled — no per-channel debounce), PLUS
// the genuine end-to-end manual force-write path: tapping `Low`/`High` on
// the SegmentedButton in the detail dialog writes `int8[16]` to
// `forceValuesKey` via `StateMan.write` and the painter reflects on the next
// emission.
//
// Visual differentiation from DDI3725 is shipped by
// `STBDDO3705BodyPainter` in `lib/painter/advantys_stb/ddo3705.dart` — same
// physical chrome but the top label strip carries "DDO3705" plus a small
// "▸" arrow glyph that operators recognize as the output module without
// reading the printed module name.
//
// Bit-ordering is locked at module-wide scope by `kSTBChannelBitOrder` in
// `io16.dart` — DDO3705 imports the constant (does NOT re-declare) so the
// convention cannot drift between input and output modules. The bit-order
// parity canary test in `advantys_stb_test.dart` is the compile-time guard.

/// Schneider Advantys STB DDO3705 — 16-channel digital output module.
///
/// Three optional state keys (raw bitmask + force values + descriptions)
/// drive the live LED block and the detail dialog. All keys are nullable;
/// `BaseAsset.allKeys` picks them up automatically via the `Key$` regex (no
/// override needed) and filters out empty strings.
///
/// NO filter keys — outputs don't have on/off debounce; the detail dialog
/// renders only force SegmentedButton + description per channel.
@JsonSerializable(explicitToJson: true)
class STBDDO3705Config extends BaseAsset {
  @override
  String get displayName => 'STBDDO3705 (16-Ch DO)';
  @override
  String get category => 'Advantys STB';

  @JsonKey(defaultValue: '1')
  String nameOrId;

  String? rawStateKey;
  String? forceValuesKey;
  String? descriptionsKey;

  STBDDO3705Config({
    this.nameOrId = '1',
    this.rawStateKey,
    this.forceValuesKey,
    this.descriptionsKey,
  });

  STBDDO3705Config.preview()
      : nameOrId = '1',
        rawStateKey = null,
        forceValuesKey = null,
        descriptionsKey = null,
        super();

  factory STBDDO3705Config.fromJson(Map<String, dynamic> json) =>
      _$STBDDO3705ConfigFromJson(json);

  @override
  Map<String, dynamic> toJson() => _$STBDDO3705ConfigToJson(this);

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.contain,
      child: _STBDDO3705(config: this),
    );
  }

  @override
  Widget configure(BuildContext context) {
    final media = MediaQuery.of(context).size;
    final maxWidth = media.width * 0.9;
    final maxHeight = media.height * 0.8;

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth,
          maxHeight: maxHeight,
          minWidth: 320,
          minHeight: 200,
        ),
        child: Material(
          borderRadius: BorderRadius.circular(24),
          color: DialogTheme.of(context).backgroundColor ??
              Theme.of(context).colorScheme.surface,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: SingleChildScrollView(
              child: _STBDDO3705ConfigEditor(config: this),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Live widget — _STBDDO3705
//
// Mirrors `_STBDDI3725` but subscribes only to two keys (raw + force).
// `_combinedStream` is hoisted to `initState` per PITFALL M-03 / QUAL-03.
// ---------------------------------------------------------------------------

class _STBDDO3705 extends ConsumerStatefulWidget {
  final STBDDO3705Config config;
  const _STBDDO3705({required this.config});

  @override
  ConsumerState<_STBDDO3705> createState() => _STBDDO3705State();
}

class _STBDDO3705State extends ConsumerState<_STBDDO3705> {
  Stream<Map<String, DynamicValue>>? _combinedStreamCache;
  StateMan? _stateMan;

  @override
  void initState() {
    super.initState();
    ref.read(stateManProvider.future).then((sm) {
      if (!mounted) return;
      setState(() {
        _stateMan = sm;
        _combinedStreamCache = _combinedStream(
          LinkedHashMap<String, String?>.from(<String, String?>{
            'raw': widget.config.rawStateKey,
            'force': widget.config.forceValuesKey,
          }),
          sm,
        );
      });
    });
  }

  @override
  void dispose() {
    // DDO-07 / QUAL-03 lifecycle hygiene. Matches _STBDDI3725State — the
    // docked pane goes first, it holds `_stateMan` and outlives the route.
    closeSidePane(id: _paneId, immediate: true);
    _combinedStreamCache = null;
    _stateMan = null;
    super.dispose();
  }

  /// Identity of this module's docked pane — tapping it again toggles it.
  String get _paneId => 'stb-ddo3705:${identityHashCode(widget.config)}';

  @override
  Widget build(BuildContext context) {
    if (_combinedStreamCache == null) {
      return _buildShell(
        ledStates: List<IOState>.filled(16, IOState.low),
        isStale: true,
      );
    }
    return StreamBuilder<Map<String, DynamicValue>>(
      stream: _combinedStreamCache,
      builder: (context, snap) {
        final data = (snap.hasData && !snap.hasError) ? snap.data : null;
        if (data == null) {
          return _buildShell(
            ledStates: List<IOState>.filled(16, IOState.low),
            isStale: true,
          );
        }
        final rawDv = data['raw'];
        final raw = rawDv?.asInt ?? 0;
        final forceList = _forceArrayFromDynamicValue(data['force']);
        final leds = bitmaskToLedStates(raw, forceValues: forceList);
        return _buildShell(ledStates: leds, isStale: false);
      },
    );
  }

  Widget _buildShell({
    required List<IOState> ledStates,
    required bool isStale,
  }) {
    return GestureDetector(
      // QUAL-05: opaque hit-test — see _STBDDI3725State._buildShell.
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (_stateMan == null) return;
        _showDDO3705DetailPane(
          context,
          widget.config,
          _stateMan!,
          const AlwaysStoppedAnimation<int>(0),
          _paneId,
        );
      },
      child: STBDDO3705Widget(
        ledStates: ledStates,
        isStale: isStale,
        isDisconnected: false,
        animation: const AlwaysStoppedAnimation<int>(0),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Configure dialog body — _STBDDO3705ConfigEditor
//
// 3 KeyField widgets (raw / force / descriptions). NO filter fields.
// ---------------------------------------------------------------------------

class _STBDDO3705ConfigEditor extends StatefulWidget {
  final STBDDO3705Config config;
  const _STBDDO3705ConfigEditor({required this.config});

  @override
  State<_STBDDO3705ConfigEditor> createState() =>
      _STBDDO3705ConfigEditorState();
}

class _STBDDO3705ConfigEditorState extends State<_STBDDO3705ConfigEditor> {
  @override
  Widget build(BuildContext context) {
    return Column(
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
          onChanged: (coordinates) => widget.config.coordinates = coordinates,
          enableAngle: false,
        ),
        const SizedBox(height: 16),
        TextFormField(
          decoration: const InputDecoration(
            labelText: 'Name or ID',
            border: OutlineInputBorder(),
          ),
          initialValue: widget.config.nameOrId,
          onChanged: (value) => widget.config.nameOrId = value,
        ),
        const SizedBox(height: 16),
        KeyField(
          initialValue: widget.config.rawStateKey,
          onChanged: (value) => widget.config.rawStateKey = value,
          label: 'Raw State Key',
        ),
        const SizedBox(height: 16),
        KeyField(
          initialValue: widget.config.forceValuesKey,
          onChanged: (value) => widget.config.forceValuesKey = value,
          label: 'Force Values Key',
        ),
        const SizedBox(height: 16),
        KeyField(
          initialValue: widget.config.descriptionsKey,
          onChanged: (value) => widget.config.descriptionsKey = value,
          label: 'Descriptions Key',
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Detail dialog — _showDDO3705DetailDialog
//
// 8 rows × 2 columns of `RowIOView`. Same channel pairing as DDI3725
// (`(r+1, r+9)`), but with `leftFilterEdit` / `rightFilterEdit` HARDCODED to
// `null` (outputs have no filter inputs — DDO-06).
//
// Force-write path is genuine and operator-driven: SegmentedButton onChange
// mutates the force DynamicValue in-place and writes the whole int8[16] back
// via `writeTag(ref, stateMan, forceValuesKey, ...)`, which resolves the
// permission at the tap and issues nothing when it is refused (plan 04-11).
// The same StreamBuilder receives the next emission and re-renders.
// ---------------------------------------------------------------------------

void _showDDO3705DetailPane(
  BuildContext context,
  STBDDO3705Config config,
  StateMan stateMan,
  Animation<int> animation,
  String paneId,
) {
  showIoModulePane(
    context: context,
    id: paneId,
    title: config.nameOrId,
    subtitle: 'Advantys STB · 16 DO',
    // Outputs, so the count reads "on", not "high".
    highLabel: 'On',
    summaryStream: _combinedStream(
      LinkedHashMap<String, String?>.from(<String, String?>{
        'raw': config.rawStateKey,
        'force': config.forceValuesKey,
      }),
      stateMan,
    ),
    statesOf: (data) => bitmaskToLedStates(
      data?['raw']?.asInt ?? 0,
      forceValues: _forceArrayFromDynamicValue(data?['force']),
    ),
    gridSummary: 'Force and descriptions for all 16 outputs',
    gridBuilder: (context) => _DDO3705ChannelGrid(
      config: config,
      stateMan: stateMan,
      animation: animation,
    ),
  );
}

/// The per-channel grid for the DDO3705 — 8 rows × 2 columns of `RowIOView`,
/// pairing channels `(r+1, r+9)`. Outputs are commanded, not sampled, so
/// there are no filter inputs (DDO-06).
///
/// Lifted verbatim out of the old `AlertDialog`: the force-write path is
/// byte-for-byte the one the Plan 02 tests lock, only its host changed.
/// A `ConsumerWidget` for the same reason as [_DDI3725ChannelGrid]: forcing an
/// output resolves the permission before it writes.
class _DDO3705ChannelGrid extends ConsumerWidget {
  final STBDDO3705Config config;
  final StateMan stateMan;
  final Animation<int> animation;

  const _DDO3705ChannelGrid({
    required this.config,
    required this.stateMan,
    required this.animation,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      IoGridViewport(child: _buildGrid(context, ref));

  Widget _buildGrid(BuildContext context, WidgetRef ref) {
    return StreamBuilder<Map<String, DynamicValue>>(
      stream: _combinedStream(
        LinkedHashMap<String, String?>.from(<String, String?>{
          'raw': config.rawStateKey,
          'force': config.forceValuesKey,
          'descriptions': config.descriptionsKey,
        }),
        stateMan,
      ),
      builder: (context, snap) {
        if (!snap.hasData || snap.hasError) {
          return const SizedBox.shrink();
        }
        final map = snap.data!;
        final rawDv = map['raw'];
        final List<bool>? rawStates = rawDv != null
            ? List<bool>.generate(16, (i) => (rawDv.asInt & (1 << i)) != 0)
            : null;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (int r = 0; r < 8; r++)
              Padding(
                padding: EdgeInsets.only(bottom: r < 7 ? 2.0 : 0.0),
                child: RowIOView(
                  leftRaw: rawStates?[r] ?? false,
                  rightRaw: rawStates?[r + 8] ?? false,
                  leftProcessed: null,
                  rightProcessed: null,
                  leftSelected: map['force']?[r].asInt ?? 0,
                  rightSelected: map['force']?[r + 8].asInt ?? 0,
                  animationValue: animation,
                  // No member: the force array is an `int8[16]`, so the
                  // channel is an index rather than a struct member and the
                  // question is asked about the key as a whole.
                  leftOnChanged: (value) async {
                    // DDO-09: genuine operator-driven force write.
                    // Mutate the force DV in-place (matches the EL2008
                    // pattern in beckhoff.dart), then write the whole
                    // int8[16] back through `writeTag`, which resolves the
                    // permission first and issues nothing when it is refused.
                    map['force']![r].value = value;
                    await writeTag(
                        ref, stateMan, config.forceValuesKey!, map['force']!);
                  },
                  rightOnChanged: (value) async {
                    map['force']![r + 8].value = value;
                    await writeTag(
                        ref, stateMan, config.forceValuesKey!, map['force']!);
                  },
                  leftDescription: map['descriptions']?[r].asString,
                  rightDescription: map['descriptions']?[r + 8].asString,
                  // DDO-06: outputs have NO filter inputs.
                  leftFilterEdit: null,
                  rightFilterEdit: null,
                ),
              ),
          ],
        );
      },
    );
  }
}

// ===========================================================================
// STBNIP2311Config — Schneider Advantys STB Ethernet head (composite parent).
// ===========================================================================
//
// Phase 3 introduced the NIP2311 as a DECORATIVE Ethernet head adapter
// (firmware-driven status LEDs + dual RJ45 ports — no PLC state keys).
//
// Phase 5 RETROFIT (2026-05-12): the NIP is the physical parent of the
// slotted I/O modules in a real Advantys STB rack. To mirror the Beckhoff
// precedent (`BeckhoffCX5010Config` / `BeckhoffEK1100Config` — both carry
// `List<Asset> subdevices` directly on the head class), the NIP itself now
// owns the composite-parent behavior. The standalone `AdvantysSTBStackConfig`
// wrapper was deleted; everything moved here.
//
// What stays from Phase 3:
//   - The decorative status LEDs + RJ45 visual (no NIP-level state keys).
//   - `nameOrId` field. No KeyField widgets in the head editor pane.
//   - The body widget `STBNIP2311Widget` is the visual identity anchor.
//
// What moved in from Phase 5 retrofit:
//   - `List<Asset> subdevices` with `@AssetListConverter()`.
//   - `allKeys` override flat-mapping subdevice keys.
//   - `_kAllowedSTBSubdeviceTypeNames` whitelist (PDT/DDI/DDO — NIP itself
//     is EXCLUDED so a NIP cannot nest another NIP).
//   - `_availableSTBSubdevices` Map (3 entries — NIP entry removed).
//   - `fromJson` factory wraps the generated `_$STBNIP2311ConfigFromJson`
//     with a `retainWhere` sanitiser that drops non-STB child types
//     (permissive render fallback, restrictive add via dropdown). Silent
//     filter + `Logger().w` log, matching `AssetRegistry.parse`'s convention.
//   - `_STBNIP2311ConfigContent` dialog (renamed from
//     `_AdvantysSTBStackConfigContent`) with the Add-dropdown + reorder +
//     delete trifecta on the right pane; the existing nameOrId field plus
//     Size + Coordinates(enableAngle: true) on the left.

/// Allowed STB subdevice runtimeType strings. The sanitiser drops anything
/// whose `runtimeType.toString()` is NOT in this set. The NIP itself is
/// intentionally EXCLUDED — a NIP head cannot nest another NIP head.
///
/// **Pitfall guard:** the set entries must match the exact string returned by
/// `runtimeType.toString()` on each leaf config (no package prefix, no
/// `Config` truncation). A unit test in
/// `test/page_creator/assets/advantys_stb_test.dart` asserts each leaf's
/// runtimeType against these literals.
const Set<String> _kAllowedSTBSubdeviceTypeNames = <String>{
  'STBPDT3100Config',
  'STBDDI3725Config',
  'STBDDO3705Config',
};

/// Map of human-readable display names → leaf preview-factories. The Add
/// dropdown in `_STBNIP2311ConfigContent` iterates these keys; the
/// THREE-entry whitelist is the FIRST gate against unsupported child types
/// (the post-`fromJson` sanitiser is the SECOND gate — defence-in-depth).
///
/// Mirrors `_availableSubdevices` from `beckhoff.dart`. Keys MUST match each
/// leaf's `displayName` getter; widget tests in
/// `test/page_creator/assets/advantys_stb_test.dart` assert the exact set.
/// NIP itself is excluded so the head cannot nest another head.
const Map<String, Asset Function()> _availableSTBSubdevices =
    <String, Asset Function()>{
  'STBPDT3100 (24 VDC PDM)': STBPDT3100Config.preview,
  'STBDDI3725 (16-Ch DI)': STBDDI3725Config.preview,
  'STBDDO3705 (16-Ch DO)': STBDDO3705Config.preview,
};

/// Schneider Advantys STB NIP2311 — Ethernet Modbus/TCP network interface
/// AND composite head for a stack of STB I/O modules (PDT / DDI / DDO).
///
/// The head itself is decorative (no NIP-level state keys), but it owns a
/// polymorphic [subdevices] list filtered to the three STB I/O module types
/// at load time via the post-`fromJson` sanitiser. `allKeys` flat-maps each
/// subdevice's own `allKeys` so alarms / collectors discover the full key set
/// without separate registration. The build path is type-agnostic (permissive
/// render): if a foreign type somehow survives in [subdevices], it renders
/// as-is and does not crash the page.
@JsonSerializable(explicitToJson: true)
class STBNIP2311Config extends BaseAsset {
  @override
  String get displayName => 'STBNIP2311 (Ethernet Head)';
  @override
  String get category => 'Advantys STB';

  @JsonKey(defaultValue: '1')
  String nameOrId;

  @AssetListConverter()
  List<Asset> subdevices = <Asset>[];

  STBNIP2311Config({
    this.nameOrId = '1',
    List<Asset>? subdevices,
  }) {
    if (subdevices != null) this.subdevices = subdevices;
  }

  STBNIP2311Config.preview()
      : nameOrId = '1',
        super();

  /// Custom factory that wraps the generated `_$STBNIP2311ConfigFromJson`
  /// with a post-deserialization sanitiser. Subdevices whose runtimeType is
  /// NOT in [_kAllowedSTBSubdeviceTypeNames] are dropped silently and the
  /// count of dropped entries is logged via `Logger().w(...)` (mirrors the
  /// `AssetRegistry.parse` silent-log-and-skip convention).
  factory STBNIP2311Config.fromJson(Map<String, dynamic> json) {
    final cfg = _$STBNIP2311ConfigFromJson(json);
    final before = cfg.subdevices.length;
    cfg.subdevices.retainWhere(
      (s) => _kAllowedSTBSubdeviceTypeNames.contains(s.runtimeType.toString()),
    );
    final dropped = before - cfg.subdevices.length;
    if (dropped > 0) {
      Logger().w(
        'STBNIP2311: dropped $dropped non-STB subdevice(s) on fromJson '
        '(allowed types: $_kAllowedSTBSubdeviceTypeNames)',
      );
    }
    return cfg;
  }

  @override
  Map<String, dynamic> toJson() => _$STBNIP2311ConfigToJson(this);

  /// Flat-maps each subdevice's `allKeys` into a deduplicated list with empty
  /// strings filtered out. Recurses naturally — if a subdevice is itself a
  /// composite (future), its own `allKeys` walks ITS subdevices. The NIP head
  /// itself contributes no keys (decorative).
  @override
  List<String> get allKeys {
    return subdevices
        .expand((s) => s is BaseAsset ? s.allKeys : <String>[])
        .where((k) => k.isNotEmpty)
        .toSet()
        .toList();
  }

  /// Native painter height for the subdevice height-normalization wrapper.
  /// Unitless reference — the outer `FittedBox` scales the whole row to the
  /// asset's `targetSize`. Mirrors `BeckhoffCX5010Config._cxNativeSize.height`
  /// (1000) for diff parity.
  static const double _stackNativeHeight = 1000;

  @override
  Widget build(BuildContext context) {
    // When the NIP is standalone (no subdevices), preserve the Phase-3
    // visual contract: a plain decorative head with no Row wrapper.
    if (subdevices.isEmpty) {
      return FittedBox(
        fit: BoxFit.contain,
        child: _STBNIP2311(config: this),
      );
    }
    // Composite mode: NIP head on the left, then the subdevices in slot order.
    final targetSize = size.toSize(MediaQuery.of(context).size);
    return SizedBox.fromSize(
      size: targetSize,
      child: FittedBox(
        fit: BoxFit.contain,
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            _STBSubdeviceNormalized(
              targetHeight: _stackNativeHeight,
              child: _STBNIP2311(config: this),
            ),
            for (final sub in subdevices)
              _STBSubdeviceNormalized(
                targetHeight: _stackNativeHeight,
                child: sub.build(context),
              ),
          ],
        ),
      ),
    );
  }

  /// Configure dialog — mirrors `BeckhoffCX5010Config.configure()` shape with
  /// the NIP-specific left pane (nameOrId + Size + Coordinates(enableAngle:
  /// true)) and the Add/Reorder/Delete subdevice manager on the right pane.
  @override
  Widget configure(BuildContext context) {
    return SizedBox(
      width: 800,
      height: 500,
      child: _STBNIP2311ConfigContent(config: this),
    );
  }
}

// ---------------------------------------------------------------------------
// Live widget — _STBNIP2311
//
// Decorative-only: the underlying `STBNIP2311Widget` already renders the
// fixed-state status LEDs and dual RJ45 ports. There is no StateMan
// subscription, no stream, no tap handler — taps fall through harmlessly.
// This is the NIP HEAD only; the composite Row wrapper lives on the
// `STBNIP2311Config.build()` path.
// ---------------------------------------------------------------------------

class _STBNIP2311 extends StatelessWidget {
  final STBNIP2311Config config;
  const _STBNIP2311({required this.config});

  @override
  Widget build(BuildContext context) {
    return STBNIP2311Widget(nameOrId: config.nameOrId);
  }
}

// ---------------------------------------------------------------------------
// Subdevice normalizer — `_STBSubdeviceNormalized`
//
// Wraps a subdevice widget and normalizes its visual height so it lines up
// with sibling subdevices. The outer `FittedBox` (in `build()`) then scales
// the whole row to the head's target size. Drop-in clone of
// `_SubdeviceNormalized` from `lib/page_creator/assets/beckhoff.dart`.
// ---------------------------------------------------------------------------

class _STBSubdeviceNormalized extends StatelessWidget {
  final double targetHeight;
  final Widget child;
  const _STBSubdeviceNormalized({
    required this.targetHeight,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: targetHeight,
      child: FittedBox(
        fit: BoxFit.fitHeight,
        alignment: Alignment.centerLeft,
        child: child,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Configure dialog body — _STBNIP2311ConfigContent
//
// VERBATIM clone of `_CXxxxxConfigContent` / `_CXxxxxConfigContentState` from
// `lib/page_creator/assets/beckhoff.dart` with these substitutions only:
//   - config field type     `BeckhoffCX5010Config` → `STBNIP2311Config`
//   - title text            `'CX5010'`             → `'STBNIP2311'`
//   - subdevice map ref     `_availableSubdevices` → `_availableSTBSubdevices`
//   - NIP head also carries a `nameOrId` field (the Beckhoff CX5010 does not)
//
// Everything else is line-by-line identical, INCLUDING:
//   - `enableAngle: true` on the CoordinatesField (CX5010 parity)
//   - NO delete-confirmation dialog (CX5010 parity)
//   - `ObjectKey(sub)` on the ListTile (Pitfall 6 — not ValueKey)
//   - Plain `StatefulWidget` / `State` (NOT ConsumerStatefulWidget — the
//     composite head does not subscribe to anything; only its leaf
//     subdevices do)
// ---------------------------------------------------------------------------

class _STBNIP2311ConfigContent extends StatefulWidget {
  final STBNIP2311Config config;

  const _STBNIP2311ConfigContent({required this.config});

  @override
  State<_STBNIP2311ConfigContent> createState() =>
      _STBNIP2311ConfigContentState();
}

class _STBNIP2311ConfigContentState extends State<_STBNIP2311ConfigContent> {
  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // LEFT: fields (independent scroll)
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'STBNIP2311',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                SizeField(
                  initialValue: widget.config.size,
                  onChanged: (size) => widget.config.size = size,
                ),
                const SizedBox(height: 16),
                CoordinatesField(
                  initialValue: widget.config.coordinates,
                  onChanged: (c) => widget.config.coordinates = c,
                  enableAngle: true,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  decoration: const InputDecoration(
                    labelText: 'Name or ID',
                    border: OutlineInputBorder(),
                  ),
                  initialValue: widget.config.nameOrId,
                  onChanged: (value) => widget.config.nameOrId = value,
                ),
              ],
            ),
          ),
        ),

        const VerticalDivider(width: 1),

        // RIGHT: subdevice manager
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // No "Done" button here. It used to pop the navigator, which
                // dismissed the config dialog this editor was shown in; the
                // editor now embeds it in a side pane that is not a route, so
                // the same tap would navigate out of the page editor
                // altogether. The pane's own action bar owns dismissal.
                Text('Subdevices',
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Add Subdevice',
                  ),
                  initialValue: null,
                  hint: const Text('Select a subdevice to add',
                      overflow: TextOverflow.ellipsis),
                  items: _availableSTBSubdevices.keys
                      .map((k) => DropdownMenuItem(value: k, child: Text(k)))
                      .toList(),
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() {
                      final mk = _availableSTBSubdevices[v]!;
                      widget.config.subdevices.add(mk());
                    });
                  },
                ),
                const SizedBox(height: 16),
                if (widget.config.subdevices.isEmpty)
                  Expanded(
                    child: Center(
                      child: Text(
                        'No subdevices yet',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  )
                else ...[
                  Row(
                    children: [
                      Text('Current Subdevices',
                          style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(width: 8),
                      Chip(label: Text('${widget.config.subdevices.length}')),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // Take remaining height of the dialog
                  Expanded(
                    child: Card(
                      clipBehavior: Clip.antiAlias,
                      child: ReorderableListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        buildDefaultDragHandles: false,
                        itemCount: widget.config.subdevices.length,
                        onReorder: (oldIndex, newIndex) {
                          setState(() {
                            if (newIndex > oldIndex) newIndex -= 1;
                            final item =
                                widget.config.subdevices.removeAt(oldIndex);
                            widget.config.subdevices.insert(newIndex, item);
                          });
                        },
                        itemBuilder: (context, index) {
                          final sub = widget.config.subdevices[index];
                          return ListTile(
                            key: ObjectKey(sub),
                            leading: ReorderableDragStartListener(
                              index: index,
                              child: const Icon(Icons.drag_indicator),
                            ),
                            title: Text(sub.runtimeType.toString()),
                            onTap: () => showStandardDialog<void>(
                              context: context,
                              title: sub.runtimeType.toString(),
                              subtitle: 'Configuration',
                              builder: (_) => sub.configure(context),
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete),
                              onPressed: () {
                                setState(() =>
                                    widget.config.subdevices.removeAt(index));
                              },
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ===========================================================================
// STBPDT3100Config — Schneider Advantys STB 24 VDC power distribution module.
// ===========================================================================
//
// Phase 4 deliverable: a slim cream-bodied module that distributes 24 VDC
// power to the STB I/O bus. Single optional bool key (`inputOkKey`) drives
// the front-panel "INPUT" LED via the body painter:
//   - stream emits true  → LED green
//   - stream emits false → LED dim grey
//   - stream errored / not yet emitted / key null → LED dim grey
//
// No detail dialog (single bool is too narrow to warrant one — the configure
// dialog handles the inputOkKey binding directly). Tap behaviour: harmless
// no-op (no GestureDetector wrapper).
//
// Locked by 04-CONTEXT.md. Requirements: PDT-01..03.

/// Schneider Advantys STB PDT3100 — 24 VDC power distribution module.
///
/// One optional bool state key (`inputOkKey`) drives the single front-panel
/// "INPUT" LED. When the key is null, the LED renders dim grey (consistent
/// with the stale/disconnected treatment used by the I/O modules). When the
/// key is configured AND the stream emits `true`, the LED renders green;
/// any other state (false, stale, errored) renders dim grey.
///
/// `BaseAsset.allKeys` picks up `inputOkKey` automatically via the `Key$`
/// regex (no override needed) and filters out empty strings.
@JsonSerializable(explicitToJson: true)
class STBPDT3100Config extends BaseAsset {
  @override
  String get displayName => 'STBPDT3100 (24 VDC PDM)';
  @override
  String get category => 'Advantys STB';

  @JsonKey(defaultValue: '1')
  String nameOrId;

  String? inputOkKey;

  STBPDT3100Config({
    this.nameOrId = '1',
    this.inputOkKey,
  });

  STBPDT3100Config.preview()
      : nameOrId = '1',
        inputOkKey = null,
        super();

  factory STBPDT3100Config.fromJson(Map<String, dynamic> json) =>
      _$STBPDT3100ConfigFromJson(json);

  @override
  Map<String, dynamic> toJson() => _$STBPDT3100ConfigToJson(this);

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.contain,
      child: _STBPDT3100(config: this),
    );
  }

  @override
  Widget configure(BuildContext context) {
    final media = MediaQuery.of(context).size;
    final maxWidth = media.width * 0.9;
    final maxHeight = media.height * 0.8;

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth,
          maxHeight: maxHeight,
          minWidth: 320,
          minHeight: 200,
        ),
        child: Material(
          borderRadius: BorderRadius.circular(24),
          color: DialogTheme.of(context).backgroundColor ??
              Theme.of(context).colorScheme.surface,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: SingleChildScrollView(
              child: _STBPDT3100ConfigEditor(config: this),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Live widget — _STBPDT3100
//
// ConsumerStatefulWidget so the bool stream is hoisted to `initState` (no
// resubscribe storm on parent rebuild — matches `_STBDDI3725`/`_STBDDO3705`
// hoisting contract per QUAL-03 / PITFALL M-03). When `inputOkKey` is null,
// the widget renders the static dim-grey LED state without subscribing.
// ---------------------------------------------------------------------------

class _STBPDT3100 extends ConsumerStatefulWidget {
  final STBPDT3100Config config;
  const _STBPDT3100({required this.config});

  @override
  ConsumerState<_STBPDT3100> createState() => _STBPDT3100State();
}

class _STBPDT3100State extends ConsumerState<_STBPDT3100> {
  Stream<DynamicValue>? _inputOkStreamCache;

  @override
  void initState() {
    super.initState();
    // Resolve StateMan once. If `inputOkKey` is null, no subscription is
    // built — the widget renders the dim-grey LED forever (consistent with
    // CONTEXT.md §Single LED State Mapping).
    final key = widget.config.inputOkKey;
    if (key == null || key.isEmpty) return;
    ref.read(stateManProvider.future).then((sm) {
      if (!mounted) return;
      setState(() {
        _inputOkStreamCache =
            sm.subscribe(key).asStream().asyncExpand((s) => s);
      });
    });
  }

  @override
  void dispose() {
    // QUAL-03 lifecycle hygiene — drop the cached stream to release the
    // closure-captured `StateMan` reference. The underlying StreamSubscription
    // is owned + cancelled by the framework's StreamBuilder on unmount.
    _inputOkStreamCache = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_inputOkStreamCache == null) {
      return STBPDT3100Widget(
        nameOrId: widget.config.nameOrId,
        inputOk: null,
      );
    }
    return StreamBuilder<DynamicValue>(
      stream: _inputOkStreamCache,
      builder: (context, snap) {
        final bool? inputOk;
        if (snap.hasError || !snap.hasData || snap.data == null) {
          inputOk = null;
        } else {
          // CONTEXT.md §Single LED State Mapping: only `true` lights green;
          // false / errored / stale all collapse to null (dim grey).
          inputOk = snap.data!.asBool == true ? true : false;
        }
        return STBPDT3100Widget(
          nameOrId: widget.config.nameOrId,
          inputOk: inputOk,
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Configure dialog body — _STBPDT3100ConfigEditor
//
// Surfaces: Size + Coordinates + nameOrId + Input OK Key (the single optional
// state-key field). The `editor surface` test in advantys_stb_test.dart locks
// the count to exactly one KeyField — accidental state-key growth fails CI.
// ---------------------------------------------------------------------------

class _STBPDT3100ConfigEditor extends StatefulWidget {
  final STBPDT3100Config config;
  const _STBPDT3100ConfigEditor({required this.config});

  @override
  State<_STBPDT3100ConfigEditor> createState() =>
      _STBPDT3100ConfigEditorState();
}

class _STBPDT3100ConfigEditorState extends State<_STBPDT3100ConfigEditor> {
  @override
  Widget build(BuildContext context) {
    return Column(
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
          onChanged: (coordinates) => widget.config.coordinates = coordinates,
          enableAngle: false,
        ),
        const SizedBox(height: 16),
        TextFormField(
          decoration: const InputDecoration(
            labelText: 'Name or ID',
            border: OutlineInputBorder(),
          ),
          initialValue: widget.config.nameOrId,
          onChanged: (value) => widget.config.nameOrId = value,
        ),
        const SizedBox(height: 16),
        KeyField(
          initialValue: widget.config.inputOkKey,
          onChanged: (value) => widget.config.inputOkKey = value,
          label: 'Input OK Key',
        ),
      ],
    );
  }
}

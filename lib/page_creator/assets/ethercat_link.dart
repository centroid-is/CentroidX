/// The EtherCAT cable asset — a run between two devices' ports.
///
/// Unlike every other asset on a page this one has no position of its own.
/// Its ends belong to the devices it plugs into, so moving a terminal moves
/// the cable, and its box is derived from wherever those devices are (see
/// [EtherCatLinkConfig.boxOn]).
///
/// The PLC side is `ST_EtherCATLink_HMI`
/// (`SVNCoreComponents/ECT/ST_EtherCATLink_HMI.TcDUT`): one struct per cable,
/// filled by an FB from the two ends' diagnostics rather than mapped off a
/// PDO. Nothing links to it — see that file's trailing comment for what the
/// FB owes it.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:open62541/open62541.dart' show DynamicValue;

import '../../providers/state_man.dart';
import '../../theme.dart' show HmiStateColors;
import '../../widgets/hit_boundary.dart' show AssetHitShape;
import '../../widgets/panes/side_pane.dart';
import 'common.dart';
import 'ethercat_link_pane.dart';
import 'ethercat_link_painter.dart';
import 'link_anchors.dart';
import 'link_geometry.dart';
import '../../widgets/tag_access_guard.dart' show writeTag;

part 'ethercat_link.g.dart';

/// Member names on `ST_EtherCATLink_HMI`.
abstract final class LinkFields {
  static const linkUp = 'p_stat_xLinkUp';
  static const communicating = 'p_stat_xCommunicating';
  static const degraded = 'p_stat_xDegraded';
  static const stale = 'p_stat_xStale';
  static const connectedMinutes = 'p_stat_udiConnectedMinutes';
  static const longestMinutes = 'p_stat_udiLongestConnectedMinutes';
  static const connectCount = 'p_stat_udiConnectCount';
  static const crcErrors = 'p_stat_udiCrcErrors';
  static const forwardedErrors = 'p_stat_udiForwardedErrors';
  static const lostLinks = 'p_stat_udiLostLinks';
  static const minutesSinceError = 'p_stat_udiMinutesSinceLastError';
  static const availabilityPct = 'p_stat_rAvailabilityPct';

  /// `ST_Counter` of errors over rolling windows.
  static const errorRate = 'p_stat_ErrorRate';

  /// The window worth showing: what this cable has done in the last hour.
  static const errorRateHour = 'Minute60';
  static const resetCounters = 'p_cmd_xResetCounters';
}

/// One cable's published state.
class EtherCatLinkState {
  const EtherCatLinkState({
    required this.linkUp,
    required this.communicating,
    required this.degraded,
    required this.stale,
    required this.connectedMinutes,
    required this.longestMinutes,
    required this.connectCount,
    required this.crcErrors,
    required this.forwardedErrors,
    required this.lostLinks,
    required this.minutesSinceError,
    required this.availabilityPct,
    required this.errorsLastHour,
  });

  final bool linkUp;
  final bool communicating;
  final bool degraded;
  final bool stale;
  final int connectedMinutes;
  final int longestMinutes;
  final int connectCount;
  final int crcErrors;
  final int forwardedErrors;
  final int lostLinks;
  final int minutesSinceError;
  final double availabilityPct;

  /// Errors on this cable in the last hour.
  ///
  /// The number that decides whether anybody walks out to it. A lifetime
  /// total says what this cable has ever done; forty errors two years ago and
  /// forty this morning are the same total and completely different cables.
  final int errorsLastHour;

  /// Decodes an `ST_EtherCATLink_HMI`, or null when [value] is not one.
  ///
  /// Discriminated on [LinkFields.linkUp]: it is the member the FB always
  /// fills, and no plain BOOL node carries it under that name.
  static EtherCatLinkState? tryParse(DynamicValue value) {
    if (!value.isObject) return null;
    if (!value.contains(LinkFields.linkUp)) return null;
    return EtherCatLinkState(
      linkUp: _bool(value, LinkFields.linkUp),
      communicating: _bool(value, LinkFields.communicating),
      degraded: _bool(value, LinkFields.degraded),
      stale: _bool(value, LinkFields.stale),
      connectedMinutes: _int(value, LinkFields.connectedMinutes),
      longestMinutes: _int(value, LinkFields.longestMinutes),
      connectCount: _int(value, LinkFields.connectCount),
      crcErrors: _int(value, LinkFields.crcErrors),
      forwardedErrors: _int(value, LinkFields.forwardedErrors),
      lostLinks: _int(value, LinkFields.lostLinks),
      minutesSinceError: _int(value, LinkFields.minutesSinceError),
      availabilityPct: _double(value, LinkFields.availabilityPct),
      errorsLastHour: _rate(value, LinkFields.errorRateHour),
    );
  }

  /// What the cable should be painted as.
  ///
  /// Order matters. Stale outranks everything: values that are not being
  /// updated must not be reported as facts, and "we cannot tell" is a
  /// different statement from "it is fine". Down outranks degraded because a
  /// cable that is out is not also interestingly marginal.
  LinkHealth get health {
    if (stale) return LinkHealth.unknown;
    if (!linkUp) return LinkHealth.down;
    if (degraded) return LinkHealth.degraded;
    return LinkHealth.healthy;
  }

  // `DynamicValue.operator[]` throws on a missing member, so every read is
  // guarded: a PLC running a struct revision without a member must degrade,
  // not take the mimic down.
  static bool _bool(DynamicValue v, String f) =>
      v.contains(f) ? v[f].asBool : false;
  static int _int(DynamicValue v, String f) => v.contains(f) ? v[f].asInt : 0;
  static double _double(DynamicValue v, String f) =>
      v.contains(f) ? v[f].asDouble : 0;

  /// A window off the nested `ST_Counter`, guarded twice: the struct may not
  /// carry the counter at all on an older PLC revision.
  static int _rate(DynamicValue v, String window) {
    if (!v.contains(LinkFields.errorRate)) return 0;
    final counter = v[LinkFields.errorRate];
    if (!counter.isObject || !counter.contains(window)) return 0;
    return counter[window].asInt;
  }
}

/// Formats a span of minutes the way an operator reads an uptime.
///
/// `d:hh:mm`, dropping the days when there are none. The PLC counts minutes
/// rather than a `TIME` precisely so this can run past 49.7 days without
/// pinning, so the formatter has to carry arbitrarily large day counts.
String formatDaysHoursMinutes(int minutes) {
  if (minutes < 0) minutes = 0;
  final d = minutes ~/ 1440;
  final h = (minutes % 1440) ~/ 60;
  final m = minutes % 60;
  final hh = h.toString().padLeft(2, '0');
  final mm = m.toString().padLeft(2, '0');
  return d == 0 ? '$hh:$mm' : '${d}d $hh:$mm';
}

@JsonSerializable(explicitToJson: true)
class EtherCatLinkConfig extends BaseAsset {
  @override
  String get displayName => 'EtherCAT Link';

  @override
  String get category => 'Beckhoff';

  @override
  List<String> get searchKeywords =>
      const ['cable', 'ethercat', 'link', 'run', 'patch lead', 'network'];

  /// A run is chiral — a bend goes one way — so a mirrored station must show
  /// it bending the other way or the page describes a cable that is not there.
  @override
  bool get mirrorsWithPage => true;

  /// The `ST_EtherCATLink_HMI` node for this cable. Empty means nothing is
  /// subscribed and the run paints as idle: still useful, because a cable
  /// drawn on a mimic documents the wiring whether or not the PLC reports it.
  String key;

  /// Where the cable runs, and what holds each corner.
  LinkRun run;

  /// Stroke width as a fraction of the canvas's shortest side.
  double thickness;

  EtherCatLinkConfig({
    this.key = '',
    LinkRun? run,
    this.thickness = 0.006,
  }) : run = run ?? LinkRun() {
    // BaseAsset defaults to a 3% square, which is the wrong shape for
    // something whose whole nature is being long and thin. A cable dropped
    // from the palette wants to be wide enough to see and to grab before it
    // is plugged into anything. `fromJson` overwrites this from the stored
    // size, so it only ever affects a newly made one.
    size = const RelativeSize(width: 0.18, height: 0.08);
  }

  /// The palette tile: a bend, because a straight line is not recognisable as
  /// a cable and every other tile in the grid is a picture of its thing.
  EtherCatLinkConfig.preview()
      : this(run: LinkRun(waypoints: [LinkWaypoint.onRun(0.5, -0.22)]));

  factory EtherCatLinkConfig.fromJson(Map<String, dynamic> json) =>
      _$EtherCatLinkConfigFromJson(json);

  @override
  Map<String, dynamic> toJson() => _$EtherCatLinkConfigToJson(this);

  /// Both ends and every pinned corner, so a paste can re-point them at the
  /// copies of the devices that came with it.
  @override
  void remapAssetIds(Map<String, String> idMap) {
    for (final end in [run.from, run.to]) {
      final id = end.assetId;
      if (id != null) end.assetId = idMap[id] ?? id;
    }
    for (final w in run.waypoints) {
      final pin = w.pinnedTo;
      if (pin != null) w.pinnedTo = idMap[pin] ?? pin;
    }
  }

  /// Ids this run names, for anything that needs to know what it depends on.
  @JsonKey(includeFromJson: false, includeToJson: false)
  List<String> get referencedAssetIds => [
        for (final end in [run.from, run.to])
          if (end.assetId != null) end.assetId!,
        for (final w in run.waypoints)
          if (w.pinnedTo != null) w.pinnedTo!,
      ];

  /// True once either end is plugged into something.
  ///
  /// An unplugged cable has nothing to derive a position from, so it stays an
  /// ordinary box asset: it sits where it was dropped, drags with the mouse
  /// and is selected by its rectangle, exactly like everything else off the
  /// palette. The moment an end names a device, that device decides where the
  /// cable is and [boxOn] takes over.
  @JsonKey(includeFromJson: false, includeToJson: false)
  bool get isPluggedIn => run.from.assetId != null || run.to.assetId != null;

  /// The run laid across this asset's own box, for a cable plugged into
  /// nothing.
  ///
  /// The stored free-end coordinates are a *fallback for a binding that
  /// broke*, not a position an operator ever set, so they are not what an
  /// unplugged cable should be drawn between. Its own box is.
  LinkRun runAcrossOwnBox() {
    final half = size.width / 2;
    final copy = run.copy();
    copy.from
      ..assetId = null
      ..x = coordinates.x - half
      ..y = coordinates.y;
    copy.to
      ..assetId = null
      ..x = coordinates.x + half
      ..y = coordinates.y;
    return copy;
  }

  /// The box the run occupies, from wherever its devices currently are.
  ///
  /// Padded by the stroke so the end caps are inside it: a rect measured on
  /// the centreline clips half the cable away at the extremes.
  @override
  Rect? boxOn(List<Asset> page, Size canvas) {
    if (canvas.isEmpty || !isPluggedIn) return null;
    return run.boundsIn(PageLinkAnchors(page, canvas), pad: thickness);
  }

  /// Taps land on the cable, not on the rectangle that spans its two devices.
  ///
  /// The editor puts an opaque gesture detector over an asset's whole box. On
  /// a run that box is most of the page, so without this the cable would eat
  /// every tap meant for the equipment it passes and a marquee could not be
  /// started anywhere it crosses.
  @override
  bool hitTestBox(Offset local, Size boxSize, List<Asset> page, Size canvas) {
    final box = boxOn(page, canvas);
    // Unplugged, so it really is an ordinary box asset.
    if (box == null) return true;
    final resolved = run.resolve(canvas, PageLinkAnchors(page, canvas));
    final origin = Offset(box.left * canvas.width, box.top * canvas.height);
    return resolved.distanceTo(local + origin) <= hitWidthOn(canvas) / 2;
  }

  /// Stroke width actually painted on [canvas]; see the two-pixel floor.
  double strokeWidthOn(Size canvas) =>
      math.max(thickness * canvas.shortestSide, 2.0);

  /// How wide the cable is to a finger, which is wider than its ink.
  double hitWidthOn(Size canvas) {
    final w = strokeWidthOn(canvas);
    return w < 18 ? 18 : w;
  }

  @override
  Widget build(BuildContext context) => EtherCatLink(config: this);

  @override
  Widget configure(BuildContext context) =>
      EtherCatLinkConfigEditor(config: this);
}

/// Runtime widget: subscribes to the cable's struct and paints the run.
class EtherCatLink extends ConsumerStatefulWidget {
  const EtherCatLink({super.key, required this.config});

  final EtherCatLinkConfig config;

  @override
  ConsumerState<EtherCatLink> createState() => _EtherCatLinkState();
}

class _EtherCatLinkState extends ConsumerState<EtherCatLink> {
  Stream<DynamicValue>? _stream;
  String? _subscribedTo;

  /// Last decode, for the pane. The pane is opened from a tap rather than
  /// rebuilt with the widget, so it needs somewhere to read the current
  /// values from that is not a StreamBuilder snapshot.
  EtherCatLinkState? _last;

  /// How long `p_cmd_xResetCounters` is held high. Long enough to survive a
  /// slow OPC UA round trip and the PLC scan behind it, short enough that an
  /// operator sees one press rather than a latched switch -- the same reason
  /// [kEl9222ResetPulse] is what it is.
  static const _resetPulse = Duration(milliseconds: 400);

  /// Pulses the reset bit. Nothing in the PLC clears it, so the HMI owns the
  /// whole edge.
  Future<void> _resetCounters() async {
    final key = widget.config.key;
    if (key.isEmpty) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final sm = await ref.read(stateManProvider.future);
    const readTimeout = Duration(seconds: 5);

    /// True when the write went out. A refusal answers false rather than
    /// throwing, which is what lets the pulse below suppress its falling
    /// edge — one refused press has to be one refusal, not two.
    Future<bool> set(bool level) async {
      final latest = await sm.read(key).timeout(readTimeout);
      final next = DynamicValue.from(latest);
      next[LinkFields.resetCounters] = level;
      return writeTag(ref, sm, key, next,
          member: LinkFields.resetCounters);
    }

    try {
      // Nothing in the PLC clears this bit, so the HMI owns both edges — and
      // a refused rising edge must not be followed by a falling one that
      // prompts a second time about a pulse that never started.
      if (!await set(true)) return;
      await Future<void>.delayed(_resetPulse);
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Counter reset failed: $e')),
      );
    } finally {
      try {
        await set(false);
      } catch (e) {
        messenger?.showSnackBar(
          SnackBar(
            content: Text(
              'The reset bit is stuck on -- clear it before the next '
              'reset: $e',
            ),
          ),
        );
      }
    }
  }

  void _openPane() {
    final label = widget.config.text;
    showSidePane(
      context: context,
      id: 'ethercat-link-${widget.config.ensureId()}',
      builder: (paneContext) => SidePane(
        title: label?.isNotEmpty == true ? label! : 'EtherCAT link',
        subtitle: 'Cable',
        icon: Icons.cable,
        status: etherCatLinkPaneStatus(_last?.health ??
            (widget.config.key.isEmpty ? LinkHealth.idle : LinkHealth.unknown)),
        child: EtherCatLinkPaneBody(
          state: _last,
          onResetCounters: widget.config.key.isEmpty ? null : _resetCounters,
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _resubscribe();
  }

  @override
  void didUpdateWidget(EtherCatLink old) {
    super.didUpdateWidget(old);
    // Only when the key actually changed. Rebuilding the stream on every
    // rebuild is the resubscribe storm the sensor asset documents.
    if (widget.config.key != _subscribedTo) _resubscribe();
  }

  void _resubscribe() {
    final key = widget.config.key;
    _subscribedTo = key;
    if (key.isEmpty) {
      _stream = null;
      return;
    }
    _stream = ref
        .read(stateManProvider.future)
        .asStream()
        .asyncExpand((sm) => sm.subscribe(key).asStream())
        .asyncExpand((s) => s);
  }

  @override
  Widget build(BuildContext context) {
    final stream = _stream;
    if (stream == null) return _paint(context, LinkHealth.idle);
    return StreamBuilder<DynamicValue>(
      stream: stream,
      builder: (context, snap) {
        if (snap.hasError) return _paint(context, LinkHealth.unknown);
        final value = snap.data;
        if (value == null) return _paint(context, LinkHealth.idle);
        final state = EtherCatLinkState.tryParse(value);
        _last = state;
        // A node that is not the struct is not something to guess at.
        return _paint(context, state?.health ?? LinkHealth.unknown);
      },
    );
  }

  Widget _paint(BuildContext context, LinkHealth health) {
    final states = Theme.of(context).extension<HmiStateColors>() ??
        HmiStateColors.solarizedLight;
    final anchors = PageAssetsScope.anchorsOf(context);

    return LayoutBuilder(builder: (context, constraints) {
      final scope = PageAssetsScope.maybeOf(context);
      // The run is resolved in whole-page coordinates, then drawn relative to
      // this asset's own box -- which is a slice of the page, not the page.
      final canvas =
          scope?.canvas ?? Size(constraints.maxWidth, constraints.maxHeight);
      final box = widget.config.boxOn(scope?.assets ?? const [], canvas);
      final ResolvedLink resolved;
      final Offset origin;
      if (box == null) {
        // Unplugged: an ordinary box asset, drawn across itself.
        resolved =
            widget.config.runAcrossOwnBox().resolve(canvas, LinkAnchors.none);
        origin = Offset(
          widget.config.coordinates.x * canvas.width - constraints.maxWidth / 2,
          widget.config.coordinates.y * canvas.height -
              constraints.maxHeight / 2,
        );
      } else {
        resolved = widget.config.run.resolve(canvas, anchors);
        origin = Offset(box.left * canvas.width, box.top * canvas.height);
      }

      final painter = EtherCatLinkPainter(
        link: ResolvedLink(
          [for (final p in resolved.points) p - origin],
          resolved.frame,
          canvas,
          resolved.radius,
        ),
        color: linkHealthColor(states, health),
        strokeWidth: widget.config.strokeWidthOn(canvas),
      );

      return AssetHitShape(
        shape: painter.outline,
        child: GestureDetector(
          // deferToChild, so the painter's own hitTest decides. Opaque would
          // put the cable's whole rectangle -- most of the page -- in front
          // of the equipment it runs past.
          behavior: HitTestBehavior.deferToChild,
          onTap: _openPane,
          child: CustomPaint(
            painter: painter,
            size: Size(constraints.maxWidth, constraints.maxHeight),
          ),
        ),
      );
    });
  }
}

/// Configure form. Endpoint pickers plus the cable's key and look; the corners
/// themselves are dragged on the canvas, not typed here.
class EtherCatLinkConfigEditor extends StatefulWidget {
  const EtherCatLinkConfigEditor({super.key, required this.config});

  final EtherCatLinkConfig config;

  @override
  State<EtherCatLinkConfigEditor> createState() =>
      _EtherCatLinkConfigEditorState();
}

class _EtherCatLinkConfigEditorState extends State<EtherCatLinkConfigEditor> {
  @override
  Widget build(BuildContext context) {
    final scope = PageAssetsScope.maybeOf(context);
    final candidates = [
      for (final a in scope?.assets ?? const <Asset>[])
        if (!identical(a, widget.config)) a,
    ];

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextFormField(
            initialValue: widget.config.key,
            decoration: const InputDecoration(
              labelText: 'Link struct key',
              helperText: 'ST_EtherCATLink_HMI node. Leave empty to just draw '
                  'the cable.',
            ),
            onChanged: (v) => widget.config.key = v,
          ),
          const SizedBox(height: 16),
          _EndPicker(
            label: 'From',
            end: widget.config.run.from,
            candidates: candidates,
            onChanged: () => setState(() {}),
          ),
          const SizedBox(height: 12),
          _EndPicker(
            label: 'To',
            end: widget.config.run.to,
            candidates: candidates,
            onChanged: () => setState(() {}),
          ),
          const SizedBox(height: 16),
          Text('Corner radius', style: Theme.of(context).textTheme.labelMedium),
          Slider(
            value: widget.config.run.radius,
            max: 0.15,
            onChanged: (v) => setState(() => widget.config.run.radius = v),
          ),
          Text('Thickness', style: Theme.of(context).textTheme.labelMedium),
          Slider(
            value: widget.config.thickness,
            min: 0.001,
            max: 0.02,
            onChanged: (v) => setState(() => widget.config.thickness = v),
          ),
          if (widget.config.run.waypoints.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${widget.config.run.waypoints.length} corner'
                      '${widget.config.run.waypoints.length == 1 ? '' : 's'}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        setState(() => widget.config.run.waypoints.clear()),
                    child: const Text('Straighten'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Picks the asset and port one end of a run plugs into.
class _EndPicker extends StatelessWidget {
  const _EndPicker({
    required this.label,
    required this.end,
    required this.candidates,
    required this.onChanged,
  });

  final String label;
  final LinkEnd end;
  final List<Asset> candidates;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    // Only assets that already carry an id can be named here, plus whichever
    // one this end already points at.
    final selected = end.assetId;
    final ports = _portsFor(selected);
    // A stored X1/X2 on a device that now declares A–D is still that
    // socket: show the port it resolves to rather than a blank.
    final shown = findPort(ports, end.port)?.id;
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: DropdownButtonFormField<String?>(
            initialValue:
                candidates.any((a) => a.id == selected) ? selected : null,
            decoration: InputDecoration(labelText: '$label asset'),
            items: [
              const DropdownMenuItem(value: null, child: Text('(free point)')),
              for (final a in candidates)
                DropdownMenuItem(
                  value: a.ensureId(),
                  child: Text(a.text?.isNotEmpty == true
                      ? '${a.text} — ${a.displayName}'
                      : a.displayName),
                ),
            ],
            onChanged: (v) {
              end.assetId = v;
              if (v != null) {
                final available = _portsFor(v);
                if (findPort(available, end.port) == null) {
                  end.port = available.isEmpty ? null : available.first.id;
                }
              }
              onChanged();
            },
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: shown,
            decoration: const InputDecoration(labelText: 'Port'),
            items: [
              for (final p in ports)
                DropdownMenuItem(value: p.id, child: Text(p.id)),
            ],
            onChanged: (v) {
              end.port = v;
              onChanged();
            },
          ),
        ),
      ],
    );
  }

  List<NetworkPort> _portsFor(String? assetId) {
    if (assetId == null) return const [];
    for (final a in candidates) {
      if (a.id == assetId) return portsOf(a);
    }
    return const [];
  }
}

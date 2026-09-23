/// The editor's handles for a selected cable.
///
/// A run is the one asset you draw rather than place, so it needs a surface
/// the box-and-handles chrome cannot give it: a handle per corner, a ghost on
/// each segment to make a new one, and an end you can drag onto another device
/// to re-plug it.
///
/// The rules the benches settled on, kept here so the code says them too:
///
///  - **Nothing is typed.** No sweep, no per-corner radius, none of the three
///    numbers a conveyor turn asks for. A corner is dropped where it goes and
///    the numbers are derived.
///  - **A corner stays where it was put.** Moving an end stretches the segment
///    next to it and nothing else. Following a device instead is chosen from
///    the corner's right-click menu.
///  - **Ends are ports, and the ports are shown.** While a cable is selected
///    every socket on the page is marked; dragging an end near one snaps to it
///    and lights it up, and letting go there plugs it in. Dropped on empty
///    canvas, an end unplugs and stays where it landed.
///  - **The cable is still an asset.** Double-clicking it opens its form and
///    right-clicking it opens the editor's menu, as for anything else.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme.dart' show HmiStateColors;
import 'common.dart';
import 'ethercat_link.dart';
import 'link_anchors.dart';
import 'link_geometry.dart';

/// Radius of a corner handle, in logical pixels.
const double _kHandleRadius = 8;

/// Side of the square a handle can be grabbed by. Finger-sized, not ink-sized.
const double _kHandleGrab = 32;

/// How close a dropped corner has to come to a neighbour to collapse into it.
/// Small, so it takes landing on the neighbour's handle: on a short cable a
/// larger radius deleted any corner dropped anywhere near an end.
const double _kMergeDistance = 8;

/// Shortest segment that still earns a ghost. Below this the ghost would sit
/// on top of the handles at either end and be impossible to grab.
const double _kMinGhostSegment = 36;

/// How near a dragged end has to come to a port to snap to it.
///
/// Generous on purpose. A device's sockets sit on the edge of its box, and a
/// drop a few pixels outside that edge is a drop on the socket, not on the
/// empty canvas beside it.
const double kLinkPortSnapDistance = 28;

/// Width of the invisible stroke along the cable that answers taps, drags and
/// clicks. The ink is far too thin to aim at.
const double _kCableTarget = 24;

class LinkEditOverlay extends StatefulWidget {
  const LinkEditOverlay({
    super.key,
    required this.link,
    required this.assets,
    required this.canvas,
    required this.onChanged,
    required this.onBeginEdit,
    this.onEndEdit,
    this.onConfigure,
    this.onSecondaryTap,
  });

  final EtherCatLinkConfig link;

  /// The whole page, for resolving the run and for finding what an end was
  /// dropped onto.
  final List<Asset> assets;
  final Size canvas;

  /// Called after any edit, so the editor can repaint. During a drag this
  /// fires on every pointer move; [onEndEdit] marks where the gesture settles.
  final VoidCallback onChanged;

  /// Called once at the start of a gesture, so one drag is one undo step
  /// rather than one per pointer move.
  final VoidCallback onBeginEdit;

  /// Called once when a gesture settles, so the editor can do its per-gesture
  /// work — re-encoding the page — once rather than on every move.
  final VoidCallback? onEndEdit;

  /// Double-click on the cable: open its form.
  final VoidCallback? onConfigure;

  /// Right-click on the cable, with the point in this overlay's (the
  /// canvas's) coordinates and on screen. When null the overlay offers its
  /// own small menu instead.
  final void Function(Offset local, Offset global)? onSecondaryTap;

  @override
  State<LinkEditOverlay> createState() => _LinkEditOverlayState();
}

/// One socket on the page, where a cable end could go.
class _PortSpot {
  _PortSpot(this.asset, this.port, this.at);

  final Asset asset;
  final NetworkPort port;

  /// Canvas pixels.
  final Offset at;
}

class _LinkEditOverlayState extends State<LinkEditOverlay> {
  PageLinkAnchors get _anchors => PageLinkAnchors(widget.assets, widget.canvas);

  ResolvedLink get _resolved =>
      widget.link.run.resolve(widget.canvas, _anchors);

  /// The Stack the handles are positioned in — the one coordinate space the
  /// overlay trusts. Handles report global points and this converts them.
  final GlobalKey _frame = GlobalKey();

  Offset _toLocal(Offset global) {
    final box = _frame.currentContext?.findRenderObject() as RenderBox?;
    return box == null ? global : box.globalToLocal(global);
  }

  /// Guards the whole gesture so a drag is one undo entry.
  bool _editing = false;

  /// The port an end being dragged is snapped to, lit up until it is dropped.
  _PortSpot? _snap;

  void _begin() {
    if (_editing) return;
    _editing = true;
    widget.onBeginEdit();
    // After the undo snapshot, so undo brings back the page exactly as it
    // was saved. A corner held in the run's frame would swing with every
    // pixel the end moves; this puts it on the page where it already is.
    widget.link.run.settleOnPage(_anchors);
  }

  void _end() {
    if (!_editing) return;
    _editing = false;
    widget.onEndEdit?.call();
  }

  void _changed() {
    widget.onChanged();
    setState(() {});
  }

  /// Runs a one-shot edit as its own undo step.
  void _edit(VoidCallback fn) {
    _begin();
    fn();
    _changed();
    _end();
  }

  /// Every socket on the page, the cable's own excepted. Only devices that
  /// declare their sockets are marked: the X1/X2 assumed for anything else
  /// would put two circles on every button and label on the page.
  List<_PortSpot> _ports() {
    final anchors = _anchors;
    final spots = <_PortSpot>[];
    void visit(Iterable<Asset> assets) {
      for (final a in assets) {
        if (identical(a, widget.link)) continue;
        if (a is NetworkPorted) {
          for (final p in (a as NetworkPorted).networkPorts) {
            final page = anchors.portOn(a, p);
            spots.add(_PortSpot(
                a,
                p,
                Offset(page.dx * widget.canvas.width,
                    page.dy * widget.canvas.height)));
          }
        }
        visit(a.childAssets);
      }
    }

    visit(widget.assets);
    return spots;
  }

  /// The socket nearest [at], if one is within snapping distance.
  _PortSpot? _portNear(Offset at) {
    _PortSpot? best;
    var bestD = kLinkPortSnapDistance;
    for (final s in _ports()) {
      final d = (s.at - at).distance;
      if (d <= bestD) {
        bestD = d;
        best = s;
      }
    }
    return best;
  }

  /// The asset under [at], ignoring the cable itself.
  ///
  /// Last match wins: the page paints in list order, so the last asset whose
  /// box contains the point is the one drawn on top and the one the operator
  /// thinks they dropped onto.
  Asset? _assetUnder(Offset at) {
    final anchors = _anchors;
    Asset? found;

    void test(Asset asset, Rect box) {
      final cx = box.center.dx * widget.canvas.width;
      final cy = box.center.dy * widget.canvas.height;
      final w = box.width * widget.canvas.width;
      final h = box.height * widget.canvas.height;
      if ((at.dx - cx).abs() <= w / 2 && (at.dy - cy).abs() <= h / 2) {
        found = asset;
      }
    }

    for (final asset in widget.assets) {
      if (identical(asset, widget.link)) continue;
      final box = asset.boxOn(widget.assets, widget.canvas) ??
          Rect.fromCenter(
            center: Offset(asset.coordinates.x, asset.coordinates.y),
            width: asset.size.width,
            height: asset.size.height,
          );
      test(asset, box);
      // A rack's slices are the devices a cable plugs into, and they sit on
      // top of the rack: tested after it, so dropping on a slice picks the
      // slice rather than the block it is part of.
      for (final child in asset.childAssets) {
        test(child, anchors.boxOf(child));
      }
    }
    return found;
  }

  /// The port on [asset] nearest to [at], so dropping an end on a device picks
  /// the socket the operator dragged towards rather than always the first.
  String? _nearestPort(Asset asset, Offset at) {
    final anchors = _anchors;
    String? best;
    var bestD = double.infinity;
    for (final p in portsOf(asset)) {
      final page = anchors.portOn(asset, p);
      final px =
          Offset(page.dx * widget.canvas.width, page.dy * widget.canvas.height);
      final d = (px - at).distance;
      if (d < bestD) {
        bestD = d;
        best = p.id;
      }
    }
    return best;
  }

  void _freeAt(LinkEnd end, Offset at) {
    end
      ..assetId = null
      ..port = null
      ..x = (at.dx / widget.canvas.width).clamp(0.0, 1.0)
      ..y = (at.dy / widget.canvas.height).clamp(0.0, 1.0);
  }

  /// Follows the pointer, and shows where letting go would plug in: the end
  /// sits on the snapped socket, but is not bound to it until the drop, so
  /// sweeping past a rack gives none of its slices an id.
  void _dragEnd(LinkEnd end, Offset at) {
    final snap = _portNear(at);
    _snap = snap;
    _freeAt(end, snap?.at ?? at);
    _changed();
  }

  void _dropEnd(LinkEnd end, Offset at) {
    final snap = _portNear(at);
    _snap = null;
    if (snap != null) {
      end
        ..assetId = snap.asset.ensureId()
        ..port = snap.port.id;
    } else {
      final target = _assetUnder(at);
      if (target == null) {
        // Dropped on empty canvas: unplug, and leave the end where it landed.
        _freeAt(end, at);
      } else {
        end
          ..assetId = target.ensureId()
          ..port = _nearestPort(target, at);
      }
    }
    _changed();
  }

  String _nameOf(String id) {
    final a = _anchors.assetFor(id);
    if (a == null) return id;
    return a.text?.isNotEmpty == true ? a.text! : a.displayName;
  }

  void _showCornerMenu(int index, Offset globalPosition) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final run = widget.link.run;
    final from = run.from.assetId;
    final to = run.to.assetId;
    final rule = LinkRun.ruleOf(run.waypoints[index]);

    showMenu<VoidCallback>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          value: () => _edit(() => run.waypoints.removeAt(index)),
          child: const Text('Delete point'),
        ),
        PopupMenuItem(
          value: () => _edit(run.waypoints.clear),
          child: const Text('Straighten run'),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<VoidCallback>(
          enabled: false,
          child: Text('This corner'),
        ),
        _ruleItem(index, LinkCornerRule.page, 'Stays where it is', rule),
        if (from != null)
          _ruleItem(index, LinkCornerRule.pinned(from),
              'Moves with ${_nameOf(from)}', rule),
        if (to != null && to != from)
          _ruleItem(index, LinkCornerRule.pinned(to),
              'Moves with ${_nameOf(to)}', rule),
        _ruleItem(index, LinkCornerRule.run, 'Follows both ends', rule),
      ],
    ).then((chosen) => chosen?.call());
  }

  PopupMenuItem<VoidCallback> _ruleItem(
      int index, LinkCornerRule rule, String label, LinkCornerRule current) {
    return PopupMenuItem(
      value: () =>
          _edit(() => widget.link.run.repin(index, rule, anchors: _anchors)),
      child: Row(
        children: [
          Icon(rule == current ? Icons.circle : Icons.circle_outlined,
              size: 10),
          const SizedBox(width: 8),
          Text(label),
        ],
      ),
    );
  }

  void _secondaryTap(Offset localPosition, Offset globalPosition) {
    final forward = widget.onSecondaryTap;
    if (forward != null) {
      forward(localPosition, globalPosition);
      return;
    }
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    showMenu<VoidCallback>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          value: () => _edit(() => widget.link.run.insertWaypoint(localPosition,
              canvas: widget.canvas, anchors: _anchors)),
          child: const Text('Add point here'),
        ),
      ],
    ).then((chosen) => chosen?.call());
  }

  Widget _endHandle(
      String name, LinkEnd end, Offset at, HmiStateColors states) {
    return _Handle(
      key: ValueKey('end-$name'),
      at: at,
      colour: states.blue,
      square: true,
      onStart: _begin,
      onMove: (global) => _dragEnd(end, _toLocal(global)),
      onDone: (global) {
        _dropEnd(end, _toLocal(global));
        _end();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final states = Theme.of(context).extension<HmiStateColors>() ??
        HmiStateColors.solarizedLight;
    final resolved = _resolved;
    final points = resolved.points;
    final run = widget.link.run;

    return Positioned.fill(
      child: Stack(
        key: _frame,
        clipBehavior: Clip.none,
        children: [
          // Every socket on the page, so there is something to aim an end at.
          // Under everything else and deaf to the pointer: it only marks.
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _PortMarkerPainter(
                  ports: [for (final s in _ports()) s.at],
                  snapped: _snap?.at,
                  snappedLabel: _snap == null
                      ? null
                      : [
                          _snap!.port.id,
                          if (_snap!.port.description != null)
                            _snap!.port.description!,
                        ].join(' · '),
                  colour: states.blue,
                  labelStyle: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            ),
          ),

          // The cable itself, as a target. It sits over the canvas, so it
          // answers everything the canvas would have: a double-click opens
          // the form, a right-click the menu, and a drag moves an unplugged
          // cable (a plugged one is placed by its devices).
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.deferToChild,
              onDoubleTap: widget.onConfigure,
              onSecondaryTapUp: (d) =>
                  _secondaryTap(d.localPosition, d.globalPosition),
              onPanStart: widget.link.isPluggedIn ? null : (_) => _begin(),
              onPanUpdate: widget.link.isPluggedIn
                  ? null
                  : (d) {
                      final c = widget.link.coordinates;
                      widget.link.coordinates = Coordinates(
                        x: c.x + d.delta.dx / widget.canvas.width,
                        y: c.y + d.delta.dy / widget.canvas.height,
                      );
                      _changed();
                    },
              onPanEnd: widget.link.isPluggedIn ? null : (_) => _end(),
              child: CustomPaint(
                painter: _CableTargetPainter(
                  resolved: resolved,
                  hitWidth: widget.link.hitWidthOn(widget.canvas),
                ),
              ),
            ),
          ),

          // Ghost midpoints: a corner that does not exist yet.
          for (var i = 0; i < points.length - 1; i++)
            if ((points[i] - points[i + 1]).distance >= _kMinGhostSegment)
              _Handle(
                key: ValueKey('ghost-$i'),
                at: (points[i] + points[i + 1]) / 2,
                colour: states.green,
                ghost: true,
                onStart: () {
                  _begin();
                  // Materialises on the first move, then it is an ordinary
                  // corner at index i.
                  final mid = (points[i] + points[i + 1]) / 2;
                  run.waypoints.insert(
                    i,
                    LinkWaypoint.onPage(mid.dx / widget.canvas.width,
                        mid.dy / widget.canvas.height),
                  );
                },
                onMove: (global) {
                  run.moveWaypoint(i, _toLocal(global),
                      canvas: widget.canvas, anchors: _anchors);
                  _changed();
                },
                onDone: (_) => _end(),
                // A ghost sits in the middle of its segment, which is exactly
                // where somebody right-clicks the cable. Without this it
                // would swallow that click and offer nothing.
                onSecondaryTap: (global) =>
                    _secondaryTap(_toLocal(global), global),
              ),

          // A handle per corner.
          for (var j = 0; j < run.waypoints.length; j++)
            _Handle(
              key: ValueKey('corner-$j'),
              at: points[j + 1],
              colour: run.waypoints[j].isPinned ? states.yellow : states.green,
              onStart: _begin,
              onMove: (global) {
                run.moveWaypoint(j, _toLocal(global),
                    canvas: widget.canvas, anchors: _anchors);
                _changed();
              },
              onDone: (_) {
                // Dropped on a neighbour: the corner is gone.
                final now = _resolved.points;
                final tooClose =
                    (now[j + 1] - now[j]).distance < _kMergeDistance ||
                        (now[j + 1] - now[j + 2]).distance < _kMergeDistance;
                if (tooClose) run.waypoints.removeAt(j);
                _changed();
                _end();
              },
              onSecondaryTap: (global) => _showCornerMenu(j, global),
            ),

          // The two ends. Square, because they are a different kind of thing
          // from a corner: they belong to a device, not to the cable. Last,
          // so an end is on top where it and a corner overlap.
          _endHandle('from', run.from, points.first, states),
          _endHandle('to', run.to, points.last, states),
        ],
      ),
    );
  }
}

/// One draggable dot.
///
/// Every handle is keyed. Ghosts come and go as segments grow past
/// [_kMinGhostSegment] mid-drag, and without keys the framework re-paired the
/// live handle under the pointer with whichever widget now sat at its index:
/// dragging an end would hand the gesture to a corner, which then leapt to the
/// pointer.
class _Handle extends StatefulWidget {
  const _Handle({
    super.key,
    required this.at,
    required this.colour,
    required this.onStart,
    required this.onMove,
    required this.onDone,
    this.ghost = false,
    this.square = false,
    this.onSecondaryTap,
  });

  final Offset at;
  final Color colour;
  final bool ghost;
  final bool square;
  final VoidCallback onStart;

  /// Both carry a *global* position; the overlay converts. Reading
  /// `box.parent` instead looked right and was not — the immediate render
  /// parent of a Positioned is whatever proxy the framework put there, not
  /// the Stack, so a drop landed in the wrong coordinate space and plugged
  /// the cable into whichever device happened to sit under the wrong point.
  final void Function(Offset globalPosition) onMove;
  final void Function(Offset globalPosition) onDone;
  final void Function(Offset globalPosition)? onSecondaryTap;

  @override
  State<_Handle> createState() => _HandleState();
}

class _HandleState extends State<_Handle> {
  /// Where the pointer was last. `onPanEnd` carries no position of its own,
  /// and by then the handle has already moved out from under the finger.
  Offset? _last;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: widget.at.dx - _kHandleGrab / 2,
      top: widget.at.dy - _kHandleGrab / 2,
      width: _kHandleGrab,
      height: _kHandleGrab,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (d) {
          _last = d.globalPosition;
          widget.onStart();
        },
        onPanUpdate: (d) {
          _last = d.globalPosition;
          widget.onMove(d.globalPosition);
        },
        onPanEnd: (_) {
          final at = _last;
          if (at != null) widget.onDone(at);
        },
        onSecondaryTapUp: widget.onSecondaryTap == null
            ? null
            : (d) => widget.onSecondaryTap!(d.globalPosition),
        child: Center(
          child: Container(
            width: _kHandleRadius * 2,
            height: _kHandleRadius * 2,
            decoration: BoxDecoration(
              shape: widget.square ? BoxShape.rectangle : BoxShape.circle,
              color: widget.ghost ? Colors.transparent : widget.colour,
              border: Border.all(
                color: widget.ghost ? widget.colour : Colors.white,
                width: widget.ghost ? 1.5 : 1.6,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The sockets a cable end can go to: a faint ring on each, and the one a
/// dragged end has snapped to filled, haloed and named.
class _PortMarkerPainter extends CustomPainter {
  _PortMarkerPainter({
    required this.ports,
    required this.snapped,
    required this.snappedLabel,
    required this.colour,
    required this.labelStyle,
  });

  final List<Offset> ports;
  final Offset? snapped;
  final String? snappedLabel;
  final Color colour;
  final TextStyle? labelStyle;

  static const double _ring = 5;

  @override
  void paint(Canvas canvas, Size size) {
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = colour.withValues(alpha: 0.55);
    final fill = Paint()..color = colour.withValues(alpha: 0.12);
    for (final p in ports) {
      canvas.drawCircle(p, _ring, fill);
      canvas.drawCircle(p, _ring, ring);
    }

    final s = snapped;
    if (s == null) return;
    canvas.drawCircle(s, 13, Paint()..color = colour.withValues(alpha: 0.22));
    canvas.drawCircle(s, 6, Paint()..color = colour);
    canvas.drawCircle(
        s,
        6,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = Colors.white);

    final label = snappedLabel;
    if (label == null) return;
    final tp = TextPainter(
      text: TextSpan(
          text: label,
          style: (labelStyle ?? const TextStyle(fontSize: 11))
              .copyWith(color: Colors.white)),
      textDirection: TextDirection.ltr,
    )..layout();
    // Above and to the right of the socket, clear of the halo and the finger.
    final box = Rect.fromLTWH(
        s.dx + 14, s.dy - 14 - tp.height - 4, tp.width + 10, tp.height + 4);
    canvas.drawRRect(RRect.fromRectAndRadius(box, const Radius.circular(4)),
        Paint()..color = colour);
    tp.paint(canvas, box.topLeft + const Offset(5, 2));
  }

  @override
  bool shouldRepaint(_PortMarkerPainter old) =>
      old.snapped != snapped ||
      old.snappedLabel != snappedLabel ||
      old.colour != colour ||
      old.ports.length != ports.length ||
      !_samePoints(old.ports, ports);

  static bool _samePoints(List<Offset> a, List<Offset> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Nothing visible — its only job is to answer hit tests along the cable, so a
/// click on the run reaches the overlay instead of falling to the canvas
/// underneath.
class _CableTargetPainter extends CustomPainter {
  _CableTargetPainter({required this.resolved, required this.hitWidth});

  final ResolvedLink resolved;
  final double hitWidth;

  @override
  void paint(Canvas canvas, Size size) {}

  @override
  bool hitTest(Offset position) =>
      resolved.distanceTo(position) <= math.max(hitWidth, _kCableTarget) / 2;

  @override
  bool shouldRepaint(_CableTargetPainter old) =>
      old.hitWidth != hitWidth || old.resolved != resolved;
}

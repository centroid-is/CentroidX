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
///  - **A corner follows something**, and the right-click menu is where that
///    is chosen — the run by default, or one device when the truthful model is
///    a tray the cable leaves at a fixed point.
///  - **Ends are ports.** Dragging an end onto a device plugs it in there;
///    dragging it onto empty canvas unplugs it and leaves it where it was
///    dropped.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme.dart' show HmiStateColors;
import 'common.dart';
import 'ethercat_link.dart';
import 'link_anchors.dart';
import 'link_geometry.dart';

/// Radius of a corner handle, in logical pixels.
const double _kHandleRadius = 7;

/// How close a dropped corner has to come to a neighbour to collapse into it.
const double _kMergeDistance = 14;

/// Shortest segment that still earns a ghost. Below this the ghost would sit
/// on top of the handles at either end and be impossible to grab.
const double _kMinGhostSegment = 44;

class LinkEditOverlay extends StatefulWidget {
  const LinkEditOverlay({
    super.key,
    required this.link,
    required this.assets,
    required this.canvas,
    required this.onChanged,
    required this.onBeginEdit,
  });

  final EtherCatLinkConfig link;

  /// The whole page, for resolving the run and for finding what an end was
  /// dropped onto.
  final List<Asset> assets;
  final Size canvas;

  /// Called after any edit, so the editor can re-encode and repaint.
  final VoidCallback onChanged;

  /// Called once at the start of a gesture, so one drag is one undo step
  /// rather than one per pointer move.
  final VoidCallback onBeginEdit;

  @override
  State<LinkEditOverlay> createState() => _LinkEditOverlayState();
}

class _LinkEditOverlayState extends State<LinkEditOverlay> {
  LinkAnchors get _anchors => PageLinkAnchors(widget.assets, widget.canvas);

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

  void _begin() {
    if (_editing) return;
    _editing = true;
    widget.onBeginEdit();
  }

  void _end() => _editing = false;

  void _changed() {
    widget.onChanged();
    setState(() {});
  }

  /// The asset under [at], ignoring the cable itself.
  ///
  /// Last match wins: the page paints in list order, so the last asset whose
  /// box contains the point is the one drawn on top and the one the operator
  /// thinks they dropped onto.
  Asset? _assetUnder(Offset at) {
    final anchors = PageLinkAnchors(widget.assets, widget.canvas);
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
    final anchors = PageLinkAnchors(widget.assets, widget.canvas);
    String? best;
    var bestD = double.infinity;
    for (final p in portsOf(asset)) {
      final page = anchors.portPosition(asset.ensureId(), p.id);
      if (page == null) continue;
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

  void _dropEnd(LinkEnd end, Offset at) {
    final target = _assetUnder(at);
    if (target == null) {
      // Dropped on empty canvas: unplug, and leave the end where it landed.
      end.assetId = null;
      end.port = null;
      end.x = (at.dx / widget.canvas.width).clamp(0.0, 1.0);
      end.y = (at.dy / widget.canvas.height).clamp(0.0, 1.0);
    } else {
      end.assetId = target.ensureId();
      end.port = _nearestPort(target, at);
    }
    _changed();
  }

  void _showCornerMenu(int index, Offset globalPosition) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final from = widget.link.run.from.assetId;
    final to = widget.link.run.to.assetId;
    final pinned = widget.link.run.waypoints[index].pinnedTo;

    String nameOf(String id) {
      for (final a in widget.assets) {
        if (a.id == id) {
          return a.text?.isNotEmpty == true ? a.text! : a.displayName;
        }
      }
      return id;
    }

    showMenu<VoidCallback>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          value: () {
            _begin();
            widget.link.run.waypoints.removeAt(index);
            _end();
            _changed();
          },
          child: const Text('Delete point'),
        ),
        PopupMenuItem(
          value: () {
            _begin();
            widget.link.run.waypoints.clear();
            _end();
            _changed();
          },
          child: const Text('Straighten run'),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<VoidCallback>(
          enabled: false,
          child: Text('This corner follows'),
        ),
        _followItem(index, null, 'The run (both ends)', pinned == null),
        if (from != null)
          _followItem(index, from, nameOf(from), pinned == from),
        if (to != null) _followItem(index, to, nameOf(to), pinned == to),
      ],
    ).then((chosen) => chosen?.call());
  }

  PopupMenuItem<VoidCallback> _followItem(
      int index, String? pin, String label, bool selected) {
    return PopupMenuItem(
      value: () {
        _begin();
        widget.link.run.repin(index, pin, anchors: _anchors);
        _end();
        _changed();
      },
      child: Row(
        children: [
          Icon(selected ? Icons.circle : Icons.circle_outlined, size: 10),
          const SizedBox(width: 8),
          Text(label),
        ],
      ),
    );
  }

  void _showCableMenu(Offset localPosition, Offset globalPosition) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    showMenu<VoidCallback>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          value: () {
            _begin();
            widget.link.run.insertWaypoint(localPosition,
                canvas: widget.canvas, anchors: _anchors);
            _end();
            _changed();
          },
          child: const Text('Add point here'),
        ),
      ],
    ).then((chosen) => chosen?.call());
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
          // Right-clicking the cable itself adds a corner there. A wide
          // invisible stroke, because the ink is far too thin to aim at.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.deferToChild,
              onSecondaryTapUp: (d) =>
                  _showCableMenu(d.localPosition, d.globalPosition),
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
                at: (points[i] + points[i + 1]) / 2,
                colour: states.green,
                ghost: true,
                onStart: () {
                  _begin();
                  // Materialises on the first move, then it is an ordinary
                  // corner at index i.
                  run.waypoints.insert(
                    i,
                    _describeAt((points[i] + points[i + 1]) / 2),
                  );
                },
                onMove: (global) {
                  run.moveWaypoint(i, _toLocal(global),
                      canvas: widget.canvas, anchors: _anchors);
                  _changed();
                },
                onDone: (_) => _end(),
                // A ghost sits in the middle of its segment, which is exactly
                // where somebody right-clicks to add a point. Without this it
                // would swallow that click and offer nothing.
                onSecondaryTap: (global) =>
                    _showCableMenu(_toLocal(global), global),
              ),

          // A handle per corner.
          for (var j = 0; j < run.waypoints.length; j++)
            _Handle(
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
                _end();
                _changed();
              },
              onSecondaryTap: (global) => _showCornerMenu(j, global),
            ),

          // The two ends. Square, because they are a different kind of thing
          // from a corner: they belong to a device, not to the cable.
          _Handle(
            at: points.first,
            colour: states.blue,
            square: true,
            onStart: _begin,
            onMove: (global) {
              final at = _toLocal(global);
              run.from
                ..assetId = null
                ..x = (at.dx / widget.canvas.width).clamp(0.0, 1.0)
                ..y = (at.dy / widget.canvas.height).clamp(0.0, 1.0);
              _changed();
            },
            onDone: (global) {
              _dropEnd(run.from, _toLocal(global));
              _end();
            },
          ),
          _Handle(
            at: points.last,
            colour: states.blue,
            square: true,
            onStart: _begin,
            onMove: (global) {
              final at = _toLocal(global);
              run.to
                ..assetId = null
                ..x = (at.dx / widget.canvas.width).clamp(0.0, 1.0)
                ..y = (at.dy / widget.canvas.height).clamp(0.0, 1.0);
              _changed();
            },
            onDone: (global) {
              _dropEnd(run.to, _toLocal(global));
              _end();
            },
          ),
        ],
      ),
    );
  }

  /// A fresh corner at [canvasPoint], following the run.
  ///
  /// New corners are never pinned: pinning is the escape hatch, chosen
  /// deliberately from the menu, not something a drag should decide.
  LinkWaypoint _describeAt(Offset canvasPoint) {
    final frame = widget.link.run.frameIn(_anchors);
    final l = frame.locate(Offset(canvasPoint.dx / widget.canvas.width,
        canvasPoint.dy / widget.canvas.height));
    return LinkWaypoint.onRun(l.t, l.n);
  }
}

/// One draggable dot.
class _Handle extends StatefulWidget {
  const _Handle({
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
    const grab = _kHandleRadius * 2 + 10; // finger-sized, not ink-sized
    return Positioned(
      left: widget.at.dx - grab / 2,
      top: widget.at.dy - grab / 2,
      width: grab,
      height: grab,
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

/// Nothing visible — its only job is to answer hit tests along the cable, so a
/// right-click on the run reaches the overlay's menu instead of falling to the
/// canvas underneath.
class _CableTargetPainter extends CustomPainter {
  _CableTargetPainter({required this.resolved, required this.hitWidth});

  final ResolvedLink resolved;
  final double hitWidth;

  @override
  void paint(Canvas canvas, Size size) {}

  @override
  bool hitTest(Offset position) =>
      resolved.distanceTo(position) <= math.max(hitWidth, 18) / 2;

  @override
  bool shouldRepaint(_CableTargetPainter old) =>
      old.hitWidth != hitWidth || old.resolved != resolved;
}

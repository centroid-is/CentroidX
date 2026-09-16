/// The stations a pallet wagon serves, drawn where they are: beside its rail.
///
/// A rails conveyor already shows where the wagon is. What it could not show
/// is *why* it is there — which station asked for a pallet, which one has the
/// interlock the wagon is waiting on. The PLC's `FB_Wagon` knows, and publishes
/// every station's handshake, its side of the track and its distance along it.
/// So each station becomes a dock standing against the rail at that distance,
/// on that side, coloured by what it is doing, with its name beyond it.
///
/// Three facts from `FB_Wagon` decide the whole drawing:
///
///  - **Position.** A dock is placed by the same 0..1 fraction the wagon is,
///    measured against the same rail length ([wagonRailLength]). A wagon
///    parked at a station therefore sits *on* its dock, not near it.
///  - **Side.** `etLoc` says whether a station is in front of the wagon or
///    behind it, meaning the end its rollers run *towards* when they run
///    forward. That is a direction the conveyor already draws, so the front
///    edge follows the belt: below the track, or above it when the belt is
///    reversed.
///  - **Role.** `etType` says which way the pallet goes. A source's chevron
///    points at the rail, a destination's away from it.
///
/// The geometry here is pure — sizes in, rects out — so the painter that
/// draws a dock and the gesture that opens its pane read the same rect.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme.dart' show HmiStateColors;
import '../../widgets/panes/pane_chrome.dart';
import 'led.dart' show LEDPainter, LEDType;
import 'wagon_station.dart';

/// Which edge of the rail band a dock stands against, in the painter's frame
/// (before the asset's rotation or the page mirror).
enum WagonDockEdge { top, bottom }

/// One station, placed.
@immutable
class WagonDock {
  const WagonDock({
    required this.station,
    required this.edge,
    required this.body,
    required this.label,
  });

  final WagonStation station;
  final WagonDockEdge edge;

  /// The dock itself, touching the rail band — the tap target.
  final Rect body;

  /// Where the name goes: beyond the dock, away from the rail.
  final Rect label;
}

/// How the box of a rails conveyor with stations is shared out.
abstract final class WagonDockGeometry {
  /// Fraction of the box height given to the docks on *each* side of the
  /// track. Both sides are reserved whenever stations are bound, not only the
  /// sides that happen to have stations right now: the layout is decided by
  /// the configuration, never by the data, so a stream that drops out or a
  /// station that is disabled moves nothing else on the page.
  static const bandFraction = 0.3;

  /// Share of a side band the dock body takes; the name gets the rest.
  static const bodyFraction = 0.45;

  /// The track, wagon and belt's strip down the middle of the box.
  static Rect railBand(Size size) => Rect.fromLTWH(
      0, size.height * bandFraction, size.width, size.height * (1 - 2 * bandFraction));

  /// A dock is never wider than the wagon's belt — it is the end of the lane
  /// the belt hands a pallet across — and never so wide that it runs into its
  /// neighbour on the same side.
  static const _neighbourShare = 0.85;

  /// Places [stations] beside the rail band of a box of [size].
  ///
  /// [centreXAt] maps a rail fraction to the x the wagon's belt is centred at
  /// when parked there, and [laneWidth] is that belt's width: both come from
  /// the painter, so a dock and a parked wagon are placed by one function.
  /// [frontOnBottom] says which edge a station in front of the wagon takes.
  static List<WagonDock> layout({
    required Size size,
    required List<WagonStation> stations,
    required double railLength,
    required double Function(double fraction) centreXAt,
    required double laneWidth,
    required bool frontOnBottom,
  }) {
    if (stations.isEmpty || size.isEmpty) return const [];
    final rail = railBand(size);
    final band = rail.top;
    final bodyH = band * bodyFraction;

    WagonDockEdge edgeOf(WagonStation s) =>
        (s.side == WagonStationSide.inFront) == frontOnBottom
            ? WagonDockEdge.bottom
            : WagonDockEdge.top;

    final placed = [
      for (final s in stations)
        (station: s, edge: edgeOf(s), x: centreXAt(s.railFraction(railLength)))
    ];

    final docks = <WagonDock>[];
    for (final p in placed) {
      // Spacing to the nearest neighbour on the same side; the other side's
      // docks cannot collide with this one.
      var gap = double.infinity;
      for (final q in placed) {
        if (identical(p, q) || q.edge != p.edge) continue;
        final d = (q.x - p.x).abs();
        // Two stations on one spot, one side: they share the room evenly
        // rather than vanishing into zero width.
        gap = math.min(gap, d < 1 ? laneWidth : d);
      }
      final bodyW = math.max(math.min(laneWidth, gap * _neighbourShare), 4.0);
      // A name is centred under its own dock. Half a neighbour gap each way
      // keeps it off the next name; the box edge bounds it too, so a station
      // at the end of the rail keeps its name over it instead of having the
      // name slid along to somewhere between it and the next one.
      final double toEdge = 2 * math.min(p.x, size.width - p.x);
      final double labelW =
          math.max(math.min(math.min(gap * 0.95, toEdge), size.width), bodyW);
      final bodyTop =
          p.edge == WagonDockEdge.top ? rail.top - bodyH : rail.bottom;
      final labelTop = p.edge == WagonDockEdge.top ? 0.0 : rail.bottom + bodyH;
      docks.add(WagonDock(
        station: p.station,
        edge: p.edge,
        body: Rect.fromLTWH(p.x - bodyW / 2, bodyTop, bodyW, bodyH),
        label: _keepInside(
            Rect.fromLTWH(p.x - labelW / 2, labelTop, labelW, band - bodyH),
            size.width),
      ));
    }
    return docks;
  }

  /// Slides [r] sideways until it is inside `0..width`: a name at the rail's
  /// end reads off-centre rather than off the asset.
  static Rect _keepInside(Rect r, double width) {
    if (r.left < 0) return r.shift(Offset(-r.left, 0));
    if (r.right > width) return r.shift(Offset(width - r.right, 0));
    return r;
  }
}

/// The colours a dock is painted in, resolved from the theme by the widget —
/// the painter has no context.
@immutable
class WagonDockPalette {
  const WagonDockPalette({
    required this.go,
    required this.wait,
    required this.idle,
    required this.ink,
    required this.labelStyle,
  });

  factory WagonDockPalette.of(BuildContext context) {
    final states = HmiStateColors.of(context);
    final theme = Theme.of(context);
    return WagonDockPalette(
      go: states.green,
      wait: states.yellow,
      idle: states.grey,
      ink: theme.colorScheme.onSurface,
      labelStyle: (theme.textTheme.labelSmall ?? const TextStyle())
          .copyWith(color: theme.colorScheme.onSurface),
    );
  }

  /// "Yes, now": ready, delivering. The house green.
  final Color go;

  /// Waiting on something: an interlock. The house yellow — a blocked station
  /// is not a fault, and red stays reserved for the ones that are.
  final Color wait;

  /// Nothing going on.
  final Color idle;

  /// The page's foreground, for the wagon-here bar and the names.
  final Color ink;

  final TextStyle labelStyle;

  /// What a dock in [state] is filled with.
  ///
  /// Asking is filled idle and *outlined* green (see [outlineFor]): the
  /// station wants something, but nothing is permitted yet, so it must not
  /// read the same as ready.
  Color fillFor(WagonStationState state) => switch (state) {
        WagonStationState.blocked => wait,
        WagonStationState.delivering || WagonStationState.ready => go,
        WagonStationState.asking || WagonStationState.idle => idle,
      };

  /// The dock's border colour; only an asking dock's is not black.
  Color outlineFor(WagonStationState state) =>
      state == WagonStationState.asking ? go : Colors.black;

  @override
  bool operator ==(Object other) =>
      other is WagonDockPalette &&
      other.go == go &&
      other.wait == wait &&
      other.idle == idle &&
      other.ink == ink &&
      other.labelStyle == labelStyle;

  @override
  int get hashCode => Object.hash(go, wait, idle, ink, labelStyle);
}

/// Paints [docks] onto a canvas in the box's own frame.
///
/// [angle] (degrees) and the mirror flags are the asset's, so each name can be
/// turned back upright around its own centre the way the belt's frequency
/// figure is.
void paintWagonDocks(
  Canvas canvas,
  List<WagonDock> docks,
  WagonDockPalette palette, {
  double angle = 0,
  bool mirrorX = false,
  bool mirrorY = false,
}) {
  for (final dock in docks) {
    final state = dock.station.state;
    final body = dock.body;
    final radius = Radius.circular(math.min(body.shortestSide * 0.18, 4));
    final rrect = RRect.fromRectAndRadius(body, radius);
    canvas.drawRRect(rrect, Paint()..color = palette.fillFor(state));
    final asking = state == WagonStationState.asking;
    canvas.drawRRect(
        asking ? rrect.deflate(1) : rrect,
        Paint()
          ..color = palette.outlineFor(state)
          ..style = PaintingStyle.stroke
          ..strokeWidth = asking ? 2.5 : 1.2);

    _paintChevron(canvas, dock, delivering: state == WagonStationState.delivering);

    // The wagon is at this station by its own sensor, not by the dead-reckoned
    // position: a bar across the dock's rail edge, which says "docked" in a
    // way that survives the wagon being drawn a little off it.
    if (dock.station.atStation) {
      final bar = math.max(body.height * 0.28, 3.0);
      final strip = dock.edge == WagonDockEdge.top
          ? Rect.fromLTRB(body.left, body.bottom - bar, body.right, body.bottom)
          : Rect.fromLTRB(body.left, body.top, body.right, body.top + bar);
      canvas.drawRect(strip, Paint()..color = Colors.black.withValues(alpha: 0.8));
    }

    _paintName(canvas, dock, palette, angle: angle, mirrorX: mirrorX, mirrorY: mirrorY);
  }
}

/// Which way the pallet moves: at the rail for a source, away from it for a
/// destination. Bold while the station's rollers are released to run.
void _paintChevron(Canvas canvas, WagonDock dock, {required bool delivering}) {
  final body = dock.body;
  final size = math.min(body.width * 0.5, body.height * 0.55);
  if (size < 4) return;
  final towardRail = dock.station.role == WagonStationRole.source;
  // +1 points down the screen.
  final down = (dock.edge == WagonDockEdge.top) == towardRail ? 1.0 : -1.0;
  final c = body.center;
  final half = size / 2;
  final path = Path()
    ..moveTo(c.dx - half, c.dy - down * half * 0.45)
    ..lineTo(c.dx, c.dy + down * half * 0.45)
    ..lineTo(c.dx + half, c.dy - down * half * 0.45);
  canvas.drawPath(
      path,
      Paint()
        ..color = Colors.black.withValues(alpha: delivering ? 0.9 : 0.45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = delivering ? math.max(size * 0.2, 2) : math.max(size * 0.12, 1.2)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round);
}

void _paintName(
  Canvas canvas,
  WagonDock dock,
  WagonDockPalette palette, {
  required double angle,
  required bool mirrorX,
  required bool mirrorY,
}) {
  final area = dock.label;
  if (area.height < 6 || area.width < 12) return;
  final fontSize = math.min(area.height * 0.75, 13.0);
  final text = TextPainter(
    text: TextSpan(
      text: dock.station.name,
      style: palette.labelStyle.copyWith(fontSize: fontSize, height: 1.0),
    ),
    textAlign: TextAlign.center,
    textDirection: TextDirection.ltr,
    maxLines: 1,
    ellipsis: '…',
  )..layout(maxWidth: area.width);
  canvas.save();
  canvas.translate(area.center.dx, area.center.dy);
  canvas.rotate(-angle * math.pi / 180);
  if (mirrorX || mirrorY) {
    canvas.scale(mirrorX ? -1.0 : 1.0, mirrorY ? -1.0 : 1.0);
  }
  text.paint(canvas, Offset(-text.width / 2, -text.height / 2));
  canvas.restore();
}

/// The header chip a station's pane shows, in the same colours as its dock.
PaneStatus wagonStationPaneStatus(BuildContext context, WagonStationState state) {
  final states = HmiStateColors.of(context);
  return switch (state) {
    WagonStationState.blocked =>
      PaneStatus(label: state.label, color: states.yellow, icon: Icons.block),
    WagonStationState.delivering => PaneStatus(
        label: state.label, color: states.green, icon: Icons.play_circle_fill),
    WagonStationState.ready => PaneStatus(
        label: state.label, color: states.green, icon: Icons.check_circle),
    WagonStationState.asking => PaneStatus(
        label: state.label, color: states.green, icon: Icons.radio_button_unchecked),
    WagonStationState.idle => PaneStatus(
        label: state.label, color: states.grey, icon: Icons.pause_circle_filled),
  };
}

/// One line of a station's handshake: a sentence and whether it holds.
typedef WagonHandshakeBit = ({String label, bool on, bool isWait});

/// The station's handshake as sentences an operator reads, in the order the
/// exchange happens.
///
/// `ST_WagonStation`'s members mean different things for the two roles — the
/// PLC's own comments say so member by member — so the words come from the
/// role. The completion flag the other role never sets is left out rather
/// than shown as a lamp that is always dark.
List<WagonHandshakeBit> wagonStationHandshake(WagonStation s) {
  final source = s.role == WagonStationRole.source;
  return [
    (label: 'Wagon at station', on: s.atStation, isWait: false),
    (
      label: source ? 'Has a pallet to send' : 'Needs a pallet',
      on: s.order,
      isWait: false
    ),
    (
      label: source ? 'Pallet ready' : 'Ready to receive',
      on: s.ready,
      isWait: false
    ),
    (
      label: source
          ? 'May feed the pallet onto the wagon'
          : 'May run its rollers',
      on: s.outfeed,
      isWait: false
    ),
    if (source)
      (label: 'Pallet taken onto the wagon', on: s.outfeedComplete, isWait: false)
    else
      (label: 'Has the pallet', on: s.deliveryComplete, isWait: false),
    (label: 'Wagon may not travel here', on: s.interlock, isWait: true),
    (
      label: 'Wagon waiting for the interlock',
      on: s.waitingForInterlock,
      isWait: true
    ),
  ];
}

/// The body of a station's side pane: what the station is, then its
/// handshake as lamps.
class WagonStationPaneBody extends StatelessWidget {
  const WagonStationPaneBody({super.key, required this.station});

  final WagonStation station;

  @override
  Widget build(BuildContext context) {
    final states = HmiStateColors.of(context);
    return PaneBody(
      sections: [
        PaneBodySection.status(
          title: 'Handshake',
          child: Column(
            children: [
              for (final bit in wagonStationHandshake(station))
                PaneDetailRow(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  label: bit.label,
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CustomPaint(
                      painter: LEDPainter(
                        color: bit.on
                            ? (bit.isWait ? states.yellow : states.green)
                            : Colors.white,
                        ledType: LEDType.circle,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        PaneBodySection.details(
          title: 'Station',
          child: Column(
            children: [
              PaneDetailRow(label: 'Role', value: station.role.label),
              PaneDetailRow(
                label: 'Side',
                value: station.side == WagonStationSide.inFront
                    ? 'In front of the wagon'
                    : 'Behind the wagon',
              ),
              PaneDetailRow(
                  label: 'Along the rail', value: station.positionLabel),
            ],
          ),
        ),
      ],
    );
  }
}

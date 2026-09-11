/// Resolving the assets a run is plugged into, into the positions it needs.
///
/// [LinkRun] deliberately knows nothing about assets — it asks a [LinkAnchors]
/// where things are and gets page-relative points back. This is the
/// implementation of that interface for a real page: a lookup over the asset
/// list by [Asset.id], plus the small amount of geometry that turns "port X2
/// on the EK1100" into a point on the edge of that asset's box.
library;

import 'dart:math' as math;
import 'package:flutter/widgets.dart'
    show BuildContext, InheritedWidget, Offset, Size;

import 'common.dart';
import 'link_geometry.dart';

/// Which edge of an asset's box a port sits on.
enum PortSide { left, right, top, bottom }

/// One network socket on an asset, in the terms the asset's glyph is drawn in.
///
/// [at] is the fraction along [side], measured left-to-right or top-to-bottom,
/// so a terminal with two sockets stacked on its right face gives them the
/// same side and different [at].
class NetworkPort {
  /// What the operator sees on the label — `'X1'`, `'X2'`.
  final String id;
  final PortSide side;
  final double at;

  /// What the port is for, shown when picking one. EtherCAT is a chain, so
  /// this is nearly always "in" or "out" and worth saying.
  final String? description;

  /// Other names a stored cable end may carry for this port — the implicit
  /// `X1`/`X2` of a device that has since declared its real sockets. Resolved
  /// by [findPort]; a stored end is never rewritten to match.
  final List<String> aliases;

  const NetworkPort(
    this.id,
    this.side, {
    this.at = 0.5,
    this.description,
    this.aliases = const [],
  });
}

/// An asset that a cable can plug into.
///
/// Implemented by the device assets that actually have sockets. Anything that
/// does not implement it still accepts a cable — see [kImplicitPorts] — so a
/// run can be drawn between any two things on a page without 40 assets having
/// to be edited first.
abstract class NetworkPorted {
  List<NetworkPort> get networkPorts;
}

/// The ports assumed for an asset that declares none.
///
/// An EtherCAT device is a chain link: one socket the frame comes in on and
/// one it leaves by, conventionally X1 and X2 on Beckhoff hardware, on
/// opposite faces. Assuming that shape means a cable is drawable against any
/// asset on day one, and a device that declares its real ports later simply
/// overrides it.
const List<NetworkPort> kImplicitPorts = [
  NetworkPort('X1', PortSide.left, description: 'EtherCAT in'),
  NetworkPort('X2', PortSide.right, description: 'EtherCAT out'),
];

/// The four ports every EtherCAT subdevice controller has, named as the PLC and
/// TwinCAT name them: A in on the left, B out on the right, and the two
/// junction ports below and above so a branch leaves the chain at a right
/// angle. The fallback for an EtherCAT device that declares nothing better.
const List<NetworkPort> kEcSubDevicePorts = [
  NetworkPort('A', PortSide.left, description: 'In', aliases: ['X1']),
  NetworkPort('B', PortSide.right, description: 'Out', aliases: ['X2']),
  NetworkPort('C', PortSide.bottom, description: 'Branch'),
  NetworkPort('D', PortSide.top, description: 'Branch'),
];

/// The port of [ports] that [id] names: by id first, then by alias.
///
/// Per device, not a global rename: `X2` is B on a terminal and C on an
/// EK1100, and only the device knows which.
NetworkPort? findPort(List<NetworkPort> ports, String? id) {
  if (id == null) return null;
  for (final p in ports) {
    if (p.id == id) return p;
  }
  for (final p in ports) {
    if (p.aliases.contains(id)) return p;
  }
  return null;
}

/// The ports [asset] offers, declared or assumed.
List<NetworkPort> portsOf(Asset asset) {
  // Explicit cast: `Asset` and `NetworkPorted` are unrelated declarations, so
  // there is no promotion to lean on here.
  if (asset is NetworkPorted) return (asset as NetworkPorted).networkPorts;
  return kImplicitPorts;
}

/// [LinkAnchors] over a page's asset list.
///
/// Answers in page-relative 0..1 space taken from each asset's *stored*
/// coordinates, never from a laid-out rectangle — see [LinkAnchors] for why
/// that matters to mirroring. [canvas] is needed only to rotate a port around
/// a turned asset: page space is anisotropic on any canvas that is not square,
/// so a rotation done in it would shear rather than turn.
class PageLinkAnchors implements LinkAnchors {
  PageLinkAnchors(Iterable<Asset> assets, this.canvas)
      : _byId = {
          for (final a in assets)
            if (a.id != null) a.id!: a,
        };

  final Map<String, Asset> _byId;
  final Size canvas;

  /// The asset [id] names, or null if the page has no such asset.
  Asset? assetFor(String id) => _byId[id];

  @override
  Offset? portPosition(String assetId, String? port) {
    final asset = _byId[assetId];
    if (asset == null) return null;

    final ports = portsOf(asset);
    // An unnamed port, or one this device does not have (its glyph changed
    // under a cable that was already drawn), lands on the box centre rather
    // than nowhere: a cable to the middle of the device reads as "plugged in
    // somewhere on this box", which is true and fixable, where a vanished end
    // reads as a bug.
    final spec = findPort(ports, port);
    if (spec == null) return _centre(asset);

    final w = asset.size.width, h = asset.size.height;
    final local = switch (spec.side) {
      PortSide.left => Offset(-w / 2, -h / 2 + h * spec.at),
      PortSide.right => Offset(w / 2, -h / 2 + h * spec.at),
      PortSide.top => Offset(-w / 2 + w * spec.at, -h / 2),
      PortSide.bottom => Offset(-w / 2 + w * spec.at, h / 2),
    };
    return _centre(asset) + _rotate(local, asset.coordinates.angle);
  }

  /// The asset's centre, which is what a pinned corner is an offset from.
  ///
  /// The centre and not a corner of the box: a box corner is only
  /// well-defined while the asset is unrotated, and the centre is the point
  /// `AssetStack` positions the asset by anyway.
  ///
  /// The offset itself does not rotate with the asset. A pin exists to nail a
  /// corner to a fixed place in the hall — where the cable enters a tray —
  /// and turning a terminal's glyph on the mimic does not move the tray.
  @override
  Offset? assetAnchor(String assetId) {
    final asset = _byId[assetId];
    return asset == null ? null : _centre(asset);
  }

  static Offset _centre(Asset a) => Offset(a.coordinates.x, a.coordinates.y);

  /// Rotates a page-space offset about the origin by [angleDegrees].
  ///
  /// Via pixels and back. Page space stretches x and y independently, so
  /// rotating in it turns a square into a sheared parallelogram — the port
  /// would drift off the corner of the glyph it is drawn on by more the
  /// further the canvas is from square.
  Offset _rotate(Offset local, double? angleDegrees) {
    if (angleDegrees == null || angleDegrees == 0) return local;
    if (canvas.width == 0 || canvas.height == 0) return local;
    final r = angleDegrees * math.pi / 180;
    final px = local.dx * canvas.width, py = local.dy * canvas.height;
    final rx = px * math.cos(r) - py * math.sin(r);
    final ry = px * math.sin(r) + py * math.cos(r);
    return Offset(rx / canvas.width, ry / canvas.height);
  }
}

/// Publishes the page an asset is being built inside.
///
/// A run is the only asset whose appearance depends on the others: it needs
/// their positions to find its own ends, and its configure form needs their
/// names to offer as endpoints. `build(BuildContext)` and
/// `configure(BuildContext)` take nothing but a context, so the page arrives
/// this way rather than through forty constructors that do not want it.
///
/// Absent in a bare widget test, which is the case [maybeOf] exists for: a run
/// with no page around it falls back to [LinkAnchors.none] and draws between
/// its own stored coordinates.
class PageAssetsScope extends InheritedWidget {
  const PageAssetsScope({
    super.key,
    required this.assets,
    required this.canvas,
    required super.child,
  });

  final List<Asset> assets;

  /// Canvas pixel size, needed only to turn a port on a rotated asset.
  final Size canvas;

  static PageAssetsScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PageAssetsScope>();

  /// The anchors for this page, or [LinkAnchors.none] outside one.
  static LinkAnchors anchorsOf(BuildContext context) {
    final scope = maybeOf(context);
    return scope == null
        ? LinkAnchors.none
        : PageLinkAnchors(scope.assets, scope.canvas);
  }

  @override
  bool updateShouldNotify(PageAssetsScope old) =>
      old.canvas != canvas ||
      old.assets.length != assets.length ||
      !identical(old.assets, assets);
}
